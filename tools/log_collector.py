#!/usr/bin/env python3
"""Log collector for the CC:Tweaked Draconic Reactor Manager.

Receives the batches that ``log_shipper.lua`` POSTs from in-game computers
and appends every line to real files, one folder per computer::

    <root>/computer-<id>[-<label>]/draconic.log
    <root>/computer-<id>[-<label>]/reactor_stats.csv
    ...

Standard library only (Python 3.8+). Run it on any PC or server that the
Minecraft server can reach::

    python3 log_collector.py --token <secret> --bind 0.0.0.0 --port 8780

Endpoints:
    POST /ingest   JSON batch, header ``Authorization: Bearer <token>``
    GET  /health   liveness check, no authentication, reveals nothing

Payload (as sent by log_shipper.lua)::

    {"computer_id": 7, "computer_label": "Reactors", "sent_at": 1700000000000,
     "dropped": 0,
     "entries": [{"file": "draconic.log", "line": "2024-01-01 12:00:00 [INFO] ..."},
                 {"file": "reactor_stats.csv", "line": "time,temp,...", "header": true}]}

CC:Tweaked's JSON encoder writes bytes 0x80-0xFF as ``\\u0080``-``\\u00FF``,
so lines are encoded back to Latin-1 to reproduce the bytes the computer
wrote locally (text that does not fit Latin-1 is written as UTF-8).

CSV files stay valid: a header entry is written only to an empty file,
skipped when the file already starts with it, and starts a fresh file
(after rotating the old one) when the columns changed. After a size based
rotation the last known header is written again at the top of the new file.
"""

import argparse
import hmac
import json
import logging
import os
import re
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Sequence, Tuple

LOG = logging.getLogger("log_collector")

TOKEN_ENV = "CC_LOG_TOKEN"
DEFAULT_PORT = 8780
DEFAULT_MAX_BYTES = 10 * 1024 * 1024
DEFAULT_BACKUPS = 5
# CC:Tweaked's default per-request upload limit (AddressRule.MAX_UPLOAD).
DEFAULT_MAX_REQUEST = 4 * 1024 * 1024
MAX_ENTRIES = 100000
MAX_LINE_CHARS = 64 * 1024
MAX_LABEL_CHARS = 40
MAX_COMPUTER_ID = 2 ** 31 - 1

# A file name is one plain component with a known extension: no
# separators, no "..", no leading dot, no rotation suffix.
FILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\.(log|csv|txt)$")
LABEL_UNSAFE_RE = re.compile(r"[^A-Za-z0-9_-]+")


class PayloadError(ValueError):
    """Raised when a request body is not a valid batch."""


def sanitize_label(label: Any) -> str:
    """Return a computer label reduced to ``[A-Za-z0-9_-]`` (may be empty)."""
    if not isinstance(label, str):
        return ""
    cleaned = LABEL_UNSAFE_RE.sub("_", label).strip("_-")
    return cleaned[:MAX_LABEL_CHARS].strip("_-")


def computer_folder(computer_id: int, label: Any) -> str:
    """Return the folder name for one in-game computer."""
    safe = sanitize_label(label)
    return "computer-%d" % computer_id + ("-" + safe if safe else "")


def is_safe_file_name(name: Any) -> bool:
    """Return True if ``name`` is an acceptable log file name."""
    return isinstance(name, str) and FILE_NAME_RE.match(name) is not None


def encode_line(line: str) -> bytes:
    """Encode one line to the bytes the in-game computer wrote."""
    try:
        return line.encode("latin-1")
    except UnicodeEncodeError:
        return line.encode("utf-8", errors="replace")


def parse_batch(body: bytes) -> Dict[str, Any]:
    """Decode and validate a request body.

    Returns a dict with ``computer_id``, ``label``, ``dropped`` and
    ``entries`` (a list of ``(file, line, is_header)`` tuples).
    Raises PayloadError with a client-safe message on any problem.
    """
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise PayloadError("body is not valid JSON: %s" % exc) from None
    if not isinstance(data, dict):
        raise PayloadError("body must be a JSON object")

    computer_id = data.get("computer_id")
    if (not isinstance(computer_id, int) or isinstance(computer_id, bool)
            or not 0 <= computer_id <= MAX_COMPUTER_ID):
        raise PayloadError("computer_id must be an integer 0..%d" % MAX_COMPUTER_ID)
    label = data.get("computer_label", "")
    if label is not None and not isinstance(label, str):
        raise PayloadError("computer_label must be a string")
    dropped = data.get("dropped", 0)
    if not isinstance(dropped, int) or isinstance(dropped, bool) or dropped < 0:
        raise PayloadError("dropped must be a non-negative integer")

    raw_entries = data.get("entries")
    if not isinstance(raw_entries, list):
        raise PayloadError("entries must be a list")
    if len(raw_entries) > MAX_ENTRIES:
        raise PayloadError("too many entries (max %d)" % MAX_ENTRIES)
    entries: List[Tuple[str, str, bool]] = []
    for index, entry in enumerate(raw_entries):
        if not isinstance(entry, dict):
            raise PayloadError("entries[%d] must be an object" % index)
        name, line = entry.get("file"), entry.get("line")
        if not is_safe_file_name(name):
            raise PayloadError("entries[%d].file is not an allowed file name" % index)
        if not isinstance(line, str) or len(line) > MAX_LINE_CHARS:
            raise PayloadError("entries[%d].line must be a string of at most %d chars"
                               % (index, MAX_LINE_CHARS))
        entries.append((name, line, entry.get("header") is True))
    return {"computer_id": computer_id, "label": label or "",
            "dropped": dropped, "entries": entries}


class LogStore:
    """Appends lines to files under a root directory with size rotation.

    Each file has its own lock, so concurrent requests for different
    computers never wait for each other and lines of one file are never
    interleaved mid-write.
    """

    def __init__(self, root: str, max_bytes: int, backups: int) -> None:
        self.root = os.path.realpath(root)
        self.max_bytes = max_bytes
        self.backups = backups
        self._locks: Dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()
        self._headers: Dict[str, bytes] = {}
        os.makedirs(self.root, exist_ok=True)

    def _lock_for(self, path: str) -> threading.Lock:
        with self._locks_guard:
            lock = self._locks.get(path)
            if lock is None:
                lock = self._locks[path] = threading.Lock()
            return lock

    def resolve(self, folder: str, name: str) -> str:
        """Return the absolute path for ``folder/name`` inside the root.

        Raises PayloadError if the result would escape the root or
        point at a symbolic link.
        """
        if not is_safe_file_name(name) or not folder or "/" in folder or "\\" in folder \
                or folder in (".", ".."):
            raise PayloadError("unsafe path")
        directory = os.path.join(self.root, folder)
        path = os.path.join(directory, name)
        real = os.path.realpath(path)
        if os.path.commonpath([self.root, real]) != self.root or real != path:
            raise PayloadError("unsafe path")
        if os.path.islink(directory) or os.path.islink(path):
            raise PayloadError("unsafe path")
        return path

    def rotate(self, path: str) -> None:
        """Rotate ``path`` to ``path.1`` .. ``path.<backups>``."""
        if self.backups <= 0:
            if os.path.exists(path):
                os.remove(path)
            return
        oldest = "%s.%d" % (path, self.backups)
        if os.path.exists(oldest):
            os.remove(oldest)
        for index in range(self.backups - 1, 0, -1):
            source = "%s.%d" % (path, index)
            if os.path.exists(source):
                os.replace(source, "%s.%d" % (path, index + 1))
        if os.path.exists(path):
            os.replace(path, path + ".1")
        LOG.info("rotated %s", os.path.relpath(path, self.root))

    @staticmethod
    def _first_line(path: str) -> Optional[bytes]:
        try:
            with open(path, "rb") as handle:
                line = handle.readline(MAX_LINE_CHARS * 4 + 2)
        except FileNotFoundError:
            return None
        return line.rstrip(b"\r\n") if line else None

    def append(self, folder: str, name: str, lines: Sequence[Tuple[str, bool]]) -> int:
        """Append ``(line, is_header)`` pairs to one file; return lines written."""
        path = self.resolve(folder, name)
        is_csv = name.endswith(".csv")
        written = 0
        with self._lock_for(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            size = os.path.getsize(path) if os.path.exists(path) else 0
            if is_csv and path not in self._headers and size > 0:
                first = self._first_line(path)
                if first is not None:
                    self._headers[path] = first
            handle = open(path, "ab")
            try:
                for text, is_header in lines:
                    data = encode_line(text)
                    chunks: List[bytes] = []
                    if is_csv and is_header:
                        if size > 0 and self._headers.get(path) == data:
                            continue                    # already at the top
                        if size > 0:
                            handle.close()              # columns changed
                            self.rotate(path)
                            handle, size = open(path, "ab"), 0
                        self._headers[path] = data
                        chunks.append(data)
                    else:
                        if size > 0 and size + len(data) + 1 > self.max_bytes:
                            handle.close()
                            self.rotate(path)
                            handle, size = open(path, "ab"), 0
                        if is_csv and size == 0 and path in self._headers:
                            chunks.append(self._headers[path])
                        chunks.append(data)
                    blob = b"".join(chunk + b"\n" for chunk in chunks)
                    handle.write(blob)
                    size += len(blob)
                    written += 1
            finally:
                handle.close()
        return written


class CollectorServer(ThreadingHTTPServer):
    """HTTP server holding the collector settings for its handlers."""

    daemon_threads = True

    def __init__(self, address: Tuple[str, int], token: str, store: LogStore,
                 max_request: int) -> None:
        super().__init__(address, CollectorHandler)
        self.token = token.encode("utf-8")
        self.store = store
        self.max_request = max_request


class CollectorHandler(BaseHTTPRequestHandler):
    """Handles /ingest and /health."""

    server: CollectorServer
    server_version = "CCLogCollector/1.0"
    timeout = 30            # seconds; drops stalled clients

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        """Route http.server's access log through ``logging``."""
        LOG.debug("%s %s", self.address_string(), format % args)

    def _reply(self, status: HTTPStatus, payload: Dict[str, Any],
               headers: Optional[Dict[str, str]] = None) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _reject(self, status: HTTPStatus, message: str,
                headers: Optional[Dict[str, str]] = None) -> None:
        LOG.warning("%s %s %s: %d %s", self.address_string(), self.command,
                    self.path, status.value, message)
        self.close_connection = True
        self._reply(status, {"ok": False, "error": message}, headers)

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        scheme, _, supplied = header.partition(" ")
        if scheme.lower() != "bearer":
            supplied = ""
        return hmac.compare_digest(supplied.strip().encode("utf-8"), self.server.token)

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        """Answer the health check."""
        if self.path.split("?", 1)[0] == "/health":
            self._reply(HTTPStatus.OK, {"ok": True})
        else:
            self._reject(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:  # noqa: N802 (http.server naming)
        """Validate, authenticate and store one batch."""
        if self.path.split("?", 1)[0] != "/ingest":
            self._reject(HTTPStatus.NOT_FOUND, "not found")
            return
        if not self._authorized():
            self._reject(HTTPStatus.UNAUTHORIZED, "missing or wrong token",
                         {"WWW-Authenticate": 'Bearer realm="cc-logs"'})
            return
        length_header = self.headers.get("Content-Length")
        if length_header is None:
            self._reject(HTTPStatus.LENGTH_REQUIRED, "Content-Length required")
            return
        try:
            length = int(length_header)
        except ValueError:
            self._reject(HTTPStatus.BAD_REQUEST, "bad Content-Length")
            return
        if length < 0:
            self._reject(HTTPStatus.BAD_REQUEST, "bad Content-Length")
            return
        if length > self.server.max_request:
            self._reject(HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                         "body over %d bytes" % self.server.max_request)
            return
        body = self.rfile.read(length)
        if len(body) != length:
            self._reject(HTTPStatus.BAD_REQUEST, "body shorter than Content-Length")
            return
        try:
            batch = parse_batch(body)
        except PayloadError as exc:
            self._reject(HTTPStatus.BAD_REQUEST, str(exc))
            return
        folder = computer_folder(batch["computer_id"], batch["label"])
        try:
            written = self._store(folder, batch["entries"])
        except PayloadError as exc:
            self._reject(HTTPStatus.BAD_REQUEST, str(exc))
            return
        except OSError as exc:
            LOG.error("write failed for %s: %s", folder, exc)
            self._reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": "write failed"})
            return
        summary = ", ".join("%s: %d" % item for item in sorted(written.items())) or "no lines"
        LOG.info("%s %s: %s%s", self.address_string(), folder, summary,
                 (" (computer dropped %d)" % batch["dropped"]) if batch["dropped"] else "")
        if batch["dropped"]:
            LOG.warning("%s reports %d log lines dropped (in-game queue full)",
                        folder, batch["dropped"])
        self._reply(HTTPStatus.OK, {"ok": True, "written": sum(written.values())})

    def _store(self, folder: str, entries: List[Tuple[str, str, bool]]) -> Dict[str, int]:
        """Group entries by file (keeping order) and append them."""
        grouped: Dict[str, List[Tuple[str, bool]]] = {}
        for name, line, is_header in entries:
            grouped.setdefault(name, []).append((line, is_header))
        written: Dict[str, int] = {}
        for name, lines in grouped.items():
            written[name] = self.server.store.append(folder, name, lines)
        return written


def make_server(bind: str, port: int, root: str, token: str,
                max_bytes: int = DEFAULT_MAX_BYTES, backups: int = DEFAULT_BACKUPS,
                max_request: int = DEFAULT_MAX_REQUEST) -> CollectorServer:
    """Create (but do not start) a collector server."""
    if not token:
        raise ValueError("a token is required")
    store = LogStore(root, max_bytes, backups)
    return CollectorServer((bind, port), token, store, max_request)


def positive_int(text: str) -> int:
    """argparse type: an integer >= 1."""
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return value


def build_parser() -> argparse.ArgumentParser:
    """Return the command line parser."""
    parser = argparse.ArgumentParser(
        description="Receive CC:Tweaked Draconic Manager logs and write them to files.")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="address to listen on (default 127.0.0.1; use 0.0.0.0 "
                             "when Minecraft runs on another machine)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="TCP port (default %d)" % DEFAULT_PORT)
    parser.add_argument("--root", default="cc-logs",
                        help="directory for the log files (default ./cc-logs)")
    parser.add_argument("--token", default=None,
                        help="shared secret; defaults to the %s environment variable"
                             % TOKEN_ENV)
    parser.add_argument("--max-bytes", type=positive_int, default=DEFAULT_MAX_BYTES,
                        help="rotate a file once it would exceed this size "
                             "(default %d)" % DEFAULT_MAX_BYTES)
    parser.add_argument("--backups", type=int, default=DEFAULT_BACKUPS,
                        help="rotated copies kept per file, name.1 .. name.N "
                             "(default %d)" % DEFAULT_BACKUPS)
    parser.add_argument("--max-request", type=positive_int, default=DEFAULT_MAX_REQUEST,
                        help="largest accepted request body in bytes "
                             "(default %d)" % DEFAULT_MAX_REQUEST)
    parser.add_argument("--verbose", action="store_true", help="also log every HTTP request")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Run the collector until interrupted. Returns the exit status."""
    args = build_parser().parse_args(argv)
    logging.basicConfig(stream=sys.stdout,
                        level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    token = args.token or os.environ.get(TOKEN_ENV, "")
    if not token:
        LOG.error("no token: pass --token or set %s. Generate one with: "
                  "python3 -c \"import secrets; print(secrets.token_urlsafe(24))\"", TOKEN_ENV)
        return 2
    if args.backups < 0:
        LOG.error("--backups must be 0 or more")
        return 2
    try:
        server = make_server(args.bind, args.port, args.root, token, args.max_bytes,
                             args.backups, args.max_request)
    except OSError as exc:
        LOG.error("cannot listen on %s:%d: %s", args.bind, args.port, exc)
        return 1
    host, port = server.server_address[:2]
    LOG.info("listening on http://%s:%d/ingest, writing to %s", host, port, server.store.root)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("stopping")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
