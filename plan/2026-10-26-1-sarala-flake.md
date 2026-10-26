---
status: approved
issue: 1
spec: spec/2026-10-26-1-sarala-flake.md
reviewers:
  - codex   # spec decision: cross-model review of the final diff
  - agy     # same; it caught the runtime-PATH and desktop-name bugs in the spec
---

# Plan: Package Sarala for NixOS and Home Manager

Repo: `/mnt/code/Source-home/GitHub/sarala-nix`, branch `feat/1-sarala-flake`,
remote `olafkfreund/sarala-nix` (public). Builds run on the local host (p620,
x86_64, Nix with flakes). Upstream: `solancer/sarala` tag `v1.3.3`.

## Approved decisions (self-contained copy of the spec)

- Build from source with `rustPlatform.buildRustPackage` + `cargo-tauri.hook`.
  `cargoRoot = buildAndTestSubdir = "src-tauri"`.
- Frontend deps: `fetchPnpmDeps { pnpm = pnpm_11; fetcherVersion = 5; }`, plus
  `pnpmConfigHook`, `pnpm_11` and `nodejs_22`.
- `buildInputs`: `webkitgtk_4_1 gtk3 librsvg libayatana-appindicator
  glib-networking wayland dbus`, plus `alsa-lib openblas` when `withVoice`
  (adjust to what pkg-config reports).
- `withVoice ? true` maps to `buildNoDefaultFeatures = !withVoice`,
  `buildFeatures = optional withVoice "voice"`, and `cmake` in nativeBuildInputs.
- `env.TRANSCRIBE_CMAKE_ARGS`: `-DGGML_NATIVE=OFF -DBLA_VENDOR=OpenBLAS`. On
  x86_64 also `-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX512=OFF`.
- `tauriBuildFlags = [ "--config" ''{"bundle":{"createUpdaterArtifacts":false}}'' ]`.
- `postPatch`: `grep -q 'fn can_self_update' src-tauri/src/main.rs`, which
  fails the build if upstream drops the self-update gate.
- `postInstall`: rename `Sarala.desktop` to `sarala.desktop`. With voice, assert
  that `patchelf --print-needed` on the binary lists `libopenblas`.
- `preFixup`: `gappsWrapperArgs+=(--prefix PATH : ${makeBinPath [curl xdg-utils]})`.
- `doCheck = false`. `passthru.tests.frontend` runs `pnpm test` on the same `pnpmDeps`.
- Modules (NixOS and HM) take `self` and define `programs.sarala.{enable,
  withVoice, package, defaultForMarkdown}`. The `package` default is the flake
  package `.override { inherit withVoice; }`; a user-supplied package is never
  overridden. NixOS uses `environment.systemPackages` and `xdg.mime.defaultApplications`.
  HM uses `home.packages`, `xdg.mimeApps.enable = mkDefault true` and
  `xdg.mimeApps.defaultApplications`. MIME types `text/markdown` and
  `text/x-markdown` map to `sarala.desktop`.
- Flake inputs: `nixpkgs` (nixos-unstable) and `home-manager` (follows nixpkgs).
  Systems: x86_64-linux and aarch64-linux, via `genAttrs`. Outputs: packages,
  apps, overlays, nixosModules, homeManagerModules, checks and formatter (`nixfmt`).
- Checks: `sarala`, `frontend`, `home-manager` (asserts `mimeapps.list`), and
  `vm` on x86_64 only (WEBKIT_DISABLE_DMABUF_RENDERER=1 and
  WEBKIT_DISABLE_COMPOSITING_MODE=1, waits for the window).
- CI and the updater as in steps 6 and 7. `UPDATE_TOKEN` comes from the agenix
  secret `api-github-token` (`/run/agenix/api-github-token`), piped into
  `gh secret set` and never printed.
- License: MIT for this repo.

## Steps

Implementer: the `coder` agent (Sonnet), per the managed model split (more
than 3 file-editing steps). Claude runs step 8 (secrets and repo settings,
outward-facing) itself.

1. `package.nix` (new) and a minimal `flake.nix` (new, `packages` only):
   write the derivation with fake hashes (`lib.fakeHash`). Build
   `.#sarala.src`, `.#sarala.pnpmDeps` and `.#sarala.cargoDeps`, and paste
   each real hash in turn. → verify: `nix build .#sarala.pnpmDeps -L` succeeds.
   Traps: if `fetchPnpmDeps` with pnpm_11 fails on this lockfile, STOP and
   report; that is a spec risk, not something to work around silently.
   Use `tag =` in `fetchFromGitHub`.
2. `package.nix`: complete the build. → verify: `nix build .#sarala -L`
   succeeds, `result/bin/sarala` exists,
   `result/share/applications/sarala.desktop` exists, and the patchelf assert
   passes. Then `timeout 20 nix run .#sarala` under the desktop session shows
   a window (or at least no crash in the first 20 s).
   Traps: add a missing pkg-config library to `buildInputs`, or drop an unused
   one (e.g. openssl was not needed per the lockfile). The ggml build takes
   minutes; use `-L` and do not kill it early. Build with `--cores 0`.
3. `package.nix`: `passthru.tests.frontend`, a `stdenv.mkDerivation` reusing
   `src` and `pnpmDeps` that runs `pnpm test` and does `touch $out`.
   → verify: `nix build .#sarala.tests.frontend -L` passes all 11 suites.
   Traps: jsdom tests need no browser. If a suite needs network, report it;
   do not delete the suite.
4. `modules/nixos.nix` and `modules/home.nix` (new), each a function
   `self: { config, lib, pkgs, ... }:`. Wire them into `flake.nix` together
   with `overlays.default`, `apps.default` and `formatter`.
   → verify: `nix flake show` lists every output, and
   `nix eval .#nixosModules.default` does not error.
   Traps: `package` must not use `mkPackageOption pkgs "sarala"`, because
   `pkgs.sarala` doesn't exist without the overlay.
5. `checks/vm.nix` (new) and `flake.nix` checks: `sarala`, `frontend`,
   `home-manager` (via `home-manager.lib.homeManagerConfiguration`, with a
   `runCommand` that greps `home-files/.config/mimeapps.list` for
   `sarala.desktop`) and `vm` (x86_64 only).
   → verify: `nix flake check -L` passes locally, VM test included.
   Traps: the VM needs `virtualisation.memorySize = 2048` or more. Use xserver
   plus icewm/xfwm-free `services.xserver.windowManager.icewm`, autologin,
   and `machine.wait_for_window("Sarala")` with a long timeout.
6. `.github/workflows/ci.yml` (new). Two jobs:
   - `x86_64` on `ubuntu-latest`: a step running
     `echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' | sudo tee /etc/udev/rules.d/99-kvm.rules && sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=kvm`,
     then `DeterminateSystems/nix-installer-action@main`,
     `DeterminateSystems/magic-nix-cache-action@main`, `nix flake check -L`.
   - `aarch64` on `ubuntu-24.04-arm`: the same Nix setup, then
     `nix build -L .#checks.aarch64-linux.{sarala,frontend,home-manager}` and
     `nix eval .#packages.aarch64-linux.sarala.override… ` (or the x86 job
     evaluates `(sarala.override { withVoice = false; }).drvPath`).
   Both run on `push: main` and `pull_request`. Job names are fixed, because
   they are required checks.
   → verify: `actionlint` passes (`nix run nixpkgs#actionlint`).
7. `.github/workflows/update.yml` (new): `schedule: '17 4 * * *'` plus
   `workflow_dispatch`. Steps: checkout with `token: ${{ secrets.UPDATE_TOKEN }}`,
   the Nix setup, `nix flake update`,
   `nix run nixpkgs#nix-update -- --flake sarala`, then
   `peter-evans/create-pull-request@v7` (branch `auto/update`, token
   `UPDATE_TOKEN`, title `chore: update sarala and inputs`), then
   `gh pr merge --auto --squash` on the PR number it returns.
   `permissions: contents: write, pull-requests: write`.
   → verify: `actionlint` passes.
8. Claude, not the coder: `README.md` (install via flake for NixOS and HM,
   options table, how updates work), `LICENSE` (MIT), `nix fmt`, then
   commit and push. Repo setup:
   `gh secret set UPDATE_TOKEN -R olafkfreund/sarala-nix < /run/agenix/api-github-token`
   (never echoed). Check the token's scopes include `repo` and `workflow` via
   `gh api -i user` response headers (headers only). Then
   `gh repo edit --enable-auto-merge --delete-branch-on-merge`.
   → verify: `gh secret list` shows UPDATE_TOKEN.
9. Open the PR (links intent, spec and plan; says which steps the coder did).
   Wait for CI green and fix as needed. Once the job names exist, add branch
   protection on `main` requiring `x86_64` and `aarch64`. Run the Opus review,
   then the Codex and agy reviews (reviewers above) of `git diff main...`, and
   address the findings. Merge.
   → verify: CI green on the PR and on `main`.
10. Run `gh workflow run update.yml` on main. → verify: either no PR (nothing
    changed) or an `auto/update` PR that goes green and auto-merges.

## Tests

- `nix flake check -L` (local and CI): package, frontend unit tests, HM
  install with mimeapps, and a NixOS VM that launches Sarala.
- `nix build .#checks.aarch64-linux.*` in CI (no VM test on aarch64).
- `nix run .#sarala` locally shows the editor window.
- The update workflow by dispatch, as in step 10.

## Rollback

A new standalone repo: nothing deployed to any host. Disable `update.yml`
(`gh workflow disable update.yml`) to stop the automation, revert the merge
commit, or archive the repo. Remove the secret with
`gh secret delete UPDATE_TOKEN -R olafkfreund/sarala-nix`.

## Deviations during implementation

- Steps 1–8 were implemented by Claude (Opus), not the `coder` agent: the
  agent stalled for 19 min without writing a file (likely blocked on a
  permission prompt in its pane) and was stopped.
- `formatter` is `nixfmt-tree`, not `nixfmt`: `nix fmt` runs the formatter
  with no arguments, and bare `nixfmt` then waits on stdin forever.
- The aarch64 CI job runs `nix flake check -L` instead of naming the checks:
  aarch64 `checks` already omit `vm`, so the result is the same set.
- The `withVoice = false` evaluation is a check of its own
  (`checks.no-voice-eval`, a text file holding the drvPath) rather than a
  CI-only `nix eval` step, so it also runs locally.
- Review fixes (Opus/Codex/agy, step 9): `update.yml` no longer persists
  UPDATE_TOKEN in `.git/config`; `GITHUB_TOKEN` is read-only and authenticates
  `nix flake update`/`nix-update` against API rate limits; a failed `nix-update`
  only warns so the input bump still lands; auto-merge runs only when the PR
  was created or updated. CI uses `udevadm trigger --settle`. Checks also
  assert `text/x-markdown`, and the VM test asserts the process is still
  alive after start-up. README documents `inputs.nixpkgs.follows`.
