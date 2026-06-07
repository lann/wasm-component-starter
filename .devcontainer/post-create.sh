#!/usr/bin/env bash
set -euo pipefail

# jco — JavaScript toolchain for Wasm components. Installed here (not in the
# Dockerfile) because it depends on Node, which the devcontainer Node feature
# layers on top of the image after the build.
JCO_VERSION="1.20.0"

# The cargo registry cache and target volumes are created owned by root; hand
# them to the dev user so cargo can write to them.
sudo chown -R "$(id -u):$(id -g)" \
  /usr/local/cargo/registry \
  "${containerWorkspaceFolder:-$PWD}/target" 2>/dev/null || true

npm install -g "@bytecodealliance/jco@${JCO_VERSION}"

echo ""
echo "Component Model toolchain ready:"
printf '  rustc            %s\n' "$(rustc --version | awk '{print $2}')"
printf '  wasmtime         %s\n' "$(wasmtime --version | awk '{print $2}')"
printf '  wasm-tools       %s\n' "$(wasm-tools --version | awk '{print $2}')"
printf '  wit-bindgen      %s\n' "$(wit-bindgen --version | awk '{print $2}')"
printf '  wac              %s\n' "$(wac --version | awk '{print $2}')"
printf '  componentize-py  %s\n' "$(componentize-py --version 2>/dev/null | awk '{print $NF}')"
printf '  jco              %s\n' "$(jco --version)"
printf '  node             %s\n' "$(node --version)"
