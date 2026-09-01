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

local mod = nest.module("api")

-- module-level decorator usable from controllers/routes
mod:decorator("use_paging", function(target)
  assert(nest.is_route(target) or nest.is_controller(target))
  return target
      :use_query("pageIndex", function(v) return v or "0" end)
      :use_query("pageLimit", function(v) return v or "10" end)
end)

local function AuthGuard(ctx)
  local token = nil
  if ctx.req.headers then token = ctx.req.headers["Authorization"] end
  if token == "secret" then return true end
  return false, "Unauthorized"
end

local calls = {}
local function ExampleInterceptor(ctx, next_fn)
  calls[#calls + 1] = "before:" .. ctx.route.name
  local result = next_fn()
  calls[#calls + 1] = "after:" .. ctx.route.name
  return result
end

local function sortValidator(value)
  if value == nil then return true end
  return value == "ascending" or value == "descending"
end

local users = nest.module and mod:controller("Users")
users:use_prefix("/users")

local getUsers = users:route("GetUsers")
getUsers
    :get("/")
    :guard(AuthGuard)
    :intercept(ExampleInterceptor)
    :use_query("sort", sortValidator)
    :use_paging()
    :handle(function(sort, pageIndex, pageLimit)
      return { sort = sort, pageIndex = pageIndex, pageLimit = pageLimit }
    end)

-- route using use_custom (registered before the ":id" route below so that
-- the more specific literal "/me" segment is matched first -- routes are
-- tried in registration order, just like Express/Nest route ordering)
local whoAmI = users:route("WhoAmI")
whoAmI
    :get("/me")
    :use_custom(function(ctx) return ctx.route.name end)
    :handle(function(routeName)
      return { self_name = routeName }
    end)

-- route with :param, multiple verbs mapped to one handler, use_request/use_response
local getUserById = users:route("GetUserById")
getUserById
    :get("/:id")
    :get("/byId/:id")
    :use_param("id", function(v) return tonumber(v) end)
    :use_response()
    :handle(function(id, res)
      res.headers["X-Test"] = "yes"
      return { id = id, kind = "single" }
    end)

-- route using body (whole + named field) and header
local createUser = users:route("CreateUser")
createUser
    :post("/")
    :use_body("name")
    :use_body(nil)
    :use_header("Content-Type")
    :handle(function(name, wholeBody, contentType)
      return { created = name, whole = wholeBody, ctype = contentType }
    end)

-- wildcard route
local files = mod:controller("Files")
files:use_prefix("/files")
files:route("Catchall")
    :get("/*")
    :handle(function() return "catchall" end)

-- nested subcontroller inheriting prefix + guard
local admin = users:controller("Admin")
admin:use_prefix("/admin")
admin:guard(function(ctx) return true end)
admin:route("Ping")
    :get("/ping")
    :handle(function() return "pong" end)

mod:build()

--=====================================================--
-- Tests
--=====================================================--

-- 1. basic query + paging decorator + validator pipe (valid)
local r1 = mod:handle({ method = "GET", url = "/users?sort=ascending", headers = { Authorization = "secret" } })
check("query+paging happy path returns 200", r1.code == 200, r1.body)
check("query sort value correct", r1.body.sort == "ascending", r1.body.sort)
check("paging default pageIndex applied", r1.body.pageIndex == "0", r1.body.pageIndex)

-- 2. guard rejection
local r2 = mod:handle({ method = "GET", url = "/users?sort=ascending", headers = {} })
check("guard rejects missing auth with 403", r2.code == 403, r2.code)

-- 3. pipe validation failure -> 400
local r3 = mod:handle({ method = "GET", url = "/users?sort=sideways", headers = { Authorization = "secret" } })
check("invalid sort pipe rejected with 400", r3.code == 400, r3.code)

-- 4. interceptor ran before and after handler
check("interceptor wrapped handler call", calls[1] == "before:GetUsers" and calls[2] == "after:GetUsers",
  table.concat(calls, ","))

-- 5. :param with pipe transform (tonumber) + two different paths, same handler
local r4 = mod:handle({ method = "GET", url = "/users/42" })
check(":id param transformed to number", r4.body.id == 42, r4.body.id)
local r4b = mod:handle({ method = "GET", url = "/users/byId/7" })
check("second path alias for same route works", r4b.body.id == 7, r4b.body.id)
check("use_response header mutation persisted", r4.headers["X-Test"] == "yes", r4.headers and r4.headers["X-Test"])

-- 6. body extraction (named + whole) and header extraction
local r5 = mod:handle({
  method = "POST",
  url = "/users",
  headers = { ["Content-Type"] = "application/json" },
  body = { name = "Ada" },
})
check("named body field extracted", r5.body.created == "Ada", r5.body.created)
check("whole body extracted", r5.body.whole.name == "Ada")
check("header extracted case-sensitively", r5.body.ctype == "application/json", r5.body.ctype)

-- 6b. header lookup is case-insensitive
local r5b = mod:handle({
  method = "POST",
  url = "/users",
  headers = { ["content-type"] = "text/plain" },
  body = { name = "Bob" },
})
check("header lookup case-insensitive", r5b.body.ctype == "text/plain", r5b.body.ctype)

-- 7. use_custom selector
local r6 = mod:handle({ method = "GET", url = "/users/me" })
check("use_custom selector supplies arg", r6.body.self_name == "WhoAmI", r6.body.self_name)

-- 8. wildcard route
local r7 = mod:handle({ method = "GET", url = "/files/a/b/c.txt" })
check("wildcard route matches nested path", r7.code == 200 and r7.body == "catchall", r7.code)

-- 9. nested sub-controller prefix composition + inherited guard
local r8 = mod:handle({ method = "GET", url = "/users/admin/ping" })
check("nested controller prefix composed correctly", r8.code == 200 and r8.body == "pong", r8.code)

-- 10. 404 for unknown route
local r9 = mod:handle({ method = "GET", url = "/does/not/exist" })
check("unknown route returns 404", r9.code == 404, r9.code)

-- 11. introspection
local desc = mod:describe()
check("describe() reports module name", desc.name == "api")
check("describe() reports controllers", #desc.controllers >= 2)

-- 12. is_route / is_controller / is_module type guards
check("is_module true for module", nest.is_module(mod))
check("is_controller true for controller", nest.is_controller(users))
check("is_route true for route builder", nest.is_route(getUsers))
check("is_route false for a plain table", nest.is_route({}) == false)

-- 13. assertion guards on bad input
local ok_err = pcall(function() nest.module(123) end)
check("nest.module rejects non-string name", ok_err == false)

local ok_err2 = pcall(function() getUsers:get(123) end)
check("route:get rejects non-string path", ok_err2 == false)

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
