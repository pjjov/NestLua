-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Text-format predicates: character classes, encodings, case, versions,
-- passwords and CSS colors. Each takes a string (plus optional arguments)
-- and returns a boolean.

local function is_boolean_string(s)
  local l = s:lower()
  return l == "true" or l == "false"
end

local function is_alpha(s) return s:match("^%a+$") ~= nil end

local function is_alphanumeric(s) return s:match("^%w+$") ~= nil end

local function is_ascii(s)
  for i = 1, #s do
    if s:byte(i) > 127 then return false end
  end
  return true
end

local function is_base32(s)
  local body, pad = s:match("^([A-Z2-7]+)(=*)$")
  if not body then return false end
  return #pad == 0 or (#s % 8 == 0 and #pad <= 6)
end

local function is_base64(s)
  local body, pad = s:match("^([A-Za-z0-9+/]+)(=?=?)$")
  return body ~= nil and #s % 4 == 0 and #s > 0 and #pad <= 2
end

local function is_hexadecimal(s) return s:match("^%x+$") ~= nil end

local function is_octal(s) return s:match("^[0-7]+$") ~= nil end

local function is_jwt(s)
  local parts = {}
  for p in (s .. "."):gmatch("([^%.]*)%.") do parts[#parts + 1] = p end
  if #parts ~= 3 then return false end
  for i, p in ipairs(parts) do
    -- the signature may be empty for unsecured ("alg":"none") tokens
    if not (p:match("^[A-Za-z0-9_%-]+$") or (i == 3 and p == "")) then return false end
  end
  return true
end

local function is_lowercase(s) return s == s:lower() end

local function is_uppercase(s) return s == s:upper() end

local function is_sem_ver(s)
  local core, rest = s:match("^(%d+%.%d+%.%d+)(.-)$")
  if not core then return false end
  for n in core:gmatch("%d+") do
    if #n > 1 and n:sub(1, 1) == "0" then return false end
  end
  if rest == "" then return true end
  if rest:match("^%-[%w%.%-]+%+[%w%.%-]+$") then return true end
  if rest:match("^%-[%w%.%-]+$") then return true end
  if rest:match("^%+[%w%.%-]+$") then return true end
  return false
end

local function is_strong_password(s)
  if #s < 8 then return false end
  if not s:match("%u") then return false end
  if not s:match("%l") then return false end
  if not s:match("%d") then return false end
  if not s:match("[^%w]") then return false end
  return true
end

local function is_hex_color(s)
  local hex = s:match("^#(%x+)$")
  if not hex then return false end
  local n = #hex
  return n == 3 or n == 4 or n == 6 or n == 8
end

local function is_hsl(s)
  local h, sat, l = s:match("^hsla?%(%s*(%-?%d+)%s*,%s*(%d+)%%%s*,%s*(%d+)%%")
  if not h then return false end
  local sn, ln = tonumber(sat), tonumber(l)
  return sn ~= nil and ln ~= nil and sn >= 0 and sn <= 100 and ln >= 0 and ln <= 100
end

local function is_rgb(s)
  local r, g, b = s:match("^rgba?%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
  if not r then return false end
  for _, v in ipairs({ r, g, b }) do
    local n = tonumber(v)
    if not n or n < 0 or n > 255 then return false end
  end
  return true
end

return {
  boolean_string = is_boolean_string,
  alpha = is_alpha,
  alphanumeric = is_alphanumeric,
  ascii = is_ascii,
  base32 = is_base32,
  base64 = is_base64,
  hexadecimal = is_hexadecimal,
  octal = is_octal,
  jwt = is_jwt,
  lowercase = is_lowercase,
  uppercase = is_uppercase,
  sem_ver = is_sem_ver,
  strong_password = is_strong_password,
  hex_color = is_hex_color,
  hsl = is_hsl,
  rgb = is_rgb,
}
