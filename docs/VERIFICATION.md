# Verification of the resumed launch

This record covers the resumed implementation from the exact accepted bundle; [ACCEPTED_VERIFICATION.md](ACCEPTED_VERIFICATION.md) preserves the earlier job's evidence. Checks use Foundry 1.8.3, Solidity 0.8.26 and the unchanged accepted `foundry.toml` / `remappings.txt`.

## Changes from the accepted bundle

- Added root `launch.json` using the published launch #1015 manifest schema and the four pool values supplied in this task. The companion recipe agrees with it. `$poolManager`, `$token` and `$factory` remain deployment placeholders; no guessed deployed addresses are committed.
- Replaced push refunds with immediately withdrawable bidder credits, included those credits in aggregate auction escrow, added the site's refund balance and withdrawal action, and exported the updated ABI.
- Made site configuration validate the supplied paired-currency address, complete pool key, token metadata/supply, hook address flags and child relationships.
- Browser integration found stale post-transaction reads: a polling refresh could discard a requested ownership refresh, and the RPC client could reuse a recent latest-state response. Refreshes now serialize, latest reads bypass that short cache, and selected-pixel information updates after transactions.
- Backported upstream `forge-std`'s `fail(string)` overload into the accepted v1.9.6 copy. The supplied hook protected test calls this overload, absent from that version. It calls `fail()` and `vm.assertTrue(false, message)`; no assertion or protected input was relaxed. The patch is recorded in `dependencies.json`.

Bundle and manifest provenance is in [deployment/provenance.json](../deployment/provenance.json). The five production contracts retain their accepted architecture, authorities and economics; the only production Solidity change is in `Seasons` refund accounting.

## Current checks

| Check | Result |
| --- | --- |
| `forge build` and `forge build --sizes` | Passed; production runtime and initcode fit EIP-170 / EIP-3860 |
| `forge test -vv` | 37 passed, 0 failed, 1 explicitly skipped opt-in fork suite |
| Stateful invariants | 64 runs × 64 calls; artist allocation and exact hook backing hold |
| Independent retained tests | 10 passed, including 256 randomized 3-season × 24-bid refund traces |
| Exact pinned protected tests | 11 passed, 0 failed, 0 skipped: 4 hook + 7 token |
| Robinhood fork buy/sell/redeem | 1 passed, 0 failed, 0 skipped at block 83,190,389 |
| `forge fmt --check` | Passed |
| JavaScript syntax | Site and both deployment utilities passed |
| Site configuration | Local chain-4663 fixture accepted; substituted pair rejected |
| Chromium desktop/mobile integration | Connect, quote/approval/buy, paint, season closure, SVG gallery, auction bid, outbid credit display and withdrawal passed; no page exceptions or 390px overflow |

The original protected inputs were copied without modification into a disposable project under `/tmp`, with the actual compiled hook/token creation bytecode, declared flags 8396, the supplied pool parameters and locally constructed manager/token/factory probes. Its environment inputs belong to the pinned protected harness; delivered tests neither set nor read environment variables. The protected checks are an additional local reproduction, not an independent launch-service admission decision.

The refund regression tests cover self-outbids, independent withdrawal authority, immediate withdrawals, repeated withdrawals, refund credits held across seasons, exact escrow conservation, reentrancy rejection, and a blocked recipient whose failing withdrawal cannot prevent a new bid or finalization. The independent model verifies every modeled liability and token holding after each operation. All prior fee/paint/repaint/season/payout tests remain included.

## Robinhood fork evidence

RPC: `https://rpc.mainnet.chain.robinhood.com`; chain **4663**; block **83,190,389**; hash `0x7b6f6700c14a69876da11490a30843b6ca5c14d65e0764ae624d04806b81cb47`. The block RPC parameter was generated from its decimal value and the returned `number` was converted back and checked. Both real external contracts had code at that block; the fork checks IMD symbol and decimals.

```sh
forge test --match-contract RobinhoodForkTest \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 83190389 -vv
```

The fork deploys a new local token and mined hook/children, initializes its own pool, buys and sells through Robinhood's real PoolManager, redeems artist/treasury fees and reconciles backing. Its trading/liquidity balances are synthetic. The test does not broadcast or certify a production factory transaction. The public RPC may prune this block; repeat with an archive RPC or record a newly verified block.

The browser test used unlocked local Anvil accounts and injected a temporary deployment response. No local configuration was written into the delivered site. It also verified all seven explorer links in both header and footer. Browser tooling was used for verification only; the delivered site uses its existing vendored ethers/font assets and needs no build or network dependency installation.

## Review and deployment boundary

The separate [revision review](REVISION_REVIEW.md) found no further unresolved critical, high or medium finding after the refund repair. It records size checks and a PUSH-aware scan excluding escape-hatch opcodes in all five production runtimes. This is a bounded source review, not a professional audit or proof.

Slither was not installed or rerun in this resumed task. `static-analysis.json` is retained historical evidence from the accepted job; its push-refund-era results do not attest the current repair. Forge's build lints still report intentional timestamp comparisons, bounded casts, renderer assembly and guarded external calls; they were not disabled.

No public-chain transaction was broadcast and no public site was hosted from this workspace. The launch service must deploy using `launch.json`, verify its receipt/runtime/pool/child addresses, run `tools/configure-site.mjs` on the real hook, and publish the complete `site/` directory. The manifest resolves all contract inputs; no owner configuration is required or available. No local deployment addresses, test wallets or signing material are shipped as a live configuration.
