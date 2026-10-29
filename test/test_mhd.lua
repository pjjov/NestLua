-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- The lua-mhd adapter. The conversion/handler tests run everywhere; the
-- live server test only runs when lua-mhd is installed and `curl` exists.

local h = require "test.helper"
local nest = require "nestlua"
local json = require "nestlua.json"
local adapter = require "nestlua.mhd"
local check = h.check

--=====================================================--
-- Response conversion
--=====================================================--

local out = adapter.to_mhd({ code = 201, headers = { ["X-N"] = 5, ["X-L"] = { "a", "b" } }, body = { a = 1 } })
check("table bodies are JSON-encoded", out.body == '{"a":1}')
check("JSON content type is added", out.headers["Content-Type"] == "application/json; charset=utf-8")
check("numeric header values are stringified", out.headers["X-N"] == "5")
check("list header values are joined", out.headers["X-L"] == "a, b")
check("status is kept", out.code == 201)

out = adapter.to_mhd({ code = 200, headers = { ["content-type"] = "text/html" }, body = "<p>" })
check("explicit content type is respected", out.headers["Content-Type"] == nil and out.headers["content-type"] == "text/html")
out = adapter.to_mhd({ code = 204, headers = {} })
check("nil body becomes empty string", out.body == "")
out = adapter.to_mhd({ code = 200, headers = {}, file = "/x" })
check("file responses pass through", out.file == "/x" and out.body == nil)
out = adapter.to_mhd({ code = 200, headers = {}, body = { f = print } })
check("unencodable bodies become a 500", out.code == 500)

--=====================================================--
-- Request conversion + handler
--=====================================================--

local app = nest.module("app"):logger(false)
app:controller("C"):route("Echo"):post("/echo")
    :use_query("q")
    :use_body("name")
    :use_request()
    :handle(function(q, name, req) return { q = q, name = name, user = req.basic_auth and req.basic_auth.username } end)

local handler = adapter.handler(app)
local res = handler({
  method = "POST",
  url = "/echo",
  version = "HTTP/1.1",
  headers = { ["Content-Type"] = "application/json" },
  query = { q = "search" },
  body = '{"name":"Ada"}',
  basic_auth = { username = "alice" },
})
local decoded = json.decode(res.body)
check("handler decodes JSON bodies", decoded.name == "Ada", res.body)
check("handler uses lua-mhd's parsed query", decoded.q == "search")
check("handler passes auth fields through", decoded.user == "alice")
check("handler returns a lua-mhd response", res.code == 200 and type(res.body) == "string")

--=====================================================--
-- Worker bootstrap function
--=====================================================--

-- lua-mhd serializes the worker function to bytecode, so it may only
-- reference globals (_ENV on 5.2+, no upvalues at all on 5.1/LuaJIT).
local upvalues = {}
for i = 1, 10 do
  local name = debug.getupvalue(adapter.bootstrap, i)
  if not name then break end
  upvalues[#upvalues + 1] = name
end
check("bootstrap captures no locals", #upvalues == 0 or (#upvalues == 1 and upvalues[1] == "_ENV"),
  table.concat(upvalues, ","))
check("bootstrap is dumpable", pcall(string.dump, adapter.bootstrap))

local tmp = os.tmpname()
local f = assert(io.open(tmp .. ".lua", "w"))
f:write([[
local nest = require "nestlua"
return function(greeting)
  local m = nest.module("loaded")
  m:controller("C"):route("R"):get("/"):handle(function() return greeting end)
  return m
end
]])
f:close()
local loaded = adapter.load_app(tmp .. ".lua", "hi")
check("load_app runs app functions with the worker args", nest.is_module(loaded) and h.get(loaded, "/").body == "hi")
os.remove(tmp .. ".lua")
os.remove(tmp)

--=====================================================--
-- Live server (optional)
--=====================================================--

local has_mhd = pcall(require, "lua-mhd")
local has_curl = os.execute("command -v curl >/dev/null 2>&1")
if has_mhd and (has_curl == true or has_curl == 0) then
  local app_file = os.tmpname()
  local af = assert(io.open(app_file .. ".lua", "w"))
  af:write([[
local nest = require "nestlua"
return function(word)
  local m = nest.module("live")
  m:controller("C"):route("R"):post("/echo/:id"):use_param("id", nest.pipes.int):use_body("v")
    :handle(function(id, v) return { id = id, v = v, word = word } end)
  return m
end
]])
  af:close()
  local port = 20000 + (os.time() % 10000)
  local srv = adapter.listen({ port = port, single_thread = true }, app_file .. ".lua", "bird")
  local p = io.popen("curl -s -XPOST -H 'Content-Type: application/json' -d '{\"v\":3}' localhost:" .. port .. "/echo/9")
  local body = p:read("*a")
  p:close()
  srv:stop()
  os.remove(app_file .. ".lua")
  os.remove(app_file)
  local live = json.decode(body)
  check("live lua-mhd server round-trip", live and live.id == 9 and live.v == 3 and live.word == "bird", body)
else
  print("SKIP  live lua-mhd server test (lua-mhd or curl not available)")
end

h.done()
