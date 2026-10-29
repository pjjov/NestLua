<!--
    NestLua -- NestJS-inspired framework for Lua.

    Copyright (C) 2026 Предраг Јовановић
    SPDX-FileCopyrightText: 2026 Предраг Јовановић
    SPDX-License-Identifier: Apache-2.0

    Look at the LICENSE file for more information.
-->

# NestLua

A NestJS-inspired framework for Lua: modules with dependency injection,
controllers, routes, middleware, guards, interceptors, pipes, exception
filters, a class-validator-style validator and OpenAPI generation.

The core does **not** open sockets or speak HTTP itself. An adapter turns
network traffic into a plain `request` table, calls `module:handle(request)`
and turns the returned `response` table back into bytes on the wire. One
ships with NestLua ([libmicrohttpd via lua-mhd](#http-server-lua-mhd)), and
writing one for another stack (OpenResty, lua-http, luasocket, ...) is a few
lines.

Runs on Lua 5.1–5.5 and LuaJIT, with no dependencies.

```lua
local nest = require "nestlua"
```

| Module | Purpose |
|---|---|
| `nestlua` | modules, DI, routing, middleware, guards, interceptors, pipes, exceptions |
| `nestlua.scheme` | validation / DTO schemas |
| `nestlua.middleware` | body parser (JSON, urlencoded, multipart), CORS, request ids, access log |
| `nestlua.openapi` | OpenAPI 3.1 document generation |
| `nestlua.json` | JSON encoder / decoder |
| `nestlua.mhd` | HTTP server adapter for [lua-mhd](https://github.com/pjjov/lua-mhd) |

## Quick start

```lua
-- app.lua
local nest = require "nestlua"
local scheme = require "nestlua.scheme"
local pipes = nest.pipes

local CreateUserDto = scheme {
  username = scheme.string:trim():range(3, 32):alphanumeric(),
  email    = scheme.string:email(),
}:strip()

local users = nest.module("users")
users:provide("users_repository", function() return require("my.repo").new() end)

local controller = users:controller("Users"):use_prefix("/users")

controller:route("GetUser")
  :get("/:id(%d+)")
  :use_param("id", pipes.int)
  :use_inject("users_repository")
  :handle(function(id, repo)
    return repo:find(id) or nest:not_found_error()
  end)

controller:route("CreateUser")
  :post("/")
  :status(201)
  :use_body(nil, CreateUserDto)     -- a schema is a pipe
  :use_inject("users_repository")
  :handle(function(dto, repo) return repo:create(dto) end)

local app = nest.module("app"):use_prefix("/api"):import(users)
return app
```

```lua
-- server.lua
local srv = require("nestlua.mhd").listen({ port = 8080 }, "app")
io.read("l")
srv:stop()
```

A complete example lives in [`examples/`](examples/) (`lua examples/server.lua`).

## Request / response shape

```lua
-- request (built by the adapter, read by NestLua)
{
  method  = "GET",
  url     = "/users/42?sort=asc",
  version = "HTTP/1.1",
  headers = { ["Content-Type"] = "text/plain" },
  query   = { sort = "asc" },   -- optional: used if the adapter already parsed it
  body    = "...",              -- string, or whatever the adapter decoded
}

-- response (built by NestLua, read by the adapter)
{
  code    = 200,
  headers = { ["Content-Type"] = "application/json" },
  body    = { ... },
  file    = "/path",            -- optional, see nest.file()
  stream  = function() ... end, -- optional, see nest.stream()
}
```

## Modules

| Call | Description |
|---|---|
| `nest.module(name)` | Creates a `Module`. |
| `module:controller(name)` | Creates a top-level `Controller`. |
| `module:use_prefix(prefix)` | Global path prefix for every route in the module (e.g. `"/api"`). |
| `module:versioning(prefix)` | Prefix in front of version numbers (default `"v"` → `/v1/...`). |
| `module:import(other, ...)` | Serves the other module's routes here and makes its exported providers injectable. The imported module's prefix, guards, interceptors, filters and middleware still apply to its own routes, nested inside this module's. |
| `module:provide(name, factory)` | Registers a provider. `factory(module)` runs lazily, once (a singleton per module); it can resolve dependencies with `module:get(...)`. |
| `module:provide_value(name, value)` | Registers an existing value as a provider. |
| `module:export(name_or_module, ...)` | Makes providers, or a whole imported module's exports, visible to importers. |
| `module:get(name)` | Resolves a provider visible from this module (own, or exported by an import). Circular dependencies raise an error. |
| `module:use(fn, ...)` / `module:use_first(fn, ...)` | Registers [middleware](#middleware) (appended / prepended). |
| `module:guard(...)` / `module:intercept(...)` / `module:filter(...)` | Guards, interceptors and exception filters for every route in the module. |
| `module:meta(key, value)` | Default [metadata](#metadata) for every route. |
| `module:decorator(name, fn)` | Registers `fn` as `controller:name(...)` / `route:name(...)` (see [custom decorators](#custom-decorators)). |
| `module:on_init(fn)` / `module:on_shutdown(fn)` | Lifecycle hooks. Init runs once at the first build (imported modules first); shutdown runs on `module:shutdown()` (importer first). |
| `module:shutdown()` | Runs shutdown hooks, and `on_shutdown` on provider instances that define it. |
| `module:logger(fn \| false)` | `fn(level, message, err, traceback, ctx)`. Defaults to stderr; `false` silences it. |
| `module:expose_errors(true)` | Includes Lua error messages in 500 bodies. **Development only.** |
| `module:build()` | Compiles the route table. Optional: `handle()` rebuilds automatically whenever routes, guards etc. changed since the last build. Returns an `app` handle. |
| `module:handle(req)` | Dispatches one request table, returns a response table. |
| `module:routes()` | Every endpoint in match order (full path, method, route description). |
| `module:describe()` | Plain-table description of the module tree. |

Provider instances that define `on_init(self, module)` or `on_shutdown(self, module)` methods get them called on creation and on `module:shutdown()`.

## Controllers

| Call | Description |
|---|---|
| `controller:route(name)` | Returns a new `RouteBuilder`. |
| `controller:controller(name)` | Sub-controller inheriting prefix, guards, interceptors, filters, metadata and version. |
| `controller:use_prefix(prefix)` | This controller's path-prefix segment. |
| `controller:version(v, ...)` | Serves its routes under `/v<v>` (several versions allowed; inherited; overridable per route). |
| `controller:guard(...)` / `:intercept(...)` / `:filter(...)` / `:meta(k, v)` | As on modules, scoped to this controller and its children. |

## Routes

| Call | Description |
|---|---|
| `route:get/post/put/patch/delete/head/options(path)` | Registers a method + path (see [paths](#paths)). Call several to reuse one handler. |
| `route:all(path)` | Matches every method (a per-method route on the same path still wins). |
| `route:status(code)` | Status code for successful responses (Nest's `@HttpCode`). |
| `route:header(name, value)` | Response header (Nest's `@Header`). |
| `route:version(v, ...)` | Overrides the controller's version. |
| `route:meta(key, value)` | Route [metadata](#metadata). |
| `route:doc{...}` | [OpenAPI](#openapi) documentation. |
| `route:guard(...)` / `:intercept(...)` / `:filter(...)` | Innermost guards / interceptors / filters. |
| `route:use_param(name, pipes...)` | `:name` path param. |
| `route:use_query(name, pipes...)` | Query value. For a repeated key, the **last** value. `name == nil` gives the whole query table. |
| `route:use_query_array(name, pipes...)` | Every value of a query key, always as an array. |
| `route:use_header(name, pipes...)` | Header value (case-insensitive). |
| `route:use_body(name, pipes...)` | A body field, or the whole body if `name` is `nil`. |
| `route:use_file(name, pipes...)` | An uploaded file (from the multipart body parser). |
| `route:use_inject(name)` | A provider instance. |
| `route:use_request()` / `route:use_response()` | The raw request / the mutable response table. |
| `route:use_custom(selector, pipes...)` | `selector(ctx)`'s return value. |
| `route:handle(func)` | Sets the handler. It receives the `use_*` arguments **in the order they were declared**. |

A handler's return value becomes the response body. To set everything at once, return `nest.response{ code =, headers =, body = }`. For downloads and streams, see `nest.file(path, opts)` and `nest.stream(producer, opts)`:

```lua
route:get("/report"):handle(function()
  return nest.file("/srv/report.pdf", { content_type = "application/pdf", filename = "report.pdf" })
end)
```

## Paths

| Syntax | Matches |
|---|---|
| `/users` | literal segment |
| `/:id` | one segment, captured into `ctx.params.id` (percent-decoded) |
| `/:id(%d+)` | one segment matching the anchored **Lua pattern** |
| `/:tab?` | optional segment (only trailing segments may be optional) |
| `/*` or `/*path` | the rest of the path (must be last), in `ctx.params["*"]` and `ctx.params.path` |

Prefixes compose as module → imported modules → version → controllers → route.

**Routes are ranked by specificity, not registration order**: literal > constrained param > param > optional param > wildcard. So `/users/me` always beats `/users/:id`. Two routes with the same method and the same path shape (e.g. `/x/:id` and `/x/:name`) are reported as a duplicate at build time.

Automatic HTTP behaviour:

- the path matches but the method doesn't → **405** with an `Allow` header
- `HEAD` falls back to the `GET` route (and the body is dropped)
- `OPTIONS` without an explicit route → **204** with `Allow`
- no match → **404**

404 and 405 responses go through the module's middleware and exception filters, so a global error format applies to them too.

## Request lifecycle

```
root-module middleware  →  routing  →  imported-module middleware  →  guards
  →  interceptors (module → controller → route)  →  pipes  →  handler
exceptions anywhere  →  filters (route → controllers → modules)  →  default response
```

### Middleware

`function(ctx, next) -> response`. Middleware on the module whose `handle()` is called runs **before routing** for every request, 404s included. It can modify `ctx.req`, short-circuit by returning its own response, or post-process what `next()` returns. Middleware on an imported module runs only for that module's routes, after routing.

```lua
local middleware = require "nestlua.middleware"

app:use(
  middleware.request_id(),                         -- ctx.request_id + X-Request-Id
  middleware.cors({ origin = { "https://app.example" }, credentials = true }),
  middleware.body_parser({ limit = 1024 * 1024 }), -- JSON / urlencoded / multipart
  middleware.logger()                              -- "GET /users 200 1.2ms"
)
```

`body_parser` decodes `application/json` (and `+json`), `application/x-www-form-urlencoded` and `multipart/form-data` string bodies. Uploaded files end up in `req.files[name] = { filename, content_type, data, size, headers }`, readable with `route:use_file(name)`. Malformed bodies get a 400, and bodies over `limit` a 413.

`cors` options: `origin` (`"*"`, a string, a list or `function(origin)`), `methods`, `headers`, `expose`, `credentials`, `max_age`.

### Guards

`function(ctx) -> allowed[, reason]`. The first falsy result stops the request with **403** (`reason` as the body). A guard can also throw any HTTP exception.

### Interceptors

`function(ctx, next) -> response`. `next()` runs the rest of the chain. Composition is module → controller → route, outermost first.

### Metadata

`module/controller/route:meta(key, value)` attach metadata; `ctx:meta(key)` reads it with route > controller (leaf first) > module precedence. It's Nest's `SetMetadata` + `Reflector`:

```lua
local function RolesGuard(ctx)
  local roles = ctx:meta("roles")
  return not roles or roles[ctx.user.role], "forbidden"
end

controller:guard(RolesGuard)
controller:route("Delete"):delete("/:id"):meta("roles", { admin = true }):handle(...)
```

### Pipes

A pipe is any of:

- a `function(value, ctx) -> result[, detail]`:
  - `false` → 400. A table `detail` becomes the structured `errors` of the body; a string `detail` is appended to the message.
  - `nil` / `true` → the value is unchanged
  - anything else → the new value
- a table with `:parse(value, ctx) -> ok, value_or_errors`. Scheme schemas and `nest.pipes.*` are this kind, and it can produce `false`/`nil` as values.

Several pipes per argument run left to right. HTTP exceptions thrown by a pipe keep their status. Other errors become a 400 without leaking the error text.

A validation failure from a schema produces:

```json
{ "message": "Validation failed", "source": "body", "errors": { "email": ["must be a valid email address"] } }
```

Built-in pipes (`nest.pipes`):

| Pipe | Effect |
|---|---|
| `int` / `number` (`float`) / `bool` | Parse strings strictly (`"0x10"`, `"1e3"` for `int`, `"yes"` are rejected). |
| `uuid` / `uuid(version)` | Validate a UUID. |
| `enum(values...)` | Only the listed values. |
| `default(v)` | Replace a missing value (a function is called for a fresh value). |
| `optional(pipe)` | Let a missing value through as `nil`, otherwise apply `pipe`. |
| `trim` | Trim whitespace. |
| `array(item_pipe?, sep?)` | `"a,b"` → `{ "a", "b" }`, items piped. |
| `chain(pipes...)` | Several pipes as one. |
| `nest.pipe(fn, describe?)` | Build your own from `fn(value, ctx) -> ok, value_or_error`. |

```lua
route:get("/users"):use_query("limit", pipes.default("20"), pipes.int)
```

### Context

Middleware, guards, interceptors, filters and `use_custom` receive `ctx`:

```lua
{
  req, res,            -- request / mutable response
  method, path,        -- normalized method and path
  params, query,       -- path params, parsed query
  root,                -- the module handle() was called on
  module, controller,  -- owning module / controller of the matched route
  route,
  -- methods:
  ctx:inject(name),    -- resolve a provider
  ctx:meta(key),       -- read metadata
}
```

## HTTP exceptions

Call one on the required module (`nest:not_found_error()`) from any stage to abort the request with that status:

| Method | Status |
|---|---|
| `bad_request_error` | 400 |
| `unauthorized_error` | 401 |
| `payment_required_error` | 402 |
| `forbidden_error` | 403 |
| `not_found_error` | 404 |
| `method_not_allowed_error` | 405 |
| `not_acceptable_error` | 406 |
| `request_timeout_error` | 408 |
| `conflict_error` | 409 |
| `gone_error` | 410 |
| `length_required_error` | 411 |
| `precondition_failed_error` | 412 |
| `payload_too_large_error` | 413 |
| `uri_too_long_error` | 414 |
| `unsupported_media_type_error` | 415 |
| `range_not_satisfiable_error` | 416 |
| `expectation_failed_error` | 417 |
| `im_a_teapot_error` | 418 |
| `misdirected_error` | 421 |
| `unprocessable_entity_error` | 422 |
| `locked_error` | 423 |
| `precondition_required_error` | 428 |
| `too_many_requests_error` | 429 |
| `unavailable_for_legal_reasons_error` | 451 |
| `internal_server_error` | 500 |
| `not_implemented_error` | 501 |
| `bad_gateway_error` | 502 |
| `service_unavailable_error` | 503 |
| `gateway_timeout_error` | 504 |
| `http_version_not_supported_error` | 505 |
| `http_error(code, message, headers)` | any code |

Every helper takes `(message, headers)`. `message` is optional and defaults to the status text; it can be a string or a table (a structured body). `headers` are added to the default error response:

```lua
nest:too_many_requests_error("slow down", { ["Retry-After"] = "30" })
nest:unprocessable_entity_error({ message = "Validation failed", errors = { "username too short" } })
```

`nest.http_exception(code, message, headers)` builds one without throwing, and `nest.is_http_exception(x)` checks for one. `nest.status_text[code]` maps codes to reason phrases.

Any other error (a bug) becomes a **500 with a generic body**. The original error is kept as `exception.cause` (with `exception.traceback`) for filters, and is sent to the module logger. It never reaches the client unless `module:expose_errors(true)` is set.

### Exception filters

`function(exception, ctx) -> response | nil`, registered with `module/controller/route:filter(...)`. They're tried most specific first: route, then controllers (leaf to root), then modules. The first one to return a response wins. A filter that returns `nil` defers; one that errors is logged and skipped. If nothing handles the exception, its `code`/`body`/`headers` are applied on top of `ctx.res`.

```lua
app:filter(function(e, ctx)
  return { code = e.code, body = { error = e.body, path = ctx.path, request_id = ctx.request_id } }
end)
```

`nest.compose_guards(...)`, `nest.compose_interceptors(...)` (also `compose_middleware`) and `nest.compose_filters(...)` fold several into one.

## Custom decorators

`module:decorator(name, fn)` packages common `use_*`/`guard`/`meta` combinations behind one fluent method available on controllers and routes of that module:

```lua
app:decorator("use_paging", function(route)
  return route
    :use_query("page", pipes.default("1"), pipes.int)
    :use_query("limit", pipes.default("20"), pipes.int)
end)

controller:route("List"):get("/"):use_paging():handle(function(page, limit) ... end)
```

## Async / coroutines

Guards, interceptors, pipes and handlers may yield (e.g. cosockets inside a coroutine-based server). On Lua 5.2+ and LuaJIT this works natively. On PUC Lua 5.1, which cannot yield across `pcall`, NestLua runs user code in coroutines and forwards the yields itself.

---

# Scheme — a class-validator-style validator

```lua
local scheme = require "nestlua.scheme"

local ContactDto = scheme {
  phone = scheme.string:phone(),
  email = scheme.string:email(),
}

local RegisterUserDto = scheme {
  username         = scheme.string:trim():min(3):alpha(),
  password         = scheme.string:strong_password(),
  password_confirm = scheme.string:same_as("password"),
  contact          = ContactDto:optional(),
  newsletter       = scheme.boolean:default(false),
}:strip()

local ok, errors = RegisterUserDto(input)        -- validate
local ok, value  = RegisterUserDto:parse(input)  -- validate + return the cleaned value
```

**Schemas are immutable.** Every chained call returns a new schema, so `ContactDto:optional()` above doesn't change `ContactDto`, and a base schema can be refined in several places safely.

Calling a schema returns `(ok, errors)`. `:parse()` returns `(true, cleaned)` or `(false, errors)`, where the cleaned value has defaults filled in, coercions and transforms applied, and unknown fields stripped when `:strip()` is set. `errors` is plain data, safe to `json.encode`:

- leaf schemas: an array of messages
- objects: `field -> errors`, recursively; object-level failures under `_self` (`scheme.self_key`)
- arrays / tables with `:of()`: `index/key -> errors`, plus `_self`

`scheme.flatten(errors)` turns that into `{ { path = "contact.email", message = "..." }, ... }`.

## Types

| Type | Accepts |
|---|---|
| `scheme.string` | strings |
| `scheme.number` | finite numbers (NaN / ±inf rejected) |
| `scheme.int` | finite numbers with no fractional part |
| `scheme.boolean` | `true` / `false` |
| `scheme.array` | proper 1..n sequences |
| `scheme.table` | any table (maps / dictionaries) |
| `scheme.date` | a unix timestamp, a `{ year=, month=, day=, hour=, min=, sec= }` table, or ISO 8601 `"YYYY-MM-DD"` / `"YYYY-MM-DDTHH:MM[:SS[.fff]][Z\|±hh:mm]"`. Impossible dates (`2023-02-31`) are rejected; everything is UTC. |
| `scheme { ... }` | an object with the given fields |
| `scheme.any_of(a, b, ...)` | a value matching any of the schemas (first match wins) |

## Modifiers (all types)

| Modifier | Effect |
|---|---|
| `:optional()` | `nil` (and JSON null) is accepted |
| `:nullable()` | JSON null (`scheme.null` / `json.null`) is accepted as a value |
| `:default(v)` | `nil` becomes `v` (a function is called for a fresh value) |
| `:coerce()` | strings are converted first: `"42"` → 42, `"true"`/`"1"` → true, `"a,b"` → `{ "a", "b" }` |
| `:transform(fn)` | `fn(value)` runs after the type check, before rules |
| `:message(msg)` | custom message for the previous rule (or the type check); a string or `function(args, value)` |
| `:validate_if(fn)` | only validate when `fn(value, parent, root)` is truthy |
| `:refine(fn, msg)` | custom rule `fn(value, vctx) -> ok[, msg]`; on objects it receives the whole object (cross-field rules) |
| `:same_as(field)` | must equal a sibling field |

## Constraints

**Common:** `:empty()` `:not_empty()` `:is_in(values...)` (alias `:enum`) `:not_in(values...)` `:equals(v)` `:not_equals(v)` (deep comparison)

**number / int:** `:min(n)` `:max(n)` `:range(lo, hi)` `:positive()` `:negative()` `:divisible_by(n)`

**date:** `:min(d)` `:max(d)` `:range(lo, hi)` `:to_timestamp()` (the cleaned value becomes a timestamp)

**array:** `:of(schemas...)` `:min(n)` `:max(n)` `:range(lo, hi)` `:contains(v)` `:not_contains(v)` `:unique()`

**table:** `:of(schemas...)` `:keys(schema)` `:min(n)` `:max(n)` `:range(lo, hi)` `:contains(v)` `:not_contains(v)`

**object:** `:strict()` (unknown fields are errors), `:strip()` (unknown fields dropped from the parsed value; recommended for request bodies), `:passthrough()` (default); composition with `:extend{...}` `:pick(names...)` `:omit(names...)` `:partial(names...?)` `:required()`

**string:** lengths are counted in UTF-8 characters. `:min(n)` `:max(n)` `:range(lo, hi)`, transforms `:trim()` `:to_lower()` `:to_upper()`, and
`:matches(lua_pattern)` `:starts_with(s)` `:ends_with(s)` `:contains(s)` `:not_contains(s)`
`:alpha()` `:alphanumeric()` `:ascii()` `:lowercase()` `:uppercase()`
`:boolean_string()` `:number_string()` `:date_string()` `:json()` `:jwt()`
`:base32()` `:base64()` `:hexadecimal()` `:octal()`
`:email()` `:url(opts)` `:uuid(version?)` `:phone()` `:ip_address("v4"|"v6"?)` `:mac_address()` `:port_number()`
`:sem_ver()` `:strong_password()` (alias `:password()`) `:isbn()` `:credit_card()`
`:passport_number()` `:postal_code()` `:ethereum_address()` `:btc_address()`
`:hex_color()` `:hsl()` `:rgb()`

`:url{ protocols = { "http", "https" }, require_tld = true }`: by default only `http`, `https` and `ftp` are accepted; pass `protocols = "*"` for any scheme.

### What's a heuristic

- **`phone()`**: optional `+`, then 7–15 digits after stripping spaces/dashes/dots/parens. Not full E.164.
- **`passport_number()` / `postal_code()`**: generic shape checks; real formats vary per country.
- **`ethereum_address()` / `btc_address()`**: format only. Checksums need Keccak-256 / double SHA-256.
- **`jwt()`**: three base64url segments. The signature isn't verified.

`isbn` and `credit_card` (Luhn) checksums, `json`, IPv4/IPv6 (including `::`, zone ids and embedded IPv4), dates and UUIDs are validated fully.

## Messages and i18n

Every message goes through `scheme.translate(key, default, args, value)` before it's reported. `key` is the rule name (`"min"`, `"email"`, ...), `"required"`, `"unknown"`, `"union"`, or `"type.<name>"`. Replace it to translate:

```lua
local messages = { required = "es obligatorio", email = "debe ser un correo válido" }
scheme.translate = function(key, default) return messages[key] or default end
```

## Custom types and constraints

```lua
scheme:type("even_int", {
  extends = "int",
  check = function(v)
    if v % 2 == 0 then return true end
    return false, "must be an even integer"
  end,
})
scheme.even_int:min(2)

-- fn(value, ...args, vctx): vctx.parent / vctx.root / vctx.path give context
scheme:constraint("string", "not_reserved", function(value)
  return value ~= "admin"
end, "is reserved")

scheme:constraint(nil, "not_zero", function(v) return v ~= 0 end) -- every type
```

## Schemas as pipes

A schema has `:parse()`, so it *is* a pipe. Passing one to `use_body` / `use_query` / `use_param` / ... replaces the argument with the cleaned value or rejects the request with a structured 400. Use `:coerce()` for query/path params, since those are always strings:

```lua
route:get("/search"):use_query("page", scheme.int:coerce():min(1):default(1))
```

`schema:describe()` returns a plain table (type, optional/nullable, rules **with their arguments**, nested shapes), which the OpenAPI generator uses.

---

# OpenAPI

```lua
local openapi = require "nestlua.openapi"

openapi.mount(app, "/openapi.json", { info = { title = "My API", version = "1.0.0" } })
-- or: openapi.generate(app, opts) -> table, openapi.json(app, opts) -> string
```

The document is built from the routes. It covers:
* path/query/header parameters, with their pipe or schema types
* request bodies from body schemas
* multipart uploads from `use_file`
* status codes from `route:status`
* 400/403 responses when pipes/guards exist

Add the rest with `route:doc{...}`:

```lua
route:doc({
  summary = "Create a user",
  description = "...",
  tags = { "users" },          -- default: the root controller's name
  operation_id = "createUser", -- default: the route name
  deprecated = false,
  security = { { bearer = {} } },
  responses = { [201] = { description = "Created", schema = UserDto } },
})
```

Lua patterns aren't regexes, so `:matches()` and `:id(%d+)` constraints are emitted as `x-lua-pattern`. Optional path params are expanded into one path per variant. Routes with `:meta("openapi_exclude", true)` are left out (the mounted document route is, automatically).

---

# HTTP server (lua-mhd)

`nestlua.mhd` serves an app with GNU libmicrohttpd through [lua-mhd](https://github.com/pjjov/lua-mhd) (`luarocks install lua-mhd`; lua-mhd 2.1 or newer, Lua 5.2+).

lua-mhd handles every request on a worker thread with its own `lua_State`, so the app is loaded **once per worker**. Put it in a module or file that returns a Module, an App, or a `function(...)` returning one:

```lua
local adapter = require "nestlua.mhd"

local srv = adapter.listen({
  port = 8080,
  thread_pool_size = 4,
  max_body_size = 10 * 1024 * 1024,
  -- adapter options:
  nest = { body_parser = { limit = 10 * 1024 * 1024 } },
}, "app", "extra", "args")   -- "app" or "./app.lua"; extra args go to the app function

io.read("l")
srv:stop()
```

All other `options` are passed to lua-mhd (TLS, Unix sockets, connection limits, ...). Extra arguments may be `nil`, booleans, numbers or strings. Workers inherit the launching process's `package.path` / `package.cpath`.

The adapter:

- maps lua-mhd's request table onto NestLua's. lua-mhd's parsed `query` is reused (lua-mhd keeps only the last value of a repeated key), and `basic_auth`, `digest_username` and `check_digest` are passed through.
- installs `middleware.body_parser()` in front of the app (`nest = { body_parser = false }` to disable it)
- encodes table bodies as JSON and sets `Content-Type`
- stringifies header values (lua-mhd silently drops non-string ones) and joins list values with `", "`
- passes `file`, `stream`, `stream_size` and `digest_challenge` through, so `nest.file()` / `nest.stream()` work

If you write your own lua-mhd worker script, use the handler directly:

```lua
return require("nestlua.mhd").handler(require("app"))
```

Workers don't share memory, so in-process state (caches, in-memory stores, provider singletons) is per worker. Keep shared state in a database or another external service.

---

# Development

```sh
lua test/run.lua            # every suite, against ./src (never an installed rock)
lua test/run.lua routing    # one suite
luacheck src test examples
luarocks make               # install from the working tree
```

CI runs the suites on Lua 5.1–5.4 and LuaJIT, plus luacheck.

## Source layout

Each public module is a thin entry point over smaller files that can also be required directly:

```
src/nestlua/
  init.lua              public API (require "nestlua")
  module.lua            Module class: registration, lifecycle, logging
  providers.lua         dependency injection (mixed into Module)
  controller.lua        Controller builder
  route.lua             RouteBuilder
  router/init.lua       build(): route table compilation (mixed into Module)
  router/pattern.lua    path pattern syntax, matching, ranking
  router/dispatch.lua   handle(): the request pipeline (mixed into Module)
  router/args.lua       handler argument resolution
  pipes.lua             pipe protocol and nest.pipes
  http.lua              status texts, exceptions, headers
  response.lua          nest.response / file / stream
  compose.lua           guard / interceptor / filter composition
  try.lua               coroutine-safe protected calls
  url.lua, util.lua     helpers
  json.lua              JSON encoder / decoder
  scheme/               the validator
    init.lua              public API, scheme:type / scheme:constraint
    schema.lua            schema objects, modifiers, validation core
    types/                common, scalar, string, collection, object, union
    validators/           text, network, identifiers (pure string predicates)
    dates.lua, errors.lua, config.lua, util.lua
  middleware/           body_parser, multipart, cors, request_id, logger
  openapi/              schema (describe -> JSON Schema), paths, operation
  mhd/                  lua-mhd adapter (init) and request/response conversion
test/                   test suites (test/run.lua runs them all)
examples/               a runnable lua-mhd example app
```
