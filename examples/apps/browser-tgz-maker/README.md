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

The 512-byte `ustar` headers are built with the
[`tar-core`](https://crates.io/crates/tar-core) crate rather than hand-rolled
octal/checksum encoding; see `build_header` in
[../../components/tar-archiver/src/lib.rs](../../components/tar-archiver/src/lib.rs).

## Nested streams under jco

This app's interface is `archive(entries: stream<entry>) -> stream<u8>`, where
each `entry` carries its own `contents: stream<u8>` — i.e. a **stream whose
elements are themselves streams**, plus an async **import** whose function takes
a `stream<u8>` parameter *and* returns a `stream<u8>` that the `archive` export
returns directly. jco transpiles this shape (`--async-mode jspi`) so the *same*
`tar-archiver` component round-trips under jco exactly as it does under wasmtime;
the sibling [`cli-tgz-maker`](../cli-tgz-maker) drives it to a byte-for-byte
round-trip (including a 10 MB file).

The headless [test/smoke.mjs](test/smoke.mjs) carries a short watchdog that
aborts with a clear message if a read ever stalls, so a future regression fails
fast instead of hanging.

## Build and run

Prerequisites are provided by the dev container (`rust`, `wasm-tools`, `jco`,
`node`, `python3`, `just`).

```sh
cd examples/apps/browser-tgz-maker

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
| [justfile](justfile) | `build`, `transpile`, `serve`, `test`, `clean` recipes. |
