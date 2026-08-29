local bundle_bin = assert(arg[1], "bundle bin directory is required")
local ipelet_path = assert(arg[2], "MCP ipelet path is required")
io.stdout:setvbuf("no")

assert(package.loadlib(bundle_bin .. "\\ipelua.dll", "luaopen_ipe"))()
print("STEP native library loaded")

IPE_MCP_TEST_MODE = true
function revertOriginal(transaction, document)
  document:set(transaction.pno, transaction.original)
end
local environment = {
  _G = _G,
  ipe = ipe,
  ipeui = {},
  math = math,
  string = string,
  table = table,
  assert = assert,
  shortcuts = {},
  prefs = { fsep = "\\" },
  config = {
    platform = "win",
    system_ipelets = "C:\\Ipe\\ipelets",
  },
  mouse = {},
  ipairs = ipairs,
  pairs = pairs,
  print = print,
  tonumber = tonumber,
  tostring = tostring,
}

assert(loadfile(ipelet_path, "t", environment))()
assert(environment.label == "AI collaboration (MCP)")
assert(#environment.methods == 3)
assert(environment.methods[1].label == "Start local bridge")
assert(environment.methods[2].label == "Stop local bridge")
assert(environment.methods[3].label == "Connection details")
print("STEP menu loaded")

local api = assert(environment.mcp_test)
local decoded = api.json_decode('{"unicode":"diagram \\u2713","empty":[],"n":2}')
assert(decoded.unicode == "diagram ✓")
assert(api.json_encode(decoded):match('"empty":%[%]'))
print("STEP JSON codec")

local model = {
  doc = ipe.Document(),
  pno = 1,
  vno = 1,
  undo = { { label = "initial" } },
  redo = {},
  file_name = nil,
}

function model:page()
  return self.doc[self.pno]
end

function model:selection()
  local selected = {}
  for index, _, selection in self:page():objects() do
    if selection then selected[#selected + 1] = index end
  end
  return selected
end

function model:isModified()
  return #self.undo > 1
end

function model:setPage()
end

function model:register(transaction)
  transaction.redo(transaction, self.doc)
  self.undo[#self.undo + 1] = transaction
  self.redo = {}
end

function model:action_undo()
  local transaction = assert(self.undo[#self.undo])
  assert(#self.undo > 1)
  self.undo[#self.undo] = nil
  transaction.undo(transaction, self.doc)
  self.redo[#self.redo + 1] = transaction
end

function model:action_redo()
  local transaction = assert(self.redo[#self.redo])
  self.redo[#self.redo] = nil
  transaction.redo(transaction, self.doc)
  self.undo[#self.undo + 1] = transaction
end

model.ui = {}
function model.ui:renderPage(_, _, _, _, path)
  local file = assert(io.open(path, "wb"))
  file:write("\137PNG\r\n\26\nheadless-test")
  file:close()
end

local info = api.tools.get_document_info(model, {})
assert(info.structuredContent.objectCount == 0)
assert(info.structuredContent.pageCount == 1)
print("STEP document inspected")

local added = api.tools.add_objects_xml(model, {
  xml = '<path stroke="black" pen="normal">0 0 m 100 0 l</path>',
})
assert(added.structuredContent.added == 1)
assert(#model:page() == 1)
assert(model:page()[1]:type() == "path")
print("STEP object added")

local listing = api.tools.list_objects(model, { include_xml = true })
assert(#listing.structuredContent.objects == 1)
assert(listing.structuredContent.objects[1].xml:match("<path"))
print("STEP objects listed")

api.tools.transform_objects(model, {
  indices = { 1 },
  matrix = { 1, 0, 0, 1, 25, 40 },
})
assert(#model:page() == 1)
print("STEP object transformed")

local page_xml = api.tools.get_page_xml(model, {})
assert(page_xml.structuredContent.xml:match("<ipepage"))
assert(page_xml.structuredContent.xml:match("matrix="))
print("STEP page XML read")

local rendered = api.tools.render_page(model, {})
assert(rendered.content[2].type == "image")
assert(rendered.content[2].mimeType == "image/png")
assert(rendered.content[2].data:sub(1, 8) == "iVBORw0K")
print("STEP page rendered")

api.tools.delete_objects(model, { indices = { 1 } })
assert(#model:page() == 0)
print("STEP object deleted")
api.tools.undo(model, {})
assert(#model:page() == 1)
print("STEP undo")
api.tools.redo(model, {})
assert(#model:page() == 0)
print("STEP redo")

IPE_MCP_TEST_MODE = nil
print("headless MCP ipelet: ok")
-- Do not close the standalone Lua state: unloading Ipelua outside its normal
-- host can wait on runtime teardown that Ipe itself owns until process exit.
os.exit(0, false)
