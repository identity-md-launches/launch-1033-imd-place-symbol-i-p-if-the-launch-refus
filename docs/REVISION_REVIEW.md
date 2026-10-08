# Independent review of the resumed launch

Reviewed on 2026-10-08 by a separate agent that did not modify production contracts. This review covers the restored accepted project and the current refund repair. The earlier [implementation review](INDEPENDENT_REVIEW.md) remains a historical record. This is a bounded source review and regression exercise, not a professional audit or live deployment attestation.

## Finding and repair

**R3 — an outbid recipient could block further bidding (medium; repaired).** The restored `Seasons.bid` transferred the previous bid directly to the previous bidder. A failed IMD transfer reverted the replacement bid. This contradicted the current brief's explicit pull-refund requirement and exposed auctions to a previous bidder whose address the external IMD token refuses to receive transfers for. The original `testRefundFailureRollsBackNewBidAndEscrow` demonstrated that behavior.

The repaired path credits `pendingRefunds[previous]` and receives the new bid without calling the previous recipient. Each bidder withdraws its own credit through `withdrawRefund()`. Credits are cleared and aggregate liabilities reduced before the transfer; the reentrancy guard covers this path. A failed withdrawal reverts only that transaction, restoring its credit. Self-outbids leave the previous bid withdrawable while escrowing the whole replacement bid.

`totalEscrow` now includes live bids, outstanding refund credits and finalized artist payouts. It increases by each complete new bid, increases by a released season pot, and decreases only by a refund withdrawal or artist claim. The balance-coverage check therefore continues to reserve every obligation across concurrent and successive seasons.

## Independent validation

The new [PullRefundAccounting.t.sol](../test/review/PullRefundAccounting.t.sol) uses a separate liability model over three seasons, each with 24 randomized bids. It covers repeated bidders, self-outbids, immediate and delayed withdrawals, credits retained into later seasons, auction finalization, exact remainder allocation to frozen artists, and repeated empty withdrawals. After every operation it compares all four refund balances, aggregate liabilities and the season contract's actual IMD holdings. Every run finishes with all modeled obligations paid and zero remaining escrow.

`forge test --match-path 'test/review/*.t.sol' -vv` passed **10 tests, 0 failures, 0 skips**, including 256 runs of the new refund test and 256 runs of the existing 100-step ownership/fee model. Existing independent tests also exercised all four swap modes in both currency orders, delayed unbid-pot rollover, retained earnings across skipped seasons, concurrent auction pots, frozen ownership and dense metadata. Dense `tokenURI` measured 30,395,035 gas and 99,877 output bytes under its 32-million-gas test cap.

Source review covered manager-only callbacks, router-bound buyer data, the specified/unspecified IMD delta signs, claims backing, immutable cross-contract authority, repaint accounting, season snapshots, auction transitions and NFT custody. No additional unresolved critical, high or medium finding was identified in this bounded review. No owner, admin, upgrade, pause, arbitrary asset rescue or paint transfer endpoint was found.

## Deployment checks

The current root `launch.json` names chain 4663, the requested IMD address, fee 12500, tick spacing 60 and initial price `79228162514264337593543950336`. Its hook constructor arguments are `$poolManager`, `$token` and `$factory`; its five declared permissions sum to 8396 and agree with the source. The callback accepts the factory's initialization with these terms and binds the one pool. Manifest values were compared programmatically with the brief; this is not a launch-service admission result.

With the pinned Solidity 0.8.26 configuration, current artifact sizes are:

| Contract | Runtime bytes | Initcode bytes including constructor arguments |
| --- | ---: | ---: |
| PlaceToken | 1,503 | 2,453 |
| PlaceHook | 5,727 | 34,029 |
| PlaceRouter | 3,748 | 4,103 |
| Canvas | 9,842 | 23,222 |
| Seasons | 11,682 | 12,702 |

All five fit EIP-170 and EIP-3860, including the hook's embedded child creation code. A PUSH-aware scan of these runtime artifacts found no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` instructions.

## Limits and operational assumptions

The fixed IMD pair is assumed to maintain the standard balances and transfer amounts checked by the fork rehearsal. Its external transfer restrictions may still prevent a particular user withdrawing or receiving a payout; the refund repair ensures that recipient cannot prevent a new bid. A global IMD transfer restriction remains outside these immutable contracts' control.

Season closure, auction finalization, individual claims and refund withdrawals require public transactions. Unbid pots must be rolled into the immediately following season before it freezes. Empty seasons have no eligible top painter, so their NFTs remain in escrow and their pots carry forward. These documented policies were preserved from the accepted implementation.

The dense SVG renderer remains unsuitable for small-gas on-chain composition; the site's RPC must support the documented large metadata calls. This reviewer did not publish a site, broadcast transactions, independently rerun Slither, or repeat the Robinhood fork. Current whole-project and fork results belong in the primary contributor's verification record. Launch-service simulation, live contract verification and configuring the site from real deployed addresses remain separate deployment checks.
