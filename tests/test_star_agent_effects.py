from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from star_agent import effects


class StarAgentEffectsTests(unittest.TestCase):
    def test_unknown_operations_never_execute(self):
        self.assertEqual(effects.execute("shell", {})["code"], "unknown_operation")

    def test_invalid_target_and_argument_types(self):
        self.assertEqual(
            effects.execute("osint_run", {"tool": "dns", "target": "-H evil"})["code"],
            "invalid_domain",
        )
        self.assertEqual(
            effects.execute("web_fetch", {"url": ["https://example.org"]})["code"],
            "invalid_argument",
        )

    def test_private_web_destinations_denied(self):
        for url in ("http://127.0.0.1:3000/", "http://10.0.0.1/", "file:///etc/passwd"):
            with self.subTest(url=url):
                with self.assertRaises(effects.EffectError):
                    effects.public_url(url)

    def test_missing_search_configuration_is_explicit(self):
        with patch.dict(os.environ, {"STAR_AGENT_SEARXNG_URL": ""}):
            self.assertEqual(
                effects.execute("web_search", {"query": "local fixtures"})["code"],
                "not_configured",
            )

    def test_html_web_fetch_extracts_text_without_script(self):
        html_page = (
            b"<html><head><title>Example Title</title></head><body>"
            b"<h1>Visible</h1><script>SECRET SCRIPT</script>"
            b"<a href='/next'>Go</a></body></html>"
        )
        with patch.object(effects, "fetch_bytes",
                          return_value=(html_page, "text/html", "https://example.org/")):
            got = effects.web_fetch({"url": "https://example.org/"})
        self.assertIn("Visible", got["text"])
        self.assertNotIn("SECRET SCRIPT", got["text"])
        self.assertIn("https://example.org/next", got["links"])

    def test_explore_stays_same_origin_and_bounded(self):
        pages = {
            "https://example.org/": {
                "url": "https://example.org/",
                "text": "root",
                "links": ["https://example.org/a", "https://other.example.net/secret"],
            },
            "https://example.org/a": {
                "url": "https://example.org/a", "text": "child", "links": [],
            },
        }
        with patch.object(effects, "web_fetch", side_effect=lambda a: pages[a["url"]]):
            got = effects.web_explore({"url": "https://example.org/"})
        self.assertEqual(len(got["pages"]), 2)
        self.assertEqual(got["scope"], "same-origin-depth-1")

    def test_manifests_reject_forged_executable(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "actors.ndjson"
            path.write_text(json.dumps({
                "extensions": {"starintel.actor_manifest.v1": {
                    "actor_id": "reddit", "service_mode": "continuous-target",
                    "cli": {"command": ["/bin/sh", "-c", "danger"]},
                }},
            }), encoding="utf-8")
            with patch.dict(os.environ, {"STAR_AGENT_ACTOR_MANIFEST_FILE": str(path)}):
                self.assertEqual(effects.execute("actors", {})["code"], "invalid_manifest")

    def test_target_creation_invokes_exact_manifest_binary_and_idempotency(self):
        record = {"extensions": {"starintel.actor_manifest.v1": {
            "actor_id": "reddit",
            "service_mode": "continuous-target",
            "cli": {"command": ["sa-reddit"]},
        }}}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "actors.ndjson"
            path.write_text(json.dumps(record) + "\n", encoding="utf-8")
            with patch.dict(os.environ, {
                "STAR_AGENT_ACTOR_MANIFEST_FILE": str(path),
                "STAR_AGENT_SERVER_URL": "http://127.0.0.1:5000",
            }):
                with patch.object(effects.shutil, "which", return_value="/usr/bin/sa-reddit"):
                    with patch.object(effects.subprocess, "run",
                                      return_value=SimpleNamespace(
                                          returncode=0, stdout='{"accepted":true}', stderr="",
                                      )) as process:
                        output = effects.target_create({
                            "actor": "reddit", "target": "r/example",
                            "dataset": "demo",
                        })
                        args, kwargs = process.call_args
        self.assertEqual(output["status"], "submitted_not_completed")
        self.assertEqual(args[0][:4], ["/usr/bin/sa-reddit", "r/example", "--dataset", "demo"])
        self.assertNotIn("shell", kwargs)
        self.assertIn("--idempotency-key", args[0])

    def test_osint_argv_not_interpolated(self):
        with patch.dict(os.environ, {"STAR_AGENT_OSINT_TOOLS": "dns"}):
            with patch.object(effects.shutil, "which", return_value="/usr/bin/dig"):
                with patch.object(
                    effects.subprocess, "run",
                    return_value=SimpleNamespace(returncode=0, stdout="203.0.113.1\n", stderr=""),
                ) as process:
                    output = effects.osint_run({"tool": "dns", "target": "example.org"})
        self.assertEqual(output["stdout"], "203.0.113.1\n")
        self.assertEqual(process.call_args.args[0],
                         ["/usr/bin/dig", "+short", "example.org"])
        self.assertEqual(effects.execute("osint_run", {
            "tool": "dns", "target": "example.org; echo bad",
        })["code"], "invalid_domain")


if __name__ == "__main__":
    unittest.main()
