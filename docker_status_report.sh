#!/bin/bash

LOCKFILE="/tmp/docker_status_report.lock"
if [ -e "$LOCKFILE" ]; then
  echo "$(date): Script already running or ran within lock window, exiting." >> /var/log/cron.log
  exit 1
fi
touch "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

#TO_RECIPIENTS="jvdumlao@gmanetwork.com avortigoza@gmanetwork.com prramos@gmanetwork.com avvillaceran@gmanetwork.com"
TO_RECIPIENTS="avortigoza@gmanetwork.com"
ALL_RECIPIENTS="$TO_RECIPIENTS"
#CC_RECIPIENTS="jidoringo@gmanetwork.com jvdumlao@gmanetwork.com rcmacorol@gmanetwork.com mlnaval@gmanetwork.com prramos@gmanetwork.com fsvalois@gmanetwork.com avvillaceran@gmanetwork.com"
#ALL_RECIPIENTS="$TO_RECIPIENTS $CC_RECIPIENTS"

REPORT_DATE=$(date +"%A, %B %d, %Y %I:%M %p")

# Optional API key for querying remote dash-api instances. Set DASH_API_KEY
# in /etc/dash/api.env (KEY=VALUE, one per line) to keep it out of this script.
[ -f /etc/dash/api.env ] && . /etc/dash/api.env
REMOTE_API_KEY="${DASH_API_KEY:-}"
REMOTE_API_PORT="${DASH_API_PORT:-5000}"

# Remote servers to poll via their dash-api endpoint, in addition to this
# host's own local Docker socket. Add more pairs here as needed.
REMOTE_NAMES=("vmmams-dev1" "vmmams-dev2")
REMOTE_HOSTS=("10.10.10.115" "10.10.10.163")

# Known component suffixes used ONLY as a fallback when a container has no
# docker-compose project label. Deliberately excludes generic words like
# "api", "app", "admin", "ui", "dashboard" — those are common as real standalone
# app names (e.g. dash-api, compliance-dashboard) and would cause false merges.
COMPONENT_SUFFIXES="db web worker cache redis mysql postgres postgresql nginx frontend backend queue cron scheduler proxy celery beat phpmyadmin adminer mailhog smtp ftp"

get_app_name_by_suffix() {
  local n="$1"
  for s in $COMPONENT_SUFFIXES; do
    case "$n" in
      *_"$s")
        echo "${n%_$s}"
        return
        ;;
      *-"$s")
        echo "${n%-$s}"
        return
        ;;
    esac
  done
  echo "$n"
}

# Preferred grouping: docker-compose sets com.docker.compose.project on every
# container it manages, which is the actual source of truth for "these
# containers are one app" — far more reliable than guessing from the name.
# Falls back to suffix-stripping only for containers with no such label.
get_app_name() {
  local project="$1"
  local name="$2"
  if [ -n "$project" ]; then
    echo "$project"
  else
    get_app_name_by_suffix "$name"
  fi
}

# Severity ranking used to pick the "worst" status across an app's containers
rank_for() {
  case "$1" in
    unhealthy) echo 4 ;;
    stopped)   echo 4 ;;
    created)   echo 2 ;;
    running)   echo 1 ;;
    healthy)   echo 0 ;;
    *)         echo 3 ;;
  esac
}

# Maps a container's raw status/health into our display label + badge color
label_for() {
  local status="$1"
  local health="$2"
  if [ "$health" = "healthy" ]; then
    echo "healthy|#22c55e"
  elif [ "$health" = "unhealthy" ]; then
    echo "unhealthy|#ef4444"
  elif [ "$status" = "running" ]; then
    echo "running|#22c55e"
  elif [ "$status" = "exited" ]; then
    echo "stopped|#ef4444"
  elif [ "$status" = "created" ]; then
    echo "created|#6b7280"
  else
    echo "${status}|#6b7280"
  fi
}

# Grand totals across ALL hosts, for the top-line overall summary
GRAND_TOTAL=0
GRAND_HEALTHY=0
GRAND_RUNNING=0
GRAND_STOPPED=0
GRAND_UNHEALTHY=0
GRAND_OTHER=0
GRAND_ISSUES=0
HOST_SECTIONS=""

# Builds one self-contained HTML "card" section for a single host: its own
# mini summary line, app-grouped container table, and attention block if it
# has any issues. Also folds this host's counts into the GRAND_* totals.
# Args: host_label, containers_json (array of {name,status,health,compose_project})
build_host_section() {
  local host_label="$1"
  local containers_json="$2"

  local -A APP_SEEN APP_RANK APP_LABEL APP_COLOR APP_DETAILS
  local APP_ORDER=()
  local ROWS="" ATTN=""
  local TOTAL=0 HEALTHY=0 RUNNING=0 STOPPED=0 UNHEALTHY=0 OTHER=0

  while IFS= read -r c; do
    [ -z "$c" ] && continue
    local NAME STATUS HEALTH PROJECT LC LABEL COLOR APP COMPONENT THIS_RANK
    NAME=$(echo "$c" | jq -r '.name')
    STATUS=$(echo "$c" | jq -r '.status')
    HEALTH=$(echo "$c" | jq -r '.health // empty')
    PROJECT=$(echo "$c" | jq -r '.compose_project // empty')

    LC=$(label_for "$STATUS" "$HEALTH")
    LABEL="${LC%%|*}"
    COLOR="${LC##*|}"

    TOTAL=$((TOTAL+1))
    case "$LABEL" in
      healthy) HEALTHY=$((HEALTHY+1)) ;;
      running) RUNNING=$((RUNNING+1)) ;;
      stopped)
        STOPPED=$((STOPPED+1))
        ATTN+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — stopped</td></tr>"
        ;;
      unhealthy)
        UNHEALTHY=$((UNHEALTHY+1))
        ATTN+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — unhealthy</td></tr>"
        ;;
      *)
        OTHER=$((OTHER+1))
        ATTN+="<tr><td style=\"padding:0 8px 8px 0;color:#7f1d1d;font-size:14px;vertical-align:top;width:14px;\">&bull;</td><td style=\"padding:0 0 8px 0;color:#7f1d1d;font-size:14px;\"><strong>${NAME}</strong> — ${LABEL}</td></tr>"
        ;;
    esac

    APP=$(get_app_name "$PROJECT" "$NAME")
    COMPONENT="${NAME#${APP}_}"
    [ "$COMPONENT" = "$NAME" ] && COMPONENT="${NAME#${APP}-}"
    [ "$COMPONENT" = "$NAME" ] && COMPONENT="$NAME"
    THIS_RANK=$(rank_for "$LABEL")

    if [ -z "${APP_SEEN[$APP]+x}" ]; then
      APP_SEEN[$APP]=1
      APP_ORDER+=("$APP")
      APP_RANK[$APP]=$THIS_RANK
      APP_LABEL[$APP]="$LABEL"
      APP_COLOR[$APP]="$COLOR"
      APP_DETAILS[$APP]="${COMPONENT}: ${LABEL}"
    else
      APP_DETAILS[$APP]+=" &middot; ${COMPONENT}: ${LABEL}"
      if [ "$THIS_RANK" -gt "${APP_RANK[$APP]}" ]; then
        APP_RANK[$APP]=$THIS_RANK
        APP_LABEL[$APP]="$LABEL"
        APP_COLOR[$APP]="$COLOR"
      fi
    fi
  done < <(echo "$containers_json" | jq -c '.[]' 2>/dev/null)

  local APP_TOTAL=${#APP_ORDER[@]}
  local IDX=0 ROW_BORDER APP L_LABEL L_COLOR L_DETAILS
  for APP in "${APP_ORDER[@]}"; do
    IDX=$((IDX+1))
    if [ "$IDX" -eq "$APP_TOTAL" ]; then
      ROW_BORDER=""
    else
      ROW_BORDER="border-bottom:1px solid #e5e7eb;"
    fi
    L_LABEL="${APP_LABEL[$APP]}"
    L_COLOR="${APP_COLOR[$APP]}"
    L_DETAILS="${APP_DETAILS[$APP]}"

    ROWS+="<tr>
    <td style=\"padding:16px 24px;${ROW_BORDER}color:#0ea5e9;font-size:15px;font-weight:500;font-family:Arial,Helvetica,sans-serif;\">${APP}
      <div style=\"margin-top:4px;color:#9ca3af;font-size:12px;font-weight:400;\">${L_DETAILS}</div>
    </td>
    <td style=\"padding:16px 24px;${ROW_BORDER}font-family:Arial,Helvetica,sans-serif;\">
      <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr>
        <td bgcolor=\"${L_COLOR}\" style=\"background:${L_COLOR};color:#ffffff;padding:6px 16px;border-radius:14px;font-size:13px;font-weight:600;font-family:Arial,Helvetica,sans-serif;text-align:center;\">${L_LABEL}</td>
      </tr></table>
    </td>
  </tr>"
  done

  local ISSUES=$((STOPPED + UNHEALTHY + OTHER))
  local BORDER_COLOR="#22c55e"
  [ "$ISSUES" -gt 0 ] && BORDER_COLOR="#ef4444"

  local HOST_HEALTH_SCORE=0
  [ "$TOTAL" -gt 0 ] && HOST_HEALTH_SCORE=$(( (TOTAL - ISSUES) * 100 / TOTAL ))

  local ATTN_CARD=""
  if [ -n "$ATTN" ]; then
    ATTN_CARD="
<tr><td style=\"height:16px;line-height:16px;font-size:0;\">&nbsp;</td></tr>
<tr><td style=\"background:#fff5f5;border:1px solid #fecaca;border-radius:12px;padding:20px 24px;font-family:Arial,Helvetica,sans-serif;\">
  <div style=\"color:#b91c1c;font-size:14px;font-weight:600;margin-bottom:10px;\">${host_label} — Requires attention</div>
  <table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"width:100%;\">${ATTN}</table>
</td></tr>"
  fi

  local SECTION="
<tr><td style=\"height:20px;line-height:20px;font-size:0;\">&nbsp;</td></tr>
<tr><td style=\"background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;\">
  <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\">
  <tr><td style=\"padding:24px 24px 0 24px;\">
    <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\">
    <tr><td bgcolor=\"#f9fafb\" style=\"background:#f9fafb;border-left:5px solid ${BORDER_COLOR};padding:16px 20px;border-radius:8px;\">
      <div style=\"font-size:17px;font-weight:700;color:#111827;\">${host_label}</div>
      <div style=\"margin-top:4px;color:#6b7280;font-size:13px;\">Health Score: <strong style=\"color:#111827;\">${HOST_HEALTH_SCORE}%</strong> &middot; Total: ${TOTAL} &middot; Healthy: ${HEALTHY} &middot; Running: ${RUNNING} &middot; Stopped: ${STOPPED} &middot; Unhealthy: ${UNHEALTHY}</div>
    </td></tr>
    </table>
  </td></tr>
  <tr><td style=\"padding:20px 24px 24px 24px;\">
    <table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\">
      <tr bgcolor=\"#f3f4f6\">
        <th align=\"left\" style=\"padding:14px 16px;color:#374151;font-size:13px;font-weight:600;border-radius:6px 0 0 6px;\">Name</th>
        <th align=\"left\" style=\"padding:14px 16px;color:#374151;font-size:13px;font-weight:600;border-radius:0 6px 6px 0;\">State</th>
      </tr>
      ${ROWS}
    </table>
  </td></tr>
  </table>
</td></tr>
${ATTN_CARD}"

  # Set as a global, not echoed+captured — command substitution ($(...)) forks
  # a subshell, which would silently discard the GRAND_* updates below.
  SECTION_HTML="$SECTION"

  GRAND_TOTAL=$((GRAND_TOTAL+TOTAL))
  GRAND_HEALTHY=$((GRAND_HEALTHY+HEALTHY))
  GRAND_RUNNING=$((GRAND_RUNNING+RUNNING))
  GRAND_STOPPED=$((GRAND_STOPPED+STOPPED))
  GRAND_UNHEALTHY=$((GRAND_UNHEALTHY+UNHEALTHY))
  GRAND_OTHER=$((GRAND_OTHER+OTHER))
  GRAND_ISSUES=$((GRAND_ISSUES+ISSUES))
}

# Builds an "unreachable" card for a remote host that couldn't be polled
build_unreachable_section() {
  local host_label="$1"
  local reason="$2"
  GRAND_ISSUES=$((GRAND_ISSUES+1))
  SECTION_HTML="
<tr><td style=\"height:20px;line-height:20px;font-size:0;\">&nbsp;</td></tr>
<tr><td style=\"background:#fff5f5;border:1px solid #fecaca;border-radius:12px;padding:24px;font-family:Arial,Helvetica,sans-serif;\">
  <div style=\"font-size:17px;font-weight:700;color:#b91c1c;\">${host_label}</div>
  <div style=\"margin-top:6px;color:#7f1d1d;font-size:14px;\">Could not be reached: ${reason}</div>
</td></tr>"
}

### --- Local host (this server) ---
CONTAINER_IDS=$(docker ps -aq | sort)
LOCAL_JSON="[]"
LOCAL_ITEMS=()
for ID in $CONTAINER_IDS; do
  INFO=$(docker inspect "$ID")
  ITEM=$(echo "$INFO" | jq -c '{
    name: (.[0].Name | ltrimstr("/")),
    status: .[0].State.Status,
    health: (.[0].State.Health.Status // null),
    compose_project: (.[0].Config.Labels["com.docker.compose.project"] // "")
  }')
  LOCAL_ITEMS+=("$ITEM")
done
if [ "${#LOCAL_ITEMS[@]}" -gt 0 ]; then
  LOCAL_JSON=$(printf '%s\n' "${LOCAL_ITEMS[@]}" | jq -s '.')
fi
build_host_section "vmmams-core (local)" "$LOCAL_JSON"
HOST_SECTIONS+="$SECTION_HTML"

### --- Remote hosts (via dash-api) ---
for i in "${!REMOTE_NAMES[@]}"; do
  RNAME="${REMOTE_NAMES[$i]}"
  RHOST="${REMOTE_HOSTS[$i]}"
  RURL="http://${RHOST}:${REMOTE_API_PORT}/api/v1/containers"

  RESPONSE=$(curl -s -m 10 -H "X-API-Key: ${REMOTE_API_KEY}" "$RURL" 2>/tmp/dash_curl_err_$$)
  CURL_RC=$?
  CURL_ERR=$(cat /tmp/dash_curl_err_$$ 2>/dev/null)
  rm -f /tmp/dash_curl_err_$$

  if [ "$CURL_RC" -ne 0 ]; then
    build_unreachable_section "${RNAME} (${RHOST})" "connection failed (${CURL_ERR:-curl exit $CURL_RC})"
    HOST_SECTIONS+="$SECTION_HTML"
    continue
  fi

  if ! echo "$RESPONSE" | jq empty >/dev/null 2>&1; then
    build_unreachable_section "${RNAME} (${RHOST})" "invalid response from dash-api"
    HOST_SECTIONS+="$SECTION_HTML"
    continue
  fi

  if echo "$RESPONSE" | jq -e 'has("error")' >/dev/null 2>&1; then
    ERRMSG=$(echo "$RESPONSE" | jq -r '.error')
    build_unreachable_section "${RNAME} (${RHOST})" "$ERRMSG"
    HOST_SECTIONS+="$SECTION_HTML"
    continue
  fi

  build_host_section "${RNAME} (${RHOST})" "$RESPONSE"
  HOST_SECTIONS+="$SECTION_HTML"
done

### --- Assemble final email ---
OVERALL_COLOR="#22c55e"
[ "$GRAND_ISSUES" -gt 0 ] && OVERALL_COLOR="#f9a8d4"

HEALTH_SCORE=0
[ "$GRAND_TOTAL" -gt 0 ] && HEALTH_SCORE=$(( (GRAND_TOTAL - GRAND_ISSUES) * 100 / GRAND_TOTAL ))

SUMMARY_TEXT="A total of ${GRAND_TOTAL} Docker containers were assessed across 3 hosts (vmmams-core, vmmams-dev1, vmmams-dev2).<br><br>${GRAND_HEALTHY} container(s) reported a healthy state through Docker health checks, while ${GRAND_RUNNING} container(s) were running normally without health check monitoring enabled.<br><br>${GRAND_STOPPED} container(s) were stopped, ${GRAND_UNHEALTHY} container(s) were unhealthy, and ${GRAND_OTHER} container(s) reported an unexpected state.<br><br>The overall environment health score is ${HEALTH_SCORE}%."

HTML=$(cat <<EOF
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<!--[if mso]>
<style type="text/css">
table {border-collapse:collapse;}
</style>
<![endif]-->
</head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:Arial,Helvetica,sans-serif;">

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f3f4f6;">
<tr><td align="center" style="padding:30px 20px;">

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:900px;">

<!-- HEADER -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;">
  <div style="font-size:13px;color:#6b7280;text-transform:uppercase;letter-spacing:1px;">Weekly Infrastructure Report — DASH</div>
<h1 style="margin:10px 0 20px 0;font-size:28px;color:#111827;">Docker Automated Status Health (Check)</h1>

  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
  <tr><td bgcolor="#f9fafb" style="background:#f9fafb;border-left:5px solid ${OVERALL_COLOR};padding:20px;border-radius:10px;">
    <div style="color:#6b7280;font-size:14px;">Hosts: vmmams-core, vmmams-dev1, vmmams-dev2</div>
    <div style="margin-top:4px;color:#6b7280;font-size:14px;">Generated: ${REPORT_DATE}</div>
  </td></tr>
  </table>
</td></tr>

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

<!-- OVERALL SUMMARY -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;">
  <h2 style="margin:0 0 16px 0;color:#111827;font-size:20px;">Environment Summary (All Hosts)</h2>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="font-size:15px;">
    <tr><td style="padding:10px 0;color:#374151;">Health Score</td><td align="right" style="padding:10px 0;font-weight:700;color:#111827;">${HEALTH_SCORE}%</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Total Containers</td><td align="right" style="padding:10px 0;font-weight:700;color:#111827;border-top:1px solid #f0f0f0;">${GRAND_TOTAL}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Healthy</td><td align="right" style="padding:10px 0;font-weight:700;color:#22c55e;border-top:1px solid #f0f0f0;">${GRAND_HEALTHY}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Running</td><td align="right" style="padding:10px 0;font-weight:700;color:#22c55e;border-top:1px solid #f0f0f0;">${GRAND_RUNNING}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Stopped</td><td align="right" style="padding:10px 0;font-weight:700;color:#ef4444;border-top:1px solid #f0f0f0;">${GRAND_STOPPED}</td></tr>
    <tr><td style="padding:10px 0;color:#374151;border-top:1px solid #f0f0f0;">Unhealthy</td><td align="right" style="padding:10px 0;font-weight:700;color:#ef4444;border-top:1px solid #f0f0f0;">${GRAND_UNHEALTHY}</td></tr>
  </table>
</td></tr>

${HOST_SECTIONS}

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

<!-- EXECUTIVE SUMMARY -->
<tr><td style="background:#ffffff;border:1px solid #e5e7eb;border-radius:12px;padding:30px;font-family:Arial,Helvetica,sans-serif;overflow:hidden;">
  <h2 style="margin:0 0 16px 0;color:#111827;font-size:20px;">Executive Summary</h2>
  <p style="color:#374151;font-size:14px;line-height:1.7;margin:0;">${SUMMARY_TEXT}</p>
</td></tr>

<tr><td style="height:20px;line-height:20px;font-size:0;">&nbsp;</td></tr>

</table>
EOF
)

HTML+="
<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:900px;margin:0 auto;\">
<tr><td align=\"center\" style=\"padding:10px 0;color:#9ca3af;font-size:12px;font-family:Arial,Helvetica,sans-serif;\">
	DASH — Docker Automated Status Health (Check) Report
</td></tr>
</table>

</td></tr>
</table>

</body>
</html>
"

SUBJECT="DASH Weekly Report - $(date +"%B %-d, %Y")"

{
  echo "To: $(echo "$TO_RECIPIENTS" | tr ' ' ', ')"
 # echo "Cc: $(echo "$CC_RECIPIENTS" | tr ' ' ', ')"
  echo "From: \"DASH Notifications\" <gma7postmams@gmail.com>"
  echo "Subject: ${SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/html; charset=UTF-8"
  echo
  echo "$HTML"
} | msmtp -a gmail $ALL_RECIPIENTS
