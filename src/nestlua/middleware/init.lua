-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Built-in middleware for module:use(...). Every middleware here is a
  plain function(ctx, next) -> response, so it composes with your own.

    local middleware = require "nestlua.middleware"

    app:use(
      middleware.request_id(),
      middleware.cors({ origin = { "https://example.com" } }),
      middleware.body_parser({ limit = 1024 * 1024 }),
      middleware.logger()
    )

  Each one lives in its own module (nestlua.middleware.body_parser,
  .cors, .request_id, .logger; multipart parsing in .multipart) and can
  be required directly.
--]]

local multipart = require "nestlua.middleware.multipart"
local request_id = require "nestlua.middleware.request_id"

return {
  body_parser = require "nestlua.middleware.body_parser",
  cors = require "nestlua.middleware.cors",
  request_id = request_id.middleware,
  logger = require "nestlua.middleware.logger",

  -- helpers
  parse_multipart = multipart.parse,
  random_id = request_id.random_uuid,
}
