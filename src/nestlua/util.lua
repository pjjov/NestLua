-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Small helpers shared by the core modules. Internal: not part of the
-- public API.

local util = {}

---@diagnostic disable-next-line: deprecated
util.unpack = table.unpack or unpack -- luacheck: ignore

function util.pack(...) return { n = select("#", ...), ... } end

function util.copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

function util.append_all(dst, src)
  for _, v in ipairs(src) do dst[#dst + 1] = v end
  return dst
end

function util.is_callable(x)
  if type(x) == "function" then return true end
  local mt = getmetatable(x)
  return type(mt) == "table" and type(mt.__call) == "function"
end

function util.is_instance(obj, class)
  return type(obj) == "table" and rawget(obj, "__class") == class
end

function util.is_module(obj) return util.is_instance(obj, "Module") end

function util.is_controller(obj) return util.is_instance(obj, "Controller") end

function util.is_route(obj) return util.is_instance(obj, "RouteBuilder") end

function util.is_app(obj) return util.is_instance(obj, "App") end

--============================================================--
-- Change tracking
--
-- Every structural change anywhere (new route, guard, prefix, ...) bumps
-- this counter; Module:handle() rebuilds its route table whenever the
-- generation it was built at is stale, so routes added after the first
-- request are never silently ignored.
--============================================================--

local generation = 0

function util.touch() generation = generation + 1 end

function util.generation() return generation end

--============================================================--
-- Introspection
--============================================================--

--- Copies a value for describe(): plain data only, no functions inside.
--- Tables with a describe() method (schemas, pipes) are replaced by
--- their description.
function util.plain(v, seen)
  local tv = type(v)
  if tv == "string" or tv == "number" or tv == "boolean" then return v end
  if tv ~= "table" then return nil end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  if type(v.describe) == "function" then
    local ok, d = pcall(v.describe, v)
    seen[v] = nil
    if ok then return util.plain(d, seen) end
    return nil
  end
  local out = {}
  for k, x in pairs(v) do
    if type(k) == "string" or type(k) == "number" then out[k] = util.plain(x, seen) end
  end
  seen[v] = nil
  return out
end

--============================================================--
-- Class helpers
--============================================================--

--- Builds an __index function for builder classes: static methods win,
--- then decorators registered on the owning module (module:decorator).
function util.method_index(methods)
  return function(instance, key)
    local v = methods[key]
    if v ~= nil then return v end
    local mod = rawget(instance, "_module")
    local fn = mod and mod.decorators and mod.decorators[key]
    if fn then
      return function(self, ...) return fn(self, ...) end
    end
    return nil
  end
end

--- Appends one or more callables to `list` (used by guard/intercept/
--- filter/use on every scope) and returns `self` for chaining.
function util.add_functions(self, list, what, scope, ...)
  local fns = { ... }
  assert(#fns > 0, scope .. ":" .. what .. "(...) requires at least one " .. what .. " function")
  for _, f in ipairs(fns) do
    assert(util.is_callable(f), what .. " must be a function")
    list[#list + 1] = f
  end
  util.touch()
  return self
end

function util.set_meta(self, key, value)
  assert(type(key) == "string" and #key > 0, "meta(key, value): key must be a non-empty string")
  self.metadata[key] = value
  util.touch()
  return self
end

--- Normalizes version arguments (numbers or strings) to a string list.
function util.versions(scope, ...)
  local versions = { ... }
  assert(#versions > 0, scope .. ":version(...) requires at least one version")
  for i, v in ipairs(versions) do versions[i] = tostring(v) end
  return versions
end

return util
