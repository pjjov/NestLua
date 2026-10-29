-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- The union type (scheme.any_of(a, b, ...)).

local config = require "nestlua.scheme.config"
local schema = require "nestlua.scheme.schema"

local union = {}

local UNION = schema.define("union", {})

--- A value matching any one of the given schemas (first match wins).
function union.any_of(...)
  local variants = { ... }
  assert(#variants > 0, "any_of(...): requires at least one schema")
  for _, s in ipairs(variants) do assert(schema.is_schema(s), "any_of(...): every argument must be a schema") end
  local u = schema.new("union")
  u.variants = variants
  return u
end

function UNION:validate(value, ctx)
  assert(schema.is_schema(self), "validate: self must be a schema")
  local vctx = schema.as_vctx(ctx)
  local done, dok, derr, v = schema.prelude(self, value, vctx)
  if done then return dok, derr, v end
  local attempts = {}
  for _, variant in ipairs(self.variants) do
    local ok, err, cleaned = variant:validate(v, vctx)
    if ok then
      cleaned = schema.apply_transforms(self, cleaned)
      local errors = {}
      schema.run_rules(self, cleaned, vctx, errors)
      if #errors > 0 then return false, errors end
      return true, nil, cleaned
    end
    attempts[#attempts + 1] = err
  end
  return false, { config.translate("union", "must match one of the allowed shapes", {}, v), variants = attempts }
end

return union
