#!/usr/bin/env python3
"""Expose one local read-only SPARQL query endpoint to proposal processes."""

from __future__ import annotations

import argparse
import json
import re
import signal
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


READ_QUERY = re.compile(r"\b(SELECT|ASK|CONSTRUCT|DESCRIBE)\b", re.IGNORECASE)
UPDATE_WORD = re.compile(
    r"\b(INSERT|DELETE|LOAD|CLEAR|CREATE|DROP|COPY|MOVE|ADD|WITH)\b",
    re.IGNORECASE,
)


def is_read_only_query(query: str) -> bool:
    stripped = re.sub(r"#[^\n]*", "", query)
    return bool(READ_QUERY.search(stripped)) and not bool(UPDATE_WORD.search(stripped))


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "HarnessReadOnlySPARQL/1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def reject(self, status: int, message: str) -> None:
        body = json.dumps({"error": message}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def query_from_request(self) -> tuple[str, bytes, str] | None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/understood/query":
            return None
        if self.command == "GET":
            query = urllib.parse.parse_qs(parsed.query).get("query", [""])[0]
            return query, b"", ""
        if self.command != "POST":
            return None
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        if content_type.startswith("application/sparql-query"):
            query = body.decode("utf-8", errors="replace")
        elif content_type.startswith("application/x-www-form-urlencoded"):
            query = urllib.parse.parse_qs(body.decode("utf-8", errors="replace")).get("query", [""])[0]
        else:
            query = ""
        return query, body, content_type

    def do_GET(self) -> None:  # noqa: N802
        self.forward()

    def do_POST(self) -> None:  # noqa: N802
        self.forward()

    def do_PUT(self) -> None:  # noqa: N802
        self.reject(405, "SPARQL updates are not available")

    do_DELETE = do_PUT
    do_PATCH = do_PUT

    def forward(self) -> None:
        parsed_request = self.query_from_request()
        if parsed_request is None:
            self.reject(404, "only the query endpoint is available")
            return
        query, body, content_type = parsed_request
        if not is_read_only_query(query):
            self.reject(403, "only read-only SPARQL queries are allowed")
            return
        upstream = self.server.upstream  # type: ignore[attr-defined]
        if self.command == "GET":
            target = f"{upstream}?{urllib.parse.urlencode({'query': query})}"
            request = urllib.request.Request(target, method="GET")
        else:
            request = urllib.request.Request(upstream, data=body, method="POST")
            request.add_header("Content-Type", content_type)
        request.add_header("Accept", self.headers.get("Accept", "application/sparql-results+json"))
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                response_body = response.read()
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/octet-stream"))
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
        except urllib.error.HTTPError as error:
            self.reject(error.code, "upstream query failed")
        except (urllib.error.URLError, TimeoutError):
            self.reject(502, "upstream query service is unavailable")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", default="http://127.0.0.1:3030/understood/query")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), ProxyHandler)
    server.upstream = args.upstream  # type: ignore[attr-defined]
    args.ready_file.parent.mkdir(parents=True, exist_ok=True)
    args.ready_file.write_text(
        json.dumps({"pid": __import__("os").getpid(), "port": server.server_port}) + "\n",
        encoding="utf-8",
    )

    def stop(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
