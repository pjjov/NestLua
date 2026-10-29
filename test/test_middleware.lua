-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

local h = require "test.helper"
local nest = require "nestlua"
local json = require "nestlua.json"
local middleware = require "nestlua.middleware"
local check = h.check

local function post(mod, ctype, body, extra)
  local headers = { ["Content-Type"] = ctype }
  for k, v in pairs(extra or {}) do headers[k] = v end
  return mod:handle({ method = "POST", url = "/echo", headers = headers, body = body })
end

--=====================================================--
-- body_parser
--=====================================================--

local m = h.module("body"):use(middleware.body_parser({ limit = 2000 }))
local c = m:controller("C")
c:route("Echo"):post("/echo"):use_request():handle(function(req)
  return { body = req.body, files = req.files }
end)

local r = post(m, "application/json; charset=utf-8", '{"a":1,"b":[true]}')
check("JSON bodies are decoded", r.code == 200 and r.body.body.a == 1 and r.body.body.b[1] == true, r.code)
r = post(m, "application/vnd.api+json", '{"x":1}')
check("+json media types are decoded", r.body.body.x == 1)
r = post(m, "application/json", "{nope")
check("invalid JSON -> 400", r.code == 400 and r.body:find("Invalid JSON", 1, true) ~= nil, r.body)
r = post(m, "application/x-www-form-urlencoded", "name=Ada+L&tag=a&tag=b")
check("urlencoded bodies are decoded", r.body.body.name == "Ada L" and r.body.body.tag[2] == "b")
r = post(m, "text/plain", "hello")
check("other content types are left alone", r.body.body == "hello")
r = post(m, "application/json", string.rep(" ", 2001))
check("bodies over the limit -> 413", r.code == 413, r.code)
r = m:handle({ method = "POST", url = "/echo", headers = { ["Content-Type"] = "application/json" }, body = { already = 1 } })
check("already-decoded bodies are passed through", r.body.body.already == 1)

local boundary = "XyZ123"
local multipart = table.concat({
  "--" .. boundary,
  'Content-Disposition: form-data; name="title"',
  "",
  "My file",
  "--" .. boundary,
  'Content-Disposition: form-data; name="doc"; filename="a.txt"',
  "Content-Type: text/plain",
  "",
  "line1\r\nline2",
  "--" .. boundary .. "--",
  "",
}, "\r\n")
r = post(m, "multipart/form-data; boundary=" .. boundary, multipart)
check("multipart fields are decoded", r.code == 200 and r.body.body.title == "My file", r.code)
check("multipart files are exposed on req.files", r.body.files.doc.filename == "a.txt"
  and r.body.files.doc.data == "line1\r\nline2" and r.body.files.doc.size == 12
  and r.body.files.doc.content_type == "text/plain")
r = post(m, "multipart/form-data; boundary=" .. boundary, "garbage")
check("malformed multipart -> 400", r.code == 400)
r = post(m, "multipart/form-data", multipart)
check("multipart without boundary -> 400", r.code == 400)

local up = h.module("upload"):use(middleware.body_parser())
up:controller("U"):route("Up"):post("/echo"):use_file("doc"):use_body("title")
    :handle(function(file, title) return { name = file.filename, title = title } end)
r = post(up, "multipart/form-data; boundary=" .. boundary, multipart)
check("use_file() injects uploaded files", r.body.name == "a.txt" and r.body.title == "My file")

--=====================================================--
-- cors
--=====================================================--

local cm = h.module("cors"):use(middleware.cors({
  origin = { "https://good.example" }, credentials = true, max_age = 600, expose = { "X-Total" },
}))
cm:controller("C"):route("R"):get("/r"):handle(function() return "ok" end)

r = cm:handle({ method = "OPTIONS", url = "/r", headers = {
  Origin = "https://good.example", ["Access-Control-Request-Method"] = "GET",
  ["Access-Control-Request-Headers"] = "X-Token" } })
check("preflight answered with 204", r.code == 204, r.code)
check("preflight echoes the allowed origin", r.headers["Access-Control-Allow-Origin"] == "https://good.example")
check("preflight lists methods", r.headers["Access-Control-Allow-Methods"]:find("GET", 1, true) ~= nil)
check("preflight echoes requested headers", r.headers["Access-Control-Allow-Headers"] == "X-Token")
check("preflight max-age", r.headers["Access-Control-Max-Age"] == "600")
r = cm:handle({ method = "GET", url = "/r", headers = { Origin = "https://good.example" } })
check("simple requests get CORS headers", r.headers["Access-Control-Allow-Credentials"] == "true"
  and r.headers["Access-Control-Expose-Headers"] == "X-Total" and r.headers.Vary == "Origin")
r = cm:handle({ method = "GET", url = "/r", headers = { Origin = "https://evil.example" } })
check("disallowed origins get no CORS headers", r.headers["Access-Control-Allow-Origin"] == nil)

local any = h.module("cors-any"):use(middleware.cors())
any:controller("C"):route("R"):get("/r"):handle(function() return "ok" end)
r = any:handle({ method = "GET", url = "/r", headers = { Origin = "https://x" } })
check("default origin is *", r.headers["Access-Control-Allow-Origin"] == "*")

--=====================================================--
-- request_id / logger
--=====================================================--

local lines = {}
local rid = h.module("rid"):use(middleware.request_id(), middleware.logger({
  write = function(line) lines[#lines + 1] = line end,
}))
rid:controller("C"):route("R"):get("/r"):use_custom(function(ctx) return ctx.request_id end)
    :handle(function(id) return id end)

r = h.get(rid, "/r")
check("request_id generates a UUID v4", nest.pipes.uuid(4):parse(r.body) == true, r.body)
check("request_id echoes the id", r.headers["X-Request-Id"] == r.body)
r = h.get(rid, "/r", { ["X-Request-Id"] = "abc-123" })
check("request_id reuses an incoming id", r.body == "abc-123")
check("logger writes one line per request", #lines == 2 and lines[2]:find("^GET /r 200") ~= nil, lines[2])

check("json helper module loads", json.encode({}) == "{}")

h.done()
