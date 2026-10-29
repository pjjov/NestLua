-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Schema machinery shared by every scheme type:

    * the type registry (define / methods / check / kind)
    * immutable schema objects (new / clone / with / add_rule)
    * BASE: modifiers available on every type (optional, nullable,
      default, coerce, message, transform, validate_if) plus the default
      scalar validate/parse/describe
    * the validation helpers type implementations build on (prelude,
      run_rules, type_error, apply_transforms, child_vctx)

  Type-specific constraints live in nestlua.scheme.types.*.
--]]

local json = require "nestlua.json"
local config = require "nestlua.scheme.config"
local util = require "nestlua.scheme.util"

local copy = util.copy

local schema = {}

---@class nestlua.Rule
---@field name string
---@field args any[]
---@field fn fun(value: any, vctx: nestlua.ValidationContext): boolean, string?
---@field default? string|fun(args: any[], value: any): string
---@field message? string|fun(args: any[], value: any): string

---@class nestlua.ValidationContext
---@field parent? table        the object/array holding the value
---@field root? table          the top-level value being validated
---@field path (string|integer)[]
---@field ctx? table           outer context (e.g. NestLua's request ctx)
---@field __vctx true

---@class nestlua.Schema
---@field __class "Schema"
---@field __type string
---@field rules nestlua.Rule[]
---@field transforms (fun(value: any): any)[]
---@field _optional boolean
---@field _nullable boolean
---@field _coerce boolean
---@field _default any
---@field _has_default boolean
---@field _type_message? string|function
---@field _condition? function
---@field _unknown "passthrough"|"strip"|"strict"
---@field item_schemas? nestlua.Schema[]
---@field key_schema? nestlua.Schema
---@field shape? table<string, nestlua.Schema>
---@field variants? nestlua.Schema[]

--============================================================--
-- Type registry
--============================================================--

local METHODS = {} -- type name -> methods table (constraints for that type)
local CHECKS = {}  -- type name -> function(value) -> ok[, message]
local KINDS = {}   -- type name -> built-in base kind (coercion, emptiness, describe)

--- Methods shared by every type.
local BASE = {}
schema.BASE = BASE

--- Registers a type and returns its methods table, which falls back to
--- `opts.extends`' methods (or BASE).
---@param name string
---@param opts { extends?: string, check?: function, kind?: string }
---@return table methods
function schema.define(name, opts)
  local base_methods = opts.extends and METHODS[opts.extends] or BASE
  local methods = setmetatable({}, { __index = base_methods })
  METHODS[name] = methods
  CHECKS[name] = opts.check or (opts.extends and CHECKS[opts.extends])
  KINDS[name] = opts.kind or (opts.extends and KINDS[opts.extends]) or name
  return methods
end

function schema.is_type(name) return METHODS[name] ~= nil end

function schema.methods(name) return METHODS[name] end

function schema.check(name) return CHECKS[name] end

function schema.kind(name) return KINDS[name] or name end

--============================================================--
-- Schema objects
--============================================================--

local function is_schema(x)
  return type(x) == "table" and rawget(x, "__class") == "Schema"
end
schema.is_schema = is_schema

---@return nestlua.Schema
function schema.new(type_name)
  local methods = METHODS[type_name]
  assert(methods, "unknown scheme type: " .. tostring(type_name))
  return setmetatable({
    __class = "Schema",
    __type = type_name,
    rules = {},
    transforms = {},
    _optional = false,
    _nullable = false,
    _coerce = false,
    _has_default = false,
    _unknown = "passthrough", -- objects: "passthrough" | "strip" | "strict"
  }, {
    __index = methods,
    __call = function(instance, value, ctx) return instance:validate(value, ctx) end,
  })
end

--- Shallow clone: rules/transforms/shape lists are copied, the rule and
--- child schema objects themselves are shared (they're immutable too).
---@param self nestlua.Schema
---@return nestlua.Schema
function schema.clone(self)
  local c = schema.new(self.__type)
  for k, v in pairs(self) do
    if type(v) == "table" and not is_schema(v) and k ~= "_default" then
      c[k] = copy(v)
    else
      c[k] = v
    end
  end
  return c
end

--- Clones `self`, lets `fn` modify the clone, returns it.
function schema.with(self, fn)
  assert(is_schema(self), "self must be a schema")
  local c = schema.clone(self)
  fn(c)
  return c
end

--- Appends a rule to a clone of `self`.
---   check(value, vctx) -> ok[, message]
---   default_message: string | function(args, value) -> string
function schema.add_rule(self, name, args, check, default_message)
  return schema.with(self, function(c)
    c.rules[#c.rules + 1] = { name = name, args = args or {}, fn = check, default = default_message }
  end)
end

local with = schema.with

--============================================================--
-- Modifiers (BASE)
--============================================================--

--- Accepts nil (field may be absent).
function BASE:optional()
  return with(self, function(c) c._optional = true end)
end

--- Accepts JSON null (scheme.null / json.null).
function BASE:nullable()
  return with(self, function(c) c._nullable = true end)
end

--- Replaces nil with `value` (a function is called for a fresh value).
--- Implies optional.
function BASE:default(value)
  return with(self, function(c)
    c._default = value
    c._has_default = true
  end)
end

--- Converts strings to the schema's type before checking (query/path
--- params are always strings): "42" -> 42 for number/int, "true"/"false"/
--- "1"/"0" -> boolean, "a,b" -> { "a", "b" } for arrays.
function BASE:coerce()
  return with(self, function(c) c._coerce = true end)
end

--- Custom message for the most recently added rule (or for the type
--- check if no rule was added yet). `msg` may be a string or a
--- function(args, value) -> string.
function BASE:message(msg)
  assert(type(msg) == "string" or type(msg) == "function", "message(msg): msg must be a string or function")
  return with(self, function(c)
    local last = c.rules[#c.rules]
    if last then
      local r = copy(last)
      r.message = msg
      c.rules[#c.rules] = r
    else
      c._type_message = msg
    end
  end)
end

--- Arbitrary transform run after the type check and before rules:
--- fn(value) -> new_value. The result is what parse() returns.
function BASE:transform(fn)
  assert(type(fn) == "function", "transform(fn): fn must be a function")
  return with(self, function(c) c.transforms[#c.transforms + 1] = fn end)
end

--- Only validate when predicate(value, parent, root) is truthy; otherwise
--- the value is accepted as-is (class-validator's @ValidateIf).
function BASE:validate_if(predicate)
  assert(type(predicate) == "function", "validate_if(fn): fn must be a function")
  return with(self, function(c) c._condition = predicate end)
end

--============================================================--
-- Introspection
--============================================================--

local function describe_value(v)
  if is_schema(v) then return v:describe() end
  if type(v) == "table" then
    local out = {}
    for k, x in pairs(v) do out[k] = describe_value(x) end
    return out
  end
  if type(v) == "function" then return nil end
  return v
end

local function describe_list(list)
  if not list then return nil end
  local out = {}
  for i, s in ipairs(list) do out[i] = s:describe() end
  return out
end

function BASE:describe()
  assert(is_schema(self), "describe: self must be a schema")
  local rules, rule_names = {}, {}
  for i, r in ipairs(self.rules) do
    rule_names[i] = r.name
    rules[i] = { name = r.name, args = describe_value(r.args) }
  end
  local d = {
    type = self.__type,
    kind = schema.kind(self.__type),
    optional = self._optional or self._has_default,
    nullable = self._nullable,
    coerce = self._coerce,
    rules = rules,
    rule_names = rule_names,
    item_schemas = describe_list(self.item_schemas),
    variants = describe_list(self.variants),
    key_schema = self.key_schema and self.key_schema:describe() or nil,
  }
  if self._has_default and type(self._default) ~= "function" then d.default = describe_value(self._default) end
  if self.shape then
    d.shape = {}
    for k, v in pairs(self.shape) do d.shape[k] = v:describe() end
    d.unknown = self._unknown
  end
  return d
end

--============================================================--
-- Validation helpers
--============================================================--

local function render(msg, args, value)
  if type(msg) == "function" then return msg(args, value) end
  return msg
end

local function message_for(rule, value, override)
  if rule.message then return render(rule.message, rule.args, value) end
  local default = override or rule.default or (rule.name .. " failed")
  return config.translate(rule.name, render(default, rule.args, value), rule.args, value)
end

--- Runs `self.rules` against `value`, appending messages to `errors`.
function schema.run_rules(self, value, vctx, errors)
  for _, rule in ipairs(self.rules) do
    local ok, passed, msg = pcall(rule.fn, value, vctx)
    if not ok then
      -- a rule that raises is a bug in the rule; report it without the
      -- file:line prefix so it doesn't leak into API responses
      errors[#errors + 1] = message_for(rule, value, (tostring(passed):gsub("^[^:]*:%d+: ", "")))
    elseif not passed then
      errors[#errors + 1] = message_for(rule, value, msg)
    end
  end
end

--- The single-message error list for a failed type check.
function schema.type_error(self, value, default)
  if self._type_message then return { render(self._type_message, {}, value) } end
  return { config.translate("type." .. self.__type, default, {}, value) }
end

local function required_error(self, value)
  if self._type_message then return { render(self._type_message, {}, value) } end
  return { config.translate("required", "is required", {}, value) }
end

function schema.apply_transforms(self, value)
  for _, fn in ipairs(self.transforms) do value = fn(value) end
  return value
end

-- Coerces a string to the schema's base kind; returns the value
-- unchanged if it can't be converted (the type check then reports it).
local function coerce_value(kind, value)
  if type(value) ~= "string" then return value end
  if kind == "number" or kind == "int" then
    if util.is_decimal_string(value) then return tonumber(value) end
  elseif kind == "boolean" then
    if value == "true" or value == "1" then return true end
    if value == "false" or value == "0" then return false end
  elseif kind == "array" then
    local items = {}
    for item in (value .. ","):gmatch("([^,]*),") do
      if item ~= "" then items[#items + 1] = item end
    end
    return items
  end
  return value
end

--- Validation context for the value at `key` inside `container`.
---@return nestlua.ValidationContext
function schema.child_vctx(vctx, container, key)
  local path = {}
  for i, p in ipairs(vctx.path) do path[i] = p end
  path[#path + 1] = key
  return { parent = container, root = vctx.root or container, path = path, ctx = vctx.ctx, __vctx = true }
end

--- Accepts either an outer ctx (e.g. NestLua's request ctx when used as a
--- pipe) or an internal validation ctx (when called for a nested field).
---@return nestlua.ValidationContext
function schema.as_vctx(ctx)
  if type(ctx) == "table" and ctx.__vctx then return ctx end
  return { path = {}, ctx = ctx, __vctx = true }
end

--- Shared preamble for every validate(): condition, default, nil/null
--- handling, coercion. Returns done, ok, errors, value -- when `done` is
--- true the caller returns (ok, errors, value) immediately.
function schema.prelude(self, value, vctx)
  if self._condition and not self._condition(value, vctx.parent, vctx.root) then
    return true, true, nil, value
  end
  if value == nil and self._has_default then
    if type(self._default) == "function" then value = self._default() else value = self._default end
  end
  if value == nil then
    if self._optional or self._has_default then return true, true, nil, nil end
    return true, false, required_error(self, value), nil
  end
  if json.is_null(value) then
    if self._nullable then return true, true, nil, value end
    if self._optional then return true, true, nil, nil end
    return true, false, required_error(self, value), nil
  end
  if self._coerce then value = coerce_value(schema.kind(self.__type), value) end
  return false, nil, nil, value
end

--============================================================--
-- Default validate / parse (scalar types)
--============================================================--

--- Validates `value`. Returns ok, errors, cleaned_value.
function BASE:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  local vctx = schema.as_vctx(ctx)
  local done, dok, derr, v = schema.prelude(self, value, vctx)
  if done then return dok, derr, v end
  local check = CHECKS[self.__type]
  if check then
    local tok, tmsg = check(v)
    if not tok then
      return false, schema.type_error(self, v, tmsg or ("must be a valid " .. self.__type))
    end
  end
  v = schema.apply_transforms(self, v)
  local errors = {}
  schema.run_rules(self, v, vctx, errors)
  if #errors > 0 then return false, errors end
  return true, nil, v
end

--- Validates and returns the cleaned value: (true, value) or (false, errors).
--- The cleaned value has defaults filled in, coercions/transforms
--- applied and, for :strip() objects, unknown fields removed.
---
--- This is also NestLua's pipe protocol, so a schema can be passed
--- straight to use_param/use_query/use_body/...: the argument becomes the
--- cleaned value, or the request is rejected with a 400 whose body
--- carries the structured errors.
function BASE:parse(value, ctx)
  local ok, errors, cleaned = self:validate(value, ctx)
  if ok then return true, cleaned end
  return false, errors
end

return schema
