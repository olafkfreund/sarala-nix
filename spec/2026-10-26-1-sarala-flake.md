---
status: draft
issue: 1
intent: intent/2026-10-26-1-sarala-flake.md
---

# Spec: Package Sarala for NixOS and Home Manager

## Decisions carried from the approved intent

| Question | Decision |
| --- | --- |
| Platforms | x86_64-linux and aarch64-linux |
| Voice typing | On by default, `withVoice` toggle |
| Module scope | Install, desktop entry, MIME associations; no declarative settings |
| Daily updater | Opens a PR, auto-merged when CI is green |
| Cross-model review | Codex and agy review this spec and the final diff |
| Packaging license | MIT (app stays GPL-3.0-or-later) |

## Design

### Repo layout

```
flake.nix            inputs: nixpkgs (nixos-unstable), home-manager (checks only)
package.nix          callPackage-able derivation, args: withVoice ? true
modules/nixos.nix    programs.sarala
modules/home.nix     programs.sarala
checks/              nixos VM test + HM eval check
update.sh            bump version + hashes (used by the daily job)
.github/workflows/   ci.yml, update.yml
README.md, LICENSE (MIT)
```

Flake outputs (per system in `[x86_64-linux aarch64-linux]`):
`packages.{sarala,default}`, `apps.default`, `checks.*`, `formatter` (nixfmt),
plus system-independent `overlays.default`, `nixosModules.{sarala,default}`,
`homeManagerModules.{sarala,default}`. No flake-utils / flake-parts: a
`genAttrs` over two systems is a few lines. `home-manager` is a second input,
used only by `checks.home-manager`; the HM module itself is a plain module
that needs nothing from it (see Risks).

### Package (`package.nix`)

`rustPlatform.buildRustPackage` with nixpkgs' Tauri hooks, the pattern used by
nixpkgs Tauri apps:

- `src = fetchFromGitHub { owner = "solancer"; repo = "sarala"; tag = "v${version}"; }`
- `cargoRoot = "src-tauri"; buildAndTestSubdir = "src-tauri";` with
  `cargoHash` (vendored from upstream `Cargo.lock`).
- Frontend deps: `pnpmDeps = fetchPnpmDeps { pnpm = pnpm_11; fetcherVersion = 2; hash; }`
  with `pnpmConfigHook` + `pnpm_11` (upstream pins `pnpm@11.10.0`; nixpkgs has 11.27).
- `nativeBuildInputs`: `cargo-tauri.hook pnpmConfigHook pnpm_11 nodejs_22
  pkg-config wrapGAppsHook3` and `cmake` when `withVoice`.
- `buildInputs`: `webkitgtk_4_1 gtk3 librsvg libayatana-appindicator
  glib-networking openssl` plus `alsa-lib` when `withVoice`.
- Voice: `buildNoDefaultFeatures = !withVoice; buildFeatures = lib.optional withVoice "voice";`
  and `env.TRANSCRIBE_CMAKE_ARGS = "-DGGML_NATIVE=OFF -DGGML_BLAS=OFF"`.
  ggml sources are vendored inside the `transcribe-cpp-sys` crate (no network).
  `GGML_NATIVE=OFF` is mandatory: a native build bakes the builder's CPU flags
  into a cached binary that then SIGILLs on other CPUs. BLAS off keeps the
  closure small and deterministic (upstream's OpenBLAS probe linked whatever the
  runner had); x86_64 keeps upstream's AVX/AVX2/FMA/F16C flags.
- Tauri: build only the binary bundle (`tauriBundleType = "deb"` is the nixpkgs
  default trick for extracting the binary + desktop file + icons), and set
  `bundle.createUpdaterArtifacts = false` via a `--config` override so the
  build does not ask for an updater signing key.
- Updater: no patch. Upstream `can_self_update()` (src-tauri/src/main.rs:497)
  returns false when the binary is not owned by dpkg/rpm/AppImage, and
  `runCheck()` (src/updater.ts:100) then skips the startup check and tells the
  user updates come from the system. A Nix build matches that path. Verified in
  the VM test by asserting no request to the updater gist is needed to start.
- Tests: `doCheck = false` for `cargo test` (upstream has no Rust tests worth the
  rebuild); a separate `passthru.tests.frontend` derivation runs `pnpm test`
  (11 jsdom unit suites) against the same `pnpmDeps`. Playwright e2e and perf
  suites are out of scope (need a display and browsers).
- `meta`: GPL-3.0-or-later, `mainProgram = "sarala"`, platforms linux,
  `passthru.updateScript` pointing at `update.sh`.

### Modules

Both expose the same options (the whole real surface of the app):

```nix
programs.sarala = {
  enable = mkEnableOption "Sarala Markdown editor";
  package = mkPackageOption pkgs "sarala" { };   # defaults to this flake's build
  withVoice = mkOption { type = bool; default = true; };  # overrides package
  defaultForMarkdown = mkOption { type = bool; default = false; };
};
```

- NixOS: `environment.systemPackages`. The default `package` comes from the
  flake (the module closes over `self`), so users need not add the overlay.
- Home Manager: `home.packages`; `defaultForMarkdown` sets
  `xdg.mimeApps.defaultApplications."text/markdown"` (and `text/x-markdown`).
  On NixOS the same option sets `xdg.mime.defaultApplications`.
- The desktop file already declares `MimeType=text/markdown;text/x-markdown;`,
  so "Open With" works with `enable` alone.
- Voice model download (HuggingFace, at runtime, user-initiated) and settings
  stay in the app; nothing to configure.

### CI (`.github/workflows/ci.yml`)

On push to main, PRs, and `workflow_call` (reused by the updater):

1. `nix flake check` on `ubuntu-latest` (x86_64): builds the package, the
   frontend test derivation, the NixOS VM test and the HM eval check.
2. `nix build .#sarala` on `ubuntu-24.04-arm` (aarch64, eval + build, no VM test).
3. Nix via `DeterminateSystems/nix-installer-action`, cache via
   `DeterminateSystems/magic-nix-cache-action` (free, no secrets). Cachix is
   rejected for now (needs a token; add later if build time hurts).

Checks:
- `checks.vm`: `nixosTest` with `programs.sarala.enable = true`, X11 + a window
  manager, launches `sarala`, waits for its window, takes a screenshot. Proves
  it installs and starts.
- `checks.home-manager`: evaluates a `homeManagerConfiguration` with the module
  and builds its activation package (proves HM install path).
- `checks.no-voice`: builds `sarala.override { withVoice = false; }`.

### Daily updater (`.github/workflows/update.yml`)

`schedule: cron "17 4 * * *"` + `workflow_dispatch`:

1. `nix flake update` (nixpkgs bump) and `./update.sh`, which reads the latest
   release tag via `gh api repos/solancer/sarala/releases/latest`, rewrites
   `version`, and recomputes `src` hash, `cargoHash` and `pnpmDeps` hash with
   `nix-update` (`nix-update sarala --flake --version <v>` handles all three).
2. If the tree changed, open/update a PR on branch `auto/update` using
   `peter-evans/create-pull-request` and enable auto-merge (squash).
3. The PR runs `ci.yml`; branch protection on `main` requires it, so a failing
   build or test blocks the merge. A failing run leaves the PR open as the alert.

Requires: repo setting "Allow auto-merge", branch protection on `main` with the
CI checks required, and a token that triggers workflows on the bot PR (a
fine-grained PAT `UPDATE_TOKEN`; `GITHUB_TOKEN` PRs do not trigger CI). This is
one manual setup step for the owner.

## Alternatives rejected

- **Wrap the upstream AppImage/.deb**: simpler and faster CI, but violates the
  build-from-source constraint, ships a binary built for Ubuntu's glibc, and the
  .deb would trip the updater's dpkg check path. Kept as a fallback only if the
  source build proves unworkable (then the spec is revised, not silently swapped).
- **flake-parts / flake-utils**: an extra input for a two-system genAttrs.
- **Declarative settings**: Sarala stores settings in its app store with no
  documented stable format; writing it would clobber user state. Out of scope.
- **Upstream to nixpkgs instead**: worthwhile later; this flake is the proving
  ground and its `package.nix` is written in nixpkgs style to make that easy.
- **Patching the updater out**: unnecessary given `can_self_update()`.
- **Running Playwright e2e in CI**: needs browsers and a display inside the
  sandbox; the VM test covers "it launches" more cheaply.

## Risks

- **pnpm 11 fetcher**: `fetchPnpmDeps` support for pnpm 11 lockfile v9 is
  newer; if it fails, fall back to `pnpm_10` with `--lockfile-only` compat or
  pin pnpm 11.10 via override. Found in step 1 of the plan, before anything else.
- **ggml on aarch64**: CPU-flag defaults differ; x86-only flags must be set only
  on x86_64. Built in CI on the ARM runner.
- **Build time**: Rust LTO + ggml is slow (est. 20-40 min cold). magic-nix-cache
  helps after the first run; GitHub's 6 h job limit is not at risk.
- **VM test flakiness**: WebKitGTK under software GL in a VM may be slow to
  map a window; use a generous timeout and `WEBKIT_DISABLE_COMPOSITING_MODE=1`.
- **Updater upstream changes**: if upstream changes `can_self_update`, the Nix
  build could start offering updates. The VM test cannot see the network, so a
  grep check in `update.sh` fails the bump if `can_self_update` disappears.
- **HM check input**: adding `home-manager` as a flake input makes every user
  lock it. Mitigation: make it an input used only in `checks` and document
  `inputs.sarala.inputs.home-manager.follows`. Users of the module pay one lock
  entry and nothing else.
- **No change to any host**: this repo does not touch the user's machines.

## Verification

- `nix flake check` passes on x86_64 (package, frontend tests, VM test, HM
  check, no-voice build) and `nix build .#sarala` passes on aarch64, in CI.
- `nix run github:olafkfreund/sarala-nix` opens a Sarala window locally.
- `workflow_dispatch` of `update.yml` with no new upstream release makes no PR;
  with `update.sh` pointed at an older version first, it produces a PR that
  goes green and auto-merges.
- Codex and agy review this spec (findings answered in the plan) and the final diff.
