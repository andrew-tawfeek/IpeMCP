// -*- C++ -*-
#ifndef IPEUI_MCP_WIN_H
#define IPEUI_MCP_WIN_H

struct lua_State;

int ipeui_mcpStart(lua_State *L);
int ipeui_mcpStop(lua_State *L);
int ipeui_mcpPoll(lua_State *L);
int ipeui_mcpReply(lua_State *L);
int ipeui_mcpStatus(lua_State *L);

#endif
