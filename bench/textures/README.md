# Benchmark textures

Texture inputs for the decompression benchmark: real photographs encoded as
Loomwork bakes textures. They are not committed; this folder holds the
generator, and the steps below rebuild the files byte for byte.

Every output file is raw blocks, 16 bytes per 4x4 block, blocks in
row-major order, no header. BC5 files hold a tangent-space normal map, X in
the red channel and Y in the green. There are two sets.

Per photo (`gen-textures`):

- `<name>.bc7`: the photo, BC7.
- `<name>.bc5`: a normal map made from the photo, BC5.

Each file is (width / 4) x (height / 4) x 16 bytes. The seven photos give
4,024,512 bytes of BC7 and 4,024,512 bytes of BC5.

Mip chains of four 2048 x 2048 mosaics of the photos (`gen-textures
--atlas`), for k = 0 to 3 and level L = 0 to 9 (2048 x 2048 down to 4 x 4):

- `tex<k>.mip<L>.bc7`: level L of mosaic k, BC7.
- `tex<k>.mip<L>.bc5`: level L of mosaic k's normal map, BC5.

Level L is (2048 >> L) / 4 squared blocks: 4,194,304 bytes at level 0,
then 1,048,576, 262,144, 65,536, 16,384, 4,096, 1,024, 256, 64 and 16. A
whole chain is 5,592,400 bytes: the size of one Loomwork frame for a 2K
texture, where streaming makes each level a frame of its own. The 80 files
total 44,739,200 bytes.

## Files here

- `extract.py`: decodes the photos from the scikit-image wheel to raw RGBA8
  (`<name>.rgba`) and writes `photos.txt`, one line `<name> <width>
  <height>` per photo. It checks the wheel's sha256 first.
- `build.zig`, `build.zig.zon`, `gen.zig`: a small Zig package, with
  zig-bcn as its one dependency. `gen-textures [--atlas] <photo dir>
  <output dir>` reads `photos.txt` and the `.rgba` files and writes the
  per-photo files, or with `--atlas` the mosaics' mip chains. It is always
  built ReleaseFast.

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
  as test/data/bc7.bin used, and as Loomwork's bake uses (confirmed by
  its author).
- BC5: `.bc5` (stb_dxt; it has no settings), on a 2-channel image.
- The mosaics use the same two encoders and settings at every mip level.
- All through `bcn.encodeImageParallel`, 4 block rows per task. zig-bcn
  encodes every block on its own, so the bytes do not depend on the thread
  count; a run on one core gives the same files.

## Normal maps

Made in `gen.zig` (`normalVectors`) from the cropped photo, or from a
mosaic's level 0:

- Height: luminance `54 R + 183 G + 19 B` (Rec. 709 weights in 256ths), an
  integer from 0 to 65280 that stands for 0 to 1.
- Slopes: 3x3 Sobel filters in integers, edge pixels repeated; each sum is
  divided by 8 to give a slope per pixel.
- Normal: `(-s dh/dx, +s dh/dy, 1)`, normalised, with strength `s = 4` and y
  counted down the image, so +Y points up the image (the OpenGL
  convention). Computed in f64, in a fixed order.
- Bytes: `floor((n * 0.5 + 0.5) * 255 + 0.5)` for x and y, 0 to 255.

## Mosaics

Each mosaic is 2048 x 2048 pixels of the photos as they are: no scaling,
only crops and, where the photos run out, left-right mirroring. Made in
`gen.zig` (`buildMosaic`):

- Each photo is cut into strips 128 rows high from its top; rows below the
  last whole strip are left out (chelsea loses 44, coffee 16, rocket 40,
  hubble_deep_field 104). In the mosaic's photo order, the strips are laid
  end to end, photo by photo and top strip first, into one ribbon 128 rows
  high and 30,200 pixels long.
- The mosaic is 16 bands of 128 rows. Band b, column x is ribbon column
  `start + 2048 b + x`: the bands are filled from the ribbon left to right
  and top to bottom, and a strip cut by the right edge goes on at the left
  of the next band.
- The ribbon is shorter than the 32,768 columns a mosaic needs, so it
  repeats. On every second pass along it, each strip is mirrored left to
  right, so no part of a mosaic is a copy of another.
- Photo widths, strip heights and starts are multiples of 4.

| mosaic | photo order | start |
| --- | --- | ---: |
| tex0 | astronaut, chelsea, coffee, rocket, hubble_deep_field, retina, ihc | 0 |
| tex1 | retina, coffee, ihc, hubble_deep_field, chelsea, rocket, astronaut | 7,552 |
| tex2 | hubble_deep_field, astronaut, rocket, retina, ihc, coffee, chelsea | 15,104 |
| tex3 | ihc, rocket, retina, chelsea, astronaut, hubble_deep_field, coffee | 22,656 |

Mip levels:

- Colour: level L + 1 is the 2x2 box average of level L on RGBA8, per
  channel `(a + b + c + d + 2) / 4` in integers. Alpha stays 255.
- Normals: level 0 is the normal map of the level 0 mosaic, above, kept as
  f64 unit vectors (x, y, z). Level L + 1 is the sum of each 2x2 square of
  level L's vectors (top left, top right, bottom left, bottom right, in that
  order), normalised. Each level's vectors become bytes as above. The
  normals are not taken from the colour mips.
- Levels 0 to 9: 2048, 1024, 512, 256, 128, 64, 32, 16, 8 and 4 pixels a
  side.

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
./zig-out/bin/gen-textures --atlas "$OUT" "$OUT2"
```

`$OUT2` gets the mosaics' 80 files. The per-photo run takes about a second
on 4 cores, the mosaics about 8 seconds.

`zig build` fetches zig-bcn by the URL and hash in `build.zig.zon`. If
`zig fetch` cannot reach GitHub (it failed through this machine's proxy,
while `git` worked), put the package in Zig's cache from a clone; the hash
is the same:

```sh
git clone https://github.com/farhollowgames/zig-bcn && git -C zig-bcn checkout 73673bf162834090bbec7dcbdf806ede75362871
zig fetch ./zig-bcn   # prints bcn-0.3.2-046PjbQtBQCOoMpkNXzvgLBLlZjvslPm9ASiUhstp59F
```

## Hashes

sha256 of the per-photo files from the steps above:

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

sha256 of the mosaics' files; size is per file, the same for the `.bc7` and
the `.bc5` of a level:

| level | size | `.bc7` sha256 | `.bc5` sha256 |
| --- | ---: | --- | --- |
| tex0.mip0 | 4,194,304 | `6c5bc5d6bb144ad43b546b0aa079aa799fb09c606b2f1e2ce18eec1a6f021611` | `43da59ff7ed37afa5f62ae1ef4e9f8596e243cccce14279d3cc960ecad811854` |
| tex0.mip1 | 1,048,576 | `6088d16083f4ee88974f78f88782df595c97866f556a83e13f584b6d016e21b8` | `6e52326e97c298909862d44479166238a7f9bf7208b39712dc506240824ec9aa` |
| tex0.mip2 | 262,144 | `744cf04156b5d9a61f7d373323424e6f2b383cc6ca714f4da22cf7b42a264505` | `393dddd894349c2bf3bdf28d88ef0266b925d41806ce437997cb7852e04db9bb` |
| tex0.mip3 | 65,536 | `80ced9c87354759f69d824f64167e35e82fc9c8be2d2fb08e8a96d2364b2d6bc` | `fd7141b29cc12e207278e9493eb0ac923acdf38028e059292a410c877e9c5114` |
| tex0.mip4 | 16,384 | `4d7e278bb786593414bd07ab9f015d5c06bace1a8b6a89711b8bd4968c52f8ff` | `16664dfa4049e4caff867e8a52210cf8924a47728cbee61e04b03085a7c731e8` |
| tex0.mip5 | 4,096 | `f547ea1c53f3480eaff173253f1a0571683051a30557132f82f6bdfc4b0d05b4` | `d499ce4ff1d9ae0610062e7c607d1c10fa429b5733077658ebf85c904e669576` |
| tex0.mip6 | 1,024 | `544c1c1a80123bc8895bd8eeb9a2afb34075816bcce9b920d7e57a8d75c5ae9c` | `9534c35e55b728aa6f1c200a46251258ff3226514c16f2f09e6009a906e2831a` |
| tex0.mip7 | 256 | `a02623d22bcd84447acd81981abbac828643f1ebd339c16269b878a125d4951a` | `66ddbd4c61bd5ba1c20f176a90bd0c6bfc63a4a039cc83517f20db365df72bc3` |
| tex0.mip8 | 64 | `a2b6e5fafd98602490bf1b5fa8e58ff10540195d21db81043190d70218b6c72c` | `8c6e14004536aa88d85e34202ce731a0e6501e746913ed8918abc63c03dd0dda` |
| tex0.mip9 | 16 | `0fcb3047a87c3a51d8906674628b97550519d65f7e392f54806678f5888d63f9` | `0028f93670b62dd5be1332334d6205f1b660be3f10c07ee4f22d2ff4cc3a4eca` |
| tex1.mip0 | 4,194,304 | `2c758e0fde7c37662bce2e31d5589ce1e26f0298c1d663a28dfb06788bdf1b1a` | `b5d609781d0508ea6b7152f63089ef080ac7cb0d89062bca3a8dfd025e88f454` |
| tex1.mip1 | 1,048,576 | `15acefb971b0fb82c5f06cc7dee44ec2fe03d37ed5e85cd73be9b07db8b328b9` | `d91658fe100715691ebc9896476c76d2f52d9ccf45c1f08b21f3b08b56334875` |
| tex1.mip2 | 262,144 | `6a2bf2c8fbaca65ad54329528ae5a9b66211ab2fc2df770e40028f905ed1a544` | `0fb5a74a293d6ddd69ea7a25db0b1aac8df2a08718d0f707391aba11291862ba` |
| tex1.mip3 | 65,536 | `cfbac6541e8d3c6f0f08d44f3b5e2fc8fded598925ea181416d6b723e3a95be6` | `dcba83c2adb32e53fc56f72e6cd245df3d015dfcf8ed8f722218a43a7b1c4897` |
| tex1.mip4 | 16,384 | `5b2bb89a26455883b73680f98d9b01b7d84278f31a9e66219e1558eab36a308f` | `e28c664d393a59359d2654b8619f2e94363186c8fd5c9887dbeb6bdfe45a3df7` |
| tex1.mip5 | 4,096 | `a6dc2ad1617ad5fa3016d01e046a4e98e26fb4f3043ab23e9674e556560b8db6` | `d808b97f8f0aaad5baa12ffad25fd99c6fa31f44a58aafda96231eddcddfa7e8` |
| tex1.mip6 | 1,024 | `db272b6874dd037b06580e19a0734befe05d3c512f915c6925efe15e5566dfcc` | `5c51c493d681a9ec8c3a17d495f0ba6633d2d49fad6d00c6f55c64778a7ab37f` |
| tex1.mip7 | 256 | `f910b2c3d71a5e7cd1baf452297f8d6e95927003a1c6808b7eb08b152f7a589f` | `aa9d0fb7a85483e19d02f3450c4f9d15738c6b661231402fd1f43bb568aed651` |
| tex1.mip8 | 64 | `e9c15508b3998e966ea632846d091a1f68e9696b22ffa473b5adced1948c4a2d` | `97e68695ff777a8ebd256e794f2c94a3e804919e38364d4c35f3dca91783178a` |
| tex1.mip9 | 16 | `c2d7da64c91112e256c08079c9342e4ea67d7a81639d5bee01db6422bb3a8f35` | `3ec1f68d8a017a68839bd44bd69f3acb22754462be6b02d1c5025d82ab2378b9` |
| tex2.mip0 | 4,194,304 | `4d494e71448f7c410f454cd753b19a4e74ae9175196ff966b1024fe2b3bbc084` | `68e0cf808bbed8e3b64d6800c722219009e416485f37e9ee5d45e0635923bcfd` |
| tex2.mip1 | 1,048,576 | `e85fa2a3e166c26a59e3f9c4d0349ad0dfea54d3cc10fb63591285fee7f879e8` | `92e70acadc6e73f3441420d2c9f26d04be49d9f14e15f66644c497d484e17d1d` |
| tex2.mip2 | 262,144 | `a1f547699e2183e6601f1ac96b48c592fb5844fab09fe737ee47825294d7e885` | `94d5038e6bb014f52c774ae20f2edf15afdefe744467b85847c5e11d73af96c3` |
| tex2.mip3 | 65,536 | `8ac77448e2e08867c8a81517baaea3bd27976af46a9cc1168417b8bc4ab790da` | `3eac95e0eaddc865d45bb3c5b0a4d7c25bd16321bbeae2f3b8842cf412bdf49f` |
| tex2.mip4 | 16,384 | `418b960496ce542bdef057bd9e6617c65a4fa33427e6c100afe4b5bb25aabf70` | `21bf186b9f24596b28334e6ee6403ba1300d6c2cb9e5cc701766bc629ad4f12c` |
| tex2.mip5 | 4,096 | `74775c2547584b84ec8d02417afd4f59256cb0d53f40976495a9ee6c4a043b1e` | `af5a1d0bc5d20929c44a928b06b3c5a6bc4964c149eb0d58f9962d4ffc23d8b5` |
| tex2.mip6 | 1,024 | `ab1c5003607ede7bd78561dcab93c3ad19d5f0f37f86bb8e7ad12329042b0aa8` | `7afedafd6c9bee2ee83453e700db1bc6588c733ed6b8cb85093e1853eb77768a` |
| tex2.mip7 | 256 | `004e23314e0ac1da3d7a544bc54860956c8d6d6d46ddb8ec971bef5b807555b1` | `1460b29bf42cda22e111f3aed0a9baf21ca737f7d2538d5888792ffb11153c2b` |
| tex2.mip8 | 64 | `f72fa5adc9bd43fbf5a52a785c13dd5b4567922866858241b7a91a0a1036f149` | `b397cea8c7e495bb747cae5f4832637de7d0310af74ea9485432c13d329407e0` |
| tex2.mip9 | 16 | `3fed914b98c049badc381bacde4aa94140cc4ba29d2ca7b1e987144b1b952781` | `7e823305e9a4338ca73916d680d54ffbe2019a58c8e861b832167762d63a4f66` |
| tex3.mip0 | 4,194,304 | `5d12cafcc7886a21b1090c641a2197f1515e5889075fed2bb9c9c697c7b42723` | `24712549417a7b07aedf8e24827872ccbc7a074342cef297fcdf2e946709ba80` |
| tex3.mip1 | 1,048,576 | `f7ec7645d2ce16f6e795d6b8226b24576ee47c4d17190106e7b22b644bf86621` | `28781a7bc1e9d4b3f3f3dc4677aab9133dcbaf636faed25b7eecd94445c895d0` |
| tex3.mip2 | 262,144 | `a5d3646bdb274d8f636a6be8ed53048ad7beb2cfefe5c5e5d0b5db8ecc8b765e` | `6ccb1ec3da1d6488a688c20438aaca33f8fa33d3790764d5cb98a30ac09655a9` |
| tex3.mip3 | 65,536 | `f551a1149f66bd7e17bddf28b224a6797718e4333617823754a5e20824855414` | `f5707fb48cab7c6ce099abb4684ae1033d35b13660eedd5e8b5c2ac70485ea71` |
| tex3.mip4 | 16,384 | `4ddb6f677accd7ca225cbe13e75be311a06a519c3e51ae4a014c9306e082fc95` | `ba9d7760963ed1d3b895a10e63ef817f347c95b8e42278f2c7d4da3ae0a2d841` |
| tex3.mip5 | 4,096 | `8708499f439a541c5071e6b69ce4db428e1c47ffb66b238ad1446d3e78ef02db` | `a7c991c684610c326486c3779dbd4fa32f7b081daa79b64d9a854a99864f3acf` |
| tex3.mip6 | 1,024 | `e0f137a1db8eabd0fd9e956c20bdea249e503391524598cbe32bba4d0ab77176` | `5e2c914369d8966ff071d050ad5375e8ec27cbb45f4111333141ffa3350d11a7` |
| tex3.mip7 | 256 | `d57aa05af026805248fe5c14507ae6a34ff9831d4a57f7dfc99231ba78e45a02` | `cdfc4c024f3aeecc8ea0e5aa33d9d458f4e2779837c1ec068a1ab4662da0fccf` |
| tex3.mip8 | 64 | `dfad63ea4127316b28e2aee476ca1801c50d567d60709d7267480ce2f0d22f4b` | `86af789164bff8f9014c2b848579dbda919e222583e7f1970edc06ebc5b9a47d` |
| tex3.mip9 | 16 | `35ed983c13e6d472ce969d17892d1a487091472511b92532be022670b481d80e` | `7f11cb6fdd99e85416f081e81ab2b5e018598d886144f69557e110c27df6ba8e` |
