-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Shared test helpers: always loads NestLua from ./src, never from an
-- installed rock.

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local helper = { failures = 0 }

function helper.check(name, cond, extra)
  if cond then
    print("PASS  " .. name)
  else
    helper.failures = helper.failures + 1
    print("FAIL  " .. name .. (extra ~= nil and (" -- " .. tostring(extra)) or ""))
  end
end

-- pcall that also returns the error message, for assertion tests.
function helper.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then return false end
  if pattern then return tostring(err):find(pattern, 1, true) ~= nil end
  return true
end

function helper.done()
  print("")
  if helper.failures == 0 then
    print("ALL TESTS PASSED")
  else
    print(helper.failures .. " TEST(S) FAILED")
    os.exit(1)
  end
end

-- A quiet module (no stderr logging) for tests.
function helper.module(name)
  local nest = require "nestlua"
  return nest.module(name):logger(false)
end

function helper.get(mod, url, headers)
  return mod:handle({ method = "GET", url = url, headers = headers or {} })
end

return helper
