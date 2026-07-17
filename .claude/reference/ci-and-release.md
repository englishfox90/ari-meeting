# CI & Release — Reference for the GitLab Port

The inherited GitHub CI (`.github/`) and the GitHub-based updater tooling were **removed** during the move off GitHub. This file records what they did, so they can be rebuilt as GitLab CI when the GitLab remote is set up. Nothing here is live today.

## What the GitHub workflows did

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | `pull_request`, `push:main` (auto) | **The real gatekeeper.** Single job on ubuntu: pnpm 11 + Node 22, `pnpm install --frozen-lockfile`, `node --test tests/lib/*.test.mjs`, `pnpm lint`, `pnpm build`. No Rust/Tauri build. |
| `build.yml` | `workflow_call` (reusable) | Full Tauri build. pnpm cache → `cargo build --release -p llama-helper [features]` → platform codesign (Apple `APPLE_CERTIFICATE`/`APPLE_ID`/`TEAM_ID`; Windows SSL.com) → `tauri-apps/tauri-action@v0` which builds and uploads artifacts to the GitHub release. |
| `release.yml` | `workflow_dispatch` | Creates a draft GitHub Release (`github.rest.repos.createRelease`), auto-increments version from tags (`v0.5.0.N`), calls `build.yml` for macOS-aarch64 + Windows-x86_64 (Linux excluded), `asset-prefix: ari-meeting`. |
| `build-test.yml`, `build-{macos,windows,linux}.yml`, `build-devtest.yml` | `workflow_dispatch` | Per-platform build wrappers with sign/upload inputs. |
| `pr-main-check.yml` | `workflow_dispatch` | Version/branch validation only, no build. |

## Minimum viable GitLab CI

Port `ci.yml` first — it's trivial and is the actual quality gate:

```yaml
# .gitlab-ci.yml (sketch)
frontend-check:
  image: node:22
  before_script:
    - corepack enable pnpm
    - cd frontend && pnpm install --frozen-lockfile
  script:
    - node --test tests/lib/*.test.mjs
    - pnpm lint
    - pnpm build
```

The full Tauri build (`build.yml`/`release.yml`) is the hard part — it depends on `tauri-apps/tauri-action`, `actions/github-script`, the GH Releases API, `gh` CLI, and GitHub-style `secrets`. On GitLab, rebuild as explicit steps: `cargo build --release -p llama-helper --features metal` → stage the sidecar → `pnpm tauri build` → manual Apple codesign → upload to GitLab Release/Package Registry. Needs a macOS runner.

## Updater — a real functional break (must fix before shipping updates)

- `tauri.conf.json` `plugins.updater.endpoints` points at `https://github.com/henryvn27/meetily_improved/releases/latest/download/latest.json`. **Still points at GitHub — non-functional until re-pointed** to a GitLab release asset / Package Registry / Pages URL.
- `scripts/generate-update-manifest-github.js` (removed) hard-coded GitHub download URLs; a replacement manifest generator is needed for the new host. `scripts/test-update-locally.js` (kept) serves `latest.json` locally on :8080 for testing.
- **CRITICAL — the minisign signing key is host-independent and must migrate intact.** The public key in `tauri.conf.json` and `TAURI_SIGNING_PRIVATE_KEY` (+ password) verify updates. If they change, existing installs can't verify updates. Preserve them across the move.

## Issue / PR templates

`.github/ISSUE_TEMPLATE/*` + `pull_request_template.md` were GitHub-community artifacts (they linked GitHub Discussions + Security Advisories, which GitLab lacks). If wanted on GitLab, recreate as `.gitlab/issue_templates/*.md` and `.gitlab/merge_request_templates/*.md`. Given the PRD's private single-user scope, these are likely unnecessary.

## Repo string constants to update on the move

- `frontend/src-tauri/Cargo.toml` `repository = "https://github.com/henryvn27/meetily_improved"` (cosmetic rebrand updated the package.json name; this field and the updater URL still reference the old host).
