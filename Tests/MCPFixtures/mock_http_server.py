#!/usr/bin/env python3
"""Small Streamable HTTP wrapper around the deterministic stdio response set."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer


class FixtureHTTPServer(ThreadingHTTPServer):
    """Avoid a reverse-DNS lookup so the fixture also starts in offline CI."""

    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        method = request.get("method")
        if "id" not in request:
            self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers(); return
        if method == "initialize":
            value = {"protocolVersion": "2025-11-25", "serverInfo": {"name": "noema-http-fixture", "version": "1.0"},
                     "capabilities": {"tools": {"listChanged": True}, "resources": {"subscribe": True}, "prompts": {}, "completions": {}}}
        elif method == "ping": value = {}
        elif method == "tools/list":
            value = {"tools": [{"name": "http.echo", "description": "Echo", "inputSchema": {"type": "object", "additionalProperties": True}}]}
        elif method == "tools/call":
            value = {"content": [{"type": "text", "text": json.dumps(request.get("params", {}).get("arguments", {}), sort_keys=True)}], "isError": False}
        elif method == "resources/list": value = {"resources": []}
        elif method == "resources/templates/list": value = {"resourceTemplates": []}
        elif method == "prompts/list": value = {"prompts": []}
        else:
            self.reply({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Method not found"}}); return
        self.reply({"jsonrpc": "2.0", "id": request["id"], "result": value}, session=method == "initialize")

    def do_GET(self):
        self.send_response(405); self.send_header("Content-Length", "0"); self.end_headers()

    def do_DELETE(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()

    def reply(self, value, session=False):
        payload = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if session: self.send_header("Mcp-Session-Id", "noema-fixture-session")
        self.end_headers(); self.wfile.write(payload)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args(); server = FixtureHTTPServer(("127.0.0.1", args.port), Handler)
    print(server.server_port, flush=True); server.serve_forever()
