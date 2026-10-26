# sarala-nix

Nix flake for [Sarala](https://github.com/solancer/sarala), a WYSIWYG Markdown
editor, built from source, with NixOS and Home Manager modules. Linux only
(x86_64 and aarch64).

## Try it

```sh
nix run github:olafkfreund/sarala-nix
```

## NixOS

```nix
{
  inputs.sarala.url = "github:olafkfreund/sarala-nix";

  outputs = { nixpkgs, sarala, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        sarala.nixosModules.default
        { programs.sarala.enable = true; }
      ];
    };
  };
}
```

## Home Manager

```nix
{
  imports = [ inputs.sarala.homeManagerModules.default ];
  programs.sarala = {
    enable = true;
    defaultForMarkdown = true;
  };
}
```

To share your system's nixpkgs (and its graphics drivers) instead of this
flake's lock, add `inputs.sarala.inputs.nixpkgs.follows = "nixpkgs";`. That
needs a recent nixos-unstable (pnpm 11 and `fetchPnpmDeps` fetcherVersion 5);
on older nixpkgs, leave it out.

If you use Home Manager as a flake as well, add
`inputs.sarala.inputs.home-manager.follows = "home-manager";` (the input is
only used by this repo's checks).

## Options

Both modules have the same options under `programs.sarala`:

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Install Sarala, with its desktop entry and Markdown file associations. |
| `withVoice` | `true` | Build with offline voice typing (ggml + OpenBLAS). Ignored if `package` is set. |
| `package` | this flake's build | The package to install. |
| `defaultForMarkdown` | `false` | Make Sarala the default app for `text/markdown` and `text/x-markdown`. |

Sarala keeps its own settings in the app; they are not managed by Nix. Without
the modules, use `packages.<system>.sarala` or `overlays.default`.

Notes:

- Voice typing downloads its speech model from Hugging Face the first time you
  turn it on. On x86_64 it needs a CPU with AVX2, FMA and F16C, like upstream.
- Sarala's in-app updater stays off: it only updates installs owned by
  dpkg, rpm or an AppImage. The build fails if upstream removes that check.

## Updates

`update.yml` runs every day. It updates `flake.lock` and, when there is a
new Sarala release, the version and hashes (via `nix-update`). It opens a PR
that merges itself once CI passes. CI builds the package and runs upstream's
unit tests, a Home Manager install and, on x86_64, a NixOS VM test that
launches Sarala.

The repo needs: "Allow auto-merge" turned on, `main` protected with the
`x86_64` and `aarch64` checks required, and an `UPDATE_TOKEN` secret (a
token with `repo` and `workflow` scope; PRs opened with `GITHUB_TOKEN` do not
trigger CI).

## License

The packaging in this repo is MIT. Sarala itself is GPL-3.0-or-later.
