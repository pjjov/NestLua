-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Request body decoding middleware.

local nest = require "nestlua"
local json = require "nestlua.json"
local multipart = require "nestlua.middleware.multipart"

-- media type -> decoder(req, content_type, opts); each returns nothing
-- and raises an HTTP exception on malformed input
local function decode_json(req)
  local value, err = json.decode(req.body)
  if value == nil then nest:bad_request_error("Invalid JSON body: " .. tostring(err)) end
  req.body = value
end

local function decode_form(req)
  req.body = nest.parse_query(req.body)
end

local function decode_multipart(req, content_type, opts)
  local boundary = multipart.header_param(content_type, "boundary")
  if not boundary then nest:bad_request_error("multipart body without a boundary") end
  local fields, files = multipart.parse(req.body, boundary, opts)
  if not fields then nest:bad_request_error("Invalid multipart body: " .. tostring(files)) end
  req.body = fields
  req.files = files
end

local function decoder_for(mt, opts)
  if not mt then return nil end
  if opts.json ~= false and (mt == "application/json" or mt:match("%+json$")) then return decode_json end
  if opts.urlencoded ~= false and mt == "application/x-www-form-urlencoded" then return decode_form end
  if opts.multipart ~= false and mt == "multipart/form-data" then return decode_multipart end
  return nil
end

--- Decodes string request bodies according to Content-Type:
---   application/json (and +json)        -> table (json.null for null)
---   application/x-www-form-urlencoded   -> table
---   multipart/form-data                 -> fields table; files in req.files
---   anything else                       -> left as-is (raw in req.raw_body too)
--- Malformed bodies are rejected with 400; bodies above opts.limit
--- bytes with 413. Already-parsed requests are skipped, so it's safe if
--- both your module and an adapter install it.
---@param opts? { limit?: integer, json?: boolean, urlencoded?: boolean, multipart?: boolean, max_files?: integer }
return function(opts)
  opts = opts or {}
  local limit = opts.limit
  return function(ctx, next_fn)
    local req = ctx.req
    if req._body_parsed or type(req.body) ~= "string" or req.body == "" then
      return next_fn()
    end
    req._body_parsed = true
    if limit and #req.body > limit then
      nest:payload_too_large_error("Request body exceeds " .. limit .. " bytes")
    end
    req.raw_body = req.body
    local content_type = nest.find_header(req.headers, "Content-Type")
    local decode = decoder_for(multipart.media_type(content_type), opts)
    if decode then decode(req, content_type, opts) end
    return next_fn()
  end
end
