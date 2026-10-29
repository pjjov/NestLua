-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Providers / dependency injection and module imports. Mixed into
-- nestlua.Module (see nestlua.module).

local util = require "nestlua.util"
local try = require "nestlua.try"

local is_module, is_callable = util.is_module, util.is_callable

---@class nestlua.Module
local Module = {}

--- Registers a provider. `factory(module)` is called lazily, once, the
--- first time `name` is injected; the instance is then cached (a
--- singleton per module). Factories resolve their own dependencies with
--- `module:get(other_name)`. If the instance has `on_init` /
--- `on_shutdown` methods they're called on creation / module:shutdown().
---@param name string
---@param factory fun(module: nestlua.Module): any
function Module:provide(name, factory)
  assert(is_module(self), "self must be a Module")
  assert(type(name) == "string" and #name > 0, "provide(name, factory): name must be a non-empty string")
  assert(is_callable(factory), "provide(name, factory): factory must be a function (use provide_value for values)")
  assert(self.providers[name] == nil, "provider '" .. name .. "' is already registered in module '" .. self.name .. "'")
  self.providers[name] = { factory = factory }
  return self
end

--- Registers an already-built value as a provider.
function Module:provide_value(name, value)
  assert(is_module(self), "self must be a Module")
  assert(type(name) == "string" and #name > 0, "provide_value(name, value): name must be a non-empty string")
  assert(self.providers[name] == nil, "provider '" .. name .. "' is already registered in module '" .. self.name .. "'")
  self.providers[name] = { value = value, resolved = true }
  return self
end

--- Makes providers (by name) or whole imported modules (re-export)
--- visible to modules that import this one.
function Module:export(...)
  assert(is_module(self), "self must be a Module")
  for _, e in ipairs({ ... }) do
    assert(type(e) == "string" or is_module(e), "export(...): expects provider names or modules")
    self.exports[#self.exports + 1] = e
  end
  return self
end

--- Imports another module: its routes are served under this module (its
--- own prefix, guards, interceptors, filters and middleware still
--- apply to them, nested inside this module's), and its exported
--- providers become injectable here.
function Module:import(...)
  assert(is_module(self), "self must be a Module")
  for _, m in ipairs({ ... }) do
    assert(is_module(m), "import(...): every argument must be a Module")
    assert(m ~= self, "a module cannot import itself")
    self.imports[#self.imports + 1] = m
  end
  util.touch()
  return self
end

-- The module owning the exported provider `name`, looking through `mod`'s
-- exports (and re-exported modules).
local function exported_owner(mod, name, seen)
  if seen[mod] then return nil end
  seen[mod] = true
  for _, e in ipairs(mod.exports) do
    if e == name and mod.providers[name] then return mod end
    if is_module(e) then
      local owner = exported_owner(e, name, seen)
      if owner then return owner end
    end
  end
  return nil
end

-- The module that owns the provider `name` as seen from `mod`.
local function find_owner(mod, name)
  if mod.providers[name] then return mod end
  for _, imported in ipairs(mod.imports) do
    local owner = exported_owner(imported, name, {})
    if owner then return owner end
  end
  return nil
end

--- Resolves a provider instance visible from this module.
function Module:get(name)
  assert(is_module(self), "self must be a Module")
  local owner = find_owner(self, name)
  if not owner then
    error("no provider '" .. tostring(name) .. "' is visible from module '" .. self.name ..
      "' (is it registered, exported and imported?)", 2)
  end
  local p = owner.providers[name]
  if p.resolved then return p.value end
  if p.resolving then
    error("circular dependency while resolving provider '" .. name .. "' in module '" .. owner.name .. "'", 2)
  end
  p.resolving = true
  local ok, value = try(p.factory, owner)
  p.resolving = nil
  if not ok then error(value, 0) end
  p.value, p.resolved = value, true
  owner.instances[#owner.instances + 1] = value
  if type(value) == "table" and is_callable(value.on_init) then value:on_init(owner) end
  return value
end

return Module
