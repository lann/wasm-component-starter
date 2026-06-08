#!/usr/bin/env bash
#
# Revert the patched jco installed by apply.sh, restoring the stock objects
# from the *.orig backups.
set -euo pipefail

GLOBAL_JCO="$(npm root -g)/@bytecodealliance/jco"
if [[ ! -d "$GLOBAL_JCO/obj" ]]; then
  echo "error: could not find global jco at $GLOBAL_JCO" >&2
  exit 1
fi

restored=0
for f in js-component-bindgen-component.core.wasm \
         js-component-bindgen-component.core2.wasm \
         js-component-bindgen-component.js; do
  if [[ -f "$GLOBAL_JCO/obj/$f.orig" ]]; then
    mv "$GLOBAL_JCO/obj/$f.orig" "$GLOBAL_JCO/obj/$f"
    restored=1
  fi
done

if [[ "$restored" == "1" ]]; then
  echo "Restored stock jco objects in $GLOBAL_JCO/obj."
else
  echo "Nothing to restore (no *.orig backups found)."
fi
