import tempfile
import unittest
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from merge_dart_coverage import merge_reports, write_report


class MergeDartCoverageTest(unittest.TestCase):
    def _write(self, temp_dir, name, body):
        path = Path(temp_dir) / name
        path.write_text(body, encoding="utf-8")
        return path

    def test_takes_max_hit_count_for_lines_covered_by_both_shards(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            first = self._write(temp_dir, "a.info", "SF:lib/a.dart\nDA:1,3\nDA:2,0\nend_of_record\n")
            second = self._write(temp_dir, "b.info", "SF:lib/a.dart\nDA:1,1\nDA:2,2\nend_of_record\n")

            merged = merge_reports([first, second])

            self.assertEqual(merged, {"lib/a.dart": {1: 3, 2: 2}})

    def test_merges_disjoint_files_and_writes_sorted_output(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            first = self._write(temp_dir, "a.info", "SF:lib/b.dart\nDA:5,1\nend_of_record\n")
            second = self._write(temp_dir, "b.info", "SF:lib/a.dart\nDA:2,0\nDA:1,1\nend_of_record\n")
            output = Path(temp_dir) / "out" / "lcov.info"

            write_report(merge_reports([first, second]), output)

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "SF:lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n"
                "SF:lib/b.dart\nDA:5,1\nend_of_record\n",
            )

    def test_rejects_line_records_outside_a_source_block(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self._write(temp_dir, "a.info", "DA:1,1\n")

            with self.assertRaisesRegex(ValueError, "outside a source file"):
                merge_reports([path])

    def test_rejects_report_without_line_records(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "lcov.info"

            with self.assertRaisesRegex(ValueError, "line coverage records"):
                write_report({"lib/a.dart": {}}, output)


if __name__ == "__main__":
    unittest.main()
