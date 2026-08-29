# Building and using Ipe on Windows

## Build

The repository's `windows` branch contains a Bash build script for a native,
portable 64-bit Windows build of Ipe 7.2.30. It can be launched from Git Bash,
WSL, or an MSYS2 UCRT64 shell. Git Bash and WSL are forwarded to the native
MSYS2 toolchain automatically.

Install MSYS2 once if it is not already at `C:\msys64`:

```powershell
winget install --id MSYS2.MSYS2 --exact
```

Then, from the repository root:

```bash
./build-windows.sh --clean
```

The script installs missing UCRT64 build packages with `pacman`, compiles Ipe,
collects non-system runtime DLLs, strips the staged binaries, and runs an Ipe
Lua smoke test. The runnable application is written to:

```text
dist/ipe-7.2.30-windows-x64/bin/ipe.exe
```

Use `./build-windows.sh --help` for clean/dependency/job/output controls.

## Local MCP collaboration

This build adds `Ipelets > AI collaboration (MCP)` to Ipe. The bridge lets an
MCP-capable AI inspect native Ipe XML, render pages to images, select objects,
make undoable diagram edits, navigate, save, undo, and redo.

Its split transport follows the same useful pattern as the
[Cheat Engine MCP bridge](https://github.com/miscusi-peek/cheatengine-mcp-bridge):
an in-application bridge performs UI-thread work while a separate stdio MCP
server speaks to the AI client.

The bridge is local-only: Ipe binds exclusively to `127.0.0.1`, it is stopped
by default, and nothing is uploaded or published. Start it explicitly for the
Ipe window you want to share:

1. Run `bin\ipe.exe` from the portable bundle.
2. Choose `Ipelets > AI collaboration (MCP) > Start local bridge`.
3. Configure your MCP client to launch the bundled Python server.

A typical stdio MCP configuration is:

```json
{
  "mcpServers": {
    "ipe": {
      "command": "py",
      "args": [
        "-3",
        "C:\\absolute\\path\\to\\ipe-7.2.30-windows-x64\\mcp\\ipe_mcp_server.py"
      ]
    }
  }
}
```

The server uses only the Python 3 standard library. It supports both the
2026-07-28 sessionless MCP lifecycle and legacy initialize-based clients.
Choose `Connection details` in Ipe's MCP menu to see the server path and live
bridge status. Choose `Stop local bridge` when collaboration is finished.

The default port is 49328. To change it, set `IPE_MCP_PORT` to the same value
in the environments that launch Ipe and the Python MCP server.
