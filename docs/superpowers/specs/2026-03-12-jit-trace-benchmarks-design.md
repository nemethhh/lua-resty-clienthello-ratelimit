# JIT Trace Analysis Benchmarks

**Date:** 2026-03-12
**Status:** Draft

## Goal

Verify that all hot paths in `lua-resty-clienthello-ratelimit` JIT-compile cleanly under LuaJIT 2.1. Detect trace aborts and NYI (Not Yet Implemented) bailouts that would cause fallback to the interpreter.

## Approach

Use `jit.attach(callback, "trace")` to programmatically capture trace events per code path. Each path is isolated via `jit.flush()`, warmed in a loop (200 iterations), and analyzed for successful compilation vs. aborts.

## File Layout

```
bench/
├── jit_trace.lua              -- main entry point (standalone resty script)
├── mocks.lua                  -- minimal mocks for ngx, ffi, shared dicts, resty.limit.req
└── Dockerfile                 -- OpenResty container for consistent LuaJIT version

docker-compose.bench.yml       -- compose file for bench-jit service
Makefile                       -- new targets: bench-jit, bench-jit-json, bench-jit-tap; updated clean target
```

## JIT Trace Capture Mechanism

For each code path:

1. `jit.flush()` — clear existing traces so events are isolated to this path
2. `jit.attach(callback, "trace")` — register a callback that fires on trace events
3. Run the path function in a loop (200 iterations, well above LuaJIT's default hot-loop threshold of 56)
4. `jit.attach(callback)` — detach (call with handler only, no event type)
5. Analyze captured events to determine compilation status

### `jit.attach` callback signature

The callback receives `(what, tr, func, pc, otr, oex)`:

- **Trace start:** `what == "flush"` is not relevant; a new trace is indicated by the callback firing during compilation. The key distinction:
  - **Successful compilation:** callback fires with a trace number `tr` and no abort info — the trace completed.
  - **Trace abort:** `what` contains the abort reason string (e.g., `"NYI: table.new"`). The `func` and `pc` parameters identify the source location.

To reliably distinguish compiled vs. aborted traces, we track:
- Trace starts (non-abort callbacks) → increment compiled count
- Abort callbacks (where `what` is a string containing abort reason) → record reason + location

Each path returns a result struct:

```lua
{ name = "path_name", status = "compiled"|"aborted", traces = N, aborts = { {reason, location} } }
```

A path is `"compiled"` if it has at least one successful trace and zero aborts. Otherwise `"aborted"`.

## Code Paths Under Test

Each "path" is a wrapper function that calls `lim:check()` with specific mock state to force execution through a particular branch. Since `check()` is a single method, earlier tiers execute before reaching later ones (e.g., `check_per_domain_pass` also traverses T0 and T1). This is intentional — it verifies JIT compilation of the full call chain for each scenario.

`extract_client_ip()` is a local function in `init.lua` (not exported). It is reached through `check()` as a prerequisite to all tier checks. The FFI mock must replace the C symbol at the FFI level (see Mock Layer) so the actual `ffi_cast`/`ffi_str` codegen is exercised.

| # | Path Name | Setup | What It Exercises |
|---|-----------|-------|-------------------|
| 1 | `extract_client_ip` | FFI mock with real `sockaddr_in`, all tiers disabled | FFI call chain: `ffi_cast`, `ffi_str`, binary key extraction via `check()` |
| 2 | `check_blocklist_hit` | Seed blocklist dict with mock IP's binary key | `shared_dict:get()` → early return, metrics inc |
| 3 | `check_per_ip_pass` | Empty blocklist, `lim_ip:incoming()` returns `0` | T0 miss → T1 pass |
| 4 | `check_per_ip_reject` | Empty blocklist, `lim_ip:incoming()` returns `nil, "rejected"` | T1 reject → auto-block via `shared_dict:set()` |
| 5 | `check_per_domain_pass` | T1 passes, `lim_dom:incoming()` returns `0` | T2 pass with SNI string key |
| 6 | `check_per_domain_reject` | T1 passes, `lim_dom:incoming()` returns `nil, "rejected"` | T2 reject with SNI string key |
| 7 | `config_validate` | Valid nested config table | Pure Lua table traversal, type checks |

## Mock Layer

Minimal mocks in `bench/mocks.lua` — just enough to make code paths execute. No spy/assertion logic.

| Dependency | Used By | Mock Strategy |
|---|---|---|
| `ngx.shared.DICT` | T0 blocklist, T1/T2 state | Simple table with `:get()`, `:set()` storing values in a Lua table |
| `resty.limit.req` | T1, T2 rate limiting | Configurable: returns `delay` or `nil, "rejected"` from `:incoming()` |
| `ngx.ssl.clienthello` | `check()` for SNI | `get_client_hello_server_name()` returns fixed string |
| FFI + C symbols | `extract_client_ip()` | See below |
| `ngx.log`, `ngx.ERR`, etc. | Logging | No-op functions and constants |
| `ngx.var.request_id` | Request context | Fixed string |

### FFI Mock Strategy

`extract_client_ip()` calls `C.ngx_http_lua_ffi_ssl_raw_client_addr(r, addr_pp, sizep, typep, errmsgp)`. To exercise the real FFI codegen (`ffi_cast` to `sockaddr_in*`, `ffi_str` on `sin_addr`), we need the C function to actually write a valid `sockaddr_in` into the provided buffer.

Approach: Use `ffi.cdef` to declare the mock function signature, then implement it as a Lua callback via `ffi.cast("mock_fn_type", lua_function)` that populates a pre-allocated `sockaddr_in` with `127.0.0.1`. The `init.lua` code references `C.ngx_http_lua_ffi_ssl_raw_client_addr` — we replace this symbol by patching the module's upvalue or by providing a mock C library loaded via `ffi.load`. The exact mechanism will be determined during implementation based on what LuaJIT allows for symbol replacement.

The key constraint: the downstream `ffi_cast("struct sockaddr_in*", addr_pp[0])` and `ffi_str(sa.sin_addr, 4)` calls must operate on real FFI memory, not Lua stubs.

## Output Formats

All example outputs below are **illustrative** — actual results will depend on which paths compile successfully.

### Human-readable (default)

```
JIT Trace Analysis — lua-resty-clienthello-ratelimit
=====================================================

  Path                        Status     Traces  Aborts
  ─────────────────────────── ────────── ─────── ──────
  extract_client_ip           COMPILED   2       0
  check_blocklist_hit         COMPILED   1       0
  check_per_ip_pass           COMPILED   1       0
  check_per_ip_reject         COMPILED   1       0
  check_per_domain_pass       COMPILED   1       0
  check_per_domain_reject     COMPILED   1       0
  config_validate             COMPILED   1       0

=====================================================
Result: PASS (7/7 paths compiled)
```

### JSON (`--format json`)

```json
{
  "summary": { "total": 7, "compiled": 7, "aborted": 0, "status": "pass" },
  "paths": [
    { "name": "extract_client_ip", "status": "compiled", "traces": 2, "aborts": [] },
    { "name": "check_blocklist_hit", "status": "compiled", "traces": 1, "aborts": [] }
  ]
}
```

### TAP (`--format tap`)

```
TAP version 13
1..7
ok 1 - extract_client_ip
ok 2 - check_blocklist_hit
ok 3 - check_per_ip_pass
ok 4 - check_per_ip_reject
ok 5 - check_per_domain_pass
ok 6 - check_per_domain_reject
ok 7 - config_validate
```

### Argument Parsing

CLI arguments are parsed from LuaJIT's `arg` table. When invoked via `resty`, arguments after the script name are available in `arg[1]`, `arg[2]`, etc. The script checks for `--format` followed by `json` or `tap`; default is human-readable. No external flag-parsing library is needed.

## Exit Codes

- `0` — All paths compiled successfully
- `1` — One or more paths have trace aborts

## Docker & Makefile Integration

### Dockerfile (`bench/Dockerfile`)

```dockerfile
FROM openresty/openresty:jammy
COPY lib/ /usr/local/openresty/site/lualib/
COPY bench/ /bench/
WORKDIR /bench
ENTRYPOINT ["resty", "jit_trace.lua"]
```

Same base image as unit tests for consistent LuaJIT version.

### docker-compose.bench.yml

```yaml
services:
  bench-jit:
    build:
      context: .
      dockerfile: bench/Dockerfile
```

### Makefile targets

Uses `docker compose run --rm` (single-container, no dependencies needed). Exit code propagates directly.

```makefile
bench-jit:              ## Run JIT trace analysis (human-readable)
	docker compose -f docker-compose.bench.yml run --rm bench-jit

bench-jit-json:         ## Run JIT trace analysis (JSON output)
	docker compose -f docker-compose.bench.yml run --rm bench-jit --format json

bench-jit-tap:          ## Run JIT trace analysis (TAP output)
	docker compose -f docker-compose.bench.yml run --rm bench-jit --format tap
```

The `clean` target is updated to also tear down `docker-compose.bench.yml`:

```makefile
clean:
	docker compose -f docker-compose.bench.yml down -v 2>/dev/null || true
	# ... existing teardown lines ...
```

## Scope

- 4 new files: `bench/jit_trace.lua`, `bench/mocks.lua`, `bench/Dockerfile`, `docker-compose.bench.yml`
- 1 edited file: `Makefile` (new targets + updated `clean`)
- 7 code paths verified
- 3 output formats
- CI-friendly exit codes
