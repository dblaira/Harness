#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("suite_regression.py")
SPEC = importlib.util.spec_from_file_location("suite_regression", SCRIPT)
assert SPEC and SPEC.loader
suite_regression = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(suite_regression)


class SuiteRegressionTests(unittest.TestCase):
    def test_committed_manifest_is_valid(self) -> None:
        manifest = suite_regression.load_manifest(SCRIPT.parent.parent / "Regression" / "suite-regression.json")
        self.assertEqual(manifest["suite_name"], "Understood Suite Regression Patrol")

    def valid_manifest(self) -> dict:
        return {
            "schema_version": 1,
            "suite_name": "fixture",
            "apps": [
                {
                    "id": "fixture",
                    "name": "Fixture",
                    "repo_url": "git@example.test:fixture.git",
                    "branch": "main",
                    "local_candidates": [],
                    "checks": [
                        {
                            "id": "test",
                            "name": "Test",
                            "kind": "command",
                            "profiles": ["smoke"],
                            "command": ["true"],
                        }
                    ],
                }
            ],
        }

    def test_manifest_rejects_unknown_authority_fields(self) -> None:
        manifest = self.valid_manifest()
        manifest["pretend_green"] = True
        with self.assertRaises(suite_regression.ManifestError):
            suite_regression.validate_manifest(manifest)

    def test_profile_layers_are_explicit(self) -> None:
        smoke = {"profiles": ["smoke"]}
        full = {"profiles": ["full"]}
        self.assertTrue(suite_regression.selected_for_profile(smoke, "stress"))
        self.assertTrue(suite_regression.selected_for_profile(full, "stress"))
        self.assertFalse(suite_regression.selected_for_profile(full, "smoke"))

    def test_missing_visible_test_is_never_green(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            status, detail = suite_regression.coverage_check(
                {
                    "kind": "path_glob",
                    "pattern": "**/*UITests/**/*.swift",
                    "coverage_requirement": "visible flow required",
                },
                Path(directory),
            )
        self.assertEqual(status, "GAP")
        self.assertEqual(detail, "visible flow required")
        self.assertEqual(
            suite_regression.overall_status([{"status": "INCOMPLETE", "checks": [{"status": "GAP"}]}]),
            "INCOMPLETE",
        )

    def test_failure_outranks_coverage_gap(self) -> None:
        result = [
            {
                "status": "FAIL",
                "checks": [{"status": "GAP"}, {"status": "FAIL"}],
            }
        ]
        self.assertEqual(suite_regression.overall_status(result), "FAIL")


if __name__ == "__main__":
    unittest.main()
