-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  Protected calls that keep coroutines working.

  PUC Lua 5.1 cannot yield across pcall(), which breaks coroutine-based
  servers (cosockets etc.) as soon as a guard or handler does I/O. On
  that runtime only, user code is run inside a coroutine and any yields
  are forwarded to the caller (the classic "coxpcall" technique). Lua
  5.2+ and LuaJIT can yield across pcall natively, so they use xpcall
  directly.

  try(f, ...) returns (true, ...) or (false, err, traceback); the
  traceback is nil for HttpExceptions (they're control flow, not bugs).
--]]

local util = require "nestlua.util"
local http = require "nestlua.http"

local unpack, pack = util.unpack, util.pack

local needs_coxpcall = _VERSION == "Lua 5.1" and not rawget(_G, "jit")

local function traceback_of(err, co)
  if http.is_exception(err) then return nil end
  if co then return debug.traceback(co, tostring(err)) end
  return debug.traceback(tostring(err), 3)
end

local try
if needs_coxpcall then
  try = function(f, ...)
    local co = coroutine.create(f)
    local res = pack(coroutine.resume(co, ...))
    while true do
      if not res[1] then return false, res[2], traceback_of(res[2], co) end
      if coroutine.status(co) == "dead" then return unpack(res, 1, res.n) end
      res = pack(coroutine.resume(co, coroutine.yield(unpack(res, 2, res.n))))
    end
  end
else
  try = function(f, ...)
    local tb
    local res = pack(xpcall(f, function(err)
      tb = traceback_of(err)
      return err
    end, ...))
    if not res[1] then return false, res[2], tb end
    return unpack(res, 1, res.n)
  end
end

return try
