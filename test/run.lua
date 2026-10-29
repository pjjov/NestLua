-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Runs every test suite with the current interpreter, each in its own
-- process (so suites can't leak state into each other). Run it from the
-- repository root:
--
--   lua test/run.lua            -- all suites
--   lua test/run.lua routing    -- only test/test_routing.lua

local SUITES = {
  "core", "exceptions", "routing", "modules", "pipes",
  "scheme", "scheme_v2", "json", "middleware", "openapi", "mhd",
}

-- the interpreter running this script (arg[-1], or further left if it
-- was started with options such as `-e ...`)
local interpreter = "lua"
if arg then
  local i = -1
  while arg[i] do
    interpreter = arg[i]
    i = i - 1
  end
end

local selected = {}
for i = 1, (arg and #arg or 0) do selected[arg[i]] = true end

local failed = {}
for _, name in ipairs(SUITES) do
  if next(selected) == nil or selected[name] then
    local file = "test/test_" .. name .. ".lua"
    local p = io.popen(interpreter .. " " .. file .. " 2>&1")
    local output = p:read("*a")
    local ok, _, code = p:close()
    -- Lua 5.1 returns only `true` from close(); detect failure from output
    local passed = (ok == true and (code == nil or code == 0)) and output:find("ALL TESTS PASSED", 1, true)
    if passed then
      local count = select(2, output:gsub("\nPASS ", "")) + (output:find("^PASS ") and 1 or 0)
      print(string.format("ok    %-12s (%d checks)", name, count))
    else
      failed[#failed + 1] = name
      print(string.format("FAIL  %s", name))
      for line in output:gmatch("[^\n]+") do
        if not line:find("^PASS ") then print("      " .. line) end
      end
    end
  end
end

print("")
if #failed == 0 then
  print("all suites passed (" .. _VERSION .. (rawget(_G, "jit") and (", " .. jit.version) or "") .. ")")
else
  print(#failed .. " suite(s) failed: " .. table.concat(failed, ", "))
  os.exit(1)
end
