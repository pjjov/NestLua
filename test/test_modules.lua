-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Providers / DI, module imports, lifecycle hooks, metadata, middleware.

local h = require "test.helper"
local nest = require "nestlua"
local check, raises, get = h.check, h.raises, h.get

--=====================================================--
-- Providers
--=====================================================--

local created = 0
local db = h.module("db")
db:provide_value("dsn", "sqlite::memory:")
db:provide("connection", function(mod)
  created = created + 1
  return { dsn = mod:get("dsn"), id = created }
end)
db:provide("secret", function() return "not exported" end)
db:export("connection")

local users = h.module("users"):use_prefix("/users")
users:import(db)
users:provide("users_service", function(mod)
  local conn = mod:get("connection")
  return { find = function(id) return { id = id, via = conn.dsn } end }
end)
users:export("users_service", db) -- re-export db's exports too
users:controller("Users")
    :route("Get"):get("/:id")
    :use_param("id", nest.pipes.int)
    :use_inject("users_service")
    :handle(function(id, svc) return svc.find(id) end)

local app = h.module("app")
app:import(users)
app:controller("Info"):route("Info"):get("/info")
    :use_custom(function(ctx) return ctx:inject("connection") end)
    :handle(function(conn) return { dsn = conn.dsn } end)

local r = get(app, "/users/7")
check("imported module routes are served with their prefix", r.code == 200, r.code)
check("use_inject resolves a provider", r.body.id == 7 and r.body.via == "sqlite::memory:", r.body.via)
check("re-exported provider visible through the importer", get(app, "/info").body.dsn == "sqlite::memory:")
get(app, "/users/8")
check("providers are singletons", created == 1, created)
check("unexported providers are not visible", raises(function() app:get("secret") end, "no provider 'secret'"))
check("module:get works directly", users:get("users_service") ~= nil)
check("duplicate provider names are rejected", raises(function() db:provide_value("dsn", 1) end, "already registered"))

local cyc = h.module("cyc")
cyc:provide("a", function(m) return m:get("b") end)
cyc:provide("b", function(m) return m:get("a") end)
check("circular provider dependencies are detected", raises(function() cyc:get("a") end, "circular dependency"))

local self_import = h.module("self")
check("a module cannot import itself", raises(function() self_import:import(self_import) end))

--=====================================================--
-- Lifecycle hooks
--=====================================================--

local events = {}
local child = h.module("child")
child:on_init(function() events[#events + 1] = "child:init" end)
child:on_shutdown(function() events[#events + 1] = "child:shutdown" end)
child:provide("svc", function()
  return {
    on_init = function() events[#events + 1] = "svc:init" end,
    on_shutdown = function() events[#events + 1] = "svc:shutdown" end,
  }
end)
child:export("svc")
local parent = h.module("parent"):import(child)
parent:on_init(function() events[#events + 1] = "parent:init" end)
parent:on_shutdown(function() events[#events + 1] = "parent:shutdown" end)
parent:controller("P"):route("R"):get("/"):use_inject("svc"):handle(function() return "ok" end)

parent:build()
parent:build()
check("init hooks run once, imported modules first",
  table.concat(events, ",") == "child:init,parent:init", table.concat(events, ","))
get(parent, "/")
check("provider on_init runs on creation", events[#events] == "svc:init")
parent:shutdown()
check("shutdown runs importer first, then imported hooks and providers",
  table.concat(events, ",", 4) == "parent:shutdown,child:shutdown,svc:shutdown", table.concat(events, ",", 4))

--=====================================================--
-- Metadata (SetMetadata + Reflector)
--=====================================================--

local function RolesGuard(ctx)
  local roles = ctx:meta("roles")
  if not roles then return true end
  return roles[ctx.req.headers.role] == true, "missing role"
end

local meta = h.module("meta"):meta("roles", { user = true })
local mc = meta:controller("M"):guard(RolesGuard)
mc:route("ModuleDefault"):get("/default"):handle(function() return "default" end)
mc:route("AdminOnly"):get("/admin"):meta("roles", { admin = true }):handle(function() return "admin" end)
local sub = mc:controller("Sub"):use_prefix("/sub"):meta("roles", { editor = true })
sub:route("Edit"):get("/edit"):handle(function() return "edit" end)

check("module metadata is the fallback", get(meta, "/default", { role = "user" }).code == 200)
check("route metadata overrides", get(meta, "/admin", { role = "user" }).code == 403)
check("route metadata grants", get(meta, "/admin", { role = "admin" }).code == 200)
check("controller metadata applies to its routes", get(meta, "/sub/edit", { role = "editor" }).code == 200)
check("controller metadata overrides module", get(meta, "/sub/edit", { role = "user" }).code == 403)

--=====================================================--
-- Middleware
--=====================================================--

local order = {}
local inner = h.module("inner"):use_prefix("/inner")
inner:use(function(ctx, next_fn)
  order[#order + 1] = "inner-mw:" .. tostring(ctx.route and ctx.route.name)
  return next_fn()
end)
inner:controller("I"):route("Hello"):get("/hello")
    :guard(function() order[#order + 1] = "guard"; return true end)
    :handle(function() order[#order + 1] = "handler"; return "hi" end)

local outer = h.module("outer"):import(inner)
outer:use(function(ctx, next_fn)
  order[#order + 1] = "outer-mw:" .. tostring(ctx.route)
  local res = next_fn()
  res.headers["X-Outer"] = tostring(res.code)
  return res
end)
outer:use_first(function(ctx, next_fn)
  order[#order + 1] = "first"
  return next_fn()
end)
outer:use(function(ctx, next_fn)
  if ctx.path == "/blocked" then return { code = 451, headers = {}, body = "blocked" } end
  return next_fn()
end)

local res = get(outer, "/inner/hello")
check("middleware order: use_first, root (pre-routing), imported (post-routing), guard, handler",
  table.concat(order, ",") == "first,outer-mw:nil,inner-mw:Hello,guard,handler", table.concat(order, ","))
check("root middleware sees the final response", res.headers["X-Outer"] == "200")
res = get(outer, "/does-not-exist")
check("root middleware runs for 404s too", res.code == 404 and res.headers["X-Outer"] == "404")
check("middleware can short-circuit", get(outer, "/blocked").code == 451)

local boom = h.module("boom")
boom:use(function() nest:unauthorized_error("no session") end)
boom:filter(function(e) return { code = e.code, body = "filtered: " .. e.body } end)
check("middleware exceptions go through module filters", get(boom, "/x").body == "filtered: no session")

--=====================================================--
-- Introspection
--=====================================================--

local d = app:describe()
check("describe() includes imports", d.imports[1].name == "users")
check("describe() lists providers", #users:describe().providers == 1)
local routes = app:routes()
check("routes() lists imported endpoints with full paths", routes[1].path == "/users/:id" or routes[2].path == "/users/:id")
local found
for _, e in ipairs(routes) do
  if e.path == "/users/:id" then found = e end
end
check("routes() includes pipe descriptions", found and found.route.params[1].pipes[1].type == "integer")

h.done()
