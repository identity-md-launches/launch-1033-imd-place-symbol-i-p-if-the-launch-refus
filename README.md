# imd/place

The live launch #1033 interface on Robinhood Chain (4663): a 64×64 canvas, paint, i/p ↔ IMD trading, artist earnings, weekly NFT auctions and a season gallery. [@imdplace](https://x.com/imdplace)

The finished static website is in **[dist/](dist/)**. Source is in [site/](site/); the existing vanilla interface, logo and local Pixelify Sans font are retained, with TypeScript and a Vite production build. No backend, WalletConnect, API key or project ID is used. This change deploys no contracts.

## Install, rebuild and preview

Use Node.js 22+ and npm. Build dependencies are deliberately installed outside the repository. The frontend manifest and reproducible lockfile live in `web/`; existing contract dependencies and Foundry configuration are unchanged.

```sh
export IMD_TOOLCHAIN=/tmp/imd-place-toolchain
mkdir -p "$IMD_TOOLCHAIN"
cp web/package.json web/package-lock.json "$IMD_TOOLCHAIN/"
npm ci --prefix "$IMD_TOOLCHAIN" --cache /tmp/imd-place-npm-cache
npm run --prefix web typecheck
npm run --prefix web build
npm run --prefix web preview
```

Preview serves the production export at `http://localhost:4173`. Alternatively, run `python3 -m http.server 4173 --directory dist` with no npm installation. Open the HTTP URL, rather than `index.html` using `file://`.

`IMD_TOOLCHAIN` defaults to `/tmp/imd-place-toolchain`. `tools/frontend.mjs` resolves the pinned build tools there, configures Vite with `base: './'`, and typechecks every TypeScript source with strict mode. The scripts do not require `.imd/reads/` after submission. No dependency directories or npm archives are part of the export.

## Publish

Serve **the contents of `dist/`** from the assignment's static publisher or any HTTPS static host. Set its document root to `dist`, with `index.html` as the index document. The export contains relative asset URLs and hash navigation; no route rewrite or server-side application is needed. A `/place/` subpath was tested. Serve `.js`, `.css`, `.ttf`, `.svg` and image files with normal MIME types. Keep `index.html` short-lived in caches; hashed assets may be cached immutably.

The repository contains the complete publication artifact. The provided project record names no existing website URL or authenticated hosting destination, so this worker has not provisioned an external public host or claimed a public URL. Publication by the contributor network is the remaining hosting step; it must serve the submitted export, not the unbundled `site/` directory.

## Live configuration and provenance

[site/launch-config.json](site/launch-config.json) contains only public deployment data. Token and hook addresses, source commit and ABI hashes came from the pinned deployment. Canvas, router and seasons were discovered through `hook.canvas()`, `hook.router()` and `canvas.seasons()` and checked on mainnet. IMD, PoolManager, both public RPCs and wallet-add parameters came from the supplied deployment/network inputs. The ignored legacy `site/deployment.json` is not used by the new build.

| Contract | Robinhood Chain explorer |
| --- | --- |
| i/p token | [0x9aa7bef88c90d237b19afe77c8883ff119b606e7](https://robin.etherscan.io/address/0x9aa7bef88c90d237b19afe77c8883ff119b606e7) |
| PlaceHook | [0x512b15372f42f687d366fc0c3342267dc73120cc](https://robin.etherscan.io/address/0x512b15372f42f687d366fc0c3342267dc73120cc) |
| Canvas | [0xda4339c3b9a4e2d6e1cd7706b8419ccc7d112086](https://robin.etherscan.io/address/0xda4339c3b9a4e2d6e1cd7706b8419ccc7d112086) |
| PlaceRouter | [0x137182424e1b55819da5cf06c2c0a65284a0d558](https://robin.etherscan.io/address/0x137182424e1b55819da5cf06c2c0a65284a0d558) |
| Seasons NFT / auction | [0xd29e47e4c4c337cd4226dd523a73af398585d1dc](https://robin.etherscan.io/address/0xd29e47e4c4c337cd4226dd523a73af398585d1dc) |
| IMD | [0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127](https://robin.etherscan.io/address/0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127) |
| PoolManager | [0x8366a39cc670b4001a1121b8f6a443a643e40951](https://robin.etherscan.io/address/0x8366a39cc670b4001a1121b8f6a443a643e40951) |

ABIs in `site/abi.json` were compiled from source commit `4ba07cc1aa427c5cf5ca67f6a0494adf57222ec4` using the unchanged Foundry configuration. Both supplied canonical ABI hashes match. Runtime bytecode for all five imd/place contracts matches the compiled source after excluding compiler-reported immutable fields. The small `CustomRevert` ABI is compiled from the pinned v4 library and decodes wrapped hook errors. The ERC-20 read/approval interface for IMD uses the same standard ABI methods as PlaceToken.

At startup, chain ID, ABI hashes, all seven code hashes, initialization, pool key and child relationships must pass before transactions become available. Header and footer link every configured contract.

## Using the site

- **Canvas:** select colours and up to 50 distinct pixels. Inspect ownership, the active 24-hour repaint count and price. Use the zoom slider, Pan mode, drag, or arrow keys. Enter/Space selects the keyboard cursor; X/Y fields offer another keyboard path. Review the total before `paintWithLimit` fixes the maximum accepted cost.
- **Trading:** disconnected visitors can request quotes. Buy and sell use PlaceRouter's exact-input swap, displayed slippage minimum and a two-minute deadline. The current hook fee includes its launch decay; pool fee is 1.25%. Buys credit nontransferable paint. Sells keep paint unchanged. Wallet balances and exact token approvals are checked before submission.
- **Wallets:** EIP-6963 discovers MetaMask, Rabby, Coinbase Wallet and other injected providers, with a legacy injected fallback. Select a wallet, approve the switch to chain 4663, and add the chain if necessary. On phones, open the site in the wallet's own browser. Account/network changes invalidate the pending quote and clear account data.
- **Earnings:** see current pixels, trade fees claimable and lifetime IMD earned. Claim trading income, final-season payouts and outbid refunds separately. Season claims are split into at most 50 pixels per transaction and can be resumed after interruption.
- **Seasons:** the timer uses the latest chain timestamp. When due, anyone can freeze the canvas, resolving a previous unbid auction first if necessary. The latest auction shows its high bid and bidder; the gallery provides bids, settlement, winner/sale price and on-chain tokenURI artwork. Load older seasons to reach every past NFT.
- **Statistics:** paid IMD and the pot come from contract state. Paint credited and lifetime claims come from events, using publicnode first and the other supplied RPC when historical logs are refused. Indexing is paginated, cached locally with a block-hash checkpoint and delayed 12 blocks. Incomplete history is explicitly labeled. Earned rankings add paid claims, live claimable trade fees and unclaimed settled-season shares; quotes and ownership never rely on cached events.

Quotes are read-only `eth_call` simulations through the actual PlaceRouter. They temporarily override the input token's balance and allowance, verifying the storage locations through both token getters first. These overrides are never sent to a wallet or written on chain. Actual approval and transaction simulations use the visitor's real balances and allowances. A quote does not prove that the visitor owns the input tokens.

## Checks and actual results

```sh
# Production compilation and strict TypeScript checks
npm run --prefix web typecheck
npm run --prefix web build

# Install the test browser outside the repository
PLAYWRIGHT_BROWSERS_PATH=/tmp/imd-place-browsers \
  node "$IMD_TOOLCHAIN/node_modules/playwright/cli.js" install chromium

# Offline RPC/wallet fixtures against the actual dist export
PLAYWRIGHT_BROWSERS_PATH=/tmp/imd-place-browsers npm run --prefix web test

# Add browser checks against the public mainnet RPCs (read-only)
PLAYWRIGHT_BROWSERS_PATH=/tmp/imd-place-browsers IMD_LIVE_BROWSER=1 \
  npm run --prefix web test

# Optional repeat of source/runtime and required mainnet preflight checks
forge build --out /tmp/imd-place-forge-out \
  --cache-path /tmp/imd-place-forge-cache --skip test --skip script
IMD_FORGE_OUT=/tmp/imd-place-forge-out node tools/verify-live.mjs
```

The production build and strict typecheck passed. The complete Git bundle measured **1,446,117 bytes** in an isolated copy (plus a 65,536-byte reporting reserve), below the 8 MiB limit; the runtime export is **438,572 bytes**. [Size and asset hashes](docs/validation/submission.json). Browser validation covers selection limits, price inspection, buy/sell reviews, exact approval amounts, quote invalidation/expiry, wallet discovery/add/switch/account changes, contract errors, earnings/refunds, auction states, seasonal claims and responsive layouts. Fixture submissions are deliberately rejected, so tests never spend funds. Tests serve the export under `/place/` to catch absolute asset URLs.

The required mainnet preflight passed at block **83,235,842**: the canvas returned 4,096 bytes, pixel 0 cost **1 drop**, and season 1 ends **2026-10-15 09:44:30 UTC**. A read-only **1 IMD** buy returned **384,672.017936498385191288 i/p** and **20 paint drops** at a **2%** hook fee. An underfunded paint reverted with `InsufficientPaint` (`0x8e89355b`), mapped to actionable UI text.

The live sell check returned the hook's wrapped `PartialFill` error for the attempted 1 i/p sale. The site displays the liquidity limitation and leaves the transaction disabled; the fixture verifies sell calldata and slippage behavior. No successful live sell or funded wallet transaction is claimed. At validation the live canvas was blank, with no completed season; NFT, bid, settle and season-claim states were validated with isolated fixtures.

See [the consolidated validation and six-domain review](docs/WEBSITE_VALIDATION.md), [mainnet evidence](docs/validation/mainnet-verification.json), [browser results](docs/validation/browser-validation.json), and the [implemented design](DESIGN.md). Test results are worker observations, not independent certification. Native wallet apps, screen readers and actual funded confirmations remain unverified. The provided browser connector lacked its executable; checks instead ran against the production export using locally installed Playwright Chromium.

## Contract project and licenses

The Solidity implementation and its existing build/dependency files are unchanged. [Contract behavior](docs/CONTRACTS.md), [prior verification](docs/VERIFICATION.md) and [independent review](docs/INDEPENDENT_REVIEW.md) retain the previous project's context. Contract tests were not rerun for this website-only change; a fresh source build was used to derive and verify ABIs/runtime bytecode.

The project [LICENSE](LICENSE), local font and ethers notices remain included. Better Interface design guidance (Jakub Krehel, MIT) and the adapted Impeccable documentation method (Paul Bakaus, Apache-2.0) are attributed in [docs/INTERFACE_LICENSE.txt](docs/INTERFACE_LICENSE.txt) and the design/review documentation.
