# Brief: Meter brand kit (Codex, image generation)

Work only inside this directory (`brand/`).

## The product
Meter is a native macOS 26 menu-bar app for a CTO. It shows what the company spends on the Anthropic and OpenAI APIs: today and this month, split between the product (app keys) and the team (people, Claude Code), with budgets, limits and a projected month end. It is local-only, calm and exact. It is the one number a CTO trusts, never alarmist. Its sister app Setu uses an iris-violet accent (#6550C7); Meter must be clearly its own product, while sharing the same restraint and Liquid Glass language.

## Direction
- **Original identity.** Don't use a dollar sign, coins, a piggy bank, generic charts or anything imitating Apple or OpenAI/Anthropic marks.
- **Concept seeds (pick, combine or beat):**
  - a precise gauge or meter needle resting on a calm arc;
  - a single rising level within a glass vessel (a measured reserve);
  - two converging flows (two providers) measured by one mark;
  - a minimal dial made of layered translucent planes.
- **One strong accent colour plus neutrals.** Suggest an accent that reads as trustworthy and financial but not cliché money-green: for example deep teal, ink-blue or amber. Explain the choice. It must work in light and dark.
- **The icon must read at 16 px and 1024 px.** It is a macOS 26 rounded-square app icon with layered translucent glass depth. No text or letters in any generated image.
- **Menu-bar glyph:** a monochrome template glyph that works as a single colour at 16 to 18 pt, drawn as a simple vector in the style of an SF Symbol. It needs an "attention" variant (for stale or missing data).

## Deliverables (all in `brand/`)
1. **Concepts.** Use your image generation tool for 3 distinct app-icon concepts at 1024x1024 PNG: `concepts/icon-a.png`, `concepts/icon-b.png`, `concepts/icon-c.png`, each with a one-line rationale in `concepts/README.md`.
2. **The pick.** Choose the strongest, explain why in 3 lines, and refine it into the final `icon/meter-icon-1024.png`.
3. **Menu-bar glyphs** as hand-written SVG: `glyph/meter-glyph.svg` and `glyph/meter-glyph-attention.svg`. Each is a single path, viewBox `0 0 18 18`, monochrome, and echoes the icon.
4. **Palette.** `palette.json`: the accent in light and dark, two neutrals, and the states: fresh, delayed, stale or error, over budget. Keep the states close to the macOS system colours. Record the accent's contrast ratios on white and on near-black.
5. **`BRAND.md`.** The concept, what the mark means, the palette with hex values and usage, the icon do's and don'ts, the minimum size, and how the menu-bar glyph maps to states.
6. **Packaging.** Make `icon/Meter.iconset/` with all macOS sizes (16, 32, 128, 256 and 512, at @1x and @2x) from the final PNG, using `sips`. Add `scripts/package-icons.sh` that does it.

## Rules
- Don't launch any GUI app and don't take screenshots.
- No network beyond your image tool.
- End your final message with `BRAND KIT DONE`.
