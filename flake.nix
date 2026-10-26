{
  description = "Sarala Markdown editor: package, NixOS and Home Manager modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Only used by checks.home-manager; the HM module itself needs nothing from it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        sarala = pkgs.callPackage ./package.nix { };
        default = sarala;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.sarala;
        };
      });

      overlays.default = final: _prev: {
        sarala = final.callPackage ./package.nix { };
      };

      nixosModules = rec {
        sarala = import ./modules/nixos.nix self;
        default = sarala;
      };

      homeManagerModules = rec {
        sarala = import ./modules/home.nix self;
        default = sarala;
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      checks = forAllSystems (
        pkgs:
        let
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) sarala;
          home =
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                self.homeManagerModules.default
                {
                  home = {
                    username = "alice";
                    homeDirectory = "/home/alice";
                    stateVersion = "25.11";
                  };
                  programs.sarala = {
                    enable = true;
                    defaultForMarkdown = true;
                  };
                }
              ];
            }).activationPackage;
        in
        {
          inherit sarala;
          frontend = sarala.tests.frontend;
          # withVoice = false is evaluated, not built: a second LTO build per run is not worth it.
          no-voice-eval = pkgs.writeText "no-voice-drv" (sarala.override { withVoice = false; }).drvPath;
          home-manager = pkgs.runCommand "sarala-hm-check" { } ''
            grep -q 'text/markdown=sarala.desktop' ${home}/home-files/.config/mimeapps.list
            test -e ${home}/home-path/share/applications/sarala.desktop
            touch $out
          '';
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
          vm = import ./checks/vm.nix { inherit pkgs self; };
        }
      );
    };
}
