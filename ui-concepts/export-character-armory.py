"""Export the character armory artwork to the addon's runtime texture format."""

from pathlib import Path
from PIL import Image

MEDIA = Path(__file__).resolve().parents[1] / "GuildGearMemory" / "Media" / "ArtisanJournal"
SOURCE = Path(__file__).resolve().parents[1] / "tests" / "Source"

for name, size in (("character-armory", (1024, 1024)),
                   ("character-armory-vignette", (1024, 512)),
                   ("gear-journal-page", (1024, 1024))):
    with Image.open(SOURCE / f"{name}.png") as source:
        texture = source.convert("RGBA").resize(size, Image.Resampling.LANCZOS)
    if name.endswith("vignette"):
        alpha = texture.getchannel("A")
        assert alpha.getextrema() == (0, 255), "Vignette must retain transparency"
        assert alpha.crop((0, 0, 1, size[1])).getextrema() == (0, 0), "Left edge must blend into parchment"
        assert alpha.crop((0, size[1] - 1, size[0] // 2, size[1])).getextrema() == (0, 0), "Lower-left edge must blend into parchment"
        assert sum(alpha.histogram()[1:255]) > 0, "Fade must include partial transparency"
    destination = MEDIA / f"{name}.tga"
    texture.save(destination, format="TGA", compression=None)
    with Image.open(destination) as exported:
        assert exported.size == size and exported.mode == "RGBA"
        assert exported.tobytes() == texture.tobytes()
    header = destination.read_bytes()[:18]
    assert header[2] == 2 and header[16] == 32, "Expected uncompressed 32-bit TGA"
    print(f"Verified {destination}: {size}, RGBA, uncompressed")
