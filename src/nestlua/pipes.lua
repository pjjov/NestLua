-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Pipes: argument validation / transformation.

  A pipe is one of:
    * a function(value, ctx) -> result[, detail]
        result == false        -> 400; a table `detail` becomes the
                                  structured `errors` of the response
        result == nil / true   -> value unchanged
        anything else          -> becomes the new value
    * a table with a :parse(value, ctx) -> ok, value_or_errors method
        (nestlua.scheme schemas and the built-ins below implement this;
        unlike the function form it can produce `false`/`nil` values)
    * any other callable table, treated like the function form

  This module exports the protocol helpers (is_pipe, call, new) and the
  built-in pipes, which the facade exposes as `nest.pipes`.
--]]

local util = require "nestlua.util"

local copy, is_callable = util.copy, util.is_callable

local pipes = {}

-- Protocol helpers live in a separate table so `nest.pipes` only lists pipes.
local protocol = {}

function protocol.is_pipe(x)
  if type(x) == "table" and type(x.parse) == "function" then return true end
  return is_callable(x)
end

--- Runs one pipe. Returns ok, value_or_detail.
function protocol.call(pipe, value, ctx)
  if type(pipe) == "table" and type(pipe.parse) == "function" then
    local ok, result = pipe:parse(value, ctx)
    if ok then return true, result end
    return false, result
  end
  local result, detail = pipe(value, ctx)
  if result == false then return false, detail end
  if result == nil or result == true then return true, value end
  return true, result
end

--- Builds a reusable pipe from `fn(value, ctx) -> ok, value_or_error`.
--- `describe` (optional) is a plain table merged into describe()/OpenAPI
--- output, e.g. `{ type = "integer" }`.
---@param fn fun(value: any, ctx: table): boolean, any
---@param describe? table
function protocol.new(fn, describe)
  assert(type(fn) == "function", "nest.pipe(fn): fn must be a function")
  local d = describe or {}
  return {
    __class = "Pipe",
    parse = function(_, value, ctx) return fn(value, ctx) end,
    describe = function() return copy(d) end,
  }
end

--- Plain description of a pipe for describe()/OpenAPI.
function protocol.describe(pipe)
  if type(pipe) == "table" and type(pipe.describe) == "function" then
    local ok, d = pcall(pipe.describe, pipe)
    if ok then return util.plain(d) end
  end
  return { type = "custom" }
end

local new_pipe, call_pipe, is_pipe = protocol.new, protocol.call, protocol.is_pipe

--============================================================--
-- Built-in pipes
--============================================================--

local function required(value)
  if value == nil or value == "" then return false, "is required" end
  return true
end

-- A repeated query key arrives as an array; the scalar pipes look at its
-- last value, mirroring use_query().
local function scalar(value)
  if type(value) == "table" then return value[#value] end
  return value
end

local DECIMAL = {
  "^[-+]?%d+%.?%d*$", "^[-+]?%d*%.%d+$", "^[-+]?%d+%.?%d*[eE][-+]?%d+$", "^[-+]?%d*%.%d+[eE][-+]?%d+$",
}

local function is_decimal(s)
  for _, p in ipairs(DECIMAL) do
    if s:match(p) then return true end
  end
  return false
end

--- Parses a decimal integer string ("42", "-7"). Rejects floats, hex, blanks.
pipes.int = new_pipe(function(value)
  value = scalar(value)
  local ok, err = required(value)
  if not ok then return false, err end
  if type(value) == "number" then
    if value == math.floor(value) then return true, value end
    return false, "must be an integer"
  end
  if type(value) ~= "string" or not value:match("^[-+]?%d+$") then return false, "must be an integer" end
  return true, tonumber(value)
end, { type = "integer" })

--- Parses a decimal number string ("3.14", "-1e3"). Rejects hex, nan, inf.
pipes.number = new_pipe(function(value)
  value = scalar(value)
  local ok, err = required(value)
  if not ok then return false, err end
  if type(value) == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return false, "must be a finite number" end
    return true, value
  end
  if type(value) ~= "string" or not is_decimal(value) then return false, "must be a number" end
  return true, tonumber(value)
end, { type = "number" })
pipes.float = pipes.number

--- Parses "true"/"false" (and real booleans) into a boolean.
pipes.bool = new_pipe(function(value)
  value = scalar(value)
  if type(value) == "boolean" then return true, value end
  local ok, err = required(value)
  if not ok then return false, err end
  if value == "true" then return true, true end
  if value == "false" then return true, false end
  return false, "must be 'true' or 'false'"
end, { type = "boolean" })

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-(%x)%x%x%x%-[89abAB]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function uuid_ok(s, version)
  if type(s) ~= "string" then return false end
  local v = s:match(UUID)
  if not v then
    -- the nil UUID has no variant bits
    return s == "00000000-0000-0000-0000-000000000000" and version == nil
  end
  return version == nil or tonumber(v, 16) == version
end

local function uuid_pipe(version)
  local suffix = version and (" version " .. version) or ""
  return new_pipe(function(value)
    value = scalar(value)
    if uuid_ok(value, version) then return true, value end
    return false, "must be a valid" .. suffix .. " UUID"
  end, { type = "string", format = "uuid" })
end

--- Validates a UUID string: pipes.uuid (any version) or pipes.uuid(4).
pipes.uuid = setmetatable({}, {
  __index = uuid_pipe(nil),
  __call = function(_, version)
    assert(type(version) == "number", "pipes.uuid(version): version must be a number")
    return uuid_pipe(version)
  end,
})

--- Accepts only one of the given values (varargs or a single list).
function pipes.enum(...)
  local list = { ... }
  if #list == 1 and type(list[1]) == "table" then list = list[1] end
  assert(#list > 0, "pipes.enum(...): requires at least one value")
  local names = {}
  for i, v in ipairs(list) do names[i] = tostring(v) end
  local message = "must be one of: " .. table.concat(names, ", ")
  return new_pipe(function(value)
    value = scalar(value)
    for _, v in ipairs(list) do
      if v == value then return true, value end
    end
    return false, message
  end, { enum = copy(list) })
end

--- Replaces a missing (nil or "") value with `default` (called if it's a
--- function, so tables aren't shared between requests).
function pipes.default(default)
  return new_pipe(function(value)
    if value == nil or value == "" then
      if type(default) == "function" then return true, default() end
      return true, default
    end
    return true, value
  end, { default = type(default) ~= "function" and default or nil })
end

--- Lets a missing value through as nil; otherwise applies `pipe`.
function pipes.optional(pipe)
  assert(is_pipe(pipe), "pipes.optional(pipe): pipe must be a pipe")
  local d = protocol.describe(pipe)
  if d.type == "custom" then d = {} end
  d.optional = true
  return new_pipe(function(value, ctx)
    if value == nil or value == "" then return true, nil end
    return call_pipe(pipe, value, ctx)
  end, d)
end

--- Trims surrounding whitespace from a string value.
pipes.trim = new_pipe(function(value)
  if type(value) == "string" then return true, (value:gsub("^%s+", ""):gsub("%s+$", "")) end
  return true, value
end)

--- Splits a "a,b,c" string (or passes an array through) and optionally
--- runs every item through `item_pipe`.
function pipes.array(item_pipe, separator)
  assert(item_pipe == nil or is_pipe(item_pipe), "pipes.array(item_pipe): item_pipe must be a pipe or nil")
  separator = separator or ","
  local item_pattern = "(.-)" .. separator:gsub("%p", "%%%0")
  return new_pipe(function(value, ctx)
    if value == nil then return true, {} end
    local items
    if type(value) == "table" then
      items = copy(value)
    else
      items = {}
      for item in (tostring(value) .. separator):gmatch(item_pattern) do
        if item ~= "" then items[#items + 1] = item end
      end
    end
    if item_pipe then
      local errors
      for i, item in ipairs(items) do
        local ok, r = call_pipe(item_pipe, item, ctx)
        if ok then
          items[i] = r
        else
          errors = errors or {}
          errors[i] = r
        end
      end
      if errors then return false, errors end
    end
    return true, items
  end, { type = "array" })
end

--- Runs several pipes left to right as one.
function pipes.chain(...)
  local list = { ... }
  for _, p in ipairs(list) do assert(is_pipe(p), "pipes.chain(...): every argument must be a pipe") end
  return new_pipe(function(value, ctx)
    for _, p in ipairs(list) do
      local ok, r = call_pipe(p, value, ctx)
      if not ok then return false, r end
      value = r
    end
    return true, value
  end)
end

return { builtin = pipes, protocol = protocol }
