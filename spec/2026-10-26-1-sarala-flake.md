---
status: approved
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
checks/vm.nix        NixOS VM test
.github/workflows/   ci.yml, update.yml
README.md, LICENSE (MIT)
```

Flake outputs, per system in `[x86_64-linux aarch64-linux]`:
`packages.{sarala,default}`, `apps.default`, `checks.*` and `formatter` (nixfmt).
System-independent: `overlays.default`, `nixosModules.{sarala,default}` and
`homeManagerModules.{sarala,default}`. No flake-utils or flake-parts: a
`genAttrs` over two systems is a few lines. `home-manager` is a second input,
used only by `checks.home-manager`. The HM module itself needs nothing from it
(see Risks).

### Package (`package.nix`)

`rustPlatform.buildRustPackage` with the nixpkgs Tauri hooks:

- `src = fetchFromGitHub { owner = "solancer"; repo = "sarala"; tag = "v${version}"; hash; }`
- `cargoRoot = "src-tauri"; buildAndTestSubdir = "src-tauri"; cargoHash`
  (vendored from upstream's `Cargo.lock`).
- Frontend deps: `pnpmDeps = fetchPnpmDeps { inherit pname version src; pnpm = pnpm_11; fetcherVersion = 5; hash; }`.
  nixpkgs requires a `fetcherVersion` of at least 3; 5 is current. Upstream pins
  `pnpm@11.10.0`, while nixpkgs `pnpm_11` is 11.27. Both read lockfile v9.
- `nativeBuildInputs`: `cargo-tauri.hook pnpmConfigHook pnpm_11 nodejs_22
  pkg-config wrapGAppsHook3`, plus `cmake` when `withVoice`.
- `buildInputs`: `webkitgtk_4_1 gtk3 librsvg libayatana-appindicator
  glib-networking wayland dbus` (wayland because rfd's xdg-portal backend links
  libwayland-client; dbus via tao), plus `alsa-lib openblas` when `withVoice`.
  Plan step 1 confirms the list: drop what the build does not need, and add
  what pkg-config reports missing.
- Voice: `buildNoDefaultFeatures = !withVoice; buildFeatures = lib.optional withVoice "voice";`
  (`buildRustPackage` maps these to `cargoBuildFeatures`, which the Tauri hook
  reads). `env.TRANSCRIBE_CMAKE_ARGS` is built per architecture:
  - always `-DGGML_NATIVE=OFF -DBLA_VENDOR=OpenBLAS`
  - x86_64 also `-DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_AVX512=OFF`,
    upstream's release flags. Upstream's runtime guard (voice/mod.rs:167)
    already refuses pre-AVX2 CPUs, so this costs no CPUs that would have
    worked. `GGML_NATIVE=OFF` is required: a native build would bake the
    builder's CPU into a cached binary that crashes with SIGILL elsewhere.
  - aarch64: no extra flags (ggml's generic ARMv8 defaults).

  ggml's own BLAS is forced off inside transcribe-cpp-sys (CMakeLists.txt:282).
  The speech decoder links system BLAS through `TRANSCRIBE_USE_SYSTEM_BLAS`,
  which defaults to ON. Upstream's CI fails a release that does not link
  `libopenblas.so.0`, because without it decoding falls back to a slow scalar
  loop. We pass `openblas` and check its presence with
  `postInstall`: `patchelf --print-needed $out/bin/sarala | grep -q libopenblas`.
- Tauri: `tauriBuildFlags = [ "--config" ''{"bundle":{"createUpdaterArtifacts":false}}'' ]`
  so no updater signing key is required. The hook's default Linux bundle is
  `deb`, which yields the binary, desktop file and icons.
- `postInstall`: rename `share/applications/Sarala.desktop` to `sarala.desktop`
  (Tauri names it after productName; upstream's snap does the same rename).
- Runtime tools: `preFixup` adds `curl` (voice model download, voice/mod.rs:259)
  and `xdg-utils` (reveal in folder, main.rs:619) to the wrapper's `PATH`.
- Updater: no patch. Upstream's `can_self_update()` (main.rs:497) returns
  false when the binary isn't owned by dpkg, rpm or an AppImage. `runCheck()`
  (updater.ts:100) then skips the update check. A Nix build takes that path.
  Guard: `postPatch` runs `grep -q 'fn can_self_update' src-tauri/src/main.rs`,
  so if upstream removes the gate, the build (and the daily bump) fails
  instead of shipping a self-updating binary.
- Tests: `doCheck = false` for cargo; upstream has no Rust tests worth
  rebuilding for. A separate `frontendTests` derivation runs `pnpm test`
  (11 jsdom suites) against the same `pnpmDeps`, exposed as
  `passthru.tests.frontend` and wired into `checks`.
- `meta`: GPL-3.0-or-later, `mainProgram = "sarala"`, `platforms` = the two systems.

### Modules

Both modules expose the same options, which cover everything Sarala lets a
package manager configure:

```nix
programs.sarala = {
  enable = mkEnableOption "Sarala Markdown editor";
  withVoice = mkOption { type = bool; default = true; };
  package = mkOption {
    type = package;
    default = self.packages.${pkgs.stdenv.hostPlatform.system}.sarala.override { inherit (cfg) withVoice; };
    defaultText = literalExpression "sarala-nix.packages.\${system}.sarala";
  };
  defaultForMarkdown = mkOption { type = bool; default = false; };
};
```

- `withVoice` only shapes the default `package`. A user-supplied package is
  used as is, never overridden.
- The default comes from the flake (each module file is a function of `self`),
  so users do not need the overlay.
- NixOS: `environment.systemPackages`. `defaultForMarkdown` sets
  `xdg.mime.defaultApplications."text/markdown"` and `text/x-markdown` to
  `sarala.desktop`.
- Home Manager: `home.packages`. `defaultForMarkdown` sets
  `xdg.mimeApps.enable = mkDefault true` and the same two defaults.
- The desktop file declares `MimeType=text/markdown;text/x-markdown;`, so
  "Open With" works with `enable` alone.

### Checks (`nix flake check`, x86_64)

- `checks.sarala`: the package itself (`flake check` only evaluates `packages`).
- `checks.frontend`: the upstream unit tests.
- `checks.vm`: a `nixosTest` with `programs.sarala.enable = true` and
  `defaultForMarkdown = true`, X11 and a window manager. It sets
  `WEBKIT_DISABLE_DMABUF_RENDERER=1` and `WEBKIT_DISABLE_COMPOSITING_MODE=1`
  (upstream's flatpak manifest needs the former in VMs), launches `sarala`,
  waits for its window and takes a screenshot. It proves the app installs and
  starts. It does not prove anything about the updater; the `postPatch` guard
  covers that.
- `checks.home-manager`: a `homeManagerConfiguration` with the module and
  `defaultForMarkdown = true`, building its activation package. It asserts the
  generated `mimeapps.list` names `sarala.desktop`.

aarch64 has the same checks minus `vm` (no KVM on ARM runners).

### CI (`.github/workflows/ci.yml`)

Runs on push to main and on PRs:

- **x86_64** on `ubuntu-latest`: a step makes `/dev/kvm` world-accessible
  before the Nix install, so the daemon advertises `kvm nixos-test`. Then
  `nix flake check -L`.
- **aarch64** on `ubuntu-24.04-arm`: `nix build -L .#checks.aarch64-linux.{sarala,frontend,home-manager}`.
- Nix comes from `DeterminateSystems/nix-installer-action`, the cache from
  `DeterminateSystems/magic-nix-cache-action` (free, no secrets). Cachix is
  rejected for now because it needs a token; add it if build time hurts.

The `withVoice = false` variant is not built in CI: it would be a second full
LTO build on every run. Its correctness rests on upstream's
`--no-default-features` path and on evaluation (`nix eval` of its drvPath in
the CI job).

### Daily updater (`.github/workflows/update.yml`)

Runs on `schedule: cron "17 4 * * *"` and `workflow_dispatch`:

1. `nix flake update`, then `nix run nixpkgs#nix-update -- --flake sarala`.
   nix-update reads the latest GitHub release, sets `version`, and recomputes
   the `src` hash, `cargoHash` and `pnpmDeps` hash. No hand-written update script.
2. If the tree changed, `peter-evans/create-pull-request` opens or updates a PR
   on branch `auto/update` (titled with the new Sarala version, if any) and
   enables squash auto-merge.
3. The PR triggers `ci.yml`. Branch protection on `main` requires its jobs, so
   a failing build or test blocks the merge, and the open PR is the alert.

Daily nixpkgs bumps are intended: they are the "does it still build and
install" check, even on days without a Sarala release.

Owner setup, done once and documented in the README: enable "Allow
auto-merge", protect `main` with the CI jobs required, and add a fine-grained
PAT secret `UPDATE_TOKEN` (contents + pull-requests write). PRs opened with
`GITHUB_TOKEN` do not trigger workflows.

## Alternatives rejected

- **Wrap the upstream AppImage/.deb**: breaks the build-from-source
  constraint, ships a binary built against Ubuntu's glibc, and the .deb takes
  the updater's dpkg path. It is a fallback only if the source build proves
  unworkable, and then the spec is revised, not silently swapped.
- **flake-parts / flake-utils**: an extra input to replace a two-system genAttrs.
- **Declarative settings**: Sarala keeps settings in its app store with no
  documented stable format, and writing it would clobber user state.
- **Patching the updater out**: unnecessary given `can_self_update()`, which
  the `postPatch` grep guards.
- **Stub-evaluating the HM module instead of using a home-manager input**
  (agy's suggestion): it would not prove a real HM install. The input is cheap.
  Users who also use HM can add `inputs.sarala.inputs.home-manager.follows`.
- **Building `withVoice = false` in CI** (agy): it doubles the LTO build
  time; evaluation is enough.
- **Patching tauri.conf.json for createUpdaterArtifacts** (agy): `tauriBuildFlags`
  passes `--config` to `cargo tauri build` (hook.sh:64), so no patch is needed.
- **Adding pandoc to PATH**: Sarala's export downloads a static pandoc on demand
  or uses one on `PATH`. Users who want the system pandoc install it; it isn't
  worth a large closure for an optional export.
- **Playwright e2e in CI**: needs browsers and a display; the VM test covers
  "it launches" more cheaply.

## Risks

- **pnpm 11 fetcher**: `fetchPnpmDeps` with pnpm_11 on this lockfile is
  untested. Plan step 1 builds `pnpmDeps` before anything else. If it fails,
  stop and revise the spec.
- **aarch64 voice build**: ggml's generic ARM path and OpenBLAS on aarch64
  are only proven by the ARM CI job.
- **Build time**: Rust fat LTO plus ggml, an estimated 20–40 min cold.
  magic-nix-cache helps after the first run, and the daily lock bump means
  frequent full rebuilds. Acceptable for a free public repo; Cachix later if needed.
- **VM test on hosted runners**: nested KVM is not guaranteed by GitHub. If
  `/dev/kvm` is missing, the x86 job fails loudly rather than skipping. A
  WebKit window under software GL may be slow to map, so use a generous timeout.
- **Pandoc fallback**: an on-demand download of upstream's static pandoc
  should run on NixOS; it's unverified and outside the CI checks.
- **No change to any host**: this repo does not touch the user's machines.

## Verification

- CI is green: `nix flake check` on x86_64 (package, frontend tests, VM test,
  HM check), and the aarch64 build of the package, frontend tests and HM check.
- `nix run github:olafkfreund/sarala-nix` opens a Sarala window locally.
- `ldd $(nix build --print-out-paths)/bin/.sarala-wrapped` lists libopenblas.
- Running `update.yml` by hand produces an `auto/update` PR that goes green
  and auto-merges. It is tested once with `version` set back to 1.3.2 to show
  a real Sarala bump.
- Codex and agy review the final diff.
