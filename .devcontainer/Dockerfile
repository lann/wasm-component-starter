# syntax=docker/dockerfile:1

# Base image ships a managed Rust toolchain (rustup + cargo) and a non-root
# `vscode` user. It already sets CARGO_HOME=/usr/local/cargo and
# RUSTUP_HOME=/usr/local/rustup, keeping the registry cache and toolchain
# outside the workspace bind mount. cargo-binstall drops binaries into
# $CARGO_HOME/bin, which is already on PATH for every user.
FROM mcr.microsoft.com/devcontainers/rust:1-bookworm

# --- Toolchain knobs ---------------------------------------------------------
# componentize-py is a Python wheel (installed via pipx), so it is pinned here.
# The Rust component-model CLIs are installed at their latest release by
# cargo-binstall below.
ARG COMPONENTIZE_PY_VERSION=0.23.0

# Rust targets for component authoring: the stable WASIp2 sysroot plus bare
# metal for advanced/no-WASI use cases.
ARG RUST_WASM_TARGETS="wasm32-wasip2 wasm32-unknown-unknown"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- pipx (for componentize-py) ----------------------------------------------
RUN <<'EOF'
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl pipx
rm -rf /var/lib/apt/lists/*
EOF

# --- Component Model CLI tooling via cargo-binstall --------------------------
# cargo-binstall fetches prebuilt release binaries (falling back to a source
# build only if no artifact is published), which keeps image builds fast and
# avoids compiling these tools from scratch. Each tool resolves to its latest
# crates.io release:
#   wasmtime-cli      -> canonical host runtime (`wasmtime`)
#   wasm-tools        -> low-level inspection/manipulation suite
#   wit-bindgen-cli   -> guest-side binding generator (`wit-bindgen`)
#   wac-cli           -> component linker / composer (`wac`)
#   just              -> command runner used by the examples' `justfile`s
RUN <<'EOF'
set -euxo pipefail
curl -L --proto '=https' --tlsv1.2 -sSf \
  https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
cargo binstall --no-confirm \
  wasmtime-cli \
  wasm-tools \
  wit-bindgen-cli \
  wac-cli \
  just
EOF

# --- Rust wasm targets -------------------------------------------------------
RUN rustup target add ${RUST_WASM_TARGETS}

# --- componentize-py (Python -> component) -----------------------------------
# Installed via pipx into /usr/local/bin so the CLI is on PATH for every user.
# The wheel bundles its own CPython runtime, so no separate Python is required.
ENV PIPX_HOME=/usr/local/pipx \
    PIPX_BIN_DIR=/usr/local/bin
RUN pipx install "componentize-py==${COMPONENTIZE_PY_VERSION}"
