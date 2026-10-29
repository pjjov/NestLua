-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  A class-validator-inspired value/object validator.

    local scheme = require "nestlua.scheme"

    local ContactDtoValidator = scheme {
      phone = scheme.string:phone(),
      email = scheme.string:email(),
    }

    local RegisterUserDtoValidator = scheme {
      username = scheme.string:trim():min(3):alpha(),
      password = scheme.string:strong_password(),
      contact  = ContactDtoValidator:optional(),
    }:strip()

    local ok, errors = RegisterUserDtoValidator(obj)
    local ok, cleaned_or_errors = RegisterUserDtoValidator:parse(obj)

  Schemas are immutable: every chained call returns a new schema, so a
  base schema can be safely reused and refined in several places.

  Implementation map:
    nestlua.scheme.schema           schema objects, modifiers, validation core
    nestlua.scheme.types.common     constraints shared by every type
    nestlua.scheme.types.scalar     boolean, number, int, date
    nestlua.scheme.types.string     string
    nestlua.scheme.types.collection array, table
    nestlua.scheme.types.object     scheme{...} objects and composition
    nestlua.scheme.types.union      any_of
    nestlua.scheme.validators.*     pure string format predicates
    nestlua.scheme.dates / errors / config / util
--]]

local json = require "nestlua.json"
local config = require "nestlua.scheme.config"
local schema = require "nestlua.scheme.schema"
local util = require "nestlua.scheme.util"
local dates = require "nestlua.scheme.dates"
local errors = require "nestlua.scheme.errors"

-- type modules register themselves with nestlua.scheme.schema
require "nestlua.scheme.types.common"
require "nestlua.scheme.types.scalar"
require "nestlua.scheme.types.string"
require "nestlua.scheme.types.collection"
local object = require "nestlua.scheme.types.object"
local union = require "nestlua.scheme.types.union"

local unpack = util.unpack

local scheme = {}

scheme.is_schema = schema.is_schema
scheme.clone = schema.clone
scheme.add_rule = schema.add_rule
scheme.utf8_len = util.ulen
scheme.to_timestamp = dates.to_timestamp
scheme.flatten = errors.flatten
scheme.null = json.null
scheme.any_of = union.any_of
scheme.one_of = union.any_of

--============================================================--
-- Extensibility
--============================================================--

--- Registers a new type: scheme:type("even_int", { extends = "int", check = fn }).
--- `check(value) -> ok[, message]` is required unless `extends` names a
--- type that already has one; constraint methods are inherited from it.
function scheme:type(name, opts)
  assert(self == scheme, "call this as scheme:type(name, opts)")
  assert(type(name) == "string" and #name > 0, "type: name must be a non-empty string")
  assert(not schema.is_type(name) and rawget(scheme, name) == nil and config[name] == nil,
    "type: '" .. name .. "' already exists")
  opts = opts or {}
  assert(opts.extends == nil or type(opts.extends) == "string", "type: opts.extends must be a string")
  assert(opts.check == nil or type(opts.check) == "function",
    "type: opts.check must be a function(value) -> ok[, message]")
  if opts.extends then
    assert(schema.is_type(opts.extends), "type: unknown base type '" .. opts.extends .. "'")
  end
  assert(opts.check or (opts.extends and schema.check(opts.extends)),
    "type: opts.check is required unless extending a type that already has one")
  schema.define(name, { extends = opts.extends, check = opts.check })
  return scheme
end

--- Registers a constraint method on a type (or on every type when
--- `type_name` is nil/"any"): fn(value, ...args, vctx) -> ok[, message].
function scheme:constraint(type_name, constraint_name, fn, default_message)
  assert(self == scheme, "call this as scheme:constraint(type_name, constraint_name, fn)")
  assert(type(constraint_name) == "string" and #constraint_name > 0,
    "constraint: constraint_name must be a non-empty string")
  assert(type(fn) == "function", "constraint: fn must be a function(value, ...) -> ok[, message]")

  local target
  if type_name == nil or type_name == "any" then
    target = schema.BASE
  else
    target = schema.methods(type_name)
    assert(target, "constraint: unknown type '" .. tostring(type_name) .. "'")
  end

  target[constraint_name] = function(s, ...)
    local args = { ... }
    local n = #args
    return schema.add_rule(s, constraint_name, args, function(value, vctx)
      local call_args = { unpack(args, 1, n) }
      call_args[n + 1] = vctx
      return fn(value, unpack(call_args, 1, n + 1))
    end, default_message)
  end
  return scheme
end

--============================================================--
-- Module table: scheme.string / scheme.number / ... and scheme{...}
--============================================================--

setmetatable(scheme, {
  __index = function(_, key)
    if config[key] ~= nil then return config[key] end -- scheme.translate, scheme.self_key
    if schema.is_type(key) then return schema.new(key) end
    return nil
  end,
  __newindex = function(t, key, value)
    if config[key] ~= nil then
      config[key] = value
    else
      rawset(t, key, value)
    end
  end,
  __call = function(_, shape) return object.new(shape) end,
})

return scheme
