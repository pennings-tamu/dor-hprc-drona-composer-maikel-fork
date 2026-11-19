"""Tests for runtime_support/schedulers/slurm/scheduler.py and the scheduler/path loaders.

Run from the repository root:  python3 -m unittest tests.test_slurm_scheduler
"""
import os
import sys
import unittest
from unittest import mock

RUNTIME = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "runtime_support")
sys.path.insert(0, RUNTIME)

import drona_runtime_paths  # noqa: E402
import drona_scheduler  # noqa: E402

slurm = drona_scheduler.load("scheduler", "slurm")


class SlurmSchedulerTest(unittest.TestCase):
    def test_job_states_squeue_then_sacct_and_failures_are_soft(self):
        rows = {"squeue": [["111", "RUNNING", "1:00", "2"]],
                "sacct": [["222", "CANCELLED by 5", "0:10", "1"]]}
        with mock.patch.object(slurm, "_query", side_effect=lambda cmd: rows[cmd[0]]):
            states = slurm.job_states(["111", "222"])
        self.assertEqual(states["111"]["state"], "RUNNING")
        self.assertEqual(states["222"], {"state": "CANCELLED", "elapsed": "0:10", "nodes": "1"})
        with mock.patch.object(slurm.subprocess, "run", side_effect=OSError):
            self.assertEqual(slurm.job_states(["111"]), {})
        self.assertEqual(slurm.job_states([]), {})

    def test_parse_submit_output(self):
        self.assertEqual(slurm.parse_submit_output("Submitted batch job 12345\n"), "12345")
        self.assertIsNone(slurm.parse_submit_output("sbatch: error: invalid partition"))
        self.assertIsNone(slurm.parse_submit_output(None))

    def test_job_ids_and_cancel_command(self):
        self.assertTrue(slurm.is_job_id("123"))
        self.assertTrue(slurm.is_job_id("123_4"))
        self.assertFalse(slurm.is_job_id("123; rm -rf /"))
        self.assertEqual(slurm.base_job_id("123_4"), "123")
        self.assertIn("scancel 1 2", slurm.cancel_command(["1", "2"]))


class LoaderTest(unittest.TestCase):
    def test_default_scheduler_is_slurm_and_invalid_names_fall_back(self):
        with mock.patch.dict(os.environ, {"DRONA_SCHEDULER": ""}):
            self.assertEqual(drona_runtime_paths.scheduler_name(), "slurm")
        with mock.patch.dict(os.environ, {"DRONA_SCHEDULER": "../x"}):
            self.assertEqual(drona_runtime_paths.scheduler_name(), "slurm")

    def test_unknown_scheduler_module_is_an_import_error(self):
        with self.assertRaises(ImportError):
            drona_scheduler.load("scheduler", "nosuchscheduler")
        with self.assertRaises(ValueError):
            drona_scheduler.load("../scheduler", "slurm")

    def test_find_retriever_search_order(self):
        self.assertEqual(drona_runtime_paths.find_retriever("drona_slurm_seff.sh"),
                         os.path.join(RUNTIME, "schedulers", "slurm", "retrievers", "drona_slurm_seff.sh"))
        self.assertEqual(drona_runtime_paths.find_retriever("drona_cpu_chart_data.sh"),
                         os.path.join(RUNTIME, "retrievers", "drona_cpu_chart_data.sh"))
        self.assertIsNone(drona_runtime_paths.find_retriever("../app.py"))
        self.assertIsNone(drona_runtime_paths.find_retriever("nope.sh"))

    def test_old_paths_are_gone(self):
        # Removed at environment API 2.1: no aliases, no legacy/, no driver_scripts/ symlink
        for old in ("aliases.json", "legacy", "driver_scripts", "form_components", "map_references",
                    "retriever_scripts", "html_templates"):
            self.assertFalse(os.path.exists(os.path.join(RUNTIME, old)), old)
        self.assertIsNone(drona_runtime_paths.find_retriever("drona_slurm_cgroups.sh"))


if __name__ == "__main__":
    unittest.main()
