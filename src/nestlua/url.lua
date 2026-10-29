-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- URL helpers: decoding, path normalization, query strings.

local url = {}

--- Percent-decodes a path segment. '+' is literal in paths; only
--- application/x-www-form-urlencoded data (query strings, form bodies)
--- uses it for spaces -- see form_decode().
---@param s string
---@return string
function url.percent_decode(s)
  return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

---@param s string
---@return string
function url.form_decode(s)
  return url.percent_decode((s:gsub("%+", " ")))
end

---@param path string
---@return string[]
function url.split_path(path)
  local segments = {}
  for seg in path:gmatch("[^/]+") do
    segments[#segments + 1] = seg
  end
  return segments
end

---@param path? string
---@return string
function url.normalize_path(path)
  if path == nil or path == "" then return "/" end
  path = path:gsub("//+", "/")
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  if #path > 1 and path:sub(-1) == "/" then path = path:sub(1, -2) end
  return path
end

--- Joins path pieces, skipping nil/empty ones.
---@return string
function url.join_paths(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p and p ~= "" then parts[#parts + 1] = p end
  end
  return url.normalize_path(table.concat(parts, "/"))
end

--- Parses an application/x-www-form-urlencoded string. Repeated keys are
--- collected into an array (`?tag=a&tag=b` -> { tag = { "a", "b" } }).
---@param qs? string
---@return table<string, string|string[]>
function url.parse_query(qs)
  local q = {}
  if not qs or qs == "" then return q end
  for pair in qs:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    k = url.form_decode(k)
    v = url.form_decode(v)
    if k ~= "" then
      local existing = q[k]
      if existing == nil then
        q[k] = v
      elseif type(existing) == "table" then
        existing[#existing + 1] = v
      else
        q[k] = { existing, v }
      end
    end
  end
  return q
end

--- Splits "/a/b?x=1#frag" into "/a/b" (normalized) and "x=1".
---@param raw string
---@return string path, string query
function url.split_url(raw)
  local path, query = raw:match("^([^%?#]*)%??([^#]*)")
  return url.normalize_path(path), query or ""
end

return url
