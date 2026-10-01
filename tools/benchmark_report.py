"""Comparison rules independent of execution, transport and report printing."""
import math

# These are workload/result counts, not proof of pixel or file equivalence.
# draw/blit counts are performance observations and may improve legitimately.
RESULT_COUNTERS = frozenset({"hits", "queries", "strokes", "points", "contours",
                            "pages", "selected_pages", "source_pages", "output_bytes"})


def compare_runs(current, baseline):
    for key in ("jit", "arch", "scale", "runtime", "screen", "samples", "fixture_sha256"):
        if current[key] != baseline[key]:
            raise ValueError(f"Incompatible benchmark metadata: {key}")
    if current.get("device_screen") != baseline.get("device_screen"):
        raise ValueError("Incompatible benchmark metadata: device_screen")
    for run in (current, baseline):
        names = [result["name"] for result in run["results"]]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate benchmark scenario names")
    old = {result["name"]: result for result in baseline["results"]}
    new = {result["name"]: result for result in current["results"]}
    coverage = {"jit": current["jit"], "missing_current": sorted(old.keys() - new.keys()),
                "missing_baseline": sorted(new.keys() - old.keys())}
    comparisons = []
    for name, after in new.items():
        if name not in old:
            continue
        before = old[name]
        for key in ("iterations", "warmups", "jit_active_before", "jit_active_after"):
            if before.get(key) != after.get(key):
                raise ValueError(f"Incompatible scenario settings: {name}/{key}")
        left, right = before.get("counters", {}), after.get("counters", {})
        checked = sorted(RESULT_COUNTERS & (left.keys() | right.keys()))
        differences = {key: {"before": left.get(key), "after": right.get(key)}
                       for key in checked if left.get(key) != right.get(key)}
        cpu_before, cpu_after = before["cpu_ms"]["median"], after["cpu_ms"]["median"]
        if any(not math.isfinite(value) or value < 0 for value in (cpu_before, cpu_after)):
            raise ValueError(f"Invalid CPU timing: {name}")
        extra = {}
        for metric in ("wall_ms", "explicit_gc_ms"):
            if metric in before and metric in after:
                old_value, new_value = before[metric]["median"], after[metric]["median"]
                if any(not math.isfinite(value) or value < 0 for value in (old_value, new_value)):
                    raise ValueError(f"Invalid {metric} timing: {name}")
                extra[metric + "_ratio"] = new_value / old_value if old_value else None
        if "retained_kib" in before and "retained_kib" in after:
            retained = (before["retained_kib"]["median"], after["retained_kib"]["median"])
            if any(not math.isfinite(value) for value in retained):
                raise ValueError(f"Invalid retained_kib: {name}")
            extra["retained_kib_increase"] = retained[1] - retained[0]
        comparisons.append({**extra,"jit": current["jit"], "name": name,
                            "cpu_ratio": cpu_after / cpu_before if cpu_before else None,
                            "before_cpu_ms": cpu_before, "after_cpu_ms": cpu_after,
                            "result_equivalent": not differences if checked else None,
                            "counter_differences": differences, "checked_counters": checked,
                            "before": before, "after": after})
    return comparisons, coverage


def regression_failures(report, threshold=None, wall_threshold=None, retained_limit=None):
    failures = []
    for coverage in report.get("coverage", []):
        for side in ("missing_current", "missing_baseline"):
            failures.extend(f"{side}:{name}/{coverage['jit']}" for name in coverage[side])
    for result in report["comparison"]:
        label = result["name"] + "/" + result["jit"]
        if result["counter_differences"]:
            failures.append("result-counters:" + label)
        elif (threshold is not None and result["before_cpu_ms"] >= 0.05 and result["cpu_ratio"] is not None
              and result["cpu_ratio"] > 1 + threshold):
            failures.append("CPU:" + label)
        if (wall_threshold is not None and result.get("wall_ms_ratio") is not None
                and result["before"]["wall_ms"]["median"] >= 0.05
                and result["wall_ms_ratio"] > 1 + wall_threshold):
            failures.append("wall:" + label)
        if retained_limit is not None and result.get("retained_kib_increase", 0) > retained_limit:
            failures.append("retained-heap:" + label)
    return failures
