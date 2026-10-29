-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

-- Immutability, transforms, object modes, composition, new constraints
-- and validator fixes.

local h = require "test.helper"
local scheme = require "nestlua.scheme"
local json = require "nestlua.json"
local check, raises = h.check, h.raises

local function ok(s, v) return (s(v)) == true end
local function parsed(s, v)
  local good, value = s:parse(v)
  return good and value or nil
end

--=====================================================--
-- Immutability
--=====================================================--

local Contact = scheme { email = scheme.string:email() }
local User = scheme { contact = Contact:optional() } -- luacheck: ignore
check("optional() does not mutate the original", not ok(Contact, nil))
local base = scheme.string:min(2)
local longer = base:min(5)
check("chaining returns a new schema", ok(base, "abc") and not ok(longer, "abc"))
check("message() does not mutate the original", (select(2, base("a")))[1] ~= "custom" and
  (select(2, base:message("custom")("a")))[1] == "custom")

--=====================================================--
-- parse(): defaults, coercion, transforms
--=====================================================--

check("coerce() converts numeric strings", parsed(scheme.int:coerce(), "42") == 42)
check("coerce() rejects non-numeric strings", not ok(scheme.int:coerce(), "4x"))
check("coerce() rejects hex", not ok(scheme.number:coerce(), "0x10"))
check("coerce() converts booleans", select(2, scheme.boolean:coerce():parse("false")) == false and
  select(1, scheme.boolean:coerce():parse("false")) == true)
check("coerce() splits arrays", #parsed(scheme.array:of(scheme.int:coerce()):coerce(), "1,2,3") == 3)
check("default() fills nil", parsed(scheme.string:default("x"), nil) == "x")
check("default(fn) builds fresh values", parsed(scheme.table:default(function() return {} end), nil) ~=
  parsed(scheme.table:default(function() return {} end), nil))
check("trim() runs before length checks", ok(scheme.string:trim():min(3), "  abc  ") and
  not ok(scheme.string:trim():min(3), "  ab  "))
check("trim() result is returned by parse", parsed(scheme.string:trim(), "  a ") == "a")
check("to_lower()", parsed(scheme.string:to_lower(), "AbC") == "abc")
check("transform(fn)", parsed(scheme.int:transform(function(v) return v * 10 end), 4) == 40)
check("date:to_timestamp()", parsed(scheme.date:to_timestamp(), "1970-01-02") == 86400)

--=====================================================--
-- Objects: unknown fields, composition
--=====================================================--

local Dto = scheme { name = scheme.string, age = scheme.int:optional() }
local input = { name = "a", isAdmin = true }
check("passthrough keeps unknown fields (default)", parsed(Dto, input).isAdmin == true)
check("strip() drops unknown fields", parsed(Dto:strip(), input).isAdmin == nil and parsed(Dto:strip(), input).name == "a")
local sok, serr = Dto:strict()(input)
check("strict() rejects unknown fields", sok == false and serr.isAdmin[1] == "is not allowed")
check("objects reject arrays", not ok(Dto, { 1, 2 }))

local Ext = Dto:extend({ email = scheme.string:email() })
check("extend() adds fields", not ok(Ext, { name = "a" }) and ok(Ext, { name = "a", email = "a@b.co" }))
check("pick() keeps only some fields", ok(Ext:pick("name"), { name = "a" }))
check("omit() removes fields", ok(Ext:omit("email"), { name = "a" }))
check("partial() makes everything optional", ok(Ext:partial(), {}))
check("partial(names) makes only those optional", not ok(Ext:partial("email"), {}) and ok(Ext:partial("email"), { name = "x" }))
check("required() undoes optional", not ok(Dto:required(), { name = "a" }))
check("composition leaves the original untouched", not ok(Ext, {}))
check("field named like self_key is rejected", raises(function() scheme { _self = scheme.string } end, "collides"))

local nested = scheme { inner = scheme { v = scheme.int:coerce() }:strip() }:strip()
local nv = parsed(nested, { inner = { v = "5", junk = 1 }, junk = 2 })
check("parse() cleans nested objects", nv.inner.v == 5 and nv.inner.junk == nil and nv.junk == nil)

--=====================================================--
-- Cross-field and conditional rules
--=====================================================--

local Signup = scheme {
  password = scheme.string,
  confirm = scheme.string:same_as("password"),
}
check("same_as() passes when equal", ok(Signup, { password = "a", confirm = "a" }))
local cok, cerr = Signup({ password = "a", confirm = "b" })
check("same_as() fails when different", cok == false and cerr.confirm[1] == "must match password")

local Range = scheme { from = scheme.int, to = scheme.int }:refine(function(v) return v.to >= v.from end,
  "to must be >= from")
local rok, rerr = Range({ from = 5, to = 1 })
check("refine() on objects", rok == false and rerr._self[1] == "to must be >= from")

local Shipping = scheme {
  ship = scheme.boolean,
  address = scheme.string:min(5):validate_if(function(_, parent) return parent.ship end),
}
check("validate_if() skips when the predicate is false", ok(Shipping, { ship = false }))
check("validate_if() validates when true", not ok(Shipping, { ship = true, address = "x" }))

--=====================================================--
-- null, unions, tables, arrays
--=====================================================--

local decoded = json.decode('{"middle":null}')
local Person = scheme { middle = scheme.string:nullable() }
check("nullable() accepts JSON null", ok(Person, decoded))
check("non-nullable rejects JSON null", not ok(scheme { middle = scheme.string }, decoded))
check("optional() treats JSON null as absent", ok(scheme { middle = scheme.string:optional() }, decoded))

local IdOrName = scheme.any_of(scheme.int, scheme.string:min(2))
check("any_of() accepts either variant", ok(IdOrName, 3) and ok(IdOrName, "ab"))
local uok, uerr = IdOrName(true)
check("any_of() reports per-variant errors", uok == false and #uerr.variants == 2)

check("table:keys() validates keys", ok(scheme.table:keys(scheme.string:matches("^%l+$")), { abc = 1 }) and
  not ok(scheme.table:keys(scheme.string:matches("^%l+$")), { ABC = 1 }))
check("array:unique()", ok(scheme.array:unique(), { 1, 2 }) and not ok(scheme.array:unique(), { 1, { a = 1 }, { a = 1 } }))

--=====================================================--
-- New string constraints
--=====================================================--

check("matches()", ok(scheme.string:matches("^%d%d%d$"), "123") and not ok(scheme.string:matches("^%d%d%d$"), "12a"))
check("matches() validates the pattern eagerly", raises(function() return scheme.string:matches("[") end))
check("uuid()", ok(scheme.string:uuid(), "123e4567-e89b-42d3-a456-426614174000"))
check("uuid(version)", not ok(scheme.string:uuid(4), "123e4567-e89b-12d3-a456-426614174000"))
check("starts_with()/ends_with()", ok(scheme.string:starts_with("ab"):ends_with("yz"), "abxyz"))
check("url() rejects javascript: by default", not ok(scheme.string:url(), "javascript://x"))
check("url() protocols option", ok(scheme.string:url({ protocols = { "ws" } }), "ws://host:8080/x"))
check("url() rejects bad ports", not ok(scheme.string:url(), "http://host:abc/"))
check("ip_address() validates its version eagerly", raises(function() return scheme.string:ip_address("v5") end))

--=====================================================--
-- Validator fixes
--=====================================================--

check("string length counts UTF-8 characters", ok(scheme.string:max(3), "ććć") and not ok(scheme.string:max(2), "ććć"))
check("port_number rejects hex", not ok(scheme.string:port_number(), "0x10"))
check("port_number rejects exponent", not ok(scheme.string:port_number(), "1e3"))
check("number_string rejects hex", not ok(scheme.string:number_string(), "0x10"))
check("number_string accepts decimals", ok(scheme.string:number_string(), "-1.5e3"))
check("ipv6 rejects ':::'", not ok(scheme.string:ip_address("v6"), "1:::2"))
check("ipv6 rejects two '::'", not ok(scheme.string:ip_address("v6"), "1::2::3"))
check("ipv6 accepts embedded ipv4", ok(scheme.string:ip_address("v6"), "::ffff:192.168.0.1"))
check("ipv6 accepts full form", ok(scheme.string:ip_address("v6"), "1:2:3:4:5:6:7:8"))
check("ipv6 rejects 9 groups", not ok(scheme.string:ip_address("v6"), "1:2:3:4:5:6:7:8:9"))
check("number rejects NaN", not ok(scheme.number, 0 / 0))
check("number rejects infinity", not ok(scheme.number, math.huge))
check("int rejects infinity", not ok(scheme.int, -math.huge))
check("base64 rejects misplaced padding", not ok(scheme.string:base64(), "AA=A"))
check("email rejects leading dot", not ok(scheme.string:email(), ".a@b.co"))
check("sem_ver rejects leading zeros", not ok(scheme.string:sem_ver(), "01.2.3"))

--=====================================================--
-- Dates
--=====================================================--

check("impossible dates are rejected", not ok(scheme.date, "2023-02-31"))
check("leap days are accepted", ok(scheme.date, "2024-02-29") and not ok(scheme.date, "2023-02-29"))
check("bad times are rejected", not ok(scheme.date, "2024-01-01T25:00:00"))
check("dates are UTC", scheme.to_timestamp("1970-01-01") == 0)
check("Z suffix", scheme.to_timestamp("1970-01-01T00:00:10Z") == 10)
check("timezone offsets", scheme.to_timestamp("1970-01-01T01:00:00+01:00") == 0)
check("fractional seconds", scheme.to_timestamp("1970-01-01T00:00:01.5Z") == 1.5)
check("date tables are validated", not ok(scheme.date, { year = 2023, month = 13, day = 1 }))

--=====================================================--
-- Messages, i18n, flatten, describe
--=====================================================--

local _, merr = scheme.string:min(3):message("too short!")("a")
check("message() overrides the last rule's message", merr[1] == "too short!")
local _, terr = scheme.int:message("need an int")("x")
check("message() before rules overrides the type error", terr[1] == "need an int")
local _, ferr = scheme.int:min(10):message(function(args) return "min is " .. args[1] end)(1)
check("message() accepts a function", ferr[1] == "min is 10")

local original = scheme.translate
scheme.translate = function(key, default)
  if key == "required" then return "obligatorio" end
  return default
end
local _, ierr = scheme.string(nil)
check("scheme.translate customizes messages", ierr[1] == "obligatorio")
scheme.translate = original

local _, nested_err = scheme { a = scheme { b = scheme.string }, list = scheme.array:of(scheme.int) } ({
  a = {}, list = { 1, "x" } })
local flat = scheme.flatten(nested_err)
check("flatten() produces paths", #flat == 2 and flat[1].path == "a.b" and flat[2].path == "list[2]",
  flat[1] and flat[1].path)

local d = scheme.string:min(3):email():optional():describe()
check("describe() includes rule arguments", d.rules[1].name == "min" and d.rules[1].args[1] == 3)
check("describe() keeps rule names", d.rule_names[2] == "email")
check("describe() reports optional", d.optional == true)

check("custom constraints receive the validation context", (function()
  scheme:constraint("string", "differs_from", function(value, field, vctx)
    return vctx.parent == nil or vctx.parent[field] ~= value
  end, "must differ")
  return ok(scheme { a = scheme.string, b = scheme.string:differs_from("a") }, { a = "x", b = "y" }) and
      not ok(scheme { a = scheme.string, b = scheme.string:differs_from("a") }, { a = "x", b = "x" })
end)())

h.done()
