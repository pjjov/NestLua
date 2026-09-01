-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  This module implements the *routing / composition* layer only:
  modules, controllers, routes, guards, interceptors, argument
  decorators and pipes. A separate layer (an HTTP server adapter)
  is expected to translate real socket traffic into the plain
  `request` table documented below, call `module:handle(request)`,
  and translate the returned `response` table back into bytes on
  the wire.

  Request table shape (produced by the adapter, read by NestLua):
    {
      method  = "GET",
      url     = "/users/42?sort=asc",
      version = "HTTP/1.1",
      headers = { ["Content-Type"] = "text/plain", ... },
      body    = <any -- string, table, whatever the adapter decoded>,
    }

  Response table shape (produced by NestLua, read by the adapter):
    {
      code    = 200,
      headers = { ["Content-Type"] = "text/html", ... },
      body    = <any>,
    }
--]]

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack -- luacheck: ignore

local nest = {}
nest._VERSION = "0.1.0"

--============================================================--
-- Small utilities
--============================================================--

local function is_instance(obj, class)
  return type(obj) == "table" and obj.__class == class
end

function nest.is_module(obj) return is_instance(obj, "Module") end

function nest.is_controller(obj) return is_instance(obj, "Controller") end

function nest.is_route(obj) return is_instance(obj, "RouteBuilder") end

function nest.is_app(obj) return is_instance(obj, "App") end

local function url_decode(s)
  if s == nil then return nil end
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  return s
end

local function split_path(path)
  local segments = {}
  for seg in path:gmatch("[^/]+") do
    segments[#segments + 1] = seg
  end
  return segments
end

local function normalize_path(path)
  if path == nil or path == "" then return "/" end
  path = path:gsub("//+", "/")
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  if #path > 1 and path:sub(-1) == "/" then path = path:sub(1, -2) end
  return path
end

-- Compiles a Nest-like path pattern ("/users/:id/*") into a list of
-- segment descriptors used by match_path().
local function compile_pattern(pattern)
  assert(type(pattern) == "string", "path pattern must be a string")
  local segs = split_path(pattern)
  local compiled = {}
  for _, seg in ipairs(segs) do
    if seg == "*" then
      compiled[#compiled + 1] = { type = "wildcard" }
    elseif seg:sub(1, 1) == ":" then
      local pname = seg:sub(2)
      assert(#pname > 0, "':' path param must have a name in pattern '" .. pattern .. "'")
      compiled[#compiled + 1] = { type = "param", name = pname }
    else
      compiled[#compiled + 1] = { type = "literal", value = seg }
    end
  end
  return compiled
end

-- Attempts to match a compiled pattern against a concrete URL path.
-- Returns (true, params) on success, or (false) on failure.
local function match_path(compiled, url_path)
  local segs = split_path(url_path)
  local params = {}
  local ci = 1
  for i = 1, #compiled do
    local part = compiled[i]
    if part.type == "wildcard" then
      local rest = {}
      for j = ci, #segs do rest[#rest + 1] = segs[j] end
      params["*"] = table.concat(rest, "/")
      return true, params
    end
    local seg = segs[ci]
    if seg == nil then return false end
    if part.type == "literal" then
      if seg ~= part.value then return false end
    elseif part.type == "param" then
      params[part.name] = url_decode(seg)
    end
    ci = ci + 1
  end
  if ci <= #segs then return false end -- leftover segments and no wildcard consumed them
  return true, params
end

local function parse_query(qs)
  local q = {}
  if not qs or qs == "" then return q end
  for pair in qs:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    k = url_decode(k)
    v = url_decode(v)
    if k ~= "" then
      if q[k] ~= nil then
        if type(q[k]) == "table" then
          q[k][#q[k] + 1] = v
        else
          q[k] = { q[k], v }
        end
      else
        q[k] = v
      end
    end
  end
  return q
end

local function find_header(headers, name)
  if not headers then return nil end
  if headers[name] ~= nil then return headers[name] end
  local lname = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == lname then return v end
  end
  return nil
end

--============================================================--
-- HTTP exceptions
--
-- Mirrors Nest's built-in HttpException subclasses. Call one of these as
-- a method on the required module (`nest:not_found_error()`) from inside
-- a guard, interceptor, pipe, or route handler to abort the request with
-- that status code; the raised value is caught centrally by
-- Module:_dispatch and turned into the equivalent HTTP response (subject
-- to any exception filters registered with module/controller/route
-- :filter(), see below).
--============================================================--

local HTTP_STATUS_TEXT = {
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [406] = "Not Acceptable",
  [408] = "Request Timeout",
  [409] = "Conflict",
  [410] = "Gone",
  [412] = "Precondition Failed",
  [413] = "Payload Too Large",
  [415] = "Unsupported Media Type",
  [418] = "I'm a teapot",
  [422] = "Unprocessable Entity",
  [500] = "Internal Server Error",
  [501] = "Not Implemented",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
  [505] = "HTTP Version Not Supported",
}

local HttpExceptionMeta = {
  __tostring = function(e) return "HttpException(" .. tostring(e.code) .. "): " .. tostring(e.body) end,
}

-- Builds (but does not throw) an HttpException-shaped value. `message` may
-- be a string, a table (for a structured error body), or nil to fall back
-- to the standard status text. Useful for exception filters that want to
-- construct/re-throw a specific exception, or for advanced use where you
-- want the object without immediately aborting execution.
function nest.http_exception(code, message)
  assert(type(code) == "number" and code >= 100 and code <= 599,
    "http_exception: code must be a valid HTTP status code")
  assert(message == nil or type(message) == "string" or type(message) == "table",
    "http_exception: message must be a string, a table, or nil")
  local body = message
  if body == nil then
    body = HTTP_STATUS_TEXT[code] or ("HTTP " .. tostring(code))
  end
  return setmetatable({ __class = "HttpException", code = code, body = body }, HttpExceptionMeta)
end

function nest.is_http_exception(obj) return is_instance(obj, "HttpException") end

-- name -> status code for every one-liner exception helper below.
local HTTP_EXCEPTIONS = {
  { name = "bad_request_error",                code = 400 },
  { name = "unauthorized_error",               code = 401 },
  { name = "forbidden_error",                  code = 403 },
  { name = "not_found_error",                  code = 404 },
  { name = "method_not_allowed_error",         code = 405 },
  { name = "not_acceptable_error",             code = 406 },
  { name = "request_timeout_error",            code = 408 },
  { name = "conflict_error",                   code = 409 },
  { name = "gone_error",                       code = 410 },
  { name = "precondition_failed_error",        code = 412 },
  { name = "payload_too_large_error",          code = 413 },
  { name = "unsupported_media_type_error",     code = 415 },
  { name = "im_a_teapot_error",                code = 418 },
  { name = "unprocessable_entity_error",       code = 422 },
  { name = "internal_server_error",            code = 500 },
  { name = "not_implemented_error",            code = 501 },
  { name = "bad_gateway_error",                code = 502 },
  { name = "service_unavailable_error",        code = 503 },
  { name = "gateway_timeout_error",            code = 504 },
  { name = "http_version_not_supported_error", code = 505 },
}

for _, def in ipairs(HTTP_EXCEPTIONS) do
  -- Defined so it's callable as `nest:name(message)`; `self` is unused but
  -- required to make the colon-call convention shown in the docs work.
  nest[def.name] = function(_, message)
    error(nest.http_exception(def.code, message))
  end
end

-- nest:http_error(code, message) - escape hatch for any status code not
-- covered by the named helpers above (mirrors Nest's base HttpException).
function nest:http_error(code, message)
  error(nest.http_exception(code, message))
end

--============================================================--
-- Forward declarations
--============================================================--

local Module -- Module "class" (methods table)
local ControllerMethods, ControllerMeta
local RouteBuilderMethods, RouteBuilderMeta
local new_controller, new_route_builder

--============================================================--
-- Decorator dispatch
--
-- Decorators registered on a Module via `module:decorator(name, fn)`
-- become callable as `controller:name(...)` / `route:name(...)` for
-- any Controller/RouteBuilder that belongs to that module. This is
-- implemented with a metatable __index function: static methods win
-- first, then we fall back to the owning module's decorator table.
--============================================================--

local function decorator_lookup(instance, key)
  local mod = rawget(instance, "_module")
  if mod and mod.decorators and mod.decorators[key] then
    local fn = mod.decorators[key]
    return function(self, ...) return fn(self, ...) end
  end
  return nil
end

--============================================================--
-- RouteBuilder
--============================================================--

RouteBuilderMethods = {}
RouteBuilderMeta = {
  __index = function(instance, key)
    local v = RouteBuilderMethods[key]
    if v ~= nil then return v end
    return decorator_lookup(instance, key)
  end,
}

local HTTP_METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE" }

new_route_builder = function(module_ref, controller_ref, name)
  local self = setmetatable({}, RouteBuilderMeta)
  self.__class = "RouteBuilder"
  self._module = module_ref
  self.controller = controller_ref
  self.name = name
  self.endpoints = {} -- { {method="GET", path="/users/:id"}, ... }
  self.guards = {}
  self.interceptors = {}
  self.filters = {}
  self.params = {} -- ordered handler-argument descriptors
  self.handler = nil
  self.built = false
  return self
end

local function add_method_verb(verb)
  RouteBuilderMethods[verb:lower()] = function(self, path)
    assert(nest.is_route(self), "self must be a RouteBuilder")
    assert(type(path) == "string" and path:sub(1, 1) == "/",
      "path must be a string starting with '/' (got " .. tostring(path) .. ")")
    assert(not self.built, "cannot register more paths on route '" .. self.name .. "' after :handle() was called")
    self.endpoints[#self.endpoints + 1] = { method = verb, path = path }
    return self
  end
end

for _, verb in ipairs(HTTP_METHODS) do add_method_verb(verb) end

function RouteBuilderMethods:guard(...)
  assert(nest.is_route(self), "self must be a RouteBuilder")
  local guards = { ... }
  assert(#guards > 0, "route:guard(...) requires at least one guard function")
  for _, g in ipairs(guards) do
    assert(type(g) == "function", "guard must be a function")
    self.guards[#self.guards + 1] = g
  end
  return self
end

function RouteBuilderMethods:intercept(...)
  assert(nest.is_route(self), "self must be a RouteBuilder")
  local interceptors = { ... }
  assert(#interceptors > 0, "route:intercept(...) requires at least one interceptor function")
  for _, i in ipairs(interceptors) do
    assert(type(i) == "function", "interceptor must be a function")
    self.interceptors[#self.interceptors + 1] = i
  end
  return self
end

-- Exception filters: function(exception, ctx) -> response table | nil.
-- Return a response table ({code=, headers=, body=}, any field optional)
-- to handle the exception; return nil (or throw) to defer to the next,
-- less specific filter, or to the built-in default handling if none
-- handle it. Tried route -> controller (leaf to root) -> module, i.e.
-- the most specific filter gets first refusal.
function RouteBuilderMethods:filter(...)
  assert(nest.is_route(self), "self must be a RouteBuilder")
  local filters = { ... }
  assert(#filters > 0, "route:filter(...) requires at least one filter function")
  for _, f in ipairs(filters) do
    assert(type(f) == "function", "filter must be a function")
    self.filters[#self.filters + 1] = f
  end
  return self
end

function RouteBuilderMethods:use_request()
  self.params[#self.params + 1] = { kind = "request" }
  return self
end

function RouteBuilderMethods:use_response()
  self.params[#self.params + 1] = { kind = "response" }
  return self
end

function RouteBuilderMethods:use_param(name, pipe)
  assert(type(name) == "string" and #name > 0, "use_param: name must be a non-empty string")
  assert(pipe == nil or type(pipe) == "function", "use_param: pipe must be a function or nil")
  self.params[#self.params + 1] = { kind = "param", name = name, pipe = pipe }
  return self
end

function RouteBuilderMethods:use_query(name, pipe)
  assert(name == nil or type(name) == "string", "use_query: name must be a string or nil")
  assert(pipe == nil or type(pipe) == "function", "use_query: pipe must be a function or nil")
  self.params[#self.params + 1] = { kind = "query", name = name, pipe = pipe }
  return self
end

function RouteBuilderMethods:use_header(name, pipe)
  assert(type(name) == "string" and #name > 0, "use_header: name must be a non-empty string")
  assert(pipe == nil or type(pipe) == "function", "use_header: pipe must be a function or nil")
  self.params[#self.params + 1] = { kind = "header", name = name, pipe = pipe }
  return self
end

function RouteBuilderMethods:use_body(name, pipe)
  assert(name == nil or type(name) == "string", "use_body: name must be a string or nil")
  assert(pipe == nil or type(pipe) == "function", "use_body: pipe must be a function or nil")
  self.params[#self.params + 1] = { kind = "body", name = name, pipe = pipe }
  return self
end

function RouteBuilderMethods:use_custom(selector)
  assert(type(selector) == "function", "use_custom: selector must be a function")
  self.params[#self.params + 1] = { kind = "custom", selector = selector }
  return self
end

function RouteBuilderMethods:handle(func)
  assert(nest.is_route(self), "self must be a RouteBuilder")
  assert(type(func) == "function", "route:handle(func): func must be a function")
  assert(#self.endpoints > 0,
    "route '" .. self.name .. "' needs at least one :get/:post/:put/:patch/:delete before :handle()")
  self.handler = func
  self.built = true
  return self
end

function RouteBuilderMethods:describe()
  local endpoints = {}
  for _, e in ipairs(self.endpoints) do
    endpoints[#endpoints + 1] = { method = e.method, path = e.path }
  end
  local params = {}
  for _, p in ipairs(self.params) do
    params[#params + 1] = { kind = p.kind, name = p.name }
  end
  return {
    name = self.name,
    endpoints = endpoints,
    params = params,
    guard_count = #self.guards,
    interceptor_count = #self.interceptors,
    filter_count = #self.filters,
  }
end

--============================================================--
-- Controller
--============================================================--

ControllerMethods = {}
ControllerMeta = {
  __index = function(instance, key)
    local v = ControllerMethods[key]
    if v ~= nil then return v end
    return decorator_lookup(instance, key)
  end,
}

new_controller = function(module_ref, name, parent)
  assert(nest.is_module(module_ref), "module_ref must be a Module")
  local self = setmetatable({}, ControllerMeta)
  self.__class = "Controller"
  self._module = module_ref
  self.name = name
  self.parent = parent
  self.prefix = ""
  self.controllers = {}
  self.routes = {}
  self.guards = {}
  self.interceptors = {}
  self.filters = {}
  return self
end

function ControllerMethods:route(name)
  assert(nest.is_controller(self), "self must be a Controller")
  assert(type(name) == "string" and #name > 0, "controller:route(name): name must be a non-empty string")
  local r = new_route_builder(self._module, self, name)
  self.routes[#self.routes + 1] = r
  return r
end

function ControllerMethods:controller(name)
  -- allows building a tree of sub-controllers that inherit prefixes,
  -- guards and interceptors from their ancestors.
  assert(nest.is_controller(self), "self must be a Controller")
  assert(type(name) == "string" and #name > 0, "controller:controller(name): name must be a non-empty string")
  local c = new_controller(self._module, name, self)
  self.controllers[#self.controllers + 1] = c
  return c
end

function ControllerMethods:use_prefix(prefix)
  assert(nest.is_controller(self), "self must be a Controller")
  assert(type(prefix) == "string", "use_prefix: prefix must be a string")
  self.prefix = prefix
  return self
end

function ControllerMethods:guard(...)
  assert(nest.is_controller(self), "self must be a Controller")
  local guards = { ... }
  assert(#guards > 0, "controller:guard(...) requires at least one guard function")
  for _, g in ipairs(guards) do
    assert(type(g) == "function", "guard must be a function")
    self.guards[#self.guards + 1] = g
  end
  return self
end

function ControllerMethods:intercept(...)
  assert(nest.is_controller(self), "self must be a Controller")
  local interceptors = { ... }
  assert(#interceptors > 0, "controller:intercept(...) requires at least one interceptor function")
  for _, i in ipairs(interceptors) do
    assert(type(i) == "function", "interceptor must be a function")
    self.interceptors[#self.interceptors + 1] = i
  end
  return self
end

function ControllerMethods:filter(...)
  assert(nest.is_controller(self), "self must be a Controller")
  local filters = { ... }
  assert(#filters > 0, "controller:filter(...) requires at least one filter function")
  for _, f in ipairs(filters) do
    assert(type(f) == "function", "filter must be a function")
    self.filters[#self.filters + 1] = f
  end
  return self
end

function ControllerMethods:full_prefix()
  local parts = {}
  local node = self
  while node do
    if node.prefix and node.prefix ~= "" then
      table.insert(parts, 1, node.prefix)
    end
    node = node.parent
  end
  return normalize_path(table.concat(parts, "/"))
end

function ControllerMethods:describe()
  local routes = {}
  for _, r in ipairs(self.routes) do routes[#routes + 1] = r:describe() end
  local subs = {}
  for _, c in ipairs(self.controllers) do subs[#subs + 1] = c:describe() end
  return {
    name = self.name,
    prefix = self:full_prefix(),
    guard_count = #self.guards,
    interceptor_count = #self.interceptors,
    filter_count = #self.filters,
    routes = routes,
    controllers = subs,
  }
end

--============================================================--
-- Pipe / argument resolution helpers
--============================================================--

-- Runs `pipe(value, ctx)`.
--   * pipe returns false            -> validation error (HTTP 400)
--   * pipe throws                   -> validation/transform error (HTTP 400)
--   * pipe returns nil or true      -> value unchanged
--   * pipe returns anything else    -> becomes the new value
local function apply_pipe(pipe, value, ctx, kind, name)
  if not pipe then return value end
  local ok, result = pcall(pipe, value, ctx)
  if not ok then
    error(nest.http_exception(400,
      "Pipe failed for " .. kind .. (name and (" '" .. name .. "'") or "") .. ": " .. tostring(result)))
  end
  if result == false then
    error(nest.http_exception(400,
      "Validation failed for " .. kind .. (name and (" '" .. name .. "'") or "")))
  elseif result == nil or result == true then
    return value
  else
    return result
  end
end

local function resolve_args(route, ctx)
  local args = {}
  for _, p in ipairs(route.params) do
    if p.kind == "request" then
      args[#args + 1] = ctx.req
    elseif p.kind == "response" then
      args[#args + 1] = ctx.res
    elseif p.kind == "param" then
      args[#args + 1] = apply_pipe(p.pipe, ctx.params[p.name], ctx, "param", p.name)
    elseif p.kind == "query" then
      if p.name == nil then
        args[#args + 1] = apply_pipe(p.pipe, ctx.query, ctx, "query", nil)
      else
        args[#args + 1] = apply_pipe(p.pipe, ctx.query[p.name], ctx, "query", p.name)
      end
    elseif p.kind == "header" then
      args[#args + 1] = apply_pipe(p.pipe, find_header(ctx.req.headers, p.name), ctx, "header", p.name)
    elseif p.kind == "body" then
      if p.name == nil then
        args[#args + 1] = apply_pipe(p.pipe, ctx.req.body, ctx, "body", nil)
      else
        local body = ctx.req.body
        local v = (type(body) == "table") and body[p.name] or nil
        args[#args + 1] = apply_pipe(p.pipe, v, ctx, "body", p.name)
      end
    elseif p.kind == "custom" then
      args[#args + 1] = p.selector(ctx)
    else
      error("unknown argument descriptor kind: " .. tostring(p.kind))
    end
  end
  return args
end

--============================================================--
-- Guard / interceptor composition
--============================================================--

-- Publicly exposed helper: fold several guards into one callback.
function nest.compose_guards(...)
  local guards = { ... }
  for _, g in ipairs(guards) do
    assert(type(g) == "function", "compose_guards: every guard must be a function")
  end
  return function(ctx)
    for _, g in ipairs(guards) do
      local allowed, reason = g(ctx)
      if not allowed then return false, reason end
    end
    return true
  end
end

-- Publicly exposed helper: fold several interceptors into one callback.
function nest.compose_interceptors(...)
  local interceptors = { ... }
  for _, i in ipairs(interceptors) do
    assert(type(i) == "function", "compose_interceptors: every interceptor must be a function")
  end
  return function(ctx, next_fn)
    local handler = next_fn
    for i = #interceptors, 1, -1 do
      local interceptor = interceptors[i]
      local nextHandler = handler
      handler = function() return interceptor(ctx, nextHandler) end
    end
    return handler()
  end
end

-- Publicly exposed helper: fold several exception filters into one
-- callback that tries each in order and returns the first response.
function nest.compose_filters(...)
  local filters = { ... }
  for _, f in ipairs(filters) do
    assert(type(f) == "function", "compose_filters: every filter must be a function")
  end
  return function(exception, ctx)
    for _, f in ipairs(filters) do
      local response = f(exception, ctx)
      if response then return response end
    end
    return nil
  end
end

local function compose_interceptor_chain(interceptors, final)
  local handler = final
  for i = #interceptors, 1, -1 do
    local interceptor = interceptors[i]
    local nextHandler = handler
    handler = function(ctx)
      return interceptor(ctx, function() return nextHandler(ctx) end)
    end
  end
  return handler
end

--============================================================--
-- Module
--============================================================--

Module = {}
Module.__index = Module

function nest.module(name)
  assert(type(name) == "string" and #name > 0, "nest.module(name): name must be a non-empty string")
  local self = setmetatable({}, Module)
  self.__class = "Module"
  self.name = name
  self.controllers = {}
  self.guards = {}
  self.interceptors = {}
  self.filters = {}
  self.decorators = {}
  self._built = false
  self._routes_flat = nil
  return self
end

function Module:controller(name)
  assert(nest.is_module(self), "self must be a Module")
  assert(type(name) == "string" and #name > 0, "module:controller(name): name must be a non-empty string")
  local c = new_controller(self, name, nil)
  self.controllers[#self.controllers + 1] = c
  return c
end

function Module:decorator(name, func)
  assert(nest.is_module(self), "self must be a Module")
  assert(type(name) == "string" and #name > 0, "module:decorator(name, fn): name must be a non-empty string")
  assert(type(func) == "function", "module:decorator(name, fn): fn must be a function")
  assert(RouteBuilderMethods[name] == nil, "'" .. name .. "' shadows a built-in RouteBuilder method")
  assert(ControllerMethods[name] == nil, "'" .. name .. "' shadows a built-in Controller method")
  self.decorators[name] = func
  return self
end

function Module:guard(...)
  assert(nest.is_module(self), "self must be a Module")
  local guards = { ... }
  assert(#guards > 0, "module:guard(...) requires at least one guard function")
  for _, g in ipairs(guards) do
    assert(type(g) == "function", "guard must be a function")
    self.guards[#self.guards + 1] = g
  end
  return self
end

function Module:intercept(...)
  assert(nest.is_module(self), "self must be a Module")
  local interceptors = { ... }
  assert(#interceptors > 0, "module:intercept(...) requires at least one interceptor function")
  for _, i in ipairs(interceptors) do
    assert(type(i) == "function", "interceptor must be a function")
    self.interceptors[#self.interceptors + 1] = i
  end
  return self
end

function Module:filter(...)
  assert(nest.is_module(self), "self must be a Module")
  local filters = { ... }
  assert(#filters > 0, "module:filter(...) requires at least one filter function")
  for _, f in ipairs(filters) do
    assert(type(f) == "function", "filter must be a function")
    self.filters[#self.filters + 1] = f
  end
  return self
end

-- Flattens the controller/route tree into a fast list of dispatchable
-- endpoints, compiling every path pattern once. Safe to call again if
-- the tree changes (e.g. routes added later); handle() calls this
-- lazily on first use.
function Module:build()
  assert(nest.is_module(self), "self must be a Module")
  local flat = {}

  local function walk(controller)
    for _, route in ipairs(controller.routes) do
      assert(route.built,
        "route '" .. route.name .. "' in controller '" .. controller.name .. "' was never finished with :handle()")
      for _, e in ipairs(route.endpoints) do
        local full_path = normalize_path(controller:full_prefix() .. e.path)
        flat[#flat + 1] = {
          route = route,
          controller = controller,
          method = e.method,
          path = full_path,
          compiled = compile_pattern(full_path),
        }
      end
    end
    for _, sub in ipairs(controller.controllers) do
      walk(sub)
    end
  end

  for _, c in ipairs(self.controllers) do walk(c) end

  self._routes_flat = flat
  self._built = true

  local app = setmetatable({}, {
    __index = {
      __class = "App",
      module = self,
      handle = function(_, req) return self:handle(req) end,
      describe = function(_) return self:describe() end,
    },
  })
  app.__class = "App"
  app.module = self
  return app
end

function Module:describe()
  assert(nest.is_module(self), "self must be a Module")
  local controllers = {}
  for _, c in ipairs(self.controllers) do controllers[#controllers + 1] = c:describe() end
  return {
    name = self.name,
    guard_count = #self.guards,
    interceptor_count = #self.interceptors,
    filter_count = #self.filters,
    controllers = controllers,
  }
end

local function collect_guards(mod, entry)
  local guards = {}
  for _, g in ipairs(mod.guards) do guards[#guards + 1] = g end
  local chain = {}
  local node = entry.controller
  while node do
    table.insert(chain, 1, node)
    node = node.parent
  end
  for _, c in ipairs(chain) do
    for _, g in ipairs(c.guards) do guards[#guards + 1] = g end
  end
  for _, g in ipairs(entry.route.guards) do guards[#guards + 1] = g end
  return guards
end

local function collect_interceptors(mod, entry)
  local interceptors = {}
  for _, i in ipairs(mod.interceptors) do interceptors[#interceptors + 1] = i end
  local chain = {}
  local node = entry.controller
  while node do
    table.insert(chain, 1, node)
    node = node.parent
  end
  for _, c in ipairs(chain) do
    for _, i in ipairs(c.interceptors) do interceptors[#interceptors + 1] = i end
  end
  for _, i in ipairs(entry.route.interceptors) do interceptors[#interceptors + 1] = i end
  return interceptors
end

local function collect_filters(mod, entry)
  -- Ordered outer -> inner (module, then controllers root to leaf, then
  -- route); Module:_handle_exception walks this in reverse so the most
  -- specific (route) filter gets first refusal, like Nest's filter scoping.
  local filters = {}
  for _, f in ipairs(mod.filters) do filters[#filters + 1] = f end
  local chain = {}
  local node = entry.controller
  while node do
    table.insert(chain, 1, node)
    node = node.parent
  end
  for _, c in ipairs(chain) do
    for _, f in ipairs(c.filters) do filters[#filters + 1] = f end
  end
  for _, f in ipairs(entry.route.filters) do filters[#filters + 1] = f end
  return filters
end

-- Normalizes anything caught from the guard/interceptor/pipe/handler
-- pipeline into an HttpException-shaped value: HttpExceptions raised via
-- nest:xxx_error()/nest.http_exception() pass through unchanged; anything
-- else (a plain string error, a Lua runtime error from a bug, ...) is
-- wrapped as a 500 with the original error kept as `.cause` for filters
-- that want to inspect it.
local function normalize_exception(err)
  if nest.is_http_exception(err) then return err end
  return setmetatable({
    __class = "HttpException",
    code = 500,
    body = "Internal Server Error: " .. tostring(err),
    cause = err,
  }, HttpExceptionMeta)
end

-- Runs registered exception filters (route -> controller chain -> module,
-- most specific first) against a caught exception. The first filter that
-- returns a response table wins; a filter that errors or returns
-- nil/false is skipped in favor of the next, less specific one. If no
-- filter handles it, falls back to a default response built from the
-- exception's code/body.
function Module:_handle_exception(entry, err, ctx)
  local exception = normalize_exception(err)
  local filters = collect_filters(self, entry)
  for i = #filters, 1, -1 do
    local ok, response = pcall(filters[i], exception, ctx)
    if ok and type(response) == "table" then
      response.code = response.code or exception.code
      response.headers = response.headers or {}
      if response.body == nil then response.body = exception.body end
      return response
    end
  end
  -- Default handling. Reuses ctx.res (rather than a fresh table) so
  -- anything a pipe/handler/interceptor already wrote onto it (e.g. a
  -- structured validation-error body) survives.
  ctx.res.code = exception.code
  if ctx.res.body == nil then ctx.res.body = exception.body end
  return ctx.res
end

function Module:_dispatch(entry, req, params, query)
  local res = { code = 200, headers = {}, body = nil }
  local ctx = {
    req = req,
    res = res,
    params = params,
    query = query,
    module = self,
    controller = entry.controller,
    route = entry.route,
  }

  -- Guards, pipes, interceptors and the handler all run inside a single
  -- pcall so any of them can raise an HttpException (via nest:xxx_error())
  -- or hit a genuine bug, and either way it's caught centrally and routed
  -- through Module:_handle_exception exactly the same way.
  local function run()
    for _, guard in ipairs(collect_guards(self, entry)) do
      local allowed, reason = guard(ctx)
      if not allowed then
        error(nest.http_exception(403, reason))
      end
    end

    local final = function(context)
      local args = resolve_args(entry.route, context)
      local result = entry.route.handler(unpack(args))
      if result ~= nil then
        context.res.body = result
      end
      return context.res
    end

    local composed = compose_interceptor_chain(collect_interceptors(self, entry), final)
    return composed(ctx)
  end

  local ok, result = pcall(run)
  if ok then
    return result or res
  end
  return self:_handle_exception(entry, result, ctx)
end

-- Handles one HTTP-ish request table and returns a response table.
-- Lazily builds the route table on first call if module:build() was
-- not called explicitly beforehand.
function Module:handle(req)
  assert(nest.is_module(self), "self must be a Module")
  assert(type(req) == "table", "module:handle(req): req must be a table")
  assert(type(req.method) == "string", "module:handle(req): req.method must be a string")
  assert(type(req.url) == "string", "module:handle(req): req.url must be a string")

  if not self._built then self:build() end

  local method = req.method:upper()
  local raw_path, raw_query = req.url:match("^([^%?]*)%??(.*)$")
  raw_path = normalize_path(raw_path)
  local query = parse_query(raw_query)

  for _, entry in ipairs(self._routes_flat) do
    if entry.method == method then
      local ok, params = match_path(entry.compiled, raw_path)
      if ok then
        return self:_dispatch(entry, req, params, query)
      end
    end
  end

  return { code = 404, headers = {}, body = "Not Found: " .. method .. " " .. raw_path }
end

return nest
