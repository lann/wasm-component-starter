#!/usr/bin/env bash
set -euo pipefail

# CARGO_HOME is set by the Rust dev container feature (defaults to
# /usr/local/cargo). Binaries installed by cargo-binstall land in $CARGO_HOME/bin,
# which is already on PATH for every user.
CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"

# componentize-py is a Python wheel (installed via pipx below); pin it here.
COMPONENTIZE_PY_VERSION="0.23.0"
# jco — JavaScript toolchain for Wasm components, installed via npm.
JCO_VERSION="1.21.0"

# The cargo registry cache and target volumes are created owned by root; hand
# them to the dev user so cargo can write to them. The shared cargo bin dir is
# also root-owned (the feature runs as root), so make it writable too before
# cargo-binstall drops binaries into it.
sudo chown -R "$(id -u):$(id -g)" \
  /usr/local/cargo/registry \
  "${containerWorkspaceFolder:-$PWD}/target" 2>/dev/null || true
sudo chgrp -R "$(id -g)" "${CARGO_HOME}/bin" 2>/dev/null || true
sudo chmod -R g+w "${CARGO_HOME}/bin" 2>/dev/null || true

# --- Component Model CLI tooling via cargo-binstall --------------------------
# cargo-binstall fetches prebuilt release binaries (falling back to a source
# build only if no artifact is published), which keeps setup fast and avoids
# compiling these tools from scratch. Each tool resolves to its latest
# crates.io release:
#   wasmtime-cli      -> canonical host runtime (`wasmtime`)
#   wasm-tools        -> low-level inspection/manipulation suite
#   wit-bindgen-cli   -> guest-side binding generator (`wit-bindgen`)
#   wac-cli           -> component linker / composer (`wac`)
#   cargo-component   -> build Rust components with cargo
#   just              -> command runner used by the examples' `justfile`s
if ! command -v cargo-binstall >/dev/null 2>&1; then
  curl -L --proto '=https' --tlsv1.2 -sSf \
    https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
fi
cargo binstall --no-confirm \
  wasmtime-cli \
  wasm-tools \
  wit-bindgen-cli \
  wac-cli \
  cargo-component \
  just

# --- jco (JavaScript -> component) -------------------------------------------
npm install -g "@bytecodealliance/jco@${JCO_VERSION}"

# --- componentize-py (Python -> component) -----------------------------------
# Installed with `pip install --user`; the console script lands in
# ~/.local/bin (already on PATH) and the wheel bundles its own CPython runtime.
python3 -m pip install --user --upgrade "componentize-py==${COMPONENTIZE_PY_VERSION}"

echo ""
echo "Component Model toolchain ready:"
printf '  rustc            %s\n' "$(rustc --version | awk '{print $2}')"
printf '  wasmtime         %s\n' "$(wasmtime --version | awk '{print $2}')"
printf '  wasm-tools       %s\n' "$(wasm-tools --version | awk '{print $2}')"
printf '  wit-bindgen      %s\n' "$(wit-bindgen --version | awk '{print $2}')"
printf '  wac              %s\n' "$(wac --version | awk '{print $2}')"
printf '  cargo-component  %s\n' "$(cargo component --version 2>/dev/null | awk '{print $2}')"
printf '  componentize-py  %s\n' "$(componentize-py --version 2>/dev/null | awk '{print $NF}')"
printf '  jco              %s\n' "$(jco --version)"
printf '  node             %s\n' "$(node --version)"
printf '  just             %s\n' "$(just --version 2>/dev/null | awk '{print $2}')"
