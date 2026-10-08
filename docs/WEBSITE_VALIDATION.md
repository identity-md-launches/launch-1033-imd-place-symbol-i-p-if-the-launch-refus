# Website validation and Better Interface review

This is the worker's record for the launch #1033 website, checked on 2026-10-08. It does not certify the contracts or replace independent review. No deployment, mint, approval or funded transaction was broadcast.

## Scope and evidence

The existing vanilla canvas site, palette, logo, local font and contract semantics were retained. The source was migrated to strict TypeScript and bundled by Vite. Scope includes the canvas, buy/sell form, injected wallets, personal earnings, seasons, gallery, rankings, statistics and explorer/social links. Contract sources, Foundry configuration, dependencies in `lib/`, Git configuration and ignore files were not changed.

The pinned Better Interface workflow and core principles of accessibility, layout, writing, typography, colors and UI were read during implementation. The documentation method was applied after the functional corrections. Its licenses and attribution are in [INTERFACE_LICENSE.txt](INTERFACE_LICENSE.txt). The final design is [DESIGN.md](../DESIGN.md).

Evidence:

- [Mainnet verification](validation/mainnet-verification.json): chain, addresses, ABI hashes, compiled runtime comparison, canvas, price, season end, nonzero buy quote and insufficient-paint revert.
- [Browser/interaction report](validation/browser-validation.json): isolated wallet/RPC fixtures plus live read-only checks, with actual outcomes.
- [Submission size and asset hashes](validation/submission.json): a complete Git-history bundle measured 1,446,117 bytes; a 65,536-byte reporting reserve keeps the total safely below 8,388,608 bytes. The production export is 438,572 bytes.
- [Rendered measurements](validation/design-measurements.json): computed color pairs, font loading, mobile canvas focus and Escape focus return.
- [Desktop screenshot](validation/desktop.jpg) and [phone screenshot](validation/mobile.jpg): the actual export reading the real, currently blank, mainnet canvas. These are not populated mock artwork.

## Commands and results

| Check | Actual result |
| --- | --- |
| `forge build --out /tmp/imd-place-forge-out --cache-path /tmp/imd-place-forge-cache --skip test --skip script` | Passed; unchanged source compiled with solc 0.8.26. Existing Solidity lint warnings were emitted; no contract changes were made. |
| `IMD_FORGE_OUT=/tmp/imd-place-forge-out node tools/verify-live.mjs` | Passed 29 explicit checks. Both pinned ABI hashes matched. All five imd/place runtimes matched compiled source outside immutable fields. No transaction sent. |
| `npm run --prefix web typecheck` | Passed strict TypeScript checking of all frontend TypeScript modules. |
| `npm run --prefix web build` | Passed production build; 153 transformed modules. Relative assets, local font and required licenses are included. |
| `PLAYWRIGHT_BROWSERS_PATH=/tmp/imd-place-browsers IMD_LIVE_BROWSER=1 npm run --prefix web test` | Passed the fixture interaction groups and live browser checks in the linked JSON report. Served the actual export at `/place/`, not a development entrypoint. |
| Rendered layout | No horizontal page overflow at 320, 390, 680, 768, 1120 and 1440px. Also checked an RTL mirror and 200% CSS zoom. |
| Axe accessibility | Zero violations in the tested WCAG 2 A/AA, 2.1 AA and 2.2 AA rule sets: desktop/mobile fixtures and the live mobile export. This is automated coverage only. |
| Browser errors | No uncaught page errors or console errors in the completed fixture/live runs. All local runtime resources loaded. |
| Formatting/path integrity | `git diff --check` passed. Production export, source, lockfile and evidence are in unignored paths. No dependency directories or archives were added. |

The source-supplied browser connector failed because its expected Chromium executable was absent. A pinned Playwright Chromium installation under `/tmp` was used instead. That browser inspected the rendered export and ran the interaction suite; browser coverage is not inferred from static source inspection.

## Mainnet preflight

At block **83,235,842**, chain ID 4663 was confirmed, including converting the requested block parameter back from the returned hex value. The canvas returned **4,096 bytes** and was blank. Pixel 0's price was **1 drop**. Season 1 started at Unix timestamp **1791452670**, with end **1792057470 / 2026-10-15 09:44:30 UTC**.

`PlaceRouter.swap` returned a nonzero simulated buy: **1 IMD → 384,672.017936498385191288 i/p + 20 drops**, with hook fee **200 bps**. This was an `eth_call` with temporary balance/allowance overrides. Each slot was verified using the token's own `balanceOf` and `allowance` getters; nothing was written to chain. Real wallet sends have no overrides and require real funds/approval.

An `eth_call` from a verified contract address with **zero real paint**, attempting `paintWithLimit([0], [4], 1)`, reverted with **InsufficientPaint**, selector **0x8e89355b**. The shared error formatter and a browser fixture using this selector show: “Not enough paint. Buy i/p to earn drops, or select fewer pixels.”

The live sell simulation returned the hook's **PartialFill** nested inside v4 `WrappedError`. The UI now unwraps that error and displays: “There is not enough liquidity for the full trade. Try a smaller amount.” A successful live sell is not claimed. The fixture verifies sell direction, exact input and slippage minimum in the calldata offered to the wallet.

Publicnode refused historical log ranges with an archive-token requirement. The app first attempts that endpoint, then uses the other public endpoint supplied in the network record, which successfully returned the history. No key or authenticated service was added.

## Useful interaction coverage

The automated suite checks positive amounts and 18-decimal precision, rejected malformed amounts, slippage bounds and rounding, 50 distinct pixels and rejection of pixel 51, repaint inspection, pointer and keyboard selection, zoom/pan/reset, and exact season payout rounding.

It also checks disconnected buy quotes with no approval request, expired/edited quote invalidation, injected wallet discovery, the 4902 chain-add path, reconnect/account-change behavior, token and paint balances, bounded paint reviews, actionable custom errors, exact IMD approval destination/amount, sell output and calldata, recoverable wallet rejection, trade claims and outbid refunds. Auction fixtures cover bidding, due settlement, winner/sale price, final-owner claims, due season ending and disabled late painting. Rankings switch between current ownership and cumulative earned IMD.

All wallet fixtures reject final submission; the suite records transaction intent and validates calldata without broadcasting. The real chain currently has no finished season, so its active/settled auction, NFT gallery and season-claim states cannot yet be exercised against historical production data. These use clearly isolated fixtures; the UI never substitutes fixture values for live state.

## Consolidated six-domain review

Findings refer to the final source location where the correction is implemented. Findings discovered during tests were corrected and the relevant interactions rerun.

| Domain | Coverage and finding | Correction / final source | Result and limits |
| --- | --- | --- | --- |
| Accessibility | Keyboard canvas path, coordinate controls, names, palette selection, skip link, forms, modal behavior, target size, motion preferences. The clipped canvas could hide its focus perimeter on phones. | `site/index.html:16` navigation/skip structure; `site/index.html:70` labeled canvas and X/Y path; `site/app.ts` keyboard handlers; `site/style.css:389` inset viewport focus; form `aria-invalid` and live error regions. | Fixed. Canvas focus visibly inspected at 390px; Escape returned focus to Connect. Desktop/mobile axe had zero reported violations. No screen-reader or native-phone certification. |
| Layout | Full-width workspace, reading order, control grouping, long amounts, gallery and sidebar adaptation. The inherited sidebar reduced canvas prominence and cramped mobile controls. | `site/style.css:363` canvas viewport; `.workbench`, `.palette`, `.paint-tray`; breakpoints at 1120px and 680px. | Fixed. Six widths, RTL mirror and 200% CSS zoom had no page overflow. No exhaustive locale/pseudo-localization test. |
| Writing | Labels match actions and explain units, fees, stale data and transaction steps. A raw nested v4 sell error did not explain the recovery. | `site/core.ts:133` unwraps `WrappedError`; `errorMessages.PartialFill` and `InsufficientPaint`; `site/app.ts` review copy and human-readable signing status. | Fixed. Live sell limitation is visible before signing. Trade forms identify invalid fields. Some unusual provider-specific failures fall back to a concise provider message. |
| Typography | Heading hierarchy, local font, weights, input sizes, wrapping and changing numbers. Original help text was often 10px and inputs were small. | `site/style.css:7` role sizes; body 14px, captions 12px, inputs 16px; heading scale, `tabular-nums`, wrapping and font-face. | Fixed. Font load checked in Chromium; binary font table confirms weight axis 400–700. Retained TTF is 79KB, not WOFF2. OS font rendering outside Chromium is unverified. |
| Colors | Semantic dark tokens, selected swatch checkmarks, text/background pairs and system focus colors. Readability and non-color selection cues needed consistent treatment. | `site/style.css:7` tokens, `.swatch[aria-pressed=true]`, focus and forced-color rules. | Fixed. Computed rendered ratios: body 16.62:1; muted panel 7.90:1; neutral action 13.46:1; inline error 9.88:1. Full arbitrary-artwork contrast is not claimed. Light mode is outside the requested design. |
| UI | Empty/loading/error/pending states, modal review, exact approvals, countdowns, auction transitions, disabled controls. Manual refresh could leave auction actions stale; dynamically created actions could appear enabled during a pending request. | `site/app.ts:143` centralized controls and dynamic transaction eligibility; `refresh(forceGallery)`; `loadGallery`; `.primary`, `.segmented`, `.art-card`, native dialogs. | Fixed and regression checked across bid → settle → claim states. Reduced-motion transition duration was 0s. No slow-motion animation-panel review; the interface has only simple 150ms background/press transitions. |

Additional integrity repairs: the ignored legacy deployment filename was replaced with `site/launch-config.json`; local dependency installations and all scratch work stay under `/tmp`; output assets use relative URLs; contract-specific errors retain their exact ABI interpretation; cached event data is shape-validated and checkpointed; gallery metadata reads request enough gas for dense on-chain SVGs.

## Remaining limits and publication

- There were no funded wallets or signed mainnet confirmations. Successful receipts, replacement transactions and native wallet UI variations remain unverified.
- A first browser visit must scan event history. Long history and dense tokenURI artwork may be slow or limited by the public RPC; progress and unavailable states are visible. Event totals use 12 confirmations while other balances use latest state, so newly paid claims can temporarily lag in lifetime rankings.
- The observed live sell cannot complete at the pool's current state; the site communicates the hook error and prevents submission without a quote.
- Native phone browsers, actual MetaMask/Rabby/Coinbase extensions, hardware wallets, screen readers, browser-native 200% zoom, and other browser engines were not exercised. CSS zoom was tested explicitly and is not mislabeled as native browser zoom.
- No public hosting credential or existing website URL was supplied. `dist/` is the complete static publication deliverable for the contributor network; only local HTTP hosting and the `/place/` path were exercised. No external public URL is claimed.

The pinned guide is knowledge used in implementation; it is not an independent authority for these test results. All measurements and screenshots here were produced by this worker.
