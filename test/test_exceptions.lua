-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

package.path = "./?.lua;./?/init.lua;" .. package.path
local nest = require "nestlua"

local failures = 0
local function check(name, cond, extra)
  if cond then
    print("PASS  " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. (extra and (" -- " .. tostring(extra)) or ""))
  end
end

--=====================================================--
-- nest.http_exception / is_http_exception basics
--=====================================================--

local e = nest.http_exception(404)
check("http_exception defaults body to status text", e.body == "Not Found", e.body)
check("http_exception sets code", e.code == 404)
check("is_http_exception true for exception", nest.is_http_exception(e))
check("is_http_exception false for plain table", not nest.is_http_exception({}))

local e2 = nest.http_exception(400, "custom message")
check("http_exception accepts custom string message", e2.body == "custom message")

local e3 = nest.http_exception(422, { message = "bad", fields = { "a", "b" } })
check("http_exception accepts structured table body", e3.body.message == "bad")

local pok = pcall(function() nest.http_exception(999) end)
check("http_exception rejects out-of-range code", pok == false)

--=====================================================--
-- Named exception helpers thrown from a handler (the requested interface)
--=====================================================--

local mod = nest.module("api")
local c = mod:controller("Example")

c:route("NotImplemented")
    :get("/not-implemented")
    :handle(function()
      nest:not_implemented_error()
    end)

c:route("BadRequestWithMessage")
    :get("/bad-request")
    :handle(function()
      nest:bad_request_error("field 'x' is required")
    end)

c:route("Teapot")
    :get("/teapot")
    :handle(function()
      nest:im_a_teapot_error()
    end)

c:route("CustomCode")
    :get("/custom")
    :handle(function()
      nest:http_error(402, "Payment Required")
    end)

c:route("StructuredBody")
    :get("/structured")
    :handle(function()
      nest:unprocessable_entity_error({ message = "Validation failed", errors = { "a", "b" } })
    end)

mod:build()

local r1 = mod:handle({ method = "GET", url = "/not-implemented" })
check("not_implemented_error -> 501", r1.code == 501, r1.code)
check("not_implemented_error default body", r1.body == "Not Implemented", r1.body)

local r2 = mod:handle({ method = "GET", url = "/bad-request" })
check("bad_request_error -> 400", r2.code == 400)
check("bad_request_error custom message", r2.body == "field 'x' is required", r2.body)

local r3 = mod:handle({ method = "GET", url = "/teapot" })
check("im_a_teapot_error -> 418", r3.code == 418)

local r4 = mod:handle({ method = "GET", url = "/custom" })
check("http_error supports arbitrary code -> 402", r4.code == 402)
check("http_error custom message preserved", r4.body == "Payment Required")

local r5 = mod:handle({ method = "GET", url = "/structured" })
check("unprocessable_entity_error -> 422", r5.code == 422)
check("structured exception body preserved", r5.body.message == "Validation failed", r5.body)
check("structured exception body has nested list", r5.body.errors[1] == "a")

--=====================================================--
-- Errors thrown from other pipeline stages (guard, interceptor, handler bug)
--=====================================================--

local pipeMod = nest.module("pipes")
local pc = pipeMod:controller("Ctrl")

pc:route("GuardThrows")
    :get("/guard-throws")
    :guard(function(ctx) nest:forbidden_error("nope") end)
    :handle(function() return "unreachable" end)

pc:route("GuardReturnsFalse")
    :get("/guard-false")
    :guard(function(ctx) return false, "still forbidden" end)
    :handle(function() return "unreachable" end)

pc:route("InterceptorThrows")
    :get("/interceptor-throws")
    :intercept(function(ctx, next) nest:conflict_error("conflict!") end)
    :handle(function() return "unreachable" end)

pc:route("HandlerBug")
    :get("/handler-bug")
    :handle(function() return nil + 1 end) -- genuine runtime error, not an HttpException

pipeMod:build()

local g1 = pipeMod:handle({ method = "GET", url = "/guard-throws" })
check("guard throwing HttpException -> 403", g1.code == 403 and g1.body == "nope", g1.code)

local g2 = pipeMod:handle({ method = "GET", url = "/guard-false" })
check("guard returning false still -> 403 (unchanged behavior)", g2.code == 403 and g2.body == "still forbidden")

local i1 = pipeMod:handle({ method = "GET", url = "/interceptor-throws" })
check("interceptor throwing HttpException -> 409", i1.code == 409 and i1.body == "conflict!")

local h1 = pipeMod:handle({ method = "GET", url = "/handler-bug" })
check("genuine runtime error in handler -> 500", h1.code == 500, h1.code)
check("genuine runtime error message surfaced", tostring(h1.body):find("Internal Server Error") ~= nil, h1.body)

--=====================================================--
-- Exception filters: registration mirrors guard()/intercept()
--=====================================================--

local filterMod = nest.module("filters")
local fc = filterMod:controller("Ctrl")

local moduleFilterCalls, controllerFilterCalls, routeFilterCalls = 0, 0, 0

filterMod:filter(function(exception, ctx)
  moduleFilterCalls = moduleFilterCalls + 1
  return { code = exception.code, headers = {}, body = "module-filter: " .. tostring(exception.body) }
end)

fc:filter(function(exception, ctx)
  controllerFilterCalls = controllerFilterCalls + 1
  if exception.code == 404 then
    return { code = 404, headers = {}, body = "controller-filter: not found" }
  end
  return nil -- defer to module filter for anything else
end)

local onlyRouteFiltered = fc:route("OnlyRoute")
onlyRouteFiltered
    :get("/route-only")
    :filter(function(exception, ctx)
      routeFilterCalls = routeFilterCalls + 1
      return { code = 599, headers = {}, body = "route-filter handled it" }
    end)
    :handle(function() nest:bad_request_error("boom") end)

fc:route("NotFoundCase")
    :get("/nf")
    :handle(function() nest:not_found_error() end)

fc:route("FallsThroughToModule")
    :get("/fall-through")
    :handle(function() nest:conflict_error("conflict") end)

filterMod:build()

local fr1 = filterMod:handle({ method = "GET", url = "/route-only" })
check("most-specific (route) filter wins", fr1.code == 599 and fr1.body == "route-filter handled it", fr1.body)
check("route filter ran", routeFilterCalls == 1)
check("less specific filters were not consulted once route filter handled it",
  controllerFilterCalls == 0 and moduleFilterCalls == 0)

local fr2 = filterMod:handle({ method = "GET", url = "/nf" })
check("controller filter handles 404 specifically", fr2.code == 404 and fr2.body == "controller-filter: not found",
  fr2.body)

local fr3 = filterMod:handle({ method = "GET", url = "/fall-through" })
check("controller filter defers (returns nil) -> module filter handles it",
  fr3.code == 409 and fr3.body == "module-filter: conflict", fr3.body)

--=====================================================--
-- Filter that throws is skipped in favor of the next, less specific one
--=====================================================--

local brokenMod = nest.module("broken")
local bc = brokenMod:controller("Ctrl")
brokenMod:filter(function(exception, ctx)
  return { code = exception.code, headers = {}, body = "fallback-module-filter" }
end)
bc:filter(function(exception, ctx)
  error("this filter itself has a bug")
end)
bc:route("R")
    :get("/r")
    :handle(function() nest:bad_request_error("x") end)
brokenMod:build()

local br = brokenMod:handle({ method = "GET", url = "/r" })
check("a filter that errors is skipped, next filter still runs", br.body == "fallback-module-filter", br.body)

--=====================================================--
-- No filters registered at all -> default handling
--=====================================================--

local plainMod = nest.module("plain")
local plc = plainMod:controller("Ctrl")
plc:route("R")
    :get("/r")
    :handle(function() nest:gone_error() end)
plainMod:build()

local pr = plainMod:handle({ method = "GET", url = "/r" })
check("no filters -> default response built from exception", pr.code == 410 and pr.body == "Gone", pr.body)

--=====================================================--
-- Filters preserve structured ctx.res mutations from earlier pipeline
-- stages (e.g. a pipe that set ctx.res.body before signalling failure)
--=====================================================--

local structMod = nest.module("struct")
local sc = structMod:controller("Ctrl")
sc:route("R")
    :post("/r")
    :use_body(nil, function(body, ctx)
      ctx.res.body = { message = "Validation failed", errors = { "bad field" } }
      return false
    end)
    :handle(function(body) return "unreachable" end)
structMod:build()

local sr = structMod:handle({ method = "POST", url = "/r", body = {} })
check("default handling preserves ctx.res.body set before the exception was raised",
  type(sr.body) == "table" and sr.body.message == "Validation failed", sr.body)

--=====================================================--
-- compose_filters helper
--=====================================================--

local composed = nest.compose_filters(
  function(exception, ctx) if exception.code == 404 then return { code = 404, body = "handled 404" } end end,
  function(exception, ctx) return { code = exception.code, body = "fallback" } end
)
local resp1 = composed(nest.http_exception(404), {})
check("compose_filters: first matching filter wins", resp1.body == "handled 404")
local resp2 = composed(nest.http_exception(500), {})
check("compose_filters: falls through to later filter", resp2.body == "fallback")

--=====================================================--
-- introspection includes filter counts
--=====================================================--

local d = filterMod:describe()
check("module describe() reports filter_count", d.filter_count == 1, d.filter_count)

--=====================================================--
-- argument checking
--=====================================================--

local pok2 = pcall(function() filterMod:filter("not a function") end)
check("module:filter rejects non-function argument", pok2 == false)

local pok3 = pcall(function() fc:filter() end)
check("controller:filter requires at least one argument", pok3 == false)

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
