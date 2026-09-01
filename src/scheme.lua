-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  This module implements a class-validator-inspired value/object validator.

  Usage:
    local scheme = require "nestlua.scheme"

    local ContactDtoValidator = scheme {
      phone = scheme.string:phone(),
      email = scheme.string:email(),
    }

    local RegisterUserDtoValidator = scheme {
      username = scheme.string:min(3):alpha(),
      password = scheme.string:strong_password(),
      contact  = ContactDtoValidator:optional(),
    }

    local ok, errors = RegisterUserDtoValidator(obj)
--]]

---@diagnostic disable: assign-type-mismatch
---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack -- luacheck: ignore

local scheme = {}

--============================================================--
-- Generic utilities
--============================================================--

local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function is_pure_array(t)
  if type(t) ~= "table" then return false end
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    count = count + 1
  end
  return count == #t
end

local function table_count(t)
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  return c
end

local function is_empty(value, ty)
  if value == nil then return true end
  if ty == "string" then return value == "" end
  if ty == "array" then return #value == 0 end
  if ty == "table" or ty == "object" then return next(value) == nil end
  return false
end

-- Normalizes a date-ish value (Lua table, unix timestamp number, or an ISO
-- 8601-ish string) into a comparable unix timestamp. Returns nil on failure.
local function to_timestamp(value)
  if type(value) == "number" then return value end
  if type(value) == "table" then
    if value.year and value.month and value.day then
      local ok, t = pcall(os.time, {
        year = value.year,
        month = value.month,
        day = value.day,
        hour = value.hour or 0,
        min = value.min or 0,
        sec = value.sec or 0,
      })
      if ok then return t end
    end
    return nil
  end
  if type(value) == "string" then
    local y, mo, d, h, mi, se = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d?%d?)$")
    if y then
      if se == "" then se = "0" end
      local ok, t = pcall(os.time, {
        year = tonumber(y),
        month = tonumber(mo),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(mi),
        sec = tonumber(se),
      })
      if ok then return t end
      return nil
    end
    y, mo, d = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if y then
      local ok, t = pcall(os.time, {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 0, min = 0, sec = 0,
      })
      if ok then return t end
    end
    return nil
  end
  return nil
end

--============================================================--
-- String validators (pure functions: string -> ok[, extra args])
--============================================================--

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
  return s:match("^[A-Z2-7]+=*$") ~= nil and #(s:gsub("=", "")) > 0
end

local function is_base64(s)
  return s:match("^[A-Za-z0-9+/]+=*$") ~= nil and #s % 4 == 0 and #s > 0
end

local function is_hexadecimal(s) return s:match("^%x+$") ~= nil end
local function is_octal(s) return s:match("^[0-7]+$") ~= nil end

local function is_jwt(s)
  local parts = {}
  for p in s:gmatch("[^%.]+") do parts[#parts + 1] = p end
  if #parts ~= 3 then return false end
  for _, p in ipairs(parts) do
    if not p:match("^[A-Za-z0-9_%-]+$") then return false end
  end
  return true
end

local function is_lowercase(s) return s == s:lower() end
local function is_uppercase(s) return s == s:upper() end

local function is_phone(s)
  local cleaned = s:gsub("[%s%-%.%(%)]", "")
  local digits = cleaned:match("^%+?(%d+)$")
  if not digits then return false end
  return #digits >= 7 and #digits <= 15
end

local function is_url(s)
  local scheme_part, rest = s:match("^(%a[%w+.-]*)://(.+)$")
  if not scheme_part or rest == "" then return false end
  local host = rest:match("^([^/%?#]+)")
  if not host or host == "" then return false end
  host = host:match("^[^@]*@(.+)$") or host
  local hostname = host:match("^([^:]+)")
  return hostname ~= nil and hostname ~= ""
end

local function is_sem_ver(s)
  local core, rest = s:match("^(%d+%.%d+%.%d+)(.-)$")
  if not core then return false end
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

local function is_mac_address(s)
  local sep = s:find(":", 1, true) and ":" or (s:find("%-") and "-" or nil)
  if not sep then return false end
  local parts = {}
  for p in s:gmatch("[^" .. sep .. "]+") do parts[#parts + 1] = p end
  if #parts ~= 6 then return false end
  for _, p in ipairs(parts) do
    if not p:match("^%x%x$") then return false end
  end
  return true
end

local function is_ipv4(s)
  local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, part in ipairs({ a, b, c, d }) do
    if #part > 3 then return false end
    if #part > 1 and part:sub(1, 1) == "0" then return false end
    local n = tonumber(part)
    if n == nil or n < 0 or n > 255 then return false end
  end
  return true
end

local function is_ipv6(s)
  if s:find("::", 1, true) then
    local before, after = s:match("^(.-)::(.*)$")
    if before == nil then return false end
    local groups = 0
    if before ~= "" then
      for g in before:gmatch("[^:]+") do
        if not g:match("^%x%x?%x?%x?$") then return false end
        groups = groups + 1
      end
    end
    if after ~= "" then
      for g in after:gmatch("[^:]+") do
        if not g:match("^%x%x?%x?%x?$") then return false end
        groups = groups + 1
      end
    end
    return groups <= 7
  end
  local groups = {}
  for g in s:gmatch("[^:]+") do groups[#groups + 1] = g end
  if #groups ~= 8 then return false end
  for _, g in ipairs(groups) do
    if not g:match("^%x%x?%x?%x?$") then return false end
  end
  return true
end

local function is_ip_address(s, version)
  if version == "v4" then return is_ipv4(s) end
  if version == "v6" then return is_ipv6(s) end
  if version ~= nil then error("ip_address: version must be 'v4', 'v6' or nil") end
  return is_ipv4(s) or is_ipv6(s)
end

local function is_port_number(s)
  local n = tonumber(s)
  if n == nil or n ~= math.floor(n) then return false end
  return n >= 0 and n <= 65535
end

local function is_isbn(s)
  local cleaned = s:gsub("[%s%-]", "")
  if #cleaned == 10 then
    local sum = 0
    for i = 1, 9 do
      local d = tonumber(cleaned:sub(i, i))
      if not d then return false end
      sum = sum + d * (11 - i)
    end
    local last = cleaned:sub(10, 10)
    local checkval
    if last == "X" or last == "x" then
      checkval = 10
    else
      checkval = tonumber(last)
    end
    if not checkval then return false end
    sum = sum + checkval
    return sum % 11 == 0
  elseif #cleaned == 13 then
    local sum = 0
    for i = 1, 12 do
      local d = tonumber(cleaned:sub(i, i))
      if not d then return false end
      sum = sum + d * ((i % 2 == 1) and 1 or 3)
    end
    local last = tonumber(cleaned:sub(13, 13))
    if not last then return false end
    local check = (10 - (sum % 10)) % 10
    return check == last
  end
  return false
end

local function is_credit_card(s)
  local cleaned = s:gsub("[%s%-]", "")
  if not cleaned:match("^%d+$") then return false end
  if #cleaned < 12 or #cleaned > 19 then return false end
  local sum, alt = 0, false
  for i = #cleaned, 1, -1 do
    local d = tonumber(cleaned:sub(i, i))
    if alt then
      d = d * 2
      if d > 9 then d = d - 9 end
    end
    sum = sum + d
    alt = not alt
  end
  return sum % 10 == 0
end

-- Generic heuristics only: passport/postal formats vary hugely by issuing
-- country and there's no universal standard, so these just sanity-check a
-- plausible shape rather than validating against a real country registry.
local function is_passport_number(s)
  return s:match("^[%u%d]+$") ~= nil and #s >= 6 and #s <= 9
end

local function is_postal_code(s)
  return s:match("^[%w][%w%s%-]*[%w]$") ~= nil and #s >= 3 and #s <= 10
end

-- Format-only checks: real validation needs Keccak-256 (Ethereum EIP-55
-- checksum) / double-SHA-256 (Bitcoin base58check), neither of which is
-- available in the Lua standard library.
local function is_ethereum_address(s)
  return s:match("^0x%x+$") ~= nil and #s == 42
end

local function is_btc_address(s)
  if s:match("^bc1[a-z0-9]+$") and #s >= 14 and #s <= 74 then return true end
  local first = s:sub(1, 1)
  if (first == "1" or first == "3") and #s >= 25 and #s <= 34 then
    return s:match("^[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]+$") ~= nil
  end
  return false
end

local function is_email(s)
  local at_count = 0
  for _ in s:gmatch("@") do at_count = at_count + 1 end
  if at_count ~= 1 then return false end
  local user, domain = s:match("^([^@]+)@([^@]+)$")
  if not user or user == "" then return false end
  if not user:match("^[%w%.%%%+%-_]+$") then return false end
  if not domain or not domain:match("^[%w%-%.]+$") then return false end
  if not domain:find("%.") then return false end
  if domain:match("^%.") or domain:match("%.$") or domain:find("%.%.") then return false end
  local tld = domain:match("%.([%a]+)$")
  return tld ~= nil and #tld >= 2
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

-- Minimal recursive-descent JSON *syntax* checker (no external library).
local function is_valid_json(s)
  local i, n = 1, #s
  local function skip_ws()
    while i <= n do
      local c = s:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
    end
  end
  local parse_value

  local function parse_string()
    if s:sub(i, i) ~= '"' then return false end
    i = i + 1
    while i <= n do
      local c = s:sub(i, i)
      if c == '"' then
        i = i + 1; return true
      end
      if c == "" then return false end
      if c == "\\" then
        i = i + 1
        local esc = s:sub(i, i)
        if esc == "" then return false end
        if esc == "u" then
          local hex = s:sub(i + 1, i + 4)
          if not hex:match("^%x%x%x%x$") then return false end
          i = i + 5
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    end
    return false
  end

  local function parse_number()
    local start = i
    if s:sub(i, i) == "-" then i = i + 1 end
    if s:sub(i, i) == "0" then
      i = i + 1
    elseif s:sub(i, i):match("%d") then
      while s:sub(i, i):match("%d") do i = i + 1 end
    else
      return false
    end
    if s:sub(i, i) == "." then
      i = i + 1
      if not s:sub(i, i):match("%d") then return false end
      while s:sub(i, i):match("%d") do i = i + 1 end
    end
    if s:sub(i, i) == "e" or s:sub(i, i) == "E" then
      i = i + 1
      if s:sub(i, i) == "+" or s:sub(i, i) == "-" then i = i + 1 end
      if not s:sub(i, i):match("%d") then return false end
      while s:sub(i, i):match("%d") do i = i + 1 end
    end
    return i > start
  end

  local function parse_literal(lit)
    if s:sub(i, i + #lit - 1) == lit then
      i = i + #lit; return true
    end
    return false
  end

  local function parse_array()
    i = i + 1
    skip_ws()
    if s:sub(i, i) == "]" then
      i = i + 1; return true
    end
    while true do
      skip_ws()
      if not parse_value() then return false end
      skip_ws()
      local c = s:sub(i, i)
      if c == "," then
        i = i + 1
      elseif c == "]" then
        i = i + 1; return true
      else
        return false
      end
    end
  end

  local function parse_object()
    i = i + 1
    skip_ws()
    if s:sub(i, i) == "}" then
      i = i + 1; return true
    end
    while true do
      skip_ws()
      if not parse_string() then return false end
      skip_ws()
      if s:sub(i, i) ~= ":" then return false end
      i = i + 1
      skip_ws()
      if not parse_value() then return false end
      skip_ws()
      local c = s:sub(i, i)
      if c == "," then
        i = i + 1
      elseif c == "}" then
        i = i + 1; return true
      else
        return false
      end
    end
  end

  parse_value = function()
    skip_ws()
    local c = s:sub(i, i)
    if c == '"' then
      return parse_string()
    elseif c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif c == "t" then
      return parse_literal("true")
    elseif c == "f" then
      return parse_literal("false")
    elseif c == "n" then
      return parse_literal("null")
    elseif c == "-" or c:match("%d") then
      return parse_number()
    else
      return false
    end
  end

  skip_ws()
  if not parse_value() then return false end
  skip_ws()
  return i > n
end

--============================================================--
-- Schema "class" machinery
--============================================================--

local TYPE_METHODS = {} -- type name -> methods table (constraint methods for that type)
local TYPE_CHECKS = {}  -- type name -> function(value) -> ok[, message]  (scalar types only)

local function is_schema(x)
  return type(x) == "table" and x.__class == "Schema"
end
scheme.is_schema = is_schema

local function new_schema(type_name)
  local methods = TYPE_METHODS[type_name]
  assert(methods, "unknown scheme type: " .. tostring(type_name))
  local self = setmetatable({}, {
    __index = methods,
    __call = function(instance, value, ctx) return instance:validate(value, ctx) end,
  })
  self.__class = "Schema"
  self.__type = type_name
  self.rules = {}
  self._optional = false
  self.item_schemas = nil
  self.shape = nil
  return self
end

-- BASE holds constraints shared by every scheme type (optional, empty,
-- not_empty, is_in, not_in, equals, not_equals) plus the default scalar
-- `validate` implementation. Every other type-methods table falls back to
-- BASE via its own metatable, so e.g. `scheme.number:optional()` works
-- without number needing its own copy of `optional`.
local BASE = {}

function BASE:optional()
  assert(is_schema(self), "optional: self must be a schema")
  self._optional = true
  return self
end

function BASE:empty()
  assert(is_schema(self), "empty: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "empty",
    fn = function(value)
      if is_empty(value, self.__type) then return true end
      return false, "must be empty"
    end
  }
  return self
end

function BASE:not_empty()
  assert(is_schema(self), "not_empty: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "not_empty",
    fn = function(value)
      if not is_empty(value, self.__type) then return true end
      return false, "must not be empty"
    end
  }
  return self
end

function BASE:is_in(...)
  assert(is_schema(self), "is_in: self must be a schema")
  local args = { ... }
  local list = args
  if #args == 1 and type(args[1]) == "table" then list = args[1] end
  assert(#list > 0, "is_in: requires at least one allowed value")
  self.rules[#self.rules + 1] = {
    name = "is_in",
    fn = function(value)
      for _, v in ipairs(list) do
        if deep_equal(v, value) then return true end
      end
      return false, "must be one of the allowed values"
    end
  }
  return self
end

function BASE:not_in(...)
  assert(is_schema(self), "not_in: self must be a schema")
  local args = { ... }
  local list = args
  if #args == 1 and type(args[1]) == "table" then list = args[1] end
  assert(#list > 0, "not_in: requires at least one disallowed value")
  self.rules[#self.rules + 1] = {
    name = "not_in",
    fn = function(value)
      for _, v in ipairs(list) do
        if deep_equal(v, value) then return false, "must not be one of the disallowed values" end
      end
      return true
    end
  }
  return self
end

function BASE:equals(other)
  assert(is_schema(self), "equals: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "equals",
    fn = function(value)
      if deep_equal(value, other) then return true end
      return false, "must equal the expected value"
    end
  }
  return self
end

function BASE:not_equals(other)
  assert(is_schema(self), "not_equals: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "not_equals",
    fn = function(value)
      if not deep_equal(value, other) then return true end
      return false, "must not equal the disallowed value"
    end
  }
  return self
end

function BASE:describe()
  assert(is_schema(self), "describe: self must be a schema")
  local rule_names = {}
  for _, r in ipairs(self.rules) do rule_names[#rule_names + 1] = r.name end
  local d = { type = self.__type, optional = self._optional, rules = rule_names }
  if self.shape then
    d.shape = {}
    for k, v in pairs(self.shape) do d.shape[k] = v:describe() end
  end
  if self.item_schemas then
    d.item_schemas = {}
    for idx, s in ipairs(self.item_schemas) do d.item_schemas[idx] = s:describe() end
  end
  return d
end

local function run_rules(self, value, ctx, errors)
  for _, rule in ipairs(self.rules) do
    local ok, a, b = pcall(rule.fn, value, ctx)
    if not ok then
      errors[#errors + 1] = tostring(a)
    elseif a == false then
      errors[#errors + 1] = b or (rule.name .. " failed")
    end
  end
end

-- Default validate() for scalar types (string/number/int/boolean/date and
-- any custom type that doesn't override it).
function BASE:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  ctx = ctx or {}
  if value == nil then
    if self._optional then return true end
    return false, { "is required" }
  end
  local check = TYPE_CHECKS[self.__type]
  if check then
    local tok, tmsg = check(value)
    if not tok then
      return false, { tmsg or ("must be a valid " .. self.__type) }
    end
  end
  local errors = {}
  run_rules(self, value, ctx, errors)
  if #errors > 0 then return false, errors end
  return true
end

local function new_type_methods(base)
  return setmetatable({}, { __index = base or BASE })
end

--============================================================--
-- boolean
--============================================================--

TYPE_METHODS.boolean = new_type_methods()
TYPE_CHECKS.boolean = function(v)
  if type(v) == "boolean" then return true end
  return false, "must be a boolean"
end

--============================================================--
-- number / int
--============================================================--

local function register_numeric(methods)
  methods.divisible_by = function(self, num)
    assert(is_schema(self), "divisible_by: self must be a schema")
    assert(type(num) == "number" and num ~= 0, "divisible_by: num must be a non-zero number")
    self.rules[#self.rules + 1] = {
      name = "divisible_by",
      fn = function(value)
        if value % num == 0 then return true end
        return false, "must be divisible by " .. tostring(num)
      end
    }
    return self
  end
  methods.positive = function(self)
    assert(is_schema(self), "positive: self must be a schema")
    self.rules[#self.rules + 1] = {
      name = "positive",
      fn = function(value)
        if value > 0 then return true end
        return false, "must be positive"
      end
    }
    return self
  end
  methods.negative = function(self)
    assert(is_schema(self), "negative: self must be a schema")
    self.rules[#self.rules + 1] = {
      name = "negative",
      fn = function(value)
        if value < 0 then return true end
        return false, "must be negative"
      end
    }
    return self
  end
  methods.min = function(self, num)
    assert(is_schema(self), "min: self must be a schema")
    assert(type(num) == "number", "min: num must be a number")
    self.rules[#self.rules + 1] = {
      name = "min",
      fn = function(value)
        if value >= num then return true end
        return false, "must be >= " .. tostring(num)
      end
    }
    return self
  end
  methods.max = function(self, num)
    assert(is_schema(self), "max: self must be a schema")
    assert(type(num) == "number", "max: num must be a number")
    self.rules[#self.rules + 1] = {
      name = "max",
      fn = function(value)
        if value <= num then return true end
        return false, "must be <= " .. tostring(num)
      end
    }
    return self
  end
  methods.range = function(self, lo, hi)
    assert(is_schema(self), "range: self must be a schema")
    assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
    self.rules[#self.rules + 1] = {
      name = "range",
      fn = function(value)
        if value >= lo and value <= hi then return true end
        return false, "must be between " .. tostring(lo) .. " and " .. tostring(hi)
      end
    }
    return self
  end
end

TYPE_METHODS.number = new_type_methods()
TYPE_CHECKS.number = function(v)
  if type(v) == "number" then return true end
  return false, "must be a number"
end
register_numeric(TYPE_METHODS.number)

TYPE_METHODS.int = new_type_methods()
TYPE_CHECKS.int = function(v)
  if type(v) == "number" and v == math.floor(v) and v ~= math.huge and v ~= -math.huge then return true end
  return false, "must be an integer"
end
register_numeric(TYPE_METHODS.int)

--============================================================--
-- date
--============================================================--

TYPE_METHODS.date = new_type_methods()
TYPE_CHECKS.date = function(v)
  if to_timestamp(v) ~= nil then return true end
  return false, "must be a valid date"
end

TYPE_METHODS.date.min = function(self, d)
  assert(is_schema(self), "min: self must be a schema")
  local bound = to_timestamp(d)
  assert(bound, "min: invalid date bound")
  self.rules[#self.rules + 1] = {
    name = "min",
    fn = function(value)
      local m = to_timestamp(value)
      if m and m >= bound then return true end
      return false, "date must not be earlier than the minimum"
    end
  }
  return self
end

TYPE_METHODS.date.max = function(self, d)
  assert(is_schema(self), "max: self must be a schema")
  local bound = to_timestamp(d)
  assert(bound, "max: invalid date bound")
  self.rules[#self.rules + 1] = {
    name = "max",
    fn = function(value)
      local m = to_timestamp(value)
      if m and m <= bound then return true end
      return false, "date must not be later than the maximum"
    end
  }
  return self
end

TYPE_METHODS.date.range = function(self, lo, hi)
  assert(is_schema(self), "range: self must be a schema")
  local blo, bhi = to_timestamp(lo), to_timestamp(hi)
  assert(blo and bhi, "range: invalid date bounds")
  self.rules[#self.rules + 1] = {
    name = "range",
    fn = function(value)
      local m = to_timestamp(value)
      if m and m >= blo and m <= bhi then return true end
      return false, "date must be within range"
    end
  }
  return self
end

--============================================================--
-- string
--============================================================--

TYPE_METHODS.string = new_type_methods()
TYPE_CHECKS.string = function(v)
  if type(v) == "string" then return true end
  return false, "must be a string"
end

local STR = TYPE_METHODS.string

local function def_string_check(name, check_fn, err_msg)
  STR[name] = function(self, ...)
    assert(is_schema(self), name .. ": self must be a schema")
    local extra = { ... }
    self.rules[#self.rules + 1] = {
      name = name,
      fn = function(value)
        local ok, msg = check_fn(value, unpack(extra))
        if ok then return true end
        return false, msg or err_msg
      end
    }
    return self
  end
end

def_string_check("boolean_string", is_boolean_string, "must be 'true' or 'false'")
def_string_check("date_string", function(v) return to_timestamp(v) ~= nil end, "must be a valid date string")
def_string_check("number_string", function(v) return tonumber(v) ~= nil end, "must be a numeric string")
def_string_check("contains", function(v, seed)
  assert(type(seed) == "string", "contains: seed must be a string")
  return v:find(seed, 1, true) ~= nil
end, "does not contain the required substring")
def_string_check("not_contains", function(v, seed)
  assert(type(seed) == "string", "not_contains: seed must be a string")
  return v:find(seed, 1, true) == nil
end, "must not contain the given substring")
def_string_check("alpha", is_alpha, "must contain only letters")
def_string_check("alphanumeric", is_alphanumeric, "must contain only letters and numbers")
def_string_check("ascii", is_ascii, "must contain only ASCII characters")
def_string_check("base32", is_base32, "must be a valid base32 string")
def_string_check("base64", is_base64, "must be a valid base64 string")
def_string_check("hexadecimal", is_hexadecimal, "must be a valid hexadecimal string")
def_string_check("octal", is_octal, "must be a valid octal string")
def_string_check("json", is_valid_json, "must be valid JSON")
def_string_check("jwt", is_jwt, "must be a well-formed JWT")
def_string_check("lowercase", is_lowercase, "must be lowercase")
def_string_check("uppercase", is_uppercase, "must be uppercase")
def_string_check("phone", is_phone, "must be a valid phone number")
def_string_check("url", is_url, "must be a valid URL")
def_string_check("sem_ver", is_sem_ver, "must be a valid semantic version")
def_string_check("strong_password", is_strong_password,
  "must be at least 8 characters and include an uppercase letter, a lowercase letter, a digit and a symbol")
STR.password = STR.strong_password -- alias; the example in the spec calls this `:password()`
def_string_check("mac_address", is_mac_address, "must be a valid MAC address")
def_string_check("ip_address", is_ip_address, "must be a valid IP address")
def_string_check("port_number", is_port_number, "must be a valid port number (0-65535)")
def_string_check("isbn", is_isbn, "must be a valid ISBN-10 or ISBN-13")
def_string_check("credit_card", is_credit_card, "must be a valid credit card number")
def_string_check("passport_number", is_passport_number, "must look like a valid passport number")
def_string_check("postal_code", is_postal_code, "must look like a valid postal code")
def_string_check("ethereum_address", is_ethereum_address, "must be a valid Ethereum address")
def_string_check("btc_address", is_btc_address, "must be a valid Bitcoin address")
def_string_check("email", is_email, "must be a valid email address")
def_string_check("hex_color", is_hex_color, "must be a valid hex color")
def_string_check("hsl", is_hsl, "must be a valid hsl()/hsla() color")
def_string_check("rgb", is_rgb, "must be a valid rgb()/rgba() color")

STR.min = function(self, n)
  assert(is_schema(self), "min: self must be a schema")
  assert(type(n) == "number", "min: n must be a number")
  self.rules[#self.rules + 1] = {
    name = "min",
    fn = function(value)
      if #value >= n then return true end
      return false, "must be at least " .. tostring(n) .. " characters long"
    end
  }
  return self
end
STR.max = function(self, n)
  assert(is_schema(self), "max: self must be a schema")
  assert(type(n) == "number", "max: n must be a number")
  self.rules[#self.rules + 1] = {
    name = "max",
    fn = function(value)
      if #value <= n then return true end
      return false, "must be at most " .. tostring(n) .. " characters long"
    end
  }
  return self
end
STR.range = function(self, lo, hi)
  assert(is_schema(self), "range: self must be a schema")
  assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
  self.rules[#self.rules + 1] = {
    name = "range",
    fn = function(value)
      if #value >= lo and #value <= hi then return true end
      return false, "must be between " .. tostring(lo) .. " and " .. tostring(hi) .. " characters long"
    end
  }
  return self
end

--============================================================--
-- array / table (of, min/max/range, contains/not_contains)
--============================================================--

local function register_of(methods)
  methods.of = function(self, ...)
    assert(is_schema(self), "of: self must be a schema")
    local schemas = { ... }
    assert(#schemas > 0, "of: requires at least one item schema")
    for _, sch in ipairs(schemas) do
      assert(is_schema(sch), "of: every argument must be a schema")
    end
    self.item_schemas = schemas
    return self
  end
end

local function validate_items(item_schemas, iterate, ctx)
  local item_errors, has_item_errors = {}, false
  if not item_schemas then return item_errors, has_item_errors end
  for key, item in iterate() do
    local matched, attempts = false, {}
    for _, ischema in ipairs(item_schemas) do
      local iok, ierr = ischema:validate(item, ctx)
      if iok then
        matched = true
        break
      end
      attempts[#attempts + 1] = ierr
    end
    if not matched then
      has_item_errors = true
      item_errors[key] = (#item_schemas == 1) and attempts[1] or attempts
    end
  end
  return item_errors, has_item_errors
end

TYPE_METHODS.array = new_type_methods()
local ARR = TYPE_METHODS.array
register_of(ARR)

ARR.min = function(self, n)
  assert(is_schema(self), "min: self must be a schema")
  assert(type(n) == "number", "min: n must be a number")
  self.rules[#self.rules + 1] = {
    name = "min",
    fn = function(value)
      if #value >= n then return true end
      return false, "must contain at least " .. tostring(n) .. " item(s)"
    end
  }
  return self
end
ARR.max = function(self, n)
  assert(is_schema(self), "max: self must be a schema")
  assert(type(n) == "number", "max: n must be a number")
  self.rules[#self.rules + 1] = {
    name = "max",
    fn = function(value)
      if #value <= n then return true end
      return false, "must contain at most " .. tostring(n) .. " item(s)"
    end
  }
  return self
end
ARR.range = function(self, lo, hi)
  assert(is_schema(self), "range: self must be a schema")
  assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
  self.rules[#self.rules + 1] = {
    name = "range",
    fn = function(value)
      if #value >= lo and #value <= hi then return true end
      return false, "must contain between " .. tostring(lo) .. " and " .. tostring(hi) .. " item(s)"
    end
  }
  return self
end
ARR.contains = function(self, v)
  assert(is_schema(self), "contains: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "contains",
    fn = function(value)
      for _, item in ipairs(value) do
        if deep_equal(item, v) then return true end
      end
      return false, "must contain the required value"
    end
  }
  return self
end
ARR.not_contains = function(self, v)
  assert(is_schema(self), "not_contains: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "not_contains",
    fn = function(value)
      for _, item in ipairs(value) do
        if deep_equal(item, v) then return false, "must not contain the disallowed value" end
      end
      return true
    end
  }
  return self
end

function ARR:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  ctx = ctx or {}
  if value == nil then
    if self._optional then return true end
    return false, { "is required" }
  end
  if not is_pure_array(value) then
    return false, { "must be an array" }
  end
  local errors = {}
  run_rules(self, value, ctx, errors)
  local item_errors, has_item_errors = validate_items(self.item_schemas, function() return ipairs(value) end, ctx)
  if #errors > 0 or has_item_errors then
    if #errors > 0 then item_errors._self = errors end
    return false, item_errors
  end
  return true
end

TYPE_METHODS.table = new_type_methods()
local TBL = TYPE_METHODS.table
register_of(TBL)

TBL.min = function(self, n)
  assert(is_schema(self), "min: self must be a schema")
  assert(type(n) == "number", "min: n must be a number")
  self.rules[#self.rules + 1] = {
    name = "min",
    fn = function(value)
      if table_count(value) >= n then return true end
      return false, "must contain at least " .. tostring(n) .. " entrie(s)"
    end
  }
  return self
end
TBL.max = function(self, n)
  assert(is_schema(self), "max: self must be a schema")
  assert(type(n) == "number", "max: n must be a number")
  self.rules[#self.rules + 1] = {
    name = "max",
    fn = function(value)
      if table_count(value) <= n then return true end
      return false, "must contain at most " .. tostring(n) .. " entrie(s)"
    end
  }
  return self
end
TBL.range = function(self, lo, hi)
  assert(is_schema(self), "range: self must be a schema")
  assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
  self.rules[#self.rules + 1] = {
    name = "range",
    fn = function(value)
      local c = table_count(value)
      if c >= lo and c <= hi then return true end
      return false, "must contain between " .. tostring(lo) .. " and " .. tostring(hi) .. " entrie(s)"
    end
  }
  return self
end
TBL.contains = function(self, v)
  assert(is_schema(self), "contains: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "contains",
    fn = function(value)
      for _, item in pairs(value) do
        if deep_equal(item, v) then return true end
      end
      return false, "must contain the required value"
    end
  }
  return self
end
TBL.not_contains = function(self, v)
  assert(is_schema(self), "not_contains: self must be a schema")
  self.rules[#self.rules + 1] = {
    name = "not_contains",
    fn = function(value)
      for _, item in pairs(value) do
        if deep_equal(item, v) then return false, "must not contain the disallowed value" end
      end
      return true
    end
  }
  return self
end

function TBL:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  ctx = ctx or {}
  if value == nil then
    if self._optional then return true end
    return false, { "is required" }
  end
  if type(value) ~= "table" then
    return false, { "must be a table" }
  end
  local errors = {}
  run_rules(self, value, ctx, errors)
  local item_errors, has_item_errors = validate_items(self.item_schemas, function() return pairs(value) end, ctx)
  if #errors > 0 or has_item_errors then
    if #errors > 0 then item_errors._self = errors end
    return false, item_errors
  end
  return true
end

--============================================================--
-- object (created via scheme{ field = schema, ... })
--============================================================--

TYPE_METHODS.object = new_type_methods()
local OBJ = TYPE_METHODS.object

function OBJ:validate(value, ctx)
  assert(is_schema(self), "validate: self must be a schema")
  ctx = ctx or {}
  if value == nil then
    if self._optional then return true end
    return false, { "is required" }
  end
  if type(value) ~= "table" then
    return false, { "must be an object" }
  end
  local base_errors = {}
  run_rules(self, value, ctx, base_errors)
  local field_errors, has_field_errors = {}, false
  if self.shape then
    for field, field_schema in pairs(self.shape) do
      local fok, ferr = field_schema:validate(value[field], ctx)
      if not fok then
        field_errors[field] = ferr
        has_field_errors = true
      end
    end
  end
  if #base_errors > 0 or has_field_errors then
    if #base_errors > 0 then field_errors._self = base_errors end
    return false, field_errors
  end
  return true
end

--============================================================--
-- Extensibility: scheme:type(name, opts) / scheme:constraint(...)
--============================================================--

function scheme:type(name, opts)
  assert(self == scheme, "call this as scheme:type(name, opts)")
  assert(type(name) == "string" and #name > 0, "type: name must be a non-empty string")
  assert(TYPE_METHODS[name] == nil, "type: '" .. name .. "' already exists")
  opts = opts or {}
  assert(opts.extends == nil or type(opts.extends) == "string", "type: opts.extends must be a string")
  assert(opts.check == nil or type(opts.check) == "function",
    "type: opts.check must be a function(value) -> ok[, message]")

  local base_methods, base_check = BASE, nil
  if opts.extends then
    assert(TYPE_METHODS[opts.extends], "type: unknown base type '" .. opts.extends .. "'")
    base_methods = TYPE_METHODS[opts.extends]
    base_check = TYPE_CHECKS[opts.extends]
  end
  assert(opts.check or base_check, "type: opts.check is required unless extending a type that already has one")

  TYPE_METHODS[name] = new_type_methods(base_methods)
  TYPE_CHECKS[name] = opts.check or base_check
  return scheme
end

function scheme:constraint(type_name, constraint_name, fn, default_message)
  assert(self == scheme, "call this as scheme:constraint(type_name, constraint_name, fn)")
  assert(type(constraint_name) == "string" and #constraint_name > 0,
    "constraint: constraint_name must be a non-empty string")
  assert(type(fn) == "function", "constraint: fn must be a function(value, ...) -> ok[, message]")

  local target
  if type_name == nil or type_name == "any" then
    target = BASE
  else
    target = TYPE_METHODS[type_name]
    assert(target, "constraint: unknown type '" .. tostring(type_name) .. "'")
  end

  target[constraint_name] = function(self, ...)
    assert(is_schema(self), constraint_name .. ": self must be a schema")
    local args = { ... }
    self.rules[#self.rules + 1] = {
      name = constraint_name,
      fn = function(value)
        local ok, msg = fn(value, unpack(args))
        if ok then return true end
        return false, msg or default_message or (constraint_name .. " failed")
      end
    }
    return self
  end
  return scheme
end

--============================================================--
-- Module table: scheme.string / scheme.number / ... and scheme{...}
--============================================================--

setmetatable(scheme, {
  __index = function(_, key)
    if TYPE_METHODS[key] then
      return new_schema(key)
    end
    return nil
  end,
  __call = function(_, shape)
    assert(type(shape) == "table", "scheme{...}: expects a table describing the object's fields")
    for k, v in pairs(shape) do
      assert(is_schema(v), "scheme{...}: field '" .. tostring(k) .. "' must be a schema")
    end
    local obj = new_schema("object")
    obj.shape = shape
    return obj
  end,
})

return scheme
