# Follow-up: ship the LIGHT gauge (concept A)

The owner chose **concept A (light frosted tile, teal arc and needle)** over the dark final. Work only in `brand/`.

1. **Refine `concepts/icon-a.png`** into the shipping icon `icon/meter-icon-1024.png`, replacing the dark one; keep the dark version as `icon/meter-icon-dark-1024.png`. Keep A's look (a light frosted glass tile, a teal arc and needle) but make it production-clean:
   - perfectly clean alpha edges, with no stray white specks or halo outside the rounded square (the concept has speckle artifacts around the tile);
   - standard macOS 26 icon margins;
   - a crisp silhouette;
   - an arc and needle contrast that still reads at 16 px on both light and dark Dock backgrounds.

   Use image generation or image editing as needed. Verify the edge alpha programmatically: pixels outside the tile must be fully transparent.
2. **Update** `palette.json` and `BRAND.md` so the light tile is primary (adjust the accent only if contrast requires it, and record the ratios). The glyphs stay unless the change needs them to.
3. **Regenerate** `icon/Meter.iconset` with `scripts/package-icons.sh`.
4. **Write** 3 lines in `concepts/README.md` under "Final: light gauge" explaining the cleanup.

Rules: don't launch GUI apps and take no screenshots. End with `BRAND KIT DONE`.
