-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

local h = require "test.helper"
local nest = require "nestlua"
local scheme = require "nestlua.scheme"
local check, get = h.check, h.get
local pipes = nest.pipes
---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack -- luacheck: ignore

local m = h.module("pipes")
local c = m:controller("C")

local function route(path, ...)
  local pipe_list = { ... }
  c:route(path):get(path):use_query("v", unpack(pipe_list))
      :handle(function(v) return { v = v, t = type(v) } end)
end

route("/int", pipes.int)
route("/num", pipes.number)
route("/bool", pipes.bool)
route("/uuid", pipes.uuid)
route("/uuid4", pipes.uuid(4))
route("/enum", pipes.enum("asc", "desc"))
route("/default", pipes.default("10"), pipes.int)
route("/optional", pipes.optional(pipes.int))
route("/trim", pipes.trim)
route("/array", pipes.array(pipes.int))
route("/chain", pipes.chain(pipes.trim, pipes.int))
route("/schema", scheme.int:coerce():min(5))
route("/http", function() nest:unauthorized_error("nope") end)
route("/bug", function() error("internal detail") end)
route("/detail", function() return false, "too spicy" end)
route("/table-detail", function() return false, { reason = "x" } end)

local function v(path) return get(m, path).body.v end
local function code(path) return get(m, path).code end

check("pipes.int parses", v("/int?v=42") == 42)
check("pipes.int rejects floats", code("/int?v=4.2") == 400)
check("pipes.int rejects hex", code("/int?v=0x10") == 400)
check("pipes.int requires a value", code("/int") == 400)
check("pipes.number parses decimals", v("/num?v=-1.5e2") == -150)
check("pipes.number rejects junk", code("/num?v=1.2.3") == 400)
check("pipes.bool parses false (a falsy value!)", v("/bool?v=false") == false and get(m, "/bool?v=false").body.t == "boolean")
check("pipes.bool rejects other strings", code("/bool?v=yes") == 400)
check("pipes.uuid accepts a uuid", code("/uuid?v=123e4567-e89b-42d3-a456-426614174000") == 200)
check("pipes.uuid rejects garbage", code("/uuid?v=123") == 400)
check("pipes.uuid(4) checks the version", code("/uuid4?v=123e4567-e89b-12d3-a456-426614174000") == 400)
check("pipes.enum accepts listed", v("/enum?v=asc") == "asc")
check("pipes.enum rejects unlisted", code("/enum?v=up") == 400)
check("pipes.default fills in and chains", v("/default") == 10)
check("pipes.optional passes nil", code("/optional") == 200 and v("/optional") == nil)
check("pipes.optional still validates", code("/optional?v=x") == 400)
check("pipes.trim trims", v("/trim?v=++a++") == "a")
local arr = v("/array?v=1,2,3")
check("pipes.array splits and pipes items", type(arr) == "table" and arr[3] == 3)
check("pipes.array reports bad items", code("/array?v=1,x") == 400)
check("pipes.chain composes", v("/chain?v=+7+") == 7)

local r = get(m, "/schema?v=3")
check("a scheme schema works directly as a pipe", code("/schema?v=9") == 200 and v("/schema?v=9") == 9)
check("schema errors become a structured 400 body",
  r.code == 400 and r.body.message == "Validation failed" and r.body.field == "v" and r.body.errors[1] ~= nil, r.body)

r = get(m, "/http")
check("HTTP exceptions from pipes keep their status", r.code == 401 and r.body == "nope", r.code)
r = get(m, "/bug")
check("pipe bugs -> 400 without leaking internals",
  r.code == 400 and not tostring(r.body):find("internal detail", 1, true), r.body)
r = get(m, "/detail")
check("string detail from a function pipe is reported", r.body:find("too spicy", 1, true) ~= nil, r.body)
r = get(m, "/table-detail")
check("table detail from a function pipe becomes errors", r.body.errors.reason == "x")

-- multiple pipes on one argument run left to right
local multi = h.module("multi")
multi:controller("M"):route("R"):get("/:id")
    :use_param("id", pipes.int, function(n) return n * 2 end)
    :handle(function(id) return id end)
check("several pipes per argument run in order", get(multi, "/21").body == 42)

-- the pipe protocol: any table with :parse(value, ctx)
local custom = { parse = function(_, value) return true, "parsed:" .. tostring(value) end }
local cm = h.module("custom")
cm:controller("C"):route("R"):get("/"):use_query("x", custom):handle(function(x) return x end)
check("custom :parse pipes are supported", get(cm, "/?x=1").body == "parsed:1")

check("non-pipes are rejected at registration", h.raises(function()
  h.module("bad"):controller("C"):route("R"):get("/"):use_query("x", 42)
end))

h.done()
