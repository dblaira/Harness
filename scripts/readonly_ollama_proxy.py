#!/usr/bin/env python3
"""Expose only one fixed-model, non-streaming Ollama generation route."""

from __future__ import annotations

import argparse
import json
import signal
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import snapshot_ollama_state
except ModuleNotFoundError:  # Imported as scripts.readonly_ollama_proxy in tests.
    from scripts import snapshot_ollama_state


MAX_BODY = 2 * 1024 * 1024


def route_kind(method: str, path: str) -> str | None:
    if method == "GET" and path == "/api/tags":
        return "tags"
    if method == "POST" and path == "/api/generate":
        return "generate"
    return None


def generation_errors(payload: object, model: str) -> list[str]:
    if not isinstance(payload, dict):
        return ["request body must be a JSON object"]
    errors: list[str] = []
    if payload.get("model") != model:
        errors.append("request model does not match the protected model")
    if payload.get("stream") is not False:
        errors.append("stream must be false")
    return errors


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "HarnessReadOnlyOllama/1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def reject(self, status: int, message: str) -> None:
        body = json.dumps({"error": message}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def forward(self, path: str, body: bytes | None = None) -> None:
        request = urllib.request.Request(
            f"{self.server.upstream}{path}",  # type: ignore[attr-defined]
            data=body,
            method=self.command,
        )
        if body is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                response_body = response.read()
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
        except urllib.error.HTTPError as error:
            self.reject(error.code, "upstream Ollama request failed")
        except (urllib.error.URLError, TimeoutError):
            self.reject(502, "upstream Ollama service is unavailable")

    def do_GET(self) -> None:  # noqa: N802
        if route_kind(self.command, self.path) != "tags":
            self.reject(403, "only model inspection and generation are available")
            return
        self.forward("/api/tags")

    def do_POST(self) -> None:  # noqa: N802
        if route_kind(self.command, self.path) != "generate":
            self.reject(403, "Ollama mutation endpoints are not available")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.reject(400, "invalid request length")
            return
        if length <= 0 or length > MAX_BODY:
            self.reject(413, "invalid request size")
            return
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.reject(400, "request body must be valid JSON")
            return
        errors = generation_errors(payload, self.server.model)  # type: ignore[attr-defined]
        if errors:
            self.reject(403, "; ".join(errors))
            return
        self.forward("/api/generate", body)

    def do_PUT(self) -> None:  # noqa: N802
        self.reject(403, "Ollama mutation endpoints are not available")

    do_DELETE = do_PUT
    do_PATCH = do_PUT


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", default="http://127.0.0.1:11434")
    parser.add_argument("--model", default="hermes3:8b")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", required=True, type=Path)
    args = parser.parse_args()
    state = snapshot_ollama_state.fetch_state(args.upstream)
    matching = next(
        (item for item in state["models"] if args.model in {item["name"], item["model"]}),
        None,
    )
    if matching is None or not matching["digest"]:
        raise SystemExit(f"protected Ollama model is unavailable or lacks a digest: {args.model}")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), ProxyHandler)
    server.upstream = args.upstream.rstrip("/")  # type: ignore[attr-defined]
    server.model = args.model  # type: ignore[attr-defined]
    args.ready_file.parent.mkdir(parents=True, exist_ok=True)
    args.ready_file.write_text(
        json.dumps(
            {
                "pid": __import__("os").getpid(),
                "port": server.server_port,
                "model": args.model,
                "digest": matching["digest"],
            }
        )
        + "\n",
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
