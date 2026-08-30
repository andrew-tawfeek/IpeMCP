import importlib.util
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "mcp" / "ipe_mcp_server.py"
BUNDLE_BIN = ROOT / "dist" / "ipe-7.2.30-windows-x64" / "bin"
IPELET_PATH = ROOT / "ipe-7.2.30" / "src" / "ipelets" / "lua" / "mcp.lua"
LUA = shutil.which("lua5.4")
MSYS2_ROOT = Path(os.environ.get("MSYS2_ROOT", "C:/msys64"))
MSYS2_LUA = MSYS2_ROOT / "ucrt64" / "bin" / "lua5.4.exe"
if LUA is None and MSYS2_LUA.is_file():
    LUA = str(MSYS2_LUA)
SPEC = importlib.util.spec_from_file_location("ipe_mcp_server", SERVER_PATH)
assert SPEC and SPEC.loader
mcp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.server = mcp.IpeMcpServer(port=49328, timeout=1)

    def test_discovery_supports_current_and_legacy_protocols(self):
        response = self.server.handle(
            {"jsonrpc": "2.0", "id": 1, "method": "server/discover"}
        )
        result = response["result"]
        self.assertEqual(result["supportedVersions"][0], "2026-07-28")
        self.assertIn("2025-11-25", result["supportedVersions"])
        self.assertIn("tools", result["capabilities"])

    def test_initialize_echoes_a_supported_legacy_version(self):
        response = self.server.handle(
            {
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                },
            }
        )
        self.assertEqual(response["result"]["protocolVersion"], "2025-06-18")

    def test_tool_list_is_deterministic_and_has_schemas(self):
        response = self.server.handle(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
        )
        tools = response["result"]["tools"]
        names = [tool["name"] for tool in tools]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("render_page", names)
        self.assertIn("replace_page_xml", names)
        self.assertTrue(all(tool["inputSchema"]["type"] == "object" for tool in tools))

    def test_notification_has_no_response(self):
        response = self.server.handle(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}
        )
        self.assertIsNone(response)

    @mock.patch.object(mcp, "call_ipe")
    def test_tool_call_forwards_to_ipe(self, call_ipe):
        call_ipe.return_value = {
            "content": [{"type": "text", "text": "ok"}],
            "structuredContent": {"pageCount": 1},
            "isError": False,
        }
        response = self.server.handle(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "get_document_info", "arguments": {}},
            }
        )
        call_ipe.assert_called_once_with(
            "get_document_info", {}, port=49328, timeout=1
        )
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(response["result"]["resultType"], "complete")

    @mock.patch.object(mcp, "call_ipe", side_effect=mcp.BridgeError("not running"))
    def test_bridge_failure_is_a_tool_error(self, _call_ipe):
        response = self.server.handle(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {"name": "get_document_info", "arguments": {}},
            }
        )
        self.assertTrue(response["result"]["isError"])
        self.assertIn("not running", response["result"]["content"][0]["text"])

    def test_stdio_emits_only_json_rpc_lines(self):
        requests = b"\n".join(
            [
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {"protocolVersion": "2025-11-25"},
                    }
                ).encode(),
                json.dumps(
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
                ).encode(),
            ]
        ) + b"\n"
        completed = subprocess.run(
            [sys.executable, str(SERVER_PATH)],
            input=requests,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=10,
        )
        messages = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([message["id"] for message in messages], [1, 2])
        self.assertEqual(completed.stderr, b"")


class BridgeFramingTests(unittest.TestCase):
    def test_length_prefixed_loopback_round_trip(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(listener.close)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        observed = {}

        def fake_ipe():
            connection, _ = listener.accept()
            with connection:
                size = struct.unpack("<I", connection.recv(4))[0]
                request = b""
                while len(request) < size:
                    request += connection.recv(size - len(request))
                observed.update(json.loads(request.decode("utf-8")))
                response = json.dumps(
                    {
                        "ok": True,
                        "result": {
                            "content": [{"type": "text", "text": "Ipe replied"}],
                            "isError": False,
                        },
                    },
                    separators=(",", ":"),
                ).encode()
                connection.sendall(struct.pack("<I", len(response)) + response)

        thread = threading.Thread(target=fake_ipe)
        thread.start()
        result = mcp.call_ipe("get_document_info", {}, port=port, timeout=2)
        thread.join(timeout=2)
        self.assertEqual(observed["name"], "get_document_info")
        self.assertEqual(result["content"][0]["text"], "Ipe replied")


@unittest.skipUnless(
    LUA and (BUNDLE_BIN / "ipelua.dll").is_file(),
    "the compiled Windows bundle and Lua 5.4 are required",
)
class CompiledIntegrationTests(unittest.TestCase):
    def bundle_environment(self):
        environment = os.environ.copy()
        environment["PATH"] = str(BUNDLE_BIN) + os.pathsep + environment.get("PATH", "")
        return environment

    def test_ipelet_loads_as_a_menu_extension_and_edits_real_ipe_objects(self):
        completed = subprocess.run(
            [
                LUA,
                str(ROOT / "tests" / "mcp_ipelet_headless.lua"),
                str(BUNDLE_BIN),
                str(IPELET_PATH),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=30,
            env=self.bundle_environment(),
        )
        self.assertIn(b"headless MCP ipelet: ok", completed.stdout)
        self.assertEqual(completed.stderr, b"")

    def test_compiled_renderer_produces_a_real_png(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "ipe-render.png"
            completed = subprocess.run(
                [
                    str(BUNDLE_BIN / "iperender.exe"),
                    "-png",
                    "-resolution",
                    "96",
                    str(ROOT / "ipe-7.2.30" / "artwork" / "ipe_logo.ipe"),
                    str(output),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
                env=self.bundle_environment(),
            )
            self.assertEqual(
                completed.returncode,
                0,
                completed.stderr.decode("utf-8", errors="replace"),
            )
            png = output.read_bytes()
            self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertGreater(len(png), 1000)

    def test_stdio_mcp_round_trip_through_compiled_winsock_bridge(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]

        bridge = subprocess.Popen(
            [
                LUA,
                str(ROOT / "tests" / "mcp_native_bridge.lua"),
                str(BUNDLE_BIN / "ipeui.dll"),
                str(port),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.bundle_environment(),
        )
        self.addCleanup(lambda: bridge.poll() is None and bridge.kill())
        ready = bridge.stdout.readline()
        if ready.strip() != b"READY":
            _, stderr = bridge.communicate(timeout=5)
            self.fail(f"native bridge did not start: {ready!r} {stderr!r}")

        request = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 17,
                "method": "tools/call",
                "params": {"name": "get_document_info", "arguments": {}},
            }
        ).encode() + b"\n"
        adapter = subprocess.run(
            [sys.executable, str(SERVER_PATH), "--port", str(port), "--timeout", "5"],
            input=request,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=10,
        )
        response = json.loads(adapter.stdout)
        self.assertEqual(response["id"], 17)
        self.assertFalse(response["result"]["isError"])
        self.assertEqual(
            response["result"]["structuredContent"]["transport"], "winsock"
        )
        stdout, stderr = bridge.communicate(timeout=5)
        self.assertIn(b"REPLIED", stdout)
        self.assertEqual(stderr, b"")


if __name__ == "__main__":
    unittest.main()
