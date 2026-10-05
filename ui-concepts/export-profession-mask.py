"""Build the shared mathematical UI mask; never resample profession artwork."""
from pathlib import Path
from math import hypot
from PIL import Image
import sys
import zipfile

MEDIA = Path(__file__).resolve().parents[1] / "GuildGearMemory" / "Media" / "ArtisanJournal"
SIZE = 1024
BASE_FADE = 0.05
UPPER_FADE = BASE_FADE * 1.5
TOP_RADIUS = 0.10
BOTTOM_RADIUS = 0.04


def smoothstep(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def opacity(x, y):
    # An inward feather of a rounded rectangle. The upper and lower treatments
    # meet smoothly, with the lower half retaining the baseline 5% fade.
    upper_weight = 1.0 - smoothstep((y - 0.30) / 0.20)
    fade = BASE_FADE + (UPPER_FADE - BASE_FADE) * upper_weight
    radius = TOP_RADIUS if y < 0.5 else BOTTOM_RADIUS
    qx = abs(x - 0.5) - (0.5 - radius)
    qy = abs(y - 0.5) - (0.5 - radius)
    distance = hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    return round(255 * smoothstep(-distance / fade))


if __name__ == "__main__":
    mask = Image.new("RGBA", (SIZE, SIZE))
    mask.putdata([(255, 255, 255, opacity(x / (SIZE - 1), y / (SIZE - 1)))
                  for y in range(SIZE) for x in range(SIZE)])
    target = MEDIA / "profession-page-mask.tga"
    mask.save(target, compression=None)
    with Image.open(target) as exported:
        assert exported.mode == "RGBA" and exported.tobytes() == mask.tobytes()
    assert mask.getpixel((0, 0))[3] == 0
    assert mask.getpixel((SIZE // 2, SIZE // 2))[3] == 255
    assert opacity(0.04, 0.25) < opacity(0.04, 0.75)
    assert opacity(0.20, 0.20) == 255
    print(f"Verified shared rounded mask: {target}")
    if "--package" in sys.argv:
        root = MEDIA.parents[2]
        addon = root / "GuildGearMemory"
        archive = root / "ui-concepts" / "GuildGearMemory-rounded-professions.zip"
        files = sorted(p for p in addon.rglob("*") if p.is_file()
                       and "Source" not in p.parts
                       and (p.suffix.lower() in {".lua", ".toc", ".tga", ".ttf", ".json", ".md"}
                            or p.name == "FONT-LICENSE.txt"))
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for path in files:
                bundle.write(path, path.relative_to(root).as_posix())
        with zipfile.ZipFile(archive) as bundle:
            assert bundle.testzip() is None
            for path in files:
                assert bundle.read(path.relative_to(root).as_posix()) == path.read_bytes()
            for line in (addon / "GuildGearMemory.toc").read_text().splitlines():
                if line.strip() and not line.startswith("#"):
                    assert "GuildGearMemory/" + line.strip() in bundle.namelist()
            assert "GuildGearMemory/Media/ArtisanJournal/profession-page-mask.tga" in bundle.namelist()
        print(f"Verified complete addon package ({len(files)} files): {archive}")
