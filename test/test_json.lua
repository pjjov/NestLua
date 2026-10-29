-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

local h = require "test.helper"
local json = require "nestlua.json"
local check, raises = h.check, h.raises

check("encodes scalars", json.encode(1) == "1" and json.encode(1.5) == "1.5" and json.encode(true) == "true"
  and json.encode("a") == '"a"' and json.encode(nil) == "null")
check("encodes arrays", json.encode({ 1, 2, 3 }) == "[1,2,3]")
check("encodes objects with sorted keys", json.encode({ b = 1, a = 2 }) == '{"a":2,"b":1}')
check("empty table is an object", json.encode({}) == "{}")
check("json.array() forces an array", json.encode(json.array()) == "[]")
check("escapes strings", json.encode('a"b\\c\n\1') == '"a\\"b\\\\c\\n\\u0001"')
check("json.null encodes to null", json.encode({ a = json.null }) == '{"a":null}')
check("rejects cycles", raises(function()
  local t = {}
  t.self = t
  json.encode(t)
end, "cycles"))
check("rejects NaN", raises(function() json.encode(0 / 0) end))
check("rejects functions", raises(function() json.encode({ f = print }) end))

local v = json.decode('{"a":[1,2,{"b":null}],"s":"\\u00e9\\ud83d\\ude00","n":-1.5e2,"t":true,"f":false}')
check("decodes nested structures", v.a[3].b == json.null)
check("decodes unicode escapes and surrogate pairs", v.s == "é😀")
check("decodes numbers", v.n == -150)
check("decodes booleans", v.t == true and v.f == false)
check("decoded arrays re-encode as arrays", json.encode(json.decode("[]")) == "[]")
check("null_as_nil option", json.decode('{"a":null}', { null_as_nil = true }).a == nil)

for _, bad in ipairs({ "", "{", "[1,]", "{\"a\":}", "01", "1.", "\"\\x\"", "tru", "[1] x", "\"\1\"" }) do
  local value, err = json.decode(bad)
  check("rejects invalid JSON " .. string.format("%q", bad), value == nil and type(err) == "string")
end
check("max_depth guards deep nesting", json.decode(string.rep("[", 600) .. string.rep("]", 600)) == nil)
check("is_valid", json.is_valid('{"a":1}') and not json.is_valid("{a:1}"))

h.done()
