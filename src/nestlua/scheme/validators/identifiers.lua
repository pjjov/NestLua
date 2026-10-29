-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Identifier predicates: phone numbers, ISBN, payment cards, passports,
-- postal codes, crypto addresses, UUIDs.

local function is_phone(s)
  local cleaned = s:gsub("[%s%-%.%(%)]", "")
  local digits = cleaned:match("^%+?(%d+)$")
  if not digits then return false end
  return #digits >= 7 and #digits <= 15
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

local function is_uuid(s, version)
  local v = s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-(%x)%x%x%x%-[89abAB]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
  if not v then
    return version == nil and (s == "00000000-0000-0000-0000-000000000000"
      or s:lower() == "ffffffff-ffff-ffff-ffff-ffffffffffff")
  end
  return version == nil or tonumber(v, 16) == version
end

return {
  phone = is_phone,
  isbn = is_isbn,
  credit_card = is_credit_card,
  passport_number = is_passport_number,
  postal_code = is_postal_code,
  ethereum_address = is_ethereum_address,
  btc_address = is_btc_address,
  uuid = is_uuid,
}
