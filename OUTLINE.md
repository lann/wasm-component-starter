# Agent Context Guide: WebAssembly Component Model & WASI P3

This document serves as a high-density reference for autonomous agents and expert systems building within the WebAssembly Component Model ecosystem. It is optimized for context efficiency, prioritizing structural rules and tooling boundaries over exhaustive API definitions.

## I. Canonical Specifications

Do not memorize these documents wholesale; retain their scope to query them efficiently.

* **The Component Model Explainer:** The architectural blueprint. Defines language agnosticism, virtualization boundaries, the share-nothing architecture, and the canonical ABI for complex cross-module type passing.
* **The Concurrency Explainer:** The definitive standard on the async ABI. Crucial for understanding cooperative multitasking and how components yield backpressure to the host instead of blocking an OS thread.
* **The WIT (Wasm Interface Type) Specification:** The IDL syntax and semantics. The absolute source of truth for type mapping, resource definitions, and world declarations.

## II. Toolchain Ecosystem

Distinguish strictly between host runtimes, linkers, build tools, and code generators.

* **`wasmtime`:** The canonical host runtime. Executes components and provisions host-side WASI implementations. *(Note: Embedder API provisioning details are highly useful for test harnesses but should be deferred to external documentation to save context.)*
* **`wasm-tools`:** The low-level inspection and manipulation suite. Validates components, translates text-to-binary (`wat2wasm`), and inspects structures (`wasm-tools component info`). It handles "lifting and lowering" (translating complex WIT types to/from Core Wasm linear memory), though interface designers rarely need these low-level details.
* **`wac` (WebAssembly Compose):** The component linker. Statically satisfies component imports by plugging them into the exports of other components.
* **`wit-bindgen`:** The code generator. Translates WIT files into guest-side bindings for interacting with imports/exports.
* **`jco`:** The JavaScript toolchain. Transpiles Wasm components into standard ES modules for Node.js or browser execution.

### Host Invocation Flags (`wasmtime`)

A component only gets a host capability if the runtime is told to provision it; the relevant imports are otherwise unsatisfied at instantiation. The flags the examples in this repo rely on (discover the full set with `wasmtime run -S help` / `-W help`):

* `-W component-model-async=y` — enable the component-model async ABI. Required for *any* `stream`/`future` or async export.
* `-S p3` — provision the host's WASIp3 (async) APIs. Pairs with the `wasip3` crate.
* `-S http` — provision `wasi:http`. Required to satisfy a `wasi:http` `client.send` import.
* `-S inherit-network` — grant the guest network access for outgoing connections.
* `--dir <host>[::<guest>]` — preopen a directory so `std::fs` / `wasi:filesystem` can resolve paths.

## III. WASI (WebAssembly System Interface) Evolution

WASI defines the standard API boundaries. Understanding the paradigm shift between stable (0.2) and upcoming (0.3) versions is critical for architectural planning.

* **WASI P2 (0.2.x) vs. P3 (0.3.0-drafts):**
* **I/O:** P3 completely replaces the complex `wasi:io` package—which relied on manual pollables and stream management—with native component model async features.
* **HTTP:** P3 merges `wasi:http` incoming and outgoing types into a unified model, an architectural simplification enabled directly by the native async primitives.


* **Common Worlds:** Components target specific "worlds" defining their execution environment:
* `wasi:cli/command`: Traditional CLI execution.
* `wasi:http/proxy` (transitioning to `wasi:http/service` in 0.3): HTTP-driven request/response handling.



## IV. Rust Component Authoring Targets

Rust is the primary language for component authoring. Target selection dictates runtime capabilities.

* **`wasm32-wasip2`:** The stable standard. Provides a complete sysroot mapped to WASI Preview 2 synchronous APIs.
* **`wasm32-unknown-unknown`:** Bare-metal WebAssembly. Requires extensive polyfilling for I/O, but is often the least-bad option for advanced, custom use cases where standard WASI bindings interfere or are unnecessary.
* **The `wasip3` crate:** The experimental edge for async capability. It provides bindings for asynchronous host capabilities and is used in conjunction with `wasm32-wasip2` or `wasm32-unknown-unknown`. *(Do not use the `wasm32-wasip3` target; it is not ready for use at the time of this writing).*

### The `wasm32-wasip2` CLI Cannot Export an Async `run`

* **The Trap:** Building a `wasm32-wasip2` *binary* (`fn main`) yields a component whose `wasi:cli/run` export is **lifted synchronously** by the Rust standard library's pre-generated bindings. If `main` then tries to drive an async import (e.g. `wit_bindgen::block_on` over a `stream`/`future`), the runtime traps with `cannot block a synchronous task before returning`. A synchronous task is forbidden from yielding to the host, which is exactly what awaiting an async import requires.
* **The Reality:** The synchronous `run` lifting is baked into `std` for the `wasm32-wasip2` target; you cannot opt the standard `main` into the async ABI.
* **The Fix:** To author a command that consumes async imports, do **not** use a `bin`/`fn main` crate. Instead build a `cdylib` and export an *async* `wasi:cli/run` yourself. The `wasip3` crate's `wasi::cli::command::export!` macro provides exactly this (its `Guest::run` is `async fn run() -> Result<(), ()>`). A `cdylib` on the ordinary `wasm32-wasip2` target works well: `std` keeps a functioning filesystem and stdio (lowered to synchronous `wasi:*@0.2.0` imports, which an async task may freely call), the async `run` export coexists with those synchronous imports, and the target's linker componentizes the result automatically — no `wasm-tools component new` step. Generate any custom interface bindings with `wit-bindgen`. See `examples/async-composition/` for a worked end-to-end example. *(Bare `wasm32-unknown-unknown` is an alternative when you want `std` to contribute no WASI imports at all, but then every byte of I/O must go through `wasip3` and you must finalize the core module with `wasm-tools component new`.)*

### Consuming Async `wasi:http` with Idiomatic `http` Types

* **The client:** `wasip3` exposes the outgoing HTTP client as `wasip3::http::client::send(request).await` (async; same type signature as a `handler.handle` export). It operates on raw WASI `Request`/`Response` *resources* whose bodies are component-model `stream`s. The client is an **import** — it needs no entry in your own WIT, but the host must provision it (`-S http -S inherit-network`).
* **The Trap:** Hand-rolling those resources and their body streams is verbose and easy to get wrong.
* **The Fix:** Enable the `wasip3` crate's **`http-compat`** feature to work in terms of the ecosystem-standard [`http`](https://crates.io/crates/http) crate. It adds `http_compat::http_into_wasi_request` / `http_from_wasi_response` (plus the request/response inverses) and an `http-body` adapter for incoming bodies, pulling in `http`, `http-body`, `bytes`, and `thiserror`. Add `http-body-util` yourself for `Empty`/`Full` request bodies and `BodyExt::collect`. End-to-end GET: build an `http::Request` → `http_into_wasi_request` → `client::send().await` → `http_from_wasi_response` → drain the streaming body (`resp.into_body().collect().await?.to_bytes()`). See `examples/async-composition/cli-app` (URL inputs).

## V. Architectural Pitfalls & Edge Cases

### 1. Import Graph Acyclicity

The component model strictly prohibits cyclical imports. Components are instantiated via a topological sort.

* **The Trap:** Designing bidirectional callbacks via imports, mimicking standard application development patterns.
* **The Reality:** The import graph is a Directed Acyclic Graph (DAG), not a strict tree. Component C can import both A and B, and B can import A, as long as no cycle is formed.
* **The Fix:** When bidirectional data flow is inherently required, introduce a new component to mediate between the dependent components.

### 2. Runtime Reentrancy Rules

Component instances are strictly non-reentrant.

* **The Trap:** Attempting cooperative control flow using synchronous cross-component calls.
* **The Reality:** Reentrancy rules are strictly enforced and not configurable. If a synchronous call chain circles back to an active instance, the runtime traps instantly. The definition of reentrance becomes highly nuanced when dealing with async tasks, requiring precise yielding to the host to avoid traps.

### 3. Resource Type Virtuality and Proxying

Resources are opaque, instance-bound handles. If Component A exports a `File` resource, *only* that specific instance of Component A can allocate or interact with its internal state.

* **The Trap:** Attempting to subclass, extend, or directly cast an imported resource type into an exported one.
* **The Fix:** To "wrap" or modify a resource's behavior, export a distinct "proxy" resource type. Store the imported handle inside the new resource's internal state, and explicitly map/mediate methods between the two boundaries.

### 4. Concurrency vs. Parallelism (The Async Deadlock)

Component model async provides *cooperative concurrency*, not true parallelism.

* **The Execution Model:** Single-threaded cooperative execution bound to the instance call stack. This directly contrasts with multithreaded runtimes (like Tokio) that utilize M:N scheduling across multiple OS threads.
* **The Trap (Deadlocks):** In a multithreaded runtime, deadlocks are usually driven by complex lock acquisitions. In the component model, high deadlock risk arises from interdependencies between async calls, futures, and streams. If two futures can resolve in either order, but a consumer tightly loops assuming one specific resolution sequence, the single thread cannot yield back to the host, resulting in a deadlock. Treat the execution environment like a single-threaded event loop.

### 5. Stream Reads Require Non-Zero Buffer Capacity

`wit-bindgen`'s `StreamReader::read(buf)` reads into the *spare capacity* of the `Vec` you pass it, returning that buffer refilled alongside a `StreamResult`.

* **The Trap:** Calling `reader.read(Vec::new()).await` to "read whatever is available." With zero spare capacity the read can never make progress: it yields `StreamResult::Complete(0)` indefinitely (a busy hang), which is **not** how end-of-stream is signalled.
* **The Fix:** Always pass `Vec::with_capacity(N)` with `N > 0` (e.g. a small drain buffer, or ~16 KiB per frame). Loop until you observe `StreamResult::Dropped` / `Cancelled` for end-of-stream; `Complete(n)` merely means a batch arrived — keep reading. The `http_compat` incoming-body reader follows exactly this rule internally.