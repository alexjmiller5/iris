{ config, lib, pkgs, ... }:
let cfg = config.programs.life-ui;
in {
  options.programs.life-ui = {
    enable = lib.mkEnableOption "Life UI";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix {}";
      description = "The immutable signed Life UI release to install.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.isDarwin;
      message = "programs.life-ui requires macOS; the web development shell also supports Linux.";
    }];
    home.packages = [ cfg.package ];
  };
}
