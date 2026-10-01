#!/usr/bin/env python3
"""Compare production pixels/PNG with a baseline, locally or on an SSH Kindle."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ("check-scaled-render.lua", "check-preview-cache.lua")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--source", type=Path, default=ROOT / "lua")
    parser.add_argument("--runtime", type=Path, default=ROOT.parent / "koreader-src/koreader-emulator-x86_64-pc-linux-gnu-debug/koreader")
    parser.add_argument("--ssh")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--remote-runtime", default="/mnt/us/koreader")
    parser.add_argument("--output", type=Path, default=ROOT / "build/native-optimization-checks.txt")
    args = parser.parse_args()
    logs = []
    if args.ssh:
        ssh = ["ssh", "-p", str(args.port), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", args.ssh]
        stage = subprocess.run(ssh + ["mktemp -d /tmp/.notebook-native.XXXXXX"], check=True,
                               capture_output=True, text=True, timeout=20).stdout.strip()
        if not stage.startswith("/tmp/.notebook-native.") or any(c.isspace() for c in stage):
            raise RuntimeError("Unexpected remote staging path")
        try:
            with tempfile.TemporaryFile() as archive:
                with tarfile.open(fileobj=archive, mode="w:gz") as tar:
                    for source, name in ((args.source, "current"), (args.baseline, "baseline")):
                        tar.add(source.resolve(), arcname=name,
                                filter=lambda info: None if "/spec" in info.name else info)
                    for script in SCRIPTS:
                        tar.add(ROOT / "tools" / script, arcname=script)
                archive.seek(0)
                subprocess.run(ssh + ["tar -xzf - -C " + shlex.quote(stage)], stdin=archive, check=True, timeout=90)
            for i, script in enumerate(SCRIPTS):
                temporary = stage + "/case-" + str(i)
                subprocess.run(ssh + ["mkdir " + shlex.quote(temporary)], check=True, timeout=20)
                command = "cd " + shlex.quote(args.remote_runtime) + " && " + shlex.join([
                    "./luajit", stage + "/" + script, stage + "/current", stage + "/baseline", temporary])
                result = subprocess.run(ssh + [command], capture_output=True, text=True, timeout=180)
                logs.append(result.stdout + result.stderr)
                if result.returncode:
                    raise RuntimeError(logs[-1])
                print(next(line for line in result.stdout.splitlines() if "comparisons passed" in line), flush=True)
        finally:
            subprocess.run(ssh + ["rm -rf -- " + shlex.quote(stage)], check=True, timeout=30)
    else:
        for script in SCRIPTS:
            with tempfile.TemporaryDirectory(prefix="notebook-native-") as temporary:
                result = subprocess.run([str(args.runtime.resolve() / "luajit"), str(ROOT / "tools" / script),
                                         str(args.source.resolve()), str(args.baseline.resolve()), temporary],
                                        cwd=args.runtime, env={**os.environ, "SDL_VIDEODRIVER": "dummy"},
                                        capture_output=True, text=True, timeout=180)
                logs.append(result.stdout + result.stderr)
                if result.returncode:
                    raise RuntimeError(logs[-1])
                print(next(line for line in result.stdout.splitlines() if "comparisons passed" in line), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(logs))


if __name__ == "__main__":
    main()
