-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- The string type: length rules (in UTF-8 characters), transforms and
-- format constraints backed by nestlua.scheme.validators.*.

local json = require "nestlua.json"
local schema = require "nestlua.scheme.schema"
local util = require "nestlua.scheme.util"
local dates = require "nestlua.scheme.dates"
local text = require "nestlua.scheme.validators.text"
local network = require "nestlua.scheme.validators.network"
local identifiers = require "nestlua.scheme.validators.identifiers"

local unpack, ulen, add_rule = util.unpack, util.ulen, schema.add_rule

local STR = schema.define("string", {
  check = function(v)
    if type(v) == "string" then return true end
    return false, "must be a string"
  end,
})

-- Defines STR[name](self, ...) adding a rule that calls check(value, ...).
-- `validate_args` (optional) checks the call-site arguments eagerly.
local function constraint(name, check, message, validate_args)
  STR[name] = function(self, ...)
    local args = { ... }
    if validate_args then validate_args(unpack(args)) end
    return add_rule(self, name, args, function(value) return check(value, unpack(args)) end, message)
  end
end

local function string_arg(what)
  return function(s) assert(type(s) == "string", what .. " must be a string") end
end

--============================================================--
-- Length and transforms
--============================================================--

function STR:min(n)
  assert(type(n) == "number", "min: n must be a number")
  return add_rule(self, "min", { n }, function(value) return ulen(value) >= n end,
    function(a) return "must be at least " .. tostring(a[1]) .. " characters long" end)
end

function STR:max(n)
  assert(type(n) == "number", "max: n must be a number")
  return add_rule(self, "max", { n }, function(value) return ulen(value) <= n end,
    function(a) return "must be at most " .. tostring(a[1]) .. " characters long" end)
end

function STR:range(lo, hi)
  assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
  return add_rule(self, "range", { lo, hi }, function(value)
    local n = ulen(value)
    return n >= lo and n <= hi
  end, function(a)
    return "must be between " .. tostring(a[1]) .. " and " .. tostring(a[2]) .. " characters long"
  end)
end

function STR:trim()
  return self:transform(function(v) return (v:gsub("^%s+", ""):gsub("%s+$", "")) end)
end

function STR:to_lower() return self:transform(string.lower) end

function STR:to_upper() return self:transform(string.upper) end

--============================================================--
-- Substrings and patterns
--============================================================--

constraint("contains", function(v, seed) return v:find(seed, 1, true) ~= nil end,
  "does not contain the required substring", string_arg("contains: seed"))
constraint("not_contains", function(v, seed) return v:find(seed, 1, true) == nil end,
  "must not contain the given substring", string_arg("not_contains: seed"))
constraint("starts_with", function(v, prefix) return v:sub(1, #prefix) == prefix end,
  "does not start with the required prefix", string_arg("starts_with: prefix"))
constraint("ends_with", function(v, suffix) return suffix == "" or v:sub(- #suffix) == suffix end,
  "does not end with the required suffix", string_arg("ends_with: suffix"))
constraint("matches", function(v, pattern) return v:match(pattern) ~= nil end, "has an invalid format",
  function(pattern)
    assert(type(pattern) == "string", "matches: pattern must be a Lua pattern string")
    assert(pcall(string.find, "", pattern), "matches: invalid Lua pattern '" .. pattern .. "'")
  end)

--============================================================--
-- Text formats
--============================================================--

constraint("boolean_string", text.boolean_string, "must be 'true' or 'false'")
constraint("number_string", util.is_decimal_string, "must be a numeric string")
constraint("date_string", function(v) return dates.to_timestamp(v) ~= nil end, "must be a valid date string")
constraint("json", json.is_valid, "must be valid JSON")
constraint("alpha", text.alpha, "must contain only letters")
constraint("alphanumeric", text.alphanumeric, "must contain only letters and numbers")
constraint("ascii", text.ascii, "must contain only ASCII characters")
constraint("lowercase", text.lowercase, "must be lowercase")
constraint("uppercase", text.uppercase, "must be uppercase")
constraint("base32", text.base32, "must be a valid base32 string")
constraint("base64", text.base64, "must be a valid base64 string")
constraint("hexadecimal", text.hexadecimal, "must be a valid hexadecimal string")
constraint("octal", text.octal, "must be a valid octal string")
constraint("jwt", text.jwt, "must be a well-formed JWT")
constraint("sem_ver", text.sem_ver, "must be a valid semantic version")
constraint("strong_password", text.strong_password,
  "must be at least 8 characters and include an uppercase letter, a lowercase letter, a digit and a symbol")
STR.password = STR.strong_password
constraint("hex_color", text.hex_color, "must be a valid hex color")
constraint("hsl", text.hsl, "must be a valid hsl()/hsla() color")
constraint("rgb", text.rgb, "must be a valid rgb()/rgba() color")

--============================================================--
-- Network formats
--============================================================--

constraint("email", network.email, "must be a valid email address")
constraint("url", network.url, "must be a valid URL", function(opts)
  assert(opts == nil or type(opts) == "table", "url(opts): opts must be a table or nil")
  if opts and opts.protocols ~= nil then
    assert(opts.protocols == "*" or type(opts.protocols) == "table",
      "url(opts): opts.protocols must be a list of schemes or '*'")
  end
end)
constraint("ip_address", network.ip_address, "must be a valid IP address", function(version)
  assert(version == nil or version == "v4" or version == "v6" or version == 4 or version == 6,
    "ip_address: version must be 'v4', 'v6' or nil")
end)
constraint("mac_address", network.mac_address, "must be a valid MAC address")
constraint("port_number", network.port_number, "must be a valid port number (0-65535)")

--============================================================--
-- Identifiers
--============================================================--

constraint("uuid", identifiers.uuid, "must be a valid UUID", function(version)
  assert(version == nil or (type(version) == "number" and version >= 1 and version <= 8),
    "uuid(version): version must be 1-8 or nil")
end)
constraint("phone", identifiers.phone, "must be a valid phone number")
constraint("isbn", identifiers.isbn, "must be a valid ISBN-10 or ISBN-13")
constraint("credit_card", identifiers.credit_card, "must be a valid credit card number")
constraint("passport_number", identifiers.passport_number, "must look like a valid passport number")
constraint("postal_code", identifiers.postal_code, "must look like a valid postal code")
constraint("ethereum_address", identifiers.ethereum_address, "must be a valid Ethereum address")
constraint("btc_address", identifiers.btc_address, "must be a valid Bitcoin address")
