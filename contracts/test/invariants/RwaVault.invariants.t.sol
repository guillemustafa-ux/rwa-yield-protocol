// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RwaVault} from "../../src/RwaVault.sol";
import {RwaNavFeed} from "../../src/RwaNavFeed.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {MockUSDC} from "../utils/MockUSDC.sol";
import {RwaVaultHandler} from "./RwaVaultHandler.sol";

/// @title RwaVaultInvariantsTest
/// @notice D3 acceptance bar (ARCHITECTURE.md §5/§6): multi-actor invariant suite for
///         `RwaVault`, plus two Fable-audit follow-ups that don't fit the handler's
///         randomized-sequence shape and are instead explicit, hand-written scenario tests:
///
///           (a) "Assets-in-transit" window (hallazgo a): quantifies, in dollar terms, what
///               happens if `fulfillDeposit`/`fulfillRedeem` lands between `investInTBill`
///               (USDC leaves) and the ASSET_MANAGER's follow-up `tBillToken.mint` (value
///               comes back) — see `test_AssetsInTransitWindow_*` below.
///           (b) Plain `ReentrancyGuard` via proxy (hallazgo b): proves the guard's slot is
///               genuinely never initialized on the PROXY's own storage, and that the
///               sentinel-only comparison (`== ENTERED`, never `== NOT_ENTERED`) still blocks
///               a real reentrant call regardless — see `test_ReentrancyGuard_*` below.
///
///      All state-changing actions used by the invariant campaign are routed exclusively
///      through `RwaVaultHandler` (wired below via `targetContract`) — the fuzzer never
///      calls the vault/tokens/feed directly with an arbitrary sender.
contract RwaVaultInvariantsTest is Test {
    RwaVault internal vault;
    RwaVault internal implementation;
    MockUSDC internal asset;
    TBillToken internal tBillToken;
    RwaNavFeed internal navFeed;
    RwaVaultHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal assetManager = makeAddr("assetManager");
    address internal tBillAdmin = makeAddr("tBillAdmin");
    address internal navAdmin = makeAddr("navAdmin");

    // Named actors reused by the two standalone scenario tests below (distinct from the
    // handler's own internal actor pool, which the handler owns privately).
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    int256 internal constant INITIAL_NAV = 100e8;

    /// @dev keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1))
    ///      & ~bytes32(uint256(0xff)) — reproduces, rather than hardcodes, the exact formula
    ///      documented in `ReentrancyGuard.sol` so this constant is independently verifiable
    ///      by reading the comment there, not just trusted. Cross-checked against the
    ///      literal hex constant in that file via `cast keccak` before writing this file.
    bytes32 internal constant REENTRANCY_GUARD_STORAGE_SLOT = bytes32(
        uint256(keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)))
            & ~uint256(0xff)
    );

    function setUp() public {
        // Windows/foundry gotcha: local timestamp starts at 1 — warp before anything reads it.
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
        vm.stopPrank();

        // Role hash cached BEFORE the prank — a view read sandwiched between vm.prank and
        // the intended call consumes the prank (Windows/foundry gotcha, bit us 3x already).
        bytes32 tBillAssetManagerRole = tBillToken.ASSET_MANAGER_ROLE();
        vm.prank(tBillAdmin);
        tBillToken.grantRole(tBillAssetManagerRole, assetManager);

        vm.prank(navAdmin);
        navFeed.updateNav(INITIAL_NAV);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("handlerActorA");
        actors[1] = makeAddr("handlerActorB");
        actors[2] = makeAddr("handlerActorC");
        actors[3] = makeAddr("handlerActorD");

        handler = new RwaVaultHandler(vault, asset, tBillToken, navFeed, operator, assetManager, navAdmin, actors);

        targetContract(address(handler));
    }

    // =====================================================================
    // Helpers for the two standalone scenario tests (a)/(b) below — NOT used by the
    // handler-driven invariant campaign, which is fully self-contained in RwaVaultHandler.
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

    // =====================================================================
    // Invariants (ARCHITECTURE.md §5)
    // =====================================================================

    /// @notice (1) SOLVENCIA: the vault must always physically hold enough of the underlying
    ///         asset to cover what's still owed to un-fulfilled depositors plus what's
    ///         already earmarked for fulfilled-but-unclaimed redeems.
    function invariant_Solvency() public view {
        uint256 assetBalance = asset.balanceOf(address(vault));
        uint256 reserved = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();
        assertGe(assetBalance, reserved, "SOLVENCY: vault asset balance < pendingDeposit+claimableRedeem reserve");
    }

    /// @notice (2) NAV value of holdings + free buffer >= liability with depositors (shares
    ///         outstanding, valued via the vault's own `convertToAssets`). Skipped ONLY when
    ///         a nonzero tBILL holding would force a read against a stale/invalid NAV feed —
    ///         that revert is the contract's documented fail-safe (ARCHITECTURE.md §4), not
    ///         a solvency violation, and is never silently swallowed for any OTHER reason
    ///         (no blanket try/catch around the actual assertion).
    function invariant_NavBackedValueCoversShareLiability() public view {
        (, int256 answer,, uint256 updatedAt,) = navFeed.latestRoundData();
        bool fresh = answer > 0 && block.timestamp <= updatedAt + vault.MAX_STALENESS();
        uint256 tBillBal = tBillToken.balanceOf(address(vault));

        if (tBillBal > 0 && !fresh) {
            return;
        }

        uint256 totalAssetsNow = vault.totalAssets();
        uint256 liability = vault.convertToAssets(vault.totalSupply());
        assertLe(liability, totalAssetsNow, "NAV-backed totalAssets() cannot cover the outstanding share liability");
    }

    /// @notice (3) Conservación por actor: pending + claimable + claimed == solicitado,
    ///         independently on the deposit side and the redeem side, for every actor the
    ///         handler ever touched.
    function invariant_PerActorConservation() public view {
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];

            uint256 depositSum =
                vault.pendingDeposit(a) + vault.claimableDepositAssets(a) + handler.ghost_claimedDepositAssets(a);
            assertEq(
                depositSum,
                handler.ghost_requestedDepositAssets(a),
                "deposit-side conservation broken: pending+claimable+claimed != requested"
            );

            uint256 redeemSum =
                vault.pendingRedeem(a) + vault.claimableRedeemShares(a) + handler.ghost_claimedRedeemShares(a);
            assertEq(
                redeemSum,
                handler.ghost_requestedRedeemShares(a),
                "redeem-side conservation broken: pending+claimable+claimed != requested"
            );
        }
    }

    /// @notice (4) Shares nunca gratis: `totalSupply()` only ever moves through the two
    ///         mint/burn call sites the handler tracks (`fulfillDeposit` mints exactly the
    ///         shares it returns; `fulfillRedeem` burns exactly the shares it's given).
    function invariant_SharesOnlyMintedViaFulfillDeposit() public view {
        uint256 expectedSupply =
            handler.ghost_totalSharesMintedViaFulfillDeposit() - handler.ghost_totalSharesBurnedViaFulfillRedeem();
        assertEq(
            vault.totalSupply(), expectedSupply, "totalSupply diverged from the only two known mint/burn call sites"
        );
    }

    /// @notice (5) El buffer reservado (`totalPendingDepositAssets + totalClaimableRedeemAssets`)
    ///         NUNCA baja como consecuencia de `investInTBill` — checked live by the handler
    ///         on every single call (see `ghost_reservedBufferDecreasedByInvest`), asserted
    ///         here as a permanent "never happened across the whole run" property.
    function invariant_ReservedBufferNeverDecreasesViaInvest() public view {
        assertFalse(
            handler.ghost_reservedBufferDecreasedByInvest(),
            "investInTBill decreased the reserved pendingDeposit+claimableRedeem buffer"
        );
    }

    // =====================================================================
    // (a) Assets-in-transit window — Fable audit hallazgo (a). Quantifies the gap between
    //     `investInTBill` (USDC leaves) and the ASSET_MANAGER's follow-up `tBillToken.mint`
    //     (value returns): a `fulfillDeposit` landing INSIDE that gap prices new shares
    //     against a `totalAssets()` that has been temporarily crushed toward zero, massively
    //     over-minting shares to whoever gets fulfilled there at the expense of every
    //     existing holder. ASSET_MANAGER_ROLE is a trusted role (contract NatSpec point 4)
    //     — this is not a permissionless exploit — but the MAGNITUDE of the damage if the
    //     two legs aren't kept atomic is large enough to need its own name and number.
    //
    //     Operational mitigation (documented here, not code-enforced): the OPERATOR must
    //     never call `fulfillDeposit`/`fulfillRedeem` while there is an in-flight
    //     `investInTBill` whose matching `tBillToken.mint` hasn't landed yet — i.e. only
    //     fulfill when "assets in transit" == 0. `test_AssetsInTransitWindow_Mitigated...`
    //     below proves that discipline alone (no source change) fully restores fairness.
    // =====================================================================

    function test_AssetsInTransitWindow_FulfillDuringGap_DilutesExistingDepositor() public {
        uint256 aliceShares = _depositFulfillClaim(alice, 1_000e6);
        assertEq(vault.convertToAssets(aliceShares), 1_000e6);

        // ASSET_MANAGER pulls Alice's USDC out to fund the off-chain purchase. The matching
        // tBILL mint has NOT happened yet — this is the transit gap.
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        assertEq(vault.totalAssets(), 0, "assets-in-transit: totalAssets() collapses to zero mid-settlement");

        // Bob deposits an equal amount and the OPERATOR fulfills him RIGHT NOW, inside the
        // gap (before the tBILL mint below). His shares get priced against totalAssets()==0.
        _mintAndApprove(bob, 1_000e6);
        vm.prank(bob);
        vault.requestDeposit(1_000e6, bob, bob);
        vm.prank(operator);
        uint256 bobShares = vault.fulfillDeposit(bob, 1_000e6);

        // Only now does the ASSET_MANAGER complete the other leg of ALICE's trade.
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6); // 10 tBILL @ NAV 100 == Alice's 1,000 USDC

        vm.prank(bob);
        vault.deposit(1_000e6, bob, bob);

        // Bob contributed the exact same 1,000 USDC as Alice but, fulfilled while
        // totalAssets() read as ~0, was minted orders of magnitude more shares per asset.
        assertGt(
            bobShares,
            aliceShares * 1000,
            "expected the in-transit fulfill to mint >1000x more shares per asset than Alice's fair fulfill"
        );

        // Quantify the damage in dollar terms: pool value is back to a sane 2,000 USDC
        // (Alice's 1,000 now in tBILL + Bob's 1,000 in the free buffer)...
        uint256 totalValue = vault.totalAssets();
        assertApproxEqAbs(totalValue, 2_000e6, 10);

        // ...but Alice's PROPORTIONAL claim on that 2,000 USDC has been diluted to a sliver
        // of the 1,000 USDC she actually put in.
        uint256 aliceValueAfter = vault.convertToAssets(aliceShares);
        assertLt(aliceValueAfter, 1e6, "Alice's 1,000 USDC claim was diluted to under 1 USDC by the in-transit fulfill");
    }

    function test_AssetsInTransitWindow_MitigatedByFulfillingOnlyAfterMintCompletes() public {
        uint256 aliceShares = _depositFulfillClaim(alice, 1_000e6);

        vm.prank(assetManager);
        vault.investInTBill(1_000e6);

        // Operational mitigation: close BOTH legs of the trade before fulfilling ANYTHING
        // that would price against this gap ("fulfillear solo con transit=0").
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);
        assertEq(vault.totalAssets(), 1_000e6, "transit closed before any fulfill: totalAssets recovered");

        uint256 bobShares = _depositFulfillClaim(bob, 1_000e6);

        // With the gap closed before fulfilling, Bob's shares-per-asset ratio matches
        // Alice's almost exactly — the dilution in the test above is entirely attributable
        // to fulfilling INSIDE the gap, not to anything else about the two-step design.
        assertApproxEqRel(bobShares, aliceShares, 0.0001e18); // within 0.01%
    }

    // =====================================================================
    // (c) Redeem-side liquidity gap — discovered BY the invariant fuzzer itself (first run
    //     of `invariant_Solvency`, seed logged in notes), not requested by the audit brief.
    //     `fulfillRedeem` has NO on-chain liquidity check: it prices `assets` purely off NAV
    //     (which counts illiquid tBILL holdings) and commits to `totalClaimableRedeemAssets`
    //     regardless of the vault's actual raw cash balance. This is the exact mirror image
    //     of hallazgo (a) (deposit-side "assets-in-transit"), but on the redeem side, and it
    //     was NOT previously called out anywhere in contract NatSpec / ARCHITECTURE.md §4.
    //     Not fixed here (src/ is out of this task's ownership and this reads as a
    //     trust-boundary design choice symmetric to the deposit side, not an implementation
    //     slip) — flagged for Fable/Guille to decide: either document it explicitly next to
    //     contract NatSpec point 4, or add a `_freeAssetBuffer()`-style cap to `fulfillRedeem`.
    // =====================================================================

    function test_RedeemLiquidityGap_FulfillBeyondLiquidBuffer_CreatesUnbackedClaim() public {
        // Alice deposits and ASSET_MANAGER invests the WHOLE buffer in tBILL: value is real
        // (NAV-backed) but no longer liquid — the vault's raw USDC balance drops to zero.
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);
        assertEq(asset.balanceOf(address(vault)), 0, "no liquid USDC left in the vault");
        assertEq(vault.totalAssets(), 1_000e6, "value is intact, just illiquid");

        // Alice requests a full redeem. fulfillRedeem has no liquidity check — OPERATOR_ROLE
        // can fulfill it right now even though there is not one wei of USDC to pay it out.
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(operator);
        uint256 fulfilledAssets = vault.fulfillRedeem(alice, shares);

        assertEq(fulfilledAssets, 1_000e6);
        assertEq(vault.totalClaimableRedeemAssets(), 1_000e6);
        // The literal "raw cash >= reserved" solvency reading is broken the instant this
        // lands: the vault owes 1,000 USDC in claimable-redeem-assets but holds zero.
        assertLt(asset.balanceOf(address(vault)), vault.totalClaimableRedeemAssets());

        // Alice cannot actually get paid until ASSET_MANAGER sells tBILL back for cash — a
        // claim attempt reverts for lack of funds (plain ERC-20 insufficient balance).
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
    }

    function test_RedeemLiquidityGap_MitigatedByDivestingBeforeFulfilling() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        // Operational mitigation: divest (sell tBILL for cash) BEFORE fulfilling, so the
        // claim this creates is immediately backed by real liquidity — no source change.
        asset.mint(assetManager, 1_000e6); // stand-in for realized off-chain sale proceeds
        vm.startPrank(assetManager);
        asset.approve(address(vault), 1_000e6);
        vault.divestFromTBill(1_000e6);
        tBillToken.burn(address(vault), 10e6);
        vm.stopPrank();

        vm.prank(operator);
        uint256 fulfilledAssets = vault.fulfillRedeem(alice, shares);
        assertGe(asset.balanceOf(address(vault)), vault.totalClaimableRedeemAssets());

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertEq(assetsOut, fulfilledAssets);
    }

    // =====================================================================
    // (b) ReentrancyGuard via an uninitialized proxy slot — Fable audit hallazgo (b).
    //     `RwaVault` deliberately uses the PLAIN (non-upgradeable) `ReentrancyGuard`, whose
    //     constructor (which sets the slot to NOT_ENTERED) only ever runs on the
    //     IMPLEMENTATION contract's own storage during ITS deployment — never on any proxy's
    //     storage, since constructors are never delegatecalled. This proves the guard still
    //     works correctly on a proxy whose copy of that slot was NEVER explicitly set.
    // =====================================================================

    function test_ReentrancyGuard_UninitializedProxySlot_StillBlocksReentrantCall() public {
        ReentrantAsset maliciousAsset = new ReentrantAsset();

        RwaVault impl2 = new RwaVault();
        bytes memory initData =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(maliciousAsset)), tBillToken, navFeed, admin));
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        RwaVault attackVault = RwaVault(address(proxy2));
        maliciousAsset.setTarget(attackVault);

        // The proxy's copy of the ReentrancyGuard storage slot was NEVER written: `initialize`
        // never calls any Reentrancy-related init step, and the constructor that sets it to
        // NOT_ENTERED ran only on `impl2`'s own storage, during `impl2`'s own deployment.
        bytes32 slotBefore = vm.load(address(attackVault), REENTRANCY_GUARD_STORAGE_SLOT);
        assertEq(slotBefore, bytes32(0), "expected the proxy's guard slot to start at zero (never initialized)");

        // A first, ordinary (non-reentrant) call succeeds — proving zero behaves exactly
        // like NOT_ENTERED, per the comparison-only-against-ENTERED design.
        maliciousAsset.mint(alice, 100e6);
        vm.prank(alice);
        maliciousAsset.approve(address(attackVault), type(uint256).max);
        vm.prank(alice);
        attackVault.requestDeposit(10e6, alice, alice);
        assertEq(attackVault.pendingDeposit(alice), 10e6);

        bytes32 slotAfterFirstCall = vm.load(address(attackVault), REENTRANCY_GUARD_STORAGE_SLOT);
        assertEq(uint256(slotAfterFirstCall), 1, "NOT_ENTERED sentinel (per ReentrancyGuard.sol) after a clean call");

        // Now actually reenter: mid-`transferFrom`, the malicious asset calls back into
        // `requestDeposit` on the SAME call stack. The guard must block this even though its
        // only prior write (above) came from `_nonReentrantAfter`, never a constructor/initializer.
        maliciousAsset.arm(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        attackVault.requestDeposit(10e6, alice, alice);
    }
}

/// @dev Test-only malicious ERC-20: on `transferFrom`, if armed, re-enters
///      `RwaVault.requestDeposit` mid-transfer to attempt a reentrant call on the same
///      `nonReentrant` call stack. Disarms itself before recursing so a would-be successful
///      reentry (i.e. a broken guard) wouldn't recurse forever — it only needs to prove ONE
///      nested call is blocked. Never deployed outside this scenario test.
contract ReentrantAsset is ERC20 {
    RwaVault public target;
    bool public armed;

    constructor() ERC20("Reentrant Attacker Token", "RATK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTarget(RwaVault target_) external {
        target = target_;
    }

    function arm(bool armed_) external {
        armed = armed_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        if (armed) {
            armed = false;
            target.requestDeposit(1, from, from);
        }
        return ok;
    }
}
