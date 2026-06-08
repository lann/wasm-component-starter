# async-browser-streams

A [WebAssembly Component Model](https://component-model.bytecodealliance.org/)
example that streams files through a **Rust** component in the **browser** using
[`jco`](https://github.com/bytecodealliance/jco) and JSPI.

Pick some files in the page and they are streamed into the component, packed
into a `tar` archive, gzipped by the browser's `CompressionStream` (which the
component drives as an **imported** interface), and saved as `archive.tar.gz` —
the same result as `tar czf`, but produced without ever holding a whole file (or
the whole archive) in memory.

```
 FileList ── entries (name, size) ─────────────────────────────┐
          └─ stream<u8> (all file bytes, concatenated, in order)│
                                                                ▼
                  ┌─────────────────────────────────────────────────────┐
                  │  archiver (Rust, wasm component)                     │
                  │  archive(entries, contents) -> stream<u8>            │
                  │    1. encode a tar stream from contents              │
                  │    2. call the IMPORTED compressor.compress(tar)  ───┼──┐
                  │    3. re-emit the gzipped bytes on its own stream    │  │
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
  through. Memory use stays flat regardless of file size.

## A self-contained component (one import, no WASI)

The archiver is pure data transformation: it touches no files, clock, or
network. It is built for `wasm32-unknown-unknown` (so `std` pulls in no `wasi:*`
imports) and wrapped into a component with `wasm-tools component new`. Its only
import is the `compressor` interface, which `jco` maps to the JS adapter via
`--map`. The result is one `archiver.js` with no dependency on
`@bytecodealliance/preview2-shim`.

(The sibling [`async-composition`](../async-composition) example shows the other
common target, `wasm32-wasip2`, where `std` keeps a working filesystem.)

## Returning a stream from an async export

An async export can't fill its result stream before returning. `archive` creates
a `wit_stream` pair, returns the *reader*, and uses `wit_bindgen::spawn` to run
the pipeline (holding the *writer*) as a detached task — the "ping-pong"
pattern. The detached task tar-encodes the input, calls the imported `compress`,
reads its gzipped output, and re-emits it on the returned stream. See
[archiver/src/lib.rs](archiver/src/lib.rs).

## The `jco` patch this example requires (bytecodealliance/jco#1601)

This example deliberately exercises a shape that jco 1.20.0 mis-transpiles: an
async **import** whose function takes a `stream<u8>` parameter *and* returns a
`stream<u8>`. Transpiling it with `--async-mode jspi` hits two code-generation
bugs in jco's `js-component-bindgen`:

1. **[bytecodealliance/jco#1601](https://github.com/bytecodealliance/jco/issues/1601)
   — the lift side.** The lifted `future`/`stream` *parameter* of an async
   import is referenced (`streamResult0` / `futureResult0`) but never defined,
   throwing a `ReferenceError` at runtime.
2. **The mirror bug — the lower side.** The `stream`/`future` *return value* of
   an async host import is lowered twice (once inline, once by the async
   task-return machinery). The inline lower locks the host `ReadableStream`,
   throwing `TypeError: ReadableStream is locked`.

Until the upstream fix ships, this example carries a small patch to jco's code
generator that fixes both
([jco-patch/function_bindgen.patch](jco-patch/function_bindgen.patch)). Apply it
once before building:

```sh
just patch-jco     # clone jco @ jco-v1.20.0, apply the patch, build, install
```

`patch-jco` backs up the stock jco objects as `*.orig`, so you can drop the
workaround at any time with `just restore-jco`. This is a temporary measure; the
maintainers have indicated a proper fix is coming.

## Build and run

Prerequisites are provided by the dev container (`rust`, `wasm-tools`, `jco`,
`node`, `python3`, `just`).

```sh
cd examples/async-browser-streams

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
| [wit/world.wit](wit/world.wit) | The `archiver` and `compressor` interfaces and the world. |
| [archiver/src/lib.rs](archiver/src/lib.rs) | The streaming `tar` encoder that drives the imported compressor. |
| [web/compressor.js](web/compressor.js) | The host adapter implementing the imported `compress` with `CompressionStream`. |
| [web/index.html](web/index.html), [web/main.js](web/main.js) | The browser UI and the stream-wiring driver. |
| [test/smoke.mjs](test/smoke.mjs) | A headless Node run of the full pipeline, asserting the archive round-trips. |
| [jco-patch/](jco-patch/) | The temporary jco patch and `apply.sh` / `restore.sh` scripts. |
| [justfile](justfile) | `patch-jco`, `restore-jco`, `build`, `transpile`, `serve`, `test`, `clean` recipes. |
