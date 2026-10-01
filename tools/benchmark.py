#!/usr/bin/env python3
"""Run native Notebook benchmarks in disposable storage and compare JSON reports."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import shlex
import tarfile
import tempfile
from benchmark_report import compare_runs, regression_failures

ROOT = Path(__file__).resolve().parents[1]


def source_hash(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory)
        if not path.is_file() or "spec" in relative.parts:
            continue
        digest.update(relative.as_posix().encode() + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def fingerprints(source):
    return source_hash(source), hashlib.sha256((ROOT / "tools/bench-suite.lua").read_bytes()).hexdigest()


def read_result(completed, source, expected):
    if completed.returncode:
        raise RuntimeError(completed.stdout + completed.stderr)
    line = next((line for line in completed.stdout.splitlines()
                 if line.startswith("NOTEBOOK_BENCH_JSON=")), None)
    if line is None:
        raise RuntimeError("Benchmark returned no structured results: " + completed.stdout + completed.stderr)
    if fingerprints(source) != expected:
        raise RuntimeError("Sources or benchmark fixture changed during execution; rerun without concurrent edits")
    data = json.loads(line.split("=", 1)[1])
    data["source_sha256"], data["fixture_sha256"] = expected
    return data


def run(runtime, source, mode, scale, extended=False, case_filter=""):
    expected = fingerprints(source)
    with tempfile.TemporaryDirectory(prefix="notebook-benchmark-") as temporary:
        command = [str(runtime / "luajit"), str(ROOT / "tools/bench-suite.lua"),
                   str(source), temporary, mode, str(scale), "extended" if extended else "core", case_filter]
        completed = subprocess.run(command, cwd=runtime, env={**os.environ, "SDL_VIDEODRIVER": "dummy"},
                                   capture_output=True, text=True, timeout=900)
        return read_result(completed, source, expected)


def cleanup_remote(ssh, stage):
    # A disconnected device may leave temporary files; never replace the actual
    # benchmark/transfer exception with the cleanup exception.
    try:
        completed = subprocess.run(ssh + ["rm -rf -- " + shlex.quote(stage)],
                                   capture_output=True, timeout=30)
        if completed.returncode:
            print(f"Remote cleanup failed; disposable files may remain at {stage}", flush=True)
    except (OSError, subprocess.SubprocessError):
        print(f"Remote cleanup failed; disposable files may remain at {stage}", flush=True)


def save_report(report, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")


def previous_runs(path, report):
    previous = json.loads(path.read_text())
    if previous.get("complete") is False:
        raise ValueError("Cannot compare an incomplete benchmark report; rerun the missing profiles")
    if (previous["host"] != report["host"] or previous["runtime_directory"] != report["runtime_directory"]
            or previous.get("storage_root", "/tmp") != report["storage_root"]):
        raise ValueError("Cannot compare different hosts or runtime directories")
    return previous["runs"]


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
    parser.add_argument("--fail-wall-regression", type=float, help="Fail above this fractional wall-time regression")
    parser.add_argument("--fail-retained-kib", type=float, help="Fail above this increase in post-GC retained Lua heap (KiB)")
    args = parser.parse_args()
    limits = (args.fail_regression, args.fail_wall_regression, args.fail_retained_kib)
    for value in limits:
        if value is not None and (not math.isfinite(value) or value < 0):
            parser.error("Regression limits must be finite and non-negative")
    if args.baseline and args.compare:
        parser.error("--baseline and --compare are mutually exclusive")
    if any(value is not None for value in limits) and not (args.baseline or args.compare):
        parser.error("Regression limits require --baseline or --compare")
    modes = ["on", "off"] if args.jit == "both" else [args.jit]
    report = {"complete": False, "schema": 1, "host": platform.platform(), "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "storage_root": tempfile.gettempdir(), "runtime_directory": str(args.runtime.resolve()), "runs": [], "baseline": [], "comparison": [], "coverage": []}
    save_report(report, args.output)
    if args.ssh:
        ssh=["ssh","-p",str(args.port),"-o","BatchMode=yes","-o","ConnectTimeout=10",args.ssh]
        metadata=subprocess.run(ssh+["uname -a"],capture_output=True,text=True,check=True,timeout=20).stdout.strip()
        report["host"]=metadata
        report["runtime_directory"]=args.remote_runtime
        if not args.remote_work_root.startswith("/"):
            parser.error("--remote-work-root must be an absolute remote directory")
        report["storage_root"]=args.remote_work_root
        def remote_run(source, mode, extended=False):
            expected = fingerprints(source)
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
                return read_result(completed, source, expected)
            finally:
                cleanup_remote(ssh, stage)
        for mode in modes:
            print(f"Kindle offscreen benchmark: JIT {mode}, scale {args.scale}",flush=True)
            if args.baseline:
                report["baseline"].append(remote_run(args.baseline.resolve(),mode,args.baseline_extended))
                save_report(report, args.output)
            report["runs"].append(remote_run(args.source.resolve(),mode,args.extended))
            save_report(report, args.output)
        modes=[]
    for mode in modes:
        print(f"Native offscreen benchmark: JIT {mode}, scale {args.scale}", flush=True)
        if args.baseline:
            report["baseline"].append(run(args.runtime.resolve(), args.baseline.resolve(), mode, args.scale, args.baseline_extended, args.filter))
            save_report(report, args.output)
        report["runs"].append(run(args.runtime.resolve(), args.source.resolve(), mode, args.scale, args.extended, args.filter))
        save_report(report, args.output)
    if args.compare:
        report["baseline"] = previous_runs(args.compare, report)
    for current in report["runs"]:
        if not current["results"]:
            raise ValueError("No benchmark scenarios matched the filter")
        baseline = next((b for b in report["baseline"] if b["jit"] == current["jit"]), None)
        comparisons = []
        if baseline:
            comparisons, coverage = compare_runs(current, baseline)
            report["comparison"].extend(comparisons)
            report["coverage"].append(coverage)
            for side in ("missing_current", "missing_baseline"):
                if coverage[side]:
                    print(f"Coverage {current['jit']} {side}: " + ", ".join(coverage[side]))
        elif report["baseline"]:
            raise ValueError(f"Missing baseline for JIT {current['jit']}")
        indexed = {result["name"]: result for result in comparisons}
        for result in current["results"]:
            name, median = result["name"], result["cpu_ms"]["median"]
            suffix = ""
            if name in indexed:
                comparison = indexed[name]
                ratio = comparison["cpu_ratio"]
                suffix = f"  CPU ratio {ratio:.3f}x" if ratio is not None else "  CPU ratio unavailable (zero baseline)"
                if comparison["counter_differences"]:
                    suffix += " (result counters differ)"
                elif comparison["result_equivalent"] is None:
                    suffix += " (outcome unchecked)"
            print(f"{current['jit']:3} {name:29} CPU {median:9.3f} ms  p95 {result['cpu_ms']['p95']:9.3f}  "
                  f"wall {result['wall_ms']['median']:9.3f} ms  heap Δ {result['heap_delta_kib']['median']:9.1f} KiB{suffix}")
    report["complete"] = True
    save_report(report, args.output)
    print(f"Results: {args.output.resolve()}")
    if any(value is not None for value in limits):
        if not report["comparison"]:
            parser.error("Regression limits require overlapping benchmark cases")
        failures = regression_failures(report, *limits)
        if failures:
            raise SystemExit("Benchmark guardrail failures: " + ", ".join(failures))


if __name__ == "__main__":
    main()
