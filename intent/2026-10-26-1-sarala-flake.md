---
status: draft
issue: 1
author: olafkfreund
---

# Intent: Package Sarala for NixOS and Home Manager

## Problem

Sarala (https://github.com/solancer/sarala, v1.3.3, GPL-3.0-or-later) is a
Tauri 2 WYSIWYG Markdown editor. It is not in nixpkgs. Its Linux builds are
Snap, .deb, .rpm and AppImage, and none of those installs declaratively on
NixOS. Its built-in auto-updater rewrites the installed binary, which cannot
work in the read-only Nix store.

## Proposed outcome

- A public flake, `github:olafkfreund/sarala-nix`, exposes `packages.x86_64-linux.sarala`
  (also the default package), plus an overlay, a NixOS module and a Home Manager module.
- `programs.sarala.enable = true;` in either module installs Sarala with a
  desktop entry and the `.md`/`.markdown`/`.mdown` file associations.
- `nix run github:olafkfreund/sarala-nix` launches the editor.
- CI builds the package, runs the upstream unit tests and checks that both
  modules evaluate and install, on every push and PR.
- A daily job finds a new upstream release, bumps the version and hashes,
  builds and tests it, and opens a PR (auto-merged when green).

## Affected users and systems

- NixOS users on x86_64-linux, with or without Home Manager.
- New repo `olafkfreund/sarala-nix`; no changes upstream.

## Constraints

- Build from source; no repackaged prebuilt binaries unless the spec shows
  source builds are not workable.
- The in-app updater must be disabled or neutered; Nix owns updates.
- No network access during the build (fixed-output hashes for pnpm and Cargo deps).
- The daily job may only update the package when build and tests pass.
- Options only where they change behaviour. "All options available" means
  every real knob Sarala has, not invented ones.

## Open questions

1. Platforms: x86_64-linux only, or also aarch64-linux and darwin? (Proposal:
   x86_64-linux and aarch64-linux; darwin is served by upstream's Homebrew cask.)
2. Voice typing builds ggml from C++ (needs CMake, slower build). Ship it on by
   default with a `voice` toggle, or off by default? (Proposal: on, with `withVoice` toggle.)
3. Sarala keeps its settings in its own app store, not a plain config file. Should
   the modules manage settings declaratively, or only install and associate files?
   (Proposal: install + file associations + `package` + `withVoice`; declarative
   settings only if the spec finds a stable file format.)
4. Daily updater: open a PR for review, or auto-merge when CI is green?
   (Proposal: auto-merge when green.)
5. Codex and agy (`second-opinion` skill) review the spec and the final diff.
   OK to send the upstream source and our Nix code to OpenAI and Google for that?
6. License for the packaging code: MIT? (The packaged app stays GPL-3.0.)
