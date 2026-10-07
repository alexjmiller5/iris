# Nix packaging

`nix develop` supplies Bun 1.4.2, just, ripgrep and Git on Apple Silicon macOS
and aarch64/x86_64 Linux. It does not install tools globally. Use the repository's locked
dependencies with `bun install --frozen-lockfile`. Xcode is a separate native
development prerequisite; the Nix app package does not build Swift.

## Signed macOS app

`nix build .#life-ui` produces `result/Applications/LifeUI.app`. The default
package pins the published universal **0.4.0** ZIP by SHA-256. It extracts and
copies the bundle without fixup, stripping, patching or re-signing. The embedded
profile, entitlements and stapled notarization ticket stay with the app.
App packages support Apple Silicon and Intel macOS. Their Nixpkgs 26.05 pin
retains Intel support; the separately pinned development toolchain matches CI's
Bun version and has no Intel macOS shell.

The flake exports `homeModules.life-ui` (also `homeModules.default`):

```nix
{
  inputs.life-ui.url = "github:alexjmiller5/life-ui";
  # In your Home Manager configuration:
  # imports = [ inputs.life-ui.homeModules.life-ui ];
  # programs.life-ui.enable = true;
}
```

The module adds the package to `home.packages`; use Home Manager's macOS
application linking support to expose it in Applications. Runtime enrollment,
credentials and preferences remain in the app's supported interface and secure
storage. No token or personal configuration belongs in this flake.

To select another **published, signed** archive, override all release inputs:

```nix
programs.life-ui = {
  enable = true;
  package = inputs.life-ui.packages.${pkgs.stdenv.hostPlatform.system}.life-ui.override {
    version = "<published-version>";
    url = "https://<release-host>/<signed-release>.zip";
    hash = "sha256-<archive-hash>";
  };
};
```

The ZIP must contain `LifeUI.app` at its root. A different hash fails closed.
The default URL follows the version when only version/hash are overridden.
Pin this flake in the consuming flake lock; it never follows the latest release
automatically. Choose one installation owner when adopting the module. An
existing cask declaration is not changed by this repository.

## Verification

```sh
nix flake check --no-write-lock-file
nix flake check --all-systems --no-build --no-write-lock-file
nix build .#life-ui --no-link --print-out-paths
```

The checks exercise module disabled/default/custom-package behavior, generic
release overrides, and extraction of a synthetic bundle containing an executable,
profile, ticket, signature resource and symlink. They compare every file's bytes
and require the executable bit and symlink target to survive.

For the real output path printed by `nix build`, run:

```sh
codesign --verify --deep --strict '<output>/Applications/LifeUI.app'
xcrun stapler validate '<output>/Applications/LifeUI.app'
spctl --assess --type execute --verbose=2 '<output>/Applications/LifeUI.app'
```

Verification on macOS, 2026-10-07 UTC, against published 0.4.0:

| Check | Result |
| --- | --- |
| Archive SHA-256 | `564b6343a5a25bfe6918cf0f26901ef53e05aa3016963ad68c74f959263cf774` |
| Nix build and synthetic preservation/module checks | Pass |
| All source/output file hashes, symlink targets, executable bits | Identical |
| arm64 and x86_64 entitlements and designated requirements | Identical |
| Strict signature, stapled ticket, Gatekeeper | Pass; Notarized Developer ID |

The [0.4.0 release CI](https://github.com/alexjmiller5/life-ui/actions/runs/37546796203)
also records `Data Protection Keychain create/read/update/delete passed` from
the separately signed production-adapter probe with a unique synthetic service.
That is release evidence, not a fresh local Keychain probe of the Nix output.
No user credentials were accessed and no application was installed for these
packaging checks. Installed-app launch, enrollment and fresh Nix-output Keychain
acceptance remain separate and unverified. A future release must retain the
existing release CI Keychain gate; byte/signature preservation alone is not a
substitute for it.
