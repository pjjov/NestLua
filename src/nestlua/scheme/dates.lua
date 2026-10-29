-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[=[
  Date parsing. All dates are normalized to UTC unix timestamps,
  independent of the process time zone. Accepted inputs:
    * a number (unix timestamp, seconds)
    * a table { year=, month=, day=, hour=, min=, sec= } (UTC)
    * an ISO 8601 string: "YYYY-MM-DD", "YYYY-MM-DDTHH:MM[:SS[.fff]]"
      with an optional "Z" or "+hh:mm"/"-hh:mm"/"+hhmm" offset (no
      offset = UTC). Impossible dates (2023-02-31, 25:00) are rejected.
--]=]

local dates = {}

local function is_leap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(y, m)
  if m == 2 and is_leap(y) then return 29 end
  return DAYS_IN_MONTH[m]
end

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's
-- days_from_civil), so no os.time()/time zone is involved.
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Validated civil date/time -> UTC timestamp, or nil.
function dates.civil_timestamp(y, mo, d, h, mi, s)
  if not (y and mo and d) then return nil end
  h, mi, s = h or 0, mi or 0, s or 0
  if mo < 1 or mo > 12 or d < 1 or d > days_in_month(y, mo) then return nil end
  if h < 0 or h > 23 or mi < 0 or mi > 59 or s < 0 or s >= 61 then return nil end
  return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
end

-- "Z" / "+hh:mm" / "-hhmm" / "" -> offset in seconds, or nil if malformed.
local function parse_offset(tail)
  if tail == "" or tail == "Z" or tail == "z" then return 0 end
  local sign, oh, om = tail:match("^([+-])(%d%d):?(%d%d)$")
  if not sign then return nil end
  oh, om = tonumber(oh), tonumber(om)
  if oh > 23 or om > 59 then return nil end
  return (oh * 3600 + om * 60) * (sign == "+" and 1 or -1)
end

local function parse_iso(value)
  local y, mo, d, rest = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)(.*)$")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if rest == "" then return dates.civil_timestamp(y, mo, d) end

  local h, mi, tail = rest:match("^[T ](%d%d):(%d%d)(.*)$")
  if not h then return nil end
  local sec, frac = 0, 0
  local s, f, tail2 = tail:match("^:(%d%d)(%.?%d*)(.*)$")
  if s then
    if f == "." then return nil end
    sec, frac, tail = tonumber(s), tonumber("0" .. f), tail2
  end
  local offset = parse_offset(tail)
  if not offset then return nil end
  local ts = dates.civil_timestamp(y, mo, d, tonumber(h), tonumber(mi), sec)
  if not ts then return nil end
  return ts + frac - offset
end

--- Any accepted date value -> UTC unix timestamp, or nil.
function dates.to_timestamp(value)
  local tv = type(value)
  if tv == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if tv == "table" then
    return dates.civil_timestamp(tonumber(value.year), tonumber(value.month), tonumber(value.day),
      tonumber(value.hour), tonumber(value.min), tonumber(value.sec))
  end
  if tv == "string" then return parse_iso(value) end
  return nil
end

return dates
