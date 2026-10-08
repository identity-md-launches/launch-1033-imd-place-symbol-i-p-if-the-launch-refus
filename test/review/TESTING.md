Tests-only review, 2026-10-08. Production contracts, dependencies, launch settings,
and existing tests were retained. The requested accepted bundle was downloaded and
its SHA-256 matched `624e4be3dda1c33c6258619a53a63170bebcefca7c0890da5dcd5fa2a34cfac0`.
Its accepted commit is `5136de402279c7d7e8f86bcf355446470d73fd34`.
Every current production Solidity file matches that bundle except `Seasons.sol`,
which already contained the prior contributor's pull-refund repair.

| Added coverage | What a failure would reveal |
| --- | --- |
| `BoundaryFailures.t.sol` | Failed late batch entries changing earlier owners, checkpoints or drops; failed claim batches burning bitmap rights; bid-transfer failure changing refunds/deadlines/escrow; rounding or deadline errors |
| `HookBoundaries.t.sol` | Misallocated launch premium; wrong recipient when caller differs from origin; paint-threshold or rollover loss; replayed payment callbacks; incorrect pool binding; malformed buyer data accepted; invalid swap inputs spending funds |
| `LifecycleInvariant.t.sol` | Unbacked fee credits, missing or duplicated pot obligations, incorrect refunds, excess claims, paint creation/loss, altered frozen ownership, wrong NFT recipient, or liabilities that cannot actually be withdrawn |
| Additional Robinhood fork test | Exact-output swap settlement, self-outbid refund, PoolManager claim redemption into a frozen pot, or final artist settlement failing against the deployed manager and IMD |

The lifecycle handler uses the production hook, router, canvas and seasons with a
real local v4 PoolManager. Four funded actors perform all four swap modes, paint,
advance time, freeze seasons, bid, finalize, withdraw refunds and claim fees or
auction proceeds in random order. Eight pixel IDs include bitmap boundaries
255/256 and the last canvas pixel. Campaigns cover up to eleven frozen seasons.
No production storage is edited and fees/paint enter through swaps. The focused
canvas unit tests instead use a funded fee-source fixture to isolate accounting.

Independent cash-flow ghosts reconcile hook ERC-6909 claims and season-token
balances against bids, released pots and actual withdrawals. Retained fee backing
must equal unpaid artist allocation plus treasury credit plus current/frozen pots.
An ownership/window history model checks live and frozen pixels, ranks and counts.
Actor paint balances equal buy credits less modeled paint costs. Refunds plus
active bids plus remaining finalized awards must equal escrow exactly.

Each campaign starts with reachable funded and unbid auction histories, including
self-outbids and overlapping auctions. It ends by advancing time, finalizing every
remaining auction and withdrawing every matured refund and artist award. Auction
escrow must then be zero. Early returns in the random handler are limited to
unsatisfied action preconditions; unexpected reverts fail the campaign. The
separate unit tests assert specific failures and transaction-wide rollback.

Run counts travel with the tests through inline configuration: 256 invariant runs
of 64 calls, with failure on unexpected revert; 1,000 cases each for minimum-raise
rounding and launch-decay allocation. Existing repaint-accumulator fuzz tests,
reentrancy tests, dense metadata checks and fresh token-only pool tests remain.

Local verification used Foundry 1.8.3 and the project's Solidity 0.8.26 compiler:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge build --offline
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache forge test --offline
```

Build succeeded. The complete offline run reported **52 passed, 0 failed, 1 skipped**.
Foundry groups each contract's invariants as one result and reports the skipped
fork setup as one result. The new lifecycle campaign completed **16,384 random
handler calls with zero reverts**, followed by its withdrawal checks.

Both fork tests passed, with zero failures or skips:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
  forge test --offline --match-contract RobinhoodForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 83204458 --no-storage-caching -vv
```

Recorded chain ID: **4663**. Block hash:
`0xaaa5e7a6997e7ad019055aac3679e51c5f1d9550790342ce028c2f8611e65e58`.
The fork uses the existing manager fixture
`0x8366a39CC670B4001A1121B8F6A443A643e40951` and the supplied IMD address
`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`; setup checks deployed code and
IMD metadata. Trading balances are synthetic and the tested hook is deployed
locally on the fork. These checks do not attest a public deployment. Historical
repetition requires an RPC retaining this block. Offline verification skips the
fork cleanly; delivered tests have no dependency on scratch files or downloads.

No additional reproducible contract defect was found in this bounded review, so
no finding proof is submitted. The protected inputs were read as acceptance
criteria; their separate environment-driven attestation harness was not rerun
in this test-only change. Existing contract lints remain visible during build.
