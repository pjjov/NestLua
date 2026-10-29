-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- multipart/form-data parsing and Content-Type parameter helpers.

local multipart = {}

--- The lower-cased media type of a Content-Type value ("text/html").
function multipart.media_type(content_type)
  if type(content_type) ~= "string" then return nil end
  return (content_type:match("^%s*([^;%s]+)") or ""):lower()
end

--- A parameter of a header value: name="quoted value" or name=token.
function multipart.header_param(value, name)
  local v = value:match(";%s*" .. name .. '%s*=%s*"([^"]*)"')
  if v then return v end
  return value:match(";%s*" .. name .. "%s*=%s*([^;%s]+)")
end

local function parse_part_headers(raw)
  local headers = {}
  for line in (raw .. "\r\n"):gmatch("(.-)\r\n") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then headers[k:lower()] = v end
  end
  return headers
end

-- Adds `value` under `name`, turning repeated names into lists.
local function collect(map, name, value, is_single)
  local existing = map[name]
  if existing == nil then
    map[name] = value
  elseif is_single(existing) then
    map[name] = { existing, value }
  else
    existing[#existing + 1] = value
  end
end

local function is_string(v) return type(v) == "string" end

local function is_file(v) return v.filename ~= nil end

--- Parses a multipart/form-data body. Returns fields, files -- or nil,
--- message for malformed input. Files are
--- { filename=, content_type=, data=, size=, headers= }; repeated field
--- or file names are collected into lists.
---@param body string
---@param boundary string
---@param opts? { max_files?: integer }
function multipart.parse(body, boundary, opts)
  local max_files = (opts and opts.max_files) or 32
  local delimiter = "--" .. boundary
  local fields, files, file_count = {}, {}, 0

  local pos = body:find(delimiter, 1, true)
  if not pos then return nil, "multipart boundary not found" end
  pos = pos + #delimiter
  while body:sub(pos, pos + 1) ~= "--" do -- "--" after a delimiter closes the body
    if body:sub(pos, pos + 1) ~= "\r\n" then return nil, "malformed multipart delimiter" end
    pos = pos + 2
    local header_end = body:find("\r\n\r\n", pos, true)
    if not header_end then return nil, "malformed multipart part headers" end
    local headers = parse_part_headers(body:sub(pos, header_end - 1))
    local data_start = header_end + 4
    local next_delim = body:find("\r\n" .. delimiter, data_start, true)
    if not next_delim then return nil, "unterminated multipart part" end
    local data = body:sub(data_start, next_delim - 1)
    pos = next_delim + 2 + #delimiter

    local disposition = headers["content-disposition"] or ""
    local name = multipart.header_param(disposition, "name")
    if name then
      local filename = multipart.header_param(disposition, "filename")
      if filename then
        file_count = file_count + 1
        if file_count > max_files then return nil, "too many files" end
        collect(files, name, {
          filename = filename,
          content_type = headers["content-type"] or "application/octet-stream",
          data = data,
          size = #data,
          headers = headers,
        }, is_file)
      else
        collect(fields, name, data, is_string)
      end
    end
  end
  return fields, files
end

return multipart
