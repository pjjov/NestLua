-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Constraints available on every type: emptiness, membership, equality,
-- cross-field and custom rules.

local schema = require "nestlua.scheme.schema"
local util = require "nestlua.scheme.util"

local BASE, add_rule = schema.BASE, schema.add_rule
local deep_equal, value_list = util.deep_equal, util.value_list

function BASE:empty()
  local kind = schema.kind(self.__type)
  return add_rule(self, "empty", {}, function(value) return util.is_empty(value, kind) end, "must be empty")
end

function BASE:not_empty()
  local kind = schema.kind(self.__type)
  return add_rule(self, "not_empty", {}, function(value) return not util.is_empty(value, kind) end,
    "must not be empty")
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if deep_equal(v, value) then return true end
  end
  return false
end

--- One of the given values (varargs or a single list), deep comparison.
function BASE:is_in(...)
  local list = value_list(...)
  assert(#list > 0, "is_in: requires at least one allowed value")
  return add_rule(self, "is_in", { list }, function(value) return contains(list, value) end,
    "must be one of the allowed values")
end
BASE.enum = BASE.is_in

function BASE:not_in(...)
  local list = value_list(...)
  assert(#list > 0, "not_in: requires at least one disallowed value")
  return add_rule(self, "not_in", { list }, function(value) return not contains(list, value) end,
    "must not be one of the disallowed values")
end

function BASE:equals(other)
  return add_rule(self, "equals", { other }, function(value) return deep_equal(value, other) end,
    "must equal the expected value")
end

function BASE:not_equals(other)
  return add_rule(self, "not_equals", { other }, function(value) return not deep_equal(value, other) end,
    "must not equal the disallowed value")
end

--- Custom check with access to the whole value: fn(value, vctx) -> ok[, message].
--- On an object schema this is how cross-field rules are written.
function BASE:refine(fn, message)
  assert(type(fn) == "function", "refine(fn, message): fn must be a function")
  return add_rule(self, "refine", {}, fn, message or "is invalid")
end

--- Must equal the sibling field `field` of the parent object (e.g. a
--- password confirmation).
function BASE:same_as(field)
  assert(type(field) == "string", "same_as(field): field must be a string")
  return add_rule(self, "same_as", { field }, function(value, vctx)
    return vctx.parent ~= nil and deep_equal(value, vctx.parent[field])
  end, function(args) return "must match " .. args[1] end)
end
