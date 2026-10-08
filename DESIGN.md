# imd/place design

## Overview

A shared pixel canvas for painters and collectors on Robinhood Chain. The implemented interface retains the existing i/p pixel logo, dark surfaces and Pixelify Sans lettering. The live canvas is the full-width hero workspace; trading, personal earnings and the current season follow it. All artwork and economic values are chain-derived. A blank season stays visibly blank.

Source of truth: `site/style.css`, `site/index.html` and the DOM patterns in `site/app.ts`. The built counterpart is `dist/`. This document describes the final implementation, not an additional component library.

## Colors

The semantic tokens are declared in `site/style.css:7` using the existing hex notation.

| Token | Value | Use |
| --- | --- | --- |
| `--page` | `#101014` | Page and form backgrounds |
| `--surface` | `#19191f` | Workspace panels, gallery cards, dialogs |
| `--raised` | `#24242d` | Neutral button surfaces |
| `--text` | `#f1f0e9` | Primary text |
| `--muted` | `#adadbc` | Help, captions and secondary text |
| `--border` | `#41414f` | Panel structure and separators |
| `--accent` | `#63c74d` | Main paint/confirm buttons, brand emphasis |
| `--accent-hover` | `#83df6f` | Primary hover state |
| `--on-accent` | `#10190d` | Primary button labels |
| `--focus` | `#ffd635` | Keyboard focus and canvas cursor |
| `--error` | `#ffacb9` | Error copy |
| `--error-bg` | `#2b151e` | Error notice background |

The palette is content, read from `Canvas.getPalette()`: Ink `#181425`, White `#ffffff`, Silver `#c0cbdc`, Slate `#5a6988`, Red `#ff0044`, Orange `#ff8426`, Yellow `#ffd635`, Lime `#63c74d`, Teal `#009e8f`, Cyan `#22d3ee`, Blue `#0099db`, Indigo `#3e52f5`, Violet `#8b46ff`, Pink `#f472b6`, Brown `#8f563b`, Peach `#ffccaa`. The same fallback palette appears while the chain loads. Unpainted checker cells use `#1d1d27` / `#171720` and do not represent fabricated artwork.

Measured rendered text/background contrast: body **16.62:1**, secondary panel copy **7.90:1**, neutral buttons **13.46:1**, inline error text **9.88:1**. Exact selectors, computed colors and timestamp are in `docs/validation/design-measurements.json`. These are specific pairs, not a claim about every possible artwork color. Only the requested dark theme is implemented.

## Typography

`site/vendor/PixelifySans.ttf` is the retained local variable font. The font's `fvar` table confirms a `wght` axis of **400–700**. CSS defines `font-display: swap`; Chromium confirmed the face loaded. Retaining the existing 79 KB TTF avoids changing the project's font asset. Its OFL notice is in the source and production export.

- Headings, brand and large metrics: `Pixel, monospace`, weight 600. H1 uses `--display: clamp(42px, 5.2vw, 68px)`, 1.1 line height and −1px letter spacing. H2 is 32px, reducing to 30px on phones; H3 is 24px. Dialog H2 is 30px.
- Controls and body: `ui-monospace, SFMono-Regular, Consolas, monospace`, `--body: 14px`, line height 1.6. This is an intentionally dense drawing/trading interface.
- Captions and help: `--caption: 12px`, line height 1.7 for `.fine`. Eyebrows use 1.2px letter spacing and CSS uppercase. A few compact header/board annotations use 11px on phones.
- Inputs remain **16px** at every width, avoiding small-input zoom in iOS browsers. Metric and timer digits inherit `font-variant-numeric: tabular-nums`.
- Headings balance their text; paragraphs use `text-wrap: pretty`. IDs/quotes can wrap. Shortened account links retain their full address in the destination/title; transaction reviews show exact amounts and account addresses.

## Layout

`header`, `main` and `footer` share a 1,360px maximum width, with 32px inline padding on desktop and 16px on phones. Spacing uses 4/8px increments with 12, 16, 20, 24, 32 and 48px group gaps. `--space: 8px` controls the desktop palette gap.

The canvas wrapper spans the content width. Its desktop viewport is `min(70vh, 900px)` high, with a minimum of 280px. The 64×64 canvas remains square inside it, with nearest-neighbour rendering; the surrounding dot pattern is decorative. On phones it becomes a full-width square. Pan/zoom transforms the canvas within the clipped viewport. Paint controls, selection cost and the review action remain in normal flow below it.

At **1,120px**, navigation takes a full row, the three-column workbench becomes two columns with Season spanning both, and the gallery becomes two columns. At **680px**, the workbench/gallery become one column, statistics become 2×2, the palette becomes 8×2, pixel details stack and the paint action fills its inset row. The secondary introductory note disappears. Native dialogs fit within `calc(100% - 32px)` and `calc(100dvh - 32px)`.

No horizontal page overflow was found at 320, 390, 680, 768, 1,120 or 1,440px. A 200% CSS zoom check and RTL layout mirror also passed. These are Chromium observations, not native-device certification.

## Elevation & Depth

Panels use one-pixel borders and tonal surfaces to organize tools. The primary action has a deliberate 3px square black offset shadow. Dialogs use a dark translucent backdrop and a 4px blur. Artwork has a one-pixel low-opacity white outline. There are no decorative floating cards or perpetual animation.

## Shapes

Square corners follow the pixel identity. The 44px minimum button height applies to actions; swatches are at least 40px on desktop and 44px on phones. The canvas uses sharp pixel edges. Selected colours combine a white perimeter with a checkmark inside a dark square, so selection is not conveyed by colour alone.

## Components

| Pattern | Source | Behavior |
| --- | --- | --- |
| `.primary`, `.quiet`, `.segmented` | `site/style.css`; native buttons in `site/index.html` | Filled emphasis for paint/confirmation, quiet utility actions, pressed-state mode selectors. Disabled states reflect unavailable/pending actions. |
| `.board-panel`, `.viewport`, `.palette`, `.paint-tray` | `site/index.html`, drawing/selection functions in `site/app.ts` | Pointer selection, arrow-key cursor, Enter/Space selection, X/Y entry, pan and zoom. A 50-pixel maximum and a reviewed paint-cost ceiling. |
| Form / `.quote-info` / `.field-error` | Swap form and quote handlers | Visible labels, `aria-invalid`, field-associated errors, expected/minimum output, fee, expiry, and separate review before approval. |
| Native `<dialog>` | Wallet and review dialogs | Modal backdrop, native background inertness and Escape behavior. Cancellation returns focus; pending wallet confirmation prevents dismissing its review. Wallet names are inserted as text. |
| `.panel`, `.account-metrics`, `.pixel-list` | My pixels / Season / trade sections | Loading, empty and connected states; separate claim and refund actions. Pixel lists wrap and scroll locally. |
| `.art-card` | `auctionCard()` | On-chain image, exact bid minimum, current bidder or winner, sale price, settlement and seasonal claim review. Artwork failure leaves financial controls available. |
| `.leaderboard-panel`, `.metrics` | Community/history rendering | Ownership and earned modes; explicit event-indexing progress, confirmation delay and partial-data status. |
| Status and focus | `status()`, `:focus-visible`, `.viewport:focus-within` | Persistent feedback, inline transaction errors and 3px yellow focus. Canvas focus uses an inset viewport perimeter to avoid clipping on phones. Forced-colors mode uses system focus colors. |

Transitions are limited to background/transform at 150ms, with a 0.96 press scale. Motion is opt-in under `prefers-reduced-motion: no-preference`; the reduced-motion check observed zero transition duration. There is no entrance animation to delay the canvas.

## Do's and Don'ts

- Reuse the existing panel, heading and spacing patterns. Keep contract units and exact minimum amounts visible near transaction actions.
- Use `.primary` for the main action within a workspace or modal; keep secondary actions neutral.
- Preserve named palette buttons and the checkmark, coordinate fields, keyboard canvas path, and visible focus treatment.
- Show empty, loading, stale and unavailable state honestly. Do not substitute illustrative pixel art or sample balances for chain state.
- Keep added screens static: add a labeled section and hash navigation link, use the shared width/padding and responsive grids, and test the export at a subpath.
- Preserve local font/logo assets and their notices. Do not add external font, wallet or analytics services merely to reproduce this design.

Guidance applied: Jakub Krehel's Better Interface, pinned commit `267330e1adfc66a718fb65fa6918c1f06d0a689e` (MIT), and the adapted Impeccable documentation method by Paul Bakaus, commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8` (Apache-2.0). Notices and licenses are retained in `docs/INTERFACE_LICENSE.txt`. See `docs/WEBSITE_VALIDATION.md` for findings and limits.
