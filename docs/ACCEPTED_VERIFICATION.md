# Accepted-bundle verification record

Historical evidence shipped in the accepted source bundle, not results newly obtained in this task. See [current verification](VERIFICATION.md).

Local work used Foundry 1.8.3 and the configuration-pinned Solidity 0.8.26. All production libraries and site assets are vendored. The final command results are recorded below after the final repair pass.

| Final check | Result |
|---|---|
| `forge build --sizes` | Passed; all production runtime and initcode sizes below their EVM limits |
| `forge test -vv` | 35 passed, 0 failed, 1 explicitly skipped opt-in fork suite |
| Stateful invariants | 64 runs ×64 calls; artist claims bounded and all fee backing conserved |
| Independent retained regression suite | 9 passed, including 256×100-step accounting fuzz traces |
| `forge fmt --check` | Passed |
| Slither0.11.6 production pass | 0 high, 0 medium; 13 low, 9 informational; no detector suppressions |
| JavaScript syntax checks | Site and both deployment utilities passed |
| Chromium desktop/mobile smoke | No page exceptions; no horizontal overflow at390px; transactions disabled before configuration |
| Local Anvil browser transactions | Connected wallet; quote/approval/buy; paint; trade earnings claim; end season; SVG gallery; auction bid; finalize; exact season payout claim all completed |
| Final repaired-code Robinhood fork | 1 passed at block83,173,144 against the real deployed PoolManager and IMD |

The browser test injects an unlocked **local test wallet** and local deployment configuration. It tests the application's transaction construction and contract interaction, not a specific extension's confirmation UI. No test keys or local addresses are shipped in the public site configuration.

## Robinhood rehearsal

On 2026-10-08, the primary contributor ran `test/fork/Robinhood.t.sol` against Robinhood Chain **4663**, initially pinned block **83,156,578**, RPC `https://rpc.mainnet.chain.robinhood.com`. After the final repairs it passed again at **83,173,144**. The public RPC had pruned the earlier state by then, so the final run pinned and recorded a fresh block. Historical repetition needs an archive RPC.

- Real PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- Real IMD: `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`.
- Read-only probes confirmed chain ID4663, code at the contracts, IMD symbol, 18 decimals, and enabled transfers. The manager owner read was also checked.
- A new standard launch token and correctly mined hook/children were deployed **only inside the fork**. Liquidity and trading wallets received synthetic test balances. The test initialized a separate pool, bought and sold through the real manager, checked paint, redeemed artist/treasury claims and reconciled fee backing.
- Result: **1 passed, 0 failed, 0 skipped**. This tests the real external contracts' execution code, not the production launch factory's liquidity policy or a signed mainnet transaction. No broadcast was made.

The Uniswap deployment is independently published in [Uniswap's Robinhood playbook](https://github.com/Uniswap/UniswapX/blob/main/playbook/chains/robinhood.md). The IMD token was identified through the [IdentityMD explorer's recorded contract reviews](https://explorer.imd.fun/) and verified directly by RPC; it is not hardcoded in production contracts. These read-only fixture addresses are confined to the opt-in fork test.

## Independent review

A separate reviewer examined money flows and implemented retained tests under `test/review/`. Two issues found during development were repaired: a delayed no-bid carry could change the receiving season, and dense metadata rendering consumed excessive gas. See [INDEPENDENT_REVIEW.md](INDEPENDENT_REVIEW.md) for exact coverage and limitations.

## Static analysis

Slither0.11.6 ran against production source with vendored dependencies/tests filtered from reported findings. No blanket detector suppression or disabled checks were added. Its first pass found no arbitrary-send-erc20, but flagged before/after token balance snapshots despite the guards. Those were replaced by explicit current-budget and aggregate escrow coverage checks, with malicious callback and refund-failure tests. Money allocations now use `Math.mulDiv` to express intentional rounding before accumulator scaling.

The final machine-readable summary is [static-analysis.json](static-analysis.json). Remaining low findings concern requested timestamp comparisons, guarded router context setup/cleanup around token/manager calls, and a fee event emitted after fixed PoolManager/Canvas calls. Informational findings concern bounded renderer assembly and control-flow complexity. These were reviewed rather than suppressed.

Timestamp uses are the requested auction, season, deadline, price-window and launch-decay clocks. Remaining assembly is confined to bounded image rendering/storage extraction. Permissionless fees and maintenance are immutable; no proxy or administrator has been introduced to resolve tool warnings.

## Site

The website uses vendored ethers6.13.5 and a locally served OFL font, no CDN or npm build. Browser smoke checks cover desktop/mobile layout, coordinate selection, the pre-launch disabled state, and a local Anvil deployment. The deployment configuration is injected into the local browser test; simulated/local addresses are not published as live addresses or committed as `site/deployment.json`.
