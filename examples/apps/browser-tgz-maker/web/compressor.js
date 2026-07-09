// Implementation of the component's imported `compressor` interface.
//
// The archiver component declares gzip as an async, streaming *import* rather
// than bundling a compressor: a WebAssembly component can't reach the Web
// platform, so it lets the host provide compression. Here that host
// implementation is a thin wrapper around the platform's native
// `CompressionStream` (a global in both modern browsers and Node).
//
// `jco` wires this module in via the transpile `--map` flag; the generated
// `archiver.js` does `import { compress } from '../compressor.js'`. The
// component calls `compress` with the tar byte stream and consumes the gzip
// byte stream it returns -- all without buffering.

/**
 * gzip-compress a byte stream.
 *
 * @param {ReadableStream<Uint8Array> | AsyncIterable<Uint8Array>} data
 * @returns {ReadableStream<Uint8Array>}
 */
export function compress(data) {
    return toReadable(data).pipeThrough(new CompressionStream("gzip"));
}

// The lifted import parameter is a `ReadableStream` in practice, but accept any
// async-iterable of byte chunks defensively and normalise chunks to Uint8Array
// (CompressionStream requires BufferSource chunks).
function toReadable(stream) {
    if (stream instanceof ReadableStream) {
        return stream;
    }
    const iterator = stream[Symbol.asyncIterator]();
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
