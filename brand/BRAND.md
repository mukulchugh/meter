# Meter

Meter makes company API spend feel measured, legible and dependable. Its mark is a resting needle inside one open arc: many costs resolve into one trusted reading. The arc suggests a stable frame of reference; the needle suggests precision. It is a fixed identity, not a live budget dial.

## The chosen mark

The owner selected concept A: a light frosted glass tile with a deep petrol teal arc and needle. Its broad arc and diagonal needle stay recognisable at 16 px, while restrained internal reflections give the 1024 px artwork depth. The opaque milky tile keeps the mark's contrast consistent against light and dark Dock backgrounds.

The shipping master is [icon/meter-icon-1024.png](icon/meter-icon-1024.png). The previous dark master is preserved byte-for-byte as [icon/meter-icon-dark-1024.png](icon/meter-icon-dark-1024.png). The concepts and three-line cleanup rationale are in [concepts/README.md](concepts/README.md).

## Palette

Petrol teal conveys considered precision without relying on money-green. Its blue component gives the identity a technical, dependable character; its warmer teal component keeps it approachable. It is clearly distinct from the sister app's iris-violet while retaining a restrained glass material language.

| Role | Light appearance | Dark appearance | Use |
| --- | --- | --- | --- |
| Petrol accent | `#087F82` | `#62D4D2` | Primary reading, selection and focus |
| Paper neutral | `#F5F7F8` | `#F5F7F8` | Light surface or dark-mode foreground |
| Ink neutral | `#10181C` | `#10181C` | Light-mode foreground or dark surface |
| Fresh | `#34C759` | `#30D158` | Small positive status detail |
| Delayed | `#FF9500` | `#FF9F0A` | Delayed-data indicator |
| Stale or error | `#FF3B30` | `#FF453A` | Reading needs attention |
| Over budget | `#FF9500` | `#FF9F0A` | Budget warning with amount |

The primary icon uses deep petrol teal on light frosted glass in both appearances. The accent hex values remain unchanged: the existing light accent provides sufficient graphic contrast on the light tile. Highlights and shadows are tonal variations within the teal and neutral families. UI accents switch with appearance. Semantic state colours are reserved for small supporting details; the app icon keeps its identity colour in every state. The preserved dark artwork is an alternate reference, not the shipping default.

State values are sRGB reference swatches close to macOS system colours, not a claim that every macOS appearance resolves to these exact hex values. Native implementation should prefer `NSColor.systemGreen`, `.systemOrange` and `.systemRed`, alongside dynamic native label colours. Pair colour with a plain-language label and timestamp or amount. These bright state swatches are not approved for small coloured text on a white surface.

### Accent contrast

| Accent | On white `#FFFFFF` | On near-black `#10181C` | On paper `#F5F7F8` |
| --- | --- | --- | --- |
| Light `#087F82` | 4.81:1 | 3.74:1 | 4.47:1 |
| Dark `#62D4D2` | 1.77:1 | 10.15:1 | 1.65:1 |

Ratios use WCAG 2 sRGB relative luminance for opaque flat colours. The intended light-on-white and dark-on-near-black pairings exceed 4.5:1 for normal text. The light accent on paper exceeds the 3:1 graphic threshold, but its 4.47:1 ratio is below the 4.5:1 normal-text threshold; use ink for small text on paper. Do not use the dark accent for small text on white. The icon's glass gradients require a separate raster check; these flat-colour ratios do not describe every highlight. Machine-readable values are in [palette.json](palette.json).

At 16 px, representative arc-to-glass and needle-to-glass samples measure **4.31:1** and **3.22:1** respectively on both white and near-black composites. The sampled pixels lie within the opaque tile, so the background does not change their ratios. These are local samples of the rendered mark, not a minimum across antialiased edges. Exact sample coordinates are recorded in `palette.json`.

## Icon use

- Use the supplied master and iconset, preserving the rounded-square silhouette, transparent exterior, material layers and proportions.
- Keep the whole tile visible. The built-in margin belongs to the asset; do not add another mask or crop it away.
- The supplied raster iconset has a centred 824 × 824 px tile on a 1024 × 1024 px canvas: 100 px transparent margins and 185 px rounded corners. Exterior pixels have zero alpha and zero RGB, with an inward antialias band and no external shadow. These are baked raster packaging dimensions; a future layered Icon Composer asset needs its own system masking and export setup.
- Use at 16 × 16 px minimum. Prefer the supplied exact-size raster at each scale. At 1024 px, glass detail adds depth; at 16 px, recognition relies on the broad arc and needle.
- Keep the needle static. It is the product mark, not a reading of spend, remaining budget or current health.
- Do not add lettering, currency signs, tick marks, provider marks, charts or notification badges to the app icon.
- Do not rotate, stretch, recolour, flatten, add a second tile, or add external glow and drop shadows.
- Preserve the same artwork in light and dark appearance. Do not invert the entire icon.

## Menu-bar glyphs and states

[meter-glyph.svg](glyph/meter-glyph.svg) and [meter-glyph-attention.svg](glyph/meter-glyph-attention.svg) are hand-written 18 × 18 vector templates. Each contains one filled black path with multiple subpaths, no strokes, filters, gradients, embedded images or text. The attention variant adds a small exclamation beneath the right end of the arc while retaining the same gauge.

Use at 18 pt by default; 16 pt is the minimum. Preserve the complete viewBox, including the attention indicator's lower space. Render as a template image, allowing the system to supply the single foreground colour. The black SVG fill is the template mask, not a requirement to display black in dark mode. These are original SF Symbol-style drawings, not registered system symbols. Convert to the app's supported vector asset format during integration if needed; a raw SVG is not promised to be directly loadable by every AppKit image API.

| Product condition | Glyph | Supporting information |
| --- | --- | --- |
| Fresh data | Normal | Last successful update; optional fresh detail |
| Delayed but still usable data | Normal | Delayed label and last successful update |
| Stale, missing or failed data | Attention | Specific reason and last successful update, if known |
| Over budget with fresh data | Normal | Over-budget amount using the budget warning colour |
| Over budget and stale or missing data | Attention | Both the budget condition and freshness issue |

The attention glyph communicates uncertainty about the reading. Budget status stays a separate fact in the opened panel. Use the product's existing freshness and budget rules; this kit defines no time thresholds, spend limits or data-flow changes. Keep both glyphs monochrome in the menu bar. No flashing, pulse animation or colour-only meaning.

## Packaging

Run from any working directory on macOS:

```sh
/Users/mukulchugh/workspace/meter/brand/scripts/package-icons.sh
```

Or run `./scripts/package-icons.sh` from this directory. The script checks the master format and dimensions, then resamples directly from it using `sips`. A Swift pass clears any resampling alpha spill beyond the rounded tile at every output size. This requires Xcode Command Line Tools (`swift`); it does not download dependencies or launch an app.

| Asset points | @1x filename and pixels | @2x filename and pixels |
| --- | --- | --- |
| 16 | `icon_16x16.png`, 16 | `icon_16x16@2x.png`, 32 |
| 32 | `icon_32x32.png`, 32 | `icon_32x32@2x.png`, 64 |
| 128 | `icon_128x128.png`, 128 | `icon_128x128@2x.png`, 256 |
| 256 | `icon_256x256.png`, 256 | `icon_256x256@2x.png`, 512 |
| 512 | `icon_512x512.png`, 512 | `icon_512x512@2x.png`, 1024 |

All ten files live in [icon/Meter.iconset](icon/Meter.iconset/). Keep the 1024 px master as the source of truth and rerun the script after replacing it.

The retained [edited concept source](concepts/icon-a-refined-source.png) can be normalized with `swift scripts/refine-light-icon.swift concepts/icon-a-refined-source.png icon/meter-icon-1024.png`, then packaged with the command above. The cleanup trims the source's noisy perimeter, fits the tile to the raster margin, and applies a deterministic alpha boundary.

## Validation scope

Run `swift scripts/verify-icons.swift` from this directory to verify the shipping master dimensions, every exterior pixel's RGBA in the master and all ten iconset files, 100 px master margins, all ten iconset dimensions, palette ratios, and sampled arc/needle contrast at 16 px on white and near-black. All **398,944 exterior pixels** in the master are fully transparent with zero RGB; all iconset exterior checks also pass. Packaging was rerun successfully from a different working directory. The script also creates [a size-check composite](concepts/light-gauge-size-check.png) with exact 16 px artwork and nearest-neighbour enlargements. This is a direct raster composite, not a screenshot.

The follow-up leaves the menu-bar glyphs unchanged. Native Dock rendering, menu-bar integration and macOS accessibility appearances still require validation in the host app; no GUI app is launched for this kit.
