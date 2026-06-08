# cli-metadata-printer

A two-language [WebAssembly Component Model](https://component-model.bytecodealliance.org/)
example that wires a **Rust** command-line component to a **Python** library
component and streams data between them asynchronously.

A CLI (`metadata-printer`, Rust) reads an HTML file (or fetches a URL) and
streams its bytes to an extractor (`metadata-parser`, Python). The extractor
parses the document with Python's built-in `html.parser` and streams
`(key, value)` metadata pairs back. Neither side buffers the whole document or
the whole result set — data flows through component-model `stream`s in both
directions.

```
┌────────────────────┐   stream<u8>            ┌──────────────────────┐
│ metadata-printer   │ ──────────────────────► │  metadata-parser     │
│  (Rust)            │                         │  (Python)            │
│  wasm32-wasip2     │                         │  componentize-py     │
│  + wasip3 run      │ ◄────────────────────── │                      │
└────────────────────┘  stream<tuple<…,…>>     └──────────────────────┘
        exports wasi:cli/run (async)                exports extractor
```

The two components live under [`../../components`](../../components)
(`metadata-printer`, `metadata-parser`) and share the
[`example:metadata`](../../wit/metadata-parser/world.wit) WIT package. This app
directory only composes and runs them.

## Why this example exists

It is a deliberately small but non-trivial smoke test for a Component Model
toolchain. It exercises:

- **Cross-language composition** — Rust and Python components linked into one
  application with [`wac`](https://github.com/bytecodealliance/wac).
- **Bidirectional async streaming** — the `extractor` interface is an `async`
  function taking a `stream<u8>` and returning a `stream<tuple<string, string>>`.
- **An async `wasi:cli/run`** — the interesting constraint described below.
- **Idiomatic async `wasi:http`** — URL inputs are fetched with the outgoing
  HTTP client, using the `http` crate's request/response types via `wasip3`'s
  `http-compat` feature.

## The async pitfall (and why `metadata-printer` is built the way it is)

A plain `wasm32-wasip2` binary (`fn main`) produces a component whose
`wasi:cli/run` export is lifted **synchronously** by the Rust standard library.
A synchronous task may not block on an async import, so the moment such a `main`
tries to drive an async `stream`/`future` import the runtime traps with:

```
cannot block a synchronous task before returning
```

To export an **async** `run` instead, `metadata-printer` is built as a `cdylib`
(not a `bin`) and uses the [`wasip3`](https://crates.io/crates/wasip3) crate's
`wasi::cli::command::export!` macro, whose `Guest::run` is
`async fn run() -> Result<(), ()>`. The crate still targets `wasm32-wasip2`, so
`std` keeps a working filesystem and stdio: file reads and printing use ordinary
`std::fs` / `std::io` APIs, which lower to synchronous `wasi:*@0.2.0` imports.
An async task may freely call those synchronous imports — the trap above is the
*opposite* situation (a synchronous task blocking on an async import). Only the
cross-component `extractor` exchange uses the async component-model ABI.

The `wasm32-wasip2` linker componentizes the `cdylib` automatically, merging the
component-type sections from `command::export!` (the async `wasi:cli/run`
export), `std` (the `wasi:*@0.2.0` imports), and the custom `extractor` import
into a single component — no separate `wasm-tools component new` step is needed.

## Fetching by URL

When the argument starts with `http://` or `https://`, `metadata-printer`
fetches it over `wasi:http` instead of reading from disk. The request goes
through `wasip3::http::client::send`, which is `async` — another import an async
`run` can drive but a synchronous `main` cannot.

The raw WASI HTTP API works in terms of `Request`/`Response` *resources* and
body `stream`s. Enabling `wasip3`'s **`http-compat`** feature adds conversions
to and from the ecosystem-standard [`http`](https://crates.io/crates/http)
crate, so the code builds the request and reads the response with idiomatic
types:

```rust
let request = http::Request::builder()
    .method(http::Method::GET)
    .uri(url)
    .body(http_body_util::Empty::<bytes::Bytes>::new())?;

let wasi_request = wasip3::http_compat::http_into_wasi_request(request)?;
let wasi_response = wasip3::http::client::send(wasi_request).await?;
let response = wasip3::http_compat::http_from_wasi_response(wasi_response)?;

let body = response.into_body().collect().await?.to_bytes();
```

See the repository-root [`OUTLINE.md`](../../../OUTLINE.md) for the broader
discussion of this and other Component Model pitfalls.

## Layout

| Path | Role |
| --- | --- |
| [../../wit/metadata-parser/world.wit](../../wit/metadata-parser/world.wit) | The `extractor` interface plus the `metadata-parser` and `metadata-printer` worlds. |
| [../../components/metadata-parser/app.py](../../components/metadata-parser/app.py) | Python metadata extractor, compiled with `componentize-py`. |
| [../../components/metadata-printer/src/lib.rs](../../components/metadata-printer/src/lib.rs) | Rust CLI: async `wasi:cli/run`, file/URL reading, streaming, formatting. |
| [testdata/sample.html](testdata/sample.html) | A rich sample document to extract from. |
| [justfile](justfile) | Build, compose, run, and test recipes for [`just`](https://github.com/casey/just). |

## Prerequisites

The dev container in this repository ships with everything below; versions are
the ones this example was validated against.

- Rust toolchain with the `wasm32-wasip2` target
  (`rustup target add wasm32-wasip2`)
- [`componentize-py`](https://github.com/bytecodealliance/componentize-py) 0.23
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) 1.251
- [`wac`](https://github.com/bytecodealliance/wac) 0.10
- [`wasmtime`](https://github.com/bytecodealliance/wasmtime) 45 (with WASIp3 support)

## Build and run

The example is driven by [`just`](https://github.com/casey/just):

```sh
just              # list recipes
just build        # build both components + compose -> app.wasm
just run-sample   # build then run against testdata/sample.html
just run FILE     # build then run against your own file
just run URL      # build then run against an http(s) URL
just test         # run against the sample and assert key metadata is extracted
just clean        # remove build artifacts
```

`just run-sample` ultimately invokes:

```sh
wasmtime run -W component-model-async=y -S p3 -S http -S inherit-network --dir . app.wasm testdata/sample.html
```

- `-W component-model-async=y` enables the component-model async ABI.
- `-S p3` enables the host's WASIp3 (async) APIs.
- `-S http` enables the host's `wasi:http` implementation (needed for URL inputs).
- `-S inherit-network` lets the guest reach the network (needed for URL inputs).
- `--dir .` grants read access to the working directory so the CLI can open the
  input file.

Expected output:

```
Metadata for testdata/sample.html
=================================
lang                   en
charset                utf-8
meta:viewport          width=device-width, initial-scale=1
title                  Widgets, Gadgets & Gizmos — Acme Corp
meta:description       Acme Corp builds the finest widgets, gadgets, and gizmos in the business.
meta:author            Wile E. Coyote
meta:keywords          widgets, gadgets, gizmos, acme
meta:og:title          Widgets, Gadgets & Gizmos
meta:og:type           website
meta:og:url            https://example.com/products
meta:content-language  en
link:canonical         https://example.com/products
link:icon              /favicon.ico
h1                     Everything you need, and a few things you don't
```

## The WIT interface

```wit
interface extractor {
    extract: async func(html: stream<u8>) -> stream<tuple<string, string>>;
}

world metadata-parser  { export extractor; }   // Python
world metadata-printer { import extractor; }   // Rust CLI
```

## Limitations

- **HTML in, metadata out.** The CLI fetches/reads a document and extracts a
  fixed set of metadata; it is a composition smoke test, not a general scraper.
- The `wasip3` crate tracks a WASIp3 **draft** snapshot. The exact
  `@0.3.0-rc-*` version must match what your `wasmtime` understands; a mismatch
  shows up as a linker error naming `wasi:cli/...`. The pinned toolchain in this
  repository is known to agree.
