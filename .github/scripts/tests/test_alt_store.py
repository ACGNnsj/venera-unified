import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("alt_store", ROOT / "update_alt_store.py")
alt_store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alt_store)


class AltStoreTest(unittest.TestCase):
    def test_update_removes_upstream_history_and_preserves_own_releases(self):
        own = "https://github.com/ACGNnsj/venera-unified/releases/download/v1.8.0/VeneraUnified-ios-1.8.0+1.ipa"
        upstream = "https://github.com/CyrilPeng/Venera-Next/releases/download/v1.6.3/VeneraNext-ios-1.6.3+243.ipa"
        data = {"apps": [{"bundleIdentifier": "io.github.venera.unified",
                          "versions": [{"version": "1.8.0", "downloadURL": own},
                                       {"version": "1.6.3", "downloadURL": upstream}]}],
                "news": [{"url": own}, {"url": upstream}]}
        release = {"tag_name": "v2.0.0", "published_at": "2026-09-28T00:00:00Z",
                   "assets": [{"name": "VeneraUnified-ios-2.0.0+42.ipa", "size": 123,
                               "browser_download_url": "https://github.com/ACGNnsj/venera-unified/releases/download/v2.0.0/VeneraUnified-ios-2.0.0+42.ipa"}]}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "source.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            alt_store.update_json_file_release(path, release)
            alt_store.update_json_file_release(path, release)
            updated = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual([x["version"] for x in updated["apps"][0]["versions"]],
                             ["2.0.0", "1.8.0"])
            self.assertEqual(len(updated["news"]), 2)
            self.assertEqual(updated["apps"][0]["versions"][0]["buildVersion"], "42")
            release["assets"][0]["name"] = "VeneraNext-ios-2.0.0.ipa"
            alt_store.update_json_file_release(path, release)
            updated = json.loads(path.read_text(encoding="utf-8"))
            self.assertNotIn("buildVersion", updated["apps"][0]["versions"][0])

    def test_version_requires_a_complete_stable_tag(self):
        for tag in ("v2.0.0", "2.0.0"):
            self.assertEqual(alt_store.extract_version(tag), "2.0.0")
        for tag in ("v2.0.0-beta.1", "prefix2.0.0", "v2.0.0+42", "v2.0.0\n"):
            with self.subTest(tag=tag), self.assertRaises(RuntimeError):
                alt_store.extract_version(tag)

    def test_ipa_selection_requires_one_exact_version_match(self):
        valid = {"name": "VeneraUnified-ios-2.0.0+42.ipa"}
        for name in ("VeneraNext-ios-2.0.0.ipa", "veneraunified-ios-2.0.0+42.ipa"):
            asset = {"name": name}
            self.assertIs(alt_store.find_ipa_asset([asset], "2.0.0"), asset)
        for assets in ([], [{"name": "other.ipa"}],
                       [{"name": "VeneraUnified-ios-12.0.0.ipa"}],
                       [{"name": "VeneraUnified-ios-2.0.0-beta.ipa"}],
                       [{"name": valid["name"] + "\n"}], [valid, dict(valid)]):
            with self.subTest(assets=assets), self.assertRaises(RuntimeError):
                alt_store.find_ipa_asset(assets, "2.0.0")

    def test_invalid_metadata_does_not_rewrite_feed(self):
        release = {"tag_name": "v2.0.0", "published_at": "2026-09-28T00:00:00Z",
                   "assets": [{"name": "VeneraUnified-ios-2.0.0+42.ipa",
                               "browser_download_url": "https://github.com/ACGNnsj/venera-unified/releases/download/v2.0.0/app.ipa"}]}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "source.json"
            original = (ROOT / "alt_store.json").read_bytes()
            path.write_bytes(original)
            for size in (None, 0, -1, True, "123", 1.5):
                release["assets"][0]["size"] = size
                with self.subTest(size=size), self.assertRaises(RuntimeError):
                    alt_store.update_json_file_release(path, release)
                self.assertEqual(path.read_bytes(), original)

    def test_rejects_foreign_and_lookalike_urls(self):
        for url in ("https://github.com/venera-app/venera/releases/download/a.ipa",
                    "https://github.com.evil.test/CyrilPeng/venera-next/releases/a",
                    "https://github.com/CyrilPeng/venera-next-other/releases/a"):
            self.assertFalse(alt_store.is_project_release_url(url))

    def test_checked_in_source_only_distributes_project_releases(self):
        data = json.loads((ROOT / "alt_store.json").read_text(encoding="utf-8"))
        for app in data["apps"]:
            for entry in app["versions"]:
                self.assertTrue(alt_store.is_project_release_url(entry["downloadURL"]))
        for entry in data["news"]:
            self.assertTrue(alt_store.is_project_release_url(entry["url"]))
