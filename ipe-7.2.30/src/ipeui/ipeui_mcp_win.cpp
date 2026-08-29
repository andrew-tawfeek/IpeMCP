// --------------------------------------------------------------------
// Local transport used by the Ipe MCP ipelet on Windows.
// --------------------------------------------------------------------

#include <winsock2.h>
#include <ws2tcpip.h>

#include "ipeui_common.h"
#include "ipeui_mcp_win.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kMaxRequest = 16U * 1024U * 1024U;
constexpr size_t kMaxResponse = 64U * 1024U * 1024U;

struct McpBridgeState {
  SOCKET listener = INVALID_SOCKET;
  SOCKET client = INVALID_SOCKET;
  bool winsockStarted = false;
  bool requestReady = false;
  int port = 0;
  uint32_t expected = 0;
  std::vector<char> input;
  std::vector<char> output;
  size_t outputOffset = 0;

  ~McpBridgeState() { stop(); }

  bool running() const { return listener != INVALID_SOCKET; }

  void closeClient()
  {
    if (client != INVALID_SOCKET)
      closesocket(client);
    client = INVALID_SOCKET;
    requestReady = false;
    expected = 0;
    input.clear();
    output.clear();
    outputOffset = 0;
  }

  void stop()
  {
    closeClient();
    if (listener != INVALID_SOCKET)
      closesocket(listener);
    listener = INVALID_SOCKET;
    port = 0;
    if (winsockStarted)
      WSACleanup();
    winsockStarted = false;
  }
};

McpBridgeState bridge;

std::string socketError(const char *operation)
{
  return std::string(operation) + " failed (WinSock error "
    + std::to_string(WSAGetLastError()) + ")";
}

bool wouldBlock()
{
  int error = WSAGetLastError();
  return error == WSAEWOULDBLOCK || error == WSAEINPROGRESS;
}

void pushResult(lua_State *L, bool ok, const std::string &message)
{
  lua_pushboolean(L, ok);
  lua_pushlstring(L, message.data(), message.size());
}

bool makeNonBlocking(SOCKET socket)
{
  u_long enabled = 1;
  return ioctlsocket(socket, FIONBIO, &enabled) == 0;
}

void flushOutput()
{
  if (bridge.client == INVALID_SOCKET || bridge.output.empty())
    return;

  while (bridge.outputOffset < bridge.output.size()) {
    size_t remaining = bridge.output.size() - bridge.outputOffset;
    int amount = int(std::min(remaining,
      size_t(std::numeric_limits<int>::max())));
    int sent = send(bridge.client, bridge.output.data() + bridge.outputOffset,
                    amount, 0);
    if (sent == SOCKET_ERROR) {
      if (wouldBlock())
        return;
      bridge.closeClient();
      return;
    }
    if (sent == 0) {
      bridge.closeClient();
      return;
    }
    bridge.outputOffset += size_t(sent);
  }

  bridge.closeClient();
}

} // namespace

int ipeui_mcpStart(lua_State *L)
{
  int port = int(luaL_optinteger(L, 1, 49328));
  luaL_argcheck(L, 1024 <= port && port <= 65535, 1,
                "port must be between 1024 and 65535");

  if (bridge.running()) {
    if (bridge.port == port) {
      pushResult(L, true, "MCP bridge is already listening on 127.0.0.1:"
                 + std::to_string(port));
      return 2;
    }
    bridge.stop();
  }

  WSADATA data;
  int result = WSAStartup(MAKEWORD(2, 2), &data);
  if (result != 0) {
    WSASetLastError(result);
    pushResult(L, false, socketError("WSAStartup"));
    return 2;
  }
  bridge.winsockStarted = true;

  bridge.listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (bridge.listener == INVALID_SOCKET) {
    std::string message = socketError("socket");
    bridge.stop();
    pushResult(L, false, message);
    return 2;
  }

  BOOL exclusive = TRUE;
  setsockopt(bridge.listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
             reinterpret_cast<const char *>(&exclusive), sizeof(exclusive));

  sockaddr_in address;
  std::memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(u_short(port));

  if (bind(bridge.listener, reinterpret_cast<sockaddr *>(&address),
           sizeof(address)) == SOCKET_ERROR) {
    std::string message = socketError("bind");
    bridge.stop();
    pushResult(L, false, message);
    return 2;
  }
  if (listen(bridge.listener, 1) == SOCKET_ERROR) {
    std::string message = socketError("listen");
    bridge.stop();
    pushResult(L, false, message);
    return 2;
  }
  if (!makeNonBlocking(bridge.listener)) {
    std::string message = socketError("ioctlsocket");
    bridge.stop();
    pushResult(L, false, message);
    return 2;
  }

  bridge.port = port;
  pushResult(L, true, "MCP bridge listening locally on 127.0.0.1:"
             + std::to_string(port));
  return 2;
}

int ipeui_mcpStop(lua_State *L)
{
  bool wasRunning = bridge.running();
  bridge.stop();
  lua_pushboolean(L, wasRunning);
  return 1;
}

int ipeui_mcpPoll(lua_State *L)
{
  if (!bridge.running())
    return 0;

  flushOutput();
  if (bridge.client == INVALID_SOCKET) {
    bridge.client = accept(bridge.listener, nullptr, nullptr);
    if (bridge.client == INVALID_SOCKET) {
      if (!wouldBlock())
        bridge.closeClient();
      return 0;
    }
    if (!makeNonBlocking(bridge.client)) {
      bridge.closeClient();
      return 0;
    }
  }

  if (bridge.requestReady || !bridge.output.empty())
    return 0;

  char chunk[64 * 1024];
  for (;;) {
    int received = recv(bridge.client, chunk, sizeof(chunk), 0);
    if (received == SOCKET_ERROR) {
      if (wouldBlock())
        break;
      bridge.closeClient();
      return 0;
    }
    if (received == 0) {
      bridge.closeClient();
      return 0;
    }
    bridge.input.insert(bridge.input.end(), chunk, chunk + received);
    if (bridge.input.size() > size_t(kMaxRequest) + 4U) {
      bridge.closeClient();
      return 0;
    }
  }

  if (bridge.expected == 0 && bridge.input.size() >= 4) {
    const unsigned char *p =
      reinterpret_cast<const unsigned char *>(bridge.input.data());
    bridge.expected = uint32_t(p[0]) | (uint32_t(p[1]) << 8)
      | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
    if (bridge.expected == 0 || bridge.expected > kMaxRequest) {
      bridge.closeClient();
      return 0;
    }
  }

  if (bridge.expected != 0
      && bridge.input.size() >= size_t(bridge.expected) + 4U) {
    lua_pushlstring(L, bridge.input.data() + 4, bridge.expected);
    bridge.requestReady = true;
    return 1;
  }
  return 0;
}

int ipeui_mcpReply(lua_State *L)
{
  size_t length = 0;
  const char *payload = luaL_checklstring(L, 1, &length);
  if (bridge.client == INVALID_SOCKET || !bridge.requestReady) {
    pushResult(L, false, "there is no pending MCP request");
    return 2;
  }
  if (length == 0 || length > kMaxResponse) {
    bridge.closeClient();
    pushResult(L, false, "MCP response exceeds the transport limit");
    return 2;
  }

  uint32_t n = uint32_t(length);
  bridge.output.resize(length + 4U);
  bridge.output[0] = char(n & 0xff);
  bridge.output[1] = char((n >> 8) & 0xff);
  bridge.output[2] = char((n >> 16) & 0xff);
  bridge.output[3] = char((n >> 24) & 0xff);
  std::memcpy(bridge.output.data() + 4, payload, length);
  bridge.outputOffset = 0;
  bridge.requestReady = false;
  bridge.input.clear();
  bridge.expected = 0;
  flushOutput();
  pushResult(L, true, "response queued");
  return 2;
}

int ipeui_mcpStatus(lua_State *L)
{
  lua_createtable(L, 0, 6);
  lua_pushboolean(L, bridge.running());
  lua_setfield(L, -2, "running");
  lua_pushinteger(L, bridge.port);
  lua_setfield(L, -2, "port");
  lua_pushboolean(L, bridge.client != INVALID_SOCKET);
  lua_setfield(L, -2, "connected");
  lua_pushboolean(L, bridge.requestReady);
  lua_setfield(L, -2, "requestPending");
  lua_pushinteger(L, lua_Integer(bridge.output.size() - bridge.outputOffset));
  lua_setfield(L, -2, "outboundBytes");
  lua_pushliteral(L, "127.0.0.1");
  lua_setfield(L, -2, "host");
  return 1;
}
