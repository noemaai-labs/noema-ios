#!/usr/bin/env python3
"""Deterministic MCP 2025-11-25 stdio fixture used by Noema acceptance tests."""
import json
import sys
import time


def send(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def result(request_id, value):
    send({"jsonrpc": "2.0", "id": request_id, "result": value})


def main():
    for raw in sys.stdin:
        request = json.loads(raw)
        method = request.get("method")
        request_id = request.get("id")
        params = request.get("params", {})
        if method == "initialize":
            result(request_id, {
                "protocolVersion": "2025-11-25",
                "serverInfo": {"name": "noema-fixture", "version": "1.0"},
                "capabilities": {
                    "tools": {"listChanged": True},
                    "resources": {"subscribe": True, "listChanged": True},
                    "prompts": {"listChanged": True}, "completions": {}, "logging": {},
                    "tasks": {"list": {}, "cancel": {}, "requests": {"tools": {"call": {}}}}
                }
            })
        elif method == "ping":
            result(request_id, {})
        elif method == "tools/list":
            cursor = params.get("cursor")
            if cursor is None:
                result(request_id, {"tools": [{
                    "name": "fixture.echo", "description": "Returns every MCP content type",
                    "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]},
                    "outputSchema": {"type": "object", "properties": {"echo": {"type": "string"}}},
                    "annotations": {"readOnlyHint": True, "destructiveHint": False}
                }], "nextCursor": "tools-2"})
            else:
                result(request_id, {"tools": [{
                    "name": "fixture.slow", "description": "Emits deterministic progress",
                    "inputSchema": {"type": "object", "additionalProperties": False}
                }]})
        elif method == "tools/call":
            token = params.get("_meta", {}).get("progressToken")
            if token is not None:
                send({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": 1, "total": 1, "message": "Ready"}})
            message = params.get("arguments", {}).get("message", "ok")
            result(request_id, {
                "content": [
                    {"type": "text", "text": message},
                    {"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="},
                    {"type": "audio", "mimeType": "audio/wav", "data": "UklGRg=="},
                    {"type": "resource", "resource": {"uri": "fixture://embedded", "mimeType": "text/plain", "text": "embedded"}},
                    {"type": "resource_link", "uri": "fixture://linked", "name": "Linked resource"}
                ],
                "structuredContent": {"echo": message}, "isError": False
            })
        elif method == "resources/list":
            result(request_id, {"resources": [{"uri": "fixture://document", "name": "Document", "mimeType": "text/plain"}]})
        elif method == "resources/templates/list":
            result(request_id, {"resourceTemplates": [{"uriTemplate": "fixture://document/{name}", "name": "Named document", "mimeType": "text/plain"}]})
        elif method == "resources/read":
            result(request_id, {"contents": [{"uri": params["uri"], "mimeType": "text/plain", "text": "fixture snapshot"}]})
        elif method in ("resources/subscribe", "resources/unsubscribe"):
            result(request_id, {})
        elif method == "prompts/list":
            result(request_id, {"prompts": [{"name": "fixture.prompt", "description": "Fixture prompt", "arguments": [{"name": "topic", "required": True}]}]})
        elif method == "prompts/get":
            topic = params.get("arguments", {}).get("topic", "MCP")
            result(request_id, {"description": "Fixture", "messages": [{"role": "user", "content": {"type": "text", "text": "Explain " + topic}}]})
        elif method == "completion/complete":
            result(request_id, {"completion": {"values": ["alpha", "beta"], "total": 2, "hasMore": False}})
        elif method == "roots/list":
            result(request_id, {"roots": []})
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found: " + str(method)}})


if __name__ == "__main__":
    main()
