local dll_path = assert(arg[1], "ipeui DLL path is required")
local port = assert(tonumber(arg[2]), "port is required")

assert(package.loadlib(dll_path, "_Z13luaopen_ipeuiP9lua_State"))()
local ok, message = ipeui.startMcpBridge(port)
assert(ok, message)

io.stdout:setvbuf("no")
print("READY")

local deadline = os.clock() + 15
while os.clock() < deadline do
  local request = ipeui.pollMcpBridge()
  if request then
    assert(request:match('"name":"get_document_info"'))
    local reply = [[{"ok":true,"result":{"content":[{"type":"text","text":"native bridge replied"}],"structuredContent":{"transport":"winsock"},"isError":false}}]]
    local replied, reply_message = ipeui.replyMcpBridge(reply)
    assert(replied, reply_message)
    ipeui.stopMcpBridge()
    print("REPLIED")
    os.exit(0, false)
  end
end

ipeui.stopMcpBridge()
io.stderr:write("timed out waiting for the Python MCP adapter\n")
os.exit(1, false)
