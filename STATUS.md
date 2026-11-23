# Port status

Every public compression and decompression function, parameter, mode and
build switch of zstd 1.5.7 (`reference/lib/zstd.h`, `zdict.h`, the library's
build macros), with its state:

- **not started**: nothing in zig-zstd yet;
- **ported**: translated, with no test against the original;
- **oracle-tested**: the original runs on the same inputs in `zig build test`,
  and every frame byte and returned value matches;
- **benchmarked**: oracle-tested, and timed against the original by
  `zig build bench` (see `doc/BENCHMARKS.md`);
- **reviewed**: through the performance pass, the skeptic and the fixes.

The original is pinned in `reference/` (see `reference/README.md`): tag
`v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`. `doc/porting.md`
says how the code maps to it.

## Decompressor report (22 November 2026)

**Done.** The decompressor of zstd 1.5.7, from the same pinned commit, is
ported on branch `decompressor`: the Huffman decoder with its C fast loops,
the block decoder (every literals section, every sequence table mode, the
three sequence loops), frames, skippable frames and the frame readers,
dictionaries and `DDict`s, the buffer-less API, streaming, every
decompression parameter, and static contexts. The author's 22 November
decision put it here rather than in std. `DCtx.decompressFrameExact` is the
port's own entry point for game packs: one frame into a buffer of its size,
no allocation, the checksum always verified. Each step of the method:

1. Pinned: the original in `reference/` is the compressor's; upstream's
   `tests/golden-decompression` and `tests/golden-decompression-errors`,
   from the same commit, are added to it.
2. Inventory: the tables below, from "Decompression: frames" on.
3. Oracle tests: `test/decompress_test.zig`, `test/dstream_test.zig` (one
   or more tests per inventory row, each counting that its feature is in
   the frames), `test/decompress_skeptic_test.zig` (the review's).
4. Benchmark: `zig build bench-decompress` (`doc/BENCHMARKS.md`).
5. Performance pass: the Huffman fast loops keep each stream's container in
   a general register (LLVM's SLP vectorizer had packed them into one
   vector register, an extract and an insert per symbol): BC7 frames went
   from 563 to about 870 MB/s. `copy16` already compiles to one 16-byte
   load and store; the sequence loop's hottest instruction is the match
   copy's store, waiting on a load of bytes it just wrote, as in the
   original. With the port at or past the original on each set, the pass
   stopped there.
6. Skeptic review: a separate agent, with guard pages, in-place decoding,
   spliced and corrupted frames through every entry point; 7 findings.
7. Fixed (`0e498d5`), each with the test that failed before:
   - crash: the `DDict` set's probe stepped past its table from the last
     slot, as the original's does (a read, and in emplace a write, past its
     allocation); a frame's dictionary id could reach it. The port wraps
     inside the table, a departure from the original noted in
     `doc/parity.md`;
   - crash: `estimateDStreamSize`, `estimateDDictSize` and
     `decompressionMarginBound` overflowed where the original's sums wrap;
   - `readSkippableFrame` gave other error codes than the original on a
     frame that is not skippable and on a size that wraps;
   - `nextSrcSizeToDecompress` after a failed compressed or RLE block was
     not the original's 0;
   - `decompressFrameExact` with several `DDict`s decoded with the last one
     referenced (as the original's one-shot functions do); it now picks the
     frame's by id first;
   - the benchmark's method lines did not say that std reads checksums
     unverified.
   Found before the review, by the 32-bit run (`ac23df8`): the safe Huffman
   decoders decoded 4 symbols a stream between reloads on 32-bit targets,
   where the original decodes 2 (an assert failed on valid frames), and the
   context's size missed the original's BMI2 flag on 32-bit x86.
8. Release: version 0.2.0, this file, README, `doc/`; merged into `main`
   and tagged `v0.2.0` on 23 November, at the author's request.
9. A second review (23 November), through Loomwork's use: one frame an
   asset at level 19 with an 8 MiB window, `decompressFrameExact` with a
   required checksum on a reused `DCtx.init` context, in ReleaseFast. Its
   tests are in `test/decompress_loomwork_test.zig`. Two findings, fixed:
   - crash: `readNCount` (`entropy_common.zig`, shared with the
     compressor's dictionary loading) cast a count of 32768 into an `i16`:
     a panic in safe builds and undefined behaviour in ReleaseFast, from a
     22-byte frame whose sequence or Huffman weight table has log 15 and one
     symbol in every cell. The original stores it as a short, -32768, and
     its callers refuse the table; the port now truncates as it does;
   - a valid frame of an empty asset was refused (`error.DstSizeTooSmall`)
     when the empty output came from an allocator, whose empty slices have
     the address maxInt(usize): the block decoder's check of an output near
     the top of the address space now passes empty outputs, as the
     original's passes NULL.
   And two documentation gaps, now in the doc comments: a context is used by
   one thread at a time, and stays usable after a failed frame. Its probes
   that held up: every asset size of the bake, windows at and past 8 MiB,
   hostile frames against guard pages in ReleaseFast (30,000 cases), a
   context moved, copied or over random bytes, and no state of one asset
   reaching the next.

**Tests.** The whole suite passes (`zig build test -Dsilesia=false`, 23
November: 415 of 423, 8 skipped, the Silesia tests and the 32-bit-only test
in each oracle binary; 33 minutes here). The decompressor's 29 oracle
tests and the review's 13 pass in both oracle binaries (`oracle` against the original with its assembly,
`oracle-scalar` against its scalar build), as a 32-bit x86 process, and in
Debug at 100 fuzz cases. Each fuzz test runs 1,000 cases.

**Speed** (`zig build bench-decompress`, one frame an asset at level 19
with an 8 MiB window, one thread pinned, on the code of 0.2.0;
`doc/BENCHMARKS.md` has the table and the machine): on 2048 x 2048 BC7 and
BC5 textures the port is 33 to 61 times std's decoder and 1.08 to 1.16
times the original's with its assembly loops (BC7 whole mip chains 830
MB/s, single mips 737 to 915 MB/s); on text and source 7.7 times std and
1.11 times the original (1178 MB/s). No asset's frame is under 10% smaller
than the asset, so none would be stored raw.

**For the author.**
- Approved on 22 November: the x86-64 assembly Huffman loops, the switches
  that build one decoder of each kind, and the build-time sizes stay out,
  as deliberate differences listed in `doc/parity.md`; `.basic` BC7 is
  what Loomwork's bake uses; Canterbury and the C sources stand for the
  text set; Loomwork uses no dictionaries, and the original's behaviour
  with several `DDict`s stays (`doc/parity.md`).
- One-shot decompression with `ref_multiple_ddicts` loads the context's
  last `DDict` before the frame picks its own, in the original as in the
  port (`DCtx.decompressDCtx`, `decompressUsingDDict`): frames of other
  dictionaries fail, or decode wrong without a checksum. Streams pick
  first, and so does `decompressFrameExact`.
- The Silesia corpus cannot be fetched from this environment (its host is
  refused by the network policy): `-Dsilesia=false` runs the tests with
  Canterbury only, and the decompression benchmark's text set is
  Canterbury's text files and reference/lib's sources.
- The BC7 and BC5 inputs are 2048 x 2048 mosaics of 7 photos from the
  scikit-image wheel with their mip chains, encoded with zig-bcn `.basic`
  perceptual BC7, as Loomwork's bake, and BC5 normal maps
  (bench/textures/README.md). As Loomwork stores them, each asset is one
  frame at level 19 with an 8 MiB window: a texture's whole mip chain
  (about 5.6 MB), or with streaming each mip on its own (4 MB, 1 MB,
  256 KB, ...).

## Step 4 report (11 November 2026)

**Done.** zstd 1.5.7 pinned in `reference/` (v1.5.7, f8745da6). Every feature in this file
that is not left out is ported and merged on `main`: the entropy coders, every strategy
(fast, dfast, greedy, lazy, lazy2 with the row matcher, btlazy2, btopt, btultra,
btultra2), long-distance matching, the superblock and the pre-splitter, one-shot,
buffer-less and streaming compression (`compressStream2` with continue, flush and end,
stable buffers), dictionaries, prefixes and CDicts, the sequence API and the external
sequence producer, and multithreading on `std.Thread` with its pool.

**Tests.** `zig build test` (corpus on): 306 of 306 pass in 25 minutes (58 unit, 124
`oracle`, 124 `oracle-scalar`); `-Dcorpus=false` skips Silesia and Canterbury. Each fuzz
test runs 1,000 cases. Frames are compared byte for byte with the original's, and every
frame decodes through std's decoder and the original's.

**Speed and ratio** (Silesia, one thread, `zig build bench`, before the performance pass;
`doc/BENCHMARKS.md` has the numbers after the second pass). Ratios are equal at every
level, since the frames are equal.

| levels | port against the original |
| --- | --- |
| -5, -1 | 2% to 3% faster |
| 1 | 10% slower (whole files, noisy) |
| 2 | equal |
| 3, 4 (dfast) | 32% and 23% slower |
| 5 to 12 | 6% faster to 6% slower |
| 13 to 22 | 1% to 5% faster |
| 19 | 2.8% faster (8.3 against 8.0 MB/s, ratio 2.817) |

**Left out, approved by the author (11 November):** the list at the end of this file (dictionary
training, decompression and frame readers, `ZSTD_customMem`, BMI2 dispatch, the strategy
exclusion switches, `ZSTD_COMPRESS_HEAPMODE`, tracing, debug and sanitizer switches, C
build configuration, `ZSTD_C_PREDICT`, the fuzzing mode, `ZSTD_RESIZE_SEQPOOL`).

**For the author.** std's decoder panics when asked to verify a checksum, and takes no
dictionaries (details below). `test/data/snapshot.bin` is a snapshot pack, not B+ tree
pages. Open points for the review are listed below.

## Resume notes

**The decompressor** (branch `decompressor`): `zig build test -Dsilesia=false
-Dtest-filter=<name>` runs its tests by name (the test names start with the
feature: `frames:`, `literals:`, `streaming:`, `fuzz:`, `skeptic`, ...).
`zig build bench-decompress -- --textures DIR` needs the .bc7 and .bc5 files
that bench/textures makes (its README has the commands). Profiling works with
`perf record -e cpu-clock` (this VM has no hardware counters).

Builds: one at a time, `timeout 3000 systemd-run --user --scope -q -p MemoryMax=6G
zig build <step> -j3`, never while the scratchpad's `bench.running` exists.
`zig build check` compiles everything; `zig build test -Dcorpus=false` skips the
corpus runs.

All porting branches (`port/*`) are merged into `main` and pushed. Steps 1 to 4 of the
methodology are done (the step 4 report is above), and README.md, `doc/TESTING.md` and
`doc/parity.md` are on `main`. The left-out list is approved by the author.

**Where things are.**
- `main`: the whole port, 298 of 298 tests passing with the corpora (`zig build test`,
  28 minutes), the docs, and the benchmark tables in `doc/BENCHMARKS.md` (from before
  step 5).
- `review/perf-and-skeptic`: `main` plus step 5's first change, `cc86709` (the
  double-fast finder's range test on the long candidate is a conditional move on x86-64,
  as upstream's inline-asm `ZSTD_selectAddr` is; level 4 takes 11% less time), and the
  first skeptic's probes in `test/skeptic_test.zig` behind `-Dskeptic` (all passing). A
  second skeptic adds failing tests there, one per finding, named `skeptic: ...`.
- The second skeptic (11 and 12 November), its tests behind `-Dskeptic`:
  - `skeptic: a 2 GiB prefix with window log 31 overflows the dictionary's validity
    check` panics with an integer overflow: `Window.checkDictValidity` and
    `Window.enforceMaxDist` (`compress_internal.zig`) add the window size to the
    dictionary's end in u32 with `+`, where the original's sums wrap. Any dictionary,
    prefix or CDict whose end index reaches 2^31 with window log 31 gets there; the
    dictMatchState assert in `double_fast.zig` (`dict_limit + (1 << window_log)`) is the
    same sum. **Fixed** in `46975b9`: the sums wrap (`+%`); no other u32 index sum in
    the window, the LDM or the finders has the pattern. The test is now `refPrefix: a
    2 GiB prefix with window log 31` in the normal suite (a read-only mapping of zero
    pages: a few MB, a few milliseconds).
  - `skeptic: a thread pool replaced by refThreadPool still runs the context's workers`
    fails: the multithreaded context keeps the pool and the `Io` it was made with, so
    the docs of `refThreadPool`, of the `pool` field and of `CCtx` in `zstd.zig` ("until
    they are replaced") promise what neither the port nor the original does. **Fixed**
    in `30528a0`: the docs say valid until the context is destroyed, and `multithreading:
    a pool set after the first frame with workers is not used` checks that both sides
    keep the first pool (the original's through `reference_mtFactory`).
  - Docs: `copyCCtx` does not say that the copy refers to what the source's window
    refers to (a `compressBeginUsingDict` dictionary, a CDict's content) until its frame
    ends, and `zstd.zig`'s list of references misses it. **Fixed** in `1e9973b`, with
    the docs of the `CDict` and local dictionary fields, which said a session reset
    ends them.
  - `test/mt_test.zig`'s `Observed` compares `sizeof_after_init` with workers, which
    differs between two runs of the original itself (9,167,360 against 7,337,440 in
    `zstdmt: a context reused, resized, abandoned mid-frame, on a shared pool`): drop it
    with workers. **Fixed** in `dfc7422`: the size is not compared after an abandoned
    frame, the one case whose pools depend on timing; `common.generated(0, ...)` is
    guarded in the same commit.
  - `-Doverflow-correct-frequently` (build.zig) builds both sides with
    `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY`, so the main window's overflow correction
    (`reduceIndex`, never reached by the normal suite) runs: 33 of 34 frame, stream,
    dictionary, worker and LDM tests pass at 150 fuzz cases; the 34th is the flake above.
    After the fixes the whole suite passes with it: 300 of 306 at 150 cases (the 6
    corpus runs skipped).
  - Debug (`-Dtest-optimize=Debug`, 40 fuzz cases): entropy, fast, dfast, lazy, opt and
    LDM, 50 of 50; frame, dictionaries, streams, sequences and workers, 54 of
    55 before the run was stopped in the 55th (`CDict: every way to make one ...`, still
    running after 18 minutes); in Debug the 2 GiB prefix test panics at
    `compress_internal.zig:545` (`checkDictValidity`).
  - 32-bit (`-Dtarget=x86-linux-musl`, run natively): the port does not compile.
    `compress_internal.zig:1100` and `compress_literals.zig:77` shift a `usize` by a
    `u6`, and `fse_compress.zig:589` and `:598` mix `isize` with `u32`, which fit only
    on 64-bit targets; the tests take a 64-bit `usize` too (`1 << 40` output windows in
    `stream_test.zig` and `mt_test.zig`, a 64-bit constant at `lazy_test.zig:428`).
    Nothing builds or tests a 32-bit target, though `params.zig` keeps the 32-bit limits.
    **Fixed** in `af1aa14` (it compiles, and the tests drop their 64-bit assumptions)
    and in `6a5af9d`, `6368d7b`, `fdfe348`, `ccdf06d`, `99df126` and `05d37e0` (the
    points below). `test -Dtarget=x86-linux-musl -Dcorpus=false` runs natively here in
    about 34 minutes; counts in `doc/TESTING.md`. What was left after `af1aa14`:
    - **`p - window.base` without wrap-around** (55 sites: `fast.zig` 23,
      `double_fast.zig` 14, `compress_internal.zig` 7, `compress.zig` 5, `ldm.zig` 3,
      `opt.zig` 2, `lazy.zig` 1). A reused context keeps its indexes across frames, so
      `base` sits that far before the next input; with an input at a low address
      (`compressCCtx: edge cases`, a constant in `.rodata`), `base` wraps below 0 and
      `@intCast(@intFromPtr(p) - @intFromPtr(base))` panics (`buildSeqStore`,
      `compress.zig:3101`), where the original's pointer difference cast to U32 wraps.
      **Fixed**: every pointer difference from a window's `base` or `dict_base` (63 sites,
      and the asserts in `opt.zig`) subtracts with `-%`, as the original's pointer
      difference cast to U32 wraps, and casts with `@intCast`: an index is below 2^32 by
      the window's own limits, and the cast keeps that fact for the optimizer. The x86-64
      bench binary's disassembly is the same, instruction for instruction, before and
      after; a `@truncate` of the same difference spilled `curr` in dfast's loop and took
      1.7% longer at levels 2 to 4. `compressCCtx: edge cases` passes on 32-bit.
    - **Tables past the address space**: a hash or chain log of 30 (4 GiB of u32) is in
      bounds on 32-bit, and the original's size_t sums wrap to a workspace too small for
      its tables; the port's estimate panics with an integer overflow
      (`estimateCCtxSizeUsingCCtxParamsInternal`, from `setParameter, getParameter:
      every parameter over its bounds`, at a long distance hash log of 29 with long
      distance matching off, whose unused table size overflowed). **Fixed**: the
      estimates wrap as the original's do and return its values (`estimate: the largest
      table logs, past a 32-bit address space`); compressing with a table whose own size
      wraps, where the original reserves no room for it and writes past its workspace,
      the port refuses with `error.MemoryAllocation` (`compressStream2: tables past a
      32-bit address space are refused`, port only), noted in `doc/parity.md`.
    - `initStatic: workspaces of the estimated size, and one byte less` fails an
      `expect` with no output (likely a workspace of the level-22 estimate that a
      32-bit process cannot allocate twice). **Fixed**: the address space. It passes
      on its own and in a run where it gets a fresh process; once the earlier crashes
      were fixed, the long-running test process ran out of room for contexts of levels
      20 to 22 (400 to 900 MB each, two to four at a time): its `StaticPair.init`
      failed with `OutOfMemory` through `try`, which prints nothing, two frame tests
      got the port's memory allocation error where the original had just taken the
      room, `compressBlock: blocks of a frame body, and copyCCtx` crashed in the
      port's table copy, and `compressStream2: every level, chunks, flushes and small
      windows` looped for 30 minutes (both sides failing, the loop never ending).
      Those four tests skip levels 20 to 22 on 32-bit (`common.levelFits`), the
      stream loop stops on an error, and the initStatic test names its level and
      size when it fails. `copyCCtx` returns its reset's error where the original
      carries on into tables it has not reserved (`doc/parity.md`).
    - `compressStream2: fuzzed calls ...` (seed 984, case 479) gave the same raw value
      on both sides, 2^32 - 113, in the original's error range; the harness now takes
      that as the same, but why the hint wraps on 32-bit only is not yet known.
      **Explained**: it is the original's behaviour, and the port matches it on every
      target. `compressStream` with a stable input that has not started its frame
      returns the last frame's block size less the input held back (applied
      parameters from the frame before), which wraps when that input is larger: there
      23,605 less 23,718. It shows on 32-bit only because the fuzzer draws with
      `uintLessThan(usize, ...)`, so the cases differ between targets. `compressStream:
      a stable input's size hint after a smaller frame` makes the case on both
      targets, and `expectSameResult` says why it takes the raw value.
    - Found once the crashes above no longer hid it: in `compressStream2: fuzzed
      calls, ...` on 32-bit, a sub-block of a `targetCBlockSize` block copied its
      entropy tables into 5 bytes of room (the port's index check panicked). The
      original copies them without checking and writes past the stable output
      buffer: with the port fixed, it corrupted the harness's allocator. **Fixed**:
      the port's sub-block returns `error.DstSizeTooSmall` there and the block falls
      back to a raw block (`doc/parity.md`); the fuzzer gives a stable output too
      small only to sets without a target block size, drawing the same numbers, and
      ends a case after a failed frame that leaves stable input held back, the
      reset's known gap (open points below).
  - The benchmark: the original is a shared library built without upstream's own
    `-fvisibility=hidden` (`reference/lib/Makefile:147`), so 460 call sites into its
    own functions (`HIST_countFast_wksp`, `FSE_buildCTable_wksp`, `HUF_buildCTable_wksp`,
    `ZSTD_selectBlockCompressor`, ...) go through the PLT, unlike upstream's own `.so` or
    `.a`; likely small, not measured. The verdicts are medians with no noise floor: the
    -5 and -1 rows' "faster" (3.0%, 1.6%) sit inside min-max spreads of 28% to 64% of
    their medians.
  - Coverage: the fuzzers cap the window log at 25, hash and chain logs at 24, the LDM
    hash log at 22 and its rate at 9 (`frame_params_test.zig:165`), on inputs of at most
    400 KB from one generated buffer, and dictionaries stay at or below 110 KB; no test
    sets a window log above 25, which is where the overflow above lives. `oracle-scalar`
    runs other port code only in the row matcher's tag compare and the sequence
    conversion. **Fixed** in `7cc99a7`: fresh contexts reach window log 27, hash and
    chain logs 26, long distance hash log 27 and every rate, inputs reach 3 MiB and
    dictionaries (all four ways in) 20 MiB; about a minute per binary, at most 310 MB.
    The Canterbury corpus already runs at every positive level, so at every strategy.
  - Probes that found nothing: pledged sizes near 2^64 with dictionaries, CDicts,
    prefixes and workers; LDM hash logs 25 to 27, bucket log 8, minimum matches 4 to
    4096, rates 0 to 25, window logs 27 to 31; size hints near 2^31 with dictionaries;
    `max_block_size` 1024 with superblocks; CDicts of 16 MiB less 3 bytes to 20 MiB,
    past the short cache's limit, at levels -5 to 4 with every attach mode; eight
    workers with long distance matching on 512 KiB jobs, streamed in small pieces with
    flushes and small output windows, six runs of each; an input of 3.5 GiB and 8 MiB
    at levels 1, 5 and 13, through indexes past 2^31 and the overflow correction at its
    real threshold (3500 MiB).
- `review/perf-2` (worktree `zig-zstd.wt/perf2`): the second perf pass, made from
  `review/perf-and-skeptic`. Its target is no level slower than upstream, level 3 and 4
  first. Each kept change is one commit with its pinned-core gain in the message; its
  notes on what was tried are in the section below as they land.
- `review/perf-3` (worktree `zig-zstd.wt/perf3`): the third perf pass, made from
  `review/perf-and-skeptic`, on code placement at levels 1 and 5 to 9 (notes below).
- `port/*`: the merged porting branches, kept for history.

**The second performance pass** (`review/perf-2`, worktree `zig-zstd.wt/perf2`), as of
03:40 on 12 November:
- Profiling works: `perf record -e cycles:u` (user-mode events pass `perf_event_paranoid`
  2; only kernel events are blocked). In a profile of the bench, `bench` is the port and
  `libzstd_reference.so` the original, so `perf report --sort dso,sym` compares them
  function by function. Sample with `-c 1000000`; pin with `taskset -c 6` under the lock.
  Instruction counts (`instructions:u`) do not depend on load, so instruction profiles
  can run without the lock; cycle profiles need it.
- Level 3 before this pass: the dfast block compressor took 40.9% of the cycles against
  the original's 37.6%, and ran 32% more instructions (37.8% of all instructions against
  28.6%). The inner search loops cost the same; the match path (count, storeSeq, table
  inserts, repeat offsets) cost about 30% more. The entropy stages are even.
- Kept: the repeat offsets swap through a temporary (fast and dfast, every dictionary
  mode) and the Huffman sort swaps nodes the same way. `std.mem.swap` in Zig 0.17 swaps
  byte by byte, which split the offsets into bytes for the whole function. Level 3 1.078
  to 1.031, level 4 1.098 to 1.058 (pinned, 5 runs); level 1 unchanged at 1.058. The
  fast, dfast, Huffman and compressCCtx oracle tests pass (49 of 49).
- Kept: the dfast noDict loop is one labeled switch whose `continue`s name their targets.
  The search loop left with the next step as a value, and the dispatch on it compiled to
  jump tables (23 indirect jumps) with the live values on the stack. Level 3 1.038 to
  1.006 and 0.999 (two passes), level 4 1.057 to 1.041.
- Kept: the bench turns transparent huge pages off for its process; `--huge-pages` leaves
  them as the system has them and `--original-first` lets the original allocate first.
  With them on, which side's tables got huge pages followed where malloc placed each
  context: level 4 went from 1.038 to 0.960 when the original allocated first, and a
  rebuilt original moved its own levels 5 to 8 by 6%. With them off the order changes
  nothing and the L1 TLB misses split evenly between the sides.
- Kept: the bench's original is upstream's shared library build (`benchReferenceLibrary`
  in build.zig, -fPIC -fvisibility=hidden); the tests keep theirs. The original's times
  did not move (within 0.5%). Every ratio from then on is against it with huge pages
  off: level 1 1.04, level 3 1.015, levels 4 to 8 0.99 to 1.01. Time only while core 6
  and its sibling 22 are idle: other sessions' test runs share the machine, and a busy
  sibling inflates a run by half.
- Kept: `seqToCodes` keeps the three code tables in locals, as the original does: a code
  byte stored through the store's pointers made the loop read them again after every byte.
  Levels -5 to 3 0.5% to 1.2% faster (level 2 1.020 to 1.008); from level 4 within the
  passes' spread.
- Kept: fast's repeat-offset test makes both comparisons with `&`, as the original's, with
  no branch between them. Measured in the final state with and without it, level 1 goes
  from 1.021 to 1.000 and levels -1 to 3 gain 0.5% to 1.6%. Added on its own after
  `seqToCodes` it measured slower: changes of 1% to 2% are the size of the swings between
  builds, so this change and the next two are each measured in the final state.
- Kept: `getLowerBits` masks with `bzhi` on BMI2 targets built with intrinsics, as
  `BIT_getLowerBits` does. In the final state, every level but 4 0.1% to 2.4% faster
  with it, level 4 0.6% and 1.0% slower.
- Kept: `storeSeq` and `storeSeqOnly` read the literal and sequence pointers once into
  locals and write the sequence whole. In the final state, levels 1 and 6 to 8 1.1% to 3.2%
  faster with it, level -5 0.8% to 2.1% slower, the others within 1.1%.
- Kept: the bench's last column says "within noise" where the two sides' min-max spreads
  overlap.
- Kept: the bench runs the multithreaded rows (`port_multithread_merged = true`); the
  port's context gets the bench's `Io` before `nb_workers`.
- The final run (`doc/BENCHMARKS.md`, the whole run pinned, huge pages off): faster or
  within noise at levels -5, -1, 3, 4 and 10 to 22 (3.5% faster at 10, 1.6% to 2.8% from
  13); slower at level 1 by 2.1%, level 2 0.8%, levels 5 to 9 1.5% to 3.6%. There the port
  runs as many instructions as the original or fewer (0.95 at level 1, 0.99 to 1.00 at 5
  to 8), and the gap moves with where the code sits: a build with the same port code 1360
  bytes earlier measured level 1 at 1.00 and levels 5 to 8 at 0.99 to 1.02; profiles of
  the two show the port's hot loops taking 2% to 14% more cycles for the same instructions.
  The kept source changes above are each worth 1% to 2%, the size of those swings.
- The multithreaded rows run and give the same frames; on five cores level 3 with 4
  workers is even (1.002) and level 19 within noise.
- The full suite (`zig build test -Dcorpus=false`) passes 293 of 300, 6 skipped; the
  failure is the timing-dependent multithreading test in the open points below, which
  fails the same way on the sources before the pass's changes.
- Left as is: the prefix copy in `zstdmt.zig` is `std.mem.copyForwards`, a byte loop where
  the original uses memmove; it runs once each time the round buffer wraps.
- Tried and dropped: the dfast repeat-offset test as `&` (no change in time), glibc's
  `glibc.malloc.hugetlb` tunable for the huge-page bias (no effect).
- Next, if wanted: why the row matcher's searches at levels 5 to 9 and the fast loop at
  level 1 lose cycles in some layouts (`perf annotate` of both builds' hot loops).

**The third performance pass** (`review/perf-3`, worktree `zig-zstd.wt/perf3`), 12 November:
- Kept: `-Dbench-code-shift=N` puts N dead bytes into the bench's `main`, so the port's
  functions land elsewhere with the same code (`9c864e3`). Placement tests below use 0, 16
  and 1360. The shift does not move code by exactly N: check where the hot functions land
  with `nm`.
- Found: the placement gap is instruction-cache misses on loops that straddle a 4 KiB page.
  With the same bytes for the fast block compressor, one build missed the L1i 15 million
  times at level 1 and another 194 million (`ic_tag_hit_miss.instruction_cache_miss:u`,
  `perf record` of it puts 76% in that function's loop, which crossed a page in the slow
  build only), and the loop took 3.8% more cycles. The original's row search at levels 5
  to 9 takes misses of the same size in its own build. Cache-line alignment alone (64)
  fixed levels 5 to 9 at three placements but left level 1 at 0.999 to 1.021, as its loop
  sits in the middle of the 17 KiB fast dispatcher.
- Kept (`2c17cff`): the functions that run the inner loops are aligned to 4096
  (`hot_code_align`): fast and double-fast variants, lazy block compressors, hash-chain,
  row and binary-tree searches, the histogram, the sequence encoder, the Huffman 1X coder,
  buildSequencesStatistics. The fast and double-fast variants are noinline functions of
  their own (under 4 KiB each), where they were inlined into one dispatcher. Levels 5 to 9
  0.99 to 1.006 at every placement (before 1.011 to 1.027), level 1 1.007 to 1.010 (before
  1.018), levels 3 and 4 within 1% of before. Cost: 225 KB of padding in the text of the
  ReleaseFast bench binary for x86-64 (1.24 to 1.47 MB), never fetched; ReleaseSmall
  builds leave the functions unaligned (`hot_code_align` is 1 there).
- Left slower (every ratio is the port's time over the original's): levels -5, -1 and 2
  lose 0.5% to 2% against the build before (-5 0.994 before, 1.000 to 1.006 at the three
  placements; -1 0.982 before, 1.004 to 1.006; 2 1.005 before, 1.009 to 1.012), and
  levels 1 and 2 stay about 1% slower than the original at every placement. The split-out
  fast variants compile to about 10% more instructions in their loop than the inlined
  ones (more spills of loop invariants), and the port's side runs about 6% more
  instructions at level 1 (an instruction profile of the port's code alone). Padding a
  variant's entry by 16, 32 or 48 bytes moved level 1 by under 0.6%, so it is not the
  loop's place in a cache line.
- Tried and dropped: page-aligning the fast dispatcher with the variants inlined (level 1
  1.018: its loop crosses the page at offset 16 KiB), and entry padding in the fast
  variants (above).
- Next, if wanted: the fast variant's register allocation (the inlined version keeps the
  hash prime in memory and spills fewer loop invariants); restricting the page alignment
  to the no-dictionary paths would roughly halve the padding.

**To resume.**
1. Step 7 is done: the full suite with the corpora passes on x86-64 (310 of 312, the 2
   skipped being the 32-bit-only refusal test), and the 32-bit suite passes (counts in
   `doc/TESTING.md`). `-Dskeptic` and `-Doverflow-correct-frequently` last ran before
   the 32-bit fixes.
2. Step 8 after the author's review: merge into `main`, version and tag.

Builds and timing: `perf` is blocked by `perf_event_paranoid` for agents on this
machine. Time with the build lock held and pinned to one core, for example
`flock <lock> taskset -c 6 ./zig-out/bin/bench --levels 3,4 --runs 5`; the bench turns
transparent huge pages off for its process (see `doc/BENCHMARKS.md`).

Pushing: `main` and the review branch go to
`git@github.com:farhollowgames/zig-zstd.git`, fast-forward only.

## For the author

- The decompressor's points are in its report at the top of this file.
- std's decoder (`std.compress.zstd.Decompress`, Zig 0.17.0) cannot verify
  checksums: with `.verify_checksum = true`, any frame with a checksum and a
  non-empty block panics with "TODO all those bytes written needed to go
  through the hasher too" (Decompress.zig:373). The smallest input that shows
  it is one byte compressed with `ZSTD_c_checksumFlag` = 1. The tests decode
  through std without checksum verification and through the original with it.
- Loomwork's snapshots hold table rows as column chunks, not B+ tree pages,
  so `test/data/snapshot.bin` (a real snapshot pack from the mmo example's
  server) stands in for "B+ tree pages from a snapshot".
- std's decoder takes no dictionaries, so frames made with a dictionary or a
  prefix round-trip through the original's decoder only.

## Open points for review

- Left out, not yet put to the author: WebAssembly targets. Zig rejects function
  alignment on wasm, so `hot_code_align` (third performance pass) does not compile
  there; `main` already fails on wasm32 before it, at `compress.zig:310` (found in the
  third pass's review). Neither is fixed.
- The optimal parser keeps upstream's asserts that a dictionary's Huffman
  codes are at most 11 bits and its FSE costs under 10 when it prices from
  the dictionary's tables. A hand-made dictionary that breaks them panics in a
  safe build, where upstream's release build carries on (the Huffman case is
  undefined behaviour in C). Dictionaries from the trainer satisfy both.
- `BlockTest.create` (test-only) panics on an empty block; compression never
  runs a block compressor on one.
- With long distance matching on and `ldmMinMatch` unset,
  `ZSTD_estimateCCtxSize_usingCCtxParams` and `ZSTD_estimateCStreamSize_usingCCtxParams`
  divide by zero: the original dies with SIGFPE, the port panics in a safe
  build. The estimates skip `ZSTD_ldm_adjustParameters`, which fills it in.
- An `ldmHashRateLog` over the window log makes the original's long distance
  hash log its maximum, 30: an 8 GiB table, even for an empty input. The
  port does the same.
- `initStatic` over a workspace a few bytes larger than the context: the
  original's space check wraps, and it returns a context without its block
  states, which crashes on first use. The port returns null.
- A static context cannot compress with a dictionary loaded by reference:
  `ZSTD_initLocalDict` digests it into a `CDict`, which the original mallocs
  even for a static context, and the port refuses with
  `error.MemoryAllocation` (both refuse a copy at load time).
- `CCtx.generateSequences` takes an allocator for its scratch frame, where the
  original mallocs it.
- Workers need an `std.Io`: `CCtx.setIo`, or the one of a pool given with
  `refThreadPool`. A context with workers and neither refuses with
  `error.ParameterCombinationUnsupported`. A static context cannot make its
  multithreaded context (`error.MemoryAllocation`); the original mallocs it.
- `ZSTD_CCtx_reset` leaves the count of stable input not yet taken: after a
  broken stable-input promise before a frame starts, the original's next frame
  steps back past its input and reads out of bounds. The port's assert on it
  panics in a safe build. Likewise `ZSTD_flushStream` and `ZSTD_endStream`
  before a stable-input frame starts, when the context's last frame (or none)
  buffered its input. The tests stay clear of both.
- `ZSTD_getFrameProgression` asserts at most a block buffered, but buffers a
  block and one byte when the pledged size is exactly a block; the port's
  assert allows the extra byte.
- Malformed caller sequences: the asserts in `convertBlockSequences`,
  `get1BlockSummary`, `offsetToOffbase` and `storeSeqOnly` panic in a safe
  build, where the original's release build carries on.
- The original's `convertSequences` takes its AVX2 path on `__AVX2__`, even
  with `ZSTD_NO_INTRINSICS`; the port takes its vector path only with
  `-Dintrinsics` and AVX2. Results are the same except for lengths of 2^31
  and over.
- `compressSequencesAndLiterals` keeps `litCapacity` and reads only the
  literals given. `compressSequences` ignores a frame header that does not
  fit, as the original does (under 18 bytes of output is undefined there);
  the tests give at least 18.
- The multithreading test "a context reused, resized, abandoned mid-frame, on
  a shared pool" compares the context's size right after a frame is
  abandoned. That size counts the worker contexts the abandoned jobs
  created, which follows the threads' timing: on a loaded machine (12
  November), the port's came out one or two contexts short of the
  original's (9167360 and 7337440 bytes against 10997280), with and without
  the second performance pass's changes. **Fixed** in `dfc7422`: the size is
  no longer compared after an abandoned frame.

## Frame and one-shot compression

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compress` | `compress` | oracle-tested |
| `ZSTD_compressBound`, `ZSTD_COMPRESSBOUND` | `compressBound` | oracle-tested |
| `ZSTD_compressCCtx` | `CCtx.compressCCtx` | oracle-tested |
| `ZSTD_compress2` | `CCtx.compress2` | oracle-tested (through `compressStream2_simpleArgs` with stable buffers, as the original; with 1, 2 and 4 workers, job sizes, overlaps, `rsyncable`, LDM, checksum) |
| `ZSTD_compress_advanced` | `CCtx.compressAdvanced` | oracle-tested |
| `ZSTD_writeSkippableFrame` | `writeSkippableFrame` | oracle-tested |
| `ZSTD_minCLevel`, `ZSTD_maxCLevel`, `ZSTD_defaultCLevel` | same | oracle-tested |
| `ZSTD_versionNumber`, `ZSTD_versionString` | `params.version_number`, `params.version_string` | ported (constants for 1.5.7; the tests check the reference's number) |
| `ZSTD_isError`, `ZSTD_getErrorCode`, `ZSTD_getErrorName` | `Error`, `errorCode` | oracle-tested (every failing result compares its code with the original's; names are Zig's error names) |
| frame header: magic, window descriptor, content size, dictionary id, single segment | in `compress.zig` | oracle-tested |
| checksum (XXH64) | `std.hash.XxHash64` | oracle-tested |
| raw, RLE and compressed blocks; last-block flag | in `compress.zig` | oracle-tested |
| `ZSTD_f_zstd1_magicless` | `Format.zstd1_magicless` | oracle-tested |

## Levels and strategies

| original | zig-zstd | state |
| --- | --- | --- |
| levels 1 to 22, the default level (3), level 0 | `clevels.zig` | oracle-tested (the table, against `ZSTD_getCParams`) |
| negative levels (`ZSTD_minCLevel` = -131072) | `fast` with target length | oracle-tested per block (the table rows, and `fast` with target lengths up to 100) |
| `ZSTD_fast` (`zstd_fast.c`), with dictMatchState and extDict | `fast.zig` | oracle-tested per block and in frames |
| `ZSTD_dfast` (`zstd_double_fast.c`) | `double_fast.zig` | oracle-tested per block and in frames |
| `ZSTD_greedy`, `ZSTD_lazy`, `ZSTD_lazy2` (hash chain) | `lazy.zig` | oracle-tested per block, with dictMatchState and extDict, and in frames |
| the row-based match finder (`useRowMatchFinder`), SSE2 and NEON tag compare | `lazy.zig`, `@Vector` | oracle-tested per block and in frames, SIMD and scalar builds (NEON only by a unit test on x86) |
| `ZSTD_btlazy2` (binary tree) | `lazy.zig` | oracle-tested per block, with extDict, and in frames with dictionaries |
| dedicated dictionary search (`enableDedicatedDictSearch`) | `lazy.zig` | oracle-tested per block and in frames with CDicts |
| `ZSTD_btopt`, `ZSTD_btultra`, `ZSTD_btultra2` (`zstd_opt.c`), with dictMatchState and extDict, btultra2's two passes over the first block | `opt.zig` | oracle-tested per block (`test/opt_test.zig`) and in frames |
| the optimal parser's price model: dictionary entropy tables, fixed prices for tiny blocks, literal compression off, statistics across blocks | `opt.zig` | oracle-tested per block |
| long distance match candidates in the optimal parser (`ZSTD_optLdm_*`) | `opt.zig` | oracle-tested per block, on hand-made candidates; and in frames with `ldm.zig`'s |
| long-distance matching (`zstd_ldm.c`) | `ldm.zig` | oracle-tested below the frame (`test/ldm_test.zig`: gear hash splits, parameter defaults, sequence skipping and splitting, `ZSTD_ldm_generateSequences` over far repeats, dictionaries, full stores and the overflow correction, `ZSTD_ldm_blockCompress`) and in frames, single-threaded and with workers. `ZSTD_ldm_gear_reset` never stores its hash in the original, and the port keeps that |
| `ZSTD_getCParams`, `ZSTD_getParams`, `ZSTD_checkCParams`, `ZSTD_adjustCParams` | same | oracle-tested |

## Entropy coding

| original | zig-zstd | state |
| --- | --- | --- |
| `HIST_count`, `HIST_countFast`, `_wksp` variants | `hist.zig` | oracle-tested |
| FSE: `FSE_optimalTableLog`, `FSE_normalizeCount`, `FSE_writeNCount`, `FSE_buildCTable_wksp`, `FSE_buildCTable_rle`, `FSE_compress_usingCTable` | `fse_compress.zig` | oracle-tested |
| the FSE state encoder of `fse.h` (`FSE_initCState`, `FSE_initCState2`, `FSE_encodeSymbol`, `FSE_flushCState`, `FSE_getMaxNbBits`, `FSE_bitCost`) and the bit stream writer of `bitstream.h` | `fse_compress.zig`, `bitstream.zig` | oracle-tested |
| Huffman: `HUF_optimalTableLog`, `HUF_buildCTable_wksp`, `HUF_writeCTable_wksp`, `HUF_compress1X_repeat`, `HUF_compress4X_repeat`, `HUF_compress1X_usingCTable`, `HUF_compress4X_usingCTable`, `HUF_readCTable`, `HUF_validateCTable` | `huf_compress.zig` | oracle-tested |
| `FSE_readNCount`, `HUF_readStats` (dictionary loading) | `entropy_common.zig` | oracle-tested |
| literals: raw, RLE, Huffman 1 and 4 streams, repeat table | `compress_literals.zig` | oracle-tested (`ZSTD_compressLiterals` on real blocks' literals) |
| sequences: `ZSTD_selectEncodingType`, `ZSTD_buildCTable`, `ZSTD_encodeSequences` | `compress_sequences.zig` | oracle-tested (each function, on real blocks' sequences) |

## Parameters (`ZSTD_CCtx_setParameter`, `ZSTD_CCtxParams_setParameter`)

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_c_compressionLevel` | `.compression_level` | oracle-tested |
| `ZSTD_c_windowLog`, `hashLog`, `chainLog`, `searchLog`, `minMatch`, `targetLength`, `strategy` | same names | oracle-tested |
| `ZSTD_c_targetCBlockSize` (superblocks, `zstd_compress_superblock.c`) | `.target_cblock_size` | oracle-tested |
| `ZSTD_c_enableLongDistanceMatching`, `ldmHashLog`, `ldmMinMatch`, `ldmBucketSizeLog`, `ldmHashRateLog` | same names | oracle-tested |
| `ZSTD_c_contentSizeFlag`, `checksumFlag`, `dictIDFlag` | same names | oracle-tested |
| `ZSTD_c_nbWorkers`, `jobSize`, `overlapLog`, `rsyncable` | same names | oracle-tested (bounds, set and get; frames with 1, 2 and 4 workers through `compress2` and `compressStream2`) |
| `ZSTD_c_format` | `.format` | oracle-tested |
| `ZSTD_c_forceMaxWindow`, `forceAttachDict` | same names | oracle-tested |
| `ZSTD_c_literalCompressionMode` | `.literal_compression_mode` | oracle-tested |
| `ZSTD_c_srcSizeHint` | `.src_size_hint` | oracle-tested |
| `ZSTD_c_enableDedicatedDictSearch` | same | oracle-tested |
| `ZSTD_c_stableInBuffer`, `stableOutBuffer` | same | oracle-tested (set and get; stable buffers in every mix, broken promises refused) |
| `ZSTD_c_blockDelimiters`, `validateSequences` | same | oracle-tested (set and get; `compressSequences` in both formats, with and without validation) |
| `ZSTD_c_blockSplitterLevel`, `splitAfterSequences` (post-split, `ZSTD_compressBlock_splitBlock`) and the pre-splitter (`zstd_preSplit.c`) | same, `pre_split.zig` | oracle-tested |
| `ZSTD_c_useRowMatchFinder` | same | oracle-tested |
| `ZSTD_c_deterministicRefPrefix` | same | oracle-tested |
| `ZSTD_c_prefetchCDictTables` | same | set and get oracle-tested (no effect on the output) |
| `ZSTD_c_enableSeqProducerFallback` | same | oracle-tested |
| `ZSTD_c_maxBlockSize` | same | oracle-tested |
| `ZSTD_c_repcodeResolution` (`searchForExternalRepcodes`) | same | oracle-tested |
| `ZSTD_cParam_getBounds` | `cParamGetBounds` | oracle-tested |
| `ZSTD_CCtx_getParameter`, `ZSTD_CCtxParams_getParameter` | same | oracle-tested |
| `ZSTD_CCtx_setCParams`, `setFParams`, `setParams` | same | oracle-tested |
| `ZSTD_createCCtxParams`, `freeCCtxParams`, `CCtxParams_reset`, `_init`, `_init_advanced` | `CCtxParams` | oracle-tested |
| `ZSTD_CCtx_setParametersUsingCCtxParams` | same | oracle-tested |
| `ZSTD_CCtx_setPledgedSrcSize` | same | oracle-tested |
| `ZSTD_CCtx_reset` (session, parameters, both) | `CCtx.reset` | oracle-tested |

## Contexts and memory

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_createCCtx`, `ZSTD_freeCCtx`, `ZSTD_createCCtx_advanced` (custom allocator) | `CCtx.create(gpa)`, `CCtx.destroy` | oracle-tested |
| `ZSTD_initStaticCCtx`, `ZSTD_initStaticCStream`, `ZSTD_initStaticCDict` | `initStatic` | oracle-tested |
| context reuse: tables kept between frames, workspace resize and shrink rules | `cwksp.zig` | oracle-tested (many frames on one context, changing parameters, resets) |
| `ZSTD_sizeof_CCtx`, `ZSTD_sizeof_CStream`, `ZSTD_sizeof_CDict` | same | oracle-tested |
| `ZSTD_estimateCCtxSize*`, `ZSTD_estimateCStreamSize*`, `ZSTD_estimateCDictSize*` | same | oracle-tested |
| `ZSTD_copyCCtx` | same | oracle-tested |

## Streaming

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compressStream2` with `ZSTD_e_continue`, `ZSTD_e_flush`, `ZSTD_e_end` | `CCtx.compressStream2` | oracle-tested (`test/stream_test.zig`: every call's result, positions and progression; every level, one-byte windows, fuzzed calls, modes, dictionaries, pledged sizes and frames; workers) |
| `ZSTD_compressStream2_simpleArgs` | `CCtx.compressStream2SimpleArgs` | oracle-tested |
| `ZSTD_createCStream`, `freeCStream`, `CStreamInSize`, `CStreamOutSize` | `CStream` (= `CCtx`), `cStreamInSize`, `cStreamOutSize` | oracle-tested |
| `ZSTD_initCStream`, `_srcSize`, `_usingDict`, `_advanced`, `_usingCDict`, `_usingCDict_advanced`, `ZSTD_resetCStream` | same | oracle-tested |
| `ZSTD_compressStream`, `ZSTD_flushStream`, `ZSTD_endStream` | same | oracle-tested |
| `ZSTD_getFrameProgression`, `ZSTD_toFlushNow` | same | oracle-tested after every single-threaded call; with workers, run but timing-dependent, so not compared |
| buffer-less: `ZSTD_compressBegin*`, `ZSTD_compressContinue`, `ZSTD_compressEnd`, `ZSTD_getBlockSize`, `ZSTD_compressBlock` | same | oracle-tested |

## Dictionaries

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_compress_usingDict` | same | oracle-tested |
| `ZSTD_CCtx_loadDictionary`, `_byReference`, `_advanced` (raw content, full dictionary, auto) | same | oracle-tested |
| `ZSTD_CCtx_refPrefix`, `refPrefix_advanced` | same | oracle-tested |
| `ZSTD_createCDict`, `freeCDict`, `_advanced`, `_advanced2`, `_byReference` | `CDict` | oracle-tested |
| `ZSTD_compress_usingCDict`, `_usingCDict_advanced`, `ZSTD_CCtx_refCDict` | same | oracle-tested |
| attach, copy and load of a CDict (`forceAttachDict`) | in `compress.zig` | oracle-tested |
| entropy tables from a full dictionary (`ZSTD_loadCEntropy`) | in `compress.zig` | oracle-tested |
| `ZSTD_getDictID_fromDict`, `ZSTD_getDictID_fromCDict` | same | `getDictId` of a `CDict` oracle-tested; `ZSTD_getDictID_fromDict` is not ported |

## Sequences

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_sequenceBound`, `ZSTD_generateSequences`, `ZSTD_mergeBlockDelimiters` | same | oracle-tested |
| `ZSTD_compressSequences` (with and without delimiters, validation) | same | oracle-tested (`test/compress_sequences_test.zig`: generated and synthetic sequences, both formats, validation, repeat offsets, invalid sequences, small outputs) |
| `ZSTD_compressSequencesAndLiterals` (AVX2 conversion path) | same | oracle-tested (generated and synthetic sequences, refusals; vector and scalar paths) |
| `ZSTD_registerSequenceProducer`, `ZSTD_CCtxParams_registerSequenceProducer` (external match finders, fallback) | `SequenceProducer` | oracle-tested |

## Multithreading

| original | zig-zstd | state |
| --- | --- | --- |
| `zstdmt_compress.c`: jobs, overlap, job size, `rsyncable`, long distance matching across jobs, checksum, flush, frame progression, `updateCParams_whileCompressing` | `zstdmt.zig` on `std.Thread` and `std.Io` locks | oracle-tested (`test/mt_test.zig`: `ZSTDMT_initCStream_internal` and `ZSTDMT_compressStream_generic` driven as `ZSTD_compressStream2` drives them, every frame equal on every run; and through `compressStream2` and `compress2` in `test/stream_test.zig`) |
| `ZSTD_createThreadPool`, `ZSTD_freeThreadPool`, `ZSTD_CCtx_refThreadPool`; `pool.c` | `pool.createThreadPool`, `pool.freeThreadPool`, `CCtx.refThreadPool`; `pool.ThreadPool` | ported (unit tests in `pool.zig`; oracle-tested as a context's shared pool) |

## Decompression: frames

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_decompress` | `decompress(gpa, ...)` | oracle-tested (a context from the allocator, as the original's default heap mode) |
| `ZSTD_decompressDCtx` | `DCtx.decompressDCtx` | oracle-tested (`frames: ...`, every test in `test/decompress_test.zig`; whole output compared, every result code) |
| several frames, skippable frames between them, garbage after a frame | in `decompressMultiFrame` | oracle-tested (`frames: one, several, empty, and skippable frames between them`) |
| `ZSTD_f_zstd1_magicless` (`ZSTD_d_format`, `ZSTD_DCtx_setFormat`) | `.format`, `DCtx.setFormat` | oracle-tested (`frames: the magicless format`) |
| frame header: descriptor, window descriptor with its mantissa, dictionary id of 1, 2 and 4 bytes, content size of 1, 2, 4 and 8 bytes, single segment, reserved bit | `getFrameHeaderAdvanced` | oracle-tested (`frame header: ...`, three tests: every descriptor byte with nine window bytes at every length in both formats, fuzzed bytes, and real frames of each field size) |
| `ZSTD_getFrameHeader`, `_advanced`, `ZSTD_frameHeaderSize` | `getFrameHeader`, `getFrameHeaderAdvanced`, `frameHeaderSize` | oracle-tested (every field of the struct) |
| `ZSTD_getFrameContentSize`, `ZSTD_getDecompressedSize`, `ZSTD_findDecompressedSize`, `ZSTD_findFrameCompressedSize`, `ZSTD_decompressBound`, `ZSTD_decompressionMargin` | same names | oracle-tested (on every header the header tests make) |
| `ZSTD_DECOMPRESSION_MARGIN` | `decompressionMarginBound` | oracle-tested (`in place: ...`, decoding a frame over itself at the end of its buffer) |
| `ZSTD_isFrame`, `ZSTD_isSkippableFrame`, `ZSTD_readSkippableFrame` | same names | oracle-tested (every magic variant and truncation) |
| `ZSTD_getDictID_fromFrame`, `ZSTD_getDictID_fromDict`, `ZSTD_getDictID_fromDDict` | `getDictIdFromFrame`, `getDictIdFromDict`, `getDictIdFromDDict` | oracle-tested |
| raw, RLE and compressed blocks, the last-block flag, blocks of exactly 128 KiB | in `decompressFrame`, `decompress_block.zig` | oracle-tested (`blocks: ...`, which counts each kind in the frames) |
| checksum (XXH64): verified, wrong, cut off; `ZSTD_d_forceIgnoreChecksum` | `std.hash.XxHash64`, `.force_ignore_checksum` | oracle-tested (`checksum: ...`, every bit flip of the 4 bytes, one shot and streamed) |
| one frame into a buffer of its size, no allocation, checksum always verified | `DCtx.decompressFrameExact`, `DCtx.init` | port only: tested against the input and the original's output (`decompressFrameExact: ...`) |

## Decompression: entropy and sequences

| original | zig-zstd | state |
| --- | --- | --- |
| literals: raw, RLE, Huffman with 1 or 4 streams, Huffman with the previous table (treeless) | `decodeLiteralsBlock` | oracle-tested (`literals: ...`, which counts each kind, 1 and 4 streams, X1 and X2, sections over 64 KiB) |
| the literal buffer in the output, in the context, or split between them | `allocateLiteralsBuffer`, `decompressSequencesSplitLitBuffer` | oracle-tested (exact-size outputs, outputs with room, streaming, sections over 64 KiB) |
| `HUF_readDTableX1_wksp`, `HUF_readDTableX2_wksp` | `readDTableX1Wksp`, `readDTableX2Wksp` | oracle-tested (`Huffman decoders: ...`, every table entry compared) |
| `HUF_decompress1X_DCtx_wksp`, `HUF_decompress1X1_DCtx_wksp`, `HUF_decompress1X2_DCtx_wksp`, `HUF_decompress4X_hufOnly_wksp`, `HUF_decompress1X_usingDTable`, `HUF_decompress4X_usingDTable`, `HUF_selectDecoder` | same names, in `huf_decompress.zig` | oracle-tested (real blocks' sections, intact and corrupted, fast loops on and off) |
| the fast 4-stream loops (`HUF_decompress4X{1,2}_usingDTable_internal_fast_c_loop`) | `decompress4X1FastLoop`, `decompress4X2FastLoop` | oracle-tested; the original's x86-64 assembly version of them is not ported (below) |
| sequence tables: predefined, RLE, FSE, repeat, for each field (`ZSTD_buildSeqTable`, `ZSTD_buildFSETable`, `ZSTD_decodeSeqHeaders`) | same names | oracle-tested (`sequences: predefined, RLE, FSE and repeated tables for each field`, which counts each mode of each field) |
| repeat offsets, after literals and after none | `decodeSequence` | oracle-tested (`sequences: repeat offsets, ...`, frames from sequences that use each repeat code) |
| long offsets and the prefetching sequence decoder (`ZSTD_decompressSequencesLong`) | `decompressSequencesLong` | oracle-tested (`sequences: long offsets past 16 MiB, ...`; and with every cold dictionary) |
| `ZSTD_decompressBlock`, `ZSTD_insertBlock` | `DCtx.decompressBlock`, `DCtx.insertBlock` | oracle-tested (`buffer-less: decompressBlock and insertBlock`) |

## Decompression: dictionaries

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_decompress_usingDict` (raw content, full dictionaries) | `DCtx.decompressUsingDict` | oracle-tested (trained, raw, upstream's golden and zero-weight dictionaries, levels 1, 5, 19) |
| `ZSTD_createDDict`, `_byReference`, `_advanced`, `ZSTD_freeDDict`, `ZSTD_initStaticDDict` | `DDict.create`, `createByReference`, `createAdvanced`, `destroy`, `initStatic` | oracle-tested |
| `ZSTD_decompress_usingDDict`, `ZSTD_DCtx_refDDict` | `DCtx.decompressUsingDDict`, `DCtx.refDDict` | oracle-tested |
| `ZSTD_DCtx_loadDictionary`, `_byReference`, `_advanced` (each content type) | `DCtx.loadDictionary*` | oracle-tested |
| `ZSTD_DCtx_refPrefix`, `_advanced` (one frame only) | `DCtx.refPrefix*` | oracle-tested |
| `ZSTD_d_refMultipleDDicts` (each frame picks its dictionary by id, a hash set) | `.ref_multiple_ddicts` | oracle-tested (`dictionaries: several DDicts, ...`, past the set's first size) |
| corrupted and truncated dictionaries | `loadDEntropy` | oracle-tested (`dictionaries: corrupted and truncated dictionaries`, fuzzed) |

## Decompression: contexts, parameters, streaming

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_createDCtx`, `ZSTD_freeDCtx`, `ZSTD_createDCtx_advanced` | `DCtx.create(gpa)`, `DCtx.destroy` | oracle-tested |
| `ZSTD_initStaticDCtx`, `ZSTD_initStaticDStream` | `DCtx.initStatic` | oracle-tested (workspaces of the estimated size and one byte less, streaming) |
| `ZSTD_copyDCtx` | `DCtx.copy` | oracle-tested (mid-frame, in the buffer-less test) |
| `ZSTD_sizeof_DCtx`, `ZSTD_sizeof_DStream`, `ZSTD_sizeof_DDict`, `ZSTD_estimateDCtxSize`, `ZSTD_estimateDDictSize`, `ZSTD_estimateDStreamSize`, `_fromFrame`, `ZSTD_decodingBufferSize_min` | same names | oracle-tested (the original's sizes, from its object layouts) |
| `ZSTD_DCtx_setParameter`, `ZSTD_DCtx_getParameter`, `ZSTD_dParam_getBounds`: `windowLogMax`, `format`, `stableOutBuffer`, `forceIgnoreChecksum`, `refMultipleDDicts`, `disableHuffmanAssembly`, `maxBlockSize` | `DCtx.setParameter`, `getParameter`, `dParamGetBounds` | oracle-tested (every value from 2 below to 2 above each bound, and the extremes) |
| `ZSTD_DCtx_setMaxWindowSize`, `ZSTD_DCtx_reset` (each directive, mid-frame) | same names | oracle-tested |
| buffer-less: `ZSTD_decompressBegin`, `_usingDict`, `_usingDDict`, `ZSTD_decompressContinue`, `ZSTD_nextSrcSizeToDecompress`, `ZSTD_nextInputType` | same names | oracle-tested (into one buffer and into two pieces, the first the previous segment) |
| `ZSTD_decompressStream`, `ZSTD_decompressStream_simpleArgs` | `DCtx.decompressStream*` | oracle-tested (`streaming: ...`: every call's result, input and output positions; random sizes from 0 bytes up; several frames; the ring buffer wrapping) |
| a bounded window: `ZSTD_d_windowLogMax`, frames that ask for more | `.window_log_max` | oracle-tested (`streaming: windows past the largest the stream accepts, and static streams`) |
| `ZSTD_d_stableOutBuffer` | `.stable_out_buffer` | oracle-tested (a stable output, one too small, and one that moves) |
| `ZSTD_createDStream`, `ZSTD_freeDStream`, `ZSTD_initDStream`, `_usingDict`, `_usingDDict`, `ZSTD_resetDStream`, `ZSTD_DStreamInSize`, `ZSTD_DStreamOutSize` | `DStream` (= `DCtx`), `initDStream*`, `resetDStream`, `dStreamInSize`, `dStreamOutSize` | oracle-tested |
| corrupt and truncated input | every function | oracle-tested (`fuzz: corrupted and truncated frames, ...`, `fuzz: random bytes ...`, `golden frames: ...`: the same error code as the original, or the same bytes) |

## Build switches

| original | zig-zstd | state |
| --- | --- | --- |
| `ZSTD_MULTITHREAD` | `-Dmultithread` (`build_options.multithread`) | ported (off: one shared pool runs jobs inline, and no multithreaded context is made) |
| `ZSTD_NO_INTRINSICS`, `ZSTD_ARCH_X86_SSE2`, `ZSTD_ARCH_X86_AVX2`, `ZSTD_ARCH_ARM_NEON` | `-Dintrinsics`, the target's CPU features | oracle-tested (the `oracle` build against the reference with SIMD, `oracle-scalar` with intrinsics off on both sides; NEON only by a unit test on x86) |
| `ZSTD_CLEVEL_DEFAULT` | `params.clevel_default` | oracle-tested (level 0 and the default level against `ZSTD_getCParams`) |
| `ZSTDMT_NBWORKERS_MAX`, `ZSTDMT_JOBSIZE_MIN`, `ZSTDMT_JOBSIZE_MAX` | `nbworkers_max`, `jobsize_min`, `jobsize_max` in `zstdmt.zig` | ported (the original's values; the parameter bounds in `compress.zig` use them) |
| `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY` | a build option for the tests | oracle-tested with `-Doverflow-correct-frequently`, which builds both sides with it (`build_options.overflow_correct_frequently`; off in every other build) |

## Left out, approved by the author

| original | reason |
| --- | --- |
| `ZDICT_*`: dictionary training (`zdict.c`, `cover.c`, `fastcover.c`, `divsufsort.c`) | the brief leaves it to the author; the tests use the original's trainer to make dictionaries |
| the legacy formats (`ZSTD_LEGACY_SUPPORT`, `lib/legacy/`) | frames of zstd before 0.8, which the original's library build leaves out too. Approved on 11 November with the rest of decompression; decompression is now ported (22 November), the legacy formats are not |
| `ZSTD_customMem` as a struct of callbacks | a `std.mem.Allocator` takes its place |
| `DYNAMIC_BMI2`, `STATIC_BMI2` | run-time CPU dispatch; the port compiles for the target's CPU features, and the output does not depend on BMI2 |
| `ZSTD_EXCLUDE_{DFAST,GREEDY,LAZY,LAZY2,BTLAZY2,BTOPT,BTULTRA}_BLOCK_COMPRESSOR` | binary size only; every strategy is compiled |
| `ZSTD_COMPRESS_HEAPMODE` | stack or heap for `ZSTD_compress`'s context; the port always takes the caller's allocator |
| `ZSTD_TRACE`, `ZSTD_HAVE_WEAK_SYMBOLS` | tracing hooks through weak symbols |
| `DEBUGLEVEL`, `DEBUGLOG`, `ZSTD_ADDRESS_SANITIZER`, `ZSTD_MEMORY_SANITIZER`, `ZSTD_DATAFLOW_SANITIZER` | debug output and sanitizer annotations; Zig's safe modes check instead |
| `ZSTD_STRIP_ERROR_STRINGS`, `ZSTD_LIB_MINIFY`, `ZSTD_LINUX_KERNEL`, `ZSTD_DEPS_*`, `XXH_*` | C build configuration |
| `ZSTD_C_PREDICT` | an experimental, disabled path in `zstd_opt.c` |
| `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` | changes the superblock's checks and the overflow correction for fuzzers; the second is the build option above |
| `ZSTD_RESIZE_SEQPOOL` | fixed to 0 in the original |
| `huf_decompress_amd64.S`, `ZSTD_DISABLE_ASM` | approved 22 November, a deliberate difference (`doc/parity.md`): the port translates the C fast loops the original takes without its assembly; on the benchmark machine they are faster than the assembly. `ZSTD_d_disableHuffmanAssembly` is set and read, and changes nothing |
| `HUF_FORCE_DECOMPRESS_X1`, `HUF_FORCE_DECOMPRESS_X2`, `ZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT`, `ZSTD_FORCE_DECOMPRESS_SEQUENCES_LONG`, `HUF_DISABLE_FAST_DECODE`, `ZSTD_NO_INLINE` | approved 22 November (`doc/parity.md`): binary size: they build one decoder of each kind; every decoder is compiled. The Huffman fast loops can be turned off per call (`Flags.disable_fast`) |
| `ZSTD_HEAPMODE`, `ZSTD_MAXWINDOWSIZE_DEFAULT`, `ZSTD_NO_FORWARD_PROGRESS_MAX`, `ZSTD_DECODER_INTERNAL_BUFFER` | approved 22 November (`doc/parity.md`): build-time sizes, kept at their defaults: the port always takes an allocator, and `window_log_max` sets the window limit |
| `DYNAMIC_BMI2` on the decoder | as for the compressor: built for the target's CPU features |
