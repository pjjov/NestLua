-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Serves examples/app.lua over HTTP with libmicrohttpd (lua-mhd).
--
--   luarocks install lua-mhd
--   lua examples/server.lua [port]
--   curl localhost:8080/api/health

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local adapter = require "nestlua.mhd"

local port = tonumber(arg and arg[1]) or 8080

local srv = adapter.listen({
  port = port,
  thread_pool_size = 4,
  max_body_size = 10 * 1024 * 1024,
  nest = { body_parser = { limit = 10 * 1024 * 1024 } },
}, "./examples/app.lua", "Hello from NestLua")

print("Listening on http://localhost:" .. port .. " (press Enter to stop)")
io.read("l")
srv:stop()
