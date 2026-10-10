"""Package all three addon folders and verify the distributable against workspace files."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
from PIL import Image

root = Path(__file__).resolve().parents[1]
target = root / "ui-concepts" / "GuildGearMemory-ThreeFolders.zip"
folders = ("GuildGearMemory", "DysbankMemory", "DysgearMemory")
files = sorted(p for folder in folders
               for p in (root / folder).rglob("*") if p.is_file())
with ZipFile(target, "w", ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, path.relative_to(root).as_posix())
with ZipFile(target) as archive:
    assert archive.testzip() is None
    for path in files:
        assert archive.read(path.relative_to(root).as_posix()) == path.read_bytes()
    for folder in folders:
        for line in (root / folder / (folder + ".toc")).read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                assert folder + "/" + line.strip() in archive.namelist()
    assert "GuildGearMemory/Media/ArtisanJournal/bank-page.tga" in archive.namelist()
with Image.open(root / "GuildGearMemory/Media/ArtisanJournal/bank-page.tga") as image:
    assert image.size == (1024, 1024) and image.mode == "RGB"
print(f"Verified {len(files)} files, all three manifests and bank artwork: {target}")
