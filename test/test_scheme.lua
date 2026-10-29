-- NestLua -- NestJS-inspired framework for Lua.
--
-- Copyright (C) 2026 Предраг Јовановић
-- SPDX-FileCopyrightText: 2026 Предраг Јовановић
-- SPDX-License-Identifier: Apache-2.0
--
-- Look at the LICENSE file for more information.

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local scheme = require "nestlua.scheme"

local failures = 0
local function check(name, cond, extra)
  if cond then
    print("PASS  " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name .. (extra and (" -- " .. tostring(extra)) or ""))
  end
end

--=====================================================--
-- Basic types
--=====================================================--

check("string type accepts string", (scheme.string)("hello"))
check("string type rejects number", not (scheme.string)(42))
check("number type accepts number", (scheme.number)(3.14))
check("number type rejects string", not (scheme.number)("3.14"))
check("int accepts integer", (scheme.int)(5))
check("int rejects float", not (scheme.int)(5.5))
check("boolean accepts true/false", (scheme.boolean)(true) and (scheme.boolean)(false))
check("boolean rejects string", not (scheme.boolean)("true"))
check("array accepts sequential table", (scheme.array)({ 1, 2, 3 }))
check("array rejects sparse table", not (scheme.array)({ [1] = "a", [3] = "b" }))
check("array rejects map", not (scheme.array)({ a = 1 }))
check("table accepts any table", (scheme.table)({ a = 1, b = 2 }))
check("table accepts array-shaped table too", (scheme.table)({ 1, 2, 3 }))
check("date accepts ISO date string", (scheme.date)("2024-01-15"))
check("date accepts ISO datetime string", (scheme.date)("2024-01-15T10:30:00"))
check("date accepts unix timestamp", (scheme.date)(os.time()))
check("date rejects garbage string", not (scheme.date)("not-a-date"))

-- fresh instance per access
local s1 = scheme.string
local s2 = scheme.string
s1:min(10)
check("scheme.string returns independent instances", s2("ab") == true, "s2 wrongly inherited s1's min(10)")

--=====================================================--
-- optional / required
--=====================================================--

check("required field rejects nil", not (scheme.string)(nil))
check("optional field accepts nil", (scheme.string:optional())(nil))
check("optional field still validates when present", not (scheme.string:optional():min(5))("ab"))

--=====================================================--
-- common constraints: empty / not_empty / is_in / not_in / equals / not_equals
--=====================================================--

check("empty() accepts empty string", (scheme.string:empty())(""))
check("empty() rejects non-empty string", not (scheme.string:empty())("x"))
check("not_empty() rejects empty string", not (scheme.string:not_empty())(""))
check("not_empty() accepts non-empty array", (scheme.array:not_empty())({ 1 }))
check("not_empty() rejects empty array", not (scheme.array:not_empty())({}))

check("is_in accepts listed value", (scheme.string:is_in("a", "b", "c"))("b"))
check("is_in rejects unlisted value", not (scheme.string:is_in("a", "b", "c"))("z"))
check("is_in accepts a table list form", (scheme.string:is_in({ "x", "y" }))("y"))
check("not_in rejects listed value", not (scheme.string:not_in("a", "b"))("a"))
check("not_in accepts unlisted value", (scheme.string:not_in("a", "b"))("z"))

check("equals accepts exact match", (scheme.number:equals(42))(42))
check("equals rejects mismatch", not (scheme.number:equals(42))(43))
check("not_equals rejects match", not (scheme.number:not_equals(42))(42))
check("equals deep-compares tables", (scheme.table:equals({ a = 1, b = { 2, 3 } }))({ a = 1, b = { 2, 3 } }))

--=====================================================--
-- number / int constraints
--=====================================================--

check("divisible_by accepts multiple", (scheme.int:divisible_by(5))(15))
check("divisible_by rejects non-multiple", not (scheme.int:divisible_by(5))(17))
check("positive accepts >0", (scheme.number:positive())(0.1))
check("positive rejects 0", not (scheme.number:positive())(0))
check("negative accepts <0", (scheme.number:negative())(-1))
check("min accepts equal boundary", (scheme.number:min(5))(5))
check("min rejects below", not (scheme.number:min(5))(4.9))
check("max accepts equal boundary", (scheme.number:max(5))(5))
check("max rejects above", not (scheme.number:max(5))(5.1))
check("range accepts inside", (scheme.number:range(1, 10))(5))
check("range rejects outside", not (scheme.number:range(1, 10))(11))

--=====================================================--
-- date constraints
--=====================================================--

local mid = scheme.date:range("2024-01-01", "2024-12-31")
check("date range accepts inside", mid("2024-06-15"))
check("date range rejects before", not mid("2023-12-31"))
check("date range rejects after", not mid("2025-01-01"))
check("date min accepts on/after bound", (scheme.date:min("2024-01-01"))("2024-01-01"))
check("date max rejects after bound", not (scheme.date:max("2024-01-01"))("2024-06-01"))

--=====================================================--
-- array constraints
--=====================================================--

check("array min accepts enough items", (scheme.array:min(2))({ 1, 2 }))
check("array min rejects too few", not (scheme.array:min(2))({ 1 }))
check("array max rejects too many", not (scheme.array:max(2))({ 1, 2, 3 }))
check("array range works", (scheme.array:range(1, 3))({ 1, 2 }))
check("array contains finds value", (scheme.array:contains("x"))({ "a", "x", "b" }))
check("array not_contains passes when absent", (scheme.array:not_contains("z"))({ "a", "b" }))
check("array not_contains fails when present", not (scheme.array:not_contains("a"))({ "a", "b" }))

-- of() union types
local mixedArraySchema = scheme.array:of(scheme.string, scheme.int)
check("array of(string,int) accepts strings and ints", mixedArraySchema({ "a", 1, "b", 2 }))
local ok, errs = mixedArraySchema({ "a", true, 2 })
check("array of(string,int) rejects invalid item", ok == false, errs)
check("array of(...) reports index of bad item", errs and errs[2] ~= nil, errs)

--=====================================================--
-- table constraints
--=====================================================--

check("table min accepts enough entries", (scheme.table:min(2))({ a = 1, b = 2 }))
check("table max rejects too many entries", not (scheme.table:max(1))({ a = 1, b = 2 }))
check("table contains finds value", (scheme.table:contains(5))({ x = 5 }))
local tblOf = scheme.table:of(scheme.number)
check("table of(number) accepts all-number values", tblOf({ a = 1, b = 2.5 }))
check("table of(number) rejects non-number value", not tblOf({ a = 1, b = "x" }))

--=====================================================--
-- string constraints (spot-check the whole surface)
--=====================================================--

check("alpha accepts letters", (scheme.string:alpha())("HelloWorld"))
check("alpha rejects digits", not (scheme.string:alpha())("Hello1"))
check("alphanumeric accepts letters+digits", (scheme.string:alphanumeric())("Hello123"))
check("alphanumeric rejects symbols", not (scheme.string:alphanumeric())("Hello-123"))
check("ascii accepts plain text", (scheme.string:ascii())("Hello!"))
check("ascii rejects non-ascii", not (scheme.string:ascii())("héllo"))
check("base32 accepts valid base32", (scheme.string:base32())("JBSWY3DP"))
check("base32 rejects invalid chars", not (scheme.string:base32())("jbswy3dp1"))
check("base64 accepts valid base64", (scheme.string:base64())("SGVsbG8="))
check("base64 rejects bad length", not (scheme.string:base64())("SGVsbG8"))
check("hexadecimal accepts hex", (scheme.string:hexadecimal())("deadBEEF"))
check("hexadecimal rejects non-hex", not (scheme.string:hexadecimal())("deadBEEFG"))
check("octal accepts octal digits", (scheme.string:octal())("01234567"))
check("octal rejects 8/9", not (scheme.string:octal())("012389"))
check("json accepts valid object", (scheme.string:json())('{"a":1,"b":[1,2,3],"c":null,"d":true}'))
check("json accepts valid array", (scheme.string:json())("[1,2,3]"))
check("json rejects invalid json", not (scheme.string:json())('{"a":}'))
check("json rejects trailing garbage", not (scheme.string:json())('{"a":1} extra'))
check("jwt accepts 3-segment token", (scheme.string:jwt())("aaa.bbb.ccc"))
check("jwt rejects 2-segment token", not (scheme.string:jwt())("aaa.bbb"))
check("lowercase accepts lower", (scheme.string:lowercase())("hello"))
check("lowercase rejects mixed", not (scheme.string:lowercase())("Hello"))
check("uppercase accepts upper", (scheme.string:uppercase())("HELLO"))
check("phone accepts formatted number", (scheme.string:phone())("+1 (555) 123-4567"))
check("phone rejects too short", not (scheme.string:phone())("123"))
check("url accepts https url", (scheme.string:url())("https://example.com/path?x=1"))
check("url rejects missing scheme", not (scheme.string:url())("example.com"))
check("sem_ver accepts plain version", (scheme.string:sem_ver())("1.2.3"))
check("sem_ver accepts prerelease+build", (scheme.string:sem_ver())("1.2.3-beta.1+build.5"))
check("sem_ver rejects malformed", not (scheme.string:sem_ver())("1.2"))
check("strong_password accepts strong pw", (scheme.string:strong_password())("Example123*"))
check("strong_password rejects weak pw", not (scheme.string:strong_password())("password"))
check("password alias works same as strong_password", (scheme.string:password())("Example123*"))
check("mac_address accepts colon form", (scheme.string:mac_address())("00:1A:2B:3C:4D:5E"))
check("mac_address accepts dash form", (scheme.string:mac_address())("00-1A-2B-3C-4D-5E"))
check("mac_address rejects malformed", not (scheme.string:mac_address())("00:1A:2B:3C:4D"))
check("ip_address accepts ipv4", (scheme.string:ip_address())("192.168.1.1"))
check("ip_address rejects bad ipv4 octet", not (scheme.string:ip_address("v4"))("999.1.1.1"))
check("ip_address accepts ipv6", (scheme.string:ip_address("v6"))("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
check("ip_address accepts compressed ipv6", (scheme.string:ip_address("v6"))("::1"))
check("port_number accepts valid port", (scheme.string:port_number())("8080"))
check("port_number rejects out of range", not (scheme.string:port_number())("70000"))
check("isbn accepts valid isbn10", (scheme.string:isbn())("0-306-40615-2"))
check("isbn accepts valid isbn13", (scheme.string:isbn())("978-3-16-148410-0"))
check("isbn rejects bad checksum", not (scheme.string:isbn())("0-306-40615-1"))
check("credit_card accepts valid luhn number", (scheme.string:credit_card())("4111111111111111"))
check("credit_card rejects invalid luhn number", not (scheme.string:credit_card())("4111111111111112"))
check("passport_number accepts plausible value", (scheme.string:passport_number())("A1234567"))
check("postal_code accepts plausible value", (scheme.string:postal_code())("90210"))
check("ethereum_address accepts well-formed address", (scheme.string:ethereum_address())(
  "0x" .. string.rep("a", 40)))
check("ethereum_address rejects wrong length", not (scheme.string:ethereum_address())("0x1234"))
check("btc_address accepts legacy-looking address", (scheme.string:btc_address())(
  "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"))
check("btc_address accepts bech32-looking address", (scheme.string:btc_address())(
  "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"))
check("email accepts standard address", (scheme.string:email())("a.b+c@sub.example.co.uk"))
check("email rejects missing tld", not (scheme.string:email())("a@b"))
check("email rejects double at", not (scheme.string:email())("a@@b.com"))
check("hex_color accepts 3-digit", (scheme.string:hex_color())("#fff"))
check("hex_color accepts 6-digit", (scheme.string:hex_color())("#ffcc00"))
check("hex_color rejects bad length", not (scheme.string:hex_color())("#ffcc0"))
check("hsl accepts valid value", (scheme.string:hsl())("hsl(210, 50%, 50%)"))
check("rgb accepts valid value", (scheme.string:rgb())("rgb(255, 0, 128)"))
check("rgb rejects out of range channel", not (scheme.string:rgb())("rgb(300, 0, 0)"))
check("boolean_string accepts true/false", (scheme.string:boolean_string())("true"))
check("date_string accepts iso date", (scheme.string:date_string())("2024-01-01"))
check("number_string accepts numeric text", (scheme.string:number_string())("42.5"))
check("string contains finds substring", (scheme.string:contains("ell"))("hello"))
check("string not_contains passes when absent", (scheme.string:not_contains("zzz"))("hello"))
check("string min/max/range on length", (scheme.string:range(2, 4))("abc") and not (scheme.string:range(2, 4))("a"))

--=====================================================--
-- object schemas (the example from the prompt)
--=====================================================--

local ContactDtoValidator = scheme {
  phone = scheme.string:phone(),
  email = scheme.string:email(),
}

local RegisterUserDtoValidator = scheme {
  username = scheme.string:min(3):alpha(),
  password = scheme.string:password(),
  contact = ContactDtoValidator:optional(),
}

local goodObj = { username = "hello", password = "Example123*" }
local isValid = RegisterUserDtoValidator(goodObj)
check("spec example: valid object passes", isValid == true)

local goodObjWithContact = {
  username = "hello",
  password = "Example123*",
  contact = { phone = "+15551234567", email = "a@b.com" },
}
check("spec example: valid nested contact passes", RegisterUserDtoValidator(goodObjWithContact))

local badObj = { username = "ab", password = "weak" }
local ok2, errors2 = RegisterUserDtoValidator(badObj)
check("spec example: invalid object fails", ok2 == false)
check("spec example: username error present", errors2.username ~= nil, errors2)
check("spec example: password error present", errors2.password ~= nil, errors2)

local badNestedObj = {
  username = "hello",
  password = "Example123*",
  contact = { phone = "bad", email = "not-an-email" },
}
local ok3, errors3 = RegisterUserDtoValidator(badNestedObj)
check("nested object errors reported under field name", ok3 == false and errors3.contact ~= nil, errors3)
check("nested object errors have per-field detail", errors3.contact and errors3.contact.phone ~= nil, errors3)

check("missing required object field fails", not RegisterUserDtoValidator({ username = "hello" }))

--=====================================================--
-- custom types and constraints
--=====================================================--

scheme:type("even_int", {
  extends = "int",
  check = function(v)
    if type(v) == "number" and v == math.floor(v) and v % 2 == 0 then return true end
    return false, "must be an even integer"
  end,
})
check("custom type accepts matching value", (scheme.even_int)(4))
check("custom type rejects non-matching value", not (scheme.even_int)(3))
check("custom type inherits base type's constraints", (scheme.even_int:min(2))(4) and not (scheme.even_int:min(6))(4))

scheme:constraint("string", "starts_with", function(value, prefix)
  return value:sub(1, #prefix) == prefix
end, "does not start with the required prefix")

check("custom string constraint accepts matching prefix", (scheme.string:starts_with("Mr. "))("Mr. Smith"))
check("custom string constraint rejects non-matching prefix", not (scheme.string:starts_with("Mr. "))("Smith"))

-- NOTE: unlike JS, "" and 0 are truthy in Lua, so this predicate checks
-- against a specific sentinel rather than relying on Lua truthiness.
scheme:constraint(nil, "not_sentinel", function(value) return value ~= 0 and value ~= "" end,
  "must not be the sentinel value")
check("custom 'any' constraint applies across types",
  (scheme.number:not_sentinel())(1) and not (scheme.number:not_sentinel())(0)
  and (scheme.string:not_sentinel())("a") and not (scheme.string:not_sentinel())(""))

--=====================================================--
-- assertions on bad input
--=====================================================--

local pok = pcall(function() return (scheme.number:min("nope")) end)
check("min() rejects non-number argument", pok == false)

local pok2 = pcall(function() scheme:type(123) end)
check("scheme:type rejects non-string name", pok2 == false)

local pok3 = pcall(function() scheme { username = "not-a-schema" } end)
check("scheme{...} rejects non-schema field values", pok3 == false)

--=====================================================--
-- describe() introspection
--=====================================================--

local d = RegisterUserDtoValidator:describe()
check("describe() reports object type", d.type == "object")
check("describe() reports shape fields", d.shape.username ~= nil and d.shape.password ~= nil)

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
