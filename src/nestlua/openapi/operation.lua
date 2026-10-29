-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Builds one OpenAPI operation object from a module:routes() entry.

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack -- luacheck: ignore

local nest = require "nestlua"
local json = require "nestlua.json"
local schema = require "nestlua.openapi.schema"

local array = json.array

local operation = {}

local function is_required(p, optional)
  -- without a pipe the value may simply be absent; with one, the pipe
  -- decides, and nest.pipes.optional/default (or :optional()) mark it so
  return #p.pipes > 0 and not optional
end

local function path_parameters(route, path_params)
  local declared = {}
  for _, p in ipairs(route.params) do
    if p.kind == "param" then declared[p.name] = p end
  end
  local out = {}
  for _, pp in ipairs(path_params) do
    local s = declared[pp.name] and schema.from_pipes(declared[pp.name].pipes) or { type = "string" }
    if pp.constraint then s["x-lua-pattern"] = pp.constraint:sub(2, -2) end
    out[#out + 1] = { name = pp.name, ["in"] = "path", required = true, schema = s }
  end
  return out
end

-- query/header parameters, in declaration order
local PARAMETER_KINDS = {
  query = function(p)
    if not p.name then return nil end
    local s, optional = schema.from_pipes(p.pipes)
    return { name = p.name, ["in"] = "query", required = is_required(p, optional), schema = s }
  end,
  query_array = function(p)
    local s = schema.from_pipes(p.pipes)
    local items = s.type == "array" and (s.items or { type = "string" }) or s
    return { name = p.name, ["in"] = "query", required = false, style = "form", explode = true,
      schema = { type = "array", items = items } }
  end,
  header = function(p)
    local s, optional = schema.from_pipes(p.pipes)
    return { name = p.name, ["in"] = "header", required = is_required(p, optional), schema = s }
  end,
}

local function parameters(route, path_params)
  local list = array(path_parameters(route, path_params))
  for _, p in ipairs(route.params) do
    local make = PARAMETER_KINDS[p.kind]
    local param = make and make(p)
    if param then list[#list + 1] = param end
  end
  if #list > 0 then return list end
  return nil
end

local function request_body(route)
  local fields, whole, files = {}, nil, {}
  for _, p in ipairs(route.params) do
    if p.kind == "body" and p.name then
      local s, optional = schema.from_pipes(p.pipes)
      fields[#fields + 1] = { name = p.name, schema = s, required = is_required(p, optional) }
    elseif p.kind == "body" then
      whole = schema.from_pipes(p.pipes)
    elseif p.kind == "file" then
      files[#files + 1] = p.name
    end
  end

  if #files > 0 then
    local props, required = {}, array()
    for _, f in ipairs(files) do
      props[f] = { type = "string", format = "binary" }
      required[#required + 1] = f
    end
    for _, f in ipairs(fields) do props[f.name] = f.schema end
    return { required = true, content = { ["multipart/form-data"] = {
      schema = { type = "object", properties = props, required = required } } } }
  end

  if not whole and #fields == 0 then return nil end
  local s = whole
  if not s then
    local props, required = {}, array()
    for _, f in ipairs(fields) do
      props[f.name] = f.schema
      if f.required then required[#required + 1] = f.name end
    end
    s = { type = "object", properties = props }
    if #required > 0 then s.required = required end
  end
  return { required = true, content = { ["application/json"] = { schema = s } } }
end

local function responses(entry)
  local route, docs = entry.route, entry.route.docs or {}
  local out = {}
  if docs.responses then
    for code, r in pairs(docs.responses) do
      local resp = { description = r.description or nest.status_text[tonumber(code)] or "Response" }
      if r.schema then
        resp.content = { [r.content_type or "application/json"] = { schema = schema.from_describe(r.schema) } }
      end
      out[tostring(code)] = resp
    end
  else
    local code = route.status or 200
    out[tostring(code)] = { description = nest.status_text[code] or "Success" }
  end
  for _, p in ipairs(route.params) do
    if #p.pipes > 0 and not out["400"] then out["400"] = { description = "Validation failed" } end
  end
  if entry.guard_count > 0 and not out["403"] then out["403"] = { description = "Forbidden" } end
  return out
end

--- Builds the operation for `entry` (a module:routes() item) at a path
--- variant with `path_params`. `used_ids` keeps operationIds unique.
function operation.build(entry, path_params, used_ids)
  local route = entry.route
  local docs = route.docs or {}
  local id = docs.operation_id or route.name
  if used_ids[id] then
    used_ids[id] = used_ids[id] + 1
    id = id .. "_" .. used_ids[id]
  else
    used_ids[id] = 1
  end
  local tags = docs.tags or { entry.controllers[1] or entry.controller }
  return {
    operationId = id,
    summary = docs.summary,
    description = docs.description,
    deprecated = docs.deprecated or nil,
    security = docs.security,
    tags = array({ unpack(tags) }),
    parameters = parameters(route, path_params),
    requestBody = request_body(route),
    responses = responses(entry),
  }
end

return operation
