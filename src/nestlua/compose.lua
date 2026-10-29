-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Folding guards, interceptors/middleware and exception filters.

local util = require "nestlua.util"

local is_callable = util.is_callable

local compose = {}

--- Wraps `final(ctx)` in `fn(ctx, next)` layers, the first fn outermost.
function compose.chain(fns, final)
  local handler = final
  for i = #fns, 1, -1 do
    local fn = fns[i]
    local next_handler = handler
    handler = function(ctx)
      return fn(ctx, function() return next_handler(ctx) end)
    end
  end
  return handler
end

--- Folds several guards into one callback.
function compose.guards(...)
  local guards = { ... }
  for _, g in ipairs(guards) do
    assert(is_callable(g), "compose_guards: every guard must be a function")
  end
  return function(ctx)
    for _, g in ipairs(guards) do
      local allowed, reason = g(ctx)
      if not allowed then return false, reason end
    end
    return true
  end
end

--- Folds several interceptors (or middleware) into one callback.
function compose.interceptors(...)
  local interceptors = { ... }
  for _, i in ipairs(interceptors) do
    assert(is_callable(i), "compose_interceptors: every interceptor must be a function")
  end
  return function(ctx, next_fn)
    return compose.chain(interceptors, function() return next_fn() end)(ctx)
  end
end

--- Folds several exception filters into one callback that tries each in
--- order and returns the first response.
function compose.filters(...)
  local filters = { ... }
  for _, f in ipairs(filters) do
    assert(is_callable(f), "compose_filters: every filter must be a function")
  end
  return function(exception, ctx)
    for _, f in ipairs(filters) do
      local response = f(exception, ctx)
      if response then return response end
    end
    return nil
  end
end

return compose
