# imd/place

A 64×64 on-chain pixel war on a Uniswap v4 hook, paired with IMD. Buying i/p earns non-transferable paint. Current pixel owners share trade fees; each weekly canvas becomes a fully on-chain ERC-721 and an IMD auction.

Restored from the exact accepted [bundle](https://api.imd.fun/bundles/624e4be3dda1c33c6258619a53a63170bebcefca7c0890da5dcd5fa2a34cfac0), commit `5136de402279c7d7e8f86bcf355446470d73fd34`, from job `834c0e87-f40c-4a5d-9935-03d865b034ec`. The accepted logic is preserved except the reviewed auction refund repair: refunds are now pull-based as this brief requires. The supplied pool values are in root [launch.json](launch.json).

This repository contains the launch token, hook, router, canvas, season NFT/auction, static website, vendored dependencies, tests, and a renewed independent review. **It has not been broadcast to Robinhood Chain or published to a public host.** The launch network must deploy its standard token/pool and publish the resulting addresses. No live-address file, signing key, or hosting credential was supplied. The site deliberately displays “Launch pending” until the verified deployment configuration exists.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 tools/export-abi.py
node --check site/app.js
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, via-IR, `bytecode_hash = "none"`. No FFI, filesystem cheatcode permissions, environment-dependent tests, compiler binary, submodule, npm install, or CDN is needed. Dependencies are ordinary files in `lib/` and `site/vendor/`; exact upstream revisions, the small test-library compatibility backport, and asset hashes are recorded in `dependencies.json` and `site/vendor/provenance.json`. Foundry installs the version-pinned compiler separately.

Default tests are offline. The Robinhood fork suite explicitly skips unless a chain-4663 fork is selected; it never reports that skip as a successful fork. To repeat the recorded rehearsal:

```sh
forge test --match-contract RobinhoodForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 83190389 -vv
```

The public RPC can prune old state. Repeating a historical block requires an archive-capable RPC; otherwise select and record a fresh block. The resumed implementation passed at block **83,190,389**; the earlier accepted-bundle rehearsal remains recorded separately.

See [verification](docs/VERIFICATION.md) and the separate [independent revision review](docs/REVISION_REVIEW.md). Tests exercise success, failure, callback forgery, malicious token callbacks, pull-refund isolation and withdrawal rollback, exact escrow conservation, both token orderings, the first buy with token-only liquidity, fuzzed repaints, and stateful claim/fee invariants.

## Contracts and deployment parameters

| Contract | Deployment | Responsibility |
|---|---|---|
| `PlaceToken` | No arguments; launch factory deploys | Name `imd/place`, symbol `i/p`, 18 decimals, exactly 1,000,000,000 tokens minted to its deploying factory. Standard transfers and allowances only. |
| `PlaceHook` | `(IPoolManager $poolManager, address $token, address $factory)` | Bind the launch pool once, charge IMD fees, mint backing claims, credit paint. |
| `Canvas` | Created by the hook constructor | Packed pixels, paint, trade rewards, season snapshots. Discover with `hook.canvas()`. |
| `Seasons` | Created by the canvas constructor | ERC-721 metadata, auctions and final-owner payouts. Discover with `canvas.seasons()`. |
| `PlaceRouter` | Created by the hook constructor | User-funded, slippage-limited single-pool swaps. Discover with `hook.router()`. |

There is **no owner, admin, upgrade, pause, rescue, arbitrary execution, transferable paint, or post-construction configuration power** in these production contracts. ERC-721 `ownerOf` means ordinary NFT ownership, not protocol administration. The factory has only the one-time right to initialize the hook's pool.

The hook accepts the launch factory's pool with its standard **12500 / 1.25% LP fee**. It learns IMD from the non-launch-token side of that pool, queries its decimals, and starts the launch clock at initialization. Only the supplied factory can perform that binding through PoolManager. Root launch.json pins the supplied IMD pair to **0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127**, tick spacing **60**, and initial sqrt price X96 **79228162514264337593543950336** (1:1 raw units). PoolManager and factory remain launch-resolved arguments. The site configuration tool compares the exact paired address; a symbol alone is not an authenticity check. The hook accepts ERC-20 pair decimals from 2 to 36; the requested deployed IMD has 18.

Hook permission bits are **8396 / `0x20cc`**: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. All other bits are false. Every enabled callback requires PoolManager; every swap callback requires the one bound PoolId. The constructor validates its address bits. No LP fee override or custom AMM curve is used.

The deployment manifest is [launch.json](launch.json), using the published schema and pool settings of live launch #1015. The companion [deployment recipe](deployment/launch-recipe.json) records automatic child discovery. The launch service resolves `$poolManager`, `$token`, and `$factory`, uses the explicit pool values and standard liquidity policy, and initializes immediately after deployment. Its create2 deployer address and salt convention must match the actual deployment path. A salt helper is provided:

```text
node tools/mine-hook.mjs CREATE2_DEPLOYER POOL_MANAGER LAUNCH_TOKEN LAUNCH_FACTORY [START_SALT]
```

Arguments are real, resolved addresses; there are no literal PoolManager addresses in production source or deployment tools. The returned salt, predicted address, constructor arguments, flags and initcode hash are reviewable. The helper sends no transaction. Token addresses and constructor arguments affect the mined address, so mine again if any changes. All production runtime sizes fit EIP-170; hook initcode, including automatic child deployments, fits EIP-3860. The exact `i/p` symbol is implemented because no slash rejection has been observed; changing to the allowed `IP` fallback requires rebuilding, retesting and remining before launch.

## Paint and canvas rules

- A buy credits `floor(total IMD spent / 0.05 IMD)` drops in `afterSwap`. The spend includes the hook fee. Fractional drops round down separately per buy. Sells neither credit nor consume paint.
- Our router always encodes its actual caller in hookData. Nonempty data from another router is rejected. With empty data, `tx.origin` selects the paint recipient only; it grants no spending or claim authority. Smart wallets should use our router to receive their paint directly.
- Paint never expires and cannot transfer. `paint` accepts 1–50 distinct indices (row-major `y*64+x`) and palette indices 0–15. Duplicate indices, unequal arrays, insufficient paint, invalid colours/coordinates and expired canvases revert atomically.
- Each pixel uses one 256-bit slot: owner160, colour8, paints32, windowStart40 and insertionRank16. An empty pixel costs 1. In a fixed 24-hour window starting with its first paint, subsequent cost is `2^min(paints,10)`. At the exact expiry, the price becomes 1 and a new window begins on its next paint. Ownership changes do not restart a live window. A season reset does.
- The site uses `paintWithLimit` to reject a frontrun that increases the quoted batch cost. `paint` is the requested unconstrained alternative.
- A palette is stored in Canvas and shared with the renderer/site. Empty pixels are encoded as `0xff`; palette colour zero remains a real paint colour.

## Fees, rewards and backing

The hook charges **2% in IMD**, on top of the pool's LP fee. The first 30 minutes linearly decay from 3500 to 200 basis points, floored to integer basis points. The baseline fee is `floor(grossIMD * 200 / 10000)`. Artists get `floor(baseFee*67/100)`, treasury gets `floor(baseFee*8/100)`, and the season pot receives all remaining charged fees, including the launch premium and indivisible split remainder. With no owned pixels, the artists' share also goes to the pot. The treasury is fixed to **0xA7e99BB7155D7477E0C838E201b16E62B9c0b5Ac**.

| Swap | IMD fee handling |
|---|---|
| Exact-input buy | Reserve the fee from specified IMD input in beforeSwap; remaining input reaches the AMM. |
| Exact-output buy | Add a grossed-up fee to actual IMD input in afterSwap. |
| Exact-input sell | Deduct the fee from actual IMD output in afterSwap. |
| Exact-output sell | Gross up specified net IMD output in beforeSwap so the requested output remains exact. |

Buys measure gross total IMD spend; sells measure gross IMD proceeds. Gross-ups round up to cover the fee. **IMD-specified swaps must fill completely**: afterSwap reverts a partial fill because that side's beforeSwap delta cannot be refunded through afterSwap's unspecified delta. Exact-output router swaps also require the requested output; exact-input sells may partially fill and refund unused input. Every router call supplies a nonzero minimum output / maximum input, a price boundary, and a deadline.

The router pulls only from `msg.sender` before unlocking; the unlock callback has no `transferFrom`, user-provided payer or arbitrary pool. It settles only the current caller's prepaid budget, verifies exact PoolManager settlement, returns output to that caller and refunds unused input. Both assets are the launch's fixed standard ERC-20s; rebasing and fee-on-transfer assets are outside the supported launch configuration. Unsolicited donations have no withdrawal endpoint.

Each fee mints an **IMD ERC-6909 claim** to the hook in the same swap. This works on a fresh manager before its input tokens have settled; the entire unlock reverts unless all deltas settle. Accounting is immediately credited to the proper beneficiaries. `Canvas.claim()` redeems only the caller's earned amount; anyone may call `claimTreasury()`, but payment always goes to the fixed treasury. Fees remain denominated in IMD as requested; no ETH conversion is performed.

Artist earnings use a `1e24` scaled global accumulator per occupied pixel. Counts and checkpoints settle on every ownership change. Old-season accumulator endpoints retain unclaimed earnings even across multiple skipped seasons. Sub-wei personal credit remains after claiming; division remainders are carried forward. Whole-unit artist claims can never exceed artist fees received. Minimal fractional dust stays reserved for artists and has no sweep function.

## Seasons and auctions

The first season starts with pool initialization. Painting stops at exactly seven days. Anyone then calls `endSeason()`; its image and ownership records become immutable, it mints the 1/1 to Seasons, and a new empty canvas starts immediately. Fees continue to accrue to the currently held pixels until the actual freeze transaction, even if it is late. A delayed freeze starts the next full seven-day window at that transaction.

The NFT uses on-chain base64 JSON and an on-chain SVG with crisp edges, the required season name, external URL and numeric season/painters/paints attributes. Unique painters and total successful pixel paint actions are recorded per season. The SVG combines horizontal runs by colour. A worst-case alternating canvas is regression-tested under a 32M gas call; public RPC calls must allow **at least 35M gas (50M recommended)** for dense `tokenURI`. Image loading failures do not prevent bids, finalization or claims.

Auctions last 24 hours from the actual freeze. First bid minimum is one atomic IMD unit; later bids require the previous amount plus `ceil(previous/20)`. A bid in the last ten minutes extends the existing deadline by ten minutes. An outbid amount is immediately credited to `pendingRefunds[bidder]`, including self-outbids. `withdrawRefund()` pays only the caller, at any time before or after finalization. A replacement bid escrows the whole new amount; it never calls the previous recipient. A failed refund withdrawal preserves its credit and cannot block new bids or finalization. The site shows all pending bid refunds and a Withdraw button.

Anyone finalizes after the deadline. A winning NFT transfers directly to the bidder without an ERC-721 receiver callback, so a rejecting receiver cannot hold up artists' settlement. Bidding contracts must be able to manage their own NFT custody. Normal ERC-721 approvals and transfers are available after award. The winning bid and frozen pot are reserved to the final pixel owners, regardless of subsequent NFT ownership.

Claims accept at most 50 frozen pixel IDs. Each pixel gets `floor((pot+bid)/occupied)` atomic units; the first `(pot+bid)%occupied` insertion ranks get one extra. Thus complete claims sum **exactly** to pot + bid, with no administrator, last-claimer sweep or dust lottery. The bitmap rejects repeats, including duplicates within one call. `totalEscrow` covers outstanding bids, pending refunds and unclaimed payouts across every auction and is checked against actual IMD holdings after transfers.

Without a bid, the NFT goes to the painter with the most successful pixel paint actions (ties remain with the first to attain the leading count), and the pot rolls to the immediately following season. **Before closing that next season, an unresolved prior unbid auction must be finalized.** This prevents callers delaying an old pot into a season of their choosing. The site handles the required public finalization before submitting endSeason; no privileged keeper is needed. A completely blank season has no eligible painter: bidding is disabled, its NFT remains in season escrow, and its pot carries on finalization. No substitute recipient is invented.

## After launch

1. The launch operator resolves the constructor placeholders, confirms canonical PoolManager and IMD on chain 4663, deploys through the launch, initializes at the manifest's fee, spacing and price, and seeds its standard liquidity. Verify the hook flags, compiler settings, deployed runtime, constructor arguments, pool key and child addresses on the explorer. Independently review the final launch manifest and transaction simulation.
2. Export ABIs from this exact build, then run `node tools/configure-site.mjs RPC_URL DEPLOYED_HOOK [EXPLORER_URL]`. It checks chain ID, initialization, the exact manifest pair, token metadata and supply, hook address flags, code presence, the complete pool key and both directions of child contract relationships, and creates `site/deployment.json`. The script rejects a substitute pair even if it uses the IMD symbol. Initial price is a launch-time setting; it is not compared to the current price after trades. The file contains public data only.
3. Publish the complete `site/` directory to the launch's chosen HTTPS static host. Nothing needs bundling or a server-side wallet. Header/footer explorer links are generated for the token, hook, router, canvas, seasons, IMD and PoolManager. Serve the generated configuration with no long-lived cache and use an RPC permitting browser CORS and large metadata reads. For local preview: `python3 -m http.server 8877 --directory site`.
4. Anyone can end seasons, finalize auctions, claim treasury fees or relay these public maintenance transactions. Users individually claim trade and frozen-season earnings and withdraw their outbid refunds. There is no automatic off-chain scheduler in this repository and no maintenance reward; public operators bear transaction gas.
5. Monitor RPC availability, the season/auction deadlines, fee-claim backing and configuration integrity. The contracts themselves have no recovery controls. The external IMD issuer can restrict transfers; its `transfersEnabled`/blocklist powers can stop swaps, refunds or payouts. The Robinhood sequencer can also affect availability. These external powers are not administration of imd/place.

The renewed separate contributor review is recorded in [docs/REVISION_REVIEW.md](docs/REVISION_REVIEW.md); it is not a claim of a professional audit or permission to skip the network's final independent deployment review.
