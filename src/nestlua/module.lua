-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Module: the root of a route tree. This file holds construction,
  registration, lifecycle and logging; the rest of the class is mixed
  in from:
    nestlua.providers        provide / export / import / get (DI)
    nestlua.router           build / routes
    nestlua.router.dispatch  handle
--]]

local util = require "nestlua.util"
local url = require "nestlua.url"
local controller = require "nestlua.controller"
local route = require "nestlua.route"

local touch, is_callable = util.touch, util.is_callable

---@class nestlua.Provider
---@field factory? fun(module: nestlua.Module): any
---@field value? any
---@field resolved? boolean
---@field resolving? boolean

---@class nestlua.Module
---@field __class "Module"
---@field name string
---@field prefix string
---@field version_prefix string
---@field controllers nestlua.Controller[]
---@field imports nestlua.Module[]
---@field providers table<string, nestlua.Provider>
---@field exports (string|nestlua.Module)[]
---@field guards function[]
---@field interceptors function[]
---@field filters function[]
---@field middleware function[]
---@field decorators table<string, function>
---@field metadata table<string, any>
---@field hooks { init: function[], shutdown: function[] }
---@field instances any[]           resolved provider instances, creation order
---@field _expose_errors boolean
---@field _logger? function|false
---@field _built_generation? integer
---@field _initialized boolean
---@field _by_method? table<string, table[]>
---@field _routes_flat? table[]
---@field _pipeline? function
local Module = {}
Module.__index = Module

local module = { methods = Module }

---@param name string
---@return nestlua.Module
function module.new(name)
  assert(type(name) == "string" and #name > 0, "nest.module(name): name must be a non-empty string")
  local self = setmetatable({
    __class = "Module",
    name = name,
    prefix = "",
    version_prefix = "v",
    controllers = {},
    imports = {},
    providers = {},
    exports = {},
    guards = {},
    interceptors = {},
    filters = {},
    middleware = {},
    decorators = {},
    metadata = {},
    hooks = { init = {}, shutdown = {} },
    instances = {},
    _expose_errors = false,
    _initialized = false,
  }, Module)
  touch()
  return self
end

local function check(self)
  assert(util.is_module(self), "self must be a Module")
end

--============================================================--
-- Registration
--============================================================--

---@return nestlua.Controller
function Module:controller(name)
  check(self)
  assert(type(name) == "string" and #name > 0, "module:controller(name): name must be a non-empty string")
  local c = controller.new(self, name, nil)
  self.controllers[#self.controllers + 1] = c
  return c
end

function Module:decorator(name, func)
  check(self)
  assert(type(name) == "string" and #name > 0, "module:decorator(name, fn): name must be a non-empty string")
  assert(is_callable(func), "module:decorator(name, fn): fn must be a function")
  assert(route.methods[name] == nil, "'" .. name .. "' shadows a built-in RouteBuilder method")
  assert(controller.methods[name] == nil, "'" .. name .. "' shadows a built-in Controller method")
  self.decorators[name] = func
  return self
end

--- Global path prefix for every route in this module (e.g. "/api").
function Module:use_prefix(prefix)
  check(self)
  assert(type(prefix) == "string", "use_prefix: prefix must be a string")
  self.prefix = prefix
  touch()
  return self
end

--- Prefix put in front of version numbers (default "v" -> /v1/...).
function Module:versioning(prefix)
  check(self)
  assert(type(prefix) == "string", "versioning(prefix): prefix must be a string")
  self.version_prefix = prefix
  touch()
  return self
end

function Module:guard(...)
  check(self)
  return util.add_functions(self, self.guards, "guard", "module", ...)
end

function Module:intercept(...)
  check(self)
  return util.add_functions(self, self.interceptors, "interceptor", "module", ...)
end

function Module:filter(...)
  check(self)
  return util.add_functions(self, self.filters, "filter", "module", ...)
end

--- Registers middleware: function(ctx, next) -> response. On the module
--- whose :handle() is called, middleware runs *before* routing for every
--- request (including 404s), so it can parse bodies, add CORS headers,
--- log, or short-circuit with its own response. Middleware registered on
--- an *imported* module only runs for that module's routes, after
--- routing and before guards.
function Module:use(...)
  check(self)
  return util.add_functions(self, self.middleware, "middleware", "module", ...)
end

--- Like use(), but puts the middleware in front of everything registered
--- so far (adapters use it to install the body parser).
function Module:use_first(...)
  check(self)
  local fns = {}
  util.add_functions(self, fns, "middleware", "module", ...)
  for i = #fns, 1, -1 do table.insert(self.middleware, 1, fns[i]) end
  return self
end

function Module:meta(key, value)
  check(self)
  return util.set_meta(self, key, value)
end

--============================================================--
-- Lifecycle
--============================================================--

--- `fn(module)` runs once, the first time the module is built (imported
--- modules first).
function Module:on_init(fn)
  check(self)
  assert(is_callable(fn), "on_init(fn): fn must be a function")
  self.hooks.init[#self.hooks.init + 1] = fn
  return self
end

--- `fn(module)` runs on module:shutdown() (reverse order, importer before
--- imported modules).
function Module:on_shutdown(fn)
  check(self)
  assert(is_callable(fn), "on_shutdown(fn): fn must be a function")
  self.hooks.shutdown[#self.hooks.shutdown + 1] = fn
  return self
end

--- Runs init hooks of this module and everything it imports, once each.
function Module:_run_init_hooks(seen)
  seen = seen or {}
  if seen[self] then return end
  seen[self] = true
  for _, m in ipairs(self.imports) do m:_run_init_hooks(seen) end
  if self._initialized then return end
  self._initialized = true
  for _, fn in ipairs(self.hooks.init) do fn(self) end
end

--- Runs on_shutdown hooks and provider `on_shutdown` methods, importer
--- first, each module once.
function Module:shutdown()
  check(self)
  local root = self
  local seen = {}
  local function down(mod)
    if seen[mod] then return end
    seen[mod] = true
    for i = #mod.hooks.shutdown, 1, -1 do
      local ok, err = pcall(mod.hooks.shutdown[i], mod)
      if not ok then root:_log("error", "on_shutdown hook failed in module '" .. mod.name .. "'", err) end
    end
    for i = #mod.instances, 1, -1 do
      local inst = mod.instances[i]
      if type(inst) == "table" and is_callable(inst.on_shutdown) then
        local ok, err = pcall(inst.on_shutdown, inst, mod)
        if not ok then root:_log("error", "provider on_shutdown failed in module '" .. mod.name .. "'", err) end
      end
    end
    for _, m in ipairs(mod.imports) do down(m) end
    mod._initialized = false
  end
  down(self)
end

--============================================================--
-- Logging and error exposure
--============================================================--

--- Sets the logger: fn(level, message, err, traceback, ctx). Defaults to
--- writing to stderr. Pass `false` to silence logging.
function Module:logger(fn)
  check(self)
  assert(fn == false or is_callable(fn), "logger(fn): fn must be a function or false")
  self._logger = fn
  return self
end

--- When true, unhandled errors include the Lua error message in the 500
--- response body. Meant for development only -- it leaks internals.
function Module:expose_errors(enabled)
  check(self)
  self._expose_errors = enabled ~= false
  return self
end

function Module:_log(level, message, err, traceback, ctx)
  local logger = self._logger
  if logger == false then return end
  if logger then
    pcall(logger, level, message, err, traceback, ctx)
    return
  end
  local line = "[nestlua] " .. level .. ": " .. message
  if err ~= nil then line = line .. ": " .. tostring(err) end
  if traceback then line = line .. "\n" .. traceback end
  io.stderr:write(line, "\n")
end

--============================================================--
-- Introspection
--============================================================--

function Module:describe()
  check(self)
  local controllers = {}
  for i, c in ipairs(self.controllers) do controllers[i] = c:describe() end
  local imports = {}
  for i, m in ipairs(self.imports) do imports[i] = m:describe() end
  local providers = {}
  for name in pairs(self.providers) do providers[#providers + 1] = name end
  table.sort(providers)
  return {
    name = self.name,
    prefix = self.prefix ~= "" and url.normalize_path(self.prefix) or nil,
    guard_count = #self.guards,
    interceptor_count = #self.interceptors,
    filter_count = #self.filters,
    middleware_count = #self.middleware,
    providers = providers,
    meta = util.plain(self.metadata),
    controllers = controllers,
    imports = imports,
  }
end

--============================================================--
-- Mixins
--============================================================--

for _, name in ipairs({ "nestlua.providers", "nestlua.router", "nestlua.router.dispatch" }) do
  for k, fn in pairs(require(name)) do
    assert(Module[k] == nil, name .. " redefines Module:" .. k)
    Module[k] = fn
  end
end

return module
