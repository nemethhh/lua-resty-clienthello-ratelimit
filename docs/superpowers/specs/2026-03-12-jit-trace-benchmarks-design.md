# JIT Trace Analysis Benchmarks

**Date:** 2026-03-12
**Status:** Draft

## Goal

Verify that all hot paths in `lua-resty-clienthello-ratelimit` JIT-compile cleanly under LuaJIT 2.1. Detect trace aborts and NYI (Not Yet Implemented) bailouts that would cause fallback to the interpreter.

## Approach

Use `jit.v`'s programmatic `on` callback to capture trace events per code path. Each path is isolated via `jit.flush()`, warmed in a loop (200 iterations), and analyzed for successful compilation vs. aborts.

## File Layout

```
bench/
├── jit_trace.lua              -- main entry point (standalone resty script)
├── mocks.lua                  -- minimal mocks for ngx, ffi, shared dicts, resty.limit.req
└── Dockerfile                 -- OpenResty container for consistent LuaJIT version

docker-compose.bench.yml       -- compose file for bench-jit service
Makefile                       -- new targets: bench-jit, bench-jit-json, bench-jit-tap
```

## JIT Trace Capture Mechanism

For each code path:

1. `jit.flush()` — clear existing traces so events are isolated to this path
2. Hook `jit.v.on(callback)` — capture `start`, `stop`, and `abort` events
3. Run the path function in a loop (200 iterations, well above LuaJIT's default hot-loop threshold of 56)
4. `jit.v.off()` — stop capturing
5. Analyze events: `start` + `stop` = compiled successfully; `abort` = failed (includes NYI reason and source location)

Each path returns a result struct:

```lua
{ name = "path_name", status = "compiled"|"aborted", traces = N, aborts = { {reason, location} } }
```

## Code Paths Under Test

| # | Path Name | Setup | What It Exercises |
|---|-----------|-------|-------------------|
| 1 | `extract_client_ip` | FFI mock with real `sockaddr_in` | `ffi_cast`, `ffi_str`, binary key extraction |
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
| FFI + C symbols | `extract_client_ip()` | Mock `ngx_http_lua_ffi_ssl_raw_client_addr` writes real `sockaddr_in` struct into FFI buffer |
| `ngx.log`, `ngx.ERR`, etc. | Logging | No-op functions and constants |
| `ngx.var.request_id` | Request context | Fixed string |

The FFI mock provides a real `sockaddr_in` struct so `ffi_cast`/`ffi_str` exercise actual FFI codegen, which is critical for verifying JIT compilation of the extraction path.

## Output Formats

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
  config_validate             ABORT      0       1
                              └─ NYI: table.new at config.lua:42

=====================================================
Result: FAIL (1/7 paths have trace aborts)
```

### JSON (`--format json`)

```json
{
  "summary": { "total": 7, "compiled": 6, "aborted": 1, "status": "fail" },
  "paths": [
    { "name": "extract_client_ip", "status": "compiled", "traces": 2, "aborts": [] },
    { "name": "config_validate", "status": "aborted", "traces": 0, "aborts": [
      { "reason": "NYI: table.new", "location": "config.lua:42" }
    ]}
  ]
}
```

### TAP (`--format tap`)

```
TAP version 13
1..7
ok 1 - extract_client_ip
ok 2 - check_blocklist_hit
not ok 7 - config_validate
  ---
  reason: "NYI: table.new"
  location: "config.lua:42"
  ...
```

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

```makefile
bench-jit:          ## Run JIT trace analysis (human-readable)
bench-jit-json:     ## Run JIT trace analysis (JSON output)
bench-jit-tap:      ## Run JIT trace analysis (TAP output)
```

Exit code propagates through docker compose for CI gating.

## Scope

- 7 new files: `bench/jit_trace.lua`, `bench/mocks.lua`, `bench/Dockerfile`, `docker-compose.bench.yml`, plus edits to `Makefile`
- 7 code paths verified
- 3 output formats
- CI-friendly exit codes
