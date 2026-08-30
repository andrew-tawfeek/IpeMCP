# Contributing

Thanks for helping make Ipe MCP more useful. The current project scope is a
native 64-bit Windows build based on Ipe 7.2.30.

## Development setup

Install MSYS2 at `C:\msys64`, Python 3.10 or newer, and either Git Bash, WSL, or
an MSYS2 UCRT64 shell. Then run:

```bash
./build-windows.sh --clean
```

The script installs missing MSYS2 packages unless `--skip-deps` is supplied.
Subsequent builds can normally omit `--clean`.

## Where to make changes

- MCP schemas and stdio protocol: `mcp/ipe_mcp_server.py`
- Tool behavior and Ipe menu: `ipe-7.2.30/src/ipelets/lua/mcp.lua`
- Native Windows transport: `ipe-7.2.30/src/ipeui/ipeui_mcp_win.cpp`
- Portable build: `build-windows.sh`
- Tests: `tests/`

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing the transport
or adding a tool.

## Test expectations

Run the full build first, then:

```powershell
python -m unittest discover -s tests -v
```

A change is ready when:

- the Windows bundle builds without warnings introduced by the change;
- the build's command-line and GUI-startup smoke tests pass;
- all protocol and native integration tests pass;
- new tool behavior has both schema and compiled-Ipe coverage;
- no build products, credentials, local paths, or generated caches are tracked.

## Design guidelines

- Keep the bridge loopback-only and stopped by default.
- Do not add an authentication, account, cloud, telemetry, or upload requirement.
- Never perform Ipe document work from a socket thread; tool calls belong on the
  Ipe UI thread.
- Use native Ipe XML and parsers instead of inventing a parallel object format.
- Register mutations with Ipe's undo stack.
- Keep the Python MCP adapter dependency-free when practical.
- Return actionable tool errors instead of terminating the server.
- Preserve upstream Ipe attribution and licensing notices.

## Pull requests

Keep pull requests focused and explain the user-visible result. Include the
Windows version, build command, and test output used for verification. Screenshots
or short recordings are useful for visual behavior, but never include private
documents, API keys, usernames, or machine-specific paths.

By contributing, you agree that your changes are distributed under the project
license described in [LICENSE](LICENSE).
