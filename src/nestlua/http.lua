-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  HTTP vocabulary: methods, status texts, headers and exceptions.

  Exceptions mirror Nest's built-in HttpException subclasses. The facade
  exposes each helper as a method on the required module
  (`nest:not_found_error()`), callable from inside a middleware, guard,
  interceptor, pipe, or route handler to abort the request with that
  status code; the raised value is caught centrally and turned into the
  equivalent HTTP response (subject to any exception filters).
--]]

local util = require "nestlua.util"

local http = {}

http.METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" }

http.STATUS_TEXT = {
  [100] = "Continue",
  [101] = "Switching Protocols",
  [200] = "OK",
  [201] = "Created",
  [202] = "Accepted",
  [203] = "Non-Authoritative Information",
  [204] = "No Content",
  [205] = "Reset Content",
  [206] = "Partial Content",
  [301] = "Moved Permanently",
  [302] = "Found",
  [303] = "See Other",
  [304] = "Not Modified",
  [307] = "Temporary Redirect",
  [308] = "Permanent Redirect",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [402] = "Payment Required",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [406] = "Not Acceptable",
  [407] = "Proxy Authentication Required",
  [408] = "Request Timeout",
  [409] = "Conflict",
  [410] = "Gone",
  [411] = "Length Required",
  [412] = "Precondition Failed",
  [413] = "Payload Too Large",
  [414] = "URI Too Long",
  [415] = "Unsupported Media Type",
  [416] = "Range Not Satisfiable",
  [417] = "Expectation Failed",
  [418] = "I'm a teapot",
  [421] = "Misdirected Request",
  [422] = "Unprocessable Entity",
  [423] = "Locked",
  [424] = "Failed Dependency",
  [425] = "Too Early",
  [426] = "Upgrade Required",
  [428] = "Precondition Required",
  [429] = "Too Many Requests",
  [431] = "Request Header Fields Too Large",
  [451] = "Unavailable For Legal Reasons",
  [500] = "Internal Server Error",
  [501] = "Not Implemented",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
  [505] = "HTTP Version Not Supported",
  [507] = "Insufficient Storage",
  [508] = "Loop Detected",
  [511] = "Network Authentication Required",
}

--- Case-insensitive header lookup.
---@param headers? table<string, any>
---@param name string
function http.find_header(headers, name)
  if not headers then return nil end
  if headers[name] ~= nil then return headers[name] end
  local lname = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == lname then return v end
  end
  return nil
end

--============================================================--
-- Exceptions
--============================================================--

---@class nestlua.HttpException
---@field code integer
---@field body any
---@field headers? table<string, string>
---@field cause? any   original error, when a non-HTTP error was normalized
---@field traceback? string

local HttpExceptionMeta = {
  __tostring = function(e) return "HttpException(" .. tostring(e.code) .. "): " .. tostring(e.body) end,
}

local function new_exception(fields)
  fields.__class = "HttpException"
  return setmetatable(fields, HttpExceptionMeta)
end

--- Builds (but does not throw) an HttpException-shaped value. `message` may
--- be a string, a table (for a structured error body), or nil to fall back
--- to the standard status text. `headers` (optional) are added to the
--- default error response (e.g. `Retry-After`, `WWW-Authenticate`).
---@param code integer
---@param message? string|table
---@param headers? table<string, string>
---@return nestlua.HttpException
function http.exception(code, message, headers)
  assert(type(code) == "number" and code >= 100 and code <= 599,
    "http_exception: code must be a valid HTTP status code")
  assert(message == nil or type(message) == "string" or type(message) == "table",
    "http_exception: message must be a string, a table, or nil")
  assert(headers == nil or type(headers) == "table", "http_exception: headers must be a table or nil")
  local body = message
  if body == nil then
    body = http.STATUS_TEXT[code] or ("HTTP " .. tostring(code))
  end
  return new_exception({ code = code, body = body, headers = headers })
end

function http.is_exception(obj) return util.is_instance(obj, "HttpException") end

--- Raises an HttpException.
function http.raise(code, message, headers)
  error(http.exception(code, message, headers), 0)
end

--- Normalizes anything caught from the pipeline into an HttpException-
--- shaped value: HttpExceptions pass through unchanged; anything else (a
--- plain string error, a Lua runtime error from a bug, ...) becomes a 500
--- with the original error kept as `.cause` (and its traceback). The body
--- never contains the error text unless `expose` is set.
function http.normalize(err, traceback, expose)
  if http.is_exception(err) then return err end
  local body = "Internal Server Error"
  if expose then body = body .. ": " .. tostring(err) end
  return new_exception({ code = 500, body = body, cause = err, traceback = traceback })
end

-- name -> status code for every one-liner exception helper.
http.EXCEPTIONS = {
  { name = "bad_request_error",                   code = 400 },
  { name = "unauthorized_error",                  code = 401 },
  { name = "payment_required_error",              code = 402 },
  { name = "forbidden_error",                     code = 403 },
  { name = "not_found_error",                     code = 404 },
  { name = "method_not_allowed_error",            code = 405 },
  { name = "not_acceptable_error",                code = 406 },
  { name = "request_timeout_error",               code = 408 },
  { name = "conflict_error",                      code = 409 },
  { name = "gone_error",                          code = 410 },
  { name = "length_required_error",               code = 411 },
  { name = "precondition_failed_error",           code = 412 },
  { name = "payload_too_large_error",             code = 413 },
  { name = "uri_too_long_error",                  code = 414 },
  { name = "unsupported_media_type_error",        code = 415 },
  { name = "range_not_satisfiable_error",         code = 416 },
  { name = "expectation_failed_error",            code = 417 },
  { name = "im_a_teapot_error",                   code = 418 },
  { name = "misdirected_error",                   code = 421 },
  { name = "unprocessable_entity_error",          code = 422 },
  { name = "locked_error",                        code = 423 },
  { name = "precondition_required_error",         code = 428 },
  { name = "too_many_requests_error",             code = 429 },
  { name = "unavailable_for_legal_reasons_error", code = 451 },
  { name = "internal_server_error",               code = 500 },
  { name = "not_implemented_error",               code = 501 },
  { name = "bad_gateway_error",                   code = 502 },
  { name = "service_unavailable_error",           code = 503 },
  { name = "gateway_timeout_error",               code = 504 },
  { name = "http_version_not_supported_error",    code = 505 },
}

--- Installs `target:name(message, headers)` raising helpers for every
--- entry of http.EXCEPTIONS, plus `target:http_error(code, message,
--- headers)`. `self` is ignored; the colon form matches the docs.
function http.install_helpers(target)
  for _, def in ipairs(http.EXCEPTIONS) do
    target[def.name] = function(_, message, headers) http.raise(def.code, message, headers) end
  end
  target.http_error = function(_, code, message, headers) http.raise(code, message, headers) end
end

return http
