-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- The object type (scheme{ field = schema, ... }): unknown-field modes,
-- composition (extend/pick/omit/partial/required) and validation.

local config = require "nestlua.scheme.config"
local schema = require "nestlua.scheme.schema"
local util = require "nestlua.scheme.util"

local with, is_schema = schema.with, schema.is_schema

local object = {}

local OBJ = schema.define("object", {})

--- Asserts `shape` is a table of schemas with no field named like
--- config.self_key (used for object-level errors).
function object.check_shape(shape, where)
  assert(type(shape) == "table", where .. ": expects a table describing the object's fields")
  for k, v in pairs(shape) do
    assert(is_schema(v), where .. ": field '" .. tostring(k) .. "' must be a schema")
    assert(k ~= config.self_key, where .. ": field name '" .. tostring(k) ..
      "' collides with scheme.self_key (used for object-level errors)")
  end
end

--- New object schema with the given fields.
function object.new(shape)
  object.check_shape(shape, "scheme{...}")
  local obj = schema.new("object")
  obj.shape = util.copy(shape)
  return obj
end

--============================================================--
-- Unknown fields
--============================================================--

--- Unknown fields are reported as errors (class-validator's
--- forbidNonWhitelisted).
function OBJ:strict()
  return with(self, function(c) c._unknown = "strict" end)
end

--- Unknown fields are silently dropped from the parsed value
--- (class-validator's whitelist). Recommended for request bodies.
function OBJ:strip()
  return with(self, function(c) c._unknown = "strip" end)
end

--- Unknown fields are kept as-is (the default).
function OBJ:passthrough()
  return with(self, function(c) c._unknown = "passthrough" end)
end

--============================================================--
-- Composition
--============================================================--

--- New object schema with extra/overridden fields.
function OBJ:extend(fields)
  object.check_shape(fields, "extend")
  return with(self, function(c)
    for k, v in pairs(fields) do c.shape[k] = v end
  end)
end

--- New object schema with only the given fields.
function OBJ:pick(...)
  local names = util.value_list(...)
  return with(self, function(c)
    local shape = {}
    for _, n in ipairs(names) do
      assert(self.shape[n], "pick: unknown field '" .. tostring(n) .. "'")
      shape[n] = self.shape[n]
    end
    c.shape = shape
  end)
end

--- New object schema without the given fields.
function OBJ:omit(...)
  local names = util.value_list(...)
  return with(self, function(c)
    for _, n in ipairs(names) do c.shape[n] = nil end
  end)
end

--- New object schema where every field (or just the given ones) is
--- optional (Nest's PartialType).
function OBJ:partial(...)
  local names = util.value_list(...)
  return with(self, function(c)
    if #names == 0 then
      for k, v in pairs(c.shape) do c.shape[k] = v:optional() end
    else
      for _, n in ipairs(names) do
        assert(c.shape[n], "partial: unknown field '" .. tostring(n) .. "'")
        c.shape[n] = c.shape[n]:optional()
      end
    end
  end)
end

--- New object schema where every field is required.
function OBJ:required()
  return with(self, function(c)
    for k, v in pairs(c.shape) do
      c.shape[k] = with(v, function(f)
        f._optional = false
        f._has_default = false
        f._default = nil
      end)
    end
  end)
end

--============================================================--
-- Validation
--============================================================--

-- Validates declared fields. Returns field_errors, has_errors, cleaned.
local function validate_fields(shape, value, vctx)
  local field_errors, has_errors, cleaned = {}, false, {}
  for field, field_schema in pairs(shape) do
    local ok, err, v = field_schema:validate(value[field], schema.child_vctx(vctx, value, field))
    if ok then
      cleaned[field] = v
    else
      field_errors[field] = err
      has_errors = true
    end
  end
  return field_errors, has_errors, cleaned
end

-- Applies the unknown-field mode to fields missing from `shape`.
local function handle_unknown(mode, shape, value, cleaned, field_errors)
  local has_errors = false
  for k, x in pairs(value) do
    if shape[k] == nil then
      if mode == "strict" then
        field_errors[k] = { config.translate("unknown", "is not allowed", {}, x) }
        has_errors = true
      elseif mode == "passthrough" then
        cleaned[k] = x
      end
    end
  end
  return has_errors
end

function OBJ:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  local vctx = schema.as_vctx(ctx)
  local done, dok, derr, v = schema.prelude(self, value, vctx)
  if done then return dok, derr, v end
  if type(v) ~= "table" or (util.is_pure_array(v) and next(v) ~= nil) then
    return false, schema.type_error(self, v, "must be an object")
  end
  v = schema.apply_transforms(self, v)
  local shape = self.shape or {}
  local field_errors, has_errors, cleaned = validate_fields(shape, v, vctx)
  if handle_unknown(self._unknown, shape, v, cleaned, field_errors) then has_errors = true end

  local base_errors = {}
  if not has_errors then schema.run_rules(self, cleaned, vctx, base_errors) end
  if #base_errors > 0 or has_errors then
    if #base_errors > 0 then field_errors[config.self_key] = base_errors end
    return false, field_errors
  end
  return true, nil, cleaned
end

return object
