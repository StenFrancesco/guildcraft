"""Export the character armory artwork to the addon's runtime texture format."""

from pathlib import Path
from PIL import Image
from blp_export import save_blp

MEDIA = Path(__file__).resolve().parents[1] / "The Guild Book" / "Media" / "ArtisanJournal"
SOURCE = Path(__file__).resolve().parents[1] / "tests" / "Source"

for name, size in (("gear-journal-page", (1024, 1024)),):
    with Image.open(SOURCE / f"{name}.png") as source:
        texture = source.convert("RGBA").resize(size, Image.Resampling.LANCZOS)
    if texture.getchannel("A").getextrema() == (255, 255):
        texture = texture.convert("RGB")
    destination = MEDIA / f"{name}.blp"
    save_blp(texture, destination)
