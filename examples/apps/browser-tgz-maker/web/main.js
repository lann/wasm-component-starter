// Browser driver for the `archiver` component.
//
// Data flow (every hop streams; nothing is buffered whole):
//
//   FileList
//     -> a list<entry> (name + size of each File) plus one stream<u8> of every
//        file's bytes concatenated in order
//        -> archiver.archive(entries, contents)  ==> tar.gz stream
//           -> download as archive.tar.gz
//
// The gzip step happens *inside* the component, which calls back out to the
// host's `compressor` import (see ./compressor.js, backed by the browser's
// CompressionStream). From JavaScript's side it is a single call that takes the
// file list and the concatenated byte stream in and yields the finished tar.gz
// out.

import { archiver } from "./generated/archiver.js";

const { archive } = archiver;

const filesInput = document.getElementById("files");
const goButton = document.getElementById("go");
const logEl = document.getElementById("log");

function log(message) {
    logEl.textContent += `\n${message}`;
}

// The component is ready as soon as the module is imported.
logEl.textContent = "Component loaded. Choose files, then click the button.";
goButton.disabled = false;

goButton.addEventListener("click", async () => {
    const files = [...filesInput.files];
    if (files.length === 0) {
        log("Select at least one file first.");
        return;
    }

    goButton.disabled = true;
    logEl.textContent = `Archiving ${files.length} file(s)…`;

    try {
        const totalBytes = files.reduce((sum, f) => sum + f.size, 0);
        log(`Total input: ${totalBytes.toLocaleString()} bytes`);

        // One call in, one tar.gz stream out -- the component tars the bytes and
        // pipes them through the imported (host-provided) gzip compressor.
        const entries = files.map((file) => ({
            name: file.name,
            size: BigInt(file.size),
        }));
        const archiveStream = toReadable(await archive(entries, concatFiles(files)));

        await download(archiveStream, "archive.tar.gz");
        log("Done. archive.tar.gz is ready.");
    } catch (err) {
        log(`Error: ${err?.message ?? err}`);
        throw err;
    } finally {
        goButton.disabled = false;
    }
});

// Build the single `stream<u8>` the component consumes: every file's bytes
// concatenated in the same order as `entries`. Files are read lazily, one chunk
// at a time, so a multi-gigabyte selection never lands in memory at once. The
// archiver knows each member's length from its `entry.size`, so it can slice
// this flat byte stream back into individual files.
function concatFiles(files) {
    const readers = files.map((file) => file.stream().getReader());
    let index = 0;
    return new ReadableStream({
        async pull(controller) {
            while (index < readers.length) {
                const { value, done } = await readers[index].read();
                if (done) {
                    index += 1;
                    continue;
                }
                controller.enqueue(value);
                return;
            }
            controller.close();
        },
    });
}

// jco surfaces a component `stream<u8>` as its own async-iterable `Stream`
// object (yielding `Uint8Array`s), not a WHATWG `ReadableStream`. Wrap it so it
// can be piped and consumed with the standard streams API.
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

// Stream the result to disk. Where the File System Access API is available the
// bytes are written as they arrive (true streaming download); otherwise fall
// back to buffering into a Blob and clicking an anchor.
async function download(stream, suggestedName) {
    if ("showSaveFilePicker" in window) {
        const handle = await window.showSaveFilePicker({
            suggestedName,
            types: [{ description: "gzip archive", accept: { "application/gzip": [".tar.gz"] } }],
        });
        const writable = await handle.createWritable();
        await stream.pipeTo(writable);
        return;
    }

    const blob = await new Response(stream).blob();
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = suggestedName;
    anchor.click();
    URL.revokeObjectURL(url);
}
