-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Request id middleware.

local nest = require "nestlua"

local request_id = {}

local seeded = false

--- A random RFC 4122 version 4 UUID (math.random based: unique enough for
--- correlation ids, not for secrets).
function request_id.random_uuid()
  if not seeded then
    math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
    seeded = true
  end
  local t = {}
  for i = 1, 16 do t[i] = string.format("%02x", math.random(0, 255)) end
  t[7] = string.format("%02x", 0x40 + math.random(0, 15)) -- version 4
  t[9] = string.format("%02x", 0x80 + math.random(0, 63)) -- RFC 4122 variant
  local s = table.concat(t)
  return s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16) .. "-" .. s:sub(17, 20) .. "-" .. s:sub(21)
end

--- Reuses the incoming X-Request-Id (or generates a UUID v4), stores it
--- as ctx.request_id and echoes it on the response.
--- opts.header (default "X-Request-Id"), opts.generate (function).
function request_id.middleware(opts)
  opts = opts or {}
  local header = opts.header or "X-Request-Id"
  local generate = opts.generate or request_id.random_uuid
  return function(ctx, next_fn)
    local id = nest.find_header(ctx.req.headers, header)
    if type(id) ~= "string" or id == "" or #id > 200 then id = generate() end
    ctx.request_id = id
    local res = next_fn()
    res.headers = res.headers or {}
    res.headers[header] = id
    return res
  end
end

return request_id
