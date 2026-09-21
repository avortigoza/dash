# DASH — Docker Automated Status Health (Check)

DASH is a weekly email report that summarizes the health of every Docker
container running across your infrastructure. It groups containers by
application (not by individual container), pulls in data from remote
servers over HTTP, and sends a single combined HTML report by email.

## What it does

- Inspects every Docker container on the host it runs on (via the Docker
  socket) and, optionally, on any number of remote servers (via a small
  HTTP API, `dash-api`, deployed on each of them).
- Groups containers that belong to the same app into a single row, using
  each container's `com.docker.compose.project` label as the source of
  truth. Containers with no compose label fall back to stripping a small
  set of known component suffixes from the name (`db`, `web`, `nginx`,
  `phpmyadmin`, etc.) — this fallback deliberately excludes generic words
  like `api`, `app`, `admin`, `dashboard`, since those are also common as
  real standalone app names and would otherwise cause false merges.
- Builds one HTML section per host, each with its own health score,
  status counts, container table, and a separate "Requires attention"
  card for anything stopped, unhealthy, or in an unexpected state.
- Sends the finished report by email via `msmtp`.

## Repository layout

| File | Purpose |
|---|---|
| `docker_status_report.sh` | The main report script — inspects Docker, builds the HTML, sends the email |
| `Dockerfile` | Builds the mailer image (Alpine + `docker-cli`, `msmtp`, `bash`, `jq`, `curl`) |
| `Makefile` | Build/run/test commands for the mailer |
| `crontab.txt` | Cron schedule baked into the mailer image (default: Fridays 9:00 AM) |
| `msmtprc.example` | Template for the mailer's SMTP credentials — copy to `msmtprc` and fill in |
| `api_server.py` | `dash-api` — a small Flask app exposing one host's container status over HTTP, with a Swagger UI |
| `Dockerfile.api` | Builds the `dash-api` image |

## Architecture

DASH has two components that run in different places:

```
                 ┌─────────────────────────┐
                 │   vmmams-core            │
                 │   (runs the mailer)      │
                 │                          │
                 │  docker_status_report.sh │
                 │  reads its own Docker    │
                 │  socket directly         │
                 └──────────┬───────────────┘
                             │ HTTP GET /api/v1/containers
              ┌──────────────┴──────────────┐
              ▼                             ▼
   ┌────────────────────┐        ┌────────────────────┐
   │  vmmams-dev1        │        │  vmmams-dev2        │
   │  dash-api :5000      │        │  dash-api :5000      │
   └────────────────────┘        └────────────────────┘
```

- The **mailer** only needs to run on **one** server — the one that will
  actually send the email. It reads its own containers directly through
  the Docker socket, no HTTP call required for itself.
- **`dash-api`** runs on every *other* server you want included in the
  report. It exposes that host's container list over HTTP so the mailer
  can poll it and fold the results into the same email.

You do not need `dash-api` running on the mailer's own host unless you
specifically want to browse its Swagger UI there too.

## Prerequisites

- Docker installed on every server involved.
- The mailer's host needs outbound network access to port `5000` (or
  whichever port you configure) on every remote server running
  `dash-api`.
- A Gmail account (or any SMTP account) to send from, with an
  [app password](https://support.google.com/accounts/answer/185833) if
  using Gmail with 2FA.

## Installation

### 1. Clone the repo

```bash
git clone <this-repo-url> dash
cd dash
```

Clone this on **every** server that will run either the mailer or
`dash-api`.

### 2. Set up the mailer (one server only)

Configure SMTP credentials:

```bash
cp msmtprc.example msmtprc
```

Edit `msmtprc` and fill in your sender address and app password:

```
account gmail
host smtp.gmail.com
port 587
from YOUR_GMAIL_ADDRESS
user YOUR_GMAIL_ADDRESS
password YOUR_GMAIL_APP_PASSWORD
```

Set the recipient list by editing `TO_RECIPIENTS` near the top of
`docker_status_report.sh`:

```bash
TO_RECIPIENTS="person1@example.com person2@example.com"
```

If you want to poll remote servers via `dash-api`, edit the
`REMOTE_NAMES` / `REMOTE_HOSTS` arrays a little further down in the same
file:

```bash
REMOTE_NAMES=("vmmams-dev1" "vmmams-dev2")
REMOTE_HOSTS=("10.10.10.115" "10.10.10.163")
```

If `dash-api` on those hosts requires an API key (see below), put it in
`/etc/dash/api.env` on the mailer's host so it isn't hardcoded in the
script:

```bash
sudo mkdir -p /etc/dash
echo 'DASH_API_KEY=yourSecretKeyHere' | sudo tee /etc/dash/api.env
sudo chmod 600 /etc/dash/api.env
```

Build and start the mailer:

```bash
make build
make run
```

The container runs `crond` in the foreground and fires the report on the
schedule in `crontab.txt` (default: **Fridays at 9:00 AM**, container
timezone `Asia/Manila` — edit both the crontab and the `Dockerfile`'s
`TZ` value if you need a different schedule/timezone).

### 3. Set up `dash-api` (on each remote server you want polled)

```bash
make api-build
make api-run
```

To protect the endpoint with an API key instead of leaving it open:

```bash
make api-run API_KEY=yourSecretKeyHere
```

(Use the same key here as you put in `/etc/dash/api.env` on the mailer's
host.)

This exposes port `5000` on that server. Make sure it's reachable from
the mailer's host — either directly, or through whatever
routing/firewall/port-forwarding your network requires between the two.

## Usage

| Command | What it does |
|---|---|
| `make build` | Build the mailer image |
| `make run` | (Re)start the mailer container |
| `make restart` | Rebuild + restart — use this after editing the script or Dockerfile |
| `make test` | Force-run the report right now, bypassing cron |
| `make recipients` | Show which recipients are baked into the running script |
| `make logs` | Show the `msmtp` send log |
| `make crontab-check` | Show the container's active crontab |
| `make status` | Show container status |
| `make all` | Rebuild + restart + test, all in one go |
| `make clean` | Stop the container and remove the built image |
| `make api-build` | Build the `dash-api` image |
| `make api-run [API_KEY=...]` | (Re)start `dash-api` |
| `make api-restart [API_KEY=...]` | Rebuild + restart `dash-api` |
| `make api-logs` | Show `dash-api`'s logs |

### Testing without spamming your recipient list

`make test` sends to the real `TO_RECIPIENTS` list. To test safely,
temporarily override it:

```bash
cp docker_status_report.sh /tmp/dash_test.sh
sed -i 's/^TO_RECIPIENTS=.*/TO_RECIPIENTS="you@example.com"/' /tmp/dash_test.sh
docker exec -i status-mailer bash -c "$(cat /tmp/dash_test.sh)"
rm /tmp/dash_test.sh
```

### `dash-api` Swagger UI

Once `dash-api` is running, browse to:

```
http://<server-ip>:5000/apidocs/
```

for interactive documentation of all endpoints (`/health`,
`/api/v1/summary`, `/api/v1/containers`, `/api/v1/containers/<name>`),
including example responses and, if you set one, the `X-API-Key` header
required to authenticate.

## Updating

Pull the latest changes and rebuild:

```bash
git pull origin main
make restart          # for the mailer
# and/or, on servers running dash-api:
make api-build && make api-run [API_KEY=...]
```

If you've made local edits to `docker_status_report.sh` (e.g. a
one-off recipient change) that you haven't committed, `git pull` will
refuse to overwrite them. Either commit your change first, or:

```bash
git stash
git pull origin main
git stash pop
```

## Notes on container grouping

DASH groups containers into one row per application rather than one row
per container. It prefers each container's
`com.docker.compose.project` label (set automatically by `docker
compose`) as the grouping key, since that's the actual source of truth
for "these containers are one app." Containers with no compose label
(e.g. started with plain `docker run`) fall back to stripping a known
suffix from the name — see `COMPONENT_SUFFIXES` near the top of
`docker_status_report.sh` if you need to add more.

## Security notes

- `dash-api` exposes your container inventory (names, images, running
  state) over plain HTTP. Set an API key (`API_KEY=...` on `make
  api-run`) unless the port is already restricted to trusted hosts only
  (e.g. via firewall rules scoped to the mailer's IP).
- `msmtprc` contains your SMTP password in plaintext — it's excluded
  from version control on purpose (see `.gitignore`) and should never be
  committed. Only `msmtprc.example` (with placeholder values) is tracked.
