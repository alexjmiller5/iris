set shell := ["bash", "-euc"]
swift_cache := env_var_or_default("LIFE_UI_SWIFT_CACHE", env_var("HOME") + "/Library/Developer/life-ui-swift")

dev:
    bun run dev

test:
    bun run test
    swift test --no-parallel --package-path packages/LifeKit --scratch-path "{{swift_cache}}"

check:
    bun run check
    bun run --cwd apps/web lint
    bun scripts/check-a11y.ts
    just --justfile apps/macos/justfile check
    just --justfile apps/ios/justfile check

build:
    bun run build
    just --justfile apps/macos/justfile build
    just --justfile apps/ios/justfile check

fmt:
    bun run --cwd apps/web fmt
    rg --files -0 packages/LifeKit/Sources packages/LifeKit/Tests apps/ios/App apps/macos/App -g '*.swift' -g '!**/Generated/**' | xargs -0 xcrun swift-format format --in-place

# --- project-specific ---
gen:
    just --justfile apps/macos/justfile gen
    just --justfile apps/ios/justfile gen
