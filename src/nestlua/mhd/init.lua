-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  HTTP adapter for GNU libmicrohttpd via lua-mhd >= 2.1
  (https://github.com/pjjov/lua-mhd, `luarocks install lua-mhd`).

  lua-mhd runs every request on a worker thread with its own lua_State,
  so the application can't be built once and shared: each worker loads
  the app itself. Put the app in a module (or file) that returns a
  Module, an App, or a function(...) returning one:

    -- app.lua
    local nest = require "nestlua"
    local app = nest.module("app")
    app:controller("Hello"):route("Hi"):get("/"):handle(function() return { hello = "world" } end)
    return app

    -- server.lua
    local adapter = require "nestlua.mhd"
    local srv = adapter.listen({ port = 8080, thread_pool_size = 4 }, "app")   -- or "./app.lua"
    io.read("l")
    srv:stop()

  Extra arguments to listen() (nil/boolean/number/string only, a lua-mhd
  restriction) are passed to the app function in every worker.

  Already writing your own lua-mhd worker script? Use the handler:

    return require("nestlua.mhd").handler(require("app"))

  What the adapter does for you:
    * maps lua-mhd's request table onto NestLua's (see nestlua.mhd.convert)
    * installs nestlua.middleware.body_parser() in front of the app
      (JSON / urlencoded / multipart), unless opts.body_parser == false
    * encodes table bodies as JSON (Content-Type: application/json)
    * stringifies header values (lua-mhd drops non-string ones) and
      joins list values with ", "
    * passes `file`, `stream`, `stream_size` and `digest_challenge`
      response fields straight through to lua-mhd
--]]

local nest = require "nestlua"
local json = require "nestlua.json"
local body_parser = require "nestlua.middleware.body_parser"
local convert = require "nestlua.mhd.convert"

local adapter = {}

adapter.from_mhd = convert.request
adapter.to_mhd = convert.response

local function resolve_module(app)
  if nest.is_app(app) then return app.module end
  assert(nest.is_module(app), "nestlua.mhd: the app must be a Module, an App, or a function returning one")
  return app
end

--- Returns a lua-mhd request handler function(req) -> response for a
--- Module or App. opts.body_parser: false to skip the body parser, or a
--- table of body_parser options.
---@param app table
---@param opts? { body_parser?: false|table, default_content_type?: false }
function adapter.handler(app, opts)
  opts = opts or {}
  local module = resolve_module(app)
  if opts.body_parser ~= false then
    module:use_first(body_parser(type(opts.body_parser) == "table" and opts.body_parser or nil))
  end
  module:build()
  return function(req)
    local ok, res = pcall(module.handle, module, convert.request(req))
    if not ok then
      io.stderr:write("[nestlua.mhd] unhandled error: ", tostring(res), "\n")
      local headers = { ["Content-Type"] = "text/plain; charset=utf-8" }
      return { code = 500, headers = headers, body = "Internal Server Error" }
    end
    return convert.response(res, opts)
  end
end

--- Loads an app spec inside a worker: a module name ("app") or a file
--- path ("./app.lua"). The result may be a Module, an App, or a
--- function(...) returning one, called with the listen() extra args.
function adapter.load_app(spec, ...)
  local app
  if type(spec) == "string" and spec:match("%.lua$") then
    local chunk = assert(loadfile(spec))
    app = chunk(...)
  elseif type(spec) == "string" then
    app = require(spec)
  else
    error("nestlua.mhd: app spec must be a module name or a .lua file path")
  end
  if type(app) == "function" then app = app(...) end
  return app
end

--- Worker entry point used by listen(): loads the app and returns the
--- lua-mhd handler. `opts_json` holds the adapter options.
function adapter.worker(spec, opts_json, ...)
  local opts = opts_json and json.decode(opts_json, { null_as_nil = true }) or {}
  return adapter.handler(adapter.load_app(spec, ...), opts)
end

--- Runs first in every lua-mhd worker state. lua-mhd serializes it to
--- bytecode, so it must not capture locals (upvalues): it only uses
--- globals, and receives everything else as arguments.
function adapter.bootstrap(path, cpath, spec, opts_json, ...)
  package.path = path
  package.cpath = cpath
  return require("nestlua.mhd").worker(spec, opts_json, ...)
end

--- Starts a lua-mhd server running the given app.
---   options  -- lua-mhd server options ({ port = 8080, ... }); an
---               extra `nest` field holds adapter options
---               ({ body_parser = false | {...}, default_content_type = false })
---   app      -- module name or .lua path returning the app (see top)
---   ...      -- extra arguments for the app function
--- Returns the lua-mhd server (call :stop() to shut down). Workers
--- inherit this process's package.path / package.cpath.
function adapter.listen(options, app, ...)
  assert(type(options) == "table", "listen(options, app, ...): options must be a table")
  assert(type(app) == "string", "listen(options, app, ...): app must be a module name or a .lua path")
  local mhd = require "lua-mhd"
  local server_opts = {}
  for k, v in pairs(options) do
    if k ~= "nest" then server_opts[k] = v end
  end
  local nest_opts = options.nest and json.encode(options.nest) or nil
  return mhd.start(server_opts, adapter.bootstrap, package.path, package.cpath, app, nest_opts, ...)
end

return adapter
