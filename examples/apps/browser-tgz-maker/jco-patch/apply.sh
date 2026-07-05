#!/usr/bin/env bash
#
# Build a patched jco and install it over the globally-installed jco.
#
# Why this exists
# ---------------
# This example *imports* an async streaming `compressor` interface whose
# `compress` function takes a `stream<u8>` parameter and returns a `stream<u8>`,
# and the `archive` export returns that imported stream directly. The `archive`
# export also takes a `stream<entry>` where each `entry` record carries a
# `name: string` and a nested `contents: stream<u8>`. Transpiling that shape
# with `jco transpile --async-mode jspi` originally hit four bugs in jco's
# `js-component-bindgen` code generator. jco 1.24.6 fixes two of them upstream
# (bytecodealliance/jco#1601's lift-side `ReferenceError`, and the missing
# `typedArray` stream element-metadata field), leaving two that still need
# patching:
#
#   A. The *lower* side of async host imports: the return `stream`/`future` of
#      an async host import is lowered twice (once inline, once by the async
#      task-return machinery), which locks the host `ReadableStream`
#      ("ReadableStream is locked").
#
#   B. Lowering a `string` field inside a stream/record payload (e.g. an
#      `entry.name` carried by `archive`'s `stream<entry>`) emits a call to the
#      `_utf8AllocateAndEncode` helper, but `render_intrinsics` never emits the
#      helper's definition: the `LowerFlatStringUtf8` dependency block inserts
#      only the `TEXT_ENCODER_UTF8` global, not the `Utf8Encode` string
#      intrinsic that defines `_utf8AllocateAndEncode`. The resulting
#      `ReferenceError: _utf8AllocateAndEncode is not defined` is swallowed by
#      the stream-write machinery, so the read side waits forever -- it *looks*
#      like a nested-stream deadlock but is really a crash in string lowering.
#
# The patch fixes bug A in
# `crates/js-component-bindgen/src/function_bindgen.rs` and bug B (the missing
# string-intrinsic dependency) in
# `crates/js-component-bindgen/src/intrinsics/mod.rs`. This is a temporary
# workaround; drop it once the upstream fix ships and re-run `just restore-jco`.
#
# What this does
# --------------
#   1. Clones jco at tag jco-v1.24.6 into a temp dir (or reuses $JCO_SRC).
#   2. Applies the patch.
#   3. Builds the patched bindgen (`cargo xtask build release`).
#   4. Backs up the global jco's generated objects as *.orig (once).
#   5. Copies the patched objects over the global install.
set -euo pipefail

JCO_TAG="jco-v1.24.6"
JCO_REPO="https://github.com/bytecodealliance/jco"
PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/function_bindgen.patch"

# Locate the globally-installed jco package directory and its bundled
# code-generator artifacts. As of jco 1.24.6 the `js-component-bindgen`
# artifacts ship in the `@bytecodealliance/jco-transpile` dependency's `vendor/`
# directory (older releases kept them in `<jco>/obj`); support both layouts.
GLOBAL_JCO="$(npm root -g)/@bytecodealliance/jco"
if [[ -d "$GLOBAL_JCO/node_modules/@bytecodealliance/jco-transpile/vendor" ]]; then
  OBJ_DIR="$GLOBAL_JCO/node_modules/@bytecodealliance/jco-transpile/vendor"
elif [[ -d "$GLOBAL_JCO/obj" ]]; then
  OBJ_DIR="$GLOBAL_JCO/obj"
else
  echo "error: could not find global jco bindgen objects under $GLOBAL_JCO (is jco installed with 'npm i -g @bytecodealliance/jco'?)" >&2
  exit 1
fi

# Clone (shallow, pinned to the tag) unless a source tree is provided.
JCO_SRC="${JCO_SRC:-$(mktemp -d)/jco-src}"
if [[ ! -d "$JCO_SRC/.git" ]]; then
  echo "Cloning $JCO_REPO @ $JCO_TAG into $JCO_SRC ..."
  git clone --depth 1 --branch "$JCO_TAG" "$JCO_REPO" "$JCO_SRC"
fi

# Apply the patch (idempotently).
cd "$JCO_SRC"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
  echo "Applied $PATCH"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "Patch already applied -- skipping."
else
  echo "error: patch does not apply cleanly to $JCO_TAG" >&2
  exit 1
fi

# Install the Node deps the build needs (`cargo xtask build release` shells out
# to `jco opt`, which imports `commander` et al. from packages/jco). jco is
# a pnpm workspace that uses pnpm `catalog:` versions, which `npm` can't parse, so
# we install with pnpm. `--prod` skips dev deps (e.g. puppeteer, whose postinstall
# downloads Chrome); `--filter` scopes the install to the jco package.
if [[ ! -d "$JCO_SRC/packages/jco/node_modules/commander" ]]; then
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "error: pnpm is required to install jco's workspace dependencies" >&2
    exit 1
  fi
  echo "Installing jco's Node dependencies (pnpm install) ..."
  PUPPETEER_SKIP_DOWNLOAD=true pnpm --dir "$JCO_SRC" install --prod \
    --filter @bytecodealliance/jco --config.confirmModulesPurge=false
fi

# Build the patched code generator. The xtask's final step regenerates jco's own
# TypeScript `.d.ts` files, which can fail in a minimal `--omit=dev` checkout and
# is irrelevant here: we only consume the `obj/*` bindgen artifacts produced
# earlier by the transpile step. So we tolerate a non-zero exit as long as those
# artifacts were written (verified below).
echo "Building patched jco (cargo xtask build release) ..."
cargo xtask build release || echo "note: xtask exited non-zero (likely the jco .d.ts step) -- verifying obj artifacts ..."

# Back up the originals once, then install the patched objects.
OBJ="$JCO_SRC/packages/jco/obj"
for f in js-component-bindgen-component.core.wasm \
         js-component-bindgen-component.core2.wasm \
         js-component-bindgen-component.js; do
  if [[ ! -f "$OBJ/$f" ]]; then
    echo "error: expected build artifact missing: $OBJ/$f" >&2
    exit 1
  fi
  if [[ ! -f "$OBJ_DIR/$f.orig" ]]; then
    cp "$OBJ_DIR/$f" "$OBJ_DIR/$f.orig"
  fi
  cp "$OBJ/$f" "$OBJ_DIR/$f"
done

echo "Installed patched jco into $OBJ_DIR (originals saved as *.orig)."
echo "Run 'just restore-jco' to revert."
