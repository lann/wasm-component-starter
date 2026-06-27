# jco `main` patches

The patches in the parent directory target the released **`jco-v1.21.0`** tag.
Upstream `main` has since fixed two of the four bugs this example hit, so a
different (smaller) set of patches is needed when building from `main`.

## Status on `main` (verified against `main` HEAD)

| # | Bug | Files | Fixed upstream on `main`? |
|---|-----|-------|----------------------------|
| 1 | [#1601](https://github.com/bytecodealliance/jco/issues/1601) — `future`/`stream` **lift** references an undefined `streamResult0`/`futureResult0` | `function_bindgen.rs` | ✅ Yes (FutureLift/StreamLift refactored to `match (is_async, for_import)`) |
| 2 | Async import return `stream`/`future` is **lowered twice** → `ReadableStream is locked` | `function_bindgen.rs` | ❌ No — still needs patching |
| 3 | Host-lowered `stream` omits the `typedArray` element-metadata field | `transpile_bindgen.rs` | ✅ Yes |
| 4 | `LowerFlatStringUtf8` never emits the `_utf8AllocateAndEncode` helper → swallowed `ReferenceError` | `intrinsics/mod.rs` | ❌ No — still needs patching |

So on `main` only bugs **#2** and **#4** remain.

## `double-lower-and-string.patch`

The minimal code-generator fix for `main`. Touches only:

- `crates/js-component-bindgen/src/function_bindgen.rs` — gates the inline
  `FutureLower`/`StreamLower` body so an async host import's **return** value is
  lowered only by the async task-return machinery (`task.resolve`), never twice.
  The gate is `self.is_async && !self.params.iter().any(|p| p == arg)` (the
  operand is a return value, not an incoming parameter).
- `crates/js-component-bindgen/src/intrinsics/mod.rs` — makes
  `LowerFlatStringUtf8` (and `LowerFlatStringUtf16`) also insert the
  `Utf8Encode` / `Utf16Encode` string intrinsics that define
  `_utf8AllocateAndEncode` / `_utf16AllocateAndEncode`.

Verified with `git apply --check` against `main` HEAD.

## `regression-test.patch`

A self-contained regression test for bug **#2** that can be upstreamed to jco.
Touches only source (the `.wasm` fixture is a build artifact, regenerated from
the WIT + guest source by the `jco-test-components-artifacts` build):

- `crates/test-components/wit/all.wit` — adds a `stream-lower-return` world: an
  async import `produce-stream: async func(vals: list<u32>) -> stream<u32>`
  (return value is a stream) and an async export `read-host-stream` that drains
  it.
- `crates/test-components/src/bin/stream_lower_return.rs` — the guest that calls
  the import and returns the drained values.
- `packages/jco/test/p3/deadlock-regressions.js` — adds the test
  *"async import returning a stream is lowered exactly once"* to the existing
  `async scheduling regressions` suite. It supplies the host import as a
  function returning a `ReadableStream` and asserts the values round-trip.

### Verified fail-before / pass-after (against `main`)

| bindgen state | result |
|---------------|--------|
| `main` **without** `double-lower-and-string.patch` | ❌ `TypeError: Invalid state: ReadableStream is locked` |
| `main` **with** `double-lower-and-string.patch` | ✅ passes (round-trips `[1,2,3,4,5]`) |

The 3 pre-existing tests in that suite pass in both states, confirming the new
test isolates the double-lower regression.

## Reproducing

```bash
# in a fresh jco `main` checkout
git apply path/to/double-lower-and-string.patch
git apply path/to/regression-test.patch

# build the patched code generator
cargo xtask build release        # the trailing build:ts step may fail harmlessly

# build the test fixtures (regenerates stream-lower-return.wasm), or build just
# the one guest + encode it:
cargo build --release --target=wasm32-wasip1 -p jco-test-components --bin stream_lower_return
wasm-tools component new \
  target/wasm32-wasip1/release/stream_lower_return.wasm \
  --adapt wasi_snapshot_preview1=packages/jco/test/fixtures/wasi_snapshot_preview1.reactor.wasm \
  -o packages/jco/test/output/rust-test-components/stream-lower-return.wasm

# run just the regression suite
cd packages/jco
node_modules/.bin/vitest run -c test/vitest.ts test/p3/deadlock-regressions.js
```
