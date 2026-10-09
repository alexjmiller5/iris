{
  description = "Iris signed macOS application and web development tools";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/2bd3427b41d10b8318383195efe502ed1baca6cd";
  # Bun matches packageManager/CI. App packaging keeps the last Intel-capable
  # stable branch; the current toolchain no longer supports Intel macOS.
  inputs.tooling.url = "github:NixOS/nixpkgs/8d5d270900d3fc75655ea2d9d248b234f6631439";

  outputs = { nixpkgs, tooling, ... }:
    let
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
      darwinSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forSystems = names: f: nixpkgs.lib.genAttrs names (system: f nixpkgs.legacyPackages.${system});
      homeModule = import ./nix/home-manager.nix;
    in {
      packages = forSystems darwinSystems (pkgs:
        let package = pkgs.callPackage ./nix/package.nix {}; in {
          default = package;
          iris = package;
        });
      darwinModules.default = import ./nix/darwin.nix;
      darwinModules.iris = import ./nix/darwin.nix;
      homeModules.default = homeModule;
      homeModules.iris = homeModule;
      devShells = nixpkgs.lib.genAttrs systems (system:
        let pkgs = tooling.legacyPackages.${system}; in {
        default = assert pkgs.bun.version == "1.4.2"; pkgs.mkShellNoCC {
          packages = [ pkgs.bun pkgs.just pkgs.ripgrep pkgs.git ];
        };
      });
      checks = forSystems darwinSystems (pkgs: import ./nix/checks.nix {
        inherit pkgs homeModule;
        package = pkgs.callPackage ./nix/package.nix {};
      });
    };
}
