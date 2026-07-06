// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RwaVault} from "../../src/RwaVault.sol";
import {RwaNavFeed} from "../../src/RwaNavFeed.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {MockUSDC} from "../utils/MockUSDC.sol";

/// @title RwaVaultHandler
/// @notice Multi-actor invariant handler for `RwaVault` (ARCHITECTURE.md §5 / D3 acceptance
///         bar). Every state-changing entry point on the vault is wrapped here behind a
///         bounded, always-non-reverting-by-construction (best effort) fuzzed action; the
///         handler is the ONLY `targetContract` wired into `RwaVault.invariants.t.sol`, so
///         every call the invariant runner makes goes through here, never directly at the
///         vault/tokens/feed with a random fuzzed sender.
/// @dev Ghost variables here are the source of truth the invariant test compares on-chain
///      state against — see each `ghost_*` doc comment for exactly what it tracks and why.
///
///      Design choice: `investAndMintTBill` performs BOTH legs (pull USDC, mint the
///      equivalent tBILL) atomically in one handler call, so the routine fuzzed sequences
///      never wander into the "assets-in-transit" gap themselves — that gap is quantified
///      separately with dedicated, explicitly-named unit tests in `RwaVault.invariants.t.sol`
///      (Fable audit hallazgo (a)). What THIS handler still checks live, on every single
///      `investInTBill` call, is invariant (5): the reserved pending+claimable buffer must
///      never move because of it (see `ghost_reservedBufferDecreasedByInvest`).
contract RwaVaultHandler is Test {
    using Math for uint256;

    RwaVault public immutable vault;
    MockUSDC public immutable asset;
    TBillToken public immutable tBillToken;
    RwaNavFeed public immutable navFeed;

    address public immutable operator;
    address public immutable assetManager;
    address public immutable navUpdater;

    address[] internal actors;

    /// @dev Mirrors RwaVault._tBillValueInAsset's math, inverted, for THIS fixture's fixed
    ///      decimals only (MockUSDC=6, TBillToken=6, RwaNavFeed=8 — none of the three is
    ///      runtime-configurable, all three hardcode their own `decimals()`), so
    ///      tBillDec + navDec - assetDec = 6 + 8 - 6 = 8 is a safe constant here, not a
    ///      generic assumption. assetValue = tBillAmount * nav / SCALE (and the inverse).
    uint256 internal constant SCALE = 1e8;

    // ------------------------------------------------------------------
    // Ghost state — deposit/redeem per-actor conservation (invariant 3)
    // ------------------------------------------------------------------

    /// @notice Sum of `assets` ever passed to a successful `requestDeposit` by this actor.
    mapping(address => uint256) public ghost_requestedDepositAssets;
    /// @notice Sum of the ACTUAL drop in `claimableDepositAssets[actor]` across every
    ///         successful claim (`deposit` or `mint`), measured as an on-chain before/after
    ///         delta so it is correct regardless of which claim entry point was used or how
    ///         its internal rounding (floor vs ceil) worked out.
    mapping(address => uint256) public ghost_claimedDepositAssets;

    /// @notice Sum of `shares` ever passed to a successful `requestRedeem` by this actor.
    mapping(address => uint256) public ghost_requestedRedeemShares;
    /// @notice Sum of the ACTUAL drop in `claimableRedeemShares[actor]` across every
    ///         successful claim (`redeem` or `withdraw`), same before/after-delta approach.
    mapping(address => uint256) public ghost_claimedRedeemShares;

    // ------------------------------------------------------------------
    // Ghost state — shares never free (invariant 4)
    // ------------------------------------------------------------------

    /// @notice Sum of every `shares` value RETURNED by a successful `fulfillDeposit` — the
    ///         ONLY `_mint` call site in the whole contract.
    uint256 public ghost_totalSharesMintedViaFulfillDeposit;
    /// @notice Sum of every `shares` value PASSED IN to a successful `fulfillRedeem` — the
    ///         ONLY `_burn` call site (burns exactly the input `shares`, not the derived
    ///         `assets`).
    uint256 public ghost_totalSharesBurnedViaFulfillRedeem;

    // ------------------------------------------------------------------
    // Ghost state — reserved buffer vs investInTBill (invariant 5)
    // ------------------------------------------------------------------

    /// @notice Set to `true` the moment ANY `investInTBill` call is observed to have
    ///         decreased `totalPendingDepositAssets + totalClaimableRedeemAssets`. Checked
    ///         immediately after the call, before the handler's own follow-up tBILL mint —
    ///         `investInTBill` itself never touches either of those two variables, so this
    ///         should be permanently `false`.
    bool public ghost_reservedBufferDecreasedByInvest;

    // ------------------------------------------------------------------
    // Ghost state — call/revert accounting (debug visibility only, not asserted on)
    // ------------------------------------------------------------------

    uint256 public ghost_calls_requestDeposit;
    uint256 public ghost_calls_requestRedeem;
    uint256 public ghost_calls_fulfillDeposit;
    uint256 public ghost_calls_fulfillRedeem;
    uint256 public ghost_calls_claimDeposit;
    uint256 public ghost_calls_claimRedeem;
    uint256 public ghost_calls_invest;
    uint256 public ghost_calls_divest;
    uint256 public ghost_calls_updateNav;
    uint256 public ghost_calls_warp;
    uint256 public ghost_calls_setOperator;

    uint256 public ghost_reverts_requestDeposit;
    uint256 public ghost_reverts_requestRedeem;
    uint256 public ghost_reverts_fulfillDeposit;
    uint256 public ghost_reverts_fulfillRedeem;
    uint256 public ghost_reverts_claimDeposit;
    uint256 public ghost_reverts_claimRedeem;
    uint256 public ghost_reverts_updateNav;

    uint256 public ghost_skips_noPendingDeposit;
    uint256 public ghost_skips_noPendingRedeem;
    uint256 public ghost_skips_noClaimableDeposit;
    uint256 public ghost_skips_noClaimableRedeem;
    uint256 public ghost_skips_noShareBalance;
    uint256 public ghost_skips_noFreeBuffer;
    uint256 public ghost_skips_noFreeBufferForRedeem;
    uint256 public ghost_skips_noTBillHoldings;
    uint256 public ghost_skips_navTooSoon;

    constructor(
        RwaVault vault_,
        MockUSDC asset_,
        TBillToken tBillToken_,
        RwaNavFeed navFeed_,
        address operator_,
        address assetManager_,
        address navUpdater_,
        address[] memory actors_
    ) {
        vault = vault_;
        asset = asset_;
        tBillToken = tBillToken_;
        navFeed = navFeed_;
        operator = operator_;
        assetManager = assetManager_;
        navUpdater = navUpdater_;
        actors = actors_;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    /// @dev Scans `actors` starting at `seed % len` (wrapping once) for the first one whose
    ///      `metric(actor) > 0`, so fuzzed actions that need a non-zero starting balance
    ///      (pending/claimable/share balance) actually get to run instead of mostly no-op'ing
    ///      on whichever actor the seed happened to land on first.
    function _findActorWithNonZero(uint256 seed, function(address) external view returns (uint256) metric)
        internal
        view
        returns (address found, uint256 value)
    {
        uint256 len = actors.length;
        uint256 start = seed % len;
        for (uint256 i = 0; i < len; i++) {
            address candidate = actors[(start + i) % len];
            uint256 v = metric(candidate);
            if (v > 0) {
                return (candidate, v);
            }
        }
        return (address(0), 0);
    }

    function _assetToTBillAtCurrentNav(uint256 assetAmount) internal view returns (uint256 nav, uint256 tBillAmount) {
        (, int256 answer,,,) = navFeed.latestRoundData();
        if (answer <= 0) return (0, 0);
        nav = uint256(answer);
        tBillAmount = assetAmount.mulDiv(SCALE, nav);
    }

    function _tBillToAssetAtCurrentNav(uint256 tBillAmount) internal view returns (uint256 nav, uint256 assetAmount) {
        (, int256 answer,,,) = navFeed.latestRoundData();
        if (answer <= 0) return (0, 0);
        nav = uint256(answer);
        assetAmount = tBillAmount.mulDiv(nav, SCALE);
    }

    /// @dev Mirrors RwaVault's private `_freeAssetBuffer()` using only public state, since
    ///      the real one isn't exposed. Used to keep `fulfillRedeemPartial` from modeling an
    ///      operator who manufactures insolvency for no reason — see that function's doc
    ///      comment. `investAndMintTBill` inlines the same formula for its own free-buffer read.
    function _freeBuffer() internal view returns (uint256) {
        uint256 balance = asset.balanceOf(address(vault));
        uint256 reserved = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();
        return balance > reserved ? balance - reserved : 0;
    }

    // ------------------------------------------------------------------
    // 1) REQUEST
    // ------------------------------------------------------------------

    function requestDeposit(uint256 actorSeed, uint256 amountSeed) external {
        ghost_calls_requestDeposit++;
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);

        asset.mint(actor, amount);
        vm.prank(actor);
        asset.approve(address(vault), amount);

        vm.prank(actor);
        try vault.requestDeposit(amount, actor, actor) {
            ghost_requestedDepositAssets[actor] += amount;
        } catch {
            ghost_reverts_requestDeposit++;
        }
    }

    function requestRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_calls_requestRedeem++;
        (address actor, uint256 shareBal) = _findActorWithNonZero(actorSeed, vault.balanceOf);
        if (actor == address(0)) {
            ghost_skips_noShareBalance++;
            return;
        }
        uint256 shares = bound(sharesSeed, 1, shareBal);

        vm.prank(actor);
        try vault.requestRedeem(shares, actor, actor) {
            ghost_requestedRedeemShares[actor] += shares;
        } catch {
            ghost_reverts_requestRedeem++;
        }
    }

    // ------------------------------------------------------------------
    // 2) FULFILL (partial) — OPERATOR_ROLE
    // ------------------------------------------------------------------

    function fulfillDepositPartial(uint256 actorSeed, uint256 amountSeed) external {
        ghost_calls_fulfillDeposit++;
        (address actor, uint256 pending) = _findActorWithNonZero(actorSeed, vault.pendingDeposit);
        if (actor == address(0)) {
            ghost_skips_noPendingDeposit++;
            return;
        }
        uint256 amount = bound(amountSeed, 1, pending);

        vm.prank(operator);
        try vault.fulfillDeposit(actor, amount) returns (uint256 shares) {
            ghost_totalSharesMintedViaFulfillDeposit += shares;
        } catch {
            ghost_reverts_fulfillDeposit++;
        }
    }

    /// @dev `RwaVault.fulfillRedeem` has NO on-chain liquidity check — it prices `assets`
    ///      purely off NAV (`convertToAssets`, which counts illiquid tBILL holdings) and
    ///      commits to `totalClaimableRedeemAssets` regardless of the vault's actual raw
    ///      cash balance. That gap is real and is quantified on its own, UNGUARDED, in
    ///      `test_RedeemLiquidityGap_*` in `RwaVault.invariants.t.sol` (an invariant-fuzzing
    ///      discovery, symmetric to the deposit-side "assets-in-transit" hallazgo (a) but not
    ///      previously documented anywhere for the redeem side). For the ROUTINE multi-actor
    ///      campaign below, the handler self-imposes the discipline a responsible OPERATOR
    ///      would apply in practice — never fulfilling a redeem beyond what the vault's
    ///      current free (liquid) buffer can back — mirroring `investAndMintTBill`'s choice
    ///      to close its own gap atomically. This keeps invariant_Solvency meaningful for
    ///      catching REAL regressions instead of permanently tripping on this known,
    ///      trust-boundary gap.
    function fulfillRedeemPartial(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_calls_fulfillRedeem++;
        (address actor, uint256 pending) = _findActorWithNonZero(actorSeed, vault.pendingRedeem);
        if (actor == address(0)) {
            ghost_skips_noPendingRedeem++;
            return;
        }

        uint256 freeBuffer = _freeBuffer();
        if (freeBuffer == 0) {
            ghost_skips_noFreeBufferForRedeem++;
            return;
        }
        uint256 maxShares;
        try vault.convertToShares(freeBuffer) returns (uint256 s) {
            maxShares = s;
        } catch {
            ghost_skips_noFreeBufferForRedeem++;
            return;
        }
        if (maxShares == 0) {
            ghost_skips_noFreeBufferForRedeem++;
            return;
        }
        uint256 cappedPending = pending < maxShares ? pending : maxShares;
        uint256 shares = bound(sharesSeed, 1, cappedPending);

        vm.prank(operator);
        try vault.fulfillRedeem(actor, shares) returns (uint256 /* assets */ ) {
            ghost_totalSharesBurnedViaFulfillRedeem += shares;
        } catch {
            ghost_reverts_fulfillRedeem++;
        }
    }

    // ------------------------------------------------------------------
    // 3) CLAIM (partial) — all four entry points, exercised separately so both rounding
    //    directions (floor via deposit/redeem, ceil via mint/withdraw) get fuzzed.
    // ------------------------------------------------------------------

    function claimDepositViaDeposit(uint256 actorSeed, uint256 amountSeed) external {
        ghost_calls_claimDeposit++;
        (address actor, uint256 claimableAssets) = _findActorWithNonZero(actorSeed, vault.claimableDepositAssets);
        if (actor == address(0)) {
            ghost_skips_noClaimableDeposit++;
            return;
        }
        uint256 amount = bound(amountSeed, 1, claimableAssets);

        vm.prank(actor);
        try vault.deposit(amount, actor, actor) {
            uint256 afterAssets = vault.claimableDepositAssets(actor);
            ghost_claimedDepositAssets[actor] += claimableAssets - afterAssets;
        } catch {
            ghost_reverts_claimDeposit++;
        }
    }

    function claimDepositViaMint(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_calls_claimDeposit++;
        (address actor, uint256 claimableShares) = _findActorWithNonZero(actorSeed, vault.claimableDepositShares);
        if (actor == address(0)) {
            ghost_skips_noClaimableDeposit++;
            return;
        }
        uint256 shares = bound(sharesSeed, 1, claimableShares);
        uint256 assetsBefore = vault.claimableDepositAssets(actor);

        vm.prank(actor);
        try vault.mint(shares, actor, actor) {
            uint256 assetsAfter = vault.claimableDepositAssets(actor);
            ghost_claimedDepositAssets[actor] += assetsBefore - assetsAfter;
        } catch {
            ghost_reverts_claimDeposit++;
        }
    }

    function claimRedeemViaRedeem(uint256 actorSeed, uint256 sharesSeed) external {
        ghost_calls_claimRedeem++;
        (address actor, uint256 claimableShares) = _findActorWithNonZero(actorSeed, vault.claimableRedeemShares);
        if (actor == address(0)) {
            ghost_skips_noClaimableRedeem++;
            return;
        }
        uint256 shares = bound(sharesSeed, 1, claimableShares);

        vm.prank(actor);
        try vault.redeem(shares, actor, actor) {
            uint256 afterShares = vault.claimableRedeemShares(actor);
            ghost_claimedRedeemShares[actor] += claimableShares - afterShares;
        } catch {
            ghost_reverts_claimRedeem++;
        }
    }

    function claimRedeemViaWithdraw(uint256 actorSeed, uint256 assetsSeed) external {
        ghost_calls_claimRedeem++;
        (address actor, uint256 claimableAssets) = _findActorWithNonZero(actorSeed, vault.claimableRedeemAssets);
        if (actor == address(0)) {
            ghost_skips_noClaimableRedeem++;
            return;
        }
        uint256 amount = bound(assetsSeed, 1, claimableAssets);
        uint256 sharesBefore = vault.claimableRedeemShares(actor);

        vm.prank(actor);
        try vault.withdraw(amount, actor, actor) {
            uint256 sharesAfter = vault.claimableRedeemShares(actor);
            ghost_claimedRedeemShares[actor] += sharesBefore - sharesAfter;
        } catch {
            ghost_reverts_claimRedeem++;
        }
    }

    // ------------------------------------------------------------------
    // ERC-7540 operator delegation
    // ------------------------------------------------------------------

    function setOperatorForActor(uint256 actorSeed, uint256 targetSeed, bool approved) external {
        ghost_calls_setOperator++;
        address actor = actors[actorSeed % actors.length];
        address target = actors[targetSeed % actors.length];
        vm.prank(actor);
        vault.setOperator(target, approved);
    }

    // ------------------------------------------------------------------
    // Treasury rails — ASSET_MANAGER_ROLE (both legs done atomically, see contract NatSpec)
    // ------------------------------------------------------------------

    function investAndMintTBill(uint256 amountSeed) external {
        ghost_calls_invest++;
        uint256 freeBuffer = _freeBuffer();
        if (freeBuffer == 0) {
            ghost_skips_noFreeBuffer++;
            return;
        }
        uint256 amount = bound(amountSeed, 1, freeBuffer);

        uint256 reservedBefore = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();

        vm.prank(assetManager);
        try vault.investInTBill(amount) {
            uint256 reservedAfter = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();
            if (reservedAfter < reservedBefore) {
                ghost_reservedBufferDecreasedByInvest = true;
            }

            (, uint256 tBillAmount) = _assetToTBillAtCurrentNav(amount);
            if (tBillAmount > 0) {
                vm.prank(assetManager);
                tBillToken.mint(address(vault), tBillAmount);
            }
        } catch {
            // InsufficientFreeBuffer edge (rounding) or stale NAV read elsewhere — fine,
            // fail_on_revert=false means this fuzzed call is simply discarded.
        }
    }

    function divestFromTBillAndBurn(uint256 amountSeed) external {
        ghost_calls_divest++;
        uint256 tBillBal = tBillToken.balanceOf(address(vault));
        if (tBillBal == 0) {
            ghost_skips_noTBillHoldings++;
            return;
        }
        (uint256 nav, uint256 fullValue) = _tBillToAssetAtCurrentNav(tBillBal);
        if (nav == 0 || fullValue == 0) {
            ghost_skips_noTBillHoldings++;
            return;
        }

        uint256 amount = bound(amountSeed, 1, fullValue);
        (, uint256 tBillToBurn) = _assetToTBillAtCurrentNav(amount);
        if (tBillToBurn == 0) {
            return;
        }
        if (tBillToBurn > tBillBal) {
            tBillToBurn = tBillBal;
        }

        vm.startPrank(assetManager);
        try tBillToken.burn(address(vault), tBillToBurn) {
            asset.mint(assetManager, amount);
            asset.approve(address(vault), amount);
            try vault.divestFromTBill(amount) {
                // success — no dedicated ghost needed, covered by invariant (1)/(2)
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Oracle — NAV_UPDATER_ROLE, always within RwaNavFeed's own ±5% band
    // ------------------------------------------------------------------

    function updateNavWithinBand(uint256 navSeed) external {
        ghost_calls_updateNav++;
        (, int256 answer,, uint256 updatedAt,) = navFeed.latestRoundData();
        if (block.timestamp < updatedAt + navFeed.MIN_UPDATE_INTERVAL()) {
            ghost_skips_navTooSoon++;
            return; // respects RwaNavFeed's own rate limit; a separate warpForward call
                //  advances time — decoupled on purpose, see warpForward's doc comment.
        }

        uint256 previousNav = uint256(answer);
        uint256 maxDeviation = (previousNav * navFeed.MAX_DEVIATION_BPS()) / navFeed.BPS_DENOMINATOR();
        uint256 lowerBound = previousNav > maxDeviation ? previousNav - maxDeviation : 1;
        uint256 upperBound = previousNav + maxDeviation;
        uint256 newNav = bound(navSeed, lowerBound, upperBound);
        if (newNav == 0) newNav = 1;

        vm.prank(navUpdater);
        try navFeed.updateNav(int256(newNav)) {
            // success
        } catch {
            ghost_reverts_updateNav++;
        }
    }

    /// @dev Bounded to (0, 6 hours] — strictly less than `RwaVault.MAX_STALENESS` (24h) per
    ///      single jump, so no individual warp can, by itself, brick every other action in
    ///      the same run by instantly staling the NAV feed. `updateNavWithinBand` is a
    ///      separate, decoupled action responsible for actually refreshing the feed.
    function warpForward(uint256 secondsSeed) external {
        ghost_calls_warp++;
        uint256 delta = bound(secondsSeed, 0, 6 hours);
        vm.warp(block.timestamp + delta);
    }
}
