#!/usr/bin/env python3
"""Tests for log_collector.py (standard library unittest).

Run from the repository root::

    python3 -m unittest discover -s tools -p "test_*.py"
"""

import http.client
import json
import logging
import os
import sys
import tempfile
import threading
import unittest
from typing import Any, Dict, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import log_collector  # noqa: E402  (path set up above)

log_collector.LOG.setLevel(logging.CRITICAL)  # keep test output readable

TOKEN = "test-token-123"


def batch(entries: Any, computer_id: Any = 7, label: Any = "Reactors",
          dropped: Any = 0) -> Dict[str, Any]:
    """Build a payload like log_shipper.lua sends."""
    return {"computer_id": computer_id, "computer_label": label,
            "sent_at": 1700000000000, "dropped": dropped, "entries": entries}


class ServerTestCase(unittest.TestCase):
    """Starts a collector on an ephemeral port for each test."""

    max_request = 256 * 1024
    max_bytes = 1024 * 1024

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "logs")
        self.server = log_collector.make_server(
            "127.0.0.1", 0, self.root, TOKEN, max_bytes=self.max_bytes,
            backups=3, max_request=self.max_request)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        self.tmp.cleanup()

    def request(self, method: str, path: str, body: Optional[bytes] = None,
                token: Optional[str] = TOKEN,
                headers: Optional[Dict[str, str]] = None) -> Tuple[int, Dict[str, Any]]:
        """Send one request; return status and decoded JSON answer."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            all_headers = {"Content-Type": "application/json"}
            if token is not None:
                all_headers["Authorization"] = "Bearer " + token
            all_headers.update(headers or {})
            conn.request(method, path, body=body, headers=all_headers)
            response = conn.getresponse()
            return response.status, json.loads(response.read() or b"{}")
        finally:
            conn.close()

    def post(self, payload: Any, **kwargs: Any) -> Tuple[int, Dict[str, Any]]:
        """POST a payload to /ingest."""
        return self.request("POST", "/ingest", json.dumps(payload).encode("utf-8"), **kwargs)

    def read(self, *parts: str) -> bytes:
        """Return the raw contents of a file under the root."""
        with open(os.path.join(self.root, *parts), "rb") as handle:
            return handle.read()


class AuthTests(ServerTestCase):
    """Token handling."""

    def test_missing_token_is_rejected(self) -> None:
        status, answer = self.post(batch([{"file": "a.log", "line": "x"}]), token=None)
        self.assertEqual(status, 401)
        self.assertFalse(answer["ok"])
        self.assertFalse(os.path.exists(os.path.join(self.root, "computer-7-Reactors")))

    def test_wrong_token_is_rejected(self) -> None:
        status, _ = self.post(batch([{"file": "a.log", "line": "x"}]), token="nope")
        self.assertEqual(status, 401)

    def test_wrong_scheme_is_rejected(self) -> None:
        status, _ = self.post(batch([]), token=None,
                              headers={"Authorization": "Basic " + TOKEN})
        self.assertEqual(status, 401)

    def test_health_needs_no_token(self) -> None:
        status, answer = self.request("GET", "/health", token=None)
        self.assertEqual((status, answer), (200, {"ok": True}))

    def test_unknown_path(self) -> None:
        status, _ = self.request("POST", "/other", b"{}")
        self.assertEqual(status, 404)

    def test_server_refuses_empty_token(self) -> None:
        with self.assertRaises(ValueError):
            log_collector.make_server("127.0.0.1", 0, self.root, "")


class RequestValidationTests(ServerTestCase):
    """Malformed and oversized bodies."""

    def test_bad_json(self) -> None:
        status, answer = self.request("POST", "/ingest", b"{not json")
        self.assertEqual(status, 400)
        self.assertIn("JSON", answer["error"])

    def test_bad_shapes(self) -> None:
        cases = [
            [1, 2, 3],
            batch([], computer_id="7"),
            batch([], computer_id=-1),
            batch([], computer_id=True),
            batch([], computer_id=2 ** 40),
            batch([], label=5),
            batch([], dropped=-3),
            batch("entries"),
            batch(["line"]),
            batch([{"file": "a.log", "line": 5}]),
            batch([{"file": "a.log", "line": "x" * (log_collector.MAX_LINE_CHARS + 1)}]),
        ]
        for payload in cases:
            with self.subTest(payload=str(payload)[:80]):
                status, _ = self.post(payload)
                self.assertEqual(status, 400)

    def test_oversized_body(self) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.putrequest("POST", "/ingest")
            conn.putheader("Authorization", "Bearer " + TOKEN)
            conn.putheader("Content-Length", str(self.max_request + 1))
            conn.endheaders()
            response = conn.getresponse()
            self.assertEqual(response.status, 413)
        finally:
            conn.close()

    def test_length_required(self) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.putrequest("POST", "/ingest")
            conn.putheader("Authorization", "Bearer " + TOKEN)
            conn.endheaders()
            self.assertEqual(conn.getresponse().status, 411)
        finally:
            conn.close()


class SanitizationTests(ServerTestCase):
    """Path traversal and naming."""

    def test_traversal_file_names_are_rejected(self) -> None:
        bad = ["../escape.log", "..", "/etc/passwd", "a/b.log", "a\\b.log", ".hidden.log",
               "draconic.log.1", "x.sh", "", "C:evil.log", "nul\x00.log", "a" * 70 + ".log",
               "draconic.log/", "%2e%2e.log"]
        for name in bad:
            with self.subTest(name=name):
                status, _ = self.post(batch([{"file": name, "line": "pwned"}]))
                self.assertEqual(status, 400)
        found = []
        for _, _, files in os.walk(self.tmp.name):
            found.extend(files)
        self.assertEqual(found, [])

    def test_whole_batch_rejected_if_one_entry_is_bad(self) -> None:
        status, _ = self.post(batch([{"file": "ok.log", "line": "a"},
                                     {"file": "../x.log", "line": "b"}]))
        self.assertEqual(status, 400)
        self.assertFalse(os.path.exists(os.path.join(self.root, "computer-7-Reactors", "ok.log")))

    def test_label_is_sanitized(self) -> None:
        cases = {
            "../../etc": "computer-3-etc",
            "Main Reactor #1": "computer-3-Main_Reactor_1",
            "": "computer-3",
            "....": "computer-3",
            "/": "computer-3",
            "x" * 100: "computer-3-" + "x" * log_collector.MAX_LABEL_CHARS,
        }
        for label, folder in cases.items():
            with self.subTest(label=label):
                self.assertEqual(log_collector.computer_folder(3, label), folder)
        status, _ = self.post(batch([{"file": "a.log", "line": "hi"}], computer_id=3,
                                    label="../../etc"))
        self.assertEqual(status, 200)
        self.assertEqual(self.read("computer-3-etc", "a.log"), b"hi\n")
        self.assertEqual(sorted(os.listdir(self.tmp.name)), ["logs"])

    def test_symlinked_computer_folder_is_refused(self) -> None:
        outside = os.path.join(self.tmp.name, "outside")
        os.makedirs(outside)
        os.makedirs(self.root, exist_ok=True)
        os.symlink(outside, os.path.join(self.root, "computer-9"))
        status, _ = self.post(batch([{"file": "a.log", "line": "x"}], computer_id=9, label=""))
        self.assertEqual(status, 400)
        self.assertEqual(os.listdir(outside), [])


class StorageTests(unittest.TestCase):
    """LogStore rotation and CSV header handling, without HTTP."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.store = log_collector.LogStore(self.tmp.name, max_bytes=100, backups=2)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def path(self, name: str) -> str:
        """Path of a file in the test computer folder."""
        return os.path.join(self.tmp.name, "c", name)

    def content(self, name: str) -> bytes:
        """Raw file content."""
        with open(self.path(name), "rb") as handle:
            return handle.read()

    def test_size_rotation_keeps_n_backups(self) -> None:
        for index in range(12):
            self.store.append("c", "a.log", [("line %02d " % index + "x" * 30, False)])
        files = sorted(os.listdir(os.path.join(self.tmp.name, "c")))
        self.assertEqual(files, ["a.log", "a.log.1", "a.log.2"])
        for name in files:
            self.assertLessEqual(len(self.content(name)), 100)
        self.assertTrue(self.content("a.log").endswith(b"x" * 30 + b"\n"))
        self.assertIn(b"line 11", self.content("a.log"))
        self.assertIn(b"line 09", self.content("a.log.1"))

    def test_csv_header_written_once_and_after_rotation(self) -> None:
        header = "time,temp"
        self.store.append("c", "s.csv", [(header, True), ("1,7000", False)])
        self.store.append("c", "s.csv", [(header, True), ("2,7001", False)])
        self.assertEqual(self.content("s.csv"), b"time,temp\n1,7000\n2,7001\n")
        for index in range(20):
            self.store.append("c", "s.csv", [("%d,7000" % (index + 3), False)])
        self.assertTrue(os.path.exists(self.path("s.csv.1")))
        for name in ("s.csv", "s.csv.1"):
            self.assertTrue(self.content(name).startswith(b"time,temp\n"), name)
            self.assertEqual(self.content(name).count(b"time,temp"), 1, name)

    def test_csv_header_survives_collector_restart(self) -> None:
        self.store.append("c", "s.csv", [("time,temp", True), ("1,7000", False)])
        fresh = log_collector.LogStore(self.tmp.name, max_bytes=100, backups=2)
        fresh.append("c", "s.csv", [("time,temp", True), ("2,7000", False)])
        self.assertEqual(self.content("s.csv"), b"time,temp\n1,7000\n2,7000\n")

    def test_changed_csv_columns_start_a_new_file(self) -> None:
        self.store.append("c", "s.csv", [("time,temp", True), ("1,7000", False)])
        self.store.append("c", "s.csv", [("time,temp,field", True), ("2,7000,50", False)])
        self.assertEqual(self.content("s.csv"), b"time,temp,field\n2,7000,50\n")
        self.assertEqual(self.content("s.csv.1"), b"time,temp\n1,7000\n")

    def test_latin1_round_trip(self) -> None:
        self.store.append("c", "a.log", [("café ÿ", False), ("snow ☃", False)])
        self.assertEqual(self.content("a.log"), b"caf\xe9 \xff\nsnow \xe2\x98\x83\n")

    def test_zero_backups_truncates(self) -> None:
        store = log_collector.LogStore(self.tmp.name, max_bytes=20, backups=0)
        for index in range(5):
            store.append("c", "a.log", [("%d" % index + "y" * 10, False)])
        self.assertEqual(sorted(os.listdir(os.path.join(self.tmp.name, "c"))), ["a.log"])


class EndToEndTests(ServerTestCase):
    """A batch shaped exactly like log_shipper.lua's output."""

    def test_post_writes_files_per_computer(self) -> None:
        # CC:Tweaked's serializeJSON writes byte 0xE9 as é and keeps
        # key order arbitrary; build the body by hand to mirror that.
        body = (b'{"entries":[{"file":"draconic.log","line":"2024-01-01 [INFO] Starting v4.0"},'
                b'{"header":true,"file":"reactor_stats.csv","line":"time,temperature"},'
                b'{"file":"reactor_stats.csv","line":"2024-01-01,7000"},'
                b'{"file":"draconic.log","line":"caf\\u00E9 \\"quoted\\""}],'
                b'"computer_label":"Main Base","dropped":4,"sent_at":1700000000000,'
                b'"computer_id":12}')
        status, answer = self.request("POST", "/ingest", body)
        self.assertEqual(status, 200, answer)
        self.assertEqual(answer, {"ok": True, "written": 4})
        folder = "computer-12-Main_Base"
        self.assertEqual(self.read(folder, "draconic.log"),
                         b'2024-01-01 [INFO] Starting v4.0\ncaf\xe9 "quoted"\n')
        self.assertEqual(self.read(folder, "reactor_stats.csv"),
                         b"time,temperature\n2024-01-01,7000\n")
        # A second computer gets its own folder; concurrent posts are fine.
        threads = [threading.Thread(target=self.post, args=(
            batch([{"file": "draconic.log", "line": "c%d-%d" % (cid, n)} for n in range(50)],
                  computer_id=cid, label=""),)) for cid in range(20, 26)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        for cid in range(20, 26):
            lines = self.read("computer-%d" % cid, "draconic.log").splitlines()
            self.assertEqual(lines, [("c%d-%d" % (cid, n)).encode() for n in range(50)])

    def test_main_requires_token(self) -> None:
        env = os.environ.pop(log_collector.TOKEN_ENV, None)
        try:
            self.assertEqual(log_collector.main(["--port", "0", "--root", self.root]), 2)
        finally:
            if env is not None:
                os.environ[log_collector.TOKEN_ENV] = env


if __name__ == "__main__":
    unittest.main()
