-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Request dispatch. Mixed into nestlua.Module (see nestlua.module).

    handle(req)
      root middleware (pre-routing, every request)
        -> routing: 404 / 405 / automatic OPTIONS, HEAD -> GET fallback
        -> endpoint.run: imported-module middleware, guards,
           interceptors, pipes, handler
      errors anywhere -> exception filters -> default response
--]]

local util = require "nestlua.util"
local url = require "nestlua.url"
local http = require "nestlua.http"
local try = require "nestlua.try"
local compose = require "nestlua.compose"
local pattern = require "nestlua.router.pattern"

---@class nestlua.Module
local Module = {}

--============================================================--
-- Request context
--============================================================--

---@class nestlua.Context
---@field req table
---@field res table
---@field method string
---@field path string
---@field segments string[]
---@field params table<string, string>
---@field query table
---@field root nestlua.Module
---@field module? nestlua.Module
---@field controller? nestlua.Controller
---@field route? nestlua.RouteBuilder
---@field entry? nestlua.Endpoint
local Context = {}
local ContextMeta = { __index = Context }

--- Resolves a provider as seen from the matched route's module (or the
--- root module before routing).
function Context:inject(name)
  return (self.module or self.root):get(name)
end

--- Reads route metadata, falling back to the controller chain (leaf
--- first) and then to the module chain.
function Context:meta(key)
  if not self.entry then return self.root.metadata[key] end
  return self.entry.meta[key]
end

local function new_context(root, req)
  local path, raw_query = url.split_url(req.url)
  local query
  if type(req.query) == "table" and raw_query == "" then
    query = req.query -- pre-parsed by the adapter
  else
    query = url.parse_query(raw_query)
  end
  req.headers = req.headers or {}
  return setmetatable({
    req = req,
    res = { code = 200, headers = {}, body = nil },
    method = req.method:upper(),
    path = path,
    segments = url.split_path(path),
    params = {},
    query = query,
    root = root,
  }, ContextMeta)
end

--============================================================--
-- Exceptions
--============================================================--

-- Runs exception filters (route -> controller chain -> module chain, most
-- specific first) against a caught error. The first filter returning a
-- response table wins; a filter that errors (logged) or returns nil is
-- skipped in favor of the next, less specific one. If none handles it,
-- the exception's code/headers/body are applied on top of ctx.res, so
-- anything a pipe/handler/interceptor already wrote there survives.
function Module:_handle_exception(entry, err, ctx, traceback)
  local exception = http.normalize(err, traceback, self._expose_errors)
  if exception.cause ~= nil then
    self:_log("error", ctx.method .. " " .. ctx.req.url .. " failed", exception.cause, exception.traceback, ctx)
  end
  local filters = entry and entry.filters or self.filters
  for i = #filters, 1, -1 do
    local ok, res, tb = try(filters[i], exception, ctx)
    if not ok then
      self:_log("warn", "exception filter raised an error and was skipped", res, tb, ctx)
    elseif type(res) == "table" then
      res.code = res.code or exception.code
      res.headers = res.headers or {}
      if res.body == nil then res.body = exception.body end
      return res
    end
  end
  local res = ctx.res
  res.code = exception.code
  for k, v in pairs(exception.headers or {}) do res.headers[k] = v end
  if res.body == nil then res.body = exception.body end
  return res
end

--============================================================--
-- Routing
--============================================================--

local function find_endpoint(mod, method, segs)
  for _, key in ipairs({ method, "*" }) do
    for _, entry in ipairs(mod._by_method[key] or {}) do
      local params = pattern.match(entry.compiled, segs)
      if params then return entry, params end
    end
  end
  return nil
end

-- Methods with an endpoint matching `segs`, for Allow headers.
local function allowed_methods(mod, segs)
  local set = {}
  for method, list in pairs(mod._by_method) do
    for _, entry in ipairs(list) do
      if pattern.match(entry.compiled, segs) then
        if method == "*" then
          for _, m in ipairs(http.METHODS) do set[m] = true end
        else
          set[method] = true
        end
        break
      end
    end
  end
  if set.GET then set.HEAD = true end
  if next(set) then set.OPTIONS = true end
  local allowed = {}
  for _, m in ipairs(http.METHODS) do
    if set[m] then allowed[#allowed + 1] = m end
  end
  return allowed
end

-- No endpoint matched: automatic OPTIONS, 405 or 404.
function Module:_unmatched(ctx)
  local allowed = allowed_methods(self, ctx.segments)
  if #allowed == 0 then
    return self:_handle_exception(nil, http.exception(404, "Not Found: " .. ctx.method .. " " .. ctx.path), ctx)
  end
  local allow = table.concat(allowed, ", ")
  if ctx.method == "OPTIONS" then
    ctx.res.code = 204
    ctx.res.headers["Allow"] = allow
    return ctx.res
  end
  return self:_handle_exception(nil,
    http.exception(405, "Method Not Allowed: " .. ctx.method .. " " .. ctx.path, { Allow = allow }), ctx)
end

-- Pipeline step after the root middleware: route the request and run the
-- endpoint, turning errors into responses here so root middleware always
-- gets a response back from next().
function Module:_route(ctx)
  local entry, params = find_endpoint(self, ctx.method, ctx.segments)
  if not entry and ctx.method == "HEAD" then
    entry, params = find_endpoint(self, "GET", ctx.segments)
  end
  if not entry then return self:_unmatched(ctx) end

  ctx.entry = entry
  ctx.params = params
  ctx.module = entry.module
  ctx.controller = entry.controller
  ctx.route = entry.route
  if entry.route.status_code then ctx.res.code = entry.route.status_code end
  for k, v in pairs(entry.route.response_headers) do ctx.res.headers[k] = v end

  local ok, result, tb = try(entry.run, ctx)
  if ok then return result or ctx.res end
  return self:_handle_exception(entry, result, ctx, tb)
end

--- Handles one HTTP-ish request table and returns a response table.
--- (Re)builds the route table first if anything changed since the last
--- build.
---@param req table
---@return table response
function Module:handle(req)
  assert(util.is_module(self), "self must be a Module")
  assert(type(req) == "table", "module:handle(req): req must be a table")
  assert(type(req.method) == "string", "module:handle(req): req.method must be a string")
  assert(type(req.url) == "string", "module:handle(req): req.url must be a string")

  self:_ensure_built()
  if not self._pipeline then
    self._pipeline = compose.chain(self.middleware, function(c) return self:_route(c) end)
  end

  local ctx = new_context(self, req)
  local ok, res, tb = try(self._pipeline, ctx)
  if not ok then res = self:_handle_exception(ctx.entry, res, ctx, tb) end
  res = res or ctx.res
  res.code = res.code or 200
  res.headers = res.headers or {}
  if ctx.method == "HEAD" then res.body = nil end
  return res
end

return Module
