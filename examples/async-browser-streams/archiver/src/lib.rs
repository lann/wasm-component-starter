//! `archiver` component: a streaming `tar.gz` encoder driven through
//! component-model `stream`s.
//!
//! The component exports the `archiver` interface and *imports* a `compressor`
//! interface for the gzip step. It is meant to be transpiled with
//! [`jco`](https://github.com/bytecodealliance/jco) and run in the browser (or
//! Node) over JSPI: JavaScript lowers a `ReadableStream` of file bytes into
//! [`archive`](Component), the component encodes a tar stream and pipes it
//! through the imported compressor, and JavaScript reads the gzipped archive
//! back out as another stream.
//!
//! ## Returning a stream from an async export
//!
//! An async export cannot block on its own output, so it can't fill a result
//! stream before returning. [`archive`](Component) instead spawns the tar
//! producer with [`wit_bindgen::spawn`], hands the tar stream to the imported
//! compressor, and returns the compressor's gzipped output stream *directly* --
//! the component never has to own or re-emit the result bytes itself.
//!
//! ## jco note (bug bytecodealliance/jco#1601)
//!
//! Transpiling an async *import* whose parameter is a `future`/`stream` with
//! `--async-mode jspi` is broken upstream. This example deliberately exercises
//! exactly that (the `compressor.compress` import takes a `stream<u8>`); the
//! repo carries a small jco patch to work around it until the fix lands.

wit_bindgen::generate!({
    world: "archiver-component",
    path: "../wit",
});

use crate::example::async_browser_streams::compressor;
use exports::example::async_browser_streams::archiver::{Entry, Guest};
use tar_core::builder::HeaderBuilder;
use tar_core::EntryType;
use wit_bindgen::{StreamReader, StreamResult, StreamWriter};

/// Copy at most this many bytes per stream read/write hop.
const CHUNK: usize = 64 * 1024;

/// The type backing the `archiver` export.
struct Component;

impl Guest for Component {
    /// Stream `contents` into a tar archive described by `entries`, gzip it via
    /// the imported compressor, and return the resulting `tar.gz` stream.
    async fn archive(entries: Vec<Entry>, contents: StreamReader<u8>) -> StreamReader<u8> {
        // Produce the tar bytes on a detached task and hand that stream to the
        // host's gzip compressor. We return the compressor's output stream
        // straight out of the export -- this component never has to read and
        // re-emit the gzipped bytes itself. (`compress` is the async streaming
        // *import* that the jco patch fixes; see the module note.)
        let (tar_tx, tar_rx) = wit_stream::new();
        wit_bindgen::spawn(produce_tar(entries, contents, tar_tx));
        compressor::compress(tar_rx).await
    }
}

export!(Component);

/// Producer task spawned by [`archive`](Component): writes the tar byte stream
/// to `tx`.
async fn produce_tar(
    entries: Vec<Entry>,
    mut contents: StreamReader<u8>,
    mut tx: StreamWriter<u8>,
) {
    for entry in entries {
        // Header first -- it declares the length, so the reader knows exactly
        // how many content bytes follow.
        let _ = tx
            .write_all(build_header(&entry.name, entry.size).to_vec())
            .await;

        // Copy exactly `entry.size` bytes from the shared input stream. We never
        // read past the declared length, so the next member's bytes stay queued.
        let mut remaining = entry.size;
        while remaining > 0 {
            let want = remaining.min(CHUNK as u64) as usize;
            let (status, buf) = contents.read(Vec::with_capacity(want)).await;
            if !buf.is_empty() {
                remaining -= buf.len() as u64;
                let _ = tx.write_all(buf).await;
            }
            if matches!(status, StreamResult::Dropped | StreamResult::Cancelled) {
                // Input ended early; stop emitting this member.
                remaining = 0;
            }
        }

        // tar pads each member out to a 512-byte boundary with zeros.
        let padding = (512 - (entry.size % 512)) % 512;
        if padding > 0 {
            let _ = tx.write_all(vec![0u8; padding as usize]).await;
        }
    }

    // The archive ends with two zero-filled 512-byte blocks.
    let _ = tx.write_all(vec![0u8; 1024]).await;
    drop(tx);
}

/// Build a 512-byte `ustar` header for a regular file via [`tar_core`].
///
/// `tar_core` formats every numeric field as octal and computes the checksum;
/// we only feed it the path, size, and a fixed mode/mtime for reproducibility.
/// The name is truncated to the 100-byte `ustar` name field, matching what a
/// browser-supplied path can carry without a `prefix`/PAX extension.
fn build_header(name: &str, size: u64) -> [u8; 512] {
    let name_bytes = name.as_bytes();
    let name = &name_bytes[..name_bytes.len().min(100)];

    let mut builder = HeaderBuilder::new_ustar();
    builder
        .path(name)
        .expect("name is truncated to 100 bytes")
        .mode(0o644)
        .expect("0o644 fits the mode field")
        .size(size)
        .expect("size fits the ustar octal field")
        .mtime(0)
        .expect("0 fits the mtime field")
        .entry_type(EntryType::Regular);

    *builder.finish().as_bytes()
}
