{ config, lib, pkgs, ... }:
let
  cfg = config.programs.life-ui;
  command = phase: ''
    /usr/bin/sudo --user=${lib.escapeShellArg config.homebrew.user} --set-home \
      /usr/bin/env PATH=${lib.makeBinPath [ pkgs.jq ]}:/usr/bin:/bin:/usr/sbin:/sbin \
      ${pkgs.bash}/bin/bash ${../scripts/migrate-homebrew.sh} ${phase} \
      ${lib.escapeShellArg config.homebrew.prefix} \
      ${lib.escapeShellArg "${cfg.package}/Applications/LifeUI.app"} \
      '/Applications/Nix Apps/LifeUI.app' ${if cfg.migrateFromHomebrew then "1" else "0"} || exit $?
  '';
in {
  options.programs.life-ui = {
    enable = lib.mkEnableOption "LifeUI";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {};
      description = "Signed release package; its bundle is published without modification.";
    };
    migrateFromHomebrew = lib.mkEnableOption "the exact app-only, non-zap cask migration";
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    assertions = [
      {
        assertion = !(lib.any (cask: lib.last (lib.splitString "/" cask.name) == "life-ui") config.homebrew.casks);
        message = "Remove the LifeUI cask declaration when enabling its Nix module.";
      }
      {
        assertion = !cfg.migrateFromHomebrew || config.homebrew.enable;
        message = "LifeUI cask migration requires the Homebrew module.";
      }
    ];
    # Checks run before applications are copied. A homebrew hook alone is too late.
    system.checks.text = command "preflight";
    system.activationScripts.homebrew.text = lib.mkBefore (command "migrate");
  };
}
