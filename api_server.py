import os
from functools import wraps
from flask import Flask, jsonify, request
import docker

app = Flask(__name__)
client = docker.from_env()
API_KEY = os.environ.get("API_KEY", "")

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
        result.append({
            "name": c.name,
            "status": c.attrs["State"]["Status"],
            "health": c.attrs["State"].get("Health", {}).get("Status"),
            "label": label,
            "image": c.attrs["Config"]["Image"],
        })
    return result

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

@app.route("/api/v1/summary")
@require_api_key
def summary():
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
    return jsonify(get_all_containers())

@app.route("/api/v1/containers/<name>")
@require_api_key
def container_detail(name):
    for c in get_all_containers():
        if c["name"] == name:
            return jsonify(c)
    return jsonify({"error": "Container not found"}), 404

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
