//! `cli-archive-maker` component: a CLI that reads files from the filesystem and
//! drives the `archiver` component to produce an archive file.
//!
//! This is a `cdylib` built for `wasm32-wasip2` that exports an *async*
//! `wasi:cli/run` via the `wasip3` crate. The async export is what lets us drive
//! the `archive` import's `stream`s without tripping the runtime's "cannot block
//! a synchronous task before returning" guard -- a plain `wasm32-wasip2` *binary*
//! lifts `run` synchronously and cannot. Because the target is `wasm32-wasip2`
//! (not bare `wasm32-unknown-unknown`), `std` still has a working filesystem, so
//! the file reads and the final write use ordinary `std` APIs. Those lower to
//! synchronous `wasi:*@0.2.0` imports, which an async task may freely call; only
//! the cross-component streaming uses the async component-model ABI.

use std::path::Path;
use wit_bindgen::StreamResult;

wit_bindgen::generate!({
    path: "../../wit/archive",
    inline: "
        package inline:inline;
        world inline {
            import example:archive/archiver@0.1.0;
        }
    ",
    generate_all,
});
use example::archive::archiver::{self, Entry};

/// Read and stream at most this many bytes per chunk, so no whole file -- nor
/// the whole archive -- is ever held in memory.
const BUFFER_SIZE: usize = 64 * 1024;

const USAGE: &str = "usage: cli-archive-maker <output.tar.gz> <input-file>...";

/// The type that backs the asynchronous `wasi:cli/run` export.
struct Component;

impl wasip3::exports::cli::run::Guest for Component {
    async fn run() -> Result<(), ()> {
        let mut args = std::env::args().skip(1);
        let Some(output) = args.next() else {
            eprintln!("{USAGE}");
            return Err(());
        };
        let inputs: Vec<String> = args.collect();
        if inputs.is_empty() {
            eprintln!("{USAGE}");
            return Err(());
        }

        // Stat each file to learn its size without reading it. `entry.size` must
        // match the bytes we later stream for that member, so we capture each
        // length now and assert the stream delivers exactly that much as we go.
        let mut files: Vec<(String, u64)> = Vec::with_capacity(inputs.len());
        for input in inputs {
            let size = match std::fs::metadata(&input) {
                Ok(meta) => meta.len(),
                Err(err) => {
                    eprintln!("error: could not stat `{input}`: {err}");
                    return Err(());
                }
            };
            files.push((input, size));
        }

        let written = match build_archive(&output, &files).await {
            Ok(written) => written,
            Err(err) => {
                eprintln!("error: {err}");
                return Err(());
            }
        };

        eprintln!(
            "wrote {output} ({written} bytes) from {} file(s)",
            files.len()
        );
        Ok(())
    }
}

wasip3::cli::command::export!(Component);

/// Stream `files` from disk into the `archiver` import and write the resulting
/// archive straight to `output`, returning the number of archive bytes written.
///
/// Each `(path, size)` pair was stat'd by the caller. We hand the archiver a
/// `stream<entry>`; each `entry` carries its own `contents` stream, which we
/// feed from disk in `BUFFER_SIZE` chunks. Writing an entry and then streaming
/// its bytes keeps us in lockstep with the archiver -- it reads one entry,
/// drains that member's `contents`, and only then sees the next entry -- so even
/// a multi-gigabyte input never lands in memory. Nothing is buffered whole on
/// either side: input bytes flow disk -> archiver and archive bytes flow
/// archiver -> disk a chunk at a time.
async fn build_archive(output: &str, files: &[(String, u64)]) -> std::io::Result<u64> {
    use std::io::{Read, Write};

    let (mut entry_tx, entry_rx) = wit_stream::new();

    // Producer: for each file, hand the archiver an `entry` carrying a fresh
    // content stream, then stream that file's bytes into it. We assert each file
    // yields exactly the `size` we stat'd -- a short or long read (e.g. the file
    // changed since we stat'd it) would desync the tar framing, so it is better
    // to fail loudly than to emit a corrupt archive.
    let producer = async {
        for (path, expected) in files {
            let name = Path::new(path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.clone());

            let mut file = std::fs::File::open(path).map_err(|err| {
                std::io::Error::new(err.kind(), format!("could not open `{path}`: {err}"))
            })?;

            // A fresh byte stream for this member: the reader half travels inside
            // the `entry` to the archiver; the writer half stays here.
            let (mut content_tx, content_rx) = wit_stream::new();
            let _ = entry_tx
                .write_all(vec![Entry {
                    name,
                    size: *expected,
                    contents: content_rx,
                }])
                .await;

            let mut buf = vec![0u8; BUFFER_SIZE];
            let mut read_total: u64 = 0;
            loop {
                let n = file.read(&mut buf).map_err(|err| {
                    std::io::Error::new(err.kind(), format!("could not read `{path}`: {err}"))
                })?;
                if n == 0 {
                    break;
                }
                read_total += n as u64;
                let _ = content_tx.write_all(buf[..n].to_vec()).await;
            }
            // Dropping the writer signals end-of-member to the archiver.
            drop(content_tx);

            assert_eq!(
                read_total, *expected,
                "`{path}`: streamed {read_total} bytes but metadata reported {expected}",
            );
        }
        // Dropping the entry writer signals end-of-archive.
        drop(entry_tx);
        Ok::<(), std::io::Error>(())
    };

    // Consumer: call the async import and write the archive bytes straight to the
    // output file as they arrive, so the finished archive is never buffered whole
    // either. Runs concurrently with the producer.
    let consumer = async {
        let mut out = std::fs::File::create(output).map_err(|err| {
            std::io::Error::new(err.kind(), format!("could not create `{output}`: {err}"))
        })?;
        let mut result = archiver::archive(entry_rx).await;
        let mut written: u64 = 0;
        loop {
            let (status, batch) = result.read(Vec::with_capacity(BUFFER_SIZE)).await;
            if !batch.is_empty() {
                written += batch.len() as u64;
                out.write_all(&batch).map_err(|err| {
                    std::io::Error::new(err.kind(), format!("could not write `{output}`: {err}"))
                })?;
            }
            match status {
                StreamResult::Complete(_) => continue,
                StreamResult::Dropped | StreamResult::Cancelled => break,
            }
        }
        out.flush()?;
        Ok::<u64, std::io::Error>(written)
    };

    let (produced, written) = futures_util::join!(producer, consumer);
    produced?;
    written
}
