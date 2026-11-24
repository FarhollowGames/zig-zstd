# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.


## In this repository

### The original

zstd 1.5.7, tag `v1.5.7`, commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`,
is copied into `reference/` unchanged (see `reference/README.md`): the whole
`lib/` directory, upstream's licences, its test inputs
(`tests/golden-compression`, `tests/golden-dictionaries`, `tests/dict-files`)
and its generator of compressible data (`programs/datagen.c`). The tests and
the benchmark build it with Zig's C compiler; a package that depends on
zig-zstd never builds or fetches it.

### What is compared

- Every frame the port makes is compared with the original's, byte for
  byte, and decoded back to its input through std's decoder
  (`std.compress.zstd`) and the original's.
- Below the frame, the block compressors of every strategy run on one block
  after the same setup on both sides, and every stored sequence, literal,
  repeat offset and table entry is compared, with the match state the next
  block starts from (the optimal parser's statistics and prices, the
  window, and the hash and tree tables).
- The entropy coders (histograms, FSE, Huffman, the bit stream writer, the
  table header readers) are compared output byte by output byte, table entry
  by table entry, with every returned value and error code.
- Streaming is driven call by call on both sides with the same input
  chunks, output windows and directives; after every call the results, the
  input and output positions and the frame progression must be the same.
- Long distance matching compares the raw sequences, the whole hash table,
  the bucket offsets and the window after every step.
- Parameters: their bounds, setting and reading them, contexts reused and
  reset, and the size estimates, which static contexts are then built with.
- The decompressor decodes the same input on both sides and compares every
  result code and every decoded byte: one shot into exact and larger
  outputs; streamed call by call with the same input pieces and output
  windows, each call's result and both positions compared; buffer-less,
  each `nextSrcSizeToDecompress` and `nextInputType` compared; and through
  the Huffman decoders on their own, every table entry compared. The inputs
  are the original's frames (its compressor's output, which the port's
  compressor matches byte for byte, and its golden files), and corrupt,
  truncated and random bytes. Each feature's test counts, from the frames'
  headers, that the feature it names is there: block types, literal
  section types, 1 and 4 Huffman streams and which Huffman decoder the
  original picks, each table mode of each sequence field, dictionary ids,
  single-segment frames.

The compressor's frames also round-trip through std's decoder. Two limits of
std's decoder (Zig 0.17.0) shape those round trips:
- it panics when asked to verify a checksum, so the tests decode through std
  without checksum verification and through the original with it;
- it takes no dictionaries, so frames made with a dictionary or a prefix
  decode through the original only.

### Tests and counts

`zig build test` runs 447 tests: 63 unit tests in `src/`, and 192 oracle
tests run twice, as `oracle` (the port's `@Vector` paths against the
original's SIMD paths) and as `oracle-scalar` (both sides on their scalar
paths). `-Dcorpus=false` skips the corpus tests, and `-Doracle-scalar=false`
the second run.

| file | what it covers |
| --- | --- |
| `test/entropy_test.zig` | histograms, FSE, Huffman, the bit stream, the table readers |
| `test/literals_sequences_test.zig` | the literals section and each step of the sequences section, on real blocks |
| `test/core_test.zig` | the parameter table, and the fast and double-fast block compressors |
| `test/lazy_test.zig` | greedy, lazy and lazy2 over the hash chain and the row matcher, and btlazy2, with and without dictionaries |
| `test/opt_test.zig` | btopt, btultra and btultra2 over one or more blocks |
| `test/ldm_test.zig` | long distance matching |
| `test/frame_test.zig` | one-shot and buffer-less frames, and choosing and checking parameters |
| `test/frame_params_test.zig` | every advanced parameter, reused and reset contexts, static contexts |
| `test/frame_dict_test.zig` | dictionaries, prefixes and `CDict`s, attached, copied or reloaded |
| `test/frame_sequences_test.zig` | `generateSequences`, `mergeBlockDelimiters`, external sequence producers |
| `test/compress_sequences_test.zig` | `compressSequences` and `compressSequencesAndLiterals` |
| `test/stream_test.zig` | `compressStream2` and the streaming functions around it |
| `test/mt_test.zig` | multithreaded compression |
| `test/corpus_test.zig` | the corpora below |
| `test/decompress_test.zig` | the decompressor: frames, the frame header, blocks, literals, sequences, repeat and long offsets, checksums, dictionaries, upstream's golden frames, the Canterbury corpus, in-place decoding, `decompressFrameExact` |
| `test/decompress_skeptic_test.zig`, `test/decompress_loomwork_test.zig` | the decompressor's two reviews: a test per finding, and their probes that held up |
| `test/review_test.zig` | the compressor review's: allocation failures through every entry point that allocates, random and out-of-range caller sequences, contexts on several threads sharing a pool |
| `test/dstream_test.zig` | the decompressor: streaming, the buffer-less API, parameters, sizes and static objects, the Huffman decoders, and its fuzzers |

### Inputs

- Upstream's test files and the data its generator makes.
- The Canterbury corpus (its canterbury, artificial and large sets) at
  levels -5 and -1 and every positive level; the first 4 MiB of every
  Silesia file at -5 and every positive level, and each whole Silesia file
  at levels 1, 3 and 19, one-shot and streamed. Both corpora are lazy
  dependencies, fetched only for the tests and the benchmark.
- `test/data/`: a BC7 texture from zig-bcn, encoded mesh streams from
  zig-meshoptimizer and a Loomwork snapshot pack, each at every level
  (`test/data/README.md` says how each was made).
- Hand-made edge cases, among them one-byte output windows and invalid
  sequences, which must fail with the original's errors.
- For the decompressor, upstream's `tests/golden-decompression` (frames it
  must decode) and `tests/golden-decompression-errors` (frames it must
  refuse), and frame headers made by hand: every descriptor byte with
  windows of every mantissa, and 8-byte content sizes.

### Fuzzing

Each fuzz test runs `-Dfuzz-cases` cases, 1,000 by default.
`-Dfuzz-seed=N` is added to every fuzz test's first seed. Fuzzed inputs
cover the entropy coders' inputs, the block compressors, parameter sets,
streaming calls, long distance matching and caller sequences.

The decompressor's fuzzers decode frames of random inputs and random
compression parameters (level, window, checksum, content size, literal
compression, target and largest block sizes, long distance matching) one
shot into outputs of random sizes, streamed in random pieces (with a stable
output in one case of 4) and through `decompressFrameExact`; corrupt frames
from 1 to 4 random changes (flipped bits, bytes set, removed or inserted, a
cut, mostly in the first 64 bytes where the headers and tables are), one
shot and streamed; random bytes behind a valid frame and block header; and
corrupt Huffman sections and dictionaries. Every result must be the
original's.

The parameter fuzzer (`compress2: fuzzed parameter sets ...`) sets up to 8
parameters per case on a fresh context of each side, made one side after
the other: window logs up to 27, hash and chain logs up to 26, long distance
hash logs up to 27 and every hash rate. Inputs reach 3 MiB in one case of
32 and 400 KB in one of 8. One case in 4 adds a dictionary, by copy, by
reference, as a prefix or as a `CDict` of a random level, of up to 110 KB,
or in one dictionary case of 4 up to 20 MiB, past the 16 MiB a `CDict` with
tagged indexes loads whole. A context kept across cases takes the same
values lowered to window log 25, hash and chain logs 24, long distance hash
log 22 and rate 9, so that its tables stay small.

### Malformed input

The compressor reads no encoded input except the caller's dictionaries and
sequences. Invalid sequences must give the original's errors. Malformed
sequences and dictionaries that break the original's own asserts panic in
a safe build, as [`parity.md`](parity.md) says; the tests stay clear of the
two cases where the original then reads out of bounds.

The decompressor reads untrusted frames and dictionaries: on corrupt,
truncated and random input it must give the original's error code, or the
original's bytes where the original decodes it, and never panic in a safe
build. The tests of corrupt input turn the original's x86-64 assembly
Huffman loops off, which stop at other places than its C loops on corrupt
streams; on valid frames both run.

### Allocation failures

`test/review_test.zig` runs each entry point that allocates (one-shot and
reused contexts, dictionaries and `CDict`s, streaming with and without long
distance matching, workers and a shared pool, `generateSequences`, and the
decoder's one-shot, context, `DDict`, loaded-dictionary and streaming paths)
with each allocation failing in turn, then with every allocation from each
one on failing. The port must refuse with `error.MemoryAllocation`, free
everything it took, and give the original's frame or bytes from the same
objects once memory is back. The allocator is safe to share between the
workers' threads.

### Determinism

The multithreaded tests drive the port and the original with 1, 2, 3, 4
and 8 workers. Every frame must be the original's on every run, whatever the
threads' timing, and so must the sizes after the start of a frame, the
frame progression whenever no job is in progress, and the errors. The size
is not compared after an abandoned frame: its jobs leave the pools at sizes
that depend on the timing, in two runs of the original 9,167,360 and
7,337,440 bytes.

### Build modes

The compressor review's runs (24 November, a 4-core cloud VM, with
`-Dsilesia=false`): the whole suite in ReleaseSafe in 42 minutes, 439 of
447 passing and 8 skipped (the 3 Silesia corpus tests and the 32-bit-only
test, in each oracle binary), and in ReleaseFast (`-Dtest-optimize=ReleaseFast`)
in 39 minutes with the same counts, after the fix to the Huffman tests'
workspaces (`STATUS.md`). It was the first whole run in ReleaseFast.

The decompressor's last runs (23 November, a 4-core cloud VM, with
`-Dsilesia=false`, as Silesia's host cannot be reached from it): the whole
suite in ReleaseSafe in 33 minutes, 415 of 423 passing and 8 skipped (the
3 Silesia corpus tests and the 32-bit-only test, in each oracle binary); the
decompressor's tests as a 32-bit x86 process (`-Dtarget=x86-linux-musl`)
and in Debug at 100 fuzz cases, all passing.

The compressor's recorded run is the default, ReleaseSafe: 310 of 312 pass, and the 2
skipped are a 32-bit-only test, in each oracle binary. Four more runs check
what the default run does not reach (the second and third were last made
with 306 tests, before the 32-bit fixes):

- `-Dtarget=x86-linux-musl` runs the suite as a 32-bit x86 process, natively
  on x86-64. With `-Dcorpus=false`, 58 of 58 unit tests pass, and in each
  oracle binary 123 of 127 pass and 4 are skipped (the 3 corpus tests, and
  the 2 GiB prefix, which is 64-bit only), in about 34 minutes. On 32-bit the tests that hold several contexts
  of levels 20 to 22 at once skip those levels (`common.levelFits`): a long
  run fragments the address space past where they fit.

- `-Doverflow-correct-frequently` builds both sides with upstream's
  `ZSTD_WINDOW_OVERFLOW_CORRECT_FREQUENTLY`, so the window's index correction
  runs on small inputs. With `-Dcorpus=false -Dfuzz-cases=150`, 300 of 306
  pass and the 6 corpus runs are skipped, in 14 minutes.
- `-Dskeptic` adds the skeptics' probes: parameter combinations, LDM hash logs
  25 to 27, pledged sizes near 2^64, size hints near 2^31, large CDicts, and a
  3.5 GiB input through the real index correction. With `-Dcorpus=false`, 252
  of 258 oracle runs pass and the 6 corpus runs are skipped, in 17 minutes, at
  a peak of 6 GB.
- `-Dmultithread=false` builds the port without workers and the original
  without `ZSTD_MULTITHREAD`. With `-Dcorpus=true -Dsilesia=false
  -Doracle-scalar=false` (24 November): 167 of 178 pass, 11 skipped (the
  worker tests, the Silesia tests and the 32-bit-only test), in 37 minutes.
- `-Dtest-optimize=Debug` on the block-level tests (50 of 50) and the frame
  tests (54 of 55; the CDict test was stopped after 18 minutes) found no
  panic that ReleaseSafe misses.

### State

The oracle tests pass, on x86-64 and as a 32-bit x86 process. The skeptics'
review and its fixes are done, and so is the performance pass;
[`STATUS.md`](../STATUS.md) has the details.
