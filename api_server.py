import os
from functools import wraps
from flask import Flask, jsonify, request
from flasgger import Swagger
import docker

app = Flask(__name__)
client = docker.from_env()
API_KEY = os.environ.get("API_KEY", "")

app.config["SWAGGER"] = {
    "title": "DASH API",
    "uiversion": 3,
    "specs_route": "/apidocs/",
}

swagger_template = {
    "swagger": "2.0",
    "info": {
        "title": "DASH API",
        "description": (
            "Docker Automated Status Health (DASH) — exposes this host's Docker "
            "container status over HTTP. Polled by the DASH weekly report script "
            "(docker_status_report.sh) running on vmmams-core to build one combined "
            "multi-host email report."
        ),
        "version": "1.0.0",
    },
    "securityDefinitions": {
        "ApiKeyAuth": {
            "type": "apiKey",
            "name": "X-API-Key",
            "in": "header",
            "description": (
                "Required only if this server was started with API_KEY set "
                "(see the api-run Makefile target). If no key was configured, "
                "these endpoints are open."
            ),
        }
    },
    "security": [{"ApiKeyAuth": []}],
}

swagger = Swagger(app, template=swagger_template)


def require_api_key(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if API_KEY:
            key = request.headers.get("X-API-Key", "")
            if key != API_KEY:
                return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper


def classify(c):
    attrs = c.attrs
    status = attrs["State"]["Status"]
    health = attrs["State"].get("Health", {}).get("Status")
    if health == "healthy":
        return "healthy"
    if health == "unhealthy":
        return "unhealthy"
    if status == "running":
        return "running"
    if status == "exited":
        return "stopped"
    if status == "created":
        return "created"
    return status


def get_all_containers():
    result = []
    for c in client.containers.list(all=True):
        label = classify(c)
        labels = c.attrs["Config"].get("Labels") or {}
        result.append({
            "name": c.name,
            "status": c.attrs["State"]["Status"],
            "health": c.attrs["State"].get("Health", {}).get("Status"),
            "label": label,
            "image": c.attrs["Config"]["Image"],
            "compose_project": labels.get("com.docker.compose.project", ""),
        })
    return result


@app.route("/health")
def health():
    """
    Liveness check — always open, no API key required.
    ---
    tags:
      - Meta
    security: []
    responses:
      200:
        description: Server is up
        schema:
          type: object
          properties:
            status:
              type: string
              example: ok
    """
    return jsonify({"status": "ok"})


@app.route("/api/v1/summary")
@require_api_key
def summary():
    """
    Roll-up counts and health score for this host.
    ---
    tags:
      - Status
    parameters:
      - name: X-API-Key
        in: header
        type: string
        required: false
        description: Required only if this server was started with an API key.
    responses:
      200:
        description: Aggregate status for this host
        schema:
          type: object
          properties:
            host:
              type: string
              example: vmmams-core
            total_containers:
              type: integer
              example: 24
            healthy:
              type: integer
              example: 10
            running:
              type: integer
              example: 12
            stopped:
              type: integer
              example: 1
            unhealthy:
              type: integer
              example: 1
            other:
              type: integer
              example: 0
            health_score:
              type: integer
              example: 92
      401:
        description: Missing or incorrect X-API-Key
    """
    containers = get_all_containers()
    total = len(containers)
    healthy = sum(1 for c in containers if c["label"] == "healthy")
    running = sum(1 for c in containers if c["label"] == "running")
    stopped = sum(1 for c in containers if c["label"] == "stopped")
    unhealthy = sum(1 for c in containers if c["label"] == "unhealthy")
    other = total - healthy - running - stopped - unhealthy
    issues = stopped + unhealthy + other
    health_score = round((total - issues) * 100 / total) if total else 0

    return jsonify({
        "host": os.environ.get("REPORT_HOSTNAME", "vmmams-core"),
        "total_containers": total,
        "healthy": healthy,
        "running": running,
        "stopped": stopped,
        "unhealthy": unhealthy,
        "other": other,
        "health_score": health_score
    })


@app.route("/api/v1/containers")
@require_api_key
def containers():
    """
    List every container on this host, with status and compose-project grouping.
    ---
    tags:
      - Status
    parameters:
      - name: X-API-Key
        in: header
        type: string
        required: false
        description: Required only if this server was started with an API key.
    responses:
      200:
        description: All containers on this host
        schema:
          type: array
          items:
            type: object
            properties:
              name:
                type: string
                example: axis-db
              status:
                type: string
                example: running
              health:
                type: string
                example: healthy
              label:
                type: string
                example: healthy
              image:
                type: string
                example: mysql:8
              compose_project:
                type: string
                example: axis
      401:
        description: Missing or incorrect X-API-Key
    """
    return jsonify(get_all_containers())


@app.route("/api/v1/containers/<name>")
@require_api_key
def container_detail(name):
    """
    Look up a single container by its exact name.
    ---
    tags:
      - Status
    parameters:
      - name: name
        in: path
        type: string
        required: true
        description: Exact container name (as shown by `docker ps`)
      - name: X-API-Key
        in: header
        type: string
        required: false
        description: Required only if this server was started with an API key.
    responses:
      200:
        description: The matching container
        schema:
          type: object
          properties:
            name:
              type: string
              example: axis-db
            status:
              type: string
              example: running
            health:
              type: string
              example: healthy
            label:
              type: string
              example: healthy
            image:
              type: string
              example: mysql:8
            compose_project:
              type: string
              example: axis
      404:
        description: No container with that name
      401:
        description: Missing or incorrect X-API-Key
    """
    for c in get_all_containers():
        if c["name"] == name:
            return jsonify(c)
    return jsonify({"error": "Container not found"}), 404


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
