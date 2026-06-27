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
# with `jco transpile --async-mode jspi` hits four bugs in jco 1.21.0's
# `js-component-bindgen` code generator that are still unfixed upstream:
#
#   1. bytecodealliance/jco#1601 -- the *lift* of a `future`/`stream` parameter
#      to an async import references an undefined `streamResult0`/`futureResult0`
#      variable (a ReferenceError at runtime).
#
#   2. A mirror bug on the *lower* side: the return `stream`/`future` of an async
#      host import is lowered twice (once inline, once by the async task-return
#      machinery), which locks the host `ReadableStream` ("ReadableStream is
#      locked").
#
#   3. A host-lowered `stream` omitted the `typedArray` field from its element
#      metadata that guest-created streams (`streamNew`) include. Reading a
#      directly-returned host `stream<u8>` (e.g. the `archive` export forwarding
#      the compressor's result stream) therefore yielded bare `number`s instead
#      of `Uint8Array` chunks, so a consumer doing `Uint8Array.from(value)` saw
#      empty chunks -- the gzip stream looked truncated. (This is what the older
#      revision of this example worked around by reading and re-emitting the
#      bytes itself; with the fix the export can return the stream directly.)
#
#   4. Lowering a `string` field inside a stream/record payload (e.g. an
#      `entry.name` carried by `archive`'s `stream<entry>`) emits a call to the
#      `_utf8AllocateAndEncode` helper, but `render_intrinsics` never emits the
#      helper's definition: the `LowerFlatStringUtf8` dependency block inserts
#      only the `TEXT_ENCODER_UTF8` global, not the `Utf8Encode` string
#      intrinsic that defines `_utf8AllocateAndEncode`. The resulting
#      `ReferenceError: _utf8AllocateAndEncode is not defined` is swallowed by
#      the stream-write machinery, so the read side waits forever -- it *looks*
#      like a nested-stream deadlock but is really a crash in string lowering.
#
# The patch fixes #1601's two bugs in
# `crates/js-component-bindgen/src/function_bindgen.rs`, the metadata bug in
# `crates/js-component-bindgen/src/transpile_bindgen.rs`, and the missing
# string-intrinsic dependency in
# `crates/js-component-bindgen/src/intrinsics/mod.rs`. This is a temporary
# workaround; drop it once the upstream fix ships and re-run `just restore-jco`.
#
# What this does
# --------------
#   1. Clones jco at tag jco-v1.21.0 into a temp dir (or reuses $JCO_SRC).
#   2. Applies the patch.
#   3. Builds the patched bindgen (`cargo xtask build release`).
#   4. Backs up the global jco's generated objects as *.orig (once).
#   5. Copies the patched objects over the global install.
set -euo pipefail

JCO_TAG="jco-v1.21.0"
JCO_REPO="https://github.com/bytecodealliance/jco"
PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/function_bindgen.patch"

# Locate the globally-installed jco package directory.
GLOBAL_JCO="$(npm root -g)/@bytecodealliance/jco"
if [[ ! -d "$GLOBAL_JCO/obj" ]]; then
  echo "error: could not find global jco at $GLOBAL_JCO (is jco installed with 'npm i -g @bytecodealliance/jco'?)" >&2
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
# to `jco opt`, which imports `commander` et al. from packages/jco). jco 1.21.0 is
# a pnpm workspace that uses pnpm `catalog:` versions, which `npm` can't parse, so
# we install with pnpm. `--prod` skips dev deps (e.g. puppeteer, whose postinstall
# downloads Chrome); `--filter` scopes the install to the jco package.
if [[ ! -d "$JCO_SRC/packages/jco/node_modules/commander" ]]; then
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "error: pnpm is required to install jco 1.21.0's workspace dependencies" >&2
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
  if [[ ! -f "$GLOBAL_JCO/obj/$f.orig" ]]; then
    cp "$GLOBAL_JCO/obj/$f" "$GLOBAL_JCO/obj/$f.orig"
  fi
  cp "$OBJ/$f" "$GLOBAL_JCO/obj/$f"
done

echo "Installed patched jco into $GLOBAL_JCO/obj (originals saved as *.orig)."
echo "Run 'just restore-jco' to revert."
