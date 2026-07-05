#!/usr/bin/env bash
#
# Revert the patched jco installed by apply.sh, restoring the stock objects
# from the *.orig backups.
set -euo pipefail

# As of jco 1.24.6 the bindgen artifacts live in the `@bytecodealliance/
# jco-transpile` dependency's `vendor/` directory; older releases kept them in
# `<jco>/obj`. Support both layouts (matching apply.sh).
GLOBAL_JCO="$(npm root -g)/@bytecodealliance/jco"
if [[ -d "$GLOBAL_JCO/node_modules/@bytecodealliance/jco-transpile/vendor" ]]; then
  OBJ_DIR="$GLOBAL_JCO/node_modules/@bytecodealliance/jco-transpile/vendor"
elif [[ -d "$GLOBAL_JCO/obj" ]]; then
  OBJ_DIR="$GLOBAL_JCO/obj"
else
  echo "error: could not find global jco bindgen objects under $GLOBAL_JCO" >&2
  exit 1
fi

restored=0
for f in js-component-bindgen-component.core.wasm \
         js-component-bindgen-component.core2.wasm \
         js-component-bindgen-component.js; do
  if [[ -f "$OBJ_DIR/$f.orig" ]]; then
    mv "$OBJ_DIR/$f.orig" "$OBJ_DIR/$f"
    restored=1
  fi
done

if [[ "$restored" == "1" ]]; then
  echo "Restored stock jco objects in $OBJ_DIR."
else
  echo "Nothing to restore (no *.orig backups found)."
fi
