-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Small dependency-free JSON encoder/decoder used by the body parser, the
  HTTP adapters, the OpenAPI generator and scheme's :json() constraint.

    local json = require "nestlua.json"
    json.encode({ a = 1, b = { 1, 2 } })   --> '{"a":1,"b":[1,2]}'
    json.decode('{"a":null}')               --> { a = json.null }

  JSON `null` decodes to the `json.null` sentinel (so a present-but-null
  field can be told apart from a missing one) and `json.null` encodes back
  to `null`. Empty Lua tables encode as `{}` unless marked as an array with
  `json.array(t)`.
--]]

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack -- luacheck: ignore

local json = {}

---@class nestlua.json.null
json.null = setmetatable({}, {
  __tostring = function() return "null" end,
  __json_null = true,
})

local ARRAY_MT = { __json_array = true }

--- Marks `t` (or a new empty table) so it always encodes as a JSON array.
---@param t? table
---@return table
function json.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

--- True for the `json.null` sentinel.
function json.is_null(v)
  local mt = getmetatable(v)
  return type(v) == "table" and mt ~= nil and type(mt) == "table" and mt.__json_null == true
end

--============================================================--
-- Encoding
--============================================================--

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local mt = getmetatable(t)
  if type(mt) == "table" and mt.__json_array then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("json.encode: cannot encode NaN or infinity")
  end
  if math.floor(n) == n and n > -2 ^ 53 and n < 2 ^ 53 then
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

local encode_value

local function encode_table(t, seen, out)
  if seen[t] then error("json.encode: cannot encode a table with cycles") end
  seen[t] = true
  if is_array(t) then
    out[#out + 1] = "["
    for i = 1, #t do
      if i > 1 then out[#out + 1] = "," end
      encode_value(t[i], seen, out)
    end
    out[#out + 1] = "]"
  else
    local keys = {}
    for k in pairs(t) do
      if type(k) ~= "string" and type(k) ~= "number" then
        error("json.encode: object keys must be strings or numbers (got " .. type(k) .. ")")
      end
      keys[#keys + 1] = k
    end
    -- sorted so the output is deterministic (stable tests, cacheable bodies)
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
      if i > 1 then out[#out + 1] = "," end
      out[#out + 1] = encode_string(tostring(k))
      out[#out + 1] = ":"
      encode_value(t[k], seen, out)
    end
    out[#out + 1] = "}"
  end
  seen[t] = nil
end

encode_value = function(v, seen, out)
  local tv = type(v)
  if v == nil or json.is_null(v) then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    out[#out + 1] = encode_number(v)
  elseif tv == "string" then
    out[#out + 1] = encode_string(v)
  elseif tv == "table" then
    encode_table(v, seen, out)
  else
    error("json.encode: cannot encode a value of type " .. tv)
  end
end

--- Encodes a Lua value as a JSON string. Raises on cycles, NaN/inf,
--- functions/userdata and non-string/number keys.
---@param value any
---@return string
function json.encode(value)
  local out = {}
  encode_value(value, {}, out)
  return table.concat(out)
end

--============================================================--
-- Decoding
--============================================================--

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local UNESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function decoder(s, opts)
  local i, n = 1, #s
  local null = json.null
  if opts and opts.null ~= nil then null = opts.null end
  if opts and opts.null_as_nil then null = nil end
  local max_depth = (opts and opts.max_depth) or 512

  local function fail(msg)
    error({ json_error = msg .. " at position " .. i }, 0)
  end

  local function skip_ws()
    i = s:find("[^ \t\r\n]", i) or (n + 1)
  end

  local parse_value

  local function parse_string()
    i = i + 1 -- opening quote
    local parts = {}
    while true do
      local j = s:find('["\\%c]', i)
      if not j then fail("unterminated string") end
      parts[#parts + 1] = s:sub(i, j - 1)
      local c = s:sub(j, j)
      if c == '"' then
        i = j + 1
        return table.concat(parts)
      elseif c == "\\" then
        local esc = s:sub(j + 1, j + 1)
        if esc == "u" then
          local hex = s:sub(j + 2, j + 5)
          if not hex:match("^%x%x%x%x$") then fail("invalid \\u escape") end
          local cp = tonumber(hex, 16)
          i = j + 6
          if cp >= 0xD800 and cp <= 0xDBFF then
            local lo = s:match("^\\u(%x%x%x%x)", i)
            local lcp = lo and tonumber(lo, 16)
            if not lcp or lcp < 0xDC00 or lcp > 0xDFFF then fail("invalid surrogate pair") end
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lcp - 0xDC00)
            i = i + 6
          elseif cp >= 0xDC00 and cp <= 0xDFFF then
            fail("unpaired low surrogate")
          end
          parts[#parts + 1] = utf8_char(cp)
        elseif UNESCAPES[esc] then
          parts[#parts + 1] = UNESCAPES[esc]
          i = j + 2
        else
          fail("invalid escape")
        end
      else
        fail("control character in string")
      end
    end
  end

  local function parse_number()
    local int = s:match("^-?%d+", i)
    if not int or int:match("^-?0%d") then fail("invalid number") end
    local j = i + #int
    local frac = s:match("^%.%d+", j)
    if s:sub(j, j) == "." and not frac then fail("invalid number") end
    j = j + #(frac or "")
    local exp = s:match("^[eE][-+]?%d+", j)
    if s:match("^[eE]", j) and not exp then fail("invalid number") end
    j = j + #(exp or "")
    local num = s:sub(i, j - 1)
    i = j
    return tonumber(num)
  end

  local function parse_container(close, depth, item)
    if depth > max_depth then fail("nesting too deep") end
    i = i + 1
    local t = {}
    skip_ws()
    if s:sub(i, i) == close then
      i = i + 1
      return t
    end
    while true do
      item(t)
      skip_ws()
      local c = s:sub(i, i)
      i = i + 1
      if c == close then return t end
      if c ~= "," then fail("expected ',' or '" .. close .. "'") end
      skip_ws()
    end
  end

  parse_value = function(depth)
    skip_ws()
    local c = s:sub(i, i)
    if c == '"' then
      return parse_string()
    elseif c == "{" then
      return parse_container("}", depth, function(t)
        skip_ws()
        if s:sub(i, i) ~= '"' then fail("expected string key") end
        local k = parse_string()
        skip_ws()
        if s:sub(i, i) ~= ":" then fail("expected ':'") end
        i = i + 1
        t[k] = parse_value(depth + 1)
      end)
    elseif c == "[" then
      local arr = parse_container("]", depth, function(t)
        -- rawset with an explicit index so json.null-as-nil keeps positions
        t.n = (t.n or 0) + 1
        t[t.n] = parse_value(depth + 1)
      end)
      arr.n = nil
      return json.array(arr)
    elseif c == "-" or c:match("%d") then
      return parse_number()
    elseif s:sub(i, i + 3) == "true" then
      i = i + 4
      return true
    elseif s:sub(i, i + 4) == "false" then
      i = i + 5
      return false
    elseif s:sub(i, i + 3) == "null" then
      i = i + 4
      return null
    end
    fail("unexpected character")
  end

  return function()
    local v = parse_value(1)
    skip_ws()
    if i <= n then fail("trailing characters") end
    return v
  end
end

--- Decodes a JSON string. Returns the value, or `nil, message` on invalid
--- input (it never raises for malformed JSON).
---
--- opts.null        -- value to use for JSON null (default `json.null`)
--- opts.null_as_nil -- decode null as plain nil
--- opts.max_depth   -- maximum nesting depth (default 512)
---@param s string
---@param opts? { null?: any, null_as_nil?: boolean, max_depth?: integer }
---@return any value, string? err
function json.decode(s, opts)
  if type(s) ~= "string" then return nil, "json.decode: expected a string" end
  local ok, result = pcall(decoder(s, opts))
  if ok then return result end
  if type(result) == "table" and result.json_error then return nil, result.json_error end
  error(result, 0)
end

--- True if `s` is syntactically valid JSON.
function json.is_valid(s)
  if type(s) ~= "string" then return false end
  local ok = pcall(decoder(s, nil))
  return ok
end

return json
