#!/usr/bin/env python3
"""Black-box protected-session CLI checks; synthetic canaries only, no network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

CANARY = "CV-CANARY-NEVER-PUBLIC-7f29"
DID = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"


def exchange(proc, request):
    line = proc.stdout.readline()
    if not line:
        raise AssertionError("Boris closed the broker channel before a request")
    value = json.loads(line)
    assert value["protocol"] == "boris-session-provider"
    assert value["version"] == 1
    for key, expected in request.items():
        assert value.get(key) == expected, (key, value)
    return value


def respond(proc, **fields):
    payload = dict(protocol="boris-session-provider", version=1, kind="response")
    payload.update(fields)
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()


def launch(binary, cwd, args):
    env = dict(os.environ)
    env["HOME"] = str(cwd / "home-that-must-not-be-used")
    return subprocess.Popen(
        [binary, *args, "--session-provider-stdio"],
        cwd=cwd,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def finish(proc):
    stderr = proc.stderr.read()
    code = proc.wait(timeout=10)
    assert CANARY not in stderr, stderr
    return code, stderr


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="boris-protected-session-") as raw:
        cwd = Path(raw)
        # Public listing stays off protocol stdout (Boris emits it on stderr).
        proc = launch(binary, cwd, ["standard-site", "sessions"])
        hello = exchange(proc, {"kind": "hello"})
        instance = hello["instance"]
        respond(proc, kind="hello", instance=instance)
        exchange(proc, {"kind": "request", "id": 1, "operation": "list", "did": None, "instance": instance})
        respond(proc, id=1, operation="list", did=None, instance=instance, status="ok", entries=[
            {"did": DID, "flavor": "app-password", "pds_origin": "https://pds.example.com"}
        ])
        code, stderr = finish(proc)
        assert code == 0, (code, stderr)
        assert DID in stderr

        # Logout is bound to the DID and creates no compatibility file store.
        proc = launch(binary, cwd, ["standard-site", "logout", "--did", DID])
        instance = exchange(proc, {"kind": "hello"})["instance"]
        respond(proc, kind="hello", instance=instance)
        exchange(proc, {"kind": "request", "id": 1, "operation": "remove", "did": DID, "instance": instance})
        respond(proc, id=1, operation="remove", did=DID, instance=instance, status="ok", removed=True, session=CANARY)
        code, _ = finish(proc)
        assert code == 0

        # Malformed secret-bearing broker data never reaches stderr or reports.
        proc = launch(binary, cwd, ["standard-site", "sessions"])
        instance = exchange(proc, {"kind": "hello"})["instance"]
        respond(proc, kind="hello", instance=instance)
        exchange(proc, {"kind": "request", "id": 1, "operation": "list", "instance": instance})
        respond(proc, id=1, operation="list", did=None, instance=instance, status="ok", entries=[], unexpected=CANARY)
        code, stderr = finish(proc)
        assert code == 9, (code, stderr)
        assert "malformed or mismatched" in stderr

        # The protected child receives no secret through argv or environment;
        # all synthetic secret material originates in this broker process.
        child_public_inputs = binary + " standard-site sessions logout " + DID + " " + os.environ.get("HOME", "")
        assert CANARY not in child_public_inputs
        files = [path for path in cwd.rglob("*") if path.is_file()]
        assert not files, files
        assert not (cwd / "home-that-must-not-be-used").exists()
    print("protected-session-provider: no files or public canary leakage")


if __name__ == "__main__":
    main()
