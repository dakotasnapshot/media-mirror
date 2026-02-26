#!/usr/bin/env python3
"""Media Mirror Dashboard — Web server for monitoring and controlling the pipeline."""
import http.server
import json
import os
import signal
import subprocess
import socketserver
import urllib.parse
import datetime

PORT = int(os.environ.get("DASHBOARD_PORT", 8080))
STATE_FILE = os.environ.get("STATE_FILE", "/opt/media-mirror/state.json")
LOG_DIR = os.environ.get("LOG_DIR", "/opt/media-mirror/logs")
CONFIG_FILE = os.environ.get("CONFIG_FILE", "/opt/media-mirror/config.env")
INSTALL_DIR = os.environ.get("INSTALL_DIR", "/opt/media-mirror")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def read_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"jobs": [], "stats": {}, "runner": {"status": "unknown", "paused": False}}


def read_config():
    config = {}
    try:
        with open(CONFIG_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    config[key.strip()] = val.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return config


def write_config(updates):
    """Update config.env with new values, preserving comments and structure."""
    lines = []
    try:
        with open(CONFIG_FILE, "r") as f:
            lines = f.readlines()
    except FileNotFoundError:
        pass

    updated_keys = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in updates:
                new_lines.append(f'{key}="{updates[key]}"\n')
                updated_keys.add(key)
                continue
        new_lines.append(line)

    # Append any keys that weren't already in the file
    for key, val in updates.items():
        if key not in updated_keys:
            new_lines.append(f'{key}="{val}"\n')

    with open(CONFIG_FILE, "w") as f:
        f.writelines(new_lines)


def get_disk_usage():
    disks = {}
    config = read_config()

    # Local disks (source + temp)
    for label, path in [("source", config.get("SOURCE_MOVIES", "")), ("temp", config.get("TEMP_DIR", ""))]:
        if not path:
            continue
        try:
            result = subprocess.run(["df", "-h", path], capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                lines = result.stdout.strip().split("\n")
                if len(lines) > 1:
                    parts = lines[1].split()
                    disks[label] = {"mount": parts[-1], "size": parts[1], "used": parts[2], "avail": parts[3], "pct": parts[4]}
        except Exception:
            pass

    # Remote disk (destination)
    dest_host = config.get("DEST_HOST", "")
    dest_key = config.get("DEST_SSH_KEY", "")
    dest_movies = config.get("DEST_MOVIES", "")
    if dest_host and dest_key and dest_movies:
        try:
            result = subprocess.run(
                ["ssh", "-i", dest_key, "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=3",
                 dest_host, f"df -h '{dest_movies}'"],
                capture_output=True, text=True, timeout=8
            )
            if result.returncode == 0:
                lines = result.stdout.strip().split("\n")
                if len(lines) > 1:
                    parts = lines[1].split()
                    disks["dest"] = {"mount": f"{dest_host}:{parts[-1]}", "size": parts[1], "used": parts[2], "avail": parts[3], "pct": parts[4]}
        except Exception:
            pass
    return disks


def get_runner_pid():
    pid_file = os.path.join(INSTALL_DIR, "runner.pid")
    try:
        with open(pid_file, "r") as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)  # Check if alive
        return pid
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError):
        return None


def start_runner():
    if get_runner_pid():
        return {"ok": False, "error": "Runner is already running"}
    script = os.path.join(INSTALL_DIR, "media-mirror.sh")
    log_out = os.path.join(LOG_DIR, "runner-stdout.log")
    log_err = os.path.join(LOG_DIR, "runner-stderr.log")
    with open(log_out, "a") as out, open(log_err, "a") as err:
        proc = subprocess.Popen(
            ["/bin/bash", script],
            stdout=out, stderr=err,
            start_new_session=True
        )
    return {"ok": True, "pid": proc.pid}


def stop_runner():
    # Kill ALL runner processes (not just the PID file one)
    pid = get_runner_pid()
    try:
        result = subprocess.run(
            ["pkill", "-9", "-f", os.path.join(INSTALL_DIR, "media-mirror.sh")],
            capture_output=True, timeout=5
        )
    except Exception:
        pass
    # Also try the PID file
    if pid:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    # Clean PID file
    pid_file = os.path.join(INSTALL_DIR, "runner.pid")
    try:
        os.remove(pid_file)
    except FileNotFoundError:
        pass
    return {"ok": True, "stopped": pid or 0}


class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/api/status":
            state = read_state()
            config = read_config()
            disks = get_disk_usage()

            active = [j for j in state["jobs"] if j["status"] in ("converting", "transferring", "queued")]
            recent_done = [j for j in state["jobs"] if j["status"] == "done"][-20:]
            failed = [j for j in state["jobs"] if j["status"] == "failed"]

            # Calculate ETA from completed jobs
            eta = {}
            done_jobs_with_times = [
                j for j in state["jobs"]
                if j["status"] == "done" and j.get("started") and j.get("updated")
            ]
            inventory = state.get("inventory", {})
            if done_jobs_with_times:
                try:
                    times = []
                    for j in done_jobs_with_times:
                        start = datetime.datetime.fromisoformat(j["started"])
                        end = datetime.datetime.fromisoformat(j["updated"])
                        times.append((end - start).total_seconds())
                    avg_secs = sum(times) / len(times)
                    # Use inventory scan for accurate totals
                    source_total = inventory.get("source_total", 0)
                    dest_done = inventory.get("dest_done", 0)
                    session_done = len([j for j in state["jobs"] if j["status"] in ("done", "skipped")])
                    total_completed = dest_done + session_done
                    remaining = max(0, source_total - total_completed) if source_total else 0
                    eta = {
                        "avg_per_file_secs": round(avg_secs),
                        "source_total": source_total,
                        "completed": total_completed,
                        "remaining": remaining,
                        "est_remaining_hours": round(remaining * avg_secs / 3600, 1),
                        "est_remaining_days": round(remaining * avg_secs / 86400, 1),
                    }
                except Exception:
                    pass

            response = {
                "runner": state.get("runner", {}),
                "runner_pid": get_runner_pid(),
                "stats": state.get("stats", {}),
                "eta": eta,
                "active_jobs": active[:50],
                "recent_done": recent_done,
                "failed": failed[:20],
                "disks": disks,
                "config": {
                    "source_movies": config.get("SOURCE_MOVIES", ""),
                    "source_tv": config.get("SOURCE_TV", ""),
                    "dest_host": config.get("DEST_HOST", ""),
                    "dest_movies": config.get("DEST_MOVIES", ""),
                    "dest_tv": config.get("DEST_TV", ""),
                    "temp_dir": config.get("TEMP_DIR", ""),
                    "dest_ssh_key": config.get("DEST_SSH_KEY", ""),
                    "target_height": config.get("TARGET_HEIGHT", "720"),
                    "ffmpeg_crf": config.get("FFMPEG_CRF", "23"),
                    "ffmpeg_preset": config.get("FFMPEG_PRESET", "medium"),
                    "ffmpeg_threads": config.get("FFMPEG_THREADS", "4"),
                    "rsync_bwlimit": config.get("RSYNC_BWLIMIT", "100000"),
                    "scan_interval": config.get("SCAN_INTERVAL", "3600"),
                    "dashboard_port": config.get("DASHBOARD_PORT", "8080"),
                },
                "timestamp": datetime.datetime.now().isoformat(),
            }

            self._json_response(200, response)

        elif parsed.path == "/api/config":
            self._json_response(200, read_config())

        elif parsed.path == "/api/pause":
            state = read_state()
            state["runner"]["paused"] = True
            with open(STATE_FILE, "w") as f:
                json.dump(state, f)
            self._json_response(200, {"ok": True, "paused": True})

        elif parsed.path == "/api/resume":
            state = read_state()
            state["runner"]["paused"] = False
            with open(STATE_FILE, "w") as f:
                json.dump(state, f)
            self._json_response(200, {"ok": True, "paused": False})

        elif parsed.path == "/api/runner/start":
            self._json_response(200, start_runner())

        elif parsed.path == "/api/runner/stop":
            self._json_response(200, stop_runner())

        elif parsed.path == "/api/runner/restart":
            stop_runner()
            import time; time.sleep(2)
            self._json_response(200, start_runner())

        elif parsed.path.startswith("/api/log/"):
            filename = urllib.parse.unquote(parsed.path[9:])
            path = os.path.join(LOG_DIR, filename)
            try:
                result = subprocess.run(["tail", "-50", path], capture_output=True, text=True, timeout=5)
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(result.stdout.encode())
            except Exception:
                self.send_response(404)
                self.end_headers()

        elif parsed.path == "/" or parsed.path == "/index.html":
            html_path = os.path.join(SCRIPT_DIR, "index.html")
            try:
                with open(html_path, "r") as f:
                    content = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(content.encode())
            except FileNotFoundError:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"index.html not found")
        else:
            super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/api/config":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                updates = json.loads(body)
                # Map friendly names to config keys
                key_map = {
                    "source_movies": "SOURCE_MOVIES",
                    "source_tv": "SOURCE_TV",
                    "dest_host": "DEST_HOST",
                    "dest_movies": "DEST_MOVIES",
                    "dest_tv": "DEST_TV",
                    "temp_dir": "TEMP_DIR",
                    "dest_ssh_key": "DEST_SSH_KEY",
                    "target_height": "TARGET_HEIGHT",
                    "ffmpeg_crf": "FFMPEG_CRF",
                    "ffmpeg_preset": "FFMPEG_PRESET",
                    "ffmpeg_threads": "FFMPEG_THREADS",
                    "rsync_bwlimit": "RSYNC_BWLIMIT",
                    "scan_interval": "SCAN_INTERVAL",
                    "dashboard_port": "DASHBOARD_PORT",
                }
                mapped = {}
                for k, v in updates.items():
                    config_key = key_map.get(k, k)
                    mapped[config_key] = str(v)
                write_config(mapped)
                self._json_response(200, {"ok": True, "updated": list(mapped.keys())})
            except (json.JSONDecodeError, Exception) as e:
                self._json_response(400, {"ok": False, "error": str(e)})
        else:
            self.send_response(404)
            self.end_headers()

    def _json_response(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("0.0.0.0", PORT), DashboardHandler) as httpd:
        print(f"Media Mirror Dashboard running on http://0.0.0.0:{PORT}")
        httpd.serve_forever()
