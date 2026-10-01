#!/usr/bin/env python3
"""Run native Notebook benchmarks in disposable storage and compare JSON reports."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import shlex
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def source_hash(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.glob("*.lua")):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def run(runtime, source, mode, scale, extended=False, case_filter=""):
    with tempfile.TemporaryDirectory(prefix="notebook-benchmark-") as temporary:
        command = [str(runtime / "luajit"), str(ROOT / "tools/bench-suite.lua"),
                   str(source), temporary, mode, str(scale), "extended" if extended else "core", case_filter]
        completed = subprocess.run(command, cwd=runtime, env={**os.environ, "SDL_VIDEODRIVER": "dummy"},
                                   capture_output=True, text=True, timeout=900)
        if completed.returncode:
            raise RuntimeError(completed.stdout + completed.stderr)
        line = next((line for line in completed.stdout.splitlines()
                     if line.startswith("NOTEBOOK_BENCH_JSON=")), None)
        if line is None:
            raise RuntimeError("Benchmark returned no structured results: " + completed.stdout)
        data = json.loads(line.split("=", 1)[1])
        data["source_sha256"] = source_hash(source)
        data["fixture_sha256"] = hashlib.sha256((ROOT/"tools/bench-suite.lua").read_bytes()).hexdigest()
        return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=ROOT.parent / "koreader-src/koreader-emulator-x86_64-pc-linux-gnu-debug/koreader")
    parser.add_argument("--source", type=Path, default=ROOT / "lua")
    parser.add_argument("--filter", default="", help="Run only matching scenario names")
    parser.add_argument("--extended", action="store_true", help="Include text, shapes, paper, PDF backgrounds, disk thumbnails and listing")
    parser.add_argument("--ssh", help="Run against a Kindle SSH target using isolated /tmp fixtures")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--remote-work-root",default="/tmp",help="Disposable fixture storage; use /mnt/us to measure real Kindle flash")
    parser.add_argument("--remote-runtime", default="/mnt/us/koreader")
    parser.add_argument("--baseline", type=Path, help="Compare a preserved Lua tree in the same runtime")
    parser.add_argument("--baseline-extended", action="store_true", help="Run extended cases on a compatible baseline too")
    parser.add_argument("--compare", type=Path, help="Compare a prior JSON run with matching runtime/fixtures")
    parser.add_argument("--jit", choices=["on", "off", "both"], default="both")
    parser.add_argument("--scale", type=int, choices=[1, 2, 4], default=1)
    parser.add_argument("--output", type=Path, default=ROOT / "build/benchmark.json")
    parser.add_argument("--fail-regression", type=float, help="Fail above this fractional CPU regression (e.g. 0.20)")
    args = parser.parse_args()
    modes = ["on", "off"] if args.jit == "both" else [args.jit]
    report = {"schema": 1, "host": platform.platform(), "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "storage_root": tempfile.gettempdir(), "runtime_directory": str(args.runtime.resolve()), "runs": [], "baseline": [], "comparison": []}
    if args.ssh:
        ssh=["ssh","-p",str(args.port),"-o","BatchMode=yes","-o","ConnectTimeout=10",args.ssh]
        metadata=subprocess.run(ssh+["uname -a"],capture_output=True,text=True,check=True,timeout=20).stdout.strip()
        report["host"]=metadata
        report["runtime_directory"]=args.remote_runtime
        if not args.remote_work_root.startswith("/"):
            parser.error("--remote-work-root must be an absolute remote directory")
        report["storage_root"]=args.remote_work_root
        def remote_run(source, mode, extended=False):
            prefix=args.remote_work_root.rstrip("/")+"/.notebook-benchmark."
            stage=subprocess.run(ssh+["mktemp -d "+shlex.quote(prefix+"XXXXXX")],capture_output=True,text=True,check=True,timeout=20).stdout.strip()
            if not stage.startswith(prefix) or any(c.isspace() for c in stage):
                raise RuntimeError("Unexpected remote temporary directory")
            try:
                with tempfile.TemporaryFile() as archive:
                    with tarfile.open(fileobj=archive,mode="w:gz") as tar:
                        tar.add(source,arcname="lua",filter=lambda info: None if "/spec" in info.name else info)
                        tar.add(ROOT/"tools/bench-suite.lua",arcname="bench-suite.lua")
                    archive.seek(0)
                    subprocess.run(ssh+["tar -xzf - -C "+shlex.quote(stage)],stdin=archive,check=True,timeout=90)
                command="cd "+shlex.quote(args.remote_runtime)+" && ./luajit "+shlex.join([
                    stage+"/bench-suite.lua",stage+"/lua",stage,mode,str(args.scale),"extended" if extended else "core",args.filter])
                completed=subprocess.run(ssh+[command],capture_output=True,text=True,timeout=900)
                if completed.returncode: raise RuntimeError(completed.stdout+completed.stderr)
                line=next((line for line in completed.stdout.splitlines() if line.startswith("NOTEBOOK_BENCH_JSON=")),None)
                if not line: raise RuntimeError(completed.stdout+completed.stderr)
                data=json.loads(line.split("=",1)[1]);data["source_sha256"]=source_hash(source)
                data["fixture_sha256"]=hashlib.sha256((ROOT/"tools/bench-suite.lua").read_bytes()).hexdigest()
                return data
            finally:
                subprocess.run(ssh+["rm -rf -- "+shlex.quote(stage)],check=True,timeout=30)
        for mode in modes:
            print(f"Kindle offscreen benchmark: JIT {mode}, scale {args.scale}",flush=True)
            if args.baseline: report["baseline"].append(remote_run(args.baseline.resolve(),mode,args.baseline_extended))
            report["runs"].append(remote_run(args.source.resolve(),mode,args.extended))
        modes=[]
    for mode in modes:
        print(f"Native offscreen benchmark: JIT {mode}, scale {args.scale}", flush=True)
        if args.baseline:
            report["baseline"].append(run(args.runtime.resolve(), args.baseline.resolve(), mode, args.scale, args.baseline_extended, args.filter))
        report["runs"].append(run(args.runtime.resolve(), args.source.resolve(), mode, args.scale, args.extended, args.filter))
    if args.compare:
        previous = json.loads(args.compare.read_text())
        if (previous["host"] != report["host"] or previous["runtime_directory"] != report["runtime_directory"]
                or previous.get("storage_root","/tmp") != report["storage_root"]):
            raise ValueError("Cannot compare different hosts or runtime directories")
        report["baseline"] = previous["runs"]
    for current in report["runs"]:
        baseline = next((b for b in report["baseline"] if b["jit"] == current["jit"]), None)
        if baseline:
            for key in ("arch", "scale", "runtime", "screen", "samples", "fixture_sha256"):
                if current[key] != baseline[key]:
                    raise ValueError(f"Incompatible benchmark metadata: {key}")
        old = {r["name"]: r for r in baseline["results"]} if baseline else {}
        for result in current["results"]:
            name, median = result["name"], result["cpu_ms"]["median"]
            suffix = ""
            if name in old:
                before = old[name]["cpu_ms"]["median"]
                ratio = median / before if before else 1
                suffix = f"  CPU ratio {ratio:.3f}x"
                report["comparison"].append({"jit": current["jit"], "name": name, "cpu_ratio": ratio,
                                             "before_cpu_ms": before, "after_cpu_ms": median,
                                             "before": old[name], "after": result})
            print(f"{current['jit']:3} {name:29} CPU {median:9.3f} ms  p95 {result['cpu_ms']['p95']:9.3f}  "
                  f"wall {result['wall_ms']['median']:9.3f} ms  heap Δ {result['heap_delta_kib']['median']:9.1f} KiB{suffix}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results: {args.output.resolve()}")
    if args.fail_regression is not None:
        if not report["comparison"]:
            parser.error("--fail-regression requires --baseline or --compare")
        failures = [r for r in report["comparison"] if r["before_cpu_ms"] >= 0.05 and r["cpu_ratio"] > 1 + args.fail_regression]
        if failures:
            raise SystemExit("CPU regression candidates: " + ", ".join(r["name"] + "/" + r["jit"] for r in failures))


if __name__ == "__main__":
    main()
