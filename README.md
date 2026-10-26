# sarala-nix

Nix flake for [Sarala](https://github.com/solancer/sarala), a WYSIWYG Markdown
editor, built from source, with NixOS and Home Manager modules.

- Linux only: `x86_64-linux` and `aarch64-linux`.
- Tracks the latest Sarala release; a daily job updates it (see [Updates](#updates)).

## Before you start

- **Flakes enabled.** In NixOS:
  `nix.settings.experimental-features = [ "nix-command" "flakes" ];`
  Elsewhere, add `experimental-features = nix-command flakes` to `~/.config/nix/nix.conf`.
- **The first install compiles Sarala from source.** There is no binary cache,
  so expect 20–40 minutes and a few GB of disk the first time (Rust with LTO,
  plus the speech engine when voice typing is on). Rebuilds only happen when
  Sarala or nixpkgs change. Setting `withVoice = false` makes the build faster.
- **Voice typing on x86_64** needs a CPU with AVX2, FMA and F16C (Intel
  Haswell / AMD Zen or newer), like upstream's own builds.

## Try it without installing

```sh
nix run github:olafkfreund/sarala-nix
```

## Install

Pick one of the methods below.

### NixOS module

Add the input and the module to your existing system flake:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sarala.url = "github:olafkfreund/sarala-nix";
  };

  outputs = { nixpkgs, sarala, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        sarala.nixosModules.default
        {
          programs.sarala = {
            enable = true;
            defaultForMarkdown = true; # optional
          };
        }
      ];
    };
  };
}
```

Then rebuild:

```sh
sudo nixos-rebuild switch --flake .#myhost
```

### Home Manager module

The module is `sarala.homeManagerModules.default`. How you load it depends on
how you run Home Manager.

**Home Manager inside NixOS** (`home-manager.nixosModules.home-manager`):

```nix
# in nixosSystem { modules = [ ... ]; }
home-manager.nixosModules.home-manager
{
  home-manager.users.alice = {
    imports = [ sarala.homeManagerModules.default ];
    programs.sarala.enable = true;
  };
}
```

**Standalone Home Manager:**

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sarala.url = "github:olafkfreund/sarala-nix";
  };

  outputs = { nixpkgs, home-manager, sarala, ... }: {
    homeConfigurations.alice = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        sarala.homeManagerModules.default
        {
          home.username = "alice";
          home.homeDirectory = "/home/alice";
          home.stateVersion = "25.11";
          programs.sarala.enable = true;
        }
      ];
    };
  };
}
```

```sh
home-manager switch --flake .#alice
```

### Without the modules

Into your user profile:

```sh
nix profile install github:olafkfreund/sarala-nix
```

Or through the overlay, which adds `pkgs.sarala`:

```nix
nixpkgs.overlays = [ sarala.overlays.default ];
environment.systemPackages = [ pkgs.sarala ];
# without voice typing:
# environment.systemPackages = [ (pkgs.sarala.override { withVoice = false; }) ];
```

## Options

Both modules have the same options under `programs.sarala`:

| Option | Default | Description |
| --- | --- | --- |
| `enable` | `false` | Install Sarala, with its desktop entry; "Open With" works for `.md` files. |
| `withVoice` | `true` | Build with offline voice typing (ggml + OpenBLAS). Ignored if `package` is set. |
| `package` | this flake's build | The package to install. Set it to use your own build or an overlay's `pkgs.sarala`. |
| `defaultForMarkdown` | `false` | Make Sarala the default app for `text/markdown` and `text/x-markdown`. |

Sarala keeps its settings (theme, AI assistant, voice model, etc.) in the app
itself; they are not managed by Nix.

## Check it works

```sh
command -v sarala                      # on PATH
xdg-mime query default text/markdown   # sarala.desktop, if defaultForMarkdown = true
```

Sarala also appears in your application launcher.

## Sharing inputs (optional)

By default this flake builds against its own pinned nixpkgs. To build against
yours (one nixpkgs in your system, and graphics libraries that match your
drivers), add `follows` to the input:

```nix
sarala = {
  url = "github:olafkfreund/sarala-nix";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager"; # only if you have a home-manager input
};
```

Your nixpkgs must be a recent nixos-unstable (it needs pnpm 11 and
`fetchPnpmDeps` with `fetcherVersion = 5`); on an older or stable nixpkgs,
leave `nixpkgs.follows` out. The `home-manager` input is only used by this
repo's checks, so following it just avoids a second copy in your lock file.

## Updating

Sarala updates when you update this input:

```sh
nix flake update sarala
sudo nixos-rebuild switch --flake .#myhost   # or: home-manager switch --flake .#alice
```

Sarala's in-app updater stays switched off: it only updates installs owned by
dpkg, rpm or an AppImage, so a Nix install always updates through Nix. The
build fails if upstream ever removes that check.

## Troubleshooting

- **Blank or white window** (some GPU / driver / VM setups): start Sarala with
  `WEBKIT_DISABLE_DMABUF_RENDERER=1 sarala`. If that fixes it, set the variable
  for your session (`environment.sessionVariables` or `home.sessionVariables`).
- **Voice model download fails**: the model comes from Hugging Face on first use;
  check network access. `curl` is already on Sarala's `PATH`.
- **The build takes a long time**: expected on the first install, see
  [Before you start](#before-you-start).

## Updates

`update.yml` runs every day at 04:17 UTC. It updates `flake.lock` and, when
there is a new Sarala release, the version and hashes (via `nix-update`). It
opens a PR that merges itself once CI passes. CI builds the package and runs
upstream's unit tests, a Home Manager install and, on x86_64, a NixOS VM test
that launches Sarala.

## Development

```sh
nix build .#sarala        # build the package -> ./result
nix flake check -L        # all checks, including the NixOS VM test (x86_64, needs KVM)
nix fmt                   # format the Nix files
```

Repository layout: `package.nix` (the derivation), `modules/` (NixOS and Home
Manager), `checks/vm.nix` (VM test), `.github/workflows/` (CI and daily updates).

### Running your own fork

The daily updater needs, in the repo settings:

- "Allow auto-merge" turned on;
- `main` protected, with the `x86_64` and `aarch64` checks required;
- an `UPDATE_TOKEN` secret: a fine-grained token for this repo with read/write
  on contents, pull requests and workflows. PRs opened with the default
  `GITHUB_TOKEN` do not trigger CI.

## License

The packaging in this repo is MIT. Sarala itself is GPL-3.0-or-later.
