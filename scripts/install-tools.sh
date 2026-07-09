#!/usr/bin/env bash
#
# Shared Component Model toolchain installer.
#
# This is the single source of truth for the CLI tools (and their version pins)
# used across every environment:
#   - the dev container (.devcontainer/post-create.sh)
#   - CI (.github/actions/setup-toolchain -> .github/workflows/ci.yml)
#   - the Copilot cloud agent (.github/workflows/copilot-setup-steps.yml)
#   - ad-hoc local setup (`just setup`)
#
# Prerequisites (provided by the environment, not installed here):
#   - Rust toolchain with the wasm32-wasip2 and wasm32-unknown-unknown targets
#   - Node.js (22+; the browser example's JSPI test needs a JSPI-capable node)
#   - Python 3
set -euo pipefail

# --- Version pins -------------------------------------------------------------
# componentize-py is a Python wheel; jco is an npm package. The cargo-binstall
# tools below intentionally track their latest crates.io releases.
COMPONENTIZE_PY_VERSION="${COMPONENTIZE_PY_VERSION:-0.23.0}"
JCO_VERSION="${JCO_VERSION:-1.25.2}"

# --- Component Model CLI tooling via cargo-binstall ---------------------------
# cargo-binstall fetches prebuilt release binaries (falling back to a source
# build only if no artifact is published), which keeps setup fast and avoids
# compiling these tools from scratch. Each tool resolves to its latest
# crates.io release:
#   wasmtime-cli      -> canonical host runtime (`wasmtime`); 46+ supports the
#                        final WASI 0.3.0 needed to run the examples
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

# --- jco (JavaScript -> component) --------------------------------------------
npm install -g "@bytecodealliance/jco@${JCO_VERSION}"

# --- componentize-py (Python -> component) ------------------------------------
# The console script lands on PATH (~/.local/bin with --user, or the active
# environment's bin dir) and the wheel bundles its own CPython runtime.
# PIP_INSTALL_ARGS lets callers choose e.g. `--user` (dev container) vs a plain
# install (CI runners, where --user can hit externally-managed environments).
# shellcheck disable=SC2086
python3 -m pip install ${PIP_INSTALL_ARGS:-} --upgrade "componentize-py==${COMPONENTIZE_PY_VERSION}"

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
