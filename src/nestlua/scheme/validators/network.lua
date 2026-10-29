-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Network-format predicates: URLs, e-mail, IP and MAC addresses, ports.

local function is_url(s, opts)
  opts = opts or {}
  local scheme_part, rest = s:match("^(%a[%w+.-]*)://(.+)$")
  if not scheme_part or rest == "" then return false end
  local protocols = opts.protocols or { "http", "https", "ftp" }
  if protocols ~= "*" then
    local allowed = false
    for _, p in ipairs(protocols) do
      if scheme_part:lower() == p:lower() then allowed = true end
    end
    if not allowed then return false end
  end
  local host = rest:match("^([^/%?#]+)")
  if not host or host == "" then return false end
  host = host:match("^[^@]*@(.+)$") or host
  local hostname, port = host:match("^%[([%x:%.]+)%](.*)$") -- [ipv6]:port
  if not hostname then hostname, port = host:match("^([^:]+)(.*)$") end
  if not hostname or hostname == "" then return false end
  if port ~= "" and not port:match("^:%d+$") then return false end
  if opts.require_tld and not hostname:match("%.%a%a+$") then return false end
  return hostname:match("^[%w%-%._~%%]+$") ~= nil or host:sub(1, 1) == "["
end

local function is_email(s)
  local at_count = 0
  for _ in s:gmatch("@") do at_count = at_count + 1 end
  if at_count ~= 1 then return false end
  local user, domain = s:match("^([^@]+)@([^@]+)$")
  if not user or user == "" or #user > 64 then return false end
  if not user:match("^[%w%.%%%+%-_]+$") then return false end
  if user:match("^%.") or user:match("%.$") or user:find("..", 1, true) then return false end
  if not domain or not domain:match("^[%w%-%.]+$") then return false end
  if not domain:find("%.") then return false end
  if domain:match("^%.") or domain:match("%.$") or domain:find("%.%.") then return false end
  for label in domain:gmatch("[^%.]+") do
    if label:match("^%-") or label:match("%-$") then return false end
  end
  local tld = domain:match("%.([%a]+)$")
  return tld ~= nil and #tld >= 2
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

-- Splits on ':' keeping empty groups, so malformed input like "1:::2" or
-- "1::2::3" is rejected instead of silently collapsing.
local function ipv6_groups(s)
  if s == "" then return {} end
  local groups = {}
  for g in (s .. ":"):gmatch("([^:]*):") do groups[#groups + 1] = g end
  return groups
end

local function valid_group(g) return g:match("^%x%x?%x?%x?$") ~= nil end

local function is_ipv6(s)
  s = s:match("^(.-)%%[%w%.]+$") or s -- strip a zone id ("fe80::1%eth0")
  local ipv4_tail = s:match(":(%d+%.%d+%.%d+%.%d+)$")
  if ipv4_tail then
    if not is_ipv4(ipv4_tail) then return false end
    s = s:sub(1, #s - #ipv4_tail) .. "0" -- placeholder group for the v4 part
  end
  local extra = ipv4_tail and 1 or 0 -- the v4 part takes two groups' worth
  local first, second = s:find("::", 1, true)
  if first then
    if s:find("::", second + 1, true) then return false end -- only one "::"
    local before, after = s:sub(1, first - 1), s:sub(second + 1)
    if after:sub(1, 1) == ":" then return false end          -- ":::"
    local gb, ga = ipv6_groups(before), ipv6_groups(after)
    for _, g in ipairs(gb) do if not valid_group(g) then return false end end
    for _, g in ipairs(ga) do if not valid_group(g) then return false end end
    return #gb + #ga + extra <= 7 -- "::" stands for at least one group
  end
  local groups = ipv6_groups(s)
  if #groups + extra ~= 8 then return false end
  for _, g in ipairs(groups) do
    if not valid_group(g) then return false end
  end
  return true
end

local function is_ip_address(s, version)
  if version == "v4" or version == 4 then return is_ipv4(s) end
  if version == "v6" or version == 6 then return is_ipv6(s) end
  return is_ipv4(s) or is_ipv6(s)
end

local function is_mac_address(s)
  local sep = s:find(":", 1, true) and ":" or (s:find("-", 1, true) and "-" or nil)
  if not sep then return false end
  local parts = {}
  for p in (s .. sep):gmatch("([^" .. sep .. "]*)" .. (sep == "-" and "%-" or sep)) do parts[#parts + 1] = p end
  if #parts ~= 6 then return false end
  for _, p in ipairs(parts) do
    if not p:match("^%x%x$") then return false end
  end
  return true
end

local function is_port_number(s)
  if not s:match("^%d+$") or #s > 5 then return false end
  local n = tonumber(s)
  return n >= 0 and n <= 65535
end

return {
  url = is_url,
  email = is_email,
  ipv4 = is_ipv4,
  ipv6 = is_ipv6,
  ip_address = is_ip_address,
  mac_address = is_mac_address,
  port_number = is_port_number,
}
