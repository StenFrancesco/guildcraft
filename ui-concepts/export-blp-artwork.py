"""Rebuild compressed runtime illustrations from their original source PNGs."""

from blp_export import BLP_SOURCES, MEDIA, save_blp, source_image


for name in BLP_SOURCES:
    save_blp(source_image(name), MEDIA / f"{name}.blp")
