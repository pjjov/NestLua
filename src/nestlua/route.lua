-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- RouteBuilder: endpoints, per-route guards/interceptors/filters,
-- metadata, response decorators and handler-argument descriptors.

local util = require "nestlua.util"
local http = require "nestlua.http"
local pattern = require "nestlua.router.pattern"
local protocol = require("nestlua.pipes").protocol

local copy, touch = util.copy, util.touch

---@class nestlua.ParamDescriptor
---@field kind string   request|response|param|query|query_array|header|body|file|inject|custom
---@field name? string
---@field pipes table[]
---@field selector? fun(ctx: table): any

---@class nestlua.RouteBuilder
---@field __class "RouteBuilder"
---@field _module nestlua.Module
---@field controller nestlua.Controller
---@field name string
---@field endpoints { method: string, path: string }[]
---@field guards function[]
---@field interceptors function[]
---@field filters function[]
---@field params nestlua.ParamDescriptor[]
---@field metadata table<string, any>
---@field response_headers table<string, string>
---@field status_code? integer
---@field versions? string[]
---@field docs table
---@field handler? function
---@field built boolean
local RouteBuilder = {}

local Meta = { __index = util.method_index(RouteBuilder) }

local route = { methods = RouteBuilder }

---@return nestlua.RouteBuilder
function route.new(module_ref, controller_ref, name)
  local self = setmetatable({
    __class = "RouteBuilder",
    _module = module_ref,
    controller = controller_ref,
    name = name,
    endpoints = {},
    guards = {},
    interceptors = {},
    filters = {},
    params = {},
    metadata = {},
    response_headers = {},
    docs = {},
    built = false,
  }, Meta)
  touch()
  return self
end

local function check(self)
  assert(util.is_route(self), "self must be a RouteBuilder")
end

--============================================================--
-- Endpoints
--============================================================--

local function add_endpoint(self, verb, path)
  check(self)
  assert(type(path) == "string" and path:sub(1, 1) == "/",
    "path must be a string starting with '/' (got " .. tostring(path) .. ")")
  assert(not self.built, "cannot register more paths on route '" .. self.name .. "' after :handle() was called")
  pattern.compile(path) -- fail fast on malformed patterns
  self.endpoints[#self.endpoints + 1] = { method = verb, path = path }
  touch()
  return self
end

for _, verb in ipairs(http.METHODS) do
  RouteBuilder[verb:lower()] = function(self, path) return add_endpoint(self, verb, path) end
end

--- Matches every HTTP method (more specific per-method routes still win).
function RouteBuilder:all(path) return add_endpoint(self, "*", path) end

--============================================================--
-- Pipeline pieces and metadata
--============================================================--

function RouteBuilder:guard(...)
  check(self)
  return util.add_functions(self, self.guards, "guard", "route", ...)
end

function RouteBuilder:intercept(...)
  check(self)
  return util.add_functions(self, self.interceptors, "interceptor", "route", ...)
end

-- Exception filters: function(exception, ctx) -> response table | nil.
-- Return a response table ({code=, headers=, body=}, any field optional)
-- to handle the exception; return nil (or throw) to defer to the next,
-- less specific filter, or to the built-in default handling if none
-- handle it. Tried route -> controller (leaf to root) -> module, i.e.
-- the most specific filter gets first refusal.
function RouteBuilder:filter(...)
  check(self)
  return util.add_functions(self, self.filters, "filter", "route", ...)
end

--- Attaches metadata readable from guards/interceptors via ctx:meta(key)
--- (Nest's SetMetadata + Reflector).
function RouteBuilder:meta(key, value)
  check(self)
  return util.set_meta(self, key, value)
end

--- Default status code for successful responses (Nest's @HttpCode).
function RouteBuilder:status(code)
  check(self)
  assert(type(code) == "number" and code >= 100 and code <= 599, "route:status(code): code must be an HTTP status")
  self.status_code = code
  touch()
  return self
end

--- Adds a response header to every response of this route (Nest's @Header).
function RouteBuilder:header(name, value)
  check(self)
  assert(type(name) == "string" and #name > 0, "route:header(name, value): name must be a non-empty string")
  assert(type(value) == "string", "route:header(name, value): value must be a string")
  self.response_headers[name] = value
  touch()
  return self
end

--- Serves this route under the given API version(s) instead of the
--- controller's (e.g. route:version("2") -> /v2/...).
function RouteBuilder:version(...)
  check(self)
  self.versions = util.versions("route", ...)
  touch()
  return self
end

--- OpenAPI documentation for this route:
--- { summary=, description=, tags={...}, deprecated=, operation_id=,
---   responses = { [200] = { description=, schema= } } }
function RouteBuilder:doc(docs)
  check(self)
  assert(type(docs) == "table", "route:doc(t): t must be a table")
  for k, v in pairs(docs) do self.docs[k] = v end
  return self
end

--============================================================--
-- Handler arguments
--============================================================--

local function add_param(self, kind, name, ...)
  local list = { ... }
  for _, p in ipairs(list) do
    assert(protocol.is_pipe(p), "use_" .. kind .. ": pipe must be a function, a callable table or a pipe")
  end
  local descriptor = { kind = kind, name = name, pipes = list }
  self.params[#self.params + 1] = descriptor
  touch()
  return self, descriptor
end

function RouteBuilder:use_request()
  return (add_param(self, "request"))
end

function RouteBuilder:use_response()
  return (add_param(self, "response"))
end

--- Adds a `:name` path param as the next handler argument, run through
--- any number of pipes (left to right).
function RouteBuilder:use_param(name, ...)
  assert(type(name) == "string" and #name > 0, "use_param: name must be a non-empty string")
  return (add_param(self, "param", name, ...))
end

--- Adds a query-string value. A repeated key yields its *last* value (use
--- use_query_array for all of them). With `name == nil`, the whole parsed
--- query table is passed instead.
function RouteBuilder:use_query(name, ...)
  assert(name == nil or type(name) == "string", "use_query: name must be a string or nil")
  return (add_param(self, "query", name, ...))
end

--- Adds every value of a (possibly repeated) query key as an array.
function RouteBuilder:use_query_array(name, ...)
  assert(type(name) == "string" and #name > 0, "use_query_array: name must be a non-empty string")
  return (add_param(self, "query_array", name, ...))
end

function RouteBuilder:use_header(name, ...)
  assert(type(name) == "string" and #name > 0, "use_header: name must be a non-empty string")
  return (add_param(self, "header", name, ...))
end

function RouteBuilder:use_body(name, ...)
  assert(name == nil or type(name) == "string", "use_body: name must be a string or nil")
  return (add_param(self, "body", name, ...))
end

--- Adds an uploaded file (from the multipart body parser) as the next argument.
function RouteBuilder:use_file(name, ...)
  assert(type(name) == "string" and #name > 0, "use_file: name must be a non-empty string")
  return (add_param(self, "file", name, ...))
end

--- Adds a provider instance (see module:provide) as the next argument.
function RouteBuilder:use_inject(name)
  assert(type(name) == "string" and #name > 0, "use_inject: name must be a non-empty string")
  return (add_param(self, "inject", name))
end

function RouteBuilder:use_custom(selector, ...)
  assert(util.is_callable(selector), "use_custom: selector must be a function")
  local _, descriptor = add_param(self, "custom", nil, ...)
  descriptor.selector = selector
  return self
end

function RouteBuilder:handle(func)
  check(self)
  assert(util.is_callable(func), "route:handle(func): func must be a function")
  assert(#self.endpoints > 0,
    "route '" .. self.name .. "' needs at least one :get/:post/:put/:patch/:delete/:all before :handle()")
  self.handler = func
  self.built = true
  touch()
  return self
end

--============================================================--
-- Introspection
--============================================================--

function RouteBuilder:describe()
  local endpoints = {}
  for i, e in ipairs(self.endpoints) do
    endpoints[i] = { method = e.method, path = e.path }
  end
  local params = {}
  for i, p in ipairs(self.params) do
    local pipe_descs = {}
    for j, pipe in ipairs(p.pipes) do pipe_descs[j] = protocol.describe(pipe) end
    params[i] = { kind = p.kind, name = p.name, pipes = pipe_descs }
  end
  return {
    name = self.name,
    endpoints = endpoints,
    params = params,
    status = self.status_code,
    headers = copy(self.response_headers),
    versions = self.versions and copy(self.versions) or nil,
    meta = util.plain(self.metadata),
    docs = util.plain(self.docs),
    guard_count = #self.guards,
    interceptor_count = #self.interceptors,
    filter_count = #self.filters,
  }
end

return route
