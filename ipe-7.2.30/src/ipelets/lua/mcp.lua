----------------------------------------------------------------------
-- Local Model Context Protocol bridge for Ipe on Windows
----------------------------------------------------------------------

label = "AI collaboration (MCP)"

about = [[
Expose the active Ipe window to a local MCP client. The bridge listens only
on 127.0.0.1 and must be started explicitly from the Ipelets menu.
]]

local type = _G.type
local error = _G.error
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local getmetatable = _G.getmetatable
local next = _G.next
local utf8 = _G.utf8
local os = _G.os
local io = _G.io
local revertOriginal = _G.revertOriginal

-- Ipe's locale-independent tonumber requires a string, unlike Lua's standard
-- tonumber(nil), so normalize an unset environment variable first.
local default_port = tonumber(os.getenv("IPE_MCP_PORT") or "") or 49328
if default_port < 1024 or default_port > 65535 then default_port = 49328 end

----------------------------------------------------------------------
-- Small, dependency-free JSON codec.  Decoded arrays carry a metatable so
-- an empty JSON array remains distinct from an empty JSON object.
----------------------------------------------------------------------

local array_metatable = { __json_array = true }

local function array(value)
  return setmetatable(value or {}, array_metatable)
end

local function decode_hex(value)
  local result = 0
  for index = 1, #value do
    local byte = string.byte(value, index)
    local digit
    if byte >= 48 and byte <= 57 then
      digit = byte - 48
    elseif byte >= 65 and byte <= 70 then
      digit = byte - 55
    elseif byte >= 97 and byte <= 102 then
      digit = byte - 87
    else
      return nil
    end
    result = result * 16 + digit
  end
  return result
end

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(ch)
    return escapes[ch] or string.format('\\u%04x', string.byte(ch))
  end) .. '"'
end

local function table_is_array(value)
  local mt = getmetatable(value)
  if mt and mt.__json_array then return true end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return false
    end
    count = count + 1
    if key > maximum then maximum = key end
  end
  return count > 0 and maximum == count
end

local function json_encode(value, seen)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("cannot encode a non-finite number")
    end
    return string.format("%.17g", value)
  elseif kind == "string" then
    return encode_string(value)
  elseif kind ~= "table" then
    error("cannot encode Lua value of type " .. kind)
  end

  seen = seen or {}
  if seen[value] then error("cannot encode a circular table") end
  seen[value] = true
  local parts = {}
  if table_is_array(value) then
    for i = 1, #value do parts[i] = json_encode(value[i], seen) end
    seen[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end

  for key, item in pairs(value) do
    if type(key) ~= "string" then error("JSON object keys must be strings") end
    parts[#parts + 1] = encode_string(key) .. ":" .. json_encode(item, seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

local function json_decode(text)
  local position = 1
  local length = #text

  local function fail(message)
    error(string.format("JSON error at byte %d: %s", position, message))
  end

  local function skip_space()
    local _, finish = text:find("^[ \t\r\n]*", position)
    position = (finish or position - 1) + 1
  end

  local parse_value

  local function parse_string()
    if text:sub(position, position) ~= '"' then fail("expected string") end
    position = position + 1
    local parts = {}
    local start = position
    while position <= length do
      local ch = text:sub(position, position)
      if ch == '"' then
        parts[#parts + 1] = text:sub(start, position - 1)
        position = position + 1
        return table.concat(parts)
      elseif ch == "\\" then
        parts[#parts + 1] = text:sub(start, position - 1)
        local escaped = text:sub(position + 1, position + 1)
        local simple = {
          ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f',
          n = '\n', r = '\r', t = '\t',
        }
        if simple[escaped] then
          parts[#parts + 1] = simple[escaped]
          position = position + 2
        elseif escaped == "u" then
          local hex = text:sub(position + 2, position + 5)
          local codepoint = decode_hex(hex)
          if #hex ~= 4 or not codepoint then fail("invalid unicode escape") end
          position = position + 6
          if codepoint >= 0xd800 and codepoint <= 0xdbff
             and text:sub(position, position + 1) == "\\u" then
            local low = decode_hex(text:sub(position + 2, position + 5))
            if low and low >= 0xdc00 and low <= 0xdfff then
              codepoint = 0x10000 + (codepoint - 0xd800) * 0x400
                + (low - 0xdc00)
              position = position + 6
            end
          end
          parts[#parts + 1] = utf8.char(codepoint)
        else
          fail("invalid string escape")
        end
        start = position
      elseif string.byte(ch) < 32 then
        fail("unescaped control character")
      else
        position = position + 1
      end
    end
    fail("unterminated string")
  end

  local function parse_array()
    position = position + 1
    local result = array()
    skip_space()
    if text:sub(position, position) == "]" then
      position = position + 1
      return result
    end
    while true do
      result[#result + 1] = parse_value()
      skip_space()
      local ch = text:sub(position, position)
      if ch == "]" then
        position = position + 1
        return result
      elseif ch ~= "," then
        fail("expected ',' or ']'")
      end
      position = position + 1
      skip_space()
    end
  end

  local function parse_object()
    position = position + 1
    local result = {}
    skip_space()
    if text:sub(position, position) == "}" then
      position = position + 1
      return result
    end
    while true do
      local key = parse_string()
      skip_space()
      if text:sub(position, position) ~= ":" then fail("expected ':'") end
      position = position + 1
      skip_space()
      result[key] = parse_value()
      skip_space()
      local ch = text:sub(position, position)
      if ch == "}" then
        position = position + 1
        return result
      elseif ch ~= "," then
        fail("expected ',' or '}'")
      end
      position = position + 1
      skip_space()
    end
  end

  function parse_value()
    skip_space()
    local ch = text:sub(position, position)
    if ch == '"' then return parse_string() end
    if ch == "[" then return parse_array() end
    if ch == "{" then return parse_object() end
    if text:sub(position, position + 3) == "true" then
      position = position + 4
      return true
    end
    if text:sub(position, position + 4) == "false" then
      position = position + 5
      return false
    end
    if text:sub(position, position + 3) == "null" then
      position = position + 4
      return nil
    end
    local token = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", position)
    if token and token ~= "" then
      local value = tonumber(token)
      if not value then fail("invalid number") end
      position = position + #token
      return value
    end
    fail("unexpected token")
  end

  local result = parse_value()
  skip_space()
  if position <= length then fail("trailing content") end
  return result
end

----------------------------------------------------------------------
-- Tool helpers
----------------------------------------------------------------------

local function require_table(value, name)
  if type(value) ~= "table" then error(name .. " must be an object") end
  return value
end

local function require_string(value, name)
  if type(value) ~= "string" or value == "" then
    error(name .. " must be a non-empty string")
  end
  return value
end

local function require_integer(value, name, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value)
     or (minimum and value < minimum) or (maximum and value > maximum) then
    error(name .. " is outside the valid integer range")
  end
  return value
end

local function page_number(model, args)
  local pno = args.page or model.pno
  return require_integer(pno, "page", 1, #model.doc)
end

local function layer_exists(page, wanted)
  for _, layer in ipairs(page:layers()) do
    if layer == wanted then return true end
  end
  return false
end

local function successful_result(data, summary)
  local text = summary
  if data then text = text .. "\n" .. json_encode(data) end
  return {
    content = array({ { type = "text", text = text } }),
    structuredContent = data or {},
    isError = false,
  }
end

local function register_page_edit(model, label_text, fields, redo)
  local transaction = fields or {}
  transaction.label = label_text
  transaction.pno = model.pno
  transaction.vno = model.vno
  transaction.original = model:page():clone()
  transaction.undo = revertOriginal
  transaction.redo = redo
  model:register(transaction)
end

local base64_alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
  local result = {}
  for i = 1, #data, 3 do
    local a = string.byte(data, i) or 0
    local b = string.byte(data, i + 1) or 0
    local c = string.byte(data, i + 2) or 0
    local value = a * 65536 + b * 256 + c
    local remaining = #data - i + 1
    result[#result + 1] = base64_alphabet:sub(math.floor(value / 262144) % 64 + 1,
                                              math.floor(value / 262144) % 64 + 1)
    result[#result + 1] = base64_alphabet:sub(math.floor(value / 4096) % 64 + 1,
                                              math.floor(value / 4096) % 64 + 1)
    result[#result + 1] = remaining > 1 and
      base64_alphabet:sub(math.floor(value / 64) % 64 + 1,
                          math.floor(value / 64) % 64 + 1) or "="
    result[#result + 1] = remaining > 2 and
      base64_alphabet:sub(value % 64 + 1, value % 64 + 1) or "="
  end
  return table.concat(result)
end

----------------------------------------------------------------------
-- MCP tool implementations. All mutations are run on Ipe's UI thread and
-- registered with the normal document undo stack.
----------------------------------------------------------------------

local tools = {}

tools.get_document_info = function(model, args)
  local page = model:page()
  local properties = model.doc:properties()
  return successful_result({
    fileName = model.file_name or "",
    modified = model:isModified(),
    pageCount = #model.doc,
    currentPage = model.pno,
    currentView = model.vno,
    viewCount = page:countViews(),
    objectCount = #page,
    layers = array(page:layers()),
    activeLayer = page:active(model.vno),
    selectedObjects = array(model:selection()),
    title = properties.title,
  }, "Read the active Ipe document state.")
end

tools.list_objects = function(model, args)
  local pno = page_number(model, args)
  local page = model.doc[pno]
  local include_xml = args.include_xml == true
  local objects = array()
  for index, object, selection, layer in page:objects() do
    local item = {
      index = index,
      type = object:type(),
      layer = layer,
      selection = selection or 0,
    }
    if object:type() == "text" then item.text = object:text() end
    if include_xml then item.xml = object:xml() end
    objects[#objects + 1] = item
  end
  return successful_result({ page = pno, objects = objects },
                           "Listed the objects on the requested page.")
end

tools.get_page_xml = function(model, args)
  local pno = page_number(model, args)
  return successful_result({ page = pno, xml = model.doc[pno]:xml("ipepage") },
                           "Read the canonical Ipe XML for the page.")
end

tools.get_selection_xml = function(model, args)
  return successful_result({
    page = model.pno,
    objectIndices = array(model:selection()),
    xml = model:page():xml("ipeselection"),
  }, "Read the active selection as canonical Ipe XML.")
end

tools.render_page = function(model, args)
  local pno = page_number(model, args)
  local page = model.doc[pno]
  local vno = args.view or (pno == model.pno and model.vno or 1)
  require_integer(vno, "view", 1, page:countViews())
  local zoom = args.zoom or 1.5
  if type(zoom) ~= "number" or zoom < 0.1 or zoom > 8 then
    error("zoom must be between 0.1 and 8")
  end
  local path = os.tmpname() .. ".png"
  local ok, message = pcall(function()
    model.ui:renderPage(model.doc, pno, vno, "png", path, zoom,
                        args.transparent == true, args.nocrop == true)
  end)
  if not ok then
    os.remove(path)
    error("could not render page: " .. tostring(message))
  end
  local file = ipe.openFile(path, "rb")
  if not file then
    os.remove(path)
    error("Ipe did not produce the rendered PNG")
  end
  local bytes = file:read("*a")
  file:close()
  os.remove(path)
  return {
    content = array({
      { type = "text", text = string.format("Rendered Ipe page %d, view %d.", pno, vno) },
      { type = "image", mimeType = "image/png", data = base64_encode(bytes) },
    }),
    structuredContent = { page = pno, view = vno, mimeType = "image/png" },
    isError = false,
  }
end

tools.add_objects_xml = function(model, args)
  local xml = require_string(args.xml, "xml")
  local parsed, parsed_layers = ipe.Object(xml)
  if not parsed then error("xml is not a valid Ipe object or selection") end
  local objects
  local layers
  if type(parsed) == "table" then
    objects = parsed
    layers = parsed_layers
    if #objects == 0 then error("the Ipe selection contains no objects") end
  else
    objects = array({ parsed })
    layers = array({ model:page():active(model.vno) })
  end

  local override = args.layer
  if override ~= nil then require_string(override, "layer") end
  local final_layers = array()
  for i = 1, #objects do
    local layer = override or layers[i] or model:page():active(model.vno)
    if not layer_exists(model:page(), layer) then
      error("layer does not exist: " .. layer)
    end
    final_layers[i] = layer
  end

  register_page_edit(model, "MCP: add diagram objects", {
    objects = objects,
    layers = final_layers,
  }, function(transaction, document)
    local page = document[transaction.pno]
    page:deselectAll()
    for i, object in ipairs(transaction.objects) do
      page:insert(nil, object, i == 1 and 1 or 2, transaction.layers[i])
    end
  end)
  return successful_result({ added = #objects, page = model.pno },
                           "Added Ipe objects. The edit is undoable.")
end

tools.replace_object_xml = function(model, args)
  local index = require_integer(args.index, "index", 1, #model:page())
  local object = ipe.Object(require_string(args.xml, "xml"))
  if not object or type(object) == "table" then
    error("xml must contain exactly one Ipe object")
  end
  register_page_edit(model, "MCP: replace diagram object", {
    index = index,
    object = object,
  }, function(transaction, document)
    document[transaction.pno]:replace(transaction.index, transaction.object)
  end)
  return successful_result({ replaced = index, page = model.pno },
                           "Replaced the Ipe object. The edit is undoable.")
end

tools.delete_objects = function(model, args)
  local indices = require_table(args.indices, "indices")
  if #indices == 0 then error("indices must contain at least one object index") end
  local unique = {}
  local sorted = array()
  for _, value in ipairs(indices) do
    local index = require_integer(value, "object index", 1, #model:page())
    if not unique[index] then
      unique[index] = true
      sorted[#sorted + 1] = index
    end
  end
  table.sort(sorted, function(a, b) return a > b end)
  register_page_edit(model, "MCP: delete diagram objects", { indices = sorted },
    function(transaction, document)
      local page = document[transaction.pno]
      for _, index in ipairs(transaction.indices) do page:remove(index) end
    end)
  return successful_result({ deleted = #sorted, page = model.pno },
                           "Deleted Ipe objects. The edit is undoable.")
end

tools.set_object_text = function(model, args)
  local index = require_integer(args.index, "index", 1, #model:page())
  local value = require_string(args.text, "text")
  local object_type = model:page()[index]:type()
  if object_type ~= "text" and object_type ~= "group" then
    error("the requested object is not text (or a group URL)")
  end
  register_page_edit(model, "MCP: edit object text", {
    index = index,
    text = value,
  }, function(transaction, document)
    document[transaction.pno][transaction.index]:setText(transaction.text)
  end)
  return successful_result({ index = index, page = model.pno, text = value },
                           "Updated object text. The edit is undoable.")
end

tools.transform_objects = function(model, args)
  local indices = require_table(args.indices, "indices")
  local coefficients = require_table(args.matrix, "matrix")
  if #indices == 0 then error("indices must contain at least one object index") end
  if #coefficients ~= 6 then
    error("matrix must be [a, b, c, d, e, f]")
  end
  local checked = array()
  for _, value in ipairs(indices) do
    checked[#checked + 1] = require_integer(value, "object index", 1, #model:page())
  end
  for i = 1, 6 do
    if type(coefficients[i]) ~= "number" then error("matrix entries must be numbers") end
  end
  local matrix = ipe.Matrix(table.unpack(coefficients))
  register_page_edit(model, "MCP: transform diagram objects", {
    indices = checked,
    matrix = matrix,
  }, function(transaction, document)
    local page = document[transaction.pno]
    for _, index in ipairs(transaction.indices) do
      page:transform(index, transaction.matrix)
    end
  end)
  return successful_result({ transformed = checked, page = model.pno },
                           "Transformed Ipe objects. The edit is undoable.")
end

tools.replace_page_xml = function(model, args)
  local replacement = ipe.Page(require_string(args.xml, "xml"))
  if not replacement then error("xml is not a valid Ipe page") end
  model.vno = math.min(model.vno, replacement:countViews())
  register_page_edit(model, "MCP: replace diagram page", {
    final = replacement,
  }, function(transaction, document)
    document:set(transaction.pno, transaction.final)
  end)
  return successful_result({ page = model.pno, objectCount = #replacement },
                           "Replaced the current page. The edit is undoable.")
end

tools.select_objects = function(model, args)
  local indices = require_table(args.indices, "indices")
  local page = model:page()
  page:deselectAll()
  for i, value in ipairs(indices) do
    local index = require_integer(value, "object index", 1, #page)
    page:setSelect(index, i == 1 and 1 or 2)
  end
  model:setPage()
  return successful_result({ selected = array(model:selection()), page = model.pno },
                           "Updated the active Ipe selection.")
end

tools.set_current_view = function(model, args)
  local pno = require_integer(args.page, "page", 1, #model.doc)
  local vno = args.view or 1
  require_integer(vno, "view", 1, model.doc[pno]:countViews())
  model.pno = pno
  model.vno = vno
  model:setPage()
  return successful_result({ page = pno, view = vno },
                           "Changed the active Ipe page and view.")
end

tools.undo = function(model, args)
  if #model.undo <= 1 then error("there is no edit to undo") end
  model:action_undo()
  return successful_result({ page = model.pno, view = model.vno },
                           "Undid the most recent Ipe edit.")
end

tools.redo = function(model, args)
  if #model.redo == 0 then error("there is no edit to redo") end
  model:action_redo()
  return successful_result({ page = model.pno, view = model.vno },
                           "Redid the most recently undone Ipe edit.")
end

tools.save_document = function(model, args)
  local path = args.path or model.file_name
  path = require_string(path, "path")
  if not model:saveDocument(path) then error("Ipe could not save the document") end
  return successful_result({ path = model.file_name }, "Saved the Ipe document.")
end

----------------------------------------------------------------------
-- Menu and transport lifecycle
----------------------------------------------------------------------

local bridge = { model = nil, timer = nil, port = default_port }

function bridge:tick()
  local payload = ipeui.pollMcpBridge()
  if not payload then return end

  local ok, request = pcall(json_decode, payload)
  local response
  if not ok then
    response = { ok = false, error = tostring(request) }
  elseif type(request) ~= "table" or type(request.name) ~= "string" then
    response = { ok = false, error = "bridge request must contain a tool name" }
  elseif not tools[request.name] then
    response = { ok = false, error = "unknown Ipe tool: " .. request.name }
  elseif not self.model then
    response = { ok = false, error = "no Ipe window is attached to the bridge" }
  else
    self.model.ui:explain("MCP: " .. request.name)
    local called, result = pcall(tools[request.name], self.model,
                                 request.arguments or {})
    if called then
      response = { ok = true, result = result }
    else
      response = { ok = false, error = tostring(result) }
    end
  end

  local encoded, reply = pcall(json_encode, response)
  if not encoded then
    reply = json_encode({ ok = false, error = "could not encode bridge response: "
                          .. tostring(reply) })
  end
  ipeui.replyMcpBridge(reply)
end

local function start_bridge(model)
  if config.platform ~= "win" or not ipeui.startMcpBridge then
    model:warning("MCP bridge unavailable",
                  "This bridge is included in the native Windows build of Ipe.")
    return
  end
  bridge.model = model
  local ok, message = ipeui.startMcpBridge(bridge.port)
  if not ok then
    model:warning("Could not start the MCP bridge", message)
    return
  end
  if not bridge.timer then
    bridge.timer = ipeui.Timer(bridge, "tick")
    bridge.timer:setInterval(25)
  end
  if not bridge.timer:active() then bridge.timer:start() end
  model.ui:explain(message)
end

local function stop_bridge(model)
  if bridge.timer and bridge.timer:active() then bridge.timer:stop() end
  local stopped = ipeui.stopMcpBridge and ipeui.stopMcpBridge()
  bridge.model = nil
  model.ui:explain(stopped and "MCP bridge stopped" or "MCP bridge was not running")
end

local function bridge_details(model)
  if not ipeui.mcpBridgeStatus then
    model:warning("MCP bridge unavailable",
                  "This bridge is included in the native Windows build of Ipe.")
    return
  end
  local status = ipeui.mcpBridgeStatus()
  local root = config.system_ipelets:match("^(.*)[/\\]ipelets$") or "<Ipe folder>"
  local server = root .. prefs.fsep .. "mcp" .. prefs.fsep .. "ipe_mcp_server.py"
  local details = string.format(
    "Status: %s\nEndpoint: 127.0.0.1:%d (local only)\n\nMCP server command:\npy -3 \"%s\"\n\nStart this bridge before connecting your MCP client.",
    status.running and "running" or "stopped", bridge.port, server)
  ipeui.messageBox(model.ui:win(), "information", "Ipe MCP bridge", details)
end

methods = {
  { label = "Start local bridge", run = start_bridge },
  { label = "Stop local bridge", run = stop_bridge },
  { label = "Connection details", run = bridge_details },
}

function run(model, num)
  methods[num or 1].run(model)
end

-- Headless regression tests opt into these internals. They are never exposed
-- in a normal Ipe process.
if _G.IPE_MCP_TEST_MODE then
  mcp_test = {
    array = array,
    json_encode = json_encode,
    json_decode = json_decode,
    tools = tools,
  }
end
