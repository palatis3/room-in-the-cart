#!/usr/bin/env python3
"""Export the approved cart's registered SVG layers and native/web rasters on macOS."""
import argparse
import hashlib
import json
from copy import deepcopy
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from xml.etree import ElementTree as ET

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "shared/brand/cart.svg"
CATALOG = ROOT / "ios/Resources/Assets.xcassets"
SVG = "{http://www.w3.org/2000/svg}"
ET.register_namespace("", SVG[1:-1])
INFO = {"author": "xcode", "version": 1}

# The Any appearance uses the master paints. Variants change only their values.
APPEARANCES = {
    "any": {},
    "dark": {"field": "#43283F", "pear": "#D9E2A0", "front": "#F6EAF0"},
    "tinted": {"field": "#242424", "pear": "#ABABAB", "front": "#F4F4F4"},
}
NATIVE_MARKS = {
    "BrandCartRest": ("field", "pear", "front"),
    "BrandCartField": ("field",),
    "BrandCartPear": ("pear",),
    "BrandCartFront": ("front",),
}


def svg_bytes(master, groups, mode="any", *, web=False):
    root = deepcopy(master)
    for group in root.findall(f"{SVG}g"):
        name = group.get("id")
        if name not in groups:
            root.remove(group)
        elif mode != "any":
            group.set("fill", APPEARANCES[mode][name])

    if web:
        # Apply the rounded tile only to artwork embedded in a page.
        root.find(f"{SVG}g[@id='field']/{SVG}rect").set("rx", "126")
        rules = " ".join(f"#{key} {{ fill: {value}; }}" for key, value in APPEARANCES["dark"].items())
        ET.SubElement(root, f"{SVG}style").text = f"@media (prefers-color-scheme: dark) {{ {rules} }}"
    return ET.tostring(root, encoding="utf-8") + b"\n"


def catalog_entry(filename, mode):
    result = {"filename": filename, "idiom": "universal"}
    if mode != "any":
        result["appearances"] = [{"appearance": "luminosity", "value": mode}]
    return result


def manifest(entries, *, vector=False):
    contents = {"images": entries, "info": INFO}
    if vector:
        contents["properties"] = {"preserves-vector-representation": True}
    return (json.dumps(contents, indent=2) + "\n").encode()


def raster(svg, folder):
    source, dest = folder / "master.svg", folder / "master.png"
    source.write_bytes(svg)
    subprocess.run(["sips", "-s", "format", "png", str(source), "--out", str(dest)],
                   check=True, stdout=subprocess.DEVNULL)
    with Image.open(dest) as rgba:
        if rgba.convert("RGBA").getchannel("A").getextrema() != (255, 255):
            raise ValueError("System icon artwork must fill its square")
        return rgba.convert("RGB")


def output(path, data, check):
    if check:
        if not path.is_file() or path.read_bytes() != data:
            raise SystemExit(f"Stale brand asset: {path.relative_to(ROOT)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def output_png(path, image, check):
    if check:
        with Image.open(path) as stored:
            if stored.mode != "RGB" or stored.size != image.size or ImageChops.difference(stored, image).getbbox():
                raise SystemExit(f"Stale brand raster: {path.relative_to(ROOT)}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        image.save(path, optimize=True)


def check_registration(reference, icon):
    """Compare filled silhouette masks inside each feature's box, away from the tile corners."""
    expected = "5658a18fde3cbe2c20dbb6372ce13e6523e440442d2dde82fa774da48941031d"
    if hashlib.sha256(reference.read_bytes()).hexdigest() != expected:
        raise SystemExit("Reference differs from the selected V1/V6 comparison sheet")
    with Image.open(reference) as board:
        source = board.convert("RGB").crop((136, 146, 700, 710))
    redraw = icon.resize(source.size, Image.Resampling.LANCZOS)
    features = {
        "cart": (42, 108, 500, 401),
        "rear wheel": (162, 400, 260, 500),
        "front wheel": (345, 400, 440, 500),
        "pear and leaf": (321, 110, 466, 270),
    }
    for name, box in features.items():
        def mask(image):
            red, green, blue = image.crop(box).split()
            if name == "pear and leaf":
                yellow = ImageChops.subtract(green, blue).point(lambda c: 255 if c > 26 else 0)
                return ImageChops.darker(green.point(lambda c: 255 if c > 132 else 0), yellow)
            return ImageChops.darker(red, blue).point(lambda c: 255 if c > 183 else 0)

        first, second = mask(source), mask(redraw)
        overlap = ImageChops.darker(first, second).histogram()[255]
        union = ImageChops.lighter(first, second).histogram()[255]
        print(f"{name}: {100 * overlap / union:.2f}% intersection over union at 564 px")
        if overlap / union < 0.98:
            raise SystemExit(f"Registration outside tolerance: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare exports without writing")
    parser.add_argument("--reference", type=Path, default=ROOT / "shared/brand/reference/Approved-cart-reference.png",
                        help="Comparison sheet used for registration (defaults to the retained original)")
    args = parser.parse_args()
    master = ET.parse(MASTER).getroot()
    all_groups = NATIVE_MARKS["BrandCartRest"]

    for asset, groups in NATIVE_MARKS.items():
        directory = CATALOG / f"{asset}.imageset"
        entries = []
        for mode in ("any", "dark"):
            name = f"{asset}-{mode}.svg"
            output(directory / name, svg_bytes(master, groups, mode), args.check)
            entries.append(catalog_entry(name, mode))
        output(directory / "Contents.json", manifest(entries, vector=True), args.check)

    output(ROOT / "web/public/brand-cart.svg", svg_bytes(master, all_groups, web=True), args.check)
    icon_directory = CATALOG / "AppIcon.appiconset"
    icons = []
    with TemporaryDirectory() as folder:
        for mode in APPEARANCES:
            filename = "AppIcon.png" if mode == "any" else f"AppIcon-{mode}.png"
            image = raster(svg_bytes(master, all_groups, mode), Path(folder))
            output_png(icon_directory / filename, image, args.check)
            icons.append(catalog_entry(filename, mode) | {"platform": "ios", "size": "1024x1024"})
            if mode == "any":
                for size, name in [(64, "icon.png"), (180, "apple-touch-icon.png")]:
                    web_icon = image.resize((size, size), Image.Resampling.LANCZOS)
                    output_png(ROOT / "web/public" / name, web_icon, args.check)
                check_registration(args.reference, image)
    output(icon_directory / "Contents.json", manifest(icons), args.check)


if __name__ == "__main__":
    main()
