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
//! ## Why the compressor is imported, not built in
//!
//! A WebAssembly component cannot reach the Web platform, so it cannot call the
//! browser's `CompressionStream`. Rather than ship a gzip implementation inside
//! the wasm, this component declares gzip as an async, streaming *import* and
//! lets the host satisfy it with a thin `CompressionStream('gzip')` adapter.
//! That keeps the component tiny and demonstrates an async streaming import
//! crossing the JS boundary (see the jco note below).
//!
//! ## Why this streams without buffering
//!
//! A tar `ustar` header records each member's length *before* its bytes. The
//! browser already knows every file's length (`File.size`), so it passes those
//! lengths in `entries` up front. That lets [`produce_tar`] emit a header and
//! then copy exactly `size` bytes from the input stream straight downstream, one
//! chunk at a time -- no file, and no archive, is ever fully resident in memory.
//!
//! ## Returning a stream from an async export
//!
//! An async export cannot block on its own output, so it can't fill the result
//! stream before returning. [`archive`](Component) creates a `wit_stream` pair,
//! spawns the tar producer (which owns the *writer*) with
//! [`wit_bindgen::spawn`], hands the *reader* to the imported compressor, and
//! returns the compressor's output stream.
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
use wit_bindgen::{StreamReader, StreamResult, StreamWriter};

/// Copy at most this many bytes per stream read/write hop.
const CHUNK: usize = 64 * 1024;

/// The type backing the `archiver` export.
struct Component;

impl Guest for Component {
    /// Stream `contents` into a tar archive described by `entries`, gzip it via
    /// the imported compressor, and return the resulting `tar.gz` stream.
    async fn archive(entries: Vec<Entry>, contents: StreamReader<u8>) -> StreamReader<u8> {
        let (out_tx, out_rx) = wit_stream::new();
        // Drive the whole pipeline on a detached task and return our own output
        // stream's reader. We deliberately do *not* forward the compressor's
        // stream handle straight out; instead we read it and re-emit, which
        // keeps this component the sole owner of its result stream.
        wit_bindgen::spawn(run_pipeline(entries, contents, out_tx));
        out_rx
    }
}

export!(Component);

/// Tar-encode `contents`, push the tar bytes through the imported gzip
/// compressor, and copy the compressed result into `out_tx`.
async fn run_pipeline(
    entries: Vec<Entry>,
    contents: StreamReader<u8>,
    mut out_tx: StreamWriter<u8>,
) {
    // Produce the tar bytes on a detached task...
    let (tar_tx, tar_rx) = wit_stream::new();
    wit_bindgen::spawn(produce_tar(entries, contents, tar_tx));
    // ...hand that tar stream to the host's gzip compressor. This `compress`
    // call is the async streaming *import* that jco #1601 affects.
    let mut compressed = compressor::compress(tar_rx).await;
    // Copy the gzipped bytes onto our own output stream.
    loop {
        let (status, buf) = compressed.read(Vec::with_capacity(CHUNK)).await;
        if !buf.is_empty() {
            let _ = out_tx.write_all(buf).await;
        }
        if matches!(status, StreamResult::Dropped | StreamResult::Cancelled) {
            break;
        }
    }
    drop(out_tx);
}

/// Producer task spawned by [`run_pipeline`]: writes the tar byte stream to `tx`.
async fn produce_tar(
    entries: Vec<Entry>,
    mut contents: StreamReader<u8>,
    mut tx: StreamWriter<u8>,
) {
    for entry in entries {
        // Header first -- it declares the length, so the reader knows exactly
        // how many content bytes follow.
        let _ = tx.write_all(build_header(&entry.name, entry.size).to_vec()).await;

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

/// Build a 512-byte `ustar` header for a regular file.
fn build_header(name: &str, size: u64) -> [u8; 512] {
    let mut header = [0u8; 512];

    // name (0..100)
    let name_bytes = name.as_bytes();
    let name_len = name_bytes.len().min(100);
    header[..name_len].copy_from_slice(&name_bytes[..name_len]);

    write_octal(&mut header[100..108], 0o644); // mode
    write_octal(&mut header[108..116], 0); // uid
    write_octal(&mut header[116..124], 0); // gid
    write_octal(&mut header[124..136], size); // size
    write_octal(&mut header[136..148], 0); // mtime (fixed for reproducibility)

    // The checksum is computed with this field filled with spaces.
    for byte in &mut header[148..156] {
        *byte = b' ';
    }
    header[156] = b'0'; // typeflag: regular file
    header[257..263].copy_from_slice(b"ustar\0"); // magic
    header[263..265].copy_from_slice(b"00"); // version

    let checksum: u32 = header.iter().map(|&b| u32::from(b)).sum();
    let checksum = format!("{checksum:06o}");
    header[148..154].copy_from_slice(checksum.as_bytes());
    header[154] = 0;
    header[155] = b' ';

    header
}

/// Write `value` into a tar numeric `field` as zero-padded octal terminated by
/// a NUL (the field is `field.len()` bytes, so `field.len() - 1` octal digits).
fn write_octal(field: &mut [u8], value: u64) {
    let digits = field.len() - 1;
    let text = format!("{value:0digits$o}");
    let text = text.as_bytes();
    // Keep the rightmost `digits` characters if `value` somehow overflows.
    let start = text.len().saturating_sub(digits);
    field[..digits].copy_from_slice(&text[start..]);
    field[digits] = 0;
}
