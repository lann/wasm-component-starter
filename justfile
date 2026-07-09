# Root justfile: build, test, format, and lint every example in the repo.
#
# Each component and app has its own justfile; these recipes fan out to them so
# the whole repo can be driven from one place. Run `just` to see the recipes,
# or `just ci` to run every check (the same set the GitHub Actions workflow runs).

# Standalone Rust component crates (each has its own Cargo.toml and a
# .cargo/config.toml pinning its wasm target). There is no Cargo workspace.
rust_crates := "examples/components/cli-archive-maker examples/components/gzip-compressor examples/components/metadata-printer examples/components/tar-archiver"

# Runnable apps that compose components and expose build/test/clean recipes.
apps := "examples/apps/cli-metadata-printer examples/apps/cli-tgz-maker examples/apps/browser-tgz-maker"

# Show the available recipes.
default:
    @just --justfile {{ justfile() }} --list

# Install the Component Model CLI toolchain (requires Rust, Node, and Python).
setup:
    bash scripts/install-tools.sh

# Build every component and app.
build: build-cli-apps build-browser

# Build the wasmtime-driven CLI apps (and the components they compose).
build-cli-apps:
    just --justfile examples/apps/cli-metadata-printer/justfile build
    just --justfile examples/apps/cli-tgz-maker/justfile build

# Build the browser app.
build-browser:
    just --justfile examples/apps/browser-tgz-maker/justfile build

# Run every example's test suite.
test: test-cli-apps test-browser

# Run the wasmtime-driven CLI app tests (require wasmtime 46+ for WASI 0.3.0).
test-cli-apps:
    just --justfile examples/apps/cli-metadata-printer/justfile test
    just --justfile examples/apps/cli-tgz-maker/justfile test

# Run the browser app test under Node JSPI.
test-browser:
    just --justfile examples/apps/browser-tgz-maker/justfile test

# Format all Rust component crates.
fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    for c in {{ rust_crates }}; do
        echo "== fmt $c =="
        ( cd "$c" && cargo fmt )
    done

# Check Rust formatting without writing changes (fails if any file is unformatted).
fmt-check:
    #!/usr/bin/env bash
    set -euo pipefail
    for c in {{ rust_crates }}; do
        echo "== fmt --check $c =="
        ( cd "$c" && cargo fmt --check )
    done

# Lint all Rust component crates with clippy (warnings are treated as errors).
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    for c in {{ rust_crates }}; do
        echo "== clippy $c =="
        ( cd "$c" && cargo clippy --release -- -D warnings )
    done

# Remove build artifacts from every app and component.
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    for a in {{ apps }}; do
        echo "== clean $a =="
        just --justfile "$a/justfile" clean
    done

# Run the full set of checks: formatting, lint, and tests (which build everything).
ci: fmt-check lint test
