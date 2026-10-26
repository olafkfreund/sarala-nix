self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.sarala;
  mimeTypes = [
    "text/markdown"
    "text/x-markdown"
  ];
in
{
  options.programs.sarala = {
    enable = lib.mkEnableOption "Sarala, a WYSIWYG Markdown editor";
    withVoice = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Build the default package with offline voice typing. Ignored when `package` is set.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.sarala.override {
        inherit (cfg) withVoice;
      };
      defaultText = lib.literalExpression "sarala-nix.packages.\${system}.sarala";
      description = "The Sarala package to install.";
    };
    defaultForMarkdown = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Make Sarala the default application for Markdown files.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    xdg.mime.defaultApplications = lib.mkIf cfg.defaultForMarkdown (
      lib.genAttrs mimeTypes (_: "sarala.desktop")
    );
  };
}
