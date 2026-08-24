#!/usr/bin/env python3
"""
A reference sentinel engine that always returns the expected verdict.

It answers from the corpus itself, so it scores 100% by construction. The point
is not to check the engine but to check the harness: without something listening,
bin/run-tests.sh is never exercised at all, and a break in it would only surface
against somebody's real engine.
"""

import argparse
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_corpus(root):
    """Map each vector's transaction to the response its verdict implies."""
    verdicts = {}
    for path in sorted(root.glob("specs/*/*.json")):
        spec = json.loads(path.read_text())
        key = json.dumps(spec["transaction"], sort_keys=True)
        answer = {"verdict": spec["verdict"]}
        if "rule" in spec:
            answer["rule"] = spec["rule"]
        if verdicts.get(key, answer) != answer:
            sys.exit(
                f"{path.relative_to(root)}: another vector has the same "
                f"transaction but expects a different verdict"
            )
        verdicts[key] = answer
    if not verdicts:
        sys.exit(f"no specs found under {root / 'specs'}")
    return verdicts


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        """Stay quiet: CI logs should be about the tests, not about this."""

    def respond(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        """Health check, so a caller can wait for the port to start serving."""
        self.respond(200, {"status": "ok", "vectors": len(self.server.verdicts)})

    def do_POST(self):
        if self.path != "/v1/security-check":
            self.respond(404, {"error": f"no such endpoint: {self.path}"})
            return

        length = int(self.headers.get("content-length") or 0)
        try:
            key = json.dumps(
                json.loads(self.rfile.read(length))["transaction"], sort_keys=True
            )
        except (ValueError, KeyError, TypeError) as error:
            self.respond(400, {"error": f"expected a transaction: {error}"})
            return

        answer = self.server.verdicts.get(key)
        if answer is None:
            # Louder than abstaining. An unknown transaction means this process
            # and the corpus disagree, which is a bug rather than an opinion.
            self.respond(404, {"error": "transaction is not in the corpus"})
            return

        self.respond(200, answer)


def main():
    parser = argparse.ArgumentParser(description=__doc__.partition("\n")[0])
    parser.add_argument("--host", default="127.0.0.1", help="default: 127.0.0.1")
    parser.add_argument("--port", type=int, default=5473, help="default: 5473")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.verdicts = load_corpus(ROOT)
    print(
        f"serving {len(server.verdicts)} vectors on "
        f"http://{args.host}:{args.port}/v1/security-check",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
