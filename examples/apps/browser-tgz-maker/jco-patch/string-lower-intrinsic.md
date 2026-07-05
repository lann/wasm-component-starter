# jco: lowering a `string` inside a stream/record payload throws `ReferenceError: _utf8AllocateAndEncode is not defined`

The fix for this specific issue is [`string-lower-intrinsic.patch`](string-lower-intrinsic.patch)
(also rolled into the combined [`function_bindgen.patch`](function_bindgen.patch)).
This bug is still present as of jco 1.24.6.

## Summary

When a component transpiled with `jco transpile` lowers a `string` that is
**not** a top-level function argument — e.g. a `string` field of a `record` that
is itself an element of a `stream` (or list/record) — the generated JS calls the
helper `_utf8AllocateAndEncode`, but that helper's **definition is never
emitted** into the module. The first such lowering throws
`ReferenceError: _utf8AllocateAndEncode is not defined`.

Because the throw happens inside the stream-write machinery, which wraps the
write in a `try`/`catch` and discards the rejection, the error is **swallowed**:
the writer never makes progress, the reader waits forever, and the symptom
presents as a hang/deadlock rather than a crash.

## Reproduction

A WIT export whose stream elements carry a string field:

```wit
record entry {
    name: string,
    size: u64,
    contents: stream<u8>,
}

archive: async func(entries: stream<entry>) -> stream<u8>;
```

Transpile with `--async-mode jspi` and drive `archive` with a single entry. With
`JCO_DEBUG=1` the swallowed error surfaces:

```
[StreamWritableEnd#write()] error ReferenceError: _utf8AllocateAndEncode is not defined
    at _lowerFlatStringUTF8 (archiver.js:2973:33)
    at _lowerFlatStringAny (archiver.js:2960:14)
    at Object._lowerFlatRecordInner [as lowerFn] (archiver.js:3018:9)
    at ManagedBuffer.write (archiver.js:6049:30)
    at StreamWritableEnd._write (archiver.js:4175:42)
    at StreamWritableEnd.copy (archiver.js:4331:14)
    at StreamWritableEnd.writeMany (archiver.js:4024:34)
    at writeValues (archiver.js:5049:45)
    at StreamReadableEnd.generatedStreamHostInject (archiver.js:5118:15)
```

The generated `_lowerFlatStringUTF8` body references the helper:

```js
function _lowerFlatStringUTF8(ctx) {
  const { ptr, codepoints } = _utf8AllocateAndEncode(ctx.vals[0], ctx.realloc, ctx.memory);
  // ...
}
```

…but `grep "function _utf8AllocateAndEncode"` over the emitted module returns
nothing.

## Root cause

jco resolves which runtime helpers ("intrinsics") to emit via a hand-maintained,
ordered sequence of dependency checks in `render_intrinsics`
(`crates/js-component-bindgen/src/intrinsics/mod.rs`). The per-intrinsic
`LowerIntrinsic::deps()` returns `&[]` for *all* lower intrinsics, so this linear
sequence is the only place dependencies are added.

The block that handles `LowerFlatStringUtf8` inserts only the `TEXT_ENCODER_UTF8`
global, **not** the `Utf8Encode` string intrinsic that actually emits the
`_utf8AllocateAndEncode` function definition:

```rust
if args.intrinsics
    .contains(&Intrinsic::Lower(LowerIntrinsic::LowerFlatStringUtf8))
{
    args.intrinsics
        .insert(Intrinsic::String(StringIntrinsic::GlobalTextEncoderUtf8));
    // <-- never inserts StringIntrinsic::Utf8Encode
}
```

Compare the lift side, which is correct — `LiftFlatStringUtf8` pulls in its
decode helper. The lower side is missing the analogous pull. `LowerFlatStringUtf16`
has the same gap (it references `_utf16AllocateAndEncode`, the `Utf16Encode`
intrinsic, which additionally needs `IsLE`).

This only manifests for "flat" lowering (stream/list/record payloads). A
top-level `string` argument is lowered through a different path that already
emits the helper, which is why simple signatures don't hit it.

## Why it looks like a deadlock

`StreamWritableEnd.copy` / `writeMany` invoke the element `lowerFn` inside a
`try`/`catch` and convert a throw into a dropped write rather than a rejected
read. So the `ReferenceError` is silently eaten: the host write side stalls, and
the guest read side blocks on a value that never arrives. Without `JCO_DEBUG=1`
it is indistinguishable from a scheduling deadlock on the nested stream.

## Fix

In `render_intrinsics`, have the `LowerFlatStringUtf8` block also emit the
`Utf8Encode` string intrinsic, and add the mirror block for `LowerFlatStringUtf16`
(`Utf16Encode` + `IsLE`). The ordering is safe: `Utf8Encode`'s only dependency
(`TEXT_ENCODER_UTF8`) is already inserted in the same block, and `Utf8Encode`
does not require `IsLE`.

```diff
--- a/crates/js-component-bindgen/src/intrinsics/mod.rs
+++ b/crates/js-component-bindgen/src/intrinsics/mod.rs
@@ -1474,6 +1474,25 @@ pub fn render_intrinsics(args: RenderIntrinsicsArgs) -> Source {
     {
         args.intrinsics
             .insert(Intrinsic::String(StringIntrinsic::GlobalTextEncoderUtf8));
+        // The lowered-string body calls `_utf8AllocateAndEncode` (the
+        // `Utf8Encode` string intrinsic) to realloc guest memory and encode the
+        // string into it. Without this the helper is referenced but never
+        // emitted, throwing `ReferenceError: _utf8AllocateAndEncode is not
+        // defined` when a string is lowered as part of a stream/record payload.
+        args.intrinsics
+            .insert(Intrinsic::String(StringIntrinsic::Utf8Encode));
+    }
+
+    if args
+        .intrinsics
+        .contains(&Intrinsic::Lower(LowerIntrinsic::LowerFlatStringUtf16))
+    {
+        // Mirror of the UTF-8 case: the lowered-string body calls
+        // `_utf16AllocateAndEncode` (the `Utf16Encode` string intrinsic), which
+        // in turn needs `IsLE`. Emit both so the helper is defined.
+        args.intrinsics
+            .insert(Intrinsic::String(StringIntrinsic::Utf16Encode));
+        args.intrinsics.insert(Intrinsic::IsLE);
     }
 
     if args
```

## Verification

After the fix, the emitted module contains `function _utf8AllocateAndEncode(...)`,
and the nested-`stream<entry>` pipeline round-trips end-to-end under jco (4-file
archive: tar 104960 B, gzip 664 B), matching the same component's behavior under
wasmtime.
