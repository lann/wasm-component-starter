"""metadata-parser component: extract page metadata from an HTML document.

This module is compiled to a WebAssembly component with `componentize-py`. It
implements the `extractor` interface from `../../wit/metadata-parser/world.wit`:
it receives the document as an incoming byte `stream`, feeds it to Python's
built-in `html.parser`, and emits `(key, value)` metadata pairs on an outgoing
`stream` as they are discovered.

The component imports nothing -- no filesystem, no network, no clock. Every
byte in and every result out travels through the two streams, which is exactly
the kind of capability-free, sandboxed unit the Component Model is designed to
make easy to reason about.
"""

import codecs
from html.parser import HTMLParser

import componentize_py_async_support
import wit_world
from componentize_py_async_support.streams import (
    ByteStreamReader,
    StreamReader,
    StreamWriter,
)
from wit_world import exports


class _MetadataParser(HTMLParser):
    """Collect a handful of useful metadata fields from an HTML document.

    Discovered pairs are buffered in `self.pairs`; the driver drains that
    buffer after every chunk so results stream out incrementally rather than
    being held back until the whole document has been parsed.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.pairs: list[tuple[str, str]] = []
        self._in_title = False
        self._title: list[str] = []
        self._in_h1 = False
        self._h1: list[str] = []
        self._seen_h1 = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        a = {k: v for k, v in attrs if v is not None}
        if tag == "html":
            if lang := a.get("lang"):
                self.pairs.append(("lang", lang))
        elif tag == "title":
            self._in_title = True
            self._title = []
        elif tag == "meta":
            if charset := a.get("charset"):
                self.pairs.append(("charset", charset))
            key = a.get("name") or a.get("property") or a.get("http-equiv")
            content = a.get("content")
            if key and content is not None:
                self.pairs.append((f"meta:{key.lower()}", content))
        elif tag == "link":
            rel = (a.get("rel") or "").lower()
            href = a.get("href")
            if href and rel in ("canonical", "icon", "shortcut icon"):
                self.pairs.append((f"link:{rel}", href))
        elif tag == "h1" and not self._seen_h1:
            self._in_h1 = True
            self._h1 = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "title" and self._in_title:
            self._in_title = False
            if title := "".join(self._title).strip():
                self.pairs.append(("title", title))
        elif tag == "h1" and self._in_h1:
            self._in_h1 = False
            self._seen_h1 = True
            if text := " ".join("".join(self._h1).split()):
                self.pairs.append(("h1", text))

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title.append(data)
        elif self._in_h1:
            self._h1.append(data)

    def drain(self) -> list[tuple[str, str]]:
        """Return the pairs collected so far and clear the buffer."""
        pairs, self.pairs = self.pairs, []
        return pairs


class Extractor(exports.Extractor):
    """The exported implementation of the `extractor` interface."""

    async def extract(
        self, html: ByteStreamReader
    ) -> StreamReader[tuple[str, str]]:
        # Create the result stream and hand its readable end straight back to
        # the caller. The writable end is filled in by a background task, so
        # `extract` returns promptly and results flow out as they are found.
        tx, rx = wit_world.tuple2_string_string_stream()
        componentize_py_async_support.spawn(self._pump(html, tx))
        return rx

    async def _pump(
        self, html: ByteStreamReader, tx: StreamWriter[tuple[str, str]]
    ) -> None:
        parser = _MetadataParser()
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        with html, tx:
            while not html.writer_dropped:
                chunk = await html.read(64 * 1024)
                if not chunk:
                    continue
                parser.feed(decoder.decode(chunk))
                if pairs := parser.drain():
                    await tx.write_all(pairs)
            # Flush any bytes the decoder was holding, then close the parser so
            # it emits a final `</title>`/`</h1>` if the document was truncated.
            parser.feed(decoder.decode(b"", final=True))
            parser.close()
            if pairs := parser.drain():
                await tx.write_all(pairs)
