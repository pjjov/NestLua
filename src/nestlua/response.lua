-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Response objects. A handler normally returns just the body; returning
  response.new{...} instead replaces the whole response (code/headers/
  body/file/stream), which is how handlers serve files or streams
  without use_response().
--]]

local util = require "nestlua.util"

local response = {}

---@class nestlua.ResponseFields
---@field code? integer
---@field headers? table<string, string>
---@field body? any
---@field file? string
---@field stream? fun(): string?
---@field stream_size? integer

--- Wraps a full response table so a handler can return status, headers and
--- body (or `file` / `stream`, see the adapter) in one value.
---@param t nestlua.ResponseFields
function response.new(t)
  assert(type(t) == "table", "nest.response(t): t must be a table")
  local r = util.copy(t)
  r.__class = "Response"
  return r
end

function response.is_response(obj) return util.is_instance(obj, "Response") end

--- Copies a nest.response{...} onto the mutable `res` table.
function response.apply(res, r)
  for k, v in pairs(r) do
    if k ~= "__class" then res[k] = v end
  end
  return res
end

--- Shorthand for a file download handled by the adapter.
---@param path string
---@param opts? { content_type?: string, filename?: string, code?: integer, headers?: table }
function response.file(path, opts)
  assert(type(path) == "string", "nest.file(path): path must be a string")
  opts = opts or {}
  local headers = util.copy(opts.headers or {})
  if opts.content_type then headers["Content-Type"] = opts.content_type end
  if opts.filename then
    headers["Content-Disposition"] = 'attachment; filename="' .. opts.filename:gsub('["\\]', "_") .. '"'
  end
  return response.new({ code = opts.code or 200, headers = headers, file = path })
end

--- Shorthand for a streamed response handled by the adapter. `producer`
--- is called repeatedly and returns the next chunk, or nil to finish.
---@param producer fun(): string?
---@param opts? { content_type?: string, code?: integer, headers?: table, size?: integer }
function response.stream(producer, opts)
  assert(type(producer) == "function", "nest.stream(producer): producer must be a function")
  opts = opts or {}
  local headers = util.copy(opts.headers or {})
  if opts.content_type then headers["Content-Type"] = opts.content_type end
  return response.new({ code = opts.code or 200, headers = headers, stream = producer, stream_size = opts.size })
end

return response
