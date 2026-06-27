# cli-tgz-maker

A [WebAssembly Component Model](https://component-model.bytecodealliance.org/)
example that builds a streaming `tar.gz` tool entirely out of composed wasm
components and runs it under [`wasmtime`](https://github.com/bytecodealliance/wasmtime).

It is the command-line counterpart to [`browser-tgz-maker`](../browser-tgz-maker):
the **same** `tar-archiver` component does the archiving, but here its
`compressor` import is satisfied by a real Rust [`gzip-compressor`](../../components/gzip-compressor)
component instead of the browser's `CompressionStream`, and the whole pipeline
is driven from `wasi:cli/run` instead of from JavaScript.

```
  files on disk
       │  std::fs::metadata + read (streamed)
       ▼
┌──────────────────────┐  stream<entry>              ┌──────────────────────┐
│  cli-archive-maker    │  (each: name, size,         │  tar-archiver        │
│  (Rust, wasm32-wasip2)│   contents: stream<u8>)     │  (Rust, no WASI)     │
│  async wasi:cli/run   │ ──────────────────────────► │  archive(entries)    │
│                       │ ◄────────────────────────── │                      │
└──────────────────────┘      stream<u8> (tar.gz)     └──────────┬───────────┘
       │  std::fs::write                                         │ stream<u8>
       ▼                                          compressor.compress (import)
  output.tar.gz                                                  ▼
                                                      ┌──────────────────────┐
                                                      │  gzip-compressor     │
                                                      │  (Rust, flate2)      │
                                                      └──────────────────────┘
```

## Why this example exists

It shows a three-component pipeline composed **statically** with
[`wac`](https://github.com/bytecodealliance/wac) and run as native wasm. It
exercises:

- **Component reuse across hosts** — `tar-archiver` is written once and driven
  two completely different ways: from a browser over JSPI, and from another wasm
  component under `wasmtime`. Its `compressor` import is the seam that lets the
  gzip implementation differ per host.
- **A pure-Rust streaming gzip component** — `gzip-compressor` wraps
  [`flate2`](https://crates.io/crates/flate2)'s `write::GzEncoder` (the
  pure-Rust `miniz_oxide` backend) and exposes it as an async streaming
  `compressor.compress`, draining compressed bytes a chunk at a time.
- **An async `wasi:cli/run` driving cross-component streams** — `cli-archive-maker`
  is a `cdylib` exporting an async `run` (via the [`wasip3`](https://crates.io/crates/wasip3)
  crate) so it can `.await` the `archive` import; a synchronous `main` would trap
  with *"cannot block a synchronous task before returning"*. It still uses plain
  `std::fs` for reading inputs and writing the result.

## Composition: two `wac plug` steps

`wac plug` wires a plug's exports into the *socket's* imports, but not one plug
into another. The graph here is a chain (`cli-archive-maker` → `tar-archiver` →
`gzip-compressor`), so the justfile composes it in two steps:

```sh
# 1. Satisfy tar-archiver's `compressor` import with gzip-compressor.
wac plug tar-archiver.component.wasm \
    --plug gzip-compressor.component.wasm \
    -o tar-archiver.plugged.wasm

# 2. Satisfy cli-archive-maker's `archiver` import with the combined component.
wac plug cli-archive-maker.component.wasm \
    --plug tar-archiver.plugged.wasm \
    -o app.wasm
```

The result, `app.wasm`, imports only `wasi:cli` and `wasi:filesystem` — all the
`example:archive` imports are satisfied internally.

## Layout

| Path | Role |
| --- | --- |
| [../../wit/archive/interfaces.wit](../../wit/archive/interfaces.wit) | The `archiver` and `compressor` interfaces. |
| [../../components/cli-archive-maker/src/lib.rs](../../components/cli-archive-maker/src/lib.rs) | Rust CLI driver: async `wasi:cli/run`, reads files, calls `archive`. |
| [../../components/tar-archiver/src/lib.rs](../../components/tar-archiver/src/lib.rs) | The streaming `tar` encoder that drives the imported compressor. |
| [../../components/gzip-compressor/src/lib.rs](../../components/gzip-compressor/src/lib.rs) | Pure-Rust streaming gzip provider of the `compressor` interface. |
| [testdata/](testdata/) | Sample files (`poem.txt`, `data.bin`, `nested.txt`) archived by `just test`. |
| [justfile](justfile) | Build, two-step compose, run, and test recipes for [`just`](https://github.com/casey/just). |

## Prerequisites

The dev container ships with everything below; versions are the ones this
example was validated against.

- Rust toolchain with the `wasm32-unknown-unknown` and `wasm32-wasip2` targets
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) 1.251
- [`wac`](https://github.com/bytecodealliance/wac) 0.10
- [`wasmtime`](https://github.com/bytecodealliance/wasmtime) 45 (with WASIp3 support)

## Build and run

```sh
just                               # list recipes
just build                         # build all three components + compose -> app.wasm
just run OUTPUT INPUT...            # archive INPUT files into OUTPUT.tar.gz
just run-sample                    # archive the bundled testdata into build/sample.tar.gz
just test                          # archive the samples and assert every member round-trips
just clean                         # remove build artifacts
```

`just run` ultimately invokes:

```sh
wasmtime run -W component-model-async=y -S p3 --dir . build/app.wasm OUTPUT INPUT...
```

- `-W component-model-async=y` enables the component-model async ABI.
- `-S p3` enables the host's WASIp3 (async) APIs.
- `--dir .` grants read/write access to the working directory so the CLI can
  open the input files and write the archive.

Verify a result with the system `tar`:

```sh
just run build/out.tar.gz testdata/poem.txt testdata/data.bin
tar tzvf build/out.tar.gz
```

## Limitations

- **Flat archive.** Member names are the input files' basenames, truncated to the
  100-byte `ustar` name field; there is no directory-prefix or PAX handling.
- The `wasip3` crate tracks a WASIp3 **draft** snapshot whose `@0.3.0-rc-*`
  version must match what your `wasmtime` understands; the pinned toolchain in
  this repository is known to agree.
