<!--
    NestLua -- NestJS-inspired framework for Lua.

    Copyright (C) 2026 Предраг Јовановић
    SPDX-FileCopyrightText: 2026 Предраг Јовановић
    SPDX-License-Identifier: Apache-2.0

    Look at the LICENSE file for more information.
-->

# NestLua

A NestJS-inspired routing/composition framework for Lua. NestLua does **not**
open sockets or speak HTTP itself — it expects a separate adapter layer to
turn real network traffic into a plain `request` table, call
`module:handle(request)`, and turn the returned `response` table back into
bytes on the wire. This keeps NestLua portable across any Lua HTTP stack
(OpenResty/nginx, love2d sockets, luasocket, a custom C binding, etc).

```lua
local nest = require "nestlua.core"
```

## Request / response shape

```lua
-- request (built by your adapter, read by NestLua)
{
  method  = "GET",
  url     = "/users/42?sort=asc",
  version = "HTTP/1.1",
  headers = { ["Content-Type"] = "text/plain" },
  body    = "...",              -- whatever your adapter decoded (string/table/etc)
}

-- response (built by NestLua, read by your adapter)
{
  code    = 200,
  headers = { ["Content-Type"] = "application/json" },
  body    = { ... },
}
```

## Building an API

```lua
local nest = require "nestlua.core"

local module     = nest.module("api")
local controller = module:controller("Users")

controller:use_prefix("/users")

controller:route("GetUsers")
  :get("/")
  :guard(AuthGuard)
  :intercept(LoggingInterceptor)
  :use_query("sort", sortValidator)
  :use_query("pageIndex")
  :use_query("pageLimit")
  :handle(function(sort, pageIndex, pageLimit)
    return { sort = sort, pageIndex = pageIndex, pageLimit = pageLimit }
  end)

local app = module:build()      -- compiles/validates the route tree
local res = module:handle(req)  -- dispatch a single request (auto-builds if needed)
```

## Core API

### Module

| Call | Description |
|---|---|
| `nest.module(name)` | Creates a new `Module`. |
| `module:controller(name)` | Creates and registers a top-level `Controller`. |
| `module:decorator(name, fn)` | Registers `fn` so it becomes callable as `controller:name(...)` / `route:name(...)` for controllers/routes belonging to this module. |
| `module:guard(...)` | Adds one or more guard functions, applied to every route in the module. |
| `module:intercept(...)` | Adds one or more interceptors, applied to every route in the module. |
| `module:build()` | Compiles path patterns, validates that every route was finished with `:handle()`, and returns an opaque `app` handle (useful for adapters that want a single object to hold on to). Idempotent; safe to call again after adding more routes. |
| `module:handle(req)` | Dispatches a single request table, returns a response table. Calls `build()` automatically the first time if you haven't. |
| `module:describe()` | Returns a plain-table description of the whole module tree (name, prefixes, route methods/paths, param descriptors, guard/interceptor counts) — meant for logging or a future Swagger generator. |

### Controller

| Call | Description |
|---|---|
| `controller:route(name)` | Returns a new `RouteBuilder` registered on this controller. |
| `controller:controller(name)` | Creates a **sub-controller** that inherits the parent's prefix, guards and interceptors (concatenated/appended). |
| `controller:use_prefix(prefix)` | Sets this controller's path-prefix segment (combined with ancestors' prefixes and each route's own path). |
| `controller:guard(...)` | Adds guards applied to every route under this controller (and its sub-controllers). |
| `controller:intercept(...)` | Adds interceptors applied to every route under this controller (and its sub-controllers). |
| `controller:describe()` | Introspection, see above. |
| `controller:<custom decorator>(...)` | Any decorator registered via `module:decorator` on the owning module. |

### RouteBuilder

| Call | Description |
|---|---|
| `route:get/post/put/patch/delete(path)` | Registers an HTTP method + Nest-like path (`:param`, `*` wildcard) mapped to this route. You can call several of these on the same route to reuse one handler for multiple method/path pairs. |
| `route:guard(...)` | Adds guards that run only for this route (after module- and controller-level guards). |
| `route:intercept(...)` | Adds interceptors that wrap only this route's handler (innermost, after module/controller interceptors). |
| `route:use_request()` | Adds the raw request table as the next handler argument. |
| `route:use_response()` | Adds the mutable response table as the next handler argument (mutate `res.code`, `res.headers`, `res.body` directly). |
| `route:use_param(name, pipe)` | Adds a `:name` path param as the next handler argument, run through `pipe` if given. |
| `route:use_query(name, pipe)` | Adds a query-string value as the next argument. If `name` is `nil`, the whole query table is passed instead. |
| `route:use_header(name, pipe)` | Adds an HTTP header value (case-insensitive lookup) as the next argument. |
| `route:use_body(name, pipe)` | Adds a field of the request body (or the whole body if `name` is `nil`) as the next argument. |
| `route:use_custom(selector)` | Adds `selector(ctx)`'s return value as the next argument — an escape hatch for anything not covered above. |
| `route:handle(func)` | Sets the handler and completes the route builder. `func` receives exactly the arguments requested by the `use_*` calls above, **in the order they were called**. Returns the route builder. |
| `route:describe()` | Introspection, see above. |
| `route:<custom decorator>(...)` | Any decorator registered via `module:decorator` on the owning module. |

Argument order matters: whichever `use_*` you call first becomes the
handler's first parameter, and so on.

## HTTP exceptions

Call one of these on the required module itself (not on `ctx` — the module
returned by `require "nestlua.core"`) from inside a guard, interceptor,
pipe, or handler to abort the request with that status code:

```lua
local nest = require "nestlua.core"

controller:route("Example")
  :get("/example")
  :handle(function(body, res)
    nest:not_implemented_error()
  end)
```

This raises a Lua error carrying the exception; `module:handle()` catches
it centrally (see "Exception filters" below) and turns it into the
matching HTTP response — here, `{ code = 501, body = "Not Implemented" }`.

| Method | Status |
|---|---|
| `nest:bad_request_error(message)` | 400 |
| `nest:unauthorized_error(message)` | 401 |
| `nest:forbidden_error(message)` | 403 |
| `nest:not_found_error(message)` | 404 |
| `nest:method_not_allowed_error(message)` | 405 |
| `nest:not_acceptable_error(message)` | 406 |
| `nest:request_timeout_error(message)` | 408 |
| `nest:conflict_error(message)` | 409 |
| `nest:gone_error(message)` | 410 |
| `nest:precondition_failed_error(message)` | 412 |
| `nest:payload_too_large_error(message)` | 413 |
| `nest:unsupported_media_type_error(message)` | 415 |
| `nest:im_a_teapot_error(message)` | 418 |
| `nest:unprocessable_entity_error(message)` | 422 |
| `nest:internal_server_error(message)` | 500 |
| `nest:not_implemented_error(message)` | 501 |
| `nest:bad_gateway_error(message)` | 502 |
| `nest:service_unavailable_error(message)` | 503 |
| `nest:gateway_timeout_error(message)` | 504 |
| `nest:http_version_not_supported_error(message)` | 505 |
| `nest:http_error(code, message)` | any code — the escape hatch, for statuses not covered above |

This mirrors Nest's full built-in `HttpException` subclass list (from
`@nestjs/common`). `message` is optional (each falls back to the standard
status text, e.g. `"Not Implemented"`), can be a plain string, or can be a
table for a structured error body:

```lua
nest:unprocessable_entity_error({ message = "Validation failed", errors = { "username too short" } })
-- -> response.body is that table, not a string
```

For advanced cases you can build (without throwing) an exception object
with `nest.http_exception(code, message)` and check for one with
`nest.is_http_exception(x)` — useful inside a filter that wants to
re-throw a different exception, or construct one to return directly.

Guards and interceptors can throw these too, not just handlers — a guard
that calls `nest:forbidden_error("no token")` behaves the same as one that
`return`s `false, "no token"` (both produce a 403), except throwing lets
you attach it to any HTTP status, not just 403.

## Exception filters

Exception filters are registered exactly like guards and interceptors, at
module, controller, or route scope:

```lua
module:filter(func)
controller:filter(func)
route:filter(func)
```

A filter is `function(exception, ctx) -> response table | nil`. `exception`
is always an HttpException-shaped value — `{ code, body }`, plus `.cause`
holding the original error when it wasn't raised via `nest:xxx_error()`
(e.g. a genuine Lua bug gets normalized to a 500 with `.cause` set to the
original error). Return a response table (`code`/`headers`/`body`, any
field optional — omitted ones default from the exception) to handle it;
return `nil` (or let the filter throw) to defer to the next, less specific
filter, or to the built-in default response if none handle it.

```lua
module:filter(function(exception, ctx)
  if exception.code == 404 then
    return { code = 404, body = { error = "not_found", path = ctx.req.url } }
  end
  -- return nothing: let something else (a more general filter, or the
  -- built-in default) handle anything that isn't a 404
end)
```

Filters are tried **most specific first**: route filters, then controller
filters (leaf controller up through its ancestors), then module filters —
the first one to return a response table wins. This mirrors Nest's filter
scoping, where a method-level `@UseFilters()` takes priority over a
controller- or app-level one. If every filter defers (or none are
registered), the exception's own `code`/`body` become the response as-is.

If a pipe already wrote a structured body onto `ctx.res` before signalling
failure (see the pipes section above), that survives even through the
default (no-filter) path — filters and the default handler both build on
top of `ctx.res` rather than replacing it outright.

`nest.compose_filters(...)` folds several filters into one callback (tries
each in registered order, returns the first non-nil response) for the same
reason `compose_guards`/`compose_interceptors` exist.

## Guards

A guard is `function(ctx) -> allowed[, reason]`. Guards run in this order
for a request: module guards → controller guards (root to leaf, including
sub-controllers) → route guards. The **first** guard to return a falsy
value stops the chain and produces an HTTP `403` response (using `reason`
as the body if provided). A guard can also throw one of the HTTP
exceptions described below (e.g. `nest:forbidden_error(...)`, or any other
status) for the same effect with more control over the status code; an
unrelated Lua bug in a guard is caught and normalized to a `500` rather
than crashing the request pipeline. Either way, exception filters (see
below) get a chance to handle it before the default response goes out.

```lua
local function AuthGuard(ctx)
  if ctx.req.headers["Authorization"] == "secret" then return true end
  return false, "Unauthorized"
end
```

You can fold several guards into one with `nest.compose_guards(...)` if
that's cleaner or cheaper than registering them individually.

## Interceptors

An interceptor is `function(ctx, next) -> response`, where `next()` invokes
the rest of the chain (further interceptors, then the handler) and returns
its response. Interceptors compose module → controller → route, outermost
first — mirroring Nest's execution model, so you can time, log, or
transform the response around the actual handler call.

```lua
local function LoggingInterceptor(ctx, next)
  local res = next()
  print(ctx.req.method, ctx.req.url, res.code)
  return res
end
```

`nest.compose_interceptors(...)` folds several interceptors into a single
callback for the same reason as `compose_guards`.

## Pipes

A pipe is `function(value, ctx) -> value2 | true | false`, passed to any
`use_param` / `use_query` / `use_header` / `use_body` call:

- returns `false` (or throws) → the request is rejected with `400`
- returns `true` or `nil` → the original value is kept unchanged
- returns anything else → that becomes the argument's value (i.e. it also
  works as a transform, not just a validator)

```lua
local function sortValidator(value)
  return value == nil or value == "ascending" or value == "descending"
end

local function toNumber(value)
  return tonumber(value) -- transforms the string param into a number
end
```

## Custom decorators

`module:decorator(name, fn)` lets you package up common combinations of
`use_*`/`guard`/`intercept` calls behind a single fluent method available on
**both** controllers and routes belonging to that module:

```lua
module:decorator("use_paging", function(route)
  return route
    :use_query("pageIndex")
    :use_query("pageLimit")
end)

controller:route("GetUsers")
  :get("/users")
  :use_paging()          -- expands to the two use_query calls above
  :handle(function(pageIndex, pageLimit) ... end)
```

`fn` receives whatever it's called on (`route` or `controller`) as its
first argument, followed by any extra arguments passed at the call site,
and should generally return that same object so the fluent chain keeps
working.

## Context table

Guards, interceptors and `use_custom` selectors all receive a `ctx` table:

```lua
{
  req        = <request table>,
  res        = <mutable response table>,
  params     = { id = "42" },      -- resolved :param values for this match
  query      = { sort = "asc" },   -- parsed query string
  module     = <Module>,
  controller = <Controller>,       -- the controller that owns the matched route
  route      = <RouteBuilder>,     -- the matched route
}
```

## Paths

Paths follow Nest conventions:

- literal segments match exactly (`/users`)
- `:name` captures a single path segment into `ctx.params.name`
- `*` as a whole segment greedily matches everything remaining and is
  available as `ctx.params["*"]`

Prefixes compose from `module` → root controller → nested controllers →
the route's own path, normalizing duplicate/missing slashes.

Routes are tried in the order they were registered (depth-first through
sub-controllers), and the first method+path match wins — so register more
specific literal paths (e.g. `/users/me`) before more general parameterized
ones (e.g. `/users/:id`) if they could otherwise collide.

## Introspection

`module:describe()` / `controller:describe()` / `route:describe()` return
plain nested Lua tables (names, prefixes, HTTP method+path pairs, ordered
argument descriptors, guard/interceptor counts) with no functions inside,
so they're trivial to `json.encode` for logging or to drive a future
Swagger/OpenAPI generator.

## Type guards

`nest.is_module(x)`, `nest.is_controller(x)`, `nest.is_route(x)`,
`nest.is_app(x)` — useful inside decorator functions to assert what they
were called on, exactly as shown in the design spec.

## Files

- `src/core.lua` — the framework, single file, no external dependencies.
- `src/scheme.lua` — the validator library described below.
- `test/test_core.lua` / `test/test_exceptions.lua` / `test/test_scheme.lua` — self-contained
  test suites. Run with `lua test-core.lua`, `lua test_exceptions.lua`, and
  `lua test_scheme.lua`.

---

# Scheme — a class-validator-style validator

```lua
local scheme = require "nestlua.scheme"
```

`scheme` builds reusable, chainable value/object validators, the same
shape as class-validator's decorators but expressed as a fluent Lua API
instead of annotations. A schema is just a callable value:

```lua
local ContactDtoValidator = scheme {
  phone = scheme.string:phone(),
  email = scheme.string:email(),
}

local RegisterUserDtoValidator = scheme {
  username = scheme.string:min(3):alpha(),
  password = scheme.string:password(),
  contact  = ContactDtoValidator:optional(),
}

local isValid = RegisterUserDtoValidator({ username = "hello", password = "Example123*" })
-- isValid == true

local ok, errors = RegisterUserDtoValidator({ username = "ab", password = "weak" })
-- ok == false
-- errors == { username = {"must be at least 3 characters long"},
--             password = {"must be at least 8 characters and include an ..."} }
```

Every schema returns `(ok, errors)` when called. `ok` is a plain boolean,
so `local isValid = Validator(obj)` (capturing only the first return value)
works exactly as in the design sample. `errors` is a plain nested Lua
table with no functions in it — safe to log or `json.encode`:

- a leaf schema (string/number/int/boolean/date) that fails returns an
  **array of message strings**.
- an object schema that fails returns a **map of `field -> errors`**,
  recursively (nested objects nest naturally); a failed constraint on the
  object itself (e.g. `:not_empty()`) is reported under the `_self` key.
- an array/table schema with `:of(...)` returns a **map of
  `index/key -> errors`** for whichever items didn't match, plus `_self`
  for any array/table-level constraint failures (min/max/contains/etc).

## Scheme types

| Type | Accepts |
|---|---|
| `scheme.string` | Lua strings |
| `scheme.number` | any Lua number (int or float) |
| `scheme.int` | a number with no fractional part |
| `scheme.boolean` | `true` / `false` |
| `scheme.array` | a table that's a proper 1..n sequence with no holes |
| `scheme.table` | any table (a general map/dictionary) |
| `scheme.date` | a Lua date table `{year=,month=,day=,...}`, a unix timestamp number, or an ISO `"YYYY-MM-DD"` / `"YYYY-MM-DDTHH:MM:SS"` string |
| `scheme { ... }` | calling `scheme` itself with a table of `field = schema` builds an **object** schema |

## Common constraints (all types)

`:optional()` `:empty()` `:not_empty()` `:is_in(values...)` `:not_in(values...)` `:equals(other)` `:not_equals(other)`

`is_in`/`not_in` accept either varargs (`:is_in("a","b","c")`) or a single
table of values (`:is_in({"a","b","c"})`). `equals`/`not_equals` deep-compare
tables field by field.

## Number / int constraints

`:divisible_by(num)` `:positive()` `:negative()` `:min(num)` `:max(num)` `:range(min, max)`

## Date constraints

`:min(date)` `:max(date)` `:range(min, max)` — bounds accept the same
date-ish values described above (string/table/timestamp).

## Array / table constraints

`:of(...)` (one or more schemas — an item is valid if it matches **any**
one of them) `:min(n)` `:max(n)` `:range(min, max)` (item/entry count)
`:contains(value)` `:not_contains(value)` `:not_empty()` (from the common set)

`array` requires a proper sequence (`{1,2,3}`); `table` accepts any table,
including maps (`{a=1,b=2}`), and iterates values via `pairs` for `:of()`
and `:contains()`.

## String constraints

`:boolean_string()` `:date_string()` `:number_string()` `:contains(seed)`
`:not_contains(seed)` `:alpha()` `:alphanumeric()` `:ascii()` `:base32()`
`:base64()` `:hexadecimal()` `:octal()` `:json()` `:jwt()` `:lowercase()`
`:uppercase()` `:phone()` `:url()` `:min(n)` `:max(n)` `:range(min, max)`
(string length) `:sem_ver()` `:strong_password()` / `:password()`
`:mac_address()` `:ip_address(version)` (`version` is `"v4"`, `"v6"`, or
omitted for either) `:port_number()` `:isbn()` `:credit_card()`
`:passport_number()` `:postal_code()` `:ethereum_address()`
`:btc_address()` `:email()` `:hex_color()` `:hsl()` `:rgb()`

## Custom types and constraints

```lua
-- new type, inheriting int's constraints (min/max/... still work on it)
scheme:type("even_int", {
  extends = "int",
  check = function(v)
    if v % 2 == 0 then return true end
    return false, "must be an even integer"
  end,
})
scheme.even_int:min(2) -- usable immediately, chains like any built-in type

-- new constraint on an existing type
scheme:constraint("string", "starts_with", function(value, prefix)
  return value:sub(1, #prefix) == prefix
end, "does not start with the required prefix")
scheme.string:starts_with("Mr. ")

-- pass nil (or "any") as the type to register a constraint usable on every type
scheme:constraint(nil, "not_sentinel", function(value) return value ~= 0 end)
```

`scheme:type(name, opts)`:
- `opts.check(value) -> ok[, message]` — the type's core type-check (required
  unless `opts.extends` is given and the base type already has one).
- `opts.extends` — an existing type name whose constraint methods (and, if
  `opts.check` is omitted, type-check) the new type inherits.

`scheme:constraint(type_name, constraint_name, fn, default_message)`:
- `fn(value, ...) -> ok[, message]` — `...` are whatever extra arguments the
  caller passes at the call site, e.g. `prefix` in `starts_with` above.
- `type_name` is a built-in or custom type name, or `nil`/`"any"` to add the
  constraint to every type (including future custom ones that don't
  `extends` anything, since they all fall back to the shared base methods).

## Pipes and introspection

Every schema is directly usable as a NestLua route pipe (`route:use_body(nil,
mySchema)` etc.) since pipes are just `function(value, ctx) -> ok|value|false`
and a schema, called with one argument, returns exactly that. See
`example_pipe_integration.lua` for a full example wiring a `scheme` object
schema into `use_body()` with structured validation errors surfacing in the
HTTP response body.

`schema:describe()` returns a plain-table introspection dump (type,
whether it's optional, the ordered list of rule names, and recursively for
nested `shape`/`item_schemas`) for the same future logging/Swagger use case
as `nest`'s `describe()` methods.

## What's a heuristic, not a full spec implementation

A few constraints can't be fully implemented in pure Lua without extra
dependencies, or don't have one universal standard to validate against.
These are implemented as reasonable format-level checks, not omitted
outright, but are worth knowing about:

- **`phone()`** — a generic "starts with optional `+`, 7–15 digits after
  stripping spaces/dashes/parens" check, not full E.164/libphonenumber
  validation (that needs a real phone-number metadata database).
- **`passport_number()` / `postal_code()`** — generic shape checks (alnum,
  plausible length). Real formats vary per issuing country; there's no
  single standard, and country-aware validation would need a large rule
  table or an external library.
- **`ethereum_address()`** — checks `0x` + 40 hex characters only. Real
  EIP-55 checksum validation needs a Keccak-256 hash, which isn't in the
  Lua standard library.
- **`btc_address()`** — checks the legacy/bech32 address *shape* only.
  Real base58check validation needs a double SHA-256 hash, also not in the
  stdlib.
- **`jwt()`** — checks that the token has three well-formed base64url
  segments. It intentionally does not (and cannot, without knowing the
  signing algorithm/secret) verify the signature.
- **`json()`** — this one *is* fully implemented: a small hand-written
  recursive-descent parser validates JSON syntax without needing an
  external JSON library.

Everything else in the requested constraint list (all the common/number/
date/array/table constraints, and the rest of the string constraints
including `email`, `url`, `credit_card` via Luhn, `isbn` via its real
checksum, `ip_address` v4/v6, `mac_address`, `sem_ver`, `hex_color`,
`hsl`, `rgb`, etc.) is fully implemented with no external dependencies.
