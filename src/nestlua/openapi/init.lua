-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  OpenAPI 3.1 document generator, driven entirely by module:routes() and
  the describe() output of scheme schemas / nest.pipes.

    local openapi = require "nestlua.openapi"
    local doc = openapi.generate(app, { info = { title = "API", version = "1.0" } })
    openapi.mount(app, "/openapi.json", { info = { ... } })   -- serve it

  Per-route documentation comes from route:doc{ summary=, description=,
  tags=, deprecated=, operation_id=, security=, responses = { [201] = {
  description = "Created", schema = SomeSchema } } }.

  Limitations: Lua patterns (:matches(), :id(%d+)) aren't regexes, so
  they're emitted as `x-lua-pattern` rather than `pattern`; wildcard
  segments become a single `{name}` path parameter.

  Implementation map:
    nestlua.openapi.schema     describe() -> JSON Schema
    nestlua.openapi.paths      path patterns -> path templates
    nestlua.openapi.operation  one route -> one operation object
--]]

local nest = require "nestlua"
local json = require "nestlua.json"
local schema = require "nestlua.openapi.schema"
local paths = require "nestlua.openapi.paths"
local operation = require "nestlua.openapi.operation"

local openapi = {}

--- Converts a scheme describe() table into a JSON Schema table.
openapi.schema_from_describe = schema.from_describe

local ALL_METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE" }

--- Builds the OpenAPI document (a plain table) for a module or app.
---@param target table  module or app
---@param opts? { info?: table, servers?: table, components?: table, security?: table, tags?: table }
function openapi.generate(target, opts)
  opts = opts or {}
  local module = nest.is_app(target) and target.module or target
  assert(nest.is_module(module), "openapi.generate(module): expected a Module or App")
  local doc = {
    openapi = "3.1.0",
    info = opts.info or { title = module.name, version = "1.0.0" },
    servers = opts.servers,
    components = opts.components,
    security = opts.security,
    tags = opts.tags,
    paths = {},
  }
  local used_ids = {}
  for _, entry in ipairs(module:routes()) do
    if not entry.meta.openapi_exclude then
      local methods = entry.method == "*" and ALL_METHODS or { entry.method }
      for _, variant in ipairs(paths.convert(entry.path)) do
        local item = doc.paths[variant.path] or {}
        doc.paths[variant.path] = item
        for _, method in ipairs(methods) do
          item[method:lower()] = operation.build(entry, variant.params, used_ids)
        end
      end
    end
  end
  return doc
end

--- The document as a JSON string.
function openapi.json(target, opts)
  return json.encode(openapi.generate(target, opts))
end

--- Registers `GET path` (default "/openapi.json") on the module, serving
--- the generated document. The route itself is excluded from the output.
function openapi.mount(module, path, opts)
  assert(nest.is_module(module), "openapi.mount(module, path, opts): expected a Module")
  module:controller("OpenAPI")
      :route("OpenAPIDocument")
      :get(path or "/openapi.json")
      :meta("openapi_exclude", true)
      :header("Content-Type", "application/json")
      :handle(function() return openapi.generate(module, opts) end)
  return module
end

return openapi
