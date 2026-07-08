# Security

This document records the F1 security pass over the RWA Yield Protocol: the threat
model, the trust assumptions, the adversarial review performed, the tooling run, and
the residual risks that are **accepted by design** (and why). It is written to be read
by an auditor or an integrator deciding whether to trust this code, not as marketing.

- **Scope:** the eight first-party contracts under [`contracts/src`](contracts/src)
  (`RwaVault`, `RwaVaultV2`, `RwaNavFeed`, `RwaVaultKeeper`, `TBillToken`,
  `CrossChainDepositRelay`, `CrossChainDepositSender`, and the `AggregatorV3Interface`
  the vault consumes). Dependencies (`lib/`) are out of scope.
- **Last reviewed:** F1 pass, 2026-07-08.
- **Prior hardening:** F0 added invariant suites, coverage, and CI; this F1 pass is a
  full adversarial re-read plus static analysis on top of that.

> ⚠️ **Testnet / portfolio status.** This protocol is deployed to Sepolia and is a
> portfolio/demo system, *not* audited-for-mainnet. Several powerful roles
> (`ASSET_MANAGER_ROLE`, `NAV_UPDATER_ROLE`, `OPERATOR_ROLE`, `UPGRADER_ROLE`) are
> **trusted** — see the trust model below. Do not deploy with real value without an
> independent audit and a governance/timelock/multisig setup for those roles.

## Verification performed

| Check | Result |
|---|---|
| `forge test` (rwa-yield-protocol) | **169 passed, 0 failed** — unit + invariants + named attack scenarios |
| `forge test` (yield-vault, shared ERC-7540 base) | **45 passed, 0 failed** |
| Storage-layout diff `RwaVault.v1` → `RwaVaultV2` | **Upgrade-safe** — slots 0–10 identical in name/type/order; V2 appends fields at 11–13 and reduces the reserved gap to `uint256[47]` at slot 14 (see [`contracts/storage-layout`](contracts/storage-layout)) |
| Slither static analysis (solc 0.8.24) | _see "Static analysis (Slither)" below_ |
| Manual adversarial review (10 contracts) | No new High/Medium (see "Adversarial review") |

The invariant campaign (F0) and the named regression tests are the load-bearing
evidence here — in particular:

- `test_AssetsInTransitWindow_*` — the deposit-USDC-out / tBILL-NAV-in settlement gap.
- `test_RedeemLiquidityGap_FulfillBeyondLiquidBuffer_RevertsAfterFix` — the
  `InsufficientLiquidity` cap on `fulfillRedeem` (finding (c) of the D3 invariant run).
- `test_ReentrancyGuard_UninitializedProxySlot_StillBlocksReentrantCall` — proves the
  non-upgradeable `ReentrancyGuard` is proxy-safe with a zero (uninitialized) slot.

## Trust model (accepted by design)

This is an oracle-priced RWA vault. Some roles are, unavoidably, trusted. The design
goal is not to make them trustless but to **bound the blast radius of each** and make
abuse detectable/stoppable rather than instantaneous and total.

| Role / actor | Power | Bound on the power |
|---|---|---|
| `NAV_UPDATER_ROLE` (`RwaNavFeed`) | Publishes the NAV that prices every share | **±5% max deviation per update** (`MAX_DEVIATION_BPS`) **and ≥1h between updates** (`MIN_UPDATE_INTERVAL`). A stolen key becomes an hours-long, detectable process — not a one-block drain. Non-positive NAV reverts. |
| `ASSET_MANAGER_ROLE` (`RwaVault`) | Moves USDC in/out for the off-chain T-bill leg | `investInTBill` is **capped by `_freeAssetBuffer()`** — it can never touch assets reserved for a pending deposit or an already-fulfilled redeem claim. The "USDC left / tBILL NAV not yet reflected" gap is a disclosed, tested settlement window. |
| `OPERATOR_ROLE` (`RwaVault`) | Settles pending requests at the current NAV | Rounding always floors in the vault's favor; `fulfillRedeem` is **capped by liquid, unreserved assets** so it can never promise an unbacked claim. |
| `UPGRADER_ROLE` (UUPS) | Ships a new implementation | The only gate on `_authorizeUpgrade`. Governance/timelock/multisig around this role is where upgrade safety must live — there is intentionally no timelock at the contract layer. |
| `PAUSER_ROLE` | Pauses new exposure | **Partial pause only** — `whenNotPaused` guards `requestDeposit`/`requestRedeem` *only*. Fulfill, all four claim paths, invest/divest and `setOperator` ignore pause, so a pause can never trap money already owed to a depositor ("pausa como DoS" is explicitly avoided). |
| Cross-chain relay allowlist | Accepts CCIP messages that drive `requestDeposit` | `_ccipReceive` acts **only** on owner-allowlisted `(sourceChainSelector, sender)` pairs, spends the relay's own pre-funded balance, checks that balance explicitly, and grants an **exact-amount** (non-infinite) approval that does not survive the call. |

## Adversarial review

Each first-party contract was read line-by-line against a concrete "how would I steal
from / brick this" checklist. Findings:

### `RwaVault` / `RwaVaultV2` (ERC-7540 async vault, UUPS)
- **Share accounting & rounding.** Settlement (`fulfillDeposit`/`fulfillRedeem`) floors
  in both directions; partial claims round the *consumed* side up and the *paid-out*
  side down, so a claimable bucket always depletes at least as fast as proportional and
  no dust becomes extractable. `totalClaimableRedeemAssets` decrements are always ≤ the
  controller's own claimable bucket ≤ the aggregate — no underflow path.
- **`totalAssets()` accounting.** Pending deposits and fulfilled-but-unclaimed redeem
  assets are excluded (`_freeAssetBuffer` saturates at zero), so a fulfilled redeem
  can't let remaining holders' price-per-share jump for free (no double-count).
- **Inflation attack.** Mitigated by a `_decimalsOffset()` of 6 (virtual shares/assets),
  independent of the tBILL token's own decimals.
- **Reentrancy.** All state-mutating externals carry `nonReentrant`; the claim/redeem
  paths also follow checks-effects-interactions (state updated before the ERC-20
  transfer). The non-upgradeable `ReentrancyGuard` is proxy-safe with a zero slot
  (tested).
- **NAV consumption.** Every price read funnels through a single `_latestNav()` site
  that rejects non-positive answers and enforces `MAX_STALENESS = 24h`, and
  `_tBillValueInAsset` reads token/feed decimals dynamically and routes every multiply
  through `Math.mulDiv` (checked 512-bit path).
- **V2 fee.** Linear, non-compounding, hard-capped at `MAX_FEE_BPS = 200` (2%/yr, no
  other setter exists), stamped `lastFeeAccrual = block.timestamp` unconditionally
  before any early return (never double-counts a second, never backdates), minted as
  dilution to a zero-checked `feeRecipient` from `totalAssets()` computed *before* the
  mint. `accrueFees()` is permissionless but takes no caller input and only mints to
  the fixed recipient — no added surface.
- **Upgrade safety.** V2 is a deliberate structural copy (not `is RwaVault`) to
  genuinely consume the reserved gap; the storage-layout diff is verified byte-for-byte
  (table above).

### `RwaNavFeed`
Deviation band + rate limit + positive-answer guard as described in the trust table.
First update is intentionally exempt (no prior value to measure against). Division in
`_deviationBps` is always by a strictly-positive previous NAV.

### `RwaVaultKeeper`
Pure orchestration — holds no funds. `performUpkeep` is permissionless but **re-derives
everything from the vault's own getters** and only calls the role-gated
`fulfillDeposit`/`fulfillRedeem`, so a replayed/forged `performData` can at most trigger
settlement of a genuinely-pending request (inevitable anyway; NAV is constant within a
round). The two documented race conditions (already-fulfilled / buffer dried up) are
silent no-ops; any *other* revert propagates loudly (no blanket try/catch).

### `TBillToken`, `CrossChainDepositSender`
`TBillToken` is a plain `AccessControl` ERC-20; mint/burn gated by `ASSET_MANAGER_ROLE`,
zero-address/zero-amount checked, no pricing logic (NAV lives only in the feed). The
sender carries no value (CCIP *messaging*, not a token bridge — a disclosed trade-off),
checks its own LINK balance explicitly, and uses an exact-amount approval.

## Static analysis (Slither)

Slither `0.11.x` was run against the first-party sources compiled with `solc 0.8.24`
(`slither . --filter-paths "lib/|test/|script/"`). It analyzed 52 contracts with 101
detectors and reported **30 results, none of them actionable High/Medium** — every one
is a false positive given the authorization/design context, an informational ordering
note, or an intentional pattern. Full triage:

| Detector | Where | Verdict |
|---|---|---|
| `arbitrary-send-erc20` | `RwaVault`/`V2.requestDeposit` `transferFrom(owner, …)` | **False positive.** The ERC-7540 operator model: `owner` is authorized by `require(msg.sender == owner || isOperator[owner][msg.sender])` immediately above the transfer. `from` is not arbitrary — it is the checked, consenting owner. |
| `incorrect-equality` | `== 0` guards (`tBillAmount`, `elapsed`, `feeAssets`, `feeShares`, `assets`, `updatedAt`) | **False positive.** All are zero-sentinel short-circuits, not exactness comparisons of manipulable balances. `updatedAt == 0` is the round-existence sentinel (a real round always stamps a nonzero `block.timestamp`). |
| `unused-return` | `_latestNav` (Chainlink tuple), keeper `fulfill*`, relay `requestDeposit` | **Intentional.** `_latestNav` deliberately destructures only `answer`+`updatedAt`; the keeper/relay don't need the settled amounts. See the note below on `answeredInRound` for the production-feed swap. |
| `reentrancy-events` | relay/keeper/sender emit after an external call | **Informational.** Event-ordering only, no state after the call; the callee vault functions are themselves `nonReentrant`. |
| `timestamp` | NAV interval/staleness, fee accrual | **Accepted by design.** All windows are hour-to-annual scale; ~12s validator timestamp drift is negligible against a ≥1h interval / 24h staleness / 365d fee. |
| `missing-inheritance` | `RwaVault` "should inherit `IRwaVaultDeposit`" | **Intentional.** That interface is a deliberately narrow local copy in the relay (ownership-boundary decision, documented in-source), not a shared abstract type. |
| `naming-convention` / `unused-state` | `__gap`, `_roundId` | **Intentional.** `__gap` is the OZ storage-gap convention (reserved-by-design, hence "unused"); `_roundId` matches the `AggregatorV3Interface` signature. |

**Noted for the production feed swap (not a fix applied here):** `_latestNav()` guards
staleness via `MAX_STALENESS` and rejects non-positive answers, which is sufficient for
the in-house `RwaNavFeed` (where `answeredInRound == roundId` always). The day a *real*
Chainlink aggregator is swapped in, adding an `answeredInRound >= roundId` completeness
check to the consumer would be the belt-and-suspenders move. It is intentionally **not**
applied now: it would modify an already-deployed, gap-constrained contract for a
condition the current oracle cannot exhibit, and this pass does not manufacture changes
absent a real defect.

**No contract code was changed by this F1 pass.** The correct output of a security pass
over already-hardened code is an honest "nothing actionable found," not a cosmetic edit
to have something to show.

## Residual risks (known, accepted)

1. **Oracle/operator trust** — the NAV is operator-published; the bounds above turn a
   compromise into a detectable, rate-limited incident, not a trustless guarantee.
2. **Settlement gap** — the window between `investInTBill` pulling USDC and the tBILL
   NAV reflecting it is real and tested; the operational rule ("divest before
   fulfilling redeems") is enforced on-chain by the `InsufficientLiquidity` cap, but the
   deposit-side dilution window is an accepted, documented property.
3. **Cross-chain demo posture** — the CCIP leg is messaging-only over a pre-funded relay
   balance; a production deployment would replace it with a registered CCIP Token Pool.

## Reporting

This is a personal portfolio project. If you find an issue, open an issue or contact the
author directly rather than disclosing publicly.
