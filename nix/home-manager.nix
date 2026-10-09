{ config, lib, pkgs, ... }:
let cfg = config.programs.iris;
in {
  options.programs.iris = {
    enable = lib.mkEnableOption "Iris";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix {}";
      description = "The immutable signed Iris release to install.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.isDarwin;
      message = "programs.iris requires macOS; the web development shell also supports Linux.";
    }];
    home.packages = [ cfg.package ];
  };
}
