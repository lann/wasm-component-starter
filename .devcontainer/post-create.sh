#!/usr/bin/env bash
set -euo pipefail

# CARGO_HOME is set by the Rust dev container feature (defaults to
# /usr/local/cargo). Binaries installed by cargo-binstall land in $CARGO_HOME/bin,
# which is already on PATH for every user.
CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"

# The cargo registry cache and target volumes are created owned by root; hand
# them to the dev user so cargo can write to them. The shared cargo bin dir is
# also root-owned (the feature runs as root), so make it writable too before
# cargo-binstall drops binaries into it.
sudo chown -R "$(id -u):$(id -g)" \
  /usr/local/cargo/registry \
  "${containerWorkspaceFolder:-$PWD}/target" 2>/dev/null || true
sudo chgrp -R "$(id -g)" "${CARGO_HOME}/bin" 2>/dev/null || true
sudo chmod -R g+w "${CARGO_HOME}/bin" 2>/dev/null || true

# Install the Component Model CLI toolchain. The shared installer is the single
# source of truth for tools and version pins across the dev container, CI, and
# the Copilot cloud agent. `--user` puts componentize-py's console script in
# ~/.local/bin, which the dev container already has on PATH.
PIP_INSTALL_ARGS="--user" bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/install-tools.sh"
