//! `gzip-compressor` component: a pure-Rust provider of the `compressor`
//! interface.
//!
//! It exports a single async streaming function, [`compress`](Component), that
//! gzip-encodes an incoming `stream<u8>` and yields the gzip-framed bytes on an
//! outgoing `stream<u8>`. It imports nothing -- no filesystem, no clock, no
//! network -- so it is a capability-free byte transform that can be composed
//! into any pipeline needing gzip. In this repo it satisfies the `tar-archiver`
//! component's `compressor` import inside the `cli-tgz-maker` app, playing the
//! same role the browser's `CompressionStream` plays in the browser app.
//!
//! ## Streaming, incremental gzip
//!
//! It uses [`flate2`](https://crates.io/crates/flate2)'s `write::GzEncoder`
//! with the pure-Rust `miniz_oxide` backend. We write each input chunk to the
//! encoder and immediately drain whatever compressed bytes it has produced so
//! far, so the input is never buffered whole. When the input ends,
//! [`GzEncoder::finish`] flushes the final deflate block and the gzip trailer.
//!
//! ## Returning a stream from an async export
//!
//! An async export cannot block on its own output, so [`compress`](Component)
//! spawns the encoder as a detached task with [`wit_bindgen::spawn`] and returns
//! the reader end of the output stream immediately.

use flate2::write::GzEncoder;
use flate2::Compression;
use std::io::Write;
use wit_bindgen::{StreamReader, StreamResult, StreamWriter};

wit_bindgen::generate!({
    path: "../../wit/archive",
    inline: "
        package inline:inline;
        world inline {
            export example:archive/compressor@0.1.0;
        }
    ",
    generate_all,
});
use exports::example::archive::compressor::Guest;

/// Read at most this many input bytes per stream hop.
const CHUNK: usize = 64 * 1024;

/// The type backing the `compressor` export.
struct Component;

impl Guest for Component {
    /// gzip-compress `data`, streaming the result.
    async fn compress(data: StreamReader<u8>) -> StreamReader<u8> {
        let (tx, rx) = wit_stream::new();
        wit_bindgen::spawn(encode(data, tx));
        rx
    }
}

export!(Component);

/// Producer task spawned by [`compress`](Component): reads input chunks, gzip
/// encodes them incrementally, and writes the framed bytes to `tx`.
async fn encode(mut data: StreamReader<u8>, mut tx: StreamWriter<u8>) {
    // The encoder writes compressed bytes into this `Vec`; we drain it after
    // every input chunk and forward whatever is ready.
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());

    loop {
        let (status, buf) = data.read(Vec::with_capacity(CHUNK)).await;
        if !buf.is_empty() {
            // `write_all` to an in-memory writer is infallible.
            let _ = encoder.write_all(&buf);
            let ready = std::mem::take(encoder.get_mut());
            if !ready.is_empty() {
                let _ = tx.write_all(ready).await;
            }
        }
        if matches!(status, StreamResult::Dropped | StreamResult::Cancelled) {
            break;
        }
    }

    // Flush deflate's final block and the gzip trailer (CRC32 + ISIZE).
    if let Ok(tail) = encoder.finish() {
        if !tail.is_empty() {
            let _ = tx.write_all(tail).await;
        }
    }
}
