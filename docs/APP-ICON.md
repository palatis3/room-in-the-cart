# Room in the Cart artwork

The approved mark has a raised cream handle, two wheels and a single pear tucked behind the sloping cart rim. Its source is the upper-left tile on the original comparison sheet. The source sheet stays outside the app and web bundles. [Original comparison sheet](../shared/brand/reference/Approved-cart-reference.png)

The production SVG has three editable layers in paint order. The field fills the square. The pear includes its stem and leaf and extends behind the rim. The cart front includes both wheels and stays still. Each export uses the same view box and resting registration. The default colors were sampled from the artwork. UI actions and surfaces use their own semantic colors. [Production master](../shared/brand/cart.svg) · [UI color contract](../shared/contracts/theme.json)

## Application

- The Home Screen receives opaque 1024 × 1024 RGB artwork for the default, dark and tinted appearances. iOS applies its own icon mask. The default asset serves iOS 17.
- In the app, `BrandCartMark()` shows the resting composition. `BrandCartMark(pearOffset:pearAngle:)` keeps the field and cart still while the pear moves in display points and rotates in degrees around its lower body. The illustration is decorative beside the saved result or About caption.
- Extensions can use the complete `BrandCartRest` vector image. The web wordmark uses the rounded `/brand-cart.svg`. The existing 64 px favicon and 180 px touch icon use the complete resting mark.

## Reproduce the exports

Run these commands on macOS with Python 3 and Pillow. The exporter uses the system SVG renderer and verifies that the opaque icon covers its square before writing RGB PNGs.

```sh
python3 scripts/generate_brand_assets.py
python3 scripts/generate_brand_assets.py --check
```

The check compares generated SVGs, asset manifests and decoded PNG pixels. It also verifies the SHA-256 of the original sheet and compares the filled silhouettes within its 564 px registered square, starting at (136, 146). The default export measured 99.61% intersection over union for the cart body, 99.28% for the rear wheel, 99.43% for the front wheel and 98.62% for the pear and leaf. It retains the open space between the handle and fruit. [Export and registration check](../scripts/generate_brand_assets.py)

Small raster previews at 60, 48, 29, 20 and 16 px showed separate wheels and a visible pear in each appearance. At 16 px the stem and leaf read as a single small detail. Home Screen clear effects and other system-applied treatments still require inspection on the relevant configured device.
