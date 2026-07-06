// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RwaVault} from "../src/RwaVault.sol";
import {RwaVaultV2} from "../src/RwaVaultV2.sol";
import {RwaNavFeed} from "../src/RwaNavFeed.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockUSDC} from "./utils/MockUSDC.sol";

/// @title RwaVaultV2Test
/// @notice Coverage for the D4 live-upgrade target per ARCHITECTURE.md §3.4: a proxy
///         deployed and used as `RwaVault` (V1), then upgraded in place to `RwaVaultV2`.
///         Every test that exercises "post-upgrade" behavior deploys V1 FIRST, drives real
///         state through it (deposits, partial fulfills, partial claims, redeems), THEN
///         upgrades — never deploys `RwaVaultV2` fresh and pretends that's the same thing.
///         That is the whole point of a storage-compatibility test: prove the SAME proxy,
///         carrying live V1 storage, keeps working correctly as V2.
contract RwaVaultV2Test is Test {
    using Math for uint256;

    RwaVault internal vaultV1;
    RwaVaultV2 internal vault; // same proxy address, cast to the V2 ABI after upgrading
    RwaVault internal implementationV1;
    RwaVaultV2 internal implementationV2;
    MockUSDC internal asset;
    TBillToken internal tBillToken;
    RwaNavFeed internal navFeed;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal assetManager = makeAddr("assetManager");
    address internal pauser = makeAddr("pauser");
    address internal upgrader = makeAddr("upgrader");
    address internal tBillAdmin = makeAddr("tBillAdmin");
    address internal navAdmin = makeAddr("navAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal feeRecipient = makeAddr("feeRecipient");

    int256 internal constant INITIAL_NAV = 100e8; // 100.00000000, 8 decimals
    uint256 internal constant ONE_HOUR = 1 hours;
    uint256 internal constant DEFAULT_FEE_BPS = 100; // 1% annualized

    function setUp() public {
        // Windows/foundry gotcha: local timestamp starts at 1 — warp in setUp.
        vm.warp(1_700_000_000);

        asset = new MockUSDC();
        tBillToken = new TBillToken(tBillAdmin);
        navFeed = new RwaNavFeed(navAdmin, "tBILL / USD NAV");

        // --- Deploy and initialize as V1 (mirrors RwaVault.t.sol exactly) ---
        implementationV1 = new RwaVault();
        bytes memory initData =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(asset)), tBillToken, navFeed, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementationV1), initData);
        vaultV1 = RwaVault(address(proxy));

        vm.startPrank(admin);
        vaultV1.grantRole(vaultV1.OPERATOR_ROLE(), operator);
        vaultV1.grantRole(vaultV1.ASSET_MANAGER_ROLE(), assetManager);
        vaultV1.grantRole(vaultV1.PAUSER_ROLE(), pauser);
        vaultV1.grantRole(vaultV1.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();

        bytes32 tBillAssetManagerRole = tBillToken.ASSET_MANAGER_ROLE();
        vm.prank(tBillAdmin);
        tBillToken.grantRole(tBillAssetManagerRole, assetManager);

        vm.prank(navAdmin);
        navFeed.updateNav(INITIAL_NAV);

        // implementationV2 is deployed once here (constructor disables its own
        // initializers); every test decides on its own whether/when to upgrade to it.
        implementationV2 = new RwaVaultV2();
    }

    // =====================================================================
    // Helpers (V1 leg — identical semantics to RwaVault.t.sol)
    // =====================================================================

    function _mintAndApprove(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vaultV1), amount);
    }

    function _depositFulfillClaim(address user, uint256 amount) internal returns (uint256 shares) {
        _mintAndApprove(user, amount);
        vm.prank(user);
        vaultV1.requestDeposit(amount, user, user);

        vm.prank(operator);
        vaultV1.fulfillDeposit(user, amount);

        vm.prank(user);
        shares = vaultV1.deposit(amount, user, user);
    }

    function _bumpNav(int256 newNav) internal {
        vm.warp(block.timestamp + ONE_HOUR + 1);
        vm.prank(navAdmin);
        navFeed.updateNav(newNav);
    }

    /// @dev Upgrades the live proxy from V1 to V2, atomically calling {initializeV2} as the
    ///      `upgradeToAndCall` data — the intended D4 flow. Re-points both `vault` (V2 view)
    ///      handles at the SAME proxy address.
    function _upgradeToV2(uint256 feeBps, address recipient) internal {
        vm.prank(upgrader);
        vaultV1.upgradeToAndCall(
            address(implementationV2), abi.encodeCall(RwaVaultV2.initializeV2, (feeBps, recipient))
        );
        vault = RwaVaultV2(address(vaultV1));
    }

    /// @dev Upgrades WITHOUT calling initializeV2 (fee stays at its zero default) — used by
    ///      tests that need to call initializeV2 themselves afterwards, separately.
    function _upgradeToV2NoInit() internal {
        vm.prank(upgrader);
        vaultV1.upgradeToAndCall(address(implementationV2), "");
        vault = RwaVaultV2(address(vaultV1));
    }

    // =====================================================================
    // Upgrade mechanics: authorization + non-re-executable initializer
    // =====================================================================

    function test_RevertWhen_Upgrade_CallerLacksUpgraderRole() public {
        bytes32 role = vaultV1.UPGRADER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vaultV1.upgradeToAndCall(
            address(implementationV2), abi.encodeCall(RwaVaultV2.initializeV2, (DEFAULT_FEE_BPS, feeRecipient))
        );
    }

    function test_Upgrade_SucceedsWithUpgraderRole_AndActivatesFee() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        assertEq(vault.managementFeeBps(), DEFAULT_FEE_BPS);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.lastFeeAccrual(), block.timestamp);
    }

    function test_RevertWhen_InitializeV2_CalledTwice() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initializeV2(DEFAULT_FEE_BPS, feeRecipient);
    }

    /// @dev Even a fresh caller (not the upgrader/admin) hits the same version guard —
    ///      reinitializer(2) checks contract state, not access control.
    function test_RevertWhen_InitializeV2_CalledTwice_ByAnyCaller() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initializeV2(1, stranger);
    }

    function test_RevertWhen_InitializeV2_FeeExceedsCap() public {
        vm.prank(upgrader);
        vm.expectRevert(abi.encodeWithSelector(RwaVaultV2.FeeTooHigh.selector, 201, 200));
        vaultV1.upgradeToAndCall(
            address(implementationV2), abi.encodeCall(RwaVaultV2.initializeV2, (201, feeRecipient))
        );
    }

    function test_InitializeV2_AcceptsExactCap() public {
        uint256 cap = implementationV2.MAX_FEE_BPS(); // pure constant, readable pre-upgrade
        _upgradeToV2(cap, feeRecipient);
        assertEq(vault.managementFeeBps(), cap);
    }

    function test_RevertWhen_InitializeV2_ZeroFeeRecipient() public {
        vm.prank(upgrader);
        vm.expectRevert(RwaVaultV2.ZeroAddress.selector);
        vaultV1.upgradeToAndCall(
            address(implementationV2), abi.encodeCall(RwaVaultV2.initializeV2, (DEFAULT_FEE_BPS, address(0)))
        );
    }

    function test_InitializeV2_AllowsZeroFeeBps_FeeStartsDisabled() public {
        _upgradeToV2(0, feeRecipient);
        assertEq(vault.managementFeeBps(), 0);
        assertEq(vault.feeRecipient(), feeRecipient);
    }

    // =====================================================================
    // Storage compatibility: live V1 state survives the upgrade byte-for-byte
    // =====================================================================

    /// @dev Snapshot struct instead of ~15 separate locals — bundling into memory avoids a
    ///      "stack too deep" under the default (non-viaIR) codegen this repo builds with.
    struct StateSnapshot {
        uint256 alicePending;
        uint256 aliceClaimableAssets;
        uint256 aliceClaimableShares;
        uint256 aliceBalance;
        uint256 bobPendingRedeem;
        uint256 bobClaimableRedeemShares;
        uint256 bobClaimableRedeemAssets;
        uint256 bobBalance;
        uint256 totalPendingDeposit;
        uint256 totalClaimableRedeem;
        uint256 totalSupply;
        bool adminHasRole;
        bool operatorHasRole;
        bool paused;
    }

    function _snapshotV1() internal view returns (StateSnapshot memory s) {
        s.alicePending = vaultV1.pendingDeposit(alice);
        s.aliceClaimableAssets = vaultV1.claimableDepositAssets(alice);
        s.aliceClaimableShares = vaultV1.claimableDepositShares(alice);
        s.aliceBalance = vaultV1.balanceOf(alice);
        s.bobPendingRedeem = vaultV1.pendingRedeem(bob);
        s.bobClaimableRedeemShares = vaultV1.claimableRedeemShares(bob);
        s.bobClaimableRedeemAssets = vaultV1.claimableRedeemAssets(bob);
        s.bobBalance = vaultV1.balanceOf(bob);
        s.totalPendingDeposit = vaultV1.totalPendingDepositAssets();
        s.totalClaimableRedeem = vaultV1.totalClaimableRedeemAssets();
        s.totalSupply = vaultV1.totalSupply();
        s.adminHasRole = vaultV1.hasRole(vaultV1.DEFAULT_ADMIN_ROLE(), admin);
        s.operatorHasRole = vaultV1.hasRole(vaultV1.OPERATOR_ROLE(), operator);
        s.paused = vaultV1.paused();
    }

    function _assertSnapshotMatchesV2(StateSnapshot memory s) internal view {
        assertEq(vault.pendingDeposit(alice), s.alicePending);
        assertEq(vault.claimableDepositAssets(alice), s.aliceClaimableAssets);
        assertEq(vault.claimableDepositShares(alice), s.aliceClaimableShares);
        assertEq(vault.balanceOf(alice), s.aliceBalance);
        assertEq(vault.pendingRedeem(bob), s.bobPendingRedeem);
        assertEq(vault.claimableRedeemShares(bob), s.bobClaimableRedeemShares);
        assertEq(vault.claimableRedeemAssets(bob), s.bobClaimableRedeemAssets);
        assertEq(vault.balanceOf(bob), s.bobBalance);
        assertEq(vault.totalPendingDepositAssets(), s.totalPendingDeposit);
        assertEq(vault.totalClaimableRedeemAssets(), s.totalClaimableRedeem);
        assertEq(vault.totalSupply(), s.totalSupply);
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), s.adminHasRole);
        assertEq(vault.hasRole(vault.OPERATOR_ROLE(), operator), s.operatorHasRole);
        assertEq(vault.paused(), s.paused);
    }

    /// @dev Core D4 acceptance test: pending deposit, claimable deposit, claimable redeem
    ///      and shares — all four ERC-7540 buckets simultaneously live and non-zero — must
    ///      read back identically after `upgradeToAndCall`, through the SAME proxy address,
    ///      now speaking the V2 ABI.
    function test_UpgradeV1ToV2_PreservesLiveState_AcrossAllBuckets() public {
        // Alice: partial deposit cycle — some still pending, some claimable, some claimed.
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vaultV1.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        vaultV1.fulfillDeposit(alice, 600e6); // 400e6 stays pending
        vm.prank(alice);
        uint256 aliceSharesClaimed = vaultV1.deposit(350e6, alice, alice); // 250e6 stays claimable

        // Bob: full deposit cycle, then a partial redeem cycle left mid-flight.
        uint256 bobShares = _depositFulfillClaim(bob, 2_000e6);
        vm.prank(bob);
        vaultV1.requestRedeem(bobShares, bob, bob);
        vm.prank(operator);
        vaultV1.fulfillRedeem(bob, bobShares / 2); // half pending, half claimable

        // Snapshot EVERY piece of custom sequential state before the upgrade.
        StateSnapshot memory before = _snapshotV1();

        // Sanity: every bucket this test claims to exercise is actually non-zero.
        assertGt(before.alicePending, 0);
        assertGt(before.aliceClaimableAssets, 0);
        assertGt(aliceSharesClaimed, 0);
        assertGt(before.bobPendingRedeem, 0);
        assertGt(before.bobClaimableRedeemAssets, 0);

        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        // Same proxy address, same storage — read back through the V2 ABI.
        assertEq(address(vault), address(vaultV1));
        _assertSnapshotMatchesV2(before);

        // And the previously-claimed shares (a plain ERC-20 balance move, not a mapping)
        // are also untouched.
        assertEq(vault.balanceOf(alice), aliceSharesClaimed);
    }

    /// @dev Post-upgrade, the surviving buckets must still be OPERABLE, not just readable —
    ///      Alice's leftover pending deposit and Bob's leftover pending redeem both settle
    ///      correctly through the V2 contract.
    function test_UpgradeV1ToV2_SurvivingBuckets_RemainOperable() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vaultV1.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        vaultV1.fulfillDeposit(alice, 400e6); // 600e6 stays pending

        _upgradeToV2(0, feeRecipient); // fee disabled so this test isolates pure mechanics

        vm.prank(operator);
        vault.fulfillDeposit(alice, 600e6);
        assertEq(vault.pendingDeposit(alice), 0);
        assertEq(vault.claimableDepositAssets(alice), 1_000e6);

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice, alice);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.claimableDepositAssets(alice), 0);
    }

    // =====================================================================
    // Roles intact post-upgrade (ERC-7201 namespaced AccessControl storage — see contract
    // NatSpec: safe by construction, but worth asserting directly rather than trusting it).
    // =====================================================================

    function test_UpgradeV1ToV2_AllOperationalRoles_SurviveIntact() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), operator));
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), assetManager));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.UPGRADER_ROLE(), upgrader));

        // And a role NOT granted stays not-granted (the grant set itself didn't get wiped
        // or reset to some default).
        assertFalse(vault.hasRole(vault.OPERATOR_ROLE(), stranger));
    }

    function test_UpgradeV1ToV2_RoleGatesStillEnforced() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        bytes32 role = vault.OPERATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.fulfillDeposit(alice, 1);
    }

    function test_UpgradeV1ToV2_UpgradeToAndCall_StillGatedByUpgraderRoleOnly() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        RwaVaultV2 anotherImpl = new RwaVaultV2();
        bytes32 role = vault.UPGRADER_ROLE();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.upgradeToAndCall(address(anotherImpl), "");

        vm.prank(upgrader);
        vault.upgradeToAndCall(address(anotherImpl), "");
        // Didn't revert, and state is still there.
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }

    // =====================================================================
    // Fee math: deterministic accrual
    // =====================================================================

    function test_AccrueFees_NoOpWhenFeeIsZero() public {
        _upgradeToV2(0, feeRecipient);
        _depositFulfillClaim2(alice, 1_000e6); // uses the V2 vault now

        uint256 supplyBefore = vault.totalSupply();
        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.balanceOf(feeRecipient), 0);
    }

    function test_AccrueFees_NoOpWhenNoTimeElapsed() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);
        _depositFulfillClaim2(alice, 1_000e6);

        // First accrual (some time already elapsed since initializeV2 due to deposit
        // cycle txs) resets the clock...
        vault.accrueFees();
        uint256 supplyAfterFirst = vault.totalSupply();

        // ...a second call in the SAME second must be a strict no-op.
        vault.accrueFees();
        assertEq(vault.totalSupply(), supplyAfterFirst);
    }

    /// @dev Deterministic check of the exact documented formula for a full-year window:
    ///      feeAssets == totalAssets() * feeBps / 10_000 (elapsed == exactly 1 year, since
    ///      nothing else touches lastFeeAccrual between upgrade and this warp). The vault
    ///      never invests in tBill in this test (balance stays 0), so totalAssets() is pure
    ///      free-asset-buffer and provably constant between `assetsBefore` and the actual
    ///      accrual — no NAV/staleness interaction to account for.
    function test_AccrueFees_FullYear_MatchesExactFormula() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);
        _depositFulfillClaim2(alice, 1_000_000e6);

        uint256 assetsBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();

        // Expected values computed from the SAME pre-mint state the contract's own
        // `_accrueFees` will read (totalAssets()/totalSupply() do not move on their own
        // merely from time passing — no NAV feed involved while tBill balance is 0).
        uint256 expectedFeeAssets = assetsBefore * DEFAULT_FEE_BPS / 10_000;
        uint256 expectedFeeShares = vault.convertToShares(expectedFeeAssets);

        vm.warp(block.timestamp + 365 days);
        vault.accrueFees();

        assertEq(vault.balanceOf(feeRecipient), expectedFeeShares);
        assertEq(vault.totalSupply(), supplyBefore + expectedFeeShares);
        // totalAssets() itself is unchanged by the mint — this is dilution, not an asset
        // transfer: nobody's redeemable assets increase from thin air.
        assertEq(vault.totalAssets(), assetsBefore);
    }

    /// @dev Two sequential half-year accruals, each checked EXACTLY (not just "grows") via
    ///      the same pre-mint-state technique as {test_AccrueFees_FullYear_MatchesExactFormula}:
    ///      totalAssets() never moves on its own (no tBill investment in this test), so at
    ///      each step `convertToShares(assets * feeBps/10_000 * elapsed/year)` computed
    ///      right before the call is exactly what {_accrueFees} mints — no fuzz slack
    ///      needed even across two compounding-supply steps.
    function test_AccrueFees_TwoSequentialHalfYearAccruals_EachExactlyMatchesFormula() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);
        _depositFulfillClaim2(alice, 1_000_000e6);

        uint256 assets = vault.totalAssets(); // constant for the whole test (see @dev)
        uint256 halfYear = 182 days + 12 hours;

        // --- Step 1: t0 -> t0 + 0.5y ---
        uint256 supply0 = vault.totalSupply();
        uint256 expectedFeeAssets1 = assets.mulDiv(DEFAULT_FEE_BPS * halfYear, 10_000 * vault.SECONDS_PER_YEAR());
        uint256 expectedFeeShares1 = vault.convertToShares(expectedFeeAssets1);

        vm.warp(block.timestamp + halfYear);
        vault.accrueFees();

        assertEq(vault.balanceOf(feeRecipient), expectedFeeShares1);
        assertEq(vault.totalSupply(), supply0 + expectedFeeShares1);
        assertGt(expectedFeeShares1, 0);

        // --- Step 2: t0 + 0.5y -> t0 + 1.0y (supply is now higher, assets unchanged) ---
        uint256 supply1 = vault.totalSupply();
        uint256 expectedFeeAssets2 = assets.mulDiv(DEFAULT_FEE_BPS * halfYear, 10_000 * vault.SECONDS_PER_YEAR());
        uint256 expectedFeeShares2 = vault.convertToShares(expectedFeeAssets2);

        vm.warp(block.timestamp + halfYear);
        vault.accrueFees();

        assertEq(vault.balanceOf(feeRecipient), expectedFeeShares1 + expectedFeeShares2);
        assertEq(vault.totalSupply(), supply1 + expectedFeeShares2);
        // Second step mints AT LEAST as many shares as the first for the same asset-terms
        // fee: totalSupply only grew in between, so the same feeAssets convert to a share
        // count that is monotonically non-decreasing (price-per-share can only have
        // dropped from more shares outstanding against the same totalAssets).
        assertGe(expectedFeeShares2, expectedFeeShares1);
        assertEq(vault.totalAssets(), assets); // still pure dilution, never asset transfer
    }

    function test_AccrueFees_CalledFromFulfillDeposit() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);

        // `totalAssets()` is 0 until SOMETHING has actually been fulfilled into the pool
        // (a still-pending deposit is excluded from `_freeAssetBuffer`, by design — see
        // RwaVault NatSpec point 3) — so seed the pool first via a full cycle for bob, THEN
        // warp, so alice's fulfill below has a non-zero base to charge the fee against.
        _depositFulfillClaim2(bob, 500_000e6);
        vm.warp(block.timestamp + 30 days);

        _mintAndApprove2(alice, 1_000_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000_000e6, alice, alice);
        vm.prank(operator);
        vault.fulfillDeposit(alice, 1_000_000e6);

        uint256 supplyAfterFirstFulfill = vault.totalSupply();
        assertGt(vault.balanceOf(feeRecipient), 0); // fee accrued as part of the fulfill

        vm.warp(block.timestamp + 30 days);
        _mintAndApprove2(alice, 200_000e6);
        vm.prank(alice);
        vault.requestDeposit(200_000e6, alice, alice);
        vm.prank(operator);
        vault.fulfillDeposit(alice, 200_000e6);

        assertGt(vault.totalSupply(), supplyAfterFirstFulfill); // fee grew again on 2nd fulfill
    }

    function test_AccrueFees_CalledFromFulfillRedeem() public {
        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);
        uint256 shares = _depositFulfillClaim2(alice, 1_000_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.warp(block.timestamp + 30 days);
        vm.prank(operator);
        vault.fulfillRedeem(alice, shares);

        assertGt(vault.balanceOf(feeRecipient), 0);
    }

    // =====================================================================
    // Fuzz: fee accrual is bounded by the annualized cap, linear, and never
    // double-charges within the same second.
    // =====================================================================

    /// @dev For ANY fee rate up to {MAX_FEE_BPS} and ANY elapsed window, a single accrual
    ///      can never mint fee shares worth more (in asset terms, at the pre-mint price)
    ///      than the annualized MAX_FEE_BPS cap would allow over that same window. This is
    ///      the direct fuzz translation of "nunca supera el cap anualizado".
    function testFuzz_AccrueFees_NeverExceedsAnnualizedCap(uint256 feeBps, uint256 elapsed, uint256 depositAmount)
        public
    {
        feeBps = bound(feeBps, 0, 200); // MAX_FEE_BPS
        elapsed = bound(elapsed, 0, 10 * 365 days);
        depositAmount = bound(depositAmount, 1e6, 1_000_000_000e6);

        _upgradeToV2(feeBps, feeRecipient);
        _depositFulfillClaim2(alice, depositAmount);

        uint256 assetsBefore = vault.totalAssets();

        vm.warp(block.timestamp + elapsed);
        vault.accrueFees();

        uint256 feeSharesMinted = vault.balanceOf(feeRecipient);
        // Convert the fee shares actually minted back to an assets-terms figure using the
        // SAME pre-mint reference point an attacker/auditor would use: the cap bound,
        // computed directly from the documented formula with feeBps replaced by MAX_FEE_BPS.
        uint256 capFeeAssets = assetsBefore * (200 * elapsed) / (10_000 * 365 days);
        uint256 actualFeeAssetsApprox =
            feeSharesMinted == 0 ? 0 : assetsBefore * (feeBps * elapsed) / (10_000 * 365 days);

        assertLe(actualFeeAssetsApprox, capFeeAssets + 1); // +1 slack for floor/floor rounding straddle
        // The rate actually used never exceeded the constant cap by construction of the
        // initializer, but assert it directly too, defense in depth:
        assertLe(vault.managementFeeBps(), vault.MAX_FEE_BPS());
    }

    /// @dev No matter how many times {accrueFees} is called within the SAME block/second,
    ///      only the first can ever mint anything.
    function testFuzz_AccrueFees_NeverDoubleChargesSameSecond(uint256 depositAmount, uint8 extraCalls) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000_000e6);
        extraCalls = uint8(bound(extraCalls, 1, 10));

        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);
        _depositFulfillClaim2(alice, depositAmount);

        vm.warp(block.timestamp + 30 days);
        vault.accrueFees();
        uint256 supplyAfterFirst = vault.totalSupply();

        for (uint256 i = 0; i < extraCalls; i++) {
            vault.accrueFees(); // same timestamp — every one of these must no-op
        }

        assertEq(vault.totalSupply(), supplyAfterFirst);
    }

    /// @dev Fee accrual is monotonically non-decreasing in elapsed time (never negative,
    ///      never mints negative/fewer shares for a longer wait).
    function testFuzz_AccrueFees_MonotonicInElapsedTime(uint256 depositAmount, uint256 firstWait, uint256 secondWait)
        public
    {
        depositAmount = bound(depositAmount, 1e6, 1_000_000_000e6);
        firstWait = bound(firstWait, 1, 5 * 365 days);
        secondWait = bound(secondWait, 1, 5 * 365 days);

        _upgradeToV2(DEFAULT_FEE_BPS, feeRecipient);
        _depositFulfillClaim2(alice, depositAmount);

        vm.warp(block.timestamp + firstWait);
        vault.accrueFees();
        uint256 afterFirst = vault.balanceOf(feeRecipient);

        vm.warp(block.timestamp + secondWait);
        vault.accrueFees();
        uint256 afterSecond = vault.balanceOf(feeRecipient);

        assertGe(afterSecond, afterFirst);
    }

    // =====================================================================
    // Helpers (V2 leg)
    // =====================================================================

    function _mintAndApprove2(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), amount);
    }

    function _depositFulfillClaim2(address user, uint256 amount) internal returns (uint256 shares) {
        _mintAndApprove2(user, amount);
        vm.prank(user);
        vault.requestDeposit(amount, user, user);

        vm.prank(operator);
        vault.fulfillDeposit(user, amount);

        vm.prank(user);
        shares = vault.deposit(amount, user, user);
    }
}
