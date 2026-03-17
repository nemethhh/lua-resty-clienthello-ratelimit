# GitHub Actions CI & Release Workflows Design

**Date:** 2026-03-17
**Status:** Approved

## Overview

Add GitHub Actions workflows for continuous integration and automated release publishing for the lua-resty-clienthello-ratelimit project. Two separate workflow files provide clean separation between PR/push validation and tag-based release publishing.

## Workflows

### CI Workflow (`.github/workflows/ci.yml`)

**Triggers:**
- Push to `main` branch
- Pull requests targeting `main`

**Concurrency:** Group by `ci-${{ github.ref }}`, cancel in-progress runs on same ref.

**Runner:** `ubuntu-latest`

**Single job steps:**
1. Checkout code
2. `make unit` — Docker Compose busted unit tests
3. `make openresty-integration` — Docker Compose OpenResty + pytest integration tests
4. `make clean` (with `if: always()`) — cleanup containers

**Rationale:** No matrix strategy needed — tests run inside OpenResty Docker containers which pin the Lua/OpenResty version. Docker Compose is pre-installed on `ubuntu-latest`. APISIX integration is excluded from CI to keep feedback fast — it runs in the release workflow where the full suite gates publishing.

### Release Workflow (`.github/workflows/release.yml`)

**Triggers:** Push tags matching `v*`

**Concurrency:** Group by `release`, do not cancel in-progress (prevent partial publishes).

#### Job 1: `test`

1. Checkout code
2. **Version validation:**
   - Extract version from tag (strip `v` prefix, e.g., `v0.3.0` → `0.3.0`)
   - Verify rockspec file exists: `lua-resty-clienthello-ratelimit-<version>-1.rockspec` (convention: revision is always `-1`)
   - Verify `dist.ini` exists and its `version` field matches the tag version
   - Fail fast with clear error messages if any check fails
3. `make unit` — unit tests
4. `make integration` — APISIX integration tests
5. `make openresty-integration` — OpenResty integration tests
6. `make bench-jit` — JIT trace benchmarks (the bench script exits non-zero when trace aborts are detected, which fails the step)
7. `make clean` (with `if: always()`) — cleanup containers even on failure

#### Job 2: `publish` (needs: test)

1. Checkout code
2. Install `luarocks` CLI (via `apt-get install luarocks`)
3. **Luarocks publish:** `luarocks upload <rockspec> --api-key $LUAROCKS_API_KEY`
4. Install `opm` CLI: add OpenResty APT repo, install `openresty-opm` package
5. **OPM publish:** `opm upload` using `OPM_GITHUB_TOKEN`
6. **GitHub Release:** `gh release create` with tag and auto-generated release notes (uses the default `GITHUB_TOKEN` provided by Actions)

## New Files

### `dist.ini` (repo root)

OPM metadata file required for `opm upload`. Created as part of the initial implementation PR.

```ini
name = lua-resty-clienthello-ratelimit
abstract = Three-tier TLS ClientHello rate limiter for OpenResty and Apache APISIX
version = 0.2.0
author = nemethhh
is_original = yes
license = mit
lib_dir = lib
repo_link = https://github.com/nemethhh/lua-resty-clienthello-ratelimit
```

Version field must stay in sync with rockspec — validated by release workflow.

## Secrets Required

Configure in GitHub repo settings (Settings → Secrets and variables → Actions):

| Secret | Purpose | Source |
|--------|---------|--------|
| `LUAROCKS_API_KEY` | luarocks.org API key for package upload | luarocks.org account settings |
| `OPM_GITHUB_TOKEN` | Personal GitHub token for OPM auth (needs `repo` scope) | GitHub personal access token |

The default `GITHUB_TOKEN` (auto-provided by Actions) is used for `gh release create`.

## Release Process (Manual Steps)

1. Create a new rockspec file with the new version in its filename (e.g., `lua-resty-clienthello-ratelimit-0.3.0-1.rockspec`), update its `version` and `source.tag` fields, and delete the old rockspec
2. Update `dist.ini`: `version` field
3. Commit changes
4. Create and push tag: `git tag v<version> && git push origin v<version>`
5. GitHub Actions handles: version validation → full tests → bench → publish to luarocks + OPM → GitHub Release

## Design Decisions

- **Two files over one:** Clean separation, easier to debug, no conditional job logic
- **No matrix strategy:** Tests run inside Docker containers that pin OpenResty version
- **Version validation before tests:** Fail fast on version mismatch, don't waste CI minutes
- **Manual version updates:** Explicit control over version bumps, no auto-patching surprises
- **bench-jit as gate:** JIT trace aborts indicate performance regressions, block release if detected
- **APISIX integration only in release:** Keeps CI fast; full suite gates the actual publish
- **`if: always()` on cleanup:** Prevents container/resource leaks on CI runner when tests fail
- **Concurrency groups:** Prevents redundant CI runs and protects against parallel release publishes
- **Rockspec revision always `-1`:** Convention for this project; version validation assumes this suffix
