-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Collection types: array (1..n sequences) and table (any map).

local json = require "nestlua.json"
local config = require "nestlua.scheme.config"
local schema = require "nestlua.scheme.schema"
local util = require "nestlua.scheme.util"

local add_rule, is_schema = schema.add_rule, schema.is_schema
local deep_equal = util.deep_equal

--============================================================--
-- Shared constraints
--============================================================--

local function item_schemas(methods)
  --- Items must match any one of the given schemas.
  function methods:of(...)
    local schemas = { ... }
    assert(#schemas > 0, "of: requires at least one item schema")
    for _, s in ipairs(schemas) do
      assert(is_schema(s), "of: every argument must be a schema")
    end
    return schema.with(self, function(c) c.item_schemas = schemas end)
  end
end

local function count_constraints(methods, counter, unit)
  function methods:min(n)
    assert(type(n) == "number", "min: n must be a number")
    return add_rule(self, "min", { n }, function(value) return counter(value) >= n end,
      function(a) return "must contain at least " .. tostring(a[1]) .. " " .. unit end)
  end

  function methods:max(n)
    assert(type(n) == "number", "max: n must be a number")
    return add_rule(self, "max", { n }, function(value) return counter(value) <= n end,
      function(a) return "must contain at most " .. tostring(a[1]) .. " " .. unit end)
  end

  function methods:range(lo, hi)
    assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
    return add_rule(self, "range", { lo, hi }, function(value)
      local c = counter(value)
      return c >= lo and c <= hi
    end, function(a) return "must contain between " .. tostring(a[1]) .. " and " .. tostring(a[2]) .. " " .. unit end)
  end

  function methods:contains(v)
    return add_rule(self, "contains", { v }, function(value)
      for _, item in pairs(value) do
        if deep_equal(item, v) then return true end
      end
      return false
    end, "must contain the required value")
  end

  function methods:not_contains(v)
    return add_rule(self, "not_contains", { v }, function(value)
      for _, item in pairs(value) do
        if deep_equal(item, v) then return false end
      end
      return true
    end, "must not contain the disallowed value")
  end
end

--============================================================--
-- Shared validation
--============================================================--

-- Validates each { key, item } entry against `schemas` (an item is valid
-- if it matches any of them). Returns item_errors, has_errors, cleaned.
local function validate_items(schemas, entries, vctx, container)
  local item_errors, has_errors, cleaned = {}, false, {}
  for _, entry in ipairs(entries) do
    local key, item = entry[1], entry[2]
    if not schemas then
      cleaned[key] = item
    else
      local matched, attempts = false, {}
      local ivctx = schema.child_vctx(vctx, container, key)
      for _, s in ipairs(schemas) do
        local ok, err, value = s:validate(item, ivctx)
        if ok then
          matched = true
          cleaned[key] = value
          break
        end
        attempts[#attempts + 1] = err
      end
      if not matched then
        has_errors = true
        item_errors[key] = (#schemas == 1) and attempts[1] or attempts
      end
    end
  end
  return item_errors, has_errors, cleaned
end

-- Runs container-level rules (only once the items are valid) and builds
-- the final (ok, errors, cleaned) result.
local function finish(self, vctx, item_errors, has_item_errors, cleaned)
  local errors = {}
  if not has_item_errors then schema.run_rules(self, cleaned, vctx, errors) end
  if #errors > 0 or has_item_errors then
    if #errors > 0 then item_errors[config.self_key] = errors end
    return false, item_errors
  end
  return true, nil, cleaned
end

--============================================================--
-- array
--============================================================--

local ARR = schema.define("array", {})
item_schemas(ARR)
count_constraints(ARR, function(v) return #v end, "item(s)")

--- Every item must be distinct (deep comparison).
function ARR:unique()
  return add_rule(self, "unique", {}, function(value)
    for i = 1, #value do
      for j = i + 1, #value do
        if deep_equal(value[i], value[j]) then return false end
      end
    end
    return true
  end, "must not contain duplicate items")
end

function ARR:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  local vctx = schema.as_vctx(ctx)
  local done, dok, derr, v = schema.prelude(self, value, vctx)
  if done then return dok, derr, v end
  if not util.is_pure_array(v) then
    return false, schema.type_error(self, v, "must be an array")
  end
  v = schema.apply_transforms(self, v)
  local entries = {}
  for i, item in ipairs(v) do entries[i] = { i, item } end
  local item_errors, has_errors, cleaned = validate_items(self.item_schemas, entries, vctx, v)
  return finish(self, vctx, item_errors, has_errors, json.array(cleaned))
end

--============================================================--
-- table
--============================================================--

local TBL = schema.define("table", {})
item_schemas(TBL)
count_constraints(TBL, util.table_count, "entrie(s)")

--- Every key must match `key_schema` (e.g. scheme.string:matches("^%l+$")).
function TBL:keys(key_schema)
  assert(is_schema(key_schema), "keys(schema): schema must be a schema")
  return schema.with(self, function(c) c.key_schema = key_schema end)
end

-- Adds "key ..." messages for keys failing `key_schema`.
local function validate_keys(key_schema, entries, item_errors)
  local has_errors = false
  for _, entry in ipairs(entries) do
    local key = entry[1]
    local ok, err = key_schema:validate(key)
    if not ok then
      has_errors = true
      local e = item_errors[key]
      if type(e) ~= "table" then e = {} end
      for _, m in ipairs(err) do e[#e + 1] = "key " .. m end
      item_errors[key] = e
    end
  end
  return has_errors
end

function TBL:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  local vctx = schema.as_vctx(ctx)
  local done, dok, derr, v = schema.prelude(self, value, vctx)
  if done then return dok, derr, v end
  if type(v) ~= "table" then
    return false, schema.type_error(self, v, "must be a table")
  end
  v = schema.apply_transforms(self, v)
  local entries = {}
  for k, item in pairs(v) do entries[#entries + 1] = { k, item } end
  local item_errors, has_errors, cleaned = validate_items(self.item_schemas, entries, vctx, v)
  if self.key_schema and validate_keys(self.key_schema, entries, item_errors) then has_errors = true end
  return finish(self, vctx, item_errors, has_errors, cleaned)
end
