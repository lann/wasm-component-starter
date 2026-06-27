// End-to-end smoke test for the browser-tgz-maker app, runnable under Node
// (which, like the browser, drives the transpiled component over JSPI).
//
// It mirrors exactly what the browser does:
//   1. Build a `stream<entry>`, each entry carrying its name, size, and its own
//      `stream<u8>` of bytes.
//   2. `archive(entries)` -> a ReadableStream of the gzipped tar.
//      Internally the component encodes a tar stream and pipes it through the
//      imported `compressor` (../web/compressor.js, backed by the platform's
//      CompressionStream) -- the async streaming *import* that exercises the
//      jco #1601 fix.
//   3. Collect, gunzip, and assert the result is a valid tar of the inputs.
//
// Usage: node test/smoke.mjs [path/to/archiver.js]

import { gunzipSync } from "node:zlib";
import { ReadableStream } from "node:stream/web";

const generated =
    process.argv[2] ?? new URL("../web/generated/archiver.js", import.meta.url).href;

const { archiver } = await import(generated);
const { archive } = archiver;

// --- Fixture "files" -------------------------------------------------------

const encoder = new TextEncoder();
const files = [
    { name: "hello.txt", bytes: encoder.encode("Hello, streaming tar!\n") },
    { name: "nested/data.bin", bytes: new Uint8Array(1000).map((_, i) => i % 256) },
    { name: "empty.txt", bytes: new Uint8Array(0) },
    { name: "big.txt", bytes: encoder.encode("x".repeat(100_000)) },
];

// The `stream<entry>` describing the archive members, in order. Each entry
// carries its own `stream<u8>` of bytes, yielded in small chunks to exercise
// the streaming path (never holding a whole file at once).
function entryStream() {
    let index = 0;
    return new ReadableStream({
        pull(controller) {
            if (index < files.length) {
                const f = files[index++];
                controller.enqueue({
                    name: f.name,
                    size: BigInt(f.bytes.length),
                    contents: fileContents(f.bytes),
                });
            } else {
                controller.close();
            }
        },
    });
}

// One file's bytes as a `stream<u8>`, emitted in small chunks.
function fileContents(bytes) {
    return new ReadableStream({
        start(controller) {
            for (let off = 0; off < bytes.length; off += 4096) {
                controller.enqueue(bytes.subarray(off, off + 4096));
            }
            controller.close();
        },
    });
}

// jco surfaces a component `stream<u8>` as its own async-iterable `Stream`
// object (not a WHATWG `ReadableStream`), yielding `Uint8Array` chunks. Wrap it
// in a real `ReadableStream` so it can be piped through `CompressionStream`.
function toReadable(jcoStream) {
    const iterator = jcoStream[Symbol.asyncIterator]();
    return new ReadableStream({
        async pull(controller) {
            const { value, done } = await iterator.next();
            if (done) {
                controller.close();
                return;
            }
            controller.enqueue(value instanceof Uint8Array ? value : Uint8Array.from(value));
        },
    });
}

// Collect any async-iterable of byte chunks into one Uint8Array.
async function collect(stream) {
    const chunks = [];
    let total = 0;
    for await (const value of stream) {
        const chunk = value instanceof Uint8Array ? value : Uint8Array.from(value);
        chunks.push(chunk);
        total += chunk.length;
    }
    const out = new Uint8Array(total);
    let pos = 0;
    for (const c of chunks) {
        out.set(c, pos);
        pos += c.length;
    }
    return out;
}

// --- Minimal tar reader for verification -----------------------------------

function parseTar(bytes) {
    const out = [];
    let off = 0;
    const readStr = (start, len) => {
        const slice = bytes.subarray(off + start, off + start + len);
        const nul = slice.indexOf(0);
        return new TextDecoder().decode(nul === -1 ? slice : slice.subarray(0, nul));
    };
    while (off + 512 <= bytes.length) {
        // Two consecutive zero blocks terminate the archive.
        if (bytes.subarray(off, off + 512).every((b) => b === 0)) break;
        const name = readStr(0, 100);
        const size = parseInt(readStr(124, 12).trim() || "0", 8);
        const content = bytes.subarray(off + 512, off + 512 + size);
        out.push({ name, content: new Uint8Array(content) });
        off += 512 + Math.ceil(size / 512) * 512;
    }
    return out;
}

function assert(cond, msg) {
    if (!cond) {
        console.error(`FAIL: ${msg}`);
        process.exit(1);
    }
}

// --- Run the pipeline ------------------------------------------------------

// The nested-stream interface (`archive(entries: stream<entry>)`, each entry
// carrying its own `contents: stream<u8>`) needs the patched jco installed by
// `just patch-jco`; stock jco 1.21.0 throws an (internally swallowed)
// `ReferenceError` while lowering an entry's `name`, which stalls the read side
// forever. With the patch the pipeline round-trips fine (and so does the same
// component under wasmtime, see ../../apps/cli-tgz-maker). This watchdog guards
// against any future stall so the test fails fast instead of hanging.
const WATCHDOG_MS = 10_000;
const watchdog = setTimeout(() => {
    console.error(
        `FAIL: timed out after ${WATCHDOG_MS} ms.\n` +
            "  The nested-stream pipeline stalled. Did you run 'just patch-jco'?\n" +
            "  Stock jco 1.21.0 cannot drive archive(entries: stream<entry>)\n" +
            "  where each entry carries its own contents: stream<u8>; the patch\n" +
            "  under jco-patch/ fixes it. The same component also round-trips\n" +
            "  under wasmtime via ../../apps/cli-tgz-maker.",
    );
    process.exit(1);
}, WATCHDOG_MS);
watchdog.unref();

const archiveStream = toReadable(await archive(entryStream()));

const gzipped = await collect(archiveStream);
const tar = gunzipSync(gzipped);
const members = parseTar(tar);

clearTimeout(watchdog);

assert(members.length === files.length, `expected ${files.length} members, got ${members.length}`);
for (let i = 0; i < files.length; i++) {
    const got = members[i];
    const want = files[i];
    assert(got.name === want.name, `member ${i} name: got "${got.name}", want "${want.name}"`);
    assert(
        got.content.length === want.bytes.length &&
            got.content.every((b, j) => b === want.bytes[j]),
        `member ${i} (${want.name}) content mismatch (${got.content.length} vs ${want.bytes.length} bytes)`,
    );
}

console.log(`PASS: ${members.length} files archived, gzipped, and round-tripped through the component`);
console.log(`  tar bytes:  ${tar.length}`);
console.log(`  gzip bytes: ${gzipped.length}`);
for (const m of members) console.log(`  - ${m.name} (${m.content.length} bytes)`);
