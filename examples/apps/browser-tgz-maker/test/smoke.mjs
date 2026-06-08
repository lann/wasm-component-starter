// End-to-end smoke test for the browser-tgz-maker app, runnable under Node
// (which, like the browser, drives the transpiled component over JSPI).
//
// It mirrors exactly what the browser does:
//   1. Build a `list<entry>` (name + size of each member) plus one `stream<u8>`
//      of every member's bytes concatenated in order.
//   2. `archive(entries, contents)` -> a ReadableStream of the gzipped tar.
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

// A single ReadableStream of every file's bytes concatenated in order, yielded
// in small chunks to exercise the streaming path (never holding a whole file at
// once). This is the flat `stream<u8>` the component consumes; it slices the
// members back apart using each `entry.size`.
function concatenatedContents() {
    return new ReadableStream({
        start(controller) {
            for (const f of files) {
                for (let off = 0; off < f.bytes.length; off += 4096) {
                    controller.enqueue(f.bytes.subarray(off, off + 4096));
                }
            }
            controller.close();
        },
    });
}

// The `list<entry>` describing the archive members, in order.
function entries() {
    return files.map((f) => ({ name: f.name, size: BigInt(f.bytes.length) }));
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

const archiveStream = toReadable(await archive(entries(), concatenatedContents()));

const gzipped = await collect(archiveStream);
const tar = gunzipSync(gzipped);
const members = parseTar(tar);

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
