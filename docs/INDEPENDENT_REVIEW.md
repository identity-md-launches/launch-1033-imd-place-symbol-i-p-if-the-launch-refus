# Independent implementation review

Historical record from the accepted bundle. Its push-refund description is superseded by the pull-refund implementation and [revision review](REVISION_REVIEW.md).

Reviewed on 2026-10-08 by a separate review agent that did not write or modify the production contracts. This is a bounded source review and independent regression exercise, not a professional audit, formal proof, production deployment attestation, or Robinhood fork result.

## Scope and outcome

Reviewed `PlaceToken`, `PlaceHook`, `PlaceRouter`, `Canvas`, `Seasons`, and their interface boundaries against the supplied behavior and prior static-analysis findings. Also examined the vendored v4 `Hooks`/`PoolManager` delta accounting and OpenZeppelin transfer/guard behavior used by the implementation. The dependencies themselves were not comprehensively audited.

No unresolved critical, high, or medium security finding was identified in this bounded review after the repairs below. All nine independent regression tests passed, including 256 randomized runs of a 100-step ownership/fee model and real-PoolManager execution of all four swap modes in both currency orders at both fee endpoints. This does not establish absence of vulnerabilities.

## Finding repaired during review

**R1 — delayed no-bid finalization could choose a later pot beneficiary season (medium).** Initially, `Canvas.rollPot` credited whatever season was current when an unbid auction was finalized. A season-1 pot could remain pending while season 2 froze, then be moved into season 3. That changed the intended recipients from the immediately following season to a season chosen through transaction timing.

The implementation now prevents `endSeason()` from freezing a season until its preceding unbid auction is resolved. `Seasons.rolloverResolved` permits advancement if the previous auction was finalized or has a bid, whose payout recipients are already fixed. Consequently an unbid pot must reach season N+1 before N+1 freezes. Anyone can perform the required finalization; no administrator is introduced. The independent regression waits 20 days, verifies advancement reverts with `PreviousAuctionPending`, finalizes the old auction, and verifies the combined pot is frozen specifically into season 2. Normal operation may require two maintenance transactions, `finalize(previous)` followed by `endSeason()`.

**R2 — dense NFT metadata resource cost (availability, resolved with an operational limit).** An independent performance probe painted all 4,096 pixels with alternating palette colours, froze the canvas, and called `tokenURI` in a fresh test call. The initial renderer consumed 79,931,608 gas and returned 295,717 bytes. This can exceed RPC call limits or the budgets of on-chain metadata consumers even though a high-gas local call succeeds.

The repaired renderer groups runs into at most 16 coloured paths, reads packed pixel storage directly, and writes bounded coordinate commands without per-run string allocation. The same independent probe measured 30,471,222 gas and 99,877 bytes for `tokenURI`, and 19,790,639 gas for `svg`. The final submitted regression passed its 32-million-gas staticcall cap, measuring 30,394,991 gas with the final compilation. Independent XML/path parsing checked every one of the 4,096 expected pixel positions and colours, with no overlap or omission. Assembly bounds were reviewed: each rectangle writes at most 15 bytes into 18 bytes reserved per counted run; x/y are at most 63 and width at most 64. Packed colour reads write exactly 4,096 bytes and use the correct owner/colour bit positions. RPC providers serving the gallery need at least a 35-million-gas `eth_call` allowance; 50 million gives operating headroom. This rendering cost still makes dense metadata unsuitable for ordinary on-chain composition.

## Prior rejection and accounting checks

- **Arbitrary allowance spending:** the router's only `transferFrom` pulls from `msg.sender` into its own escrow before calling `unlock`. The callback has no supplied payer and only transfers the router's existing escrow to the manager. A manager-only check plus a one-use hash binds the callback to the in-progress request. Amount limits and the reentrancy guard prevent spending a preceding caller's escrow. The previous callback-level `transferFrom(r.payer, ...)` path is absent.
- **v4 fee signs:** positive hook deltas charge the IMD side. Exact-input buys and exact-output sells use the specified delta in `beforeSwap`; exact-output buys and exact-input sells use the unspecified delta in `afterSwap`. Gross-up rounding is tested for exact-output modes. Unsupported partial fills on the specified IMD side revert atomically. Fees are minted as ERC-6909 claims, so recording a fee does not require a prefunded IMD manager balance.
- **Accrued trade earnings:** owner accounts settle against the global per-pixel accumulator before ownership counts change. A final accumulator is retained per season, so inactive accounts can recover old accrual after multiple skipped seasons. Independent tests use direct per-pixel credit accumulation, rather than the production account-checkpoint algorithm, and check every intermittent/final claim and the aggregate fee budget.
- **Frozen auction rights:** frozen pixels retain their owners and unique occupied ranks. Payout is the integer quotient per occupied pixel, with the remainder assigned once to the first ranks. This makes aggregate claims equal the pot plus winning bid. The claimed bitmap blocks duplicate claims; a repaint in the next season does not change frozen rights.
- **Auction escrow coverage:** `totalEscrow` tracks all outstanding bids and unclaimed finalized payouts. Outbidding adds the new amount and removes the refunded bid, finalization adds only the newly transferred pot, and claims deduct their amount before transfer. Post-transfer balance coverage prevents one auction from consuming another auction's recorded liability. A regression exercises two concurrent funded auctions, staggered finalization, and full claims.
- **Reentrancy and asset movement:** state is debited/finalized before outbound transfers; public fund-moving paths are guarded. Hook fee redemption is callable only by the canvas and requires an authenticated unlock callback. Auctions mint to escrow and use ERC-721 internal transfers at settlement, avoiding an arbitrary receiver callback that could block artists. There is no owner, upgrade, pause, sweep, or discretionary withdrawal path in the project contracts.
- **Integer/time checks:** base-fee split truncation occurs in atomic IMD units; its residual goes to the pot. The scaled accumulator carries division remainder without creating additional fees. Timestamps implement the requested decay, windows, season length, and auction deadlines; they are not randomness sources. Stateful zero/equality checks identify unopened auctions, zero fees, exact manager settlement, and complete fills. Auction token solvency is checked against aggregate liabilities rather than a stale balance snapshot.

## Independent test coverage

The submitted tests are in `test/review/` and run with Solidity 0.8.26 and the repository Foundry settings:

```sh
forge test --match-path 'test/review/*.t.sol' -vv
```

| Test | Observed result |
| --- | --- |
| Per-pixel reference model, repeated repaints/fees/claims across seasons | 256 runs passed, 100 steps each |
| Delayed no-bid rollover cannot choose a later season | Passed |
| Frozen owners, duplicate-claim rejection, exact payout remainder | Passed |
| Old fee accrual survives four skipped seasons | Passed |
| All four swap modes, IMD as currency0, 35% and 2% | Passed |
| All four swap modes, IMD as currency1, 35% and 2% | Passed |
| Dense 4,096-run NFT metadata resource limit | Passed 32M cap; final measurement 30.39M |
| Packed colour extraction for all 4,096 pixels | Passed |
| Concurrent auction escrows, staggered finalization and claims | Passed |

The swap suites additionally check buy-only paint issuance, amount-based fee formulas, zero router residue, and equality between outstanding hook claims and recorded fees. Production contract runtime/initcode sizes were below EIP-170/EIP-3860 limits at review time. The integration fixture uses the real vendored PoolManager, with test tokens and local state.

## Remaining boundaries and operational assumptions

- IMD must be the launch-selected, conventional ERC-20 with reliable balances and decimals. Transfer-tax, rebasing, censorship, malicious token callbacks, or an arbitrary substitute pair token are not certified. The launch factory controls the one-time pair initialization; the project contracts have no later configuration authority.
- A blank season has no final pixel owner or top painter. Its NFT remains in escrow and its pot rolls forward. A nonblank no-bid NFT goes to the painter with the most paint operations; ties retain the first painter to attain that count.
- Atomic-unit remainder assignment and sub-atomic scaled accounting are rounding rules. Very small historical fractions can remain below a claimable atomic unit. Unsolicited asset transfers are not recoverable through a sweep.
- `endSeason` and auction finalization are permissionless but require someone to submit transactions. Painting stops at the season deadline until the freeze is executed. The prerequisite needed for deterministic no-bid rollover must be exposed by the site and keeper documentation.
- This review did not broadcast transactions, validate live addresses, test a Robinhood RPC fork, inspect site rendering, or perform a formal verification. Central repository checks and fork/deployment results must be reported separately. No production-readiness claim follows from this document alone.
