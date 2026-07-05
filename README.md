# wasm-component-starter

A starting point for building **WebAssembly Component Model** projects.

The Component Model lets you write components in different languages, give each
one only the capabilities it needs, and compose them into a single application
that shares nothing but typed interfaces. This repository collects the pieces
needed to bootstrap that work — reference material, runnable examples, and a
dev container with the toolchain already installed — so you can go from an empty
folder to a composed, running component quickly.

## What's here

| Path | Purpose |
| --- | --- |
| [OUTLINE.md](OUTLINE.md) | A high-density agent/developer reference for the Component Model & WASI: canonical specs, the toolchain ecosystem, authoring targets, and the architectural pitfalls that bite first. Read this before designing a world. |
| [examples/](examples/) | Self-contained, runnable example projects. Each has its own README, WIT, and `justfile`. |

## Examples

Each example lives under [examples/](examples/), split into reusable
**components** ([examples/components/](examples/components)) and runnable
**apps** ([examples/apps/](examples/apps)) that compose those components and run
them. Every project has its own README, WIT, and `justfile`.

| App | What it shows |
| --- | --- |
| [examples/apps/cli-metadata-printer](examples/apps/cli-metadata-printer) | A Rust CLI component and a Python library component linked with `wac`, streaming data both directions through an `async` WIT interface. Demonstrates how to export an **async** `wasi:cli/run` (which a plain `wasm32-wasip2` binary cannot do) from a `wasm32-wasip2` `cdylib` using the `wasip3` crate, while still using `std` for file and stdio access, and how to fetch URLs over async `wasi:http` with the `http` crate via `wasip3`'s `http-compat` feature. |
| [examples/apps/cli-tgz-maker](examples/apps/cli-tgz-maker) | A three-component CLI `tar.gz` tool: a Rust CLI driver imports an async streaming `archiver`, which in turn imports an async streaming `compressor`, composed with `wac plug` and run under `wasmtime`. Demonstrates multi-step composition (plug into plug) and async streams flowing across three components. |
| [examples/apps/browser-tgz-maker](examples/apps/browser-tgz-maker) | The same `tar-archiver` component transpiled with `jco` and driven from the **browser** over JSPI, gzipping files through an **imported** async streaming `compressor` interface backed by the browser's `CompressionStream`. Demonstrates an async streaming import flowing guest → host → guest, returning a stream from an async export via `wit_bindgen::spawn`, and mapping a component import to a JS adapter with `jco --map`. Ships a small temporary patch (`just patch-jco`) for two jco 1.24.6 transpile bugs around async streaming imports (bytecodealliance/jco#1601). |

## Toolchain

The included dev container ships with the canonical Component Model toolchain:

- [`wasmtime`](https://github.com/bytecodealliance/wasmtime) — host runtime
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) — inspect, validate, and assemble components
- [`wac`](https://github.com/bytecodealliance/wac) — the component linker (compose imports with exports)
- [`wit-bindgen`](https://github.com/bytecodealliance/wit-bindgen) — guest binding generator
- [`componentize-py`](https://github.com/bytecodealliance/componentize-py) — compile Python into a component
- A Rust toolchain with the `wasm32-wasip2` and `wasm32-unknown-unknown` targets

The tool list and version pins live in a single shared installer,
[scripts/install-tools.sh](scripts/install-tools.sh), used by every
environment so they never drift:

| Environment | Entry point |
| --- | --- |
| Dev container (human or local agent) | [.devcontainer/post-create.sh](.devcontainer/post-create.sh) |
| CI | [.github/workflows/ci.yml](.github/workflows/ci.yml) via the [setup-toolchain](.github/actions/setup-toolchain/action.yml) composite action |
| Copilot cloud agent | [.github/workflows/copilot-setup-steps.yml](.github/workflows/copilot-setup-steps.yml) via the same composite action |
| Anywhere with Rust, Node, and Python | `just setup` |

## Getting started

1. Open this repository in the dev container (VS Code: *Reopen in Container*).
2. Skim [OUTLINE.md](OUTLINE.md) for the lay of the land.
3. Build and run an example:

   ```sh
   cd examples/apps/cli-tgz-maker
   just test
   ```

   Or, from the repository root, run every example's checks at once with the
   top-level [justfile](justfile):

   ```sh
   just ci
   ```

4. Use an example as a template for your own components, or start a fresh world
   from the patterns in [OUTLINE.md](OUTLINE.md).

## Ways to use this repo

- **Start from an example.** Copy an `examples/` project and adapt its WIT,
  `justfile`, and component sources.
- **Consult the reference.** [OUTLINE.md](OUTLINE.md) captures the rules and
  tooling boundaries that are easy to get wrong (cyclic imports, sync-vs-async
  `run`, target selection, composition order).
- **Drive it with an agent.** The reference and examples are written to give an
  autonomous coding agent enough grounded context to scaffold and compose
  components without rediscovering the pitfalls each time.
