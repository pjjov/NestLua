-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

local h = require "test.helper"
local nest = require "nestlua"
local check, raises, get = h.check, h.raises, h.get

local function echo_params(ctx) return ctx.params end

--=====================================================--
-- 405 / HEAD / OPTIONS / all()
--=====================================================--

local m = h.module("methods")
local c = m:controller("C")
c:route("Get"):get("/items"):handle(function() return "list" end)
c:route("Post"):post("/items"):handle(function() return "created" end)
c:route("Any"):all("/any"):use_request():handle(function(req) return req.method end)
c:route("OnlyPut"):put("/any"):handle(function() return "put-specific" end)

local r = m:handle({ method = "DELETE", url = "/items" })
check("unmatched method on known path -> 405", r.code == 405, r.code)
check("405 carries an Allow header", r.headers.Allow == "GET, POST, HEAD, OPTIONS", r.headers.Allow)

r = m:handle({ method = "HEAD", url = "/items" })
check("HEAD falls back to the GET route", r.code == 200, r.code)
check("HEAD response has no body", r.body == nil, r.body)

r = m:handle({ method = "OPTIONS", url = "/items" })
check("automatic OPTIONS -> 204", r.code == 204, r.code)
check("automatic OPTIONS lists allowed methods", r.headers.Allow == "GET, POST, HEAD, OPTIONS", r.headers.Allow)

r = m:handle({ method = "OPTIONS", url = "/nope" })
check("OPTIONS on unknown path -> 404", r.code == 404, r.code)

check("all() matches any method", m:handle({ method = "PATCH", url = "/any" }).body == "PATCH")
check("per-method route beats all()", m:handle({ method = "PUT", url = "/any" }).body == "put-specific")

--=====================================================--
-- Specificity ranking (registration order no longer matters)
--=====================================================--

local rank = h.module("rank")
local rc = rank:controller("Users"):use_prefix("/users")
rc:route("Wild"):get("/*"):handle(function() return "wildcard" end)
rc:route("ById"):get("/:id"):handle(function() return "param" end)
rc:route("Digits"):get("/:id(%d+)"):handle(function() return "digits" end)
rc:route("Me"):get("/me"):handle(function() return "literal" end)

check("literal beats params registered earlier", get(rank, "/users/me").body == "literal")
check("constrained param beats plain param", get(rank, "/users/42").body == "digits")
check("plain param used when constraint fails", get(rank, "/users/abc").body == "param")
check("wildcard is the last resort", get(rank, "/users/a/b").body == "wildcard")

--=====================================================--
-- Path syntax: optional params, constraints, named wildcards, decoding
--=====================================================--

local p = h.module("paths")
local pc = p:controller("P")
pc:route("Opt"):get("/opt/:a/:b?"):use_custom(echo_params):handle(function(x) return x end)
pc:route("Named"):get("/files/*path"):use_custom(echo_params):handle(function(x) return x end)
pc:route("Dec"):get("/dec/:v"):use_param("v"):handle(function(v) return v end)

r = get(p, "/opt/1")
check("optional param may be absent", r.code == 200 and r.body.a == "1" and r.body.b == nil, r.code)
r = get(p, "/opt/1/2")
check("optional param captured when present", r.body.b == "2")
check("too many segments still 404", get(p, "/opt/1/2/3").code == 404)

r = get(p, "/files/a/b%20c.txt")
check("named wildcard captured", r.body.path == "a/b c.txt", r.body.path)
check("named wildcard also in params['*']", r.body["*"] == "a/b c.txt")

check("'+' is literal in path params", get(p, "/dec/a+b").body == "a+b", get(p, "/dec/a+b").body)
check("percent-decoding in path params", get(p, "/dec/a%2Fb").body == "a/b")

check("wildcard in the middle is rejected",
  raises(function() h.module("x"):controller("c"):route("r"):get("/a/*/b") end, "must be the last segment"))
check("required segment after optional is rejected",
  raises(function() h.module("x"):controller("c"):route("r"):get("/a/:b?/:c") end, "cannot follow an optional"))
check("invalid param constraint pattern is rejected",
  raises(function() h.module("x"):controller("c"):route("r"):get("/a/:b([)") end))

--=====================================================--
-- Duplicate detection
--=====================================================--

local dup = h.module("dup")
local dc = dup:controller("D")
dc:route("A"):get("/x/:id"):handle(function() end)
dc:route("B"):get("/x/:name"):handle(function() end)
check("conflicting routes are reported at build()", raises(function() dup:build() end, "duplicate route"))

local nodup = h.module("nodup")
local ndc = nodup:controller("D")
ndc:route("A"):get("/x/:id"):handle(function() end)
ndc:route("B"):post("/x/:id"):handle(function() end)
check("same path with different methods is fine", not raises(function() nodup:build() end))

--=====================================================--
-- Late routes and rebuilds
--=====================================================--

local late = h.module("late")
local lc = late:controller("L")
lc:route("First"):get("/first"):handle(function() return 1 end)
check("first route works", get(late, "/first").code == 200)
lc:route("Second"):get("/second"):handle(function() return 2 end)
check("route added after the first request is served", get(late, "/second").code == 200)
lc:guard(function() return false, "late guard" end)
check("guard added later applies too", get(late, "/first").code == 403)

--=====================================================--
-- Global prefix and versioning
--=====================================================--

local api = h.module("api"):use_prefix("/api")
local vc = api:controller("Things"):use_prefix("/things"):version("1")
vc:route("List"):get("/"):handle(function() return "v1" end)
vc:route("ListV2"):get("/"):version("2"):handle(function() return "v2" end)
vc:route("Both"):get("/both"):version("1", "2"):handle(function() return "both" end)
api:controller("Plain"):route("Ping"):get("/ping"):handle(function() return "pong" end)

check("global prefix applies", get(api, "/api/ping").body == "pong")
check("controller version prefix", get(api, "/api/v1/things").body == "v1")
check("route version overrides controller", get(api, "/api/v2/things").body == "v2")
check("route served under several versions",
  get(api, "/api/v1/things/both").body == "both" and get(api, "/api/v2/things/both").body == "both")
api:versioning("version-")
check("custom version prefix", get(api, "/api/version-1/things").body == "v1")

--=====================================================--
-- Response decorators and nest.response / file / stream
--=====================================================--

local resp = h.module("resp")
local rsc = resp:controller("R")
rsc:route("Created"):post("/c"):status(201):header("X-Kind", "created"):handle(function() return { ok = true } end)
rsc:route("Full"):get("/full"):handle(function()
  return nest.response({ code = 202, headers = { ["X-A"] = "1" }, body = "accepted" })
end)
rsc:route("File"):get("/file"):handle(function()
  return nest.file("/tmp/report.pdf", { content_type = "application/pdf", filename = "report.pdf" })
end)
rsc:route("Stream"):get("/stream"):handle(function()
  local n = 0
  return nest.stream(function()
    n = n + 1
    if n <= 2 then return "chunk" .. n end
  end, { content_type = "text/plain" })
end)

r = resp:handle({ method = "POST", url = "/c" })
check("route:status sets the success code", r.code == 201, r.code)
check("route:header sets a response header", r.headers["X-Kind"] == "created")
r = get(resp, "/full")
check("nest.response replaces code/headers/body",
  r.code == 202 and r.headers["X-A"] == "1" and r.body == "accepted", r.code)
check("nest.response marker is not leaked", r.__class == nil)
r = get(resp, "/file")
check("nest.file sets file + headers",
  r.file == "/tmp/report.pdf" and r.headers["Content-Type"] == "application/pdf"
  and r.headers["Content-Disposition"]:find("report.pdf", 1, true) ~= nil)
r = get(resp, "/stream")
check("nest.stream sets a producer", type(r.stream) == "function" and r.stream() == "chunk1")

--=====================================================--
-- Query handling
--=====================================================--

local q = h.module("query")
local qc = q:controller("Q")
qc:route("Scalar"):get("/s"):use_query("tag"):handle(function(t) return t end)
qc:route("Array"):get("/a"):use_query_array("tag"):handle(function(t) return t end)
qc:route("Whole"):get("/w"):use_query(nil):handle(function(t) return t end)

check("use_query returns the last value of a repeated key", get(q, "/s?tag=a&tag=b").body == "b")
local arr = get(q, "/a?tag=a&tag=b").body
check("use_query_array returns every value", #arr == 2 and arr[1] == "a" and arr[2] == "b")
check("use_query_array wraps a single value", get(q, "/a?tag=x").body[1] == "x")
check("use_query_array is empty when absent", #get(q, "/a").body == 0)
check("'+' means space in query strings", get(q, "/s?tag=a+b").body == "a b")
r = q:handle({ method = "GET", url = "/w", query = { pre = "parsed" } })
check("adapter-provided req.query is used", r.body.pre == "parsed")

--=====================================================--
-- Exceptions: 404 through filters, 500 hygiene, headers, new helpers
--=====================================================--

local ex = h.module("ex")
ex:filter(function(e, ctx)
  if e.code == 404 then return { code = 404, body = { error = "nope", path = ctx.path } } end
end)
ex:controller("E"):route("Bug"):get("/bug"):handle(function() error("secret internals") end)
ex:controller("E2"):route("Tea"):get("/tmr"):handle(function()
  nest:too_many_requests_error("slow down", { ["Retry-After"] = "30" })
end)

r = get(ex, "/missing")
check("unmatched routes go through module filters", r.body.error == "nope" and r.body.path == "/missing")
r = get(ex, "/bug")
check("500 body does not leak the Lua error", r.code == 500 and r.body == "Internal Server Error", r.body)
r = get(ex, "/tmr")
check("too_many_requests_error -> 429", r.code == 429)
check("exception headers are applied", r.headers["Retry-After"] == "30")

local logged = {}
local lg = nest.module("logged"):logger(function(level, msg, err, tb)
  logged[#logged + 1] = { level = level, msg = msg, err = err, tb = tb }
end)
lg:controller("L"):route("Bug"):get("/bug"):handle(function() error("boom") end)
lg:controller("L2"):route("Http"):get("/http"):handle(function() nest:service_unavailable_error() end)
get(lg, "/bug")
check("genuine errors are logged with a traceback",
  #logged == 1 and tostring(logged[1].err):find("boom", 1, true) ~= nil and logged[1].tb ~= nil)
get(lg, "/http")
check("intentional HTTP exceptions are not logged", #logged == 1, #logged)

lg:expose_errors(true)
check("expose_errors includes the message (dev only)", tostring(get(lg, "/bug").body):find("boom", 1, true) ~= nil)

check("status_text covers 429", nest.status_text[429] == "Too Many Requests")

--=====================================================--
-- Coroutine-friendly dispatch (handlers may yield, e.g. cosockets)
--=====================================================--

local co_mod = h.module("co")
co_mod:controller("C"):route("Yield"):get("/y")
    :guard(function() coroutine.yield("from-guard"); return true end)
    :handle(function()
      local v = coroutine.yield("from-handler")
      return "resumed with " .. tostring(v)
    end)
local co = coroutine.create(function() return co_mod:handle({ method = "GET", url = "/y" }) end)
local _, y1 = coroutine.resume(co)
local _, y2 = coroutine.resume(co)
local ok3, res3 = coroutine.resume(co, "value")
check("guards can yield across the pipeline", y1 == "from-guard", y1)
check("handlers can yield across the pipeline", y2 == "from-handler", y2)
check("dispatch resumes after yields", ok3 and res3 and res3.body == "resumed with value", res3 and res3.body)

h.done()
