//! `metadata-printer` component: a CLI that reads an HTML file (or fetches a
//! URL), streams it to the `metadata-parser` extractor component, and prints
//! the metadata it gets back.
//!
//! This is a `cdylib` built for `wasm32-wasip2` that exports an *async*
//! `wasi:cli/run` via the `wasip3` crate. The async export is what lets us
//! drive the `extractor` import's `stream`s without tripping the runtime's
//! "cannot block a synchronous task before returning" guard -- a plain
//! `wasm32-wasip2` *binary* lifts `run` synchronously and cannot. Because the
//! target is `wasm32-wasip2` (not bare `wasm32-unknown-unknown`), `std` still
//! has a working filesystem and stdio, so file reads and printing use ordinary
//! `std` APIs. Those lower to synchronous `wasi:*@0.2.0` imports, which an
//! async task may freely call; only the cross-component streaming and the
//! outgoing HTTP request use the async component-model ABI.
//!
//! URL fetching goes through `wasi:http`'s async client. `wasip3`'s
//! `http-compat` feature lets us build the request and read the response with
//! the idiomatic `http` / `http-body-util` crates instead of the raw WASI HTTP
//! resources.

use wit_bindgen::StreamResult;

wit_bindgen::generate!({
    path: "../../wit/html-metadata",
    inline: "
        package inline:inline;
        world inline {
            import example:html-metadata/extractor@0.1.0;
        }
    ",
    generate_all,
});
use example::html_metadata::extractor;

/// The type that backs the asynchronous `wasi:cli/run` export.
struct Component;

impl wasip3::exports::cli::run::Guest for Component {
    async fn run() -> Result<(), ()> {
        let Some(source) = std::env::args().nth(1) else {
            eprintln!("usage: metadata-printer <file-path-or-url>");
            return Err(());
        };

        let source_result = if source.starts_with("http://") || source.starts_with("https://") {
            fetch_source(&source).await
        } else {
            let source = source.strip_prefix("file://").unwrap_or(&source);
            std::fs::read(source).map_err(|err| err.to_string())
        };
        let html = match source_result {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!("error: could not fetch `{source}`: {err}");
                return Err(());
            }
        };

        let metadata = extract_metadata(html).await;
        print!("{}", format_metadata(&source, &metadata));
        Ok(())
    }
}

wasip3::cli::command::export!(Component);

/// Fetch an HTML document over HTTP and return its body bytes.
///
/// This goes through `wasi:http`'s async outgoing-request client
/// (`wasip3::http::client::send`). Thanks to `wasip3`'s `http-compat` feature
/// we build the request and read the response with the ordinary `http` and
/// `http-body-util` crates -- `http_compat` only bridges those idiomatic types
/// to and from the WASI HTTP `Request`/`Response` resources at the boundary.
async fn fetch_source(url: &str) -> Result<Vec<u8>, String> {
    use http_body_util::{BodyExt as _, Empty};

    // Build a plain GET with an empty body using the `http` crate's builder.
    let request = http::Request::builder()
        .method(http::Method::GET)
        .uri(url)
        .body(Empty::<bytes::Bytes>::new())
        .map_err(|err| err.to_string())?;

    // Convert the idiomatic request into the WASI resource, send it, and convert
    // the WASI response back into an `http::Response` with a streaming body.
    let wasi_request =
        wasip3::http_compat::http_into_wasi_request(request).map_err(|err| format!("{err:?}"))?;
    let wasi_response = wasip3::http::client::send(wasi_request)
        .await
        .map_err(|err| format!("{err:?}"))?;
    let response = wasip3::http_compat::http_from_wasi_response(wasi_response)
        .map_err(|err| format!("{err:?}"))?;

    let status = response.status();
    if !status.is_success() {
        return Err(format!("unexpected status {status}"));
    }

    // Drain the streaming body to completion.
    let body = response
        .into_body()
        .collect()
        .await
        .map_err(|err| format!("{err:?}"))?;
    Ok(body.to_bytes().to_vec())
}

/// Stream `html` to the `metadata-parser` extractor and collect the
/// `(key, value)` pairs.
async fn extract_metadata(html: Vec<u8>) -> Vec<(String, String)> {
    let (mut tx, rx) = wit_stream::new();

    // Producer: write the whole document, then drop `tx` to signal end-of-input.
    let producer = async move {
        let _ = tx.write_all(html).await;
    };

    // Consumer: call the async import and drain the result stream. Running it
    // concurrently with the producer lets the parser begin before the whole
    // document has been written.
    let consumer = async move {
        let mut results = extractor::extract(rx).await;
        let mut rows: Vec<(String, String)> = Vec::new();
        loop {
            let (status, batch) = results.read(Vec::with_capacity(16)).await;
            rows.extend(batch);
            match status {
                StreamResult::Complete(_) => continue,
                StreamResult::Dropped | StreamResult::Cancelled => break,
            }
        }
        rows
    };

    let ((), rows) = futures_util::join!(producer, consumer);
    rows
}

/// Render the collected metadata as a simple aligned table.
fn format_metadata(source: &str, rows: &[(String, String)]) -> String {
    use std::fmt::Write as _;

    let heading = format!("Metadata for {source}");
    let mut out = String::new();
    let _ = writeln!(out, "{heading}");
    let _ = writeln!(out, "{}", "=".repeat(heading.len()));

    if rows.is_empty() {
        let _ = writeln!(out, "(no metadata found)");
        return out;
    }

    let width = rows.iter().map(|(key, _)| key.len()).max().unwrap_or(0);
    for (key, value) in rows {
        let _ = writeln!(out, "{key:width$}  {value}");
    }
    out
}
