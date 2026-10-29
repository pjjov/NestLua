-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Cross-Origin Resource Sharing middleware.

local nest = require "nestlua"

local function origin_allowed(rule, origin)
  if rule == "*" or rule == true then return true end
  if type(rule) == "string" then return rule == origin end
  if type(rule) == "function" then return rule(origin) and true or false end
  if type(rule) == "table" then
    for _, o in ipairs(rule) do
      if o == origin then return true end
    end
  end
  return false
end

--- Answers preflight requests itself and adds Access-Control-* headers
--- to every response.
---   origin      = "*" (default) | "https://a.com" | { list } | function(origin) -> bool
---   methods     = list (default GET, HEAD, PUT, PATCH, POST, DELETE)
---   headers     = allowed request headers (default: echo the preflight's)
---   expose      = list of response headers exposed to the browser
---   credentials = boolean
---   max_age     = seconds
return function(opts)
  opts = opts or {}
  local rule = opts.origin
  if rule == nil then rule = "*" end
  local methods = table.concat(opts.methods or { "GET", "HEAD", "PUT", "PATCH", "POST", "DELETE" }, ", ")
  local allow_headers = opts.headers and table.concat(opts.headers, ", ")
  local expose = opts.expose and table.concat(opts.expose, ", ")

  -- headers shared by preflight and actual responses
  local function apply(res, origin)
    local h = res.headers
    if rule == "*" and not opts.credentials then
      h["Access-Control-Allow-Origin"] = "*"
    else
      h["Access-Control-Allow-Origin"] = origin
      h["Vary"] = h["Vary"] and (h["Vary"] .. ", Origin") or "Origin"
    end
    if opts.credentials then h["Access-Control-Allow-Credentials"] = "true" end
    if expose then h["Access-Control-Expose-Headers"] = expose end
  end

  local function preflight(ctx, origin)
    local res = ctx.res
    res.code = 204
    apply(res, origin)
    res.headers["Access-Control-Allow-Methods"] = methods
    local requested = nest.find_header(ctx.req.headers, "Access-Control-Request-Headers")
    if allow_headers or requested then
      res.headers["Access-Control-Allow-Headers"] = allow_headers or requested
    end
    if opts.max_age then res.headers["Access-Control-Max-Age"] = tostring(opts.max_age) end
    return res
  end

  return function(ctx, next_fn)
    local origin = nest.find_header(ctx.req.headers, "Origin")
    if not origin or not origin_allowed(rule, origin) then return next_fn() end

    if ctx.method == "OPTIONS" and nest.find_header(ctx.req.headers, "Access-Control-Request-Method") ~= nil then
      return preflight(ctx, origin)
    end

    local res = next_fn()
    res.headers = res.headers or {}
    apply(res, origin)
    return res
  end
end
