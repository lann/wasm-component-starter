# browser-tgz-maker

A [WebAssembly Component Model](https://component-model.bytecodealliance.org/)
example that streams files through a **Rust** component in the **browser** using
[`jco`](https://github.com/bytecodealliance/jco) and JSPI.

Pick some files in the page and they are streamed into the component, packed
into a `tar` archive, gzipped by the browser's `CompressionStream` (which the
component drives as an **imported** interface), and saved as `archive.tar.gz` —
the same result as `tar czf`, but produced without ever holding a whole file (or
the whole archive) in memory.

```
 FileList ── stream<entry> ────────────────────────────────────┐
   each entry = { name, size, contents: stream<u8> }            │
                                                                ▼
                  ┌─────────────────────────────────────────────────────┐
                  │  tar-archiver (Rust, wasm component)                │
                  │  archive(entries) -> stream<u8>                      │
                  │    1. read each entry, encode a tar member from its  │
                  │       own contents stream                            │
                  │    2. call the IMPORTED compressor.compress(tar)  ───┼──┐
                  │    3. return the compressor's gzip stream directly   │  │
                  └─────────────────────────────────────────────────────┘  │
                                          ▲                                 │
        host provides the import:         │   stream<u8> (gzip)             │
        compress = CompressionStream      └────────────────────────────────┘
        ('gzip'); a component cannot
        call the Web platform itself
        │
        ▼
  archive.tar.gz  (streamed to disk via showSaveFilePicker, or a Blob fallback)
```

> **Nested streams under jco:** this app uses a nested-stream interface
> (`archive(entries: stream<entry>)`, where each `entry` carries its own
> `contents: stream<u8>`). Stock jco 1.21.0 fails to drive it — lowering an
> `entry`'s `name` string threw an (internally swallowed) `ReferenceError` that
> looked like a deadlock. The [`jco` patch](#the-jco-patch-this-example-requires-bytecodeallianceJco1601)
> this app installs fixes that, so the *same* component now round-trips both in
> the browser and under wasmtime (see the sibling
> [`cli-tgz-maker`](../cli-tgz-maker)). Run `just patch-jco` once before
> `just test`/`just serve`.

## Why this example exists

It is a small but end-to-end demonstration of running an **async, streaming**
component in the browser that both **exports** and **imports** streaming
functions across the JS boundary. It exercises:

- **`jco` + JSPI** — the component is transpiled to a single self-contained ES
  module; its `async` export and `async` import become async JS functions that
  suspend on WebAssembly stack switching.
- **An imported async streaming interface** — gzip is *not* built into the wasm.
  The component declares `compressor.compress: async func(stream<u8>) ->
  stream<u8>` as an **import** and the host satisfies it with a one-line
  `CompressionStream('gzip')` adapter ([web/compressor.js](web/compressor.js)).
  This keeps the wasm tiny and shows streams flowing guest → host → guest.
- **Genuine streaming** — because a `tar` header records each member's length
  *before* its bytes, and the browser already knows every `File.size`, the
  component writes a header and then copies exactly that many bytes straight
  through from the member's own `contents` stream. Memory use stays flat
  regardless of file size.

## A self-contained component (one import, no WASI)

The archiver is pure data transformation: it touches no files, clock, or
network. It is built for `wasm32-unknown-unknown` (so `std` pulls in no `wasi:*`
imports) and wrapped into a component with `wasm-tools component new`. Its only
import is the `compressor` interface, which `jco` maps to the JS adapter via
`--map`. The result is one `archiver.js` with no dependency on
`@bytecodealliance/preview2-shim`.

The `tar-archiver` component lives under
[`../../components/tar-archiver`](../../components/tar-archiver) and is built by
its own justfile; this app transpiles it and supplies the `compressor` import
from the browser. The sibling [`cli-tgz-maker`](../cli-tgz-maker) app composes
*the same* `tar-archiver` with the Rust [`gzip-compressor`](../../components/gzip-compressor)
component instead, and the [`cli-metadata-printer`](../cli-metadata-printer)
example shows the other common target, `wasm32-wasip2`, where `std` keeps a
working filesystem.

## Returning a stream from an async export

An async export can't fill its result stream before returning. `archive` spawns
the tar producer with `wit_bindgen::spawn`, hands the tar stream to the imported
`compress`, and returns the compressor's gzipped output stream *directly* — the
component never reads or re-emits the result bytes itself. See
[../../components/tar-archiver/src/lib.rs](../../components/tar-archiver/src/lib.rs).

Returning a host-backed stream straight out of the export used to look like it
truncated the gzip trailer: all the bytes actually arrived, but each element
came back as a bare `number` rather than a `Uint8Array`, so a consumer doing
`Uint8Array.from(value)` got empty chunks and the stream looked short. The cause
was a jco code-gen bug (a host-lowered stream omitted the `typedArray` field
that guest-created streams carry); the patch below fixes it, which is what lets
`archive` return the compressor stream directly instead of reading and
re-emitting it.

The 512-byte `ustar` headers are built with the
[`tar-core`](https://crates.io/crates/tar-core) crate rather than hand-rolled
octal/checksum encoding; see `build_header` in
[../../components/tar-archiver/src/lib.rs](../../components/tar-archiver/src/lib.rs).

## The `jco` patch this example requires (bytecodealliance/jco#1601)

This example deliberately exercises a shape that jco 1.21.0 mis-transpiles: an
async **import** whose function takes a `stream<u8>` parameter *and* returns a
`stream<u8>`, whose result the `archive` export then returns directly, plus a
nested `stream<entry>` whose elements each carry their own `contents: stream<u8>`.
Transpiling it with `--async-mode jspi` hits four code-generation bugs in jco's
`js-component-bindgen`:

1. **[bytecodealliance/jco#1601](https://github.com/bytecodealliance/jco/issues/1601)
   — the lift side.** The lifted `future`/`stream` *parameter* of an async
   import is referenced (`streamResult0` / `futureResult0`) but never defined,
   throwing a `ReferenceError` at runtime.
2. **The mirror bug — the lower side.** The `stream`/`future` *return value* of
   an async host import is lowered twice (once inline, once by the async
   task-return machinery). The inline lower locks the host `ReadableStream`,
   throwing `TypeError: ReadableStream is locked`.
3. **The stream element-metadata bug.** A host-lowered `stream` omitted the
   `typedArray` field that guest-created streams (`streamNew`) include, so
   reading a directly-returned host `stream<u8>` yielded bare `number`s instead
   of `Uint8Array` chunks (see the section above).
4. **The missing string-encode intrinsic.** Lowering a `string` field inside a
   stream/record payload (e.g. an `entry.name` carried by the `stream<entry>`)
   emits a call to the `_utf8AllocateAndEncode` helper, but jco's
   `render_intrinsics` never emits the helper's *definition*: the
   `LowerFlatStringUtf8` dependency block inserts only the `TEXT_ENCODER_UTF8`
   global, not the `Utf8Encode` string intrinsic. The resulting `ReferenceError:
   _utf8AllocateAndEncode is not defined` is swallowed by the stream-write
   machinery, so the read side waits forever — it *looks* like a nested-stream
   deadlock but is really a crash in string lowering. The patch makes that
   dependency block also emit `Utf8Encode` (and adds the matching
   `Utf16Encode` + `IsLE` for UTF-16).

Until the upstream fix ships, this example carries a small patch to jco's code
generator that fixes all four
([jco-patch/function_bindgen.patch](jco-patch/function_bindgen.patch)). Apply it
once before building:

```sh
just patch-jco     # clone jco @ jco-v1.21.0, apply the patch, build, install
```

`patch-jco` backs up the stock jco objects as `*.orig`, so you can drop the
workaround at any time with `just restore-jco`. This is a temporary measure; the
maintainers have indicated a proper fix is coming.

## Nested streams under jco

This app's interface is `archive(entries: stream<entry>) -> stream<u8>`, where
each `entry` carries its own `contents: stream<u8>` — i.e. a **stream whose
elements are themselves streams**. wasmtime's component-model implementation
handles this directly; the sibling [`cli-tgz-maker`](../cli-tgz-maker) drives the
*same* `tar-archiver` component to a byte-for-byte round-trip (including a 10 MB
file).

Stock jco 1.21.0 appears to *deadlock* on this shape: even a single-member
archive hangs on the first read of the host-lowered `stream<entry>`. That turned
out **not** to be a scheduling deadlock at all — lowering the first `entry`'s
`name` string threw `ReferenceError: _utf8AllocateAndEncode is not defined`
(bug 4 above: jco emitted the call but never the helper's definition), and the
stream-write machinery swallowed the error, so the read side simply waited
forever. The [jco patch](#the-jco-patch-this-example-requires-bytecodeallianceJco1601)
this app installs emits the missing intrinsic, after which the nested-stream
pipeline round-trips under jco exactly as it does under wasmtime. Run
`just patch-jco` once and `just test`/`just serve` work.

The headless [test/smoke.mjs](test/smoke.mjs) still carries a short watchdog that
aborts with a clear message if a read ever stalls, so a future regression fails
fast instead of hanging.

## Build and run

Prerequisites are provided by the dev container (`rust`, `wasm-tools`, `jco`,
`node`, `python3`, `just`).

```sh
cd examples/apps/browser-tgz-maker

# One-time: build and install the patched jco (see the section above):
just patch-jco

# Headless end-to-end check (builds, transpiles, runs the pipeline under Node):
just test

# Serve the browser demo, then open the printed URL in a recent Chromium-based
# browser (JSPI is required):
just serve
```

`just serve` prints <http://localhost:8080>. Choose files, click **Create
archive.tar.gz**, and save the result.

## Layout

| Path | What it is |
| --- | --- |
| [../../wit/archive/interfaces.wit](../../wit/archive/interfaces.wit) | The `archiver` and `compressor` interfaces. |
| [../../components/tar-archiver/src/lib.rs](../../components/tar-archiver/src/lib.rs) | The streaming `tar` encoder that drives the imported compressor. |
| [web/compressor.js](web/compressor.js) | The host adapter implementing the imported `compress` with `CompressionStream`. |
| [web/index.html](web/index.html), [web/main.js](web/main.js) | The browser UI and the stream-wiring driver. |
| [test/smoke.mjs](test/smoke.mjs) | A headless Node run of the full pipeline, asserting the archive round-trips. |
| [jco-patch/](jco-patch/) | The temporary jco patch and `apply.sh` / `restore.sh` scripts. |
| [justfile](justfile) | `patch-jco`, `restore-jco`, `build`, `transpile`, `serve`, `test`, `clean` recipes. |
