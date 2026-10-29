-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Working with validation error tables.

local config = require "nestlua.scheme.config"

local errors = {}

local function child_path(prefix, key)
  if key == config.self_key or key == "variants" then return prefix end
  if type(key) == "number" then return prefix .. "[" .. key .. "]" end
  if prefix == "" then return tostring(key) end
  return prefix .. "." .. tostring(key)
end

local function walk(errs, prefix, out)
  if type(errs) ~= "table" then return end
  -- Leading 1..n entries are this level's messages (or, for any_of
  -- attempts, nested error tables); every other key is a field/index.
  -- Indices are tracked explicitly since `#` is unreliable with holes.
  local own = {}
  for i, msg in ipairs(errs) do
    own[i] = true
    if type(msg) == "string" then out[#out + 1] = { path = prefix, message = msg } end
    if type(msg) == "table" then walk(msg, prefix, out) end
  end
  for k, v in pairs(errs) do
    if not own[k] and k ~= "variants" then walk(v, child_path(prefix, k), out) end
  end
end

--- Flattens a nested errors table into a list of { path=, message= }
--- (path like "contact.email" or "items[2]"), sorted by path.
function errors.flatten(errs, prefix)
  local out = {}
  walk(errs, prefix or "", out)
  table.sort(out, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    return a.message < b.message
  end)
  return out
end

return errors
