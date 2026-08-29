#!/usr/bin/env python3
"""Dependency-free stdio MCP server for the local Ipe Windows bridge."""

from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import sys
from typing import Any, Dict, Iterable, List, Optional


SERVER_INFO = {"name": "ipe-mcp", "version": "1.0.0"}
CURRENT_PROTOCOL = "2026-07-28"
LEGACY_PROTOCOLS = (
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
)
SUPPORTED_PROTOCOLS = (CURRENT_PROTOCOL,) + LEGACY_PROTOCOLS
DEFAULT_PORT = 49328
MAX_FRAME = 64 * 1024 * 1024

INSTRUCTIONS = (
    "This server collaborates with the Ipe vector drawing window whose local MCP "
    "bridge is running. Inspect the document or render a page before editing. "
    "Ipe XML edits use the document's native object format and are undoable."
)


def _object_schema(
    properties: Optional[Dict[str, Any]] = None,
    required: Optional[Iterable[str]] = None,
    *,
    additional: bool = False,
) -> Dict[str, Any]:
    schema: Dict[str, Any] = {
        "type": "object",
        "properties": properties or {},
        "additionalProperties": additional,
    }
    if required:
        schema["required"] = list(required)
    return schema


PAGE_PROPERTY = {
    "type": "integer",
    "minimum": 1,
    "description": "1-based page number; defaults to the current page.",
}
INDEX_PROPERTY = {
    "type": "integer",
    "minimum": 1,
    "description": "1-based object index on the current page.",
}
INDICES_PROPERTY = {
    "type": "array",
    "minItems": 1,
    "uniqueItems": True,
    "items": {"type": "integer", "minimum": 1},
    "description": "1-based object indices on the current page.",
}


TOOLS: List[Dict[str, Any]] = [
    {
        "name": "get_document_info",
        "title": "Inspect Ipe document",
        "description": (
            "Return the active Ipe document, page/view, layers, selection, and "
            "modified state. Use this first when joining an editing session."
        ),
        "inputSchema": _object_schema(),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "list_objects",
        "title": "List Ipe objects",
        "description": (
            "List objects in drawing order with type, layer, selection, and text. "
            "Set include_xml to inspect each object's canonical Ipe XML."
        ),
        "inputSchema": _object_schema(
            {
                "page": PAGE_PROPERTY,
                "include_xml": {
                    "type": "boolean",
                    "default": False,
                    "description": "Include canonical XML for every object.",
                },
            }
        ),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "get_page_xml",
        "title": "Read Ipe page XML",
        "description": (
            "Return a page as canonical <ipepage> XML. This is the most complete "
            "structural representation for understanding or revising a diagram."
        ),
        "inputSchema": _object_schema({"page": PAGE_PROPERTY}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "get_selection_xml",
        "title": "Read selected Ipe XML",
        "description": "Return the current selection as canonical <ipeselection> XML.",
        "inputSchema": _object_schema(),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "render_page",
        "title": "View Ipe page",
        "description": (
            "Render an Ipe page/view to PNG and return it as MCP image content. "
            "Use this to visually inspect the diagram before and after edits."
        ),
        "inputSchema": _object_schema(
            {
                "page": PAGE_PROPERTY,
                "view": {
                    "type": "integer",
                    "minimum": 1,
                    "description": "1-based view number; defaults to the active view.",
                },
                "zoom": {
                    "type": "number",
                    "minimum": 0.1,
                    "maximum": 8,
                    "default": 1.5,
                },
                "transparent": {"type": "boolean", "default": False},
                "nocrop": {"type": "boolean", "default": False},
            }
        ),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "add_objects_xml",
        "title": "Add Ipe diagram objects",
        "description": (
            "Add one native Ipe object XML element or an <ipeselection> containing "
            "multiple objects to the current page. Example path data uses Ipe's "
            "PostScript-like syntax: <path stroke=\"black\">0 0 m 100 0 l</path>."
        ),
        "inputSchema": _object_schema(
            {
                "xml": {
                    "type": "string",
                    "description": "One Ipe object element or an <ipeselection> document.",
                },
                "layer": {
                    "type": "string",
                    "minLength": 1,
                    "description": "Existing destination layer; defaults to XML/active layer.",
                },
            },
            ["xml"],
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "replace_object_xml",
        "title": "Replace Ipe object",
        "description": (
            "Replace one object on the current page with one native Ipe XML object. "
            "The edit is registered in Ipe's undo stack."
        ),
        "inputSchema": _object_schema(
            {"index": INDEX_PROPERTY, "xml": {"type": "string", "minLength": 1}},
            ["index", "xml"],
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
    {
        "name": "delete_objects",
        "title": "Delete Ipe objects",
        "description": "Delete objects from the current page as one undoable edit.",
        "inputSchema": _object_schema({"indices": INDICES_PROPERTY}, ["indices"]),
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
    {
        "name": "set_object_text",
        "title": "Edit Ipe text",
        "description": (
            "Set a text object's source text (or a group's URL) on the current page. "
            "The edit is undoable."
        ),
        "inputSchema": _object_schema(
            {"index": INDEX_PROPERTY, "text": {"type": "string", "minLength": 1}},
            ["index", "text"],
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "transform_objects",
        "title": "Transform Ipe objects",
        "description": (
            "Apply an affine matrix [a,b,c,d,e,f] to objects on the current page. "
            "For translation use [1,0,0,1,dx,dy]. The edit is undoable."
        ),
        "inputSchema": _object_schema(
            {
                "indices": INDICES_PROPERTY,
                "matrix": {
                    "type": "array",
                    "minItems": 6,
                    "maxItems": 6,
                    "items": {"type": "number"},
                },
            },
            ["indices", "matrix"],
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "replace_page_xml",
        "title": "Replace Ipe page",
        "description": (
            "Replace the current page from canonical <ipepage> XML as one undoable "
            "edit. Prefer targeted object edits when possible."
        ),
        "inputSchema": _object_schema(
            {"xml": {"type": "string", "minLength": 1}}, ["xml"]
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
    {
        "name": "select_objects",
        "title": "Select Ipe objects",
        "description": "Set the current page selection using 1-based object indices.",
        "inputSchema": _object_schema(
            {
                "indices": {
                    "type": "array",
                    "uniqueItems": True,
                    "items": {"type": "integer", "minimum": 1},
                }
            },
            ["indices"],
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "set_current_view",
        "title": "Navigate Ipe document",
        "description": "Show a page and view in the attached Ipe window.",
        "inputSchema": _object_schema(
            {
                "page": {"type": "integer", "minimum": 1},
                "view": {"type": "integer", "minimum": 1, "default": 1},
            },
            ["page"],
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "undo",
        "title": "Undo Ipe edit",
        "description": "Undo the latest edit using Ipe's native undo stack.",
        "inputSchema": _object_schema(),
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
    {
        "name": "redo",
        "title": "Redo Ipe edit",
        "description": "Redo the latest undone edit using Ipe's native redo stack.",
        "inputSchema": _object_schema(),
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "save_document",
        "title": "Save Ipe document",
        "description": (
            "Save using Ipe's normal save workflow. Omit path to save the current "
            "file, or provide a local .ipe, .xml, or .pdf path."
        ),
        "inputSchema": _object_schema(
            {"path": {"type": "string", "minLength": 1}}
        ),
        "annotations": {"readOnlyHint": False, "destructiveHint": True},
    },
]

TOOLS_BY_NAME = {tool["name"]: tool for tool in TOOLS}


class BridgeError(RuntimeError):
    """The local Ipe bridge could not fulfill a tool call."""


def _receive_exact(connection: socket.socket, count: int) -> bytes:
    chunks: List[bytes] = []
    remaining = count
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise BridgeError("Ipe closed the bridge connection before replying")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def call_ipe(
    name: str,
    arguments: Dict[str, Any],
    *,
    port: int,
    timeout: float,
) -> Dict[str, Any]:
    request = json.dumps(
        {"name": name, "arguments": arguments},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    if len(request) > 16 * 1024 * 1024:
        raise BridgeError("tool request exceeds the Ipe bridge limit")

    try:
        with socket.create_connection(("127.0.0.1", port), timeout=min(timeout, 5)) as conn:
            conn.settimeout(timeout)
            conn.sendall(struct.pack("<I", len(request)) + request)
            size = struct.unpack("<I", _receive_exact(conn, 4))[0]
            if size == 0 or size > MAX_FRAME:
                raise BridgeError("Ipe returned an invalid bridge frame")
            payload = _receive_exact(conn, size)
    except (ConnectionError, OSError, socket.timeout) as exc:
        raise BridgeError(
            "Cannot reach Ipe. In Ipe, choose Ipelets > AI collaboration (MCP) "
            f"> Start local bridge. ({exc})"
        ) from exc

    try:
        response = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError("Ipe returned an invalid JSON bridge response") from exc
    if not isinstance(response, dict):
        raise BridgeError("Ipe returned an invalid bridge response")
    if not response.get("ok"):
        raise BridgeError(str(response.get("error", "Ipe tool call failed")))
    result = response.get("result")
    if not isinstance(result, dict):
        raise BridgeError("Ipe returned no tool result")
    return result


def _server_meta() -> Dict[str, Any]:
    return {"io.modelcontextprotocol/serverInfo": dict(SERVER_INFO)}


def _error_response(request_id: Any, code: int, message: str) -> Dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


class IpeMcpServer:
    def __init__(self, *, port: int = DEFAULT_PORT, timeout: float = 120.0) -> None:
        self.port = port
        self.timeout = timeout

    def handle(self, message: Any) -> Optional[Dict[str, Any]]:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return _error_response(None, -32600, "Invalid Request")

        method = message.get("method")
        request_id = message.get("id")
        is_notification = "id" not in message

        if is_notification:
            return None
        if not isinstance(method, str):
            return _error_response(request_id, -32600, "Request method is required")

        if method == "server/discover":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "supportedVersions": list(SUPPORTED_PROTOCOLS),
                    "capabilities": {"tools": {}},
                    "instructions": INSTRUCTIONS,
                    "ttlMs": 0,
                    "cacheScope": "private",
                    "_meta": _server_meta(),
                },
            }

        if method == "initialize":
            params = message.get("params")
            requested = params.get("protocolVersion") if isinstance(params, dict) else None
            protocol = requested if requested in LEGACY_PROTOCOLS else LEGACY_PROTOCOLS[0]
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": protocol,
                    "capabilities": {"tools": {}},
                    "serverInfo": dict(SERVER_INFO),
                    "instructions": INSTRUCTIONS,
                },
            }

        if method == "ping":
            return {"jsonrpc": "2.0", "id": request_id, "result": {}}

        if method == "tools/list":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "resultType": "complete",
                    "tools": TOOLS,
                    "ttlMs": 0,
                    "cacheScope": "private",
                    "_meta": _server_meta(),
                },
            }

        if method == "tools/call":
            params = message.get("params")
            if not isinstance(params, dict):
                return _error_response(request_id, -32602, "Invalid tools/call parameters")
            name = params.get("name")
            arguments = params.get("arguments", {})
            if name not in TOOLS_BY_NAME:
                return _error_response(request_id, -32602, f"Unknown tool: {name}")
            if not isinstance(arguments, dict):
                return _error_response(request_id, -32602, "Tool arguments must be an object")
            try:
                result = call_ipe(name, arguments, port=self.port, timeout=self.timeout)
            except BridgeError as exc:
                result = {
                    "content": [{"type": "text", "text": str(exc)}],
                    "isError": True,
                }
            result.setdefault("content", [])
            result.setdefault("isError", False)
            result["resultType"] = "complete"
            result.setdefault("_meta", _server_meta())
            return {"jsonrpc": "2.0", "id": request_id, "result": result}

        return _error_response(request_id, -32601, f"Method not found: {method}")


def serve(server: IpeMcpServer) -> int:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    for raw_line in stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            response = _error_response(None, -32700, "Parse error")
        else:
            try:
                response = server.handle(message)
            except Exception as exc:  # Keep the stdio server alive after one bad call.
                print(f"ipe-mcp internal error: {exc}", file=sys.stderr)
                request_id = message.get("id") if isinstance(message, dict) else None
                response = _error_response(request_id, -32603, "Internal error")
        if response is not None:
            encoded = json.dumps(
                response, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
            stdout.write(encoded + b"\n")
            stdout.flush()
    return 0


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Expose a running local Ipe Windows MCP bridge over stdio."
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("IPE_MCP_PORT", DEFAULT_PORT)),
        help=f"Ipe loopback bridge port (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=120.0,
        help="seconds to wait for an Ipe tool call (default: 120)",
    )
    args = parser.parse_args(argv)
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be between 1024 and 65535")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)
    return serve(IpeMcpServer(port=args.port, timeout=args.timeout))


if __name__ == "__main__":
    raise SystemExit(main())
