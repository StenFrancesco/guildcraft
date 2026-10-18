"""Export generated source artwork as uncompressed 32-bit runtime textures."""

import json
from pathlib import Path
import struct
import zipfile

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
MEDIA = ROOT / "GuildGearMemory" / "Media" / "ArtisanJournal"
SOURCE = ROOT / "tests" / "Source"
SURFACES = ("parchment", "leather", "profession-button")


def main():
    # Fail before writing exports if any of the expected deliverables is absent.
    for name in SURFACES:
        if not (SOURCE / f"{name}.png").is_file():
            raise FileNotFoundError(SOURCE / f"{name}.png")

    manifest = {
        "design": "Artisan Journal",
        "generation": "Built-in ImageGen; gpt-6-luna subagents, max effort",
        "runtime_verified": False,
        "format": "Uncompressed 32-bit RGBA TGA",
        "textures": {},
    }
    for name in SURFACES:
        size = (512, 512)
        with Image.open(SOURCE / f"{name}.png") as source:
            source.load()
            source_size = source.size
            # Technical runtime sizing only; generated art remains in Source.
            texture = source.convert("RGBA").resize(size, Image.Resampling.LANCZOS)
        path = MEDIA / f"{name}.tga"
        texture.save(path, format="TGA", compression=None)
        with Image.open(path) as exported:
            exported.load()
            assert exported.size == size and exported.mode == "RGBA"
            assert exported.tobytes() == texture.tobytes()
        header = path.read_bytes()[:18]
        assert header[2] == 2, "Expected uncompressed true-color TGA"
        assert struct.unpack_from("<HH", header, 12) == size
        assert header[16] == 32 and header[17] & 15 == 8
        manifest["textures"][name] = {
            "file": path.name,
            "wow_path": "Interface\\AddOns\\GuildGearMemory\\Media\\ArtisanJournal\\" + path.name,
            "size": list(size),
            "source": "tests/Source/" + name + ".png",
            "source_size": list(source_size),
            "role": "reusable surface",
        }
        print(f"Verified {path.name}: {size[0]} x {size[1]}, RGBA, uncompressed")

    (MEDIA / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    archive = ROOT / "ui-concepts" / "artisan-journal-runtime-assets.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for name in SURFACES:
            path = MEDIA / f"{name}.tga"
            package.write(path, path.relative_to(ROOT).as_posix())
        for filename in ("manifest.json", "README.md"):
            path = MEDIA / filename
            if path.is_file():
                package.write(path, path.relative_to(ROOT).as_posix())
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None
        assert len([p for p in package.namelist() if p.endswith(".tga")]) == len(SURFACES)
    print(f"Verified package: {archive.name}; {len(SURFACES)} textures")


if __name__ == "__main__":
    main()
