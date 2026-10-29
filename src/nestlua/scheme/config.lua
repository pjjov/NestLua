-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

--[[
  User-tunable settings, exposed (read and write) as `scheme.self_key`
  and `scheme.translate` on the public module.
--]]

local config = {}

--- Key used for errors that belong to a table/object itself rather than
--- one of its fields/items.
config.self_key = "_self"

--- Every error message goes through translate(key, default, args, value)
--- right before it's reported. `key` is the rule name ("min", "email",
--- ...), "required", "unknown", "union", or "type.<type name>" for
--- type-check failures; `args` are the rule's arguments. Replace it to
--- translate or reword messages globally; use :message() for one rule.
function config.translate(key, default, args, value) -- luacheck: ignore
  return default
end

return config
