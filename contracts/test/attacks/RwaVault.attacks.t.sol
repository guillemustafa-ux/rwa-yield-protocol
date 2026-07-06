// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RwaVault} from "../../src/RwaVault.sol";
import {RwaNavFeed} from "../../src/RwaNavFeed.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockUSDC} from "../utils/MockUSDC.sol";

/// @dev Malicious ERC-20 whose `transfer` calls back into `RwaVault.redeem` the instant
///      it is used to pay out a claim (RwaVault.sol's `redeem`/`withdraw` both end with
///      `IERC20(asset()).safeTransfer(receiver, assets)`). Used ONLY by
///      {RwaVaultAttacksTest-test_Finding_ReentrancyGuardWorksViaProxy} to prove
///      `nonReentrant` actually blocks a live reentrancy attempt through the proxy, not
///      merely that the slot layout looks safe on paper.
contract ReentrantAsset is ERC20 {
    RwaVault private _target;
    bool private _armed;
    uint256 private _shares;
    address private _receiver;
    address private _controller;

    constructor() ERC20("Reentrant Evil Asset", "EVIL") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Arms a one-shot reentrant call: the NEXT `transfer()` this token makes will
    ///      try to re-enter `target.redeem(shares_, receiver_, controller_)`.
    function arm(RwaVault target_, uint256 shares_, address receiver_, address controller_) external {
        _target = target_;
        _armed = true;
        _shares = shares_;
        _receiver = receiver_;
        _controller = controller_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (_armed) {
            _armed = false; // one-shot — avoid an infinite loop if the guard ever failed
            _target.redeem(_shares, _receiver, _controller);
        }
        return ok;
    }
}

/// @title RwaVaultAttacksTest
/// @notice Adversarial suite per ARCHITECTURE.md §3/§4/§5 D3 acceptance bar: one test
///         with an explicit name per row of the §4 self-audit table, plus the two
///         findings from the Fable D2 audit (assets-in-transit window, and the plain
///         `ReentrancyGuard`-via-proxy claim). Every test deploys `RwaVault` ONLY
///         through an `ERC1967Proxy` + `initialize`, mirroring D4's real deploy path
///         and RwaVault.t.sol's own convention. This file does not modify `src/` —
///         every finding here is either a demonstrated (and bounded/mitigated) design
///         trade-off, or is exercised without needing a code change.
contract RwaVaultAttacksTest is Test {
    RwaVault internal vault;
    RwaVault internal implementation;
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

    int256 internal constant INITIAL_NAV = 100e8; // 100.00000000, 8 decimals
    uint256 internal constant ONE_HOUR = 1 hours;

    /// @dev Storage slot `ReentrancyGuard` (openzeppelin-contracts/utils/ReentrancyGuard.sol,
    ///      the OZ 5.6.1-generation, ERC-7201-namespaced rewrite) keeps `_status` in.
    ///      Copied verbatim from that file's `REENTRANCY_GUARD_STORAGE` constant — see
    ///      contract NatSpec point 1 in RwaVault.sol.
    bytes32 internal constant REENTRANCY_GUARD_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function setUp() public {
        // Windows/foundry gotcha: local timestamp starts at 1 — warp in setUp so
        // MAX_STALENESS/MIN_UPDATE_INTERVAL comparisons downstream are meaningful.
        vm.warp(1_700_000_000);

        asset = new MockUSDC();
        tBillToken = new TBillToken(tBillAdmin);
        navFeed = new RwaNavFeed(navAdmin, "tBILL / USD NAV");

        implementation = new RwaVault();
        bytes memory initData =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(asset)), tBillToken, navFeed, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RwaVault(address(proxy));

        vm.startPrank(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), assetManager);
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vault.grantRole(vault.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();

        // TBillToken is a SEPARATE AccessControl instance — assetManager needs its
        // OWN grant there too. Role hash cached BEFORE the prank — a view call
        // sandwiched between vm.prank and the intended call consumes the prank
        // (Windows/foundry gotcha, bit 3 times already in this repo).
        bytes32 tBillAssetManagerRole = tBillToken.ASSET_MANAGER_ROLE();
        vm.prank(tBillAdmin);
        tBillToken.grantRole(tBillAssetManagerRole, assetManager);

        // First NAV round: no deviation/frequency guard applies to it (RwaNavFeed D1).
        vm.prank(navAdmin);
        navFeed.updateNav(INITIAL_NAV);
    }

    // =====================================================================
    // Helpers (mirroring RwaVault.t.sol's conventions — this file owns its own copy,
    // no cross-file dependency, per the exclusive-ownership rule on this test file)
    // =====================================================================

    function _mintAndApprove(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), amount);
    }

    function _depositFulfillClaim(address user, uint256 amount) internal returns (uint256 shares) {
        _mintAndApprove(user, amount);
        vm.prank(user);
        vault.requestDeposit(amount, user, user);
        vm.prank(operator);
        vault.fulfillDeposit(user, amount);
        vm.prank(user);
        shares = vault.deposit(amount, user, user);
    }

    /// @dev Underlying-asset-to-share virtual offset scale (`10 ** _decimalsOffset()`),
    ///      derived from the live contracts rather than hardcoded, so the "expected"
    ///      helpers below track `RwaVault`'s actual configured offset.
    function _offsetScale() internal view returns (uint256) {
        return 10 ** (vault.decimals() - asset.decimals());
    }

    /// @dev Mirrors `ERC4626Upgradeable._convertToShares(assets, Floor)` EXACTLY —
    ///      used to compute what `fulfillDeposit` MUST return, so tests assert equality
    ///      against the documented formula rather than an approximate expectation.
    function _expectedConvertToShares(uint256 assets) internal view returns (uint256) {
        return assets * (vault.totalSupply() + _offsetScale()) / (vault.totalAssets() + 1);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Oracle staleness / feed muerto"
    // =====================================================================

    /// @notice Feed dead for > MAX_STALENESS: new fulfills revert; buckets already
    ///         fixed BEFORE the outage still claim fine (claim never reads the oracle).
    function test_Attack_StaleOracle_BlocksFulfills() public {
        address carol = makeAddr("staleOracleCarol");

        // Carol's deposit is fulfilled (her bucket is FIXED) while the feed is fresh.
        _mintAndApprove(carol, 1_000e6);
        vm.prank(carol);
        vault.requestDeposit(1_000e6, carol, carol);
        vm.prank(operator);
        uint256 carolShares = vault.fulfillDeposit(carol, 1_000e6);

        // A tBill holding now exists, so every future totalAssets()/fulfill call
        // funnels through _latestNav() (a zero tBill balance would have skipped it).
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        // Bob's request happens before the outage but is NOT fulfilled yet.
        address bob = makeAddr("staleOracleBob");
        _mintAndApprove(bob, 500e6);
        vm.prank(bob);
        vault.requestDeposit(500e6, bob, bob);

        // The feed goes dark for MAX_STALENESS + 1.
        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        uint256 staleTimestamp = updatedAt + vault.MAX_STALENESS() + 1;
        vm.warp(staleTimestamp);

        // New fulfills (deposit AND redeem side) revert — never a silent stale price.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.fulfillDeposit(bob, 500e6);

        // Carol claims her already-fixed bucket (needs no oracle read at all — see
        // the companion test below) so she actually HOLDS shares to queue a redeem.
        vm.prank(carol);
        vault.deposit(1_000e6, carol, carol);

        vm.prank(carol);
        vault.requestRedeem(carolShares, carol, carol);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.fulfillRedeem(carol, carolShares);

        // But Bob's request from BEFORE the outage is untouched — still there, waiting.
        assertEq(vault.pendingDeposit(bob), 500e6);
    }

    /// @dev Companion assertion: a bucket fixed BEFORE the outage claims with zero
    ///      oracle dependency at all, so the claim path survives an indefinitely stale
    ///      feed (unlike fulfillDeposit/fulfillRedeem, which always need a fresh read).
    function test_Attack_StaleOracle_AlreadyFixedBucketsStillClaim() public {
        address carol = makeAddr("staleOracleClaimCarol");
        _mintAndApprove(carol, 1_000e6);
        vm.prank(carol);
        vault.requestDeposit(1_000e6, carol, carol);
        vm.prank(operator);
        uint256 carolShares = vault.fulfillDeposit(carol, 1_000e6);

        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        vm.warp(updatedAt + vault.MAX_STALENESS() + 1_000_000);

        vm.prank(carol);
        uint256 claimed = vault.deposit(1_000e6, carol, carol); // does NOT revert
        assertEq(claimed, carolShares);
        assertEq(vault.balanceOf(carol), carolShares);
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Manipulación/fat-finger del NAV"
    // =====================================================================

    /// @notice A 10x fat-finger typo reverts outright; the MOST damage any single
    ///         approved NAV update can inflict on totalAssets() is exactly ±5%.
    function test_Attack_NavFatFinger_BoundedByDeviation() public {
        // Fully invest so totalAssets() tracks the NAV 1:1 (zero non-NAV buffer) —
        // makes the "5% max damage per update" bound exact, not diluted by a buffer.
        _depositFulfillClaim(alice, 1_000e6);
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6); // 10 tBILL @ NAV 100 == 1,000 USDC

        uint256 totalAssetsBefore = vault.totalAssets();
        assertEq(totalAssetsBefore, 1_000e6);

        (, int256 prevNav,, uint256 updatedAt,) = navFeed.latestRoundData();
        vm.warp(updatedAt + ONE_HOUR + 1);

        // A typo that moves the NAV an order of magnitude (100.00 -> 1,000.00)...
        int256 badNav = prevNav * 10;
        uint256 badDeviationBps = uint256(badNav - prevNav) * navFeed.BPS_DENOMINATOR() / uint256(prevNav);
        vm.prank(navAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(RwaNavFeed.NavDeviationTooHigh.selector, prevNav, badNav, badDeviationBps)
        );
        navFeed.updateNav(badNav);

        // ...never propagates: totalAssets() is completely unaffected by the rejection.
        assertEq(vault.totalAssets(), totalAssetsBefore);

        // The largest APPROVED move (exactly the ±5% band) is accepted...
        int256 maxAllowedNav = prevNav + (prevNav * int256(navFeed.MAX_DEVIATION_BPS())) / int256(navFeed.BPS_DENOMINATOR());
        vm.prank(navAdmin);
        navFeed.updateNav(maxAllowedNav);

        // ...and quantifiably bounded: real increase happened, but never more than +5%.
        uint256 totalAssetsAfter = vault.totalAssets();
        assertGt(totalAssetsAfter, totalAssetsBefore);
        assertLe(totalAssetsAfter, totalAssetsBefore * 105 / 100);
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Manipulación/fat-finger del NAV" (compromised-key variant)
    // =====================================================================

    /// @notice An attacker holding a compromised NAV_UPDATER_ROLE key cannot drain the
    ///         vault in one transaction — riding the deviation band as hard and as
    ///         often as physically allowed for 24 straight hours compounds to a
    ///         bounded, deterministic ~3.2x drift, not an instant catastrophic move.
    function test_Attack_NavKeyCompromise_RateLimited() public {
        _depositFulfillClaim(alice, 1_000e6);
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);
        uint256 totalAssetsBefore = vault.totalAssets();

        (, int256 initialNav,,,) = navFeed.latestRoundData();
        uint256 bps = navFeed.MAX_DEVIATION_BPS();
        uint256 denom = navFeed.BPS_DENOMINATOR();
        uint256 interval = navFeed.MIN_UPDATE_INTERVAL();

        int256 expectedNav = initialNav;
        for (uint256 i = 0; i < 24; i++) {
            vm.warp(block.timestamp + interval + 1);
            expectedNav = expectedNav + (expectedNav * int256(bps)) / int256(denom);
            // `navAdmin` stands in for "an attacker who has compromised this key" —
            // the compromise grants exactly the same on-chain powers navAdmin has.
            vm.prank(navAdmin);
            navFeed.updateNav(expectedNav);
        }

        (, int256 finalNav,,,) = navFeed.latestRoundData();
        assertEq(finalNav, expectedNav); // deterministic — identical integer formula

        // Quantified envelope: (1 + 5%)^24 ~= 3.2251x. Bounded, not catastrophic.
        assertGt(uint256(finalNav), uint256(initialNav) * 3);
        assertLt(uint256(finalNav), uint256(initialNav) * 33 / 10);

        // Same bound, in dollar terms, visible on the vault itself.
        uint256 totalAssetsAfter = vault.totalAssets();
        assertGt(totalAssetsAfter, totalAssetsBefore * 3);
        assertLt(totalAssetsAfter, totalAssetsBefore * 33 / 10);

        // Crucially, this took 24 separately-mined hours of individually-visible
        // transactions — not one atomic drain. The rate limit is STILL live: a 25th
        // bump attempted with zero additional wait reverts.
        int256 oneMoreBump = expectedNav + (expectedNav * int256(bps)) / int256(denom);
        vm.prank(navAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(RwaNavFeed.TooFrequent.selector, block.timestamp, block.timestamp, interval)
        );
        navFeed.updateNav(oneMoreBump);
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Donation/inflation attack"
    // =====================================================================

    /// @notice Donating raw USDC (or minting tBILL with no matching invest) inflates
    ///         totalAssets() as designed (it's just buffer/NAV), but NEVER grants the
    ///         donor a single share — and the decimals offset keeps a normal victim's
    ///         subsequent deposit from being rounded all the way down to zero.
    function test_Attack_DonationDoesNotInflateShares() public {
        address griefer = makeAddr("griefer");

        // --- USDC donated straight to the vault, bypassing requestDeposit entirely ---
        uint256 donation = 1_000_000e6; // 1,000,000 USDC, never requested/fulfilled
        asset.mint(griefer, donation);
        vm.prank(griefer);
        asset.transfer(address(vault), donation);

        assertEq(vault.totalAssets(), donation); // buffer effect: real, by design
        // ...but the donor gets NOTHING: no pending, no claimable, no shares. Ever.
        assertEq(vault.pendingDeposit(griefer), 0);
        assertEq(vault.claimableDepositShares(griefer), 0);
        assertEq(vault.balanceOf(griefer), 0);

        // Alice deposits normally into the now-inflated pool.
        uint256 depositAmount = 1_000e6;
        _mintAndApprove(alice, depositAmount);
        vm.prank(alice);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.prank(operator);
        uint256 aliceShares = vault.fulfillDeposit(alice, depositAmount);

        // Never zeroed out despite the 1,000x donation — the decimals-offset mitigation
        // (contract NatSpec point 5) holds even though Alice's shares are savaged.
        assertGt(aliceShares, 0);
        uint256 expectedShares = depositAmount * 1e6 / (donation + 1); // totalSupply()==0 pre-fulfill
        assertEq(aliceShares, expectedShares);
        // Without the donation Alice would have received depositAmount * 1e6 (1e15)
        // shares instead of a few hundred — quantified: > 1,000,000x dilution.
        assertLt(aliceShares * 1_000_000, depositAmount * 1e6);

        // --- tBILL "donated" directly: ASSET_MANAGER mints synthetic units with no
        //     matching investInTBill cash pull (same buffer-style effect, via NAV). ---
        uint256 totalAssetsBeforeTBillDonation = vault.totalAssets();
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 5e6); // 5 tBILL @ NAV 100.00000000 == 500 USDC

        uint256 totalAssetsAfterTBillDonation = vault.totalAssets();
        assertEq(totalAssetsAfterTBillDonation - totalAssetsBeforeTBillDonation, 500e6);
        // Same guarantee: minting tBILL grants the asset manager (or anyone) exactly
        // zero shares — it only ever re-prices what EXISTING/FUTURE claimants convert at.
        assertEq(vault.balanceOf(assetManager), 0);
        assertEq(vault.claimableDepositShares(assetManager), 0);
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Rounding 7540 (request vs fulfill)"
    // =====================================================================

    /// @notice 1-wei and prime-sized amounts through request/fulfill/claim, on both the
    ///         deposit and redeem cycles: every rounding step matches the DOCUMENTED
    ///         floor/ceil formula exactly (contract NatSpec point 5) — rounding never
    ///         hands the user more than their exact proportional (floored) share, and
    ///         partial claims never lose value in aggregate even when a single sliver
    ///         floors to zero.
    function test_Attack_RoundingNeverFavorsUser_MicroAmounts() public {
        // Baseline pool at a prime size so subsequent ratios are never suspiciously round.
        _depositFulfillClaim(alice, 999_999_937);

        // === fulfillDeposit with a 1-wei amount: matches the floor formula exactly ===
        address bob = makeAddr("roundingBob");
        _mintAndApprove(bob, 1);
        vm.prank(bob);
        vault.requestDeposit(1, bob, bob);
        uint256 expectedBobShares = _expectedConvertToShares(1);
        vm.prank(operator);
        uint256 bobShares = vault.fulfillDeposit(bob, 1);
        assertEq(bobShares, expectedBobShares);

        // === fulfillDeposit with a prime amount: same exact-formula guarantee ===
        address carol = makeAddr("roundingCarol");
        uint256 carolDeposit = 700_000_009; // prime
        _mintAndApprove(carol, carolDeposit);
        vm.prank(carol);
        vault.requestDeposit(carolDeposit, carol, carol);
        uint256 expectedCarolShares = _expectedConvertToShares(carolDeposit);
        vm.prank(operator);
        uint256 carolShares = vault.fulfillDeposit(carol, carolDeposit);
        assertEq(carolShares, expectedCarolShares);

        // === Partial deposit-claim (floor) of a 3-wei sliver, then the exact
        //     remainder: conservation holds even if the sliver itself floors to 0. ===
        uint256 cSharesBefore = vault.claimableDepositShares(carol);
        uint256 cAssetsBefore = vault.claimableDepositAssets(carol);
        uint256 sliver = 3;
        uint256 expectedSliverShares = sliver * cSharesBefore / cAssetsBefore;
        vm.prank(carol);
        uint256 sliverShares = vault.deposit(sliver, carol, carol);
        assertEq(sliverShares, expectedSliverShares);

        uint256 remainingAssets = vault.claimableDepositAssets(carol);
        vm.prank(carol);
        uint256 restShares = vault.deposit(remainingAssets, carol, carol);
        assertEq(sliverShares + restShares, carolShares); // nothing lost, nothing conjured
        assertEq(vault.claimableDepositAssets(carol), 0);
        assertEq(vault.claimableDepositShares(carol), 0);

        // === Partial mint-claim (ceil) with a 1-share sliver: assets consumed round UP ===
        address dave = makeAddr("roundingDave");
        uint256 daveDeposit = 555_555_557; // prime-ish
        _mintAndApprove(dave, daveDeposit);
        vm.prank(dave);
        vault.requestDeposit(daveDeposit, dave, dave);
        vm.prank(operator);
        vault.fulfillDeposit(dave, daveDeposit);

        uint256 daveCShares = vault.claimableDepositShares(dave);
        uint256 daveCAssets = vault.claimableDepositAssets(dave);
        uint256 expectedAssetsConsumed = _ceilDiv(1 * daveCAssets, daveCShares);
        vm.prank(dave);
        uint256 assetsConsumed = vault.mint(1, dave, dave);
        assertEq(assetsConsumed, expectedAssetsConsumed);
        assertGe(assetsConsumed * daveCShares, 1 * daveCAssets); // ceil never rounds down

        // === Redeem side: prime shares, floor on redeem()-claim, ceil on withdraw() ===
        address eve = makeAddr("roundingEve");
        uint256 eveShares = _depositFulfillClaim(eve, 333_333_331); // prime-ish
        vm.prank(eve);
        vault.requestRedeem(eveShares, eve, eve);
        vm.prank(operator);
        vault.fulfillRedeem(eve, eveShares);

        uint256 eveCShares = vault.claimableRedeemShares(eve);
        uint256 eveCAssets = vault.claimableRedeemAssets(eve);
        uint256 expectedAssetsOut = 1 * eveCAssets / eveCShares; // floor
        vm.prank(eve);
        uint256 assetsOut = vault.redeem(1, eve, eve);
        assertEq(assetsOut, expectedAssetsOut);

        uint256 eveCSharesAfter = vault.claimableRedeemShares(eve);
        uint256 eveCAssetsAfter = vault.claimableRedeemAssets(eve);
        if (eveCAssetsAfter > 0) {
            uint256 expectedSharesConsumed = _ceilDiv(1 * eveCSharesAfter, eveCAssetsAfter);
            vm.prank(eve);
            uint256 sharesConsumed = vault.withdraw(1, eve, eve);
            assertEq(sharesConsumed, expectedSharesConsumed);
            assertGe(sharesConsumed * eveCAssetsAfter, 1 * eveCSharesAfter); // ceil never rounds down
        }
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Uninitialized proxy"
    // =====================================================================

    /// @notice The bare implementation (never behind a proxy) can never be initialized,
    ///         and every operational entry point on it is permanently inert as a result.
    function test_Attack_UninitializedImplementation() public {
        // Permanently locked by `_disableInitializers()` in the constructor.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(IERC20(address(asset)), tBillToken, navFeed, admin);

        // AccessControl-gated functions revert: no role was EVER granted on this
        // instance (initialize, which alone grants DEFAULT_ADMIN_ROLE, never ran).
        bytes32 pauserRole = implementation.PAUSER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), pauserRole)
        );
        implementation.pause();

        bytes32 operatorRole = implementation.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), operatorRole)
        );
        implementation.fulfillDeposit(alice, 1);

        // Even the non-role-gated request path is inoperative: ERC4626 storage
        // (including `asset()`) was never populated by `initialize`, so this reverts too.
        vm.expectRevert();
        implementation.requestDeposit(1, address(this), address(this));
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Role escalation"
    // =====================================================================

    /// @notice None of the three purely-operational roles (OPERATOR/PAUSER/
    ///         ASSET_MANAGER) can grant ANY role — including their own — or push an
    ///         upgrade. Only DEFAULT_ADMIN_ROLE administers roles; only UPGRADER_ROLE
    ///         upgrades.
    function test_Attack_RoleEscalation_OperativeRolesCannotGrant() public {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = vault.UPGRADER_ROLE();
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        bytes32 assetManagerRole = vault.ASSET_MANAGER_ROLE();
        bytes32 pauserRole = vault.PAUSER_ROLE();
        address escalationTarget = makeAddr("roleEscalationTarget");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, adminRole));
        vault.grantRole(operatorRole, escalationTarget);

        vm.prank(assetManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, assetManager, adminRole)
        );
        vault.grantRole(assetManagerRole, escalationTarget);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, adminRole));
        vault.grantRole(pauserRole, escalationTarget);

        // None of the three can push an upgrade either — only UPGRADER_ROLE can.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, upgraderRole));
        vault.upgradeToAndCall(address(0xBEEF), "");

        vm.prank(assetManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, assetManager, upgraderRole)
        );
        vault.upgradeToAndCall(address(0xBEEF), "");

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, upgraderRole));
        vault.upgradeToAndCall(address(0xBEEF), "");
    }

    // =====================================================================
    // ARCHITECTURE.md §4 — "Pausa como DoS"
    // =====================================================================

    /// @notice A request made BEFORE pause rides the ENTIRE exit path — fulfillRedeem,
    ///         then claim — to completion while the vault remains paused THE WHOLE
    ///         TIME. Pause only ever blocks brand-new requests, never an exit already
    ///         in flight.
    function test_Attack_PauseIsNotExitDoS() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice); // request made BEFORE any pause

        vm.prank(pauser);
        vault.pause();

        vm.prank(operator);
        uint256 assets = vault.fulfillRedeem(alice, shares); // still works, paused

        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice); // still works, paused

        assertEq(assetsOut, assets);
        assertEq(asset.balanceOf(alice), aliceBalanceBefore + assetsOut);
        assertTrue(vault.paused()); // the pause was NEVER lifted during this whole flow

        // Contrast: this is the ONLY thing pause legitimately blocks — a brand-new request.
        address bob = makeAddr("pauseDosBob");
        _mintAndApprove(bob, 100e6);
        vm.prank(bob);
        vm.expectRevert(); // PausableUpgradeable.EnforcedPause
        vault.requestDeposit(100e6, bob, bob);
    }

    // =====================================================================
    // Fable D2 audit finding (a) — assets-in-transit window
    // =====================================================================

    /// @notice Quantifies the share-price crash between `investInTBill` pulling USDC
    ///         out and the ASSET_MANAGER actually minting the equivalent tBILL: any
    ///         fulfill that lands INSIDE that window overprices the depositor at the
    ///         existing pool's expense. Demonstrates the documented operational
    ///         mitigation ("fulfillear solo con transit == 0") eliminates it exactly.
    function test_Finding_AssetsInTransitWindow() public {
        // Alice is the only existing depositor: 1,000 USDC in, pure buffer, no tBill.
        _depositFulfillClaim(alice, 1_000e6);
        assertEq(vault.totalAssets(), 1_000e6);

        // ASSET_MANAGER pulls 400 USDC to fund an off-chain purchase but has NOT yet
        // minted the equivalent tBILL — the "assets-in-transit" window is now open.
        vm.prank(assetManager);
        vault.investInTBill(400e6);

        // The 400 has vanished from totalAssets() entirely: not USDC buffer anymore,
        // not yet-priced tBILL either. Quantified: the drop is EXACTLY the invested
        // amount, even though zero real economic value was lost.
        uint256 totalAssetsDuringTransit = vault.totalAssets();
        assertEq(totalAssetsDuringTransit, 600e6);

        uint256 snapshotId = vm.snapshotState();

        // --- Scenario A (the bug window): a NEW deposit is fulfilled WHILE the 400
        //     is still in transit — priced against the artificially shrunk pool. ---
        address bob = makeAddr("transitBob");
        _mintAndApprove(bob, 600e6);
        vm.prank(bob);
        vault.requestDeposit(600e6, bob, bob);
        // "Fair" price = what Bob would get if transit were 0 right now (pool == 1,000).
        uint256 expectedBobSharesFairPricing = 600e6 * (vault.totalSupply() + _offsetScale()) / (1_000e6 + 1);
        vm.prank(operator);
        uint256 bobSharesDuringTransit = vault.fulfillDeposit(bob, 600e6);

        // Bob contributed 600 against a pool nominally still worth 1,000 (once the
        // mint lands), but the transit window prices him against only 600 — he walks
        // away with roughly 1.67x the fair share count, at existing holders' expense.
        assertGt(bobSharesDuringTransit, expectedBobSharesFairPricing);
        assertApproxEqRel(bobSharesDuringTransit, expectedBobSharesFairPricing * 5 / 3, 0.05e18); // ~+67%, +-5%

        // --- Scenario B (the documented mitigation): roll back, close the transit
        //     window FIRST (finish the tBILL mint), THEN fulfill. ---
        vm.revertToState(snapshotId);
        assertEq(vault.totalAssets(), 600e6); // back to the transit window

        vm.prank(assetManager);
        tBillToken.mint(address(vault), 4e6); // 4 tBILL @ NAV 100 == 400 USDC -> transit closed
        assertEq(vault.totalAssets(), 1_000e6); // fully restored, transit == 0

        _mintAndApprove(bob, 600e6);
        vm.prank(bob);
        vault.requestDeposit(600e6, bob, bob);
        vm.prank(operator);
        uint256 bobSharesMitigated = vault.fulfillDeposit(bob, 600e6);

        // Following the mitigation (fulfill only when transit == 0) prices Bob exactly
        // fairly — no windfall, no dilution of Alice.
        assertEq(bobSharesMitigated, expectedBobSharesFairPricing);
        assertLt(bobSharesMitigated, bobSharesDuringTransit);
    }

    // =====================================================================
    // Fable D2 audit finding (b) — plain ReentrancyGuard is proxy-safe
    // =====================================================================

    /// @notice Proves contract NatSpec point 1's claim end-to-end: the proxy's copy of
    ///         `ReentrancyGuard`'s namespaced `_status` slot is NEVER initialized (it
    ///         stays at Solidity's default zero — `ReentrancyGuard`'s constructor only
    ///         ever ran on the standalone `implementation`'s OWN storage, since
    ///         constructors never execute in a delegatecall context), yet `nonReentrant`
    ///         works correctly from that all-zero slot, AND actively blocks a live
    ///         reentrancy attempt via a malicious asset whose `transfer` tries to
    ///         re-enter `redeem` mid-claim.
    /// @dev Confirms the storage-layout half of the claim too: `_status` does NOT
    ///      appear anywhere in `storage-layout/RwaVault.v1.txt` — that file enumerates
    ///      only RwaVault's own contiguous slots 0..11 (`tBillToken` through `__gap`).
    ///      Its absence IS the proof it lives in a separate ERC-7201 namespaced slot,
    ///      entirely outside RwaVault's sequential layout — exactly why a V1->V2
    ///      storage-layout diff (ARCHITECTURE.md §4 "Storage collision en upgrade")
    ///      never needs to account for it.
    function test_Finding_ReentrancyGuardWorksViaProxy() public {
        // The proxy's slot was NEVER touched: still the Solidity default, zero.
        bytes32 beforeSlot = vm.load(address(vault), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(beforeSlot), 0);

        // A normal nonReentrant call works FINE from this all-zero slot...
        _mintAndApprove(alice, 100e6);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, alice);

        // ...and leaves the slot at NOT_ENTERED(1), exactly like a properly
        // constructor-initialized guard would.
        bytes32 afterSlot = vm.load(address(vault), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(afterSlot), 1);

        // --- Now prove the guard actually BLOCKS a real reentrancy attempt, still
        //     via an uninitialized proxy, using a malicious asset whose transfer()
        //     callback tries to re-enter `redeem` mid-claim. ---
        ReentrantAsset evilAsset = new ReentrantAsset();
        RwaVault evilImpl = new RwaVault();
        bytes memory initData =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(evilAsset)), tBillToken, navFeed, admin));
        ERC1967Proxy evilProxy = new ERC1967Proxy(address(evilImpl), initData);
        RwaVault evilVault = RwaVault(address(evilProxy));

        vm.startPrank(admin);
        evilVault.grantRole(evilVault.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        address attacker = makeAddr("reentrancyAttacker");
        uint256 amount = 1_000e6;
        evilAsset.mint(attacker, amount);
        vm.prank(attacker);
        evilAsset.approve(address(evilVault), amount);
        vm.prank(attacker);
        evilVault.requestDeposit(amount, attacker, attacker);
        vm.prank(operator);
        uint256 attackerShares = evilVault.fulfillDeposit(attacker, amount);
        vm.prank(attacker);
        evilVault.deposit(amount, attacker, attacker);

        vm.prank(attacker);
        evilVault.requestRedeem(attackerShares, attacker, attacker);
        vm.prank(operator);
        evilVault.fulfillRedeem(attacker, attackerShares);

        // Arm the malicious asset: the NEXT time it is asked to `transfer` (i.e.
        // inside `redeem`'s payout leg), it tries to re-enter `redeem` for the SAME
        // bucket again. (msg.sender for the reentrant call is `evilAsset`, not
        // `attacker` — irrelevant, since `nonReentrant`'s guard fires before the
        // function body's own `NotAuthorized` check is ever reached.)
        evilAsset.arm(evilVault, attackerShares, attacker, attacker);

        vm.prank(attacker);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        evilVault.redeem(attackerShares, attacker, attacker);
    }
}
