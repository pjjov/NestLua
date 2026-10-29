-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

local h = require "test.helper"
local nest = require "nestlua"
local scheme = require "nestlua.scheme"
local json = require "nestlua.json"
local openapi = require "nestlua.openapi"
local check = h.check
local pipes = nest.pipes

local CreateUser = scheme {
  name = scheme.string:min(2):max(40),
  email = scheme.string:email(),
  age = scheme.int:min(0):optional(),
  role = scheme.string:is_in("admin", "user"):default("user"),
  tags = scheme.array:of(scheme.string):unique(),
}:strict()

local app = h.module("app"):use_prefix("/api")
local users = app:controller("Users"):use_prefix("/users"):version("1")
users:route("List"):get("/")
    :use_query("limit", pipes.default("10"), pipes.int)
    :use_query("q")
    :use_header("X-Tenant", pipes.uuid)
    :doc({ summary = "List users", tags = { "people" } })
    :handle(function() return {} end)
users:route("Get"):get("/:id(%d+)/:tab?")
    :use_param("id", pipes.int)
    :guard(function() return true end)
    :handle(function() return {} end)
users:route("Create"):post("/")
    :status(201)
    :use_body(nil, CreateUser)
    :doc({ responses = { [201] = { description = "Created", schema = scheme { id = scheme.int } } } })
    :handle(function() return {} end)
users:route("Avatar"):put("/:id/avatar"):use_file("image"):handle(function() end)
openapi.mount(app, "/openapi.json", { info = { title = "Test", version = "9" } })

local doc = openapi.generate(app, { info = { title = "Test", version = "9" } })
check("document header", doc.openapi == "3.1.0" and doc.info.title == "Test")

local list = doc.paths["/api/v1/users"].get
check("paths include prefixes and versions", list ~= nil)
check("operation metadata from :doc()", list.summary == "List users" and list.tags[1] == "people")
local limit, q, tenant = list.parameters[1], list.parameters[2], list.parameters[3]
check("query param with default is optional", limit.name == "limit" and limit.required == false)
check("pipe types reach the schema", limit.schema.type == "integer" and limit.schema.default == "10")
check("query param without pipes is optional", q.required == false)
check("header params", tenant["in"] == "header" and tenant.schema.format == "uuid" and tenant.required == true)
check("400 response added when pipes exist", list.responses["400"] ~= nil)

local get_full = doc.paths["/api/v1/users/{id}/{tab}"]
local get_short = doc.paths["/api/v1/users/{id}"]
check("optional params expand into path variants", get_full ~= nil and get_short ~= nil)
check("path params are required with their pipe schema",
  get_short.get.parameters[1].required == true and get_short.get.parameters[1].schema.type == "integer")
check("param constraints become x-lua-pattern", get_short.get.parameters[1].schema["x-lua-pattern"] == "%d+")
check("guarded routes document 403", get_short.get.responses["403"] ~= nil)
check("operation ids stay unique across variants", get_full.get.operationId ~= get_short.get.operationId)

local create = doc.paths["/api/v1/users"].post
local body = create.requestBody.content["application/json"].schema
check("request body schema from scheme", body.type == "object" and body.properties.email.format == "email")
check("required fields exclude optional/default ones",
  table.concat(body.required, ",") == "email,name,tags", table.concat(body.required, ","))
check("string length constraints", body.properties.name.minLength == 2 and body.properties.name.maxLength == 40)
check("enum and default", body.properties.role.enum[2] == "user" and body.properties.role.default == "user")
check("array items and uniqueItems", body.properties.tags.items.type == "string" and body.properties.tags.uniqueItems)
check("strict objects disallow additional properties", body.additionalProperties == false)
check("documented responses with schemas",
  create.responses["201"].content["application/json"].schema.properties.id.type == "integer")

local avatar = doc.paths["/api/v1/users/{id}/avatar"].put
check("file uploads become multipart binary",
  avatar.requestBody.content["multipart/form-data"].schema.properties.image.format == "binary")

check("the mounted document route is excluded", doc.paths["/api/openapi.json"] == nil)
local served = h.get(app, "/api/openapi.json")
check("openapi.mount serves the document", served.code == 200 and served.body.openapi == "3.1.0")
check("document encodes to JSON", json.decode(openapi.json(app)).paths ~= nil)

local nullable = openapi.schema_from_describe(scheme.string:nullable():describe())
check("nullable becomes a type union", nullable.type[1] == "string" and nullable.type[2] == "null")
local union = openapi.schema_from_describe(scheme.any_of(scheme.int, scheme.string):describe())
check("any_of becomes anyOf", #union.anyOf == 2)

h.done()
