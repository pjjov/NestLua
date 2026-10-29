-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Nest-like path patterns, compiled once per endpoint at build() time:
    /users            literal segment
    /:id              named param (one segment)
    /:id(%d+)         named param constrained by an anchored Lua pattern
    /:id?             optional param (only trailing segments may be optional)
    /*  or  /*path    wildcard, must be last, captures the remaining path
                      as params["*"] (and params.path for the named form)
--]]

local url = require "nestlua.url"

local percent_decode = url.percent_decode

local pattern = {}

---@class nestlua.PatternSegment
---@field type "literal"|"param"|"wildcard"
---@field value? string        literal text
---@field name? string         param / wildcard name
---@field constraint? string   anchored Lua pattern for constrained params
---@field optional? boolean

---@class nestlua.CompiledPattern
---@field segments nestlua.PatternSegment[]
---@field ranks integer[]      per-segment specificity, for route ordering
---@field signature string     shape used to detect duplicate routes

-- Weight of each segment kind for route ranking (higher = more specific).
local RANK = { literal = 4, constrained = 3, param = 2, optional = 1, wildcard = 0, missing = 5 }

local function compile_param(seg, path, seen_optional)
  local name, constraint, optional = seg:match("^:([%w_]+)(%b())(%??)$")
  if not name then
    name, optional = seg:match("^:([%w_]+)(%??)$")
  end
  assert(name, "invalid path param '" .. seg .. "' in pattern '" .. path .. "'")
  if constraint then
    constraint = "^(" .. constraint:sub(2, -2) .. ")$"
    assert(pcall(string.find, "", constraint), "invalid Lua pattern in '" .. seg .. "' of '" .. path .. "'")
  end
  optional = optional == "?"
  assert(optional or not seen_optional,
    "required segment '" .. seg .. "' cannot follow an optional one in pattern '" .. path .. "'")
  local rank = optional and RANK.optional or (constraint and RANK.constrained or RANK.param)
  local signature = ":" .. (constraint or "") .. (optional and "?" or "")
  return { type = "param", name = name, constraint = constraint, optional = optional }, rank, signature
end

--- Compiles "/users/:id/*" into segment descriptors. Raises on malformed
--- patterns.
---@param path string
---@return nestlua.CompiledPattern
function pattern.compile(path)
  assert(type(path) == "string", "path pattern must be a string")
  local segs = url.split_path(path)
  local compiled = { segments = {}, ranks = {} }
  local signature = {}
  local seen_optional = false
  for idx, seg in ipairs(segs) do
    local part, rank, sig
    local wname = seg:match("^%*([%w_]*)$")
    if wname then
      assert(idx == #segs, "wildcard '" .. seg .. "' must be the last segment in pattern '" .. path .. "'")
      part, rank, sig = { type = "wildcard", name = wname ~= "" and wname or nil }, RANK.wildcard, "*"
    elseif seg:sub(1, 1) == ":" then
      part, rank, sig = compile_param(seg, path, seen_optional)
      seen_optional = seen_optional or part.optional
    else
      assert(not seen_optional,
        "literal segment '" .. seg .. "' cannot follow an optional param in pattern '" .. path .. "'")
      part, rank, sig = { type = "literal", value = seg }, RANK.literal, seg
    end
    compiled.segments[idx] = part
    compiled.ranks[idx] = rank
    signature[idx] = sig
  end
  compiled.signature = "/" .. table.concat(signature, "/")
  return compiled
end

--- Matches a compiled pattern against pre-split URL segments. Returns the
--- params table on success, or nil.
---@param compiled nestlua.CompiledPattern
---@param segs string[]
---@return table<string, string>?
function pattern.match(compiled, segs)
  local params = {}
  local ci = 1
  for _, part in ipairs(compiled.segments) do
    if part.type == "wildcard" then
      local rest = {}
      for j = ci, #segs do rest[#rest + 1] = percent_decode(segs[j]) end
      params["*"] = table.concat(rest, "/")
      if part.name then params[part.name] = params["*"] end
      return params
    end
    local seg = segs[ci]
    if seg == nil then
      if part.type == "param" and part.optional then return params end
      return nil
    end
    if part.type == "literal" then
      if seg ~= part.value then return nil end
    else
      local value = percent_decode(seg)
      if part.constraint and not value:match(part.constraint) then return nil end
      params[part.name] = value
    end
    ci = ci + 1
  end
  if ci <= #segs then return nil end -- leftover segments and no wildcard consumed them
  return params
end

--- Ordering for endpoints `{ compiled =, order = }`: more specific first,
--- then registration order.
function pattern.more_specific(a, b)
  local ra, rb = a.compiled.ranks, b.compiled.ranks
  for i = 1, math.max(#ra, #rb) do
    local x, y = ra[i] or RANK.missing, rb[i] or RANK.missing
    if x ~= y then return x > y end
  end
  return a.order < b.order
end

return pattern
