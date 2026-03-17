# GitHub Actions CI & Release Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions workflows for CI (push/PR) and release (tag) with automated publishing to OPM.

**Architecture:** Two separate workflow files — `ci.yml` for fast feedback on PRs/main, `release.yml` for full test suite + publish on version tags. A `dist.ini` file provides OPM metadata.

**Tech Stack:** GitHub Actions, Docker Compose, OpenResty opm CLI

**Spec:** `docs/superpowers/specs/2026-03-17-github-actions-ci-release-design.md`

---

### Task 1: Create `dist.ini` for OPM

**Files:**
- Create: `dist.ini`

- [ ] **Step 1: Create `dist.ini`**

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

- [ ] **Step 2: Commit**

```bash
git add dist.ini
git commit -m "build: add dist.ini for OPM package metadata"
```

---

### Task 2: Create CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create `.github/workflows/` directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run unit tests
        run: make unit

      - name: Run OpenResty integration tests
        run: make openresty-integration

      - name: Cleanup
        if: always()
        run: make clean
```

- [ ] **Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"
```

Expected: No output (valid YAML)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add CI workflow for unit and OpenResty integration tests"
```

---

### Task 3: Create Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags: ['v*']

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Extract version from tag
        id: version
        run: |
          TAG="${GITHUB_REF#refs/tags/v}"
          echo "version=$TAG" >> "$GITHUB_OUTPUT"
          echo "Extracted version: $TAG"

      - name: Validate rockspec exists
        run: |
          ROCKSPEC="lua-resty-clienthello-ratelimit-${{ steps.version.outputs.version }}-1.rockspec"
          if [ ! -f "$ROCKSPEC" ]; then
            echo "::error::Rockspec not found: $ROCKSPEC"
            exit 1
          fi
          echo "Found rockspec: $ROCKSPEC"

      - name: Validate dist.ini version
        run: |
          if [ ! -f dist.ini ]; then
            echo "::error::dist.ini not found"
            exit 1
          fi
          DIST_VERSION=$(grep '^version' dist.ini | sed 's/version *= *//')
          TAG_VERSION="${{ steps.version.outputs.version }}"
          if [ "$DIST_VERSION" != "$TAG_VERSION" ]; then
            echo "::error::dist.ini version ($DIST_VERSION) does not match tag version ($TAG_VERSION)"
            exit 1
          fi
          echo "dist.ini version matches: $DIST_VERSION"

      - name: Run unit tests
        run: make unit

      - name: Run APISIX integration tests
        run: make integration

      - name: Run OpenResty integration tests
        run: make openresty-integration

      - name: Run JIT trace benchmarks
        run: make bench-jit

      - name: Cleanup
        if: always()
        run: make clean

  publish:
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Install opm
        run: |
          wget -qO - https://openresty.org/package/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/openresty.gpg
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/openresty.list > /dev/null
          sudo apt-get update
          sudo apt-get install -y openresty-opm

      - name: Publish to OPM
        env:
          GITHUB_TOKEN: ${{ secrets.OPM_GITHUB_TOKEN }}
        run: opm upload

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${{ github.ref_name }}" \
            --title "${{ github.ref_name }}" \
            --generate-notes
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"
```

Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow with OPM publish and GitHub Release"
```

---

### Task 4: Verify workflows locally with `act` (optional dry-run)

- [ ] **Step 1: Dry-run CI workflow syntax check**

```bash
cd /home/am/Fun/lua-resty-clienthello-ratelimit
cat .github/workflows/ci.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print('ci.yml: valid')"
cat .github/workflows/release.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print('release.yml: valid')"
```

Expected: Both print "valid"

- [ ] **Step 2: Verify `make unit` still works locally**

```bash
make unit
```

Expected: All busted tests pass

- [ ] **Step 3: Verify `make openresty-integration` still works locally**

```bash
make openresty-integration
```

Expected: All pytest tests pass

- [ ] **Step 4: Cleanup**

```bash
make clean
```
