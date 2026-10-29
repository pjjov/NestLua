-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Route table construction. Mixed into nestlua.Module (see
  nestlua.module): build() flattens the module/import/controller/route
  tree into per-method endpoint lists sorted by specificity, compiling
  every path pattern and precomputing each endpoint's guard /
  interceptor / filter / middleware chain once.
--]]

local util = require "nestlua.util"
local url = require "nestlua.url"
local http = require "nestlua.http"
local response = require "nestlua.response"
local compose = require "nestlua.compose"
local pattern = require "nestlua.router.pattern"
local args = require "nestlua.router.args"
local controller = require "nestlua.controller"

local unpack, copy, append_all = util.unpack, util.copy, util.append_all

---@class nestlua.Endpoint
---@field root nestlua.Module
---@field module nestlua.Module          owning module
---@field module_chain nestlua.Module[]  root -> ... -> owning module
---@field controller nestlua.Controller
---@field route nestlua.RouteBuilder
---@field method string                  HTTP method or "*"
---@field path string                    full path pattern
---@field compiled nestlua.CompiledPattern
---@field guards function[]
---@field filters function[]
---@field meta table<string, any>        merged module < controller < route metadata
---@field order integer                  registration order
---@field run fun(ctx: table): table     middleware -> guards -> interceptors -> handler

---@class nestlua.Module
local Module = {}

-- Calls visit(module, chain) for every module reachable through imports,
-- depth-first, where chain is root -> ... -> module.
local function walk_modules(root, visit)
  local function walk(mod, chain, stack)
    if stack[mod] then error("circular module import involving '" .. mod.name .. "'") end
    stack[mod] = true
    local my_chain = copy(chain)
    my_chain[#my_chain + 1] = mod
    visit(mod, my_chain)
    for _, m in ipairs(mod.imports) do walk(m, my_chain, stack) end
    stack[mod] = nil
  end
  walk(root, {}, {})
end

-- Concatenates guards/interceptors/filters/middleware and merges metadata
-- from the module chain, the controller chain and the route, outermost
-- first.
local function collect(module_chain, ctrl, r)
  local c = { guards = {}, interceptors = {}, filters = {}, middleware = {}, meta = {} }
  local function add(scope)
    append_all(c.guards, scope.guards)
    append_all(c.interceptors, scope.interceptors)
    append_all(c.filters, scope.filters)
    for k, v in pairs(scope.metadata) do c.meta[k] = v end
  end
  for i, m in ipairs(module_chain) do
    add(m)
    if i > 1 then append_all(c.middleware, m.middleware) end -- root middleware runs pre-routing
  end
  for _, node in ipairs(ctrl:chain()) do add(node) end
  add(r)
  return c
end

-- The innermost step: resolve arguments, call the handler, store its result.
local function handler_step(r)
  return function(ctx)
    local list, n = args.resolve(r, ctx)
    local result = r.handler(unpack(list, 1, n))
    if response.is_response(result) then
      response.apply(ctx.res, result)
    elseif result ~= nil then
      ctx.res.body = result
    end
    return ctx.res
  end
end

local function guard_step(guards, inner)
  return function(ctx)
    for _, guard in ipairs(guards) do
      local allowed, reason = guard(ctx)
      if not allowed then http.raise(403, reason) end
    end
    return inner(ctx)
  end
end

---@return nestlua.Endpoint
local function make_endpoint(root, module_chain, ctrl, r, method, full_path, order)
  local c = collect(module_chain, ctrl, r)
  local inner = compose.chain(c.interceptors, handler_step(r))
  return {
    root = root,
    module = module_chain[#module_chain],
    module_chain = module_chain,
    controller = ctrl,
    route = r,
    method = method,
    path = full_path,
    compiled = pattern.compile(full_path),
    guards = c.guards,
    filters = c.filters,
    meta = c.meta,
    order = order,
    run = compose.chain(c.middleware, guard_step(c.guards, inner)),
  }
end

--- Flattens the tree into per-method endpoint lists sorted by
--- specificity and runs on_init hooks the first time. handle() calls this
--- automatically whenever the tree changed since the last build, so
--- calling it explicitly is optional. Raises on unfinished or duplicate
--- routes.
---@return table app
function Module:build()
  assert(util.is_module(self), "self must be a Module")
  local by_method, flat, signatures = {}, {}, {}
  local order = 0

  local function add(endpoint)
    local key = endpoint.method .. " " .. endpoint.compiled.signature
    local clash = signatures[key]
    if clash then
      error("duplicate route: " .. endpoint.method .. " " .. endpoint.path .. " (route '" .. endpoint.route.name ..
        "') conflicts with route '" .. clash.route.name .. "' (" .. clash.path .. ")", 3)
    end
    signatures[key] = endpoint
    by_method[endpoint.method] = by_method[endpoint.method] or {}
    table.insert(by_method[endpoint.method], endpoint)
    flat[#flat + 1] = endpoint
  end

  walk_modules(self, function(mod, module_chain)
    local prefixes = {}
    for i, m in ipairs(module_chain) do prefixes[i] = m.prefix end
    local mod_prefix = url.join_paths(unpack(prefixes))

    local function walk(ctrl)
      for _, r in ipairs(ctrl.routes) do
        assert(r.built,
          "route '" .. r.name .. "' in controller '" .. ctrl.name .. "' was never finished with :handle()")
        for _, version in ipairs(controller.effective_versions(r) or { false }) do
          local version_seg = version and (mod.version_prefix .. version) or nil
          for _, e in ipairs(r.endpoints) do
            order = order + 1
            local full_path = url.join_paths(mod_prefix, version_seg, ctrl:full_prefix(), e.path)
            add(make_endpoint(self, module_chain, ctrl, r, e.method, full_path, order))
          end
        end
      end
      for _, sub in ipairs(ctrl.controllers) do walk(sub) end
    end
    for _, c in ipairs(mod.controllers) do walk(c) end
  end)

  for _, list in pairs(by_method) do table.sort(list, pattern.more_specific) end

  self._by_method = by_method
  self._routes_flat = flat
  self._pipeline = nil
  self._built_generation = util.generation()

  self:_run_init_hooks()

  local app = setmetatable({ __class = "App", module = self }, {
    __index = {
      handle = function(_, req) return self:handle(req) end,
      describe = function(_) return self:describe() end,
      shutdown = function(_) return self:shutdown() end,
    },
  })
  return app
end

--- Builds if anything changed since the last build.
function Module:_ensure_built()
  if self._built_generation ~= util.generation() then self:build() end
end

--- Plain-table description of every endpoint (full path, method, route
--- description, owning controller/module) in registration order. Used by
--- the OpenAPI generator.
function Module:routes()
  assert(util.is_module(self), "self must be a Module")
  self:_ensure_built()
  local list = {}
  for i, e in ipairs(self._routes_flat) do
    local names = {}
    for j, c in ipairs(e.controller:chain()) do names[j] = c.name end
    list[i] = {
      method = e.method,
      path = e.path,
      module = e.module.name,
      controller = e.controller.name,
      controllers = names,
      route = e.route:describe(),
      meta = util.plain(e.meta),
      guard_count = #e.guards,
    }
  end
  return list
end

return Module
