# Differences from the original

zig-zstd translates zstd 1.5.7's compressor and decompressor function by
function: it gives the original's frames, and decodes any input to the
original's bytes or error. [`STATUS.md`](../STATUS.md) lists every function,
parameter and build switch of the original with its counterpart and its
state, and [`porting.md`](porting.md) the rules the translation follows. This
file gives the reasons for each difference a caller can see. The review of
the port is not finished, so this list can still change.

## Additions

- **`DCtx.decompressFrameExact` and `DCtx.init`.** Game packs store one frame
  per chunk and know each chunk's decoded size. `decompressFrameExact`
  decodes exactly one frame into a buffer of that size, refuses anything
  else (a skippable frame, bytes after the frame, a size other than the
  buffer's), and verifies the frame's checksum whatever the context's
  `force_ignore_checksum`, with an option to refuse frames without one.
  `DCtx.init` sets up a context in memory the caller owns; it never
  allocates, as a static context with no room past itself. The original
  needs `ZSTD_getFrameContentSize`, `ZSTD_findFrameCompressedSize` and
  `ZSTD_decompressDCtx` with checks of its own for the same.

## Changes to expect

- **Errors.** A function that returns a size or an error code in the
  original returns `Error!usize` (or `Error!void`), with the error named as
  in `src/error.zig`. Values that are not errors keep their meaning, such as
  0 for "not compressible". `createDDict*` return the error where the
  original returns NULL (`error.DictionaryCorrupted`, `error.MemoryAllocation`);
  `ZSTD_DCtx_loadDictionary*` gives `error.MemoryAllocation` for both, as the
  original does.
- **Decompression parameters** are an enum (`params.DParameter`), so a
  number the original refuses as unknown cannot be passed. The rest of the
  parameter API refuses and accepts what the original does.
- **`disable_huffman_assembly`** is set and read as in the original, and
  changes nothing: the port has no assembly. The original's assembly loops
  and the C loops the port translates give the same bytes on valid frames;
  on a corrupt frame they can stop at different places, so the oracle tests
  of corrupt input turn the assembly off on the original's side.
- **Decoding contexts** keep pointers into themselves during a frame, as the
  original's do, so a `DCtx` must not move until its frame ends.
- **Several `DDict`s, one shot.** With `ref_multiple_ddicts`, the
  original's one-shot functions (`ZSTD_decompressDCtx`,
  `ZSTD_decompress_usingDDict`) start each frame on the context's last
  referenced `DDict`, and only then look the frame's dictionary id up: a
  frame of another dictionary decodes with the wrong content and tables,
  and fails or, without a checksum, gives wrong bytes. The port keeps that
  behaviour in `decompressDCtx` and `decompressUsingDDict`. Streams pick the
  frame's `DDict` first, in both. `decompressFrameExact`, the port's own,
  picks it first too. Loomwork uses no dictionaries.
- **The `DDict` set** (`ref_multiple_ddicts`) is the original's
  open-addressing table, but its probe wraps from the last slot to the
  first. The original's steps one past its table there, reading (and when a
  `DDict` is added, writing) past its allocation; a frame's dictionary id
  can lead it there. Where the original reads past its table, the port's
  result is the one a table without that bug gives.
- **`decompressContinue` of 0 bytes** at the end of a frame, where the next
  frame's header would start, is refused (`error.SrcSizeWrong`); the
  original reads 4 bytes past its input there.
- **Bytes past the decoded size** in the output buffer are unspecified, in
  the original as in the port: both copy in 16- and 32-byte steps, and the
  bytes over-copied there come from each side's own scratch buffers.
- **Memory.** `ZSTD_customMem` is a `std.mem.Allocator`. A context made with
  `initStatic` has none and never allocates, as the original's static
  contexts do. `CCtx.generateSequences` takes an allocator for its scratch
  frame, which the original mallocs. `decompress` takes the allocator its
  context comes from, as `compress` does; the original's `ZSTD_decompress`
  mallocs one (its default `ZSTD_HEAPMODE`). A static decompression context
  cannot load a dictionary by copy or by reference
  (`error.MemoryAllocation`), where the original's mallocs a `DDict`; it can
  reference one with `refDDict`, and `initStaticDDict` places one in the
  caller's memory.
- **Static contexts.** Where the original mallocs even for a static
  context, the port refuses with `error.MemoryAllocation`: compressing with
  a dictionary loaded by reference (the original digests it into a `CDict`),
  and making the multithreaded context. `initStatic` over a workspace a few
  bytes larger than the context returns null; the original's space check
  wraps there, and it returns a context that crashes on first use.
- **Unchecked writes.** Where the original goes on past a failure the port
  returns the error: `copyCCtx` when resetting the copy fails (the original
  then copies into tables it has not reserved), and a sub-block of a
  `targetCBlockSize` block whose entropy tables do not fit the room left
  (the original copies them past the end of its output, which happens with
  a small stable output buffer). The port's sub-block fails with
  `error.DstSizeTooSmall`, and the block falls back to a raw block, as the
  original's does for a sub-block that does not fit.
- **Workers.** Workers need an `std.Io`: `CCtx.setIo`, or the one of a pool
  given with `refThreadPool`. A context with workers and neither refuses
  with `error.ParameterCombinationUnsupported`.
- **Asserts.** The port keeps the original's asserts on promises made by the
  caller, and they panic in Debug and ReleaseSafe where the original's
  release build carries on: malformed caller sequences (in
  `convertBlockSequences`, `get1BlockSummary`, `offsetToOffbase` and
  `storeSeqOnly`), a hand-made dictionary whose Huffman codes are longer
  than 11 bits or whose FSE costs reach 10 when the optimal parser prices
  from it (undefined behaviour in the original in the Huffman case), and a
  stable-input promise broken before a frame starts, where the original's
  next frame reads out of bounds.
- **Size estimates.** With long distance matching on and `ldmMinMatch`
  unset, `estimateCCtxSizeUsingCCtxParams` and
  `estimateCStreamSizeUsingCCtxParams` divide by zero, as the original's do:
  the original dies with SIGFPE, the port panics in a safe build.
- **Tables past a 32-bit address space.** On a 32-bit target, a hash log of
  30 (a 4 GiB table) or a long distance hash log of 29 or 30 with long
  distance matching on wraps the original's size_t table size to 0, and the
  largest tables together wrap its sums. The estimates return the same
  wrapped values as the original's. Compressing, the port refuses such
  tables with `error.MemoryAllocation`. Where only the sum wraps, the
  original's workspace check refuses them too, unless its pointer sum wraps
  at the top of the address space. Where a table's own size wraps, the
  original reserves no room for it and writes past its workspace.
- **The AVX2 sequence conversion.** The original's `convertSequences` takes
  its AVX2 path whenever `__AVX2__` is defined, even with
  `ZSTD_NO_INTRINSICS`; the port takes its vector path only with the
  `intrinsics` build option and AVX2. The results are the same except for
  lengths of 2^31 and over.
- **Build switches.** `ZSTD_MULTITHREAD` is the `multithread` build option,
  and `ZSTD_NO_INTRINSICS` the `intrinsics` option turned off. The port
  compiles for the target's CPU features, where the original can dispatch on
  BMI2 at run time; the output does not depend on it.

## Left out

The author approved leaving these out of the port:

- **Dictionary training** (`ZDICT_*`: `zdict.c`, `cover.c`, `fastcover.c`,
  `divsufsort.c`). The tests use the original's trainer to make dictionaries.
- **The legacy formats** (`ZSTD_LEGACY_SUPPORT`, `lib/legacy/`), frames of
  zstd before 0.8. The original's library build leaves them out too.
- **`ZSTD_customMem`**, a struct of allocation callbacks. A `std.mem.Allocator`
  takes its place.
- **BMI2 run-time dispatch** (`DYNAMIC_BMI2`, `STATIC_BMI2`). The port is built
  for the target's CPU features, and the output does not depend on BMI2.
- **Build switches for C builds**: the `ZSTD_EXCLUDE_*_BLOCK_COMPRESSOR`
  switches (binary size only), `ZSTD_COMPRESS_HEAPMODE`, tracing (`ZSTD_TRACE`,
  `ZSTD_HAVE_WEAK_SYMBOLS`), debug and sanitizer switches (`DEBUGLEVEL`,
  `ZSTD_ADDRESS_SANITIZER`, `ZSTD_MEMORY_SANITIZER`, `ZSTD_DATAFLOW_SANITIZER`),
  and the C build-configuration macros (`ZSTD_STRIP_ERROR_STRINGS`,
  `ZSTD_LIB_MINIFY`, `ZSTD_LINUX_KERNEL`, `ZSTD_DEPS_*`, `XXH_*`).
- **`ZSTD_C_PREDICT`** (an experimental, disabled path in `zstd_opt.c`), the
  fuzzing build mode (`FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION`) and
  `ZSTD_RESIZE_SEQPOOL` (fixed to 0 in the original).

On the decompression side, the author approved these on 22 November as
deliberate differences from the original:

- **The x86-64 assembly Huffman loops** (`huf_decompress_amd64.S`,
  `ZSTD_DISABLE_ASM`). The port translates the C fast loops that the
  original runs without its assembly, and gives the same bytes on valid
  frames. On the benchmark machine they decode faster than the original's
  assembly (doc/BENCHMARKS.md), and they stay pure Zig. On corrupt frames the
  assembly can stop at other places than the C loops, so where the original
  runs its assembly, its result on a corrupt frame can differ from the
  port's; the oracle tests of corrupt input compare against the original's C
  loops (`disable_huffman_assembly`), which the port matches.
- **Switches that build one decoder of each kind, for binary size**:
  `HUF_FORCE_DECOMPRESS_X1`, `HUF_FORCE_DECOMPRESS_X2`,
  `ZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT`, `ZSTD_FORCE_DECOMPRESS_SEQUENCES_LONG`,
  `HUF_DISABLE_FAST_DECODE`, `ZSTD_NO_INLINE`. Every decoder is compiled and
  picked at run time as the original's default build picks it; the Huffman
  fast loops can still be turned off per call (`Flags.disable_fast`, the
  original's `HUF_flags_disableFast`).
- **Build-time sizes, kept at the original's defaults**: `ZSTD_HEAPMODE`
  (the port always takes an allocator, or a caller's memory),
  `ZSTD_MAXWINDOWSIZE_DEFAULT` (the `window_log_max` parameter sets the
  limit at run time), `ZSTD_NO_FORWARD_PROGRESS_MAX` (16),
  `ZSTD_DECODER_INTERNAL_BUFFER` (64 KiB). Changing them in the original
  changes no frame's bytes, only limits and memory.
