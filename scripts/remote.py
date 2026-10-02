"""Verified SSH transport for SongNote maintenance; never stores credentials.

Install dependencies in build/deploy-tools. --json-session keeps the verified
connection open for multiple ps/put operations, accepting one JSON line per op.
"""
import argparse
import base64
import getpass
import json
import os
import posixpath
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "build" / "deploy-tools"))
import paramiko

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="124.220.229.9")
parser.add_argument("--user", default="Administrator")
parser.add_argument("--port", type=int, default=22)
parser.add_argument("--key")
parser.add_argument("--password-prompt", action="store_true")
parser.add_argument("--json-session", action="store_true")
args = parser.parse_args()
client = paramiko.SSHClient()
client.load_host_keys(str(Path.home() / ".ssh" / "known_hosts"))
client.set_missing_host_key_policy(paramiko.RejectPolicy())
password = getpass.getpass("SSH password: ") if args.password_prompt else os.environ.get("SONGNOTE_SSH_PASSWORD")
try:
    client.connect(args.host, port=args.port, username=args.user, password=password,
                   key_filename=args.key, look_for_keys=not bool(password),
                   allow_agent=not bool(password), timeout=15, auth_timeout=15, banner_timeout=15)
    password = None
    client.get_transport().set_keepalive(20)

    def powershell(script):
        preamble = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);\n"
        encoded = base64.b64encode((preamble + script).encode("utf-16le")).decode("ascii")
        _, stdout, stderr = client.exec_command("powershell -NoProfile -NonInteractive -EncodedCommand " + encoded, timeout=180)
        output = stdout.read().decode("utf-8-sig", errors="replace")
        error = stderr.read().decode("utf-8-sig", errors="replace")
        return {"exit_code": stdout.channel.recv_exit_status(), "output": output, "error": error}

    if args.json_session:
        print("SSH_SESSION_READY", flush=True)
        for line in sys.stdin:
            try:
                op = json.loads(line)
                if op["op"] == "exit": break
                if op["op"] == "ps":
                    result = powershell(op["script"])
                elif op["op"] == "put":
                    source = Path(op["source"]).resolve()
                    source.relative_to(ROOT)
                    target = posixpath.normpath(op["target"].replace("\\", "/"))
                    if not target.lower().startswith("c:/便签/"):
                        raise ValueError("Upload target must remain under C:/便签")
                    with client.open_sftp() as sftp:
                        folder = posixpath.dirname(target)
                        missing = []
                        while True:
                            try: sftp.stat(folder); break
                            except FileNotFoundError:
                                missing.append(folder); folder = posixpath.dirname(folder)
                        for folder in reversed(missing): sftp.mkdir(folder)
                        sftp.put(str(source), target)
                    result = {"exit_code": 0, "uploaded": target, "bytes": source.stat().st_size}
                else:
                    raise ValueError("Unknown operation")
            except Exception as exc:
                result = {"exit_code": 1, "error": type(exc).__name__ + ": " + str(exc)}
            print(json.dumps(result, ensure_ascii=True), flush=True)
    else:
        result = powershell(sys.stdin.read())
        print(result["output"], end="")
        print(result["error"], file=sys.stderr, end="")
        sys.exit(result["exit_code"])
finally:
    password = None
    client.close()
