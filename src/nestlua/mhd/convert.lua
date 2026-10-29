-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- lua-mhd request/response tables <-> NestLua request/response tables.

local json = require "nestlua.json"

local convert = {}

local TEXT = "text/plain; charset=utf-8"
local JSON = "application/json; charset=utf-8"

--- lua-mhd request -> NestLua request. lua-mhd's parsed `query` is
--- reused (it keeps only the last value of a repeated key); auth fields
--- are passed through and the original table is kept as `raw`.
function convert.request(req)
  return {
    method = req.method,
    url = req.url,
    version = req.version,
    headers = req.headers or {},
    query = req.query or {},
    body = req.body,
    basic_auth = req.basic_auth,
    digest_username = req.digest_username,
    check_digest = req.check_digest,
    raw = req,
  }
end

-- lua-mhd only sends string header values: stringify, join lists.
local function header_value(v)
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = tostring(x) end
    return table.concat(parts, ", ")
  end
  return tostring(v)
end

-- Returns the converted headers and the key used for Content-Type, if any.
local function convert_headers(headers)
  local out, content_type = {}, nil
  for k, v in pairs(headers or {}) do
    if type(k) == "string" and v ~= nil and v ~= false then
      out[k] = header_value(v)
      if k:lower() == "content-type" then content_type = k end
    end
  end
  return out, content_type
end

-- Returns body string (or nil for file/stream responses), default
-- content type, and an error message if the body couldn't be encoded.
local function encode_body(body)
  if body == nil then return "", nil end
  if type(body) == "string" then return body, TEXT end
  if type(body) == "table" then
    local ok, encoded = pcall(json.encode, body)
    if ok then return encoded, JSON end
    return nil, nil, encoded
  end
  return tostring(body), nil
end

--- NestLua response -> lua-mhd response. Table bodies become JSON;
--- `file`, `stream`, `stream_size` and `digest_challenge` pass through.
--- opts.default_content_type = false skips the text/plain default.
function convert.response(res, opts)
  opts = opts or {}
  local headers, content_type = convert_headers(res.headers)
  local out = {
    code = tonumber(res.code) or 200,
    headers = headers,
    file = res.file,
    stream = res.stream,
    stream_size = res.stream_size,
    digest_challenge = res.digest_challenge,
  }
  if out.file or out.stream then return out end

  local body, default_type, err = encode_body(res.body)
  if err then
    io.stderr:write("[nestlua.mhd] could not encode response body: ", tostring(err), "\n")
    out.code, out.body = 500, "Internal Server Error"
    out.headers = { ["Content-Type"] = TEXT }
    return out
  end
  out.body = body
  if default_type and not content_type and (default_type == JSON or opts.default_content_type ~= false) then
    headers["Content-Type"] = default_type
  end
  return out
end

return convert
