-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Handler argument resolution: reads each use_* descriptor from the
-- request context and runs it through its pipes.

local http = require "nestlua.http"
local try = require "nestlua.try"
local protocol = require("nestlua.pipes").protocol

local args = {}

local function label(p)
  return p.kind .. (p.name and (" '" .. p.name .. "'") or "")
end

-- Turns a failed pipe into the matching 400.
local function reject(p, detail)
  if type(detail) == "table" then
    http.raise(400, { message = "Validation failed", source = p.kind, field = p.name, errors = detail })
  elseif type(detail) == "string" then
    http.raise(400, "Validation failed for " .. label(p) .. ": " .. detail)
  end
  http.raise(400, "Validation failed for " .. label(p))
end

local function apply_pipes(p, value, ctx)
  for _, pipe in ipairs(p.pipes) do
    local ok, passed, result = try(protocol.call, pipe, value, ctx)
    if not ok then
      -- passed = error, result = traceback
      if http.is_exception(passed) then error(passed, 0) end
      ctx.root:_log("error", "pipe failed for " .. label(p), passed, result, ctx)
      http.raise(400, "Pipe failed for " .. label(p))
    end
    if not passed then reject(p, result) end
    value = result
  end
  return value
end

local function last(v)
  if type(v) == "table" then return v[#v] end
  return v
end

-- kind -> function(descriptor, ctx) -> raw value (before pipes)
local READERS = {
  param = function(p, ctx) return ctx.params[p.name] end,
  query = function(p, ctx)
    if p.name == nil then return ctx.query end
    return last(ctx.query[p.name])
  end,
  query_array = function(p, ctx)
    local v = ctx.query[p.name]
    if v == nil then return {} end
    if type(v) ~= "table" then return { v } end
    return v
  end,
  header = function(p, ctx) return http.find_header(ctx.req.headers, p.name) end,
  body = function(p, ctx)
    local body = ctx.req.body
    if p.name == nil then return body end
    if type(body) == "table" then return body[p.name] end
    return nil
  end,
  file = function(p, ctx)
    local files = ctx.req.files
    return files and files[p.name] or nil
  end,
  custom = function(p, ctx) return p.selector(ctx) end,
}

-- kinds that bypass pipes entirely
local DIRECT = {
  request = function(_, ctx) return ctx.req end,
  response = function(_, ctx) return ctx.res end,
  inject = function(p, ctx) return ctx:inject(p.name) end,
}

--- Resolves every handler argument of `route` for `ctx`. Returns the list
--- and its length (arguments may be nil).
function args.resolve(route, ctx)
  local list = {}
  for i, p in ipairs(route.params) do
    local direct = DIRECT[p.kind]
    if direct then
      list[i] = direct(p, ctx)
    else
      local read = READERS[p.kind]
      if not read then error("unknown argument descriptor kind: " .. tostring(p.kind)) end
      list[i] = apply_pipes(p, read(p, ctx), ctx)
    end
  end
  return list, #route.params
end

return args
