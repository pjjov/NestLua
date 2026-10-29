-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Converts scheme / pipe describe() output into JSON Schema (2020-12).

local json = require "nestlua.json"

local array = json.array

local schema = {}

local STRING_FORMATS = {
  email = "email", url = "uri", uuid = "uuid", date_string = "date-time",
  hostname = "hostname", json = "json", jwt = "jwt", base64 = "byte",
}

local function rule_map(d)
  local m = {}
  for _, r in ipairs(d.rules or {}) do m[r.name] = r.args or {} end
  return m
end

--- True for a scheme schema description (as opposed to a pipe's).
function schema.is_scheme(d)
  return type(d) == "table" and d.kind ~= nil and d.rules ~= nil
end

local convert

local function convert_list(list)
  local out = array()
  for i, item in ipairs(list or {}) do out[i] = convert(item) end
  return out
end

-- min/max/range rules -> JSON Schema bounds named lo_key/hi_key
local function bounds(s, rules, lo_key, hi_key)
  if rules.min then s[lo_key] = rules.min[1] end
  if rules.max then s[hi_key] = rules.max[1] end
  if rules.range then s[lo_key], s[hi_key] = rules.range[1], rules.range[2] end
end

-- kind -> function(schema_out, rules, description)
local KINDS = {}

function KINDS.string(s, rules)
  s.type = "string"
  bounds(s, rules, "minLength", "maxLength")
  for name, fmt in pairs(STRING_FORMATS) do
    if rules[name] then s.format = fmt end
  end
  if rules.ip_address then
    local v = rules.ip_address[1]
    s.format = (v == "v6" or v == 6) and "ipv6" or "ipv4"
  end
  if rules.matches then s["x-lua-pattern"] = rules.matches[1] end
  if rules.not_empty then s.minLength = math.max(s.minLength or 0, 1) end
end

function KINDS.number(s, rules)
  s.type = "number"
  bounds(s, rules, "minimum", "maximum")
  if rules.positive then s.exclusiveMinimum = 0 end
  if rules.negative then s.exclusiveMaximum = 0 end
  if rules.divisible_by then s.multipleOf = rules.divisible_by[1] end
end

function KINDS.int(s, rules)
  KINDS.number(s, rules)
  s.type = "integer"
end

function KINDS.boolean(s)
  s.type = "boolean"
end

function KINDS.date(s)
  s.type = "string"
  s.format = "date-time"
end

function KINDS.array(s, rules, d)
  s.type = "array"
  if d.item_schemas then
    if #d.item_schemas == 1 then
      s.items = convert(d.item_schemas[1])
    else
      s.items = { anyOf = convert_list(d.item_schemas) }
    end
  end
  bounds(s, rules, "minItems", "maxItems")
  if rules.not_empty then s.minItems = math.max(s.minItems or 0, 1) end
  if rules.unique then s.uniqueItems = true end
end

function KINDS.table(s, rules, d)
  s.type = "object"
  if d.item_schemas and #d.item_schemas == 1 then
    s.additionalProperties = convert(d.item_schemas[1])
  end
  if rules.min then s.minProperties = rules.min[1] end
  if rules.max then s.maxProperties = rules.max[1] end
end

function KINDS.object(s, _, d)
  s.type = "object"
  s.properties = {}
  local required = array()
  local names = {}
  for name in pairs(d.shape or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local field = d.shape[name]
    s.properties[name] = convert(field)
    if not field.optional then required[#required + 1] = name end
  end
  if #required > 0 then s.required = required end
  if d.unknown == "strict" then s.additionalProperties = false end
end

function KINDS.union(s, _, d)
  s.anyOf = convert_list(d.variants)
end

-- enum / const / default / nullable apply to every kind
local function common(s, rules, d)
  if rules.is_in then
    local enum = array()
    for i, v in ipairs(rules.is_in[1] or {}) do enum[i] = v end
    s.enum = enum
  end
  if rules.equals and type(rules.equals[1]) ~= "table" then s.const = rules.equals[1] end
  if d.default ~= nil then s.default = d.default end
  if d.nullable then
    if s.type then
      s.type = array({ s.type, "null" })
    else
      s = { anyOf = array({ s, { type = "null" } }) }
    end
  end
  return s
end

convert = function(d)
  if not schema.is_scheme(d) then
    -- a nest.pipes.* description is already JSON-Schema shaped
    local out = {}
    for k, v in pairs(d or {}) do
      if k ~= "optional" then out[k] = v end
    end
    return out
  end
  local rules = rule_map(d)
  local s = {}
  local kind = KINDS[d.kind]
  if kind then kind(s, rules, d) end
  return common(s, rules, d)
end

--- Converts a scheme describe() table (or a pipe description) into a
--- JSON Schema table.
schema.from_describe = convert

--- Combines every pipe description on a parameter into one schema (a
--- scheme schema beats a bare pipe description; later pipes fill in
--- missing keys). Returns schema, optional.
function schema.from_pipes(pipe_descriptions)
  local result, optional = nil, false
  for _, d in ipairs(pipe_descriptions or {}) do
    if type(d) == "table" then
      if d.optional or d.default ~= nil then optional = true end
      local s = convert(d)
      if schema.is_scheme(d) or result == nil or next(result) == nil then
        if next(s) ~= nil then result = s end
      else
        for k, v in pairs(s) do
          if result[k] == nil then result[k] = v end
        end
      end
    end
  end
  return result or { type = "string" }, optional
end

return schema
