import argparse
import csv
import hashlib
import json
import os
import re
import socket
import subprocess
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPORT = "o11n.vllm.report/1"
COMMIT = re.compile(r"[0-9a-f]{40}")
GPU_FIELDS = "index,uuid,name,compute_cap,memory.total,driver_version"


class Hashes:
    def __init__(self, path):
        self.path = path
        self.known = {}
        self.lock = threading.Lock()
        self.hashing = threading.Lock()
        if path is not None and path.is_file():
            try:
                self.known = json.loads(path.read_text())
            except ValueError:
                pass

    def _cached(self, real, key):
        with self.lock:
            known = self.known.get(real)
        return known[2] if known is not None and known[:2] == key else None

    def sha256(self, file):
        real = os.path.realpath(file)
        stat = os.stat(real)
        key = [stat.st_size, stat.st_mtime_ns]
        if (cached := self._cached(real, key)) is not None:
            return cached
        with self.hashing:
            if (cached := self._cached(real, key)) is not None:
                return cached
            with open(real, "rb") as f:
                digest = hashlib.file_digest(f, "sha256").hexdigest()
            with self.lock:
                self.known[real] = key + [digest]
                if self.path is not None:
                    tmp = self.path.with_name(self.path.name + ".tmp")
                    tmp.write_text(json.dumps(self.known))
                    tmp.replace(self.path)
        return digest


def attempt(f, *args):
    try:
        return f(*args)
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}"}


def gpus(nvidia_smi):
    out = subprocess.run(
        [nvidia_smi, f"--query-gpu={GPU_FIELDS}", "--format=csv,noheader,nounits"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    ).stdout
    found = {}
    for row in csv.reader(out.splitlines(), skipinitialspace=True):
        if not row:
            continue
        index, uuid, name, capability, memory, driver = row
        major, minor = capability.split(".")
        found[int(index)] = {
            "index": int(index),
            "uuid": uuid,
            "name": name,
            "compute_capability": [int(major), int(minor)],
            "memory_mib": int(memory),
            "driver": driver,
        }
    return found


def allowed_gpus(found, indices):
    if "error" in found:
        return found
    missing = [i for i in indices if i not in found]
    if missing:
        raise LookupError(f"nvidia-smi lists no GPU {missing}")
    return [found[i] for i in indices]


# vLLM finds a model the way huggingface_hub does offline: a local directory as is,
# a repo id through the cache's refs (a commit hash names its snapshot directly).
def model(hub_cache, server, hashes):
    name = server["model"]
    if name.startswith("/"):
        snapshot, revision = Path(name), None
    else:
        repo = Path(hub_cache) / ("models--" + name.replace("/", "--"))
        ref = server["revision"] or "main"
        if COMMIT.fullmatch(ref):
            revision = ref
        else:
            revision = (repo / "refs" / ref).read_text().strip()
        snapshot = repo / "snapshots" / revision
    if not snapshot.is_dir():
        raise FileNotFoundError(f"no model directory {snapshot}")
    files = sorted(p for p in snapshot.rglob("*") if p.is_file())
    if not files:
        raise FileNotFoundError(f"no files in {snapshot}")
    config = snapshot / "config.json"
    return {
        "id": name,
        "revision": revision,
        "path": str(snapshot),
        "model_type": (
            json.loads(config.read_text()).get("model_type")
            if config.is_file()
            else None
        ),
        "files": [
            {
                "path": p.relative_to(snapshot).as_posix(),
                "size": p.stat().st_size,
                "sha256": hashes.sha256(p),
            }
            for p in files
        ],
    }


# Where a model keeps its own chat template, in the order transformers prefers them.
MODEL_TEMPLATES = ("chat_template.jinja", "chat_template.json", "tokenizer_config.json")


# The model's own chat template, and whether the configured one is the same to Jinja,
# which drops a single trailing newline from a template.
def model_template(path, model):
    if "path" not in model:
        raise LookupError("the model's files are unavailable")
    for name in MODEL_TEMPLATES:
        file = Path(model["path"]) / name
        if not file.is_file():
            continue
        text = file.read_text(encoding="utf-8")
        template = text if file.suffix == ".jinja" else json.loads(text).get("chat_template")
        # A tokenizer may name several; vLLM takes "default" for requests without tools.
        if isinstance(template, list):
            template = next(
                (t.get("template") for t in template if t.get("name") == "default"),
                None,
            )
        if isinstance(template, str):
            configured = Path(path).read_text(encoding="utf-8")
            return {
                "path": name,
                "sha256": hashlib.sha256(template.encode()).hexdigest(),
                "matches": configured.removesuffix("\n") == template.removesuffix("\n"),
            }
    return None


def chat_template(path, model):
    with open(path, "rb") as f:
        digest = hashlib.file_digest(f, "sha256").hexdigest()
    return {
        "path": path,
        "sha256": digest,
        # vLLM 0.24 renders gpt-oss with Harmony and never reads the template:
        # https://github.com/vllm-project/vllm/blob/v0.24.0/vllm/entrypoints/serve/render/serving.py#L234
        "used": model.get("model_type") != "gpt_oss",
        "model_template": attempt(model_template, path, model),
    }


def parent(pid):
    stat = Path(f"/proc/{pid}/stat").read_text()
    return int(stat.rpartition(")")[2].split()[1])


# The server runs as a service in its container, which systemd-nspawn puts in the
# payload/ cgroup of the container's unit: its processes are listed there by host PID.
def process(systemctl, server):
    cgroup = subprocess.run(
        [systemctl, "show", "--property=ControlGroup", "--value", server["unit"]],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout.strip()
    procs = Path(
        f"/sys/fs/cgroup{cgroup}/payload/system.slice/{server['service']}/cgroup.procs"
    )
    pids = {int(p) for p in procs.read_text().split()} if procs.is_file() else set()
    if not pids:
        return {"running": False}
    # The main process is the one the service's others descend from.
    pid = min(p for p in pids if parent(p) not in pids)
    cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
    argv = [a.decode(errors="replace") for a in cmdline.split(b"\0")[:-1]]
    tail = server["argv"][1:]
    return {
        "running": True,
        "pid": pid,
        "argv": argv,
        "matches": argv[-len(tail) :] == tail,
    }


def local_address(host):
    if host in ("", "0.0.0.0"):
        return "127.0.0.1"
    if host == "::":
        return "[::1]"
    return f"[{host}]" if ":" in host else host


def _get(url):
    with urllib.request.urlopen(url, timeout=5) as response:
        return json.loads(response.read())


def served(server):
    base = f"http://{local_address(server['host'])}:{server['port']}"
    return {
        "version": _get(base + "/version").get("version"),
        "models": [
            {
                "id": m.get("id"),
                "root": m.get("root"),
                "max_model_len": m.get("max_model_len"),
            }
            for m in _get(base + "/v1/models").get("data") or []
        ],
    }


def server_report(config, args, hashes, found, server):
    resolved = attempt(model, config["hub_cache"], server, hashes)
    return server | {
        "gpus": attempt(allowed_gpus, found, server["gpus"]),
        "model": resolved,
        "chat_template": attempt(chat_template, server["chat_template"], resolved),
        "process": attempt(process, args.systemctl, server),
        "served": attempt(served, server),
    }


def report(config, args, hashes, names):
    found = attempt(gpus, args.nvidia_smi)
    return {
        "report": REPORT,
        "hostname": config["hostname"],
        "system": attempt(os.readlink, "/run/current-system"),
        "servers": {
            name: server_report(config, args, hashes, found, config["servers"][name])
            for name in names
        },
    }


def handler(config, args, hashes):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.partition("?")[0].rstrip("/")
            name = path.removeprefix("/servers/")
            if path == "":
                body = report(config, args, hashes, list(config["servers"]))
            elif path.startswith("/servers/") and name in config["servers"]:
                body = report(config, args, hashes, [name])
            else:
                self.send_error(404)
                return
            data = json.dumps(body, indent=2).encode() + b"\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def serve(config, args, hashes):
    def warm():
        for server in config["servers"].values():
            attempt(model, config["hub_cache"], server, hashes)

    threading.Thread(target=warm, daemon=True).start()

    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in args.listen else socket.AF_INET

    Server((args.listen, args.port), handler(config, args, hashes)).serve_forever()


def main():
    parser = argparse.ArgumentParser(
        description="Report what each vLLM server on this host runs."
    )
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--nvidia-smi", default="nvidia-smi")
    parser.add_argument("--systemctl", default="systemctl")
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, help="serve the report; else print it")
    parser.add_argument("servers", nargs="*", help="servers to print (default: all)")
    args = parser.parse_args()

    config = json.loads(args.config.read_text())
    hashes = Hashes(args.cache / "sha256.json" if args.cache else None)
    if args.port is not None:
        serve(config, args, hashes)
        return
    names = args.servers or list(config["servers"])
    if unknown := sorted(set(names) - set(config["servers"])):
        parser.error(f"no server {unknown}; there is {sorted(config['servers'])}")
    print(json.dumps(report(config, args, hashes, names), indent=2))


if __name__ == "__main__":
    main()
