-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- NestLua path patterns -> OpenAPI path templates.

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack -- luacheck: ignore

local paths = {}

---@class nestlua.openapi.PathParam
---@field name string
---@field constraint? string   "(%d+)" as written in the pattern
---@field wildcard? boolean

local function parse_segment(seg)
  local wname = seg:match("^%*([%w_]*)$")
  if wname then
    return { name = wname ~= "" and wname or "wildcard", wildcard = true }
  end
  if seg:sub(1, 1) == ":" then
    return { name = seg:match("^:([%w_]+)"), constraint = seg:match("^:[%w_]+(%b())") }, seg:sub(-1) == "?"
  end
  return nil
end

--- "/users/:id(%d+)/*rest" -> { { path = "/users/{id}/{rest}", params = {...} } }.
--- Optional params expand into one variant per prefix ("/a" and "/a/{b}"),
--- since OpenAPI path params are always required.
---@param path string
---@return { path: string, params: nestlua.openapi.PathParam[] }[]
function paths.convert(path)
  local variants = { { segs = {}, params = {} } }
  for seg in path:gmatch("[^/]+") do
    local param, optional = parse_segment(seg)
    if optional then
      -- every variant so far stays valid without this (and every later) segment
      local base = variants[#variants]
      local with = { segs = { unpack(base.segs) }, params = { unpack(base.params) } }
      with.segs[#with.segs + 1] = "{" .. param.name .. "}"
      with.params[#with.params + 1] = param
      variants[#variants + 1] = with
    else
      for _, v in ipairs(variants) do
        if param then
          v.segs[#v.segs + 1] = "{" .. param.name .. "}"
          v.params[#v.params + 1] = param
        else
          v.segs[#v.segs + 1] = seg
        end
      end
    end
  end
  local out = {}
  for i, v in ipairs(variants) do
    out[i] = { path = "/" .. table.concat(v.segs, "/"), params = v.params }
  end
  return out
end

return paths
