import copy
import unittest
import json
import subprocess
from unittest.mock import patch
import tempfile
from pathlib import Path
from types import SimpleNamespace
from benchmark import fingerprints, read_result, cleanup_remote, save_report, previous_runs
from benchmark_report import compare_runs, regression_failures


def run(results):
    return dict(arch="x64", scale=1, runtime="LuaJIT", screen={}, samples=9,
                fixture_sha256="fixture", jit="on", results=results)


def result(name="erase", cpu=1, **counters):
    return dict(name=name, cpu_ms={"median": cpu}, counters=counters)


class ComparisonTests(unittest.TestCase):
    def test_fragment_change_cannot_pass_even_when_faster(self):
        comparisons, coverage = compare_runs(run([result(cpu=.5, strokes=3, contours=4)]),
                                            run([result(strokes=3, contours=5)]))
        self.assertFalse(comparisons[0]["result_equivalent"])
        self.assertTrue(regression_failures(dict(comparison=comparisons, coverage=[coverage]), .2))

    def test_unchecked_outcome_still_checks_cpu(self):
        comparisons, coverage = compare_runs(run([result(cpu=2)]), run([result()]))
        self.assertIsNone(comparisons[0]["result_equivalent"])
        self.assertEqual(regression_failures(dict(comparison=comparisons, coverage=[coverage]), .2), ["CPU:erase/on"])

    def test_missing_cases_fail_guardrail(self):
        comparisons, coverage = compare_runs(run([result("new")]), run([result("old")]))
        self.assertEqual(coverage["missing_current"], ["old"])
        self.assertEqual(len(regression_failures(dict(comparison=comparisons, coverage=[coverage]), .2)), 2)

    def test_zero_baseline_is_not_fabricated_as_one(self):
        comparisons, _ = compare_runs(run([result(cpu=2)]), run([result(cpu=0)]))
        self.assertIsNone(comparisons[0]["cpu_ratio"])

    def test_observation_counts_can_change(self):
        comparisons, _ = compare_runs(run([result(hits=3, draw_calls_total=1)]),
                                      run([result(hits=3, draw_calls_total=10)]))
        self.assertTrue(comparisons[0]["result_equivalent"])

    def test_metadata_and_duplicate_names_rejected(self):
        baseline = run([result()])
        changed = copy.deepcopy(baseline)
        changed["fixture_sha256"] = "other"
        with self.assertRaises(ValueError): compare_runs(changed, baseline)
        with self.assertRaises(ValueError): compare_runs(run([result(), result()]), baseline)

    def test_cpu_gain_cannot_hide_wall_or_retained_cost(self):
        before, after = result(cpu=2), result(cpu=1)
        before.update(wall_ms={"median": 2}, retained_kib={"median": 10})
        after.update(wall_ms={"median": 4}, retained_kib={"median": 100})
        comparisons, coverage = compare_runs(run([after]), run([before]))
        failures = regression_failures(dict(comparison=comparisons, coverage=[coverage]), .2, .2, 50)
        self.assertEqual(failures, ["wall:erase/on", "retained-heap:erase/on"])

    def test_execution_fingerprint_rejects_concurrent_edit(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            module = source / "module.lua"
            module.write_text("return {}")
            expected = fingerprints(source)
            completed = SimpleNamespace(returncode=0, stdout='NOTEBOOK_BENCH_JSON={"results":[]}\n', stderr="")
            self.assertEqual(read_result(completed, source, expected)["source_sha256"], expected[0])
            module.write_text("return {changed=true}")
            with self.assertRaises(RuntimeError): read_result(completed, source, expected)

    def test_missing_result_preserves_diagnostics(self):
        completed = SimpleNamespace(returncode=0, stdout="startup output", stderr="case diagnostics")
        with self.assertRaisesRegex(RuntimeError, "case diagnostics"):
            read_result(completed, Path("."), ("", ""))

    def test_execution_settings_must_match(self):
        for key, value in (("iterations", 20), ("warmups", 2),
                           ("jit_active_before", False), ("jit_active_after", False)):
            before, after = result(), result()
            before.update(iterations=1, warmups=1, jit_active_before=True, jit_active_after=True)
            after.update(before)
            after[key] = value
            with self.assertRaisesRegex(ValueError, key):
                compare_runs(run([after]), run([before]))

    def test_nonfinite_retained_cannot_pass_guardrail(self):
        for value in (float("nan"), float("inf"), -float("inf")):
            before, after = result(), result()
            before["retained_kib"] = {"median": 0}
            after["retained_kib"] = {"median": value}
            with self.assertRaises(ValueError):
                compare_runs(run([after]), run([before]))

    def test_jit_and_device_dimensions_must_match(self):
        baseline = run([result()])
        for key, value in (("jit", "off"), ("device_screen", {"width": 1860, "height": 2480})):
            changed = copy.deepcopy(baseline)
            changed[key] = value
            with self.assertRaisesRegex(ValueError, key):
                compare_runs(changed, baseline)

    def test_source_fingerprint_includes_assets_but_excludes_specs(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / "module.lua").write_text("return {}")
            (source / "icons").mkdir()
            icon = source / "icons/test.svg"
            icon.write_text("one")
            first = fingerprints(source)
            (source / "spec").mkdir()
            (source / "spec/test.lua").write_text("return true")
            self.assertEqual(first, fingerprints(source))
            icon.write_text("two")
            self.assertNotEqual(first, fingerprints(source))

    def test_remote_cleanup_preserves_the_original_failure(self):
        with patch("benchmark.subprocess.run", side_effect=subprocess.TimeoutExpired("ssh", 30)), patch("builtins.print") as output:
            cleanup_remote(["ssh", "kindle"], "/tmp/test")
            self.assertIn("/tmp/test", output.call_args.args[0])
        with patch("benchmark.subprocess.run", return_value=SimpleNamespace(returncode=255)), patch("builtins.print") as output:
            cleanup_remote(["ssh", "kindle"], "/tmp/test")
            output.assert_called_once()

    def test_partial_reports_are_saved_but_not_comparable(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested/report.json"
            report = dict(complete=False, host="host", runtime_directory="runtime", storage_root="/tmp", runs=[run([result()])])
            save_report(report, path)
            self.assertEqual(json.loads(path.read_text())["runs"], report["runs"])
            with self.assertRaisesRegex(ValueError, "incomplete"):
                previous_runs(path, report)
            report["complete"] = True
            save_report(report, path)
            self.assertEqual(previous_runs(path, report), report["runs"])

    def test_invalid_timings_rejected(self):
        for value in (-1, float("nan"), float("inf")):
            with self.assertRaises(ValueError): compare_runs(run([result(cpu=value)]), run([result()]))


if __name__ == "__main__":
    unittest.main()
