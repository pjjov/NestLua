-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Example application: a small in-memory users API. Loaded once per
-- lua-mhd worker by examples/server.lua (each worker has its own state,
-- so the "database" here is per worker).

local nest = require "nestlua"
local scheme = require "nestlua.scheme"
local middleware = require "nestlua.middleware"
local openapi = require "nestlua.openapi"
local json = require "nestlua.json"

local pipes = nest.pipes

return function(greeting)
  --========================== users module ==========================--

  local users = nest.module("users")

  users:provide("users_repository", function()
    local rows, next_id = {}, 1
    local repo = {}
    function repo.list() return rows end
    function repo.find(id)
      for _, u in ipairs(rows) do
        if u.id == id then return u end
      end
    end
    function repo.create(data)
      data.id = next_id
      next_id = next_id + 1
      rows[#rows + 1] = data
      return data
    end
    return repo
  end)
  users:export("users_repository")

  local CreateUserDto = scheme {
    username = scheme.string:trim():range(3, 32):alphanumeric(),
    email = scheme.string:email(),
    password = scheme.string:strong_password(),
    password_confirm = scheme.string:same_as("password"),
  }:strip()

  local function RolesGuard(ctx)
    local needed = ctx:meta("roles")
    if not needed then return true end
    local role = nest.find_header(ctx.req.headers, "X-Role")
    for _, r in ipairs(needed) do
      if r == role then return true end
    end
    return false, "requires one of: " .. table.concat(needed, ", ")
  end

  local controller = users:controller("Users")
  controller:use_prefix("/users"):version("1"):guard(RolesGuard)

  controller:route("ListUsers")
      :get("/")
      :use_query("limit", pipes.default("10"), pipes.int)
      :use_inject("users_repository")
      :doc({ summary = "List users" })
      :handle(function(limit, repo)
        local out = json.array() -- encodes as [] even when empty
        for i, u in ipairs(repo.list()) do
          if i > limit then break end
          out[i] = { id = u.id, username = u.username }
        end
        return out
      end)

  controller:route("GetUser")
      :get("/:id(%d+)")
      :use_param("id", pipes.int)
      :use_inject("users_repository")
      :handle(function(id, repo)
        local u = repo.find(id)
        if not u then nest:not_found_error("user " .. id .. " not found") end
        return { id = u.id, username = u.username, email = u.email }
      end)

  controller:route("CreateUser")
      :post("/")
      :status(201)
      :meta("roles", { "admin" })
      :use_body(nil, CreateUserDto)
      :use_inject("users_repository")
      :doc({ summary = "Create a user", responses = { [201] = { description = "Created" } } })
      :handle(function(dto, repo)
        dto.password_confirm = nil
        local u = repo.create(dto)
        return { id = u.id, username = u.username }
      end)

  controller:route("UploadAvatar")
      :post("/:id(%d+)/avatar")
      :use_param("id", pipes.int)
      :use_file("avatar")
      :handle(function(id, file)
        if not file then nest:bad_request_error("missing 'avatar' file") end
        return { id = id, filename = file.filename, size = file.size, type = file.content_type }
      end)

  --=========================== app module ===========================--

  local app = nest.module("app")
  app:use_prefix("/api")
  app:import(users)
  app:use(middleware.request_id(), middleware.cors())

  app:controller("Health")
      :route("Health")
      :get("/health")
      :handle(function() return { status = "ok", greeting = greeting } end)

  app:controller("Files")
      :route("Download")
      :get("/files/readme")
      :handle(function() return nest.file("README.md", { content_type = "text/markdown", filename = "README.md" }) end)

  openapi.mount(app, "/openapi.json", { info = { title = "Example users API", version = "1.0.0" } })

  return app
end
