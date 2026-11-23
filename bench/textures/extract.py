"""Decode the benchmark photos from a scikit-image wheel to raw RGBA8.

Usage: python3 -I extract.py <scikit-image wheel> <output dir>

Reads the photos straight out of the wheel (a zip file) without unpacking
it, crops each to a multiple of 4 in both sides (the right and bottom
remainder is dropped), and writes, in the output dir:

  <name>.rgba   width * height * 4 bytes, row-major, alpha 255
  photos.txt    one line per photo: "<name> <width> <height>"

The normal maps are made from these files by the Zig program (gen.zig).
"""

import hashlib
import io
import os
import sys
import zipfile

from PIL import Image

WHEEL_NAME = "scikit_image-0.26.0-cp313-cp313-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl"
WHEEL_SHA256 = "b36ab5e778bf50af5ff386c3ac508027dc3aaeccf2161bdf96bde6848f44d21b"

# (output name, member of the wheel)
PHOTOS = [
    ("astronaut", "skimage/data/astronaut.png"),
    ("chelsea", "skimage/data/chelsea.png"),
    ("coffee", "skimage/data/coffee.png"),
    ("rocket", "skimage/data/rocket.jpg"),
    ("hubble_deep_field", "skimage/data/hubble_deep_field.jpg"),
    ("retina", "skimage/data/retina.jpg"),
    ("ihc", "skimage/data/ihc.png"),
]

MAX_MEMBER_BYTES = 8 << 20
MAX_PIXELS = 4096 * 4096


def main(argv):
    if len(argv) != 3:
        sys.exit("usage: python3 -I extract.py <scikit-image wheel> <output dir>")
    wheel_path, out_dir = argv[1], argv[2]

    with open(wheel_path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != WHEEL_SHA256:
        sys.exit(f"{wheel_path}: sha256 {digest}, expected {WHEEL_SHA256} ({WHEEL_NAME})")

    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    os.makedirs(out_dir, exist_ok=True)
    manifest = []
    with zipfile.ZipFile(wheel_path) as wheel:
        for name, member in PHOTOS:
            info = wheel.getinfo(member)
            if info.file_size > MAX_MEMBER_BYTES:
                sys.exit(f"{member}: {info.file_size} bytes, more than expected")
            data = wheel.read(member)
            with Image.open(io.BytesIO(data)) as im:
                im.load()
                if im.mode != "RGB":
                    sys.exit(f"{member}: mode {im.mode}, expected RGB")
                w, h = im.size
                cw, ch = w - w % 4, h - h % 4
                rgba = im.crop((0, 0, cw, ch)).convert("RGBA")
            pixels = rgba.tobytes()
            assert len(pixels) == cw * ch * 4
            with open(os.path.join(out_dir, name + ".rgba"), "wb") as f:
                f.write(pixels)
            manifest.append(f"{name} {cw} {ch}\n")
            print(f"{name}: {w}x{h} -> {cw}x{ch}, rgba sha256 {hashlib.sha256(pixels).hexdigest()}")
    with open(os.path.join(out_dir, "photos.txt"), "w", newline="\n") as f:
        f.writelines(manifest)


if __name__ == "__main__":
    main(sys.argv)
