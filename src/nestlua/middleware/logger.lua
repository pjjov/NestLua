-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Access log middleware.

--- Logs one line per request: method, path, status, duration (and the
--- request id when middleware.request_id runs before it).
--- opts.write(line, ctx, res) defaults to io.stderr; opts.clock to os.clock.
return function(opts)
  opts = opts or {}
  local write = opts.write or function(line, _, _) io.stderr:write(line, "\n") end
  local clock = opts.clock or os.clock
  return function(ctx, next_fn)
    local started = clock()
    local res = next_fn()
    local ms = (clock() - started) * 1000
    write(string.format("%s %s %d %.1fms%s", ctx.method, ctx.path, res.code or 200, ms,
      ctx.request_id and (" " .. ctx.request_id) or ""), ctx, res)
    return res
  end
end
