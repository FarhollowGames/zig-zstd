# Benchmark textures

Texture inputs for the decompression benchmark: real photographs encoded as
Loomwork bakes textures. They are not committed; this folder holds the
generator, and the steps below rebuild the files byte for byte.

Per photo, two files of raw blocks, 16 bytes per 4x4 block, blocks in
row-major order, no header:

- `<name>.bc7`: the photo, BC7.
- `<name>.bc5`: a tangent-space normal map made from the photo, BC5 (X in
  the red channel, Y in the green).

Each file is (width / 4) x (height / 4) x 16 bytes. The seven photos give
4,024,512 bytes of BC7 and 4,024,512 bytes of BC5.

## Files here

- `extract.py`: decodes the photos from the scikit-image wheel to raw RGBA8
  (`<name>.rgba`) and writes `photos.txt`, one line `<name> <width>
  <height>` per photo. It checks the wheel's sha256 first.
- `build.zig`, `build.zig.zon`, `gen.zig`: a small Zig package, with
  zig-bcn as its one dependency. `gen-textures <photo dir> <output dir>`
  reads `photos.txt` and the `.rgba` files and writes the `.bc7` and `.bc5`
  files. It is always built ReleaseFast.

## Photos

From the scikit-image 0.26.0 wheel
`scikit_image-0.26.0-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl`,
sha256 `b36ab5e778bf50af5ff386c3ac508027dc3aaeccf2161bdf96bde6848f44d21b`,
from PyPI. The photos are in `skimage/data/`; the licences are as
scikit-image's docstrings in `skimage/data/_fetchers.py` give them.

| name | file | original size | used size | licence |
| --- | --- | ---: | ---: | --- |
| astronaut | astronaut.png | 512 x 512 | 512 x 512 | NASA; no known copyright restrictions, public domain |
| chelsea | chelsea.png | 451 x 300 | 448 x 300 | CC0, Stefan van der Walt |
| coffee | coffee.png | 600 x 400 | 600 x 400 | CC0, Rachel Michetti (Pikolo Espresso Bar) |
| rocket | rocket.jpg | 640 x 427 | 640 x 424 | SpaceX; released into the public domain |
| hubble_deep_field | hubble_deep_field.jpg | 1000 x 872 | 1000 x 872 | NASA; may be freely used in the public domain |
| retina | retina.jpg | 1411 x 1411 | 1408 x 1408 | CC0 1.0, Mikael Häggström (Wikimedia Commons) |
| ihc | ihc.png | 512 x 512 | 512 x 512 | CMMI; no known copyright restrictions |

- Sizes are width x height. Sides that are not multiples of 4 are cropped
  down to one, dropping the right columns and bottom rows. Nothing is
  resampled.
- All seven are RGB; alpha is set to 255.
- Left out: `motorcycle_left.png` (Middlebury 2014 stereo set), which has no
  licence statement in scikit-image; the rest of `skimage/data` is grey,
  synthetic, or not a photo.
- The JPEGs are decoded by Pillow 12.3.0 (libjpeg-turbo 3.1.4.1). Another
  JPEG decoder may give slightly different pixels, so the RGBA files' hashes
  are listed below.

## Encoding

- Encoder: zig-bcn, commit 73673bf162834090bbec7dcbdf806ede75362871
  (v0.3.2), Zig 0.17.0, ReleaseFast.
- BC7: `bcn.bc7.Params.init(.basic, true)`: level basic, perceptual error,
  as test/data/bc7.bin used. zig-bcn's documentation does not say which
  settings Loomwork's bake uses.
- BC5: `.bc5` (stb_dxt; it has no settings), on a 2-channel image.
- Both through `bcn.encodeImageParallel`, 4 block rows per task. zig-bcn
  encodes every block on its own, so the bytes do not depend on the thread
  count; a run on one core gives the same files.

## Normal maps

Made in `gen.zig` (`normalMap`) from the cropped RGBA:

- Height: luminance `54 R + 183 G + 19 B` (Rec. 709 weights in 256ths), an
  integer from 0 to 65280 that stands for 0 to 1.
- Slopes: 3x3 Sobel filters in integers, edge pixels repeated; each sum is
  divided by 8 to give a slope per pixel.
- Normal: `(-s dh/dx, +s dh/dy, 1)`, normalised, with strength `s = 4` and y
  counted down the image, so +Y points up the image (the OpenGL
  convention). Computed in f64, in a fixed order.
- Bytes: `floor((n * 0.5 + 0.5) * 255 + 0.5)` for x and y, 0 to 255.

## Regenerating

Download the wheel into an empty folder of its own:

```sh
mkdir -p /tmp/skimage-wheel && cd /tmp/skimage-wheel
pip download scikit-image==0.26.0 --no-deps --only-binary=:all: \
    --platform manylinux_2_28_x86_64 --python-version 3.13 --implementation cp -d .
sha256sum scikit_image-0.26.0-*.whl
```

From this folder (`bench/textures`), with the output folder `$OUT`:

```sh
python3 -I extract.py /tmp/skimage-wheel/scikit_image-0.26.0-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl "$OUT"
zig build
./zig-out/bin/gen-textures "$OUT" "$OUT"
```

`zig build` fetches zig-bcn by the URL and hash in `build.zig.zon`. If
`zig fetch` cannot reach GitHub (it failed through this machine's proxy,
while `git` worked), put the package in Zig's cache from a clone; the hash
is the same:

```sh
git clone https://github.com/farhollowgames/zig-bcn && git -C zig-bcn checkout 73673bf162834090bbec7dcbdf806ede75362871
zig fetch ./zig-bcn   # prints bcn-0.3.2-046PjbQtBQCOoMpkNXzvgLBLlZjvslPm9ASiUhstp59F
```

## Hashes

sha256 of the files from the steps above:

```
0df3c62c654dd5432e753a8d273e73ad3fb7d5826848b395afaead620b89bdd0  astronaut.rgba
159b15aec9186e4611b55eceee2433251d0e21c54b8509ee2615c4c2408fd856  chelsea.rgba
2c9022e5a85bd6baa1679a11f91fa94fd1d69ba879414f5da7c55066ea3b28fc  coffee.rgba
11278c5b02a573d18d5953c7ea6d7476430f88bb0f819d10f4bebf9de38a8d7b  rocket.rgba
9606312b1a6e41248fb18e2636c4d18f899d3cf331daf66bf89d562b576609e2  hubble_deep_field.rgba
5f72350027b762b166dc83ae2f2f67db599ae8a42e877b8274bed54474d40206  retina.rgba
a30338579805f5b0ce6b260e27f5e41ddd206fa643f71d216a72b2ca64a78528  ihc.rgba
96d195c51c3e629f71ef2cc971ff6f83a19afaf6dada9fd637411165c38e3bf7  astronaut.bc7
fb590b19eecaaff72edc6a2ab1bca3e81e83e3a01b672d1ac96722fabf9c38d6  chelsea.bc7
58dc0d590bcaba4e7f33a39cb6fa22cd7946c0aba46d3c1e16a306cbdc0caef6  coffee.bc7
e302de823d9ddb2c237bcda759bd43dcb579c7b5d5f3532c041916330259a8ce  rocket.bc7
d380173d2015a2f825253652af79371a1c758d03270366d528b40526d458e89d  hubble_deep_field.bc7
6e5f2f2b52f371143cae3c2b1a2bb17a40d7093e6ccc884a7c702a4e512f9b97  retina.bc7
107ada9726279c49518e385e5068b1aeb114cffc55ac660a4e366481905d19b7  ihc.bc7
8cc5b810dc6316b37f923d2ef7c342e70be8d0a4056f3d915ba60cf0e00aa011  astronaut.bc5
8a3ece0876b5063ad9ae367265888d141903eb43de2c795f1aebbea5c92919fa  chelsea.bc5
b98550663bf8832e97405360727dcc8b8d756b208b7c4fdffc355411355078e0  coffee.bc5
f1345c4fb9d19a15838ac58ad0763e80d5232f8d062495d70e8273de8280ac1c  rocket.bc5
14869bc8c1cfef64837fff7a2b7372fdd5552910f40dded9306eec19342fedef  hubble_deep_field.bc5
49b0e125329d7bdce1cb7bf0631de924720f32543f85e30ee83dc4f85f87beff  retina.bc5
105a7b23ae7706029329c1402aff3e5c46884789a5ac7351a9ced010339bf710  ihc.bc5
```

Decoded with zig-bcn, the BC7 files are 39.8 to 51.8 dB PSNR (RGB) against
the RGBA files.
