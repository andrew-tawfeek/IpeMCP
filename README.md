<p align="center">
  <img src="ipe-7.2.30/artwork/ipe.iconset/icon_256x256.png" width="128" alt="Ipe logo">
</p>

<h1 align="center">Ipe MCP for Windows</h1>

<p align="center">
  Let an MCP-capable AI see, understand, and edit native Ipe diagrams with you.
</p>

<p align="center">
  <img alt="Platform: Windows x64" src="https://img.shields.io/badge/platform-Windows%20x64-0078D4">
  <img alt="Ipe 7.2.30" src="https://img.shields.io/badge/Ipe-7.2.30-5B5FC7">
  <img alt="Python 3.10 or newer" src="https://img.shields.io/badge/Python-3.10%2B-3776AB">
  <img alt="License: GPL v3 or later" src="https://img.shields.io/badge/license-GPL--3.0%2B-green">
</p>

Ipe MCP is a Windows-only fork of the [Ipe extensible drawing
editor](https://ipe.otfried.org/). It adds a local Model Context Protocol bridge
so an AI agent can inspect the open document, render pages, manipulate native
Ipe objects, and participate in the normal save and undo workflow.

> [!NOTE]
> This is an independent community project based on Ipe 7.2.30. It is not an
> official Ipe release and is not affiliated with the upstream Ipe project.

## What it enables

Instead of describing a diagram from memory, you can ask an agent to work with
the actual document:

> “Render the current page and explain its visual hierarchy.”

> “Align objects 3, 5, and 8, then show me the result.”

> “Replace this box label, preserve the styling, and save the document.”

> “Inspect the page XML and add a matching annotation on the notes layer.”

The bridge exposes 16 tools across four workflows:

| Workflow | Tools |
|---|---|
| Inspect | `get_document_info`, `list_objects`, `get_page_xml`, `get_selection_xml` |
| See | `render_page` |
| Edit | `add_objects_xml`, `replace_object_xml`, `delete_objects`, `set_object_text`, `transform_objects`, `replace_page_xml` |
| Operate Ipe | `select_objects`, `set_current_view`, `undo`, `redo`, `save_document` |

Edits use Ipe's native object model and are registered with Ipe's regular undo
stack. Render results are returned as MCP image content, while structural reads
use canonical Ipe XML.

## Quick start

### 1. Install the build prerequisites

You need:

- 64-bit Windows 10 or 11
- [MSYS2](https://www.msys2.org/) installed at `C:\msys64`
- Python 3.10 or newer
- Git Bash, WSL, or an MSYS2 UCRT64 shell

Install MSYS2 from PowerShell if needed:

```powershell
winget install --id MSYS2.MSYS2 --exact
```

### 2. Build the portable application

From the repository root:

```bash
./build-windows.sh --clean
```

Git Bash and WSL are forwarded automatically to the native MSYS2 UCRT64
toolchain. The script installs missing compiler dependencies, builds Ipe,
collects its runtime DLLs, and runs both command-line and full GUI-startup smoke
tests.

The portable application is written to:

```text
dist/ipe-7.2.30-windows-x64/bin/ipe.exe
```

### 3. Start the local bridge

1. Run `dist\ipe-7.2.30-windows-x64\bin\ipe.exe`.
2. Open the diagram you want to work on.
3. Choose **Ipelets → AI collaboration (MCP) → Start local bridge**.

The bridge is stopped by default. **Connection details** in the same menu shows
its current status and the bundled MCP server path.

### 4. Connect an MCP client

The bundled Python server has no third-party Python dependencies. Configure
your MCP client to launch it over stdio, using an absolute path:

```json
{
  "mcpServers": {
    "ipe": {
      "command": "py",
      "args": [
        "-3",
        "C:\\absolute\\path\\to\\dist\\ipe-7.2.30-windows-x64\\mcp\\ipe_mcp_server.py"
      ]
    }
  }
}
```

Restart or reload the MCP client after changing its configuration. Then try:

```text
Inspect the active Ipe document and render its current page.
```

If Ipe is not reachable, the MCP tool response tells you how to start the
bridge.

## How it works

```mermaid
flowchart LR
    Agent["MCP-capable AI client"]
    Server["Python stdio server<br/>ipe_mcp_server.py"]
    Socket["Native WinSock bridge<br/>ipeui.dll"]
    Ipelet["Lua ipelet<br/>mcp.lua"]
    Document["Ipe document, renderer,<br/>UI, save and undo stack"]

    Agent <-->|"MCP JSON-RPC over stdio"| Server
    Server <-->|"Length-prefixed JSON<br/>127.0.0.1:49328"| Socket
    Socket <-->|"25 ms non-blocking poll"| Ipelet
    Ipelet <--> Document
```

The Python process is a protocol adapter. It publishes MCP tool definitions and
forwards tool calls to Ipe over a loopback-only socket. The native WinSock layer
uses non-blocking I/O so it never waits inside Ipe's event loop. A Lua ipelet
polls the bridge and performs every document operation on Ipe's UI thread.

This split keeps the MCP protocol out of the editor process while preserving
Ipe's native rendering, XML parsing, validation, and undo behavior. See
[Architecture](docs/ARCHITECTURE.md) for the request lifecycle and extension
points.

## Local security model

The project itself does not upload documents or expose a network service beyond
the Windows machine:

- the native server binds only to `127.0.0.1`;
- the bridge must be started explicitly from Ipe;
- it accepts one request at a time and is stopped when Ipe exits;
- no authentication token, account, or cloud service is required;
- the Python adapter communicates with the MCP client only through stdio.

> [!CAUTION]
> The loopback bridge is intentionally unauthenticated. While it is running,
> another local process that can connect to the port can request document reads,
> edits, or saves. Start it only while collaborating and choose **Stop local
> bridge** when finished. Do not proxy, forward, or expose the port.

Your chosen MCP client and AI provider have their own data-handling behavior;
review those separately before sharing sensitive diagrams.

The default port is `49328`. To change it, set `IPE_MCP_PORT` to the same value
for both Ipe and the Python MCP server before starting them.

## Build and test

The build script supports clean builds, dependency control, parallelism, and a
custom output directory:

```bash
./build-windows.sh --help
./build-windows.sh --clean --jobs 8
./build-windows.sh --skip-deps
./build-windows.sh --output ./dist/custom-ipe
```

After building, run the complete protocol and native integration suite:

```powershell
python -m unittest discover -s tests -v
```

The suite covers protocol discovery, tool schemas, stdio behavior, socket
framing, native WinSock communication, real Ipe object edits, and PNG rendering.
The build itself also launches `ipe.exe -show-configuration` without displaying
a window, catching failures in bundled resources and ipelets.

More detail is available in [Building and troubleshooting on
Windows](WINDOWS.md).

## Repository map

```text
build-windows.sh                   Native Windows build and bundle script
mcp/ipe_mcp_server.py             Dependency-free MCP stdio adapter
ipe-7.2.30/src/ipelets/lua/mcp.lua
                                   Ipe menu, tools, JSON codec, UI-thread dispatch
ipe-7.2.30/src/ipeui/ipeui_mcp_win.cpp
                                   Loopback-only non-blocking WinSock transport
tests/                             Protocol, renderer, object, and transport tests
docs/ARCHITECTURE.md               Internal design and extension guide
```

## Current scope

- Windows x64 only
- Ipe 7.2.30 source included for reproducible builds
- one active bridge per TCP port
- source distribution; compile the portable application locally

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and
please keep changes inside the current Windows-only scope.

## License and attribution

Ipe is copyright © 1993–2024 Otfried Cheong. Ipe and this modified distribution
are licensed under the GNU General Public License, version 3 or later, with
Ipe's documented CGAL linking exception. See [LICENSE](LICENSE) and the
[upstream Ipe README](ipe-7.2.30/README.md).
