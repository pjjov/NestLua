-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  NestLua public API.

  This module implements the *routing / composition* layer only:
  modules, providers, controllers, routes, middleware, guards,
  interceptors, argument decorators, pipes and exception filters. A
  separate layer (an HTTP server adapter, e.g. `nestlua.mhd`) is
  expected to translate real socket traffic into the plain `request`
  table documented below, call `module:handle(request)`, and translate
  the returned `response` table back into bytes on the wire.

  Request table shape (produced by the adapter, read by NestLua):
    {
      method  = "GET",
      url     = "/users/42?sort=asc",
      version = "HTTP/1.1",
      headers = { ["Content-Type"] = "text/plain", ... },
      query   = { sort = "asc" },  -- optional: pre-parsed by the adapter
      body    = <any -- string, table, whatever the adapter decoded>,
    }

  Response table shape (produced by NestLua, read by the adapter):
    {
      code    = 200,
      headers = { ["Content-Type"] = "text/html", ... },
      body    = <any>,
      file    = <optional path, served by the adapter>,
      stream  = <optional chunk producer, see the adapter>,
    }

  Implementation map:
    nestlua.module / providers   Module class and dependency injection
    nestlua.controller / route   builder classes
    nestlua.router               build(): route table compilation
    nestlua.router.pattern       path pattern syntax and matching
    nestlua.router.dispatch      handle(): request pipeline
    nestlua.router.args          handler argument resolution
    nestlua.pipes                pipe protocol and built-in pipes
    nestlua.http / response      exceptions, status texts, responses
    nestlua.compose / try / url / util
--]]

local util = require "nestlua.util"
local url = require "nestlua.url"
local http = require "nestlua.http"
local response = require "nestlua.response"
local compose = require "nestlua.compose"
local pipes = require "nestlua.pipes"
local module = require "nestlua.module"

local nest = {}
nest._VERSION = "2.0.0"

--- Creates a new Module.
nest.module = module.new

-- type guards
nest.is_module = util.is_module
nest.is_controller = util.is_controller
nest.is_route = util.is_route
nest.is_app = util.is_app

-- HTTP exceptions: nest:not_found_error(message, headers), ...,
-- nest:http_error(code, message, headers)
http.install_helpers(nest)
nest.http_exception = http.exception
nest.is_http_exception = http.is_exception
nest.status_text = http.STATUS_TEXT
nest.HTTP_METHODS = http.METHODS

-- responses
nest.response = response.new
nest.is_response = response.is_response
nest.file = response.file
nest.stream = response.stream

-- pipes
nest.pipes = pipes.builtin
nest.pipe = pipes.protocol.new
nest.is_pipe = pipes.protocol.is_pipe

-- composition
nest.compose_guards = compose.guards
nest.compose_interceptors = compose.interceptors
nest.compose_middleware = compose.interceptors
nest.compose_filters = compose.filters

-- helpers useful to adapters and middleware
nest.parse_query = url.parse_query
nest.find_header = http.find_header
nest.try = require "nestlua.try"

return nest
