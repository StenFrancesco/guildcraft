"""Export the character armory artwork to the addon's runtime texture format."""

from pathlib import Path
from PIL import Image

MEDIA = Path(__file__).resolve().parents[1] / "GuildGearMemory" / "Media" / "ArtisanJournal"

with Image.open(MEDIA / "Source" / "character-armory.png") as source:
    texture = source.convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)
destination = MEDIA / "character-armory.tga"
texture.save(destination, format="TGA", compression=None)
with Image.open(destination) as exported:
    assert exported.size == (1024, 1024) and exported.mode == "RGBA"
    assert exported.tobytes() == texture.tobytes()
header = destination.read_bytes()[:18]
assert header[2] == 2 and header[16] == 32, "Expected uncompressed 32-bit TGA"
print(f"Verified {destination}: 1024x1024, RGBA, uncompressed")
