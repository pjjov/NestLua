-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Controller: a prefix plus routes and sub-controllers that inherit its
-- prefix, guards, interceptors, filters, metadata and version.

local util = require "nestlua.util"
local url = require "nestlua.url"
local route = require "nestlua.route"

local copy, touch = util.copy, util.touch

---@class nestlua.Controller
---@field __class "Controller"
---@field _module nestlua.Module
---@field name string
---@field parent? nestlua.Controller
---@field prefix string
---@field controllers nestlua.Controller[]
---@field routes nestlua.RouteBuilder[]
---@field guards function[]
---@field interceptors function[]
---@field filters function[]
---@field metadata table<string, any>
---@field versions? string[]
local Controller = {}

local Meta = { __index = util.method_index(Controller) }

local controller = { methods = Controller }

---@return nestlua.Controller
function controller.new(module_ref, name, parent)
  assert(util.is_module(module_ref), "module_ref must be a Module")
  local self = setmetatable({
    __class = "Controller",
    _module = module_ref,
    name = name,
    parent = parent,
    prefix = "",
    controllers = {},
    routes = {},
    guards = {},
    interceptors = {},
    filters = {},
    metadata = {},
  }, Meta)
  touch()
  return self
end

local function check(self)
  assert(util.is_controller(self), "self must be a Controller")
end

---@return nestlua.RouteBuilder
function Controller:route(name)
  check(self)
  assert(type(name) == "string" and #name > 0, "controller:route(name): name must be a non-empty string")
  local r = route.new(self._module, self, name)
  self.routes[#self.routes + 1] = r
  return r
end

--- Creates a sub-controller inheriting prefix, guards, interceptors,
--- filters, metadata and version.
---@return nestlua.Controller
function Controller:controller(name)
  check(self)
  assert(type(name) == "string" and #name > 0, "controller:controller(name): name must be a non-empty string")
  local c = controller.new(self._module, name, self)
  self.controllers[#self.controllers + 1] = c
  return c
end

function Controller:use_prefix(prefix)
  check(self)
  assert(type(prefix) == "string", "use_prefix: prefix must be a string")
  self.prefix = prefix
  touch()
  return self
end

function Controller:guard(...)
  check(self)
  return util.add_functions(self, self.guards, "guard", "controller", ...)
end

function Controller:intercept(...)
  check(self)
  return util.add_functions(self, self.interceptors, "interceptor", "controller", ...)
end

function Controller:filter(...)
  check(self)
  return util.add_functions(self, self.filters, "filter", "controller", ...)
end

function Controller:meta(key, value)
  check(self)
  return util.set_meta(self, key, value)
end

--- Serves every route below this controller under the given API
--- version(s) (inherited by sub-controllers, overridable per route).
function Controller:version(...)
  check(self)
  self.versions = util.versions("controller", ...)
  touch()
  return self
end

--- Root-to-leaf list of this controller and its ancestors.
---@return nestlua.Controller[]
function Controller:chain()
  local chain = {}
  local node = self
  while node do
    table.insert(chain, 1, node)
    node = node.parent
  end
  return chain
end

function Controller:full_prefix()
  local parts = {}
  for _, node in ipairs(self:chain()) do
    if node.prefix ~= "" then parts[#parts + 1] = node.prefix end
  end
  return url.normalize_path(table.concat(parts, "/"))
end

--- The versions a route is served under: its own, or the nearest
--- controller's, or nil (unversioned).
---@param r nestlua.RouteBuilder
---@return string[]?
function controller.effective_versions(r)
  if r.versions then return r.versions end
  local node = r.controller
  while node do
    if node.versions then return node.versions end
    node = node.parent
  end
  return nil
end

function Controller:describe()
  local routes = {}
  for i, r in ipairs(self.routes) do routes[i] = r:describe() end
  local subs = {}
  for i, c in ipairs(self.controllers) do subs[i] = c:describe() end
  return {
    name = self.name,
    prefix = self:full_prefix(),
    versions = self.versions and copy(self.versions) or nil,
    meta = util.plain(self.metadata),
    guard_count = #self.guards,
    interceptor_count = #self.interceptors,
    filter_count = #self.filters,
    routes = routes,
    controllers = subs,
  }
end

return controller
