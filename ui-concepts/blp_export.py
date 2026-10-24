"""Encode BLP2 mipmaps using Pillow's DXT encoder; keep source PNGs lossless."""

from io import BytesIO
from pathlib import Path
import struct

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "The Guild Book" / "Media" / "ArtisanJournal"
SOURCE = ROOT / "tests" / "Source"
BLP_SOURCES = {
    **{f"{name}-page": (f"{name}-page.png", (1024, 1024))
       for name in ("alchemy", "blacksmithing", "enchanting", "engineering",
                    "leatherworking", "tailoring", "recipe")},
    "gear-journal-page": ("gear-journal-page.png", (1024, 512)),
    "bank-page": ("bank-page.png", (1024, 512)),
    "journal-window": ("journal-window-v2.png", (2048, 1024)),
}


def _dxt_payload(image, pixel_format):
    # Tiny mip levels still occupy one 4 x 4 DXT block. Repeat the edge pixels
    # into its unused area instead of allowing black padding to affect colors.
    width, height = image.size
    if width < 4 or height < 4:
        padded = Image.new(image.mode, (max(4, width), max(4, height)))
        for y in range(padded.height):
            for x in range(padded.width):
                padded.putpixel((x, y), image.getpixel((min(x, width - 1), min(y, height - 1))))
        image = padded
    stream = BytesIO()
    image.save(stream, format="DDS", pixel_format=pixel_format)
    data = stream.getvalue()
    assert data[:4] == b"DDS " and data[84:88] == pixel_format.encode("ascii")
    payload = data[128:]
    block_bytes = 8 if pixel_format == "DXT1" else 16
    assert len(payload) == max(1, (width + 3) // 4) * max(1, (height + 3) // 4) * block_bytes
    return payload


def encode_blp(image):
    image = image.convert("RGBA")
    width, height = image.size
    if not all(value > 0 and value & (value - 1) == 0 for value in image.size):
        raise ValueError("BLP dimensions must be powers of two")
    has_alpha = image.getchannel("A").getextrema() != (255, 255)
    pixel_format = "DXT5" if has_alpha else "DXT1"
    offsets, lengths, payloads = [], [], []
    offset = 148  # BLP2 header, including the two 16-entry mipmap tables.
    size = image.size
    while True:
        level = image if size == image.size else image.resize(size, Image.Resampling.LANCZOS)
        payload = _dxt_payload(level, pixel_format)
        offsets.append(offset)
        lengths.append(len(payload))
        payloads.append(payload)
        offset += len(payload)
        if size == (1, 1):
            break
        size = (max(1, size[0] // 2), max(1, size[1] // 2))
    if len(payloads) > 16:
        raise ValueError("BLP supports at most 16 mip levels")
    header = struct.pack("<4sI4BII", b"BLP2", 1, 2, 8 if has_alpha else 0,
                         7 if has_alpha else 0, 1, width, height)
    header += struct.pack("<16I", *(offsets + [0] * (16 - len(offsets))))
    header += struct.pack("<16I", *(lengths + [0] * (16 - len(lengths))))
    data = header + b"".join(payloads)
    with Image.open(BytesIO(data)) as decoded:
        decoded.load()
        assert decoded.size == image.size
        assert decoded.mode == ("RGBA" if has_alpha else "RGB")
    return data


def save_blp(image, target):
    data = encode_blp(image)
    target.write_bytes(data)
    with Image.open(target) as exported:
        exported.load()
        assert exported.size == image.size
    print(f"Verified {target.name}: {image.width} x {image.height}, BLP2 DXT with full mipmaps, {len(data):,} bytes")


def source_image(name):
    filename, size = BLP_SOURCES[name]
    with Image.open(SOURCE / filename) as source:
        return source.convert("RGBA").resize(size, Image.Resampling.LANCZOS)
