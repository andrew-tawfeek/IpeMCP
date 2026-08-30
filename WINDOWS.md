# Building and troubleshooting Ipe MCP on Windows

This page is the detailed Windows build reference. For the project overview,
MCP client setup, tool catalog, and security model, start with [README.md](README.md).

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
collects non-system runtime DLLs, strips the staged binaries, and runs both an
Ipe Lua smoke test and a full GUI-startup smoke test. The runnable application
is written to:

```text
dist/ipe-7.2.30-windows-x64/bin/ipe.exe
```

Use `./build-windows.sh --help` for clean/dependency/job/output controls.

## Local MCP collaboration

This build adds `Ipelets > AI collaboration (MCP)` to Ipe. The bridge lets an
MCP-capable AI inspect native Ipe XML, render pages to images, select objects,
make undoable diagram edits, navigate, save, undo, and redo.

An in-application bridge performs UI-thread work while a separate stdio MCP
server speaks to the AI client. The implementation and request lifecycle are
documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

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

## Troubleshooting

### Ipe exits without showing a window

Run the full startup path from Git Bash to expose any startup error:

```bash
./dist/ipe-7.2.30-windows-x64/bin/ipe.exe -show-configuration
```

A healthy bundle prints Ipe 7.2.30 along with its Lua, styles, documentation,
ipelets, and icons directories. Re-run `./build-windows.sh --clean` if any path
is missing or the command reports a Lua error.

### The MCP client cannot reach Ipe

Confirm all of the following:

1. The portable Ipe build is running.
2. **Ipelets → AI collaboration (MCP) → Start local bridge** was selected.
3. The client configuration uses an absolute path to `ipe_mcp_server.py`.
4. Ipe and the Python server use the same `IPE_MCP_PORT` value.
5. No other Ipe instance is already using that port.

Choose **Connection details** in Ipe to see the live status and expected server
command.

### Run the verification suite

After a successful build:

```powershell
python -m unittest discover -s tests -v
```

The compiled integration tests require the bundle under `dist` and the Lua 5.4
runtime installed by the build script.
