-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Generic helpers shared by the scheme modules.

local util = {}

---@diagnostic disable-next-line: deprecated
util.unpack = table.unpack or unpack -- luacheck: ignore

function util.deep_equal(a, b, seen)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do
    if not util.deep_equal(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

function util.is_pure_array(t)
  if type(t) ~= "table" then return false end
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    count = count + 1
  end
  return count == #t
end

function util.table_count(t)
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  return c
end

function util.copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

--- Length in UTF-8 characters (counts every byte that isn't a
--- continuation byte), which degrades to bytes for invalid UTF-8.
function util.ulen(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

--- Emptiness by base kind: "" for strings, no items/entries for tables.
function util.is_empty(value, kind)
  if value == nil then return true end
  if kind == "string" then return value == "" end
  if kind == "array" then return #value == 0 end
  if kind == "table" or kind == "object" then return next(value) == nil end
  return false
end

--- Varargs or a single list (but not a single schema) -> list.
function util.value_list(...)
  local args = { ... }
  local first = args[1]
  if #args == 1 and type(first) == "table" and rawget(first, "__class") ~= "Schema" then return first end
  return args
end

local DECIMAL_PATTERNS = {
  "^[-+]?%d+$", "^[-+]?%d+%.%d*$", "^[-+]?%d*%.%d+$",
  "^[-+]?%d+[eE][-+]?%d+$", "^[-+]?%d+%.%d*[eE][-+]?%d+$", "^[-+]?%d*%.%d+[eE][-+]?%d+$",
}

--- Plain decimal notation only: no hex ("0x10"), no "inf"/"nan", no
--- surrounding whitespace (all of which tonumber() would accept).
function util.is_decimal_string(s)
  for _, p in ipairs(DECIMAL_PATTERNS) do
    if s:match(p) then return true end
  end
  return false
end

return util
