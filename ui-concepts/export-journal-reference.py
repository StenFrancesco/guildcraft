"""Export the reference-matched journal artwork and build a complete local addon ZIP."""
from pathlib import Path
import json
import zipfile
from PIL import Image
from blp_export import BLP_SOURCES, save_blp

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "The Guild Book"
MEDIA = ADDON / "Media" / "ArtisanJournal"
SOURCE = ROOT / "tests" / "Source"
professions = (
    "alchemy", "blacksmithing", "cooking", "enchanting", "engineering",
    "first-aid", "fishing", "leatherworking", "tailoring",
)
exports = {f"{name}-page": (f"{name}-page.png", (1024, 1024)) for name in professions}
exports.update({"journal-window": ("journal-window-v2.png", (2048, 1024)),
                "profession-button-framed": ("profession-button-framed-v2.png", (512, 128))})
manifest = {}
for name, (source, size) in exports.items():
    original = Image.open(SOURCE / source).convert("RGBA")
    converted = original.resize(size, Image.Resampling.LANCZOS)
    if converted.getchannel("A").getextrema() == (255, 255):
        converted = converted.convert("RGB")
    target = MEDIA / f"{name}.{'blp' if name in BLP_SOURCES else 'tga'}"
    if name in BLP_SOURCES:
        save_blp(converted, target)
    else:
        converted.save(target, compression=None)
        with Image.open(target) as check:
            assert check.size == size and check.mode == converted.mode, target
            assert check.tobytes() == converted.tobytes(), target
    manifest[name] = {"source": source, "source_size": list(original.size), "size": list(size),
                      "file": target.name}
(MEDIA / "reference-export.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

archive = ROOT / "ui-concepts" / "The-Guild-Book-ArtisanJournal-v2.zip"
files = sorted(p for p in ADDON.rglob("*") if p.is_file()
               and (p.suffix.lower() in {".lua", ".toc", ".tga", ".blp", ".ttf", ".json", ".md"}
                    or p.name == "FONT-LICENSE.txt"))
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
    for path in files:
        bundle.write(path, path.relative_to(ROOT).as_posix())
with zipfile.ZipFile(archive) as bundle:
    assert bundle.testzip() is None
    names = set(bundle.namelist())
    for line in (ADDON / "The Guild Book.toc").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            assert "The Guild Book/" + line.strip() in names, line
    for name in exports:
        assert f"The Guild Book/Media/ArtisanJournal/{manifest[name]['file']}" in names
    for name in ("journal-serif.ttf", "journal-serif-bold.ttf", "FONT-LICENSE.txt"):
        assert f"The Guild Book/Media/ArtisanJournal/{name}" in names
print(f"Verified {len(exports)} reference textures; packaged {len(files)} files: {archive}")
