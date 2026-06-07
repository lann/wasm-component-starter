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

| Example | What it shows |
| --- | --- |
| [examples/async-composition](examples/async-composition) | A Rust CLI component and a Python library component linked with `wac`, streaming data both directions through an `async` WIT interface. Demonstrates how to export an **async** `wasi:cli/run` (which a plain `wasm32-wasip2` binary cannot do) from a `wasm32-wasip2` `cdylib` using the `wasip3` crate, while still using `std` for file and stdio access, and how to fetch URLs over async `wasi:http` with the `http` crate via `wasip3`'s `http-compat` feature. |

## Toolchain

The included dev container ships with the canonical Component Model toolchain:

- [`wasmtime`](https://github.com/bytecodealliance/wasmtime) — host runtime
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) — inspect, validate, and assemble components
- [`wac`](https://github.com/bytecodealliance/wac) — the component linker (compose imports with exports)
- [`wit-bindgen`](https://github.com/bytecodealliance/wit-bindgen) — guest binding generator
- [`componentize-py`](https://github.com/bytecodealliance/componentize-py) — compile Python into a component
- A Rust toolchain with the `wasm32-wasip2` and `wasm32-unknown-unknown` targets

## Getting started

1. Open this repository in the dev container (VS Code: *Reopen in Container*).
2. Skim [OUTLINE.md](OUTLINE.md) for the lay of the land.
3. Build and run an example:

   ```sh
   cd examples/async-composition
   make run
   ```

4. Use an example as a template for your own components, or start a fresh world
   from the patterns in [OUTLINE.md](OUTLINE.md).

## Ways to use this repo

- **Start from an example.** Copy an `examples/` project and adapt its WIT,
  `Makefile`, and component sources.
- **Consult the reference.** [OUTLINE.md](OUTLINE.md) captures the rules and
  tooling boundaries that are easy to get wrong (cyclic imports, sync-vs-async
  `run`, target selection, composition order).
- **Drive it with an agent.** The reference and examples are written to give an
  autonomous coding agent enough grounded context to scaffold and compose
  components without rediscovering the pitfalls each time.
