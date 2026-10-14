#!/usr/bin/env python3
"""Host-side QGA driver with durable guest-side command results."""
import base64
import hashlib
import json
import os
import secrets
import shlex
import subprocess
import sys
import time

class QGAError(RuntimeError):
    pass

def request(domain, payload, retries=5):
    for attempt in range(retries):
        try:
            r = subprocess.run(
                ["virsh", "-c", "qemu:///system", "qemu-agent-command",
                 domain, json.dumps(payload), "--timeout", "10"],
                capture_output=True, text=True, timeout=20)
            if r.returncode:
                raise QGAError(f"{payload['execute']}: {r.stderr.strip() or r.stdout.strip()}")
            response = json.loads(r.stdout)
            if "error" in response:
                raise QGAError(str(response["error"]))
            return response["return"]
        except (QGAError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
            if attempt == retries - 1:
                raise QGAError(str(exc)) from exc
            time.sleep(min(2 ** attempt, 8))

def run(domain, cmd, user=None, key=None):
    identity = (user or "root") + "\0" + (key or "") + "\0" + cmd
    tag = hashlib.sha256(identity.encode()).hexdigest()[:32] if key else secrets.token_hex(16)
    path = "/var/tmp/gnosislab-qga-" + (user or "root") + "-" + tag
    quoted = shlex.quote(path)
    # The lock and marker guard against duplicate execution after lost RPC replies.
    # A lost PID is not evidence that the command finished.
    inner = (
        f"umask 077; mkdir -p {quoted}; "
        f"( flock -x 9; "
        f"if test -f {quoted}.rc; then exit 0; fi; "
        f"if test -f {quoted}.started; then exit 96; fi; "
        f"touch {quoted}.started; "
        f"/bin/sh -c {shlex.quote(cmd)} > {quoted}.log 2>&1; "
        f"rc=$?; printf '%s\\n' \"$rc\" > {quoted}.rc.tmp; "
        f"mv {quoted}.rc.tmp {quoted}.rc "
        f") 9>{quoted}.lock")
    exe, args = ("/bin/su", ["-", user, "-c", inner]) if user else ("/bin/sh", ["-c", inner])
    request(domain, {"execute":"guest-exec",
                     "arguments":{"path":exe,"arg":args,"capture-output":False}})
    offset = 0
    last_ok = time.monotonic()
    start = last_ok
    timeout = int(os.environ.get("QGA_EXEC_TIMEOUT", "7200"))
    outage = int(os.environ.get("QGA_OUTAGE_TIMEOUT", "300"))
    while time.monotonic() - start < timeout:
        try:
            # Use guest-file APIs rather than launching one extra process per poll.
            for kind in ("log", "rc"):
                file_path = path + "." + kind
                try:
                    handle = request(domain, {"execute":"guest-file-open",
                                               "arguments":{"path":file_path,"mode":"r"}}, 1)
                except QGAError as exc:
                    if any(s in str(exc).lower() for s in ("no such file", "not found", "enoent")):
                        continue
                    raise
                try:
                    if kind == "log" and offset:
                        request(domain, {"execute":"guest-file-seek",
                                         "arguments":{"handle":handle,"offset":offset,"whence":0}}, 1)
                    result = request(domain, {"execute":"guest-file-read",
                                              "arguments":{"handle":handle,"count":65536}}, 1)
                    data = base64.b64decode(result.get("buf-b64", "") or "")
                finally:
                    try:
                        request(domain, {"execute":"guest-file-close",
                                         "arguments":{"handle":handle}}, 1)
                    except QGAError:
                        pass
                if kind == "log":
                    while data:
                        sys.stdout.buffer.write(data)
                        sys.stdout.buffer.flush()
                        offset += len(data)
                        if len(data) < 65536:
                            break
                        handle = request(domain, {"execute":"guest-file-open",
                                                   "arguments":{"path":file_path,"mode":"r"}}, 1)
                        try:
                            request(domain, {"execute":"guest-file-seek",
                                             "arguments":{"handle":handle,"offset":offset,"whence":0}}, 1)
                            data = base64.b64decode(request(domain, {"execute":"guest-file-read",
                                             "arguments":{"handle":handle,"count":65536}}, 1).get("buf-b64","") or "")
                        finally:
                            request(domain, {"execute":"guest-file-close",
                                             "arguments":{"handle":handle}}, 1)
                else:
                    return int(data.strip())
            last_ok = time.monotonic()
        except QGAError as exc:
            if time.monotonic() - last_ok > outage:
                raise QGAError(f"agent unavailable for {outage}s; guest job {path} "
                               f"may still be running. Last error: {exc}") from exc
        time.sleep(2)
    raise QGAError(f"guest job {path} exceeded {timeout}s; state unknown; do not duplicate")

def push(domain, local, remote):
    for attempt in range(3):
        h = None
        try:
            h = request(domain, {"execute":"guest-file-open",
                                 "arguments":{"path":remote,"mode":"w+"}})
            with open(local, "rb") as stream:
                while block := stream.read(48 * 1024):
                    while block:
                        res = request(domain, {"execute":"guest-file-write",
                            "arguments":{"handle":h,"buf-b64":base64.b64encode(block).decode()}}, 1)
                        count = res.get("count", 0)
                        if not isinstance(count, int) or count < 1 or count > len(block):
                            raise QGAError("guest-file-write returned invalid byte count")
                        block = block[count:]
            request(domain, {"execute":"guest-file-close","arguments":{"handle":h}}, 1)
            h = None
            print(f"pushed {local} -> {remote}")
            return
        except QGAError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
        finally:
            if h is not None:
                try:
                    request(domain, {"execute":"guest-file-close","arguments":{"handle":h}}, 1)
                except QGAError:
                    pass

def main(argv):
    domain, mode, *args = argv
    if mode == "ping":
        request(domain, {"execute":"guest-ping"})
        return 0
    if mode == "push":
        push(domain, *args)
        return 0
    if mode != "exec":
        raise ValueError("unknown QGA mode")
    user = key = None
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag not in ("--as", "--resume") or not args:
            raise ValueError("invalid QGA exec argument")
        if flag == "--as":
            user = args.pop(0)
        else:
            key = args.pop(0)
    return run(domain, " ".join(args), user, key)

if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (QGAError, OSError, ValueError, TypeError) as exc:
        print(f"qga: {exc}", file=sys.stderr)
        sys.exit(1)
