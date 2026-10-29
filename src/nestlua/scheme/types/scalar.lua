-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Scalar types: boolean, number, int, date.

local schema = require "nestlua.scheme.schema"
local dates = require "nestlua.scheme.dates"

local add_rule = schema.add_rule
local to_timestamp = dates.to_timestamp

local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end

--============================================================--
-- boolean
--============================================================--

schema.define("boolean", {
  check = function(v)
    if type(v) == "boolean" then return true end
    return false, "must be a boolean"
  end,
})

--============================================================--
-- number / int
--============================================================--

local function numeric_constraints(methods)
  function methods:divisible_by(num)
    assert(type(num) == "number" and num ~= 0, "divisible_by: num must be a non-zero number")
    return add_rule(self, "divisible_by", { num }, function(value) return value % num == 0 end,
      function(a) return "must be divisible by " .. tostring(a[1]) end)
  end

  function methods:positive()
    return add_rule(self, "positive", {}, function(value) return value > 0 end, "must be positive")
  end

  function methods:negative()
    return add_rule(self, "negative", {}, function(value) return value < 0 end, "must be negative")
  end

  function methods:min(num)
    assert(type(num) == "number", "min: num must be a number")
    return add_rule(self, "min", { num }, function(value) return value >= num end,
      function(a) return "must be >= " .. tostring(a[1]) end)
  end

  function methods:max(num)
    assert(type(num) == "number", "max: num must be a number")
    return add_rule(self, "max", { num }, function(value) return value <= num end,
      function(a) return "must be <= " .. tostring(a[1]) end)
  end

  function methods:range(lo, hi)
    assert(type(lo) == "number" and type(hi) == "number", "range: lo/hi must be numbers")
    return add_rule(self, "range", { lo, hi }, function(value) return value >= lo and value <= hi end,
      function(a) return "must be between " .. tostring(a[1]) .. " and " .. tostring(a[2]) end)
  end
end

numeric_constraints(schema.define("number", {
  check = function(v)
    if type(v) == "number" and finite(v) then return true end
    return false, "must be a number"
  end,
}))

numeric_constraints(schema.define("int", {
  check = function(v)
    if type(v) == "number" and finite(v) and v == math.floor(v) then return true end
    return false, "must be an integer"
  end,
}))

--============================================================--
-- date
--============================================================--

local DATE = schema.define("date", {
  check = function(v)
    if to_timestamp(v) ~= nil then return true end
    return false, "must be a valid date"
  end,
})

local function bound(d, what)
  local ts = to_timestamp(d)
  assert(ts, what .. ": invalid date bound")
  return ts
end

function DATE:min(d)
  local lo = bound(d, "min")
  return add_rule(self, "min", { d }, function(value)
    local m = to_timestamp(value)
    return m ~= nil and m >= lo
  end, "date must not be earlier than the minimum")
end

function DATE:max(d)
  local hi = bound(d, "max")
  return add_rule(self, "max", { d }, function(value)
    local m = to_timestamp(value)
    return m ~= nil and m <= hi
  end, "date must not be later than the maximum")
end

function DATE:range(lo, hi)
  local blo, bhi = bound(lo, "range"), bound(hi, "range")
  return add_rule(self, "range", { lo, hi }, function(value)
    local m = to_timestamp(value)
    return m ~= nil and m >= blo and m <= bhi
  end, "date must be within range")
end

--- Cleaned value becomes the UTC unix timestamp instead of the input.
function DATE:to_timestamp()
  return self:transform(to_timestamp)
end
