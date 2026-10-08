# imd/place contract behavior

Retained from the accepted contract project. The website change does not modify any contract or build configuration. Live addresses and verification are documented in the root README.

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


The earlier source reviews remain in VERIFICATION.md, REVISION_REVIEW.md, and INDEPENDENT_REVIEW.md in this directory.
