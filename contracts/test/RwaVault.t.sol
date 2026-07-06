// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RwaVault} from "../src/RwaVault.sol";
import {RwaNavFeed} from "../src/RwaNavFeed.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockUSDC} from "./utils/MockUSDC.sol";

/// @title RwaVaultTest
/// @notice Unit + fuzz coverage for `RwaVault` per ARCHITECTURE.md §3.3 and the D2
///         acceptance bar ("unit+fuzz verdes; `forge inspect` del storage layout
///         commiteado; pausa parcial probada"). Deploys the vault ONLY through an
///         ERC1967Proxy + `initialize` — never the raw implementation — matching how
///         it will actually be deployed on Sepolia in D4.
contract RwaVaultTest is Test {
    RwaVault internal vault;
    RwaVault internal implementation;
    MockUSDC internal asset;
    TBillToken internal tBillToken;
    RwaNavFeed internal navFeed;

    // --- actors (role separation is the point of the design, so every role gets its
    //     own address — never reuse `admin` as an operational role holder) ---
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
    address internal delegate = makeAddr("delegate");

    int256 internal constant INITIAL_NAV = 100e8; // 100.00000000, 8 decimals (matches RwaNavFeed)
    uint256 internal constant ONE_HOUR = 1 hours;

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

        // admin appoints operational roles post-deploy — never grants them to itself
        // (contract NatSpec point 2 / ARCHITECTURE.md §3.3 role separation).
        vm.startPrank(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), assetManager);
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vault.grantRole(vault.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();

        // TBillToken is a SEPARATE AccessControl instance — assetManager needs its
        // OWN grant there too (contract NatSpec point 4: role identifiers hash the
        // same but the grants are entirely independent).
        // NOTE: role hash cached BEFORE the prank — a view call sandwiched between
        // vm.prank and the intended call consumes the prank (Windows/foundry gotcha).
        bytes32 tBillAssetManagerRole = tBillToken.ASSET_MANAGER_ROLE();
        vm.prank(tBillAdmin);
        tBillToken.grantRole(tBillAssetManagerRole, assetManager);

        // First NAV round: no deviation/frequency guard applies to it (RwaNavFeed D1).
        vm.prank(navAdmin);
        navFeed.updateNav(INITIAL_NAV);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _mintAndApprove(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(vault), amount);
    }

    /// @dev Full deposit cycle for `user`: request → operator fulfills the whole
    ///      amount → user claims the whole claimable via the 3-arg `deposit`.
    function _depositFulfillClaim(address user, uint256 amount) internal returns (uint256 shares) {
        _mintAndApprove(user, amount);
        vm.prank(user);
        vault.requestDeposit(amount, user, user);

        vm.prank(operator);
        vault.fulfillDeposit(user, amount);

        vm.prank(user);
        shares = vault.deposit(amount, user, user);
    }

    /// @dev Full redeem cycle for `user`: request → operator fulfills the whole
    ///      share amount → user claims the whole claimable via `redeem`.
    function _redeemFulfillClaim(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        vm.prank(operator);
        vault.fulfillRedeem(user, shares);

        vm.prank(user);
        assets = vault.redeem(shares, user, user);
    }

    /// @dev Publishes a new NAV round respecting RwaNavFeed's own rate/deviation
    ///      guards (D1) — warps past MIN_UPDATE_INTERVAL first.
    function _bumpNav(int256 newNav) internal {
        vm.warp(block.timestamp + ONE_HOUR + 1);
        vm.prank(navAdmin);
        navFeed.updateNav(newNav);
    }

    // =====================================================================
    // initialize()
    // =====================================================================

    function test_Initialize_SetsState() public view {
        assertEq(vault.asset(), address(asset));
        assertEq(address(vault.tBillToken()), address(tBillToken));
        assertEq(address(vault.navFeed()), address(navFeed));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(vault.name(), "RWA Yield Vault Share");
        assertEq(vault.symbol(), "rwaYLD");
    }

    /// @dev Contract NatSpec point 2: only DEFAULT_ADMIN_ROLE is granted at
    ///      initialize — the four operational roles must be appointed separately.
    function test_Initialize_DoesNotGrantOperationalRolesToAdmin() public view {
        assertFalse(vault.hasRole(vault.OPERATOR_ROLE(), admin));
        assertFalse(vault.hasRole(vault.ASSET_MANAGER_ROLE(), admin));
        assertFalse(vault.hasRole(vault.PAUSER_ROLE(), admin));
        assertFalse(vault.hasRole(vault.UPGRADER_ROLE(), admin));
    }

    function test_RevertWhen_Initialize_ZeroAsset() public {
        bytes memory badInit =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(0)), tBillToken, navFeed, admin));
        vm.expectRevert(RwaVault.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), badInit);
    }

    function test_RevertWhen_Initialize_ZeroTBillToken() public {
        bytes memory badInit = abi.encodeCall(
            RwaVault.initialize, (IERC20(address(asset)), IERC20Metadata(address(0)), navFeed, admin)
        );
        vm.expectRevert(RwaVault.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), badInit);
    }

    function test_RevertWhen_Initialize_ZeroNavFeed() public {
        bytes memory badInit = abi.encodeCall(
            RwaVault.initialize,
            (IERC20(address(asset)), tBillToken, AggregatorV3Interface(address(0)), admin)
        );
        vm.expectRevert(RwaVault.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), badInit);
    }

    function test_RevertWhen_Initialize_ZeroAdmin() public {
        bytes memory badInit =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(asset)), tBillToken, navFeed, address(0)));
        vm.expectRevert(RwaVault.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), badInit);
    }

    function test_RevertWhen_Reinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(IERC20(address(asset)), tBillToken, navFeed, admin);
    }

    /// @dev The bare implementation (never behind a proxy) must have its initializers
    ///      permanently disabled by the constructor — ARCHITECTURE.md §4 "Uninitialized
    ///      proxy" mitigation, verified directly on the implementation this time.
    function test_RevertWhen_Implementation_InitializedDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(IERC20(address(asset)), tBillToken, navFeed, admin);
    }

    // =====================================================================
    // Roles — every gated function reverts for a caller without its role
    // =====================================================================

    function test_RevertWhen_FulfillDeposit_CallerLacksOperatorRole() public {
        bytes32 role = vault.OPERATOR_ROLE(); // cache before prank (view-after-prank gotcha)
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.fulfillDeposit(alice, 1);
    }

    function test_RevertWhen_FulfillRedeem_CallerLacksOperatorRole() public {
        bytes32 role = vault.OPERATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.fulfillRedeem(alice, 1);
    }

    function test_RevertWhen_InvestInTBill_CallerLacksAssetManagerRole() public {
        bytes32 role = vault.ASSET_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.investInTBill(1);
    }

    function test_RevertWhen_DivestFromTBill_CallerLacksAssetManagerRole() public {
        bytes32 role = vault.ASSET_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.divestFromTBill(1);
    }

    function test_RevertWhen_Pause_CallerLacksPauserRole() public {
        bytes32 role = vault.PAUSER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.pause();
    }

    function test_RevertWhen_Unpause_CallerLacksPauserRole() public {
        vm.prank(pauser);
        vault.pause();

        bytes32 role = vault.PAUSER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.unpause();
    }

    /// @dev `_authorizeUpgrade` runs BEFORE `newImplementation` is validated
    ///      (UUPSUpgradeable calls it first), so the role check fires even against a
    ///      garbage address — no need for a real implementation to prove the gate.
    function test_RevertWhen_Upgrade_CallerLacksUpgraderRole() public {
        bytes32 role = vault.UPGRADER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role));
        vault.upgradeToAndCall(address(0xBEEF), "");
    }

    function test_Upgrade_SucceedsWithUpgraderRole_PreservesState() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);

        RwaVault newImplementation = new RwaVault();
        vm.prank(upgrader);
        vault.upgradeToAndCall(address(newImplementation), "");

        // Storage (balances, roles) survives the swap — same proxy, new logic address.
        assertEq(vault.balanceOf(alice), shares);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }

    // =====================================================================
    // Authorization (ERC-7540 operator delegation, distinct from AccessControl roles)
    // =====================================================================

    function test_RevertWhen_RequestDeposit_CallerNotOwnerNorOperator() public {
        _mintAndApprove(alice, 100e6);
        vm.prank(stranger);
        vm.expectRevert(RwaVault.NotAuthorized.selector);
        vault.requestDeposit(100e6, alice, alice);
    }

    function test_RevertWhen_ClaimDeposit_CallerNotControllerNorOperator() public {
        _mintAndApprove(alice, 100e6);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, alice);
        vm.prank(operator);
        vault.fulfillDeposit(alice, 100e6);

        vm.prank(stranger);
        vm.expectRevert(RwaVault.NotAuthorized.selector);
        vault.deposit(100e6, stranger, alice);
    }

    function test_SetOperator_AllowsDelegatedRequestAndClaim() public {
        _mintAndApprove(alice, 100e6);
        vm.prank(alice);
        vault.setOperator(delegate, true);
        assertTrue(vault.isOperator(alice, delegate));

        vm.prank(delegate);
        vault.requestDeposit(100e6, alice, alice);

        vm.prank(operator);
        vault.fulfillDeposit(alice, 100e6);

        vm.prank(delegate);
        uint256 shares = vault.deposit(100e6, alice, alice);
        assertEq(vault.balanceOf(alice), shares);
    }

    // =====================================================================
    // Happy flow — deposit: requestDeposit → fulfillDeposit → claim
    // =====================================================================

    function test_RequestDeposit_TransfersAssetsAndTracksPending() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        assertEq(asset.balanceOf(address(vault)), 1_000e6);
        assertEq(vault.pendingDeposit(alice), 1_000e6);
        assertEq(vault.totalPendingDepositAssets(), 1_000e6);
        assertEq(vault.pendingDepositRequest(0, alice), 1_000e6);
    }

    function test_RevertWhen_RequestDeposit_ZeroAssets() public {
        vm.prank(alice);
        vm.expectRevert(RwaVault.ZeroAmount.selector);
        vault.requestDeposit(0, alice, alice);
    }

    function test_FulfillDeposit_MintsSharesToVaultAndUpdatesClaimable() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, 1_000e6);

        assertEq(vault.pendingDeposit(alice), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.claimableDepositAssets(alice), 1_000e6);
        assertEq(vault.claimableDepositShares(alice), shares);
        assertEq(vault.balanceOf(address(vault)), shares); // custody until claimed
        assertEq(vault.claimableDepositRequest(0, alice), 1_000e6);
    }

    function test_RevertWhen_FulfillDeposit_ExceedsPending() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        vm.prank(operator);
        vm.expectRevert(RwaVault.ExceedsPending.selector);
        vault.fulfillDeposit(alice, 1_000e6 + 1);
    }

    function test_ClaimDeposit_ViaDeposit_TransfersSharesToReceiver() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, 1_000e6);

        vm.prank(alice);
        uint256 claimedShares = vault.deposit(1_000e6, alice, alice);

        assertEq(claimedShares, shares);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.claimableDepositAssets(alice), 0);
        assertEq(vault.claimableDepositShares(alice), 0);
    }

    function test_ClaimDeposit_ViaMint_TransfersSharesToReceiver() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, 1_000e6);

        vm.prank(alice);
        uint256 assetsConsumed = vault.mint(shares, alice, alice);

        assertEq(assetsConsumed, 1_000e6);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.claimableDepositAssets(alice), 0);
        assertEq(vault.claimableDepositShares(alice), 0);
    }

    function test_RevertWhen_ClaimDeposit_ExceedsClaimable() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        vault.fulfillDeposit(alice, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(RwaVault.ExceedsClaimable.selector);
        vault.deposit(1_000e6 + 1, alice, alice);
    }

    // =====================================================================
    // Happy flow — redeem: requestRedeem → fulfillRedeem → claim
    // =====================================================================

    function test_RequestRedeem_TransfersSharesToVaultAndTracksPending() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.pendingRedeem(alice), shares);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
    }

    function test_RevertWhen_RequestRedeem_ZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(RwaVault.ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
    }

    function test_FulfillRedeem_BurnsSharesAndTracksClaimableAssets() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.prank(operator);
        uint256 assets = vault.fulfillRedeem(alice, shares);

        assertEq(vault.pendingRedeem(alice), 0);
        assertEq(vault.claimableRedeemShares(alice), shares);
        assertEq(vault.claimableRedeemAssets(alice), assets);
        assertEq(vault.totalClaimableRedeemAssets(), assets);
        assertEq(vault.balanceOf(address(vault)), 0); // burned, not held
        assertEq(vault.claimableRedeemRequest(0, alice), shares);
    }

    function test_RevertWhen_FulfillRedeem_ExceedsPending() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.prank(operator);
        vm.expectRevert(RwaVault.ExceedsPending.selector);
        vault.fulfillRedeem(alice, shares + 1);
    }

    function test_ClaimRedeem_ViaRedeem_TransfersAssetsToReceiver() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(operator);
        uint256 fulfilledAssets = vault.fulfillRedeem(alice, shares);

        uint256 balanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertEq(assetsOut, fulfilledAssets);
        assertEq(asset.balanceOf(alice), balanceBefore + assetsOut);
        assertEq(vault.claimableRedeemShares(alice), 0);
        assertEq(vault.claimableRedeemAssets(alice), 0);
        assertEq(vault.totalClaimableRedeemAssets(), 0);
    }

    function test_ClaimRedeem_ViaWithdraw_TransfersAssetsToReceiver() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(operator);
        uint256 fulfilledAssets = vault.fulfillRedeem(alice, shares);

        uint256 balanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 sharesConsumed = vault.withdraw(fulfilledAssets, alice, alice);

        assertEq(sharesConsumed, shares);
        assertEq(asset.balanceOf(alice), balanceBefore + fulfilledAssets);
    }

    function test_RevertWhen_ClaimRedeem_ExceedsClaimable() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(operator);
        vault.fulfillRedeem(alice, shares);

        vm.prank(alice);
        vm.expectRevert(RwaVault.ExceedsClaimable.selector);
        vault.redeem(shares + 1, alice, alice);
    }

    function test_ClaimDeposit_ViaTwoArgOverloads_TreatsCallerAsController() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, 1_000e6);

        assertEq(vault.maxDeposit(alice), 1_000e6);
        assertEq(vault.maxMint(alice), shares);

        vm.prank(alice);
        uint256 claimedShares = vault.deposit(1_000e6, alice); // 2-arg: controller == msg.sender

        assertEq(claimedShares, shares);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_ClaimDeposit_ViaTwoArgMint_TreatsCallerAsController() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, 1_000e6);

        vm.prank(alice);
        uint256 assetsConsumed = vault.mint(shares, alice); // 2-arg: controller == msg.sender

        assertEq(assetsConsumed, 1_000e6);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_MaxRedeemAndMaxWithdraw_ReflectClaimableRedeemBucket() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        vm.prank(operator);
        uint256 assets = vault.fulfillRedeem(alice, shares);

        assertEq(vault.maxRedeem(alice), shares);
        assertEq(vault.maxWithdraw(alice), assets);
    }

    function test_SupportsInterface_AdvertisesErc7540AndAccessControl() public view {
        assertTrue(vault.supportsInterface(0xe3bc4e65)); // operator methods
        assertTrue(vault.supportsInterface(0xce3bbe50)); // async deposit
        assertTrue(vault.supportsInterface(0x620ee8e4)); // async redeem
        assertTrue(vault.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    // =====================================================================
    // Full economic lifecycle with a REAL NAV feed: deposit, invest in tBill, NAV
    // rises with zero transfers, redeem for MORE than was deposited.
    // =====================================================================

    function test_FullLifecycle_InvestAndNavRise_RedeemerGetsMoreThanDeposited() public {
        // 1) Alice deposits 1,000 USDC and claims her shares.
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        assertEq(vault.totalAssets(), 1_000e6); // tBillBalance == 0, pure free buffer

        // 2) ASSET_MANAGER pulls the USDC out to fund the off-chain T-bill purchase,
        //    then mints the equivalent tBILL at the NAV prevailing right now
        //    (100.00000000 -> 1,000 USDC == 10 tBILL units).
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        assertEq(asset.balanceOf(assetManager), 1_000e6);
        assertEq(asset.balanceOf(address(vault)), 0);

        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6); // 10 tBILL units, 6 decimals

        assertEq(vault.totalAssets(), 1_000e6); // unchanged: value merely moved legs

        // 3) NAV appreciates +5% (T-bill accrues) — nobody transfers anything.
        _bumpNav(105e8);
        uint256 tBillBalanceBefore = tBillToken.balanceOf(address(vault));
        uint256 usdcBalanceBefore = asset.balanceOf(address(vault));

        assertEq(vault.totalAssets(), 1_050e6);
        assertEq(tBillToken.balanceOf(address(vault)), tBillBalanceBefore); // no transfer
        assertEq(asset.balanceOf(address(vault)), usdcBalanceBefore); // no transfer

        // 4) Alice redeems ALL her shares.
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        // 5) Cap de liquidez (hallazgo (c), campaña de invariantes D3): fulfillRedeem ya
        //    NO puede prometer contra tBILL ilíquido, así que el test modela el flujo de
        //    settlement real — el manager vende la posición off-chain (burn del tBILL del
        //    vault + retorno del producido realizado) y recién entonces el operador fulfilea.
        uint256 tBillHeld = tBillToken.balanceOf(address(vault));
        uint256 proceeds = 1_050e6; // 10 tBILL x NAV 105.00000000, realizado off-chain
        asset.mint(assetManager, proceeds - asset.balanceOf(assetManager));
        vm.startPrank(assetManager);
        tBillToken.burn(address(vault), tBillHeld);
        asset.approve(address(vault), proceeds);
        vault.divestFromTBill(proceeds);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 1_050e6); // el valor sobrevive el settlement completo

        uint256 expectedAssets = vault.convertToAssets(shares); // documented pricing rule
        vm.prank(operator);
        uint256 fulfilledAssets = vault.fulfillRedeem(alice, shares);
        assertEq(fulfilledAssets, expectedAssets);
        // Floor rounding costs Alice at most a handful of wei — never rounds in her favor.
        assertLe(fulfilledAssets, 1_050e6);
        assertApproxEqAbs(fulfilledAssets, 1_050e6, 10);

        uint256 aliceBalanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);

        assertEq(assetsOut, fulfilledAssets);
        assertEq(asset.balanceOf(alice), aliceBalanceBefore + assetsOut);
        // Alice deposited 1,000 USDC and walks away with (approximately) 1,050 —
        // pure NAV accrual, no one transferred yield in.
        assertGt(assetsOut, 1_000e6);
    }

    // =====================================================================
    // totalAssets() NAV accounting: share price rises with the NAV, zero transfers
    // =====================================================================

    function test_TotalAssets_RisesWithNav_WithNoBalanceChange() public {
        _depositFulfillClaim(alice, 1_000e6);
        vm.prank(assetManager);
        vault.investInTBill(1_000e6);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 tBillBalanceBefore = tBillToken.balanceOf(address(vault));
        uint256 assetBalanceBefore = asset.balanceOf(address(vault));

        _bumpNav(103e8); // +3%, within the ±5% band

        assertGt(vault.totalAssets(), totalAssetsBefore);
        assertEq(tBillToken.balanceOf(address(vault)), tBillBalanceBefore);
        assertEq(asset.balanceOf(address(vault)), assetBalanceBefore);
    }

    function test_TotalAssets_ExcludesPendingDepositAndClaimableRedeem() public {
        // Pending deposit sits in the vault's raw balance but is NOT the pool's yet.
        _mintAndApprove(alice, 500e6);
        vm.prank(alice);
        vault.requestDeposit(500e6, alice, alice);
        assertEq(vault.totalAssets(), 0);

        // Fulfilling makes it part of the pool.
        vm.prank(operator);
        vault.fulfillDeposit(alice, 500e6);
        assertEq(vault.totalAssets(), 500e6);

        // A fulfilled-but-unclaimed redeem is excluded again (contract NatSpec point 3).
        vm.prank(alice);
        vault.deposit(500e6, alice, alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice, alice);
        vm.prank(operator);
        vault.fulfillRedeem(alice, aliceShares);

        assertEq(vault.totalAssets(), 0);
    }

    // =====================================================================
    // Staleness: NAV reads revert once the feed is older than MAX_STALENESS
    // =====================================================================

    function test_RevertWhen_TotalAssets_StaleNav() public {
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6); // non-zero holding forces an oracle read

        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        uint256 staleTimestamp = updatedAt + vault.MAX_STALENESS() + 1;
        vm.warp(staleTimestamp);

        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.totalAssets();
    }

    function test_TotalAssets_DoesNotReadOracle_WhenTBillBalanceIsZero() public {
        // No tBill holdings: _tBillValueInAsset short-circuits, so a stale (or even
        // never-published) NAV must never brick totalAssets().
        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        vm.warp(updatedAt + vault.MAX_STALENESS() + 1_000_000);
        assertEq(vault.totalAssets(), 0); // does not revert
    }

    function test_RevertWhen_FulfillDeposit_StaleNav() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        uint256 staleTimestamp = updatedAt + vault.MAX_STALENESS() + 1;
        vm.warp(staleTimestamp);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.fulfillDeposit(alice, 1_000e6);
    }

    function test_RevertWhen_FulfillRedeem_StaleNav() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        uint256 staleTimestamp = updatedAt + vault.MAX_STALENESS() + 1;
        vm.warp(staleTimestamp);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.fulfillRedeem(alice, shares);
    }

    // =====================================================================
    // Partial pause: only requestDeposit/requestRedeem are blocked (contract
    // NatSpec point 6 / ARCHITECTURE.md §4 "Pausa como DoS")
    // =====================================================================

    function test_RevertWhen_RequestDeposit_Paused() public {
        vm.prank(pauser);
        vault.pause();

        _mintAndApprove(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(); // PausableUpgradeable.EnforcedPause
        vault.requestDeposit(100e6, alice, alice);
    }

    function test_RevertWhen_RequestRedeem_Paused() public {
        uint256 shares = _depositFulfillClaim(alice, 1_000e6);

        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.requestRedeem(shares, alice, alice);
    }

    function test_FulfillDeposit_And_FulfillRedeem_WorkWhilePaused() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        uint256 sharesForRedeem = _depositFulfillClaim(bob, 500e6);
        vm.prank(bob);
        vault.requestRedeem(sharesForRedeem, bob, bob);

        vm.prank(pauser);
        vault.pause();

        vm.prank(operator);
        vault.fulfillDeposit(alice, 1_000e6); // does not revert while paused

        vm.prank(operator);
        vault.fulfillRedeem(bob, sharesForRedeem); // does not revert while paused
    }

    function test_ClaimDeposit_And_ClaimRedeem_WorkWhilePaused() public {
        _mintAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);
        vm.prank(operator);
        vault.fulfillDeposit(alice, 1_000e6);

        uint256 bobShares = _depositFulfillClaim(bob, 500e6);
        vm.prank(bob);
        vault.requestRedeem(bobShares, bob, bob);
        vm.prank(operator);
        vault.fulfillRedeem(bob, bobShares);

        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vault.deposit(1_000e6, alice, alice); // claim still works while paused

        vm.prank(bob);
        vault.redeem(bobShares, bob, bob); // claim still works while paused
    }

    function test_InvestInTBill_And_DivestFromTBill_WorkWhilePaused() public {
        _depositFulfillClaim(alice, 1_000e6);

        vm.prank(pauser);
        vault.pause();

        vm.prank(assetManager);
        vault.investInTBill(1_000e6); // never gated by pause

        asset.mint(assetManager, 1_000e6);
        vm.startPrank(assetManager);
        asset.approve(address(vault), 1_000e6);
        vault.divestFromTBill(1_000e6); // never gated by pause
        vm.stopPrank();
    }

    function test_Unpause_AllowsRequestsAgain() public {
        vm.prank(pauser);
        vault.pause();
        vm.prank(pauser);
        vault.unpause();

        _mintAndApprove(alice, 100e6);
        vm.prank(alice);
        vault.requestDeposit(100e6, alice, alice); // does not revert
        assertEq(vault.pendingDeposit(alice), 100e6);
    }

    // =====================================================================
    // Treasury rails
    // =====================================================================

    function test_RevertWhen_InvestInTBill_ExceedsFreeBuffer() public {
        _depositFulfillClaim(alice, 1_000e6);

        vm.prank(assetManager);
        vm.expectRevert(
            abi.encodeWithSelector(RwaVault.InsufficientFreeBuffer.selector, 1_000e6 + 1, 1_000e6)
        );
        vault.investInTBill(1_000e6 + 1);
    }

    function test_InvestInTBill_CannotTouchPendingDepositOrClaimableRedeem() public {
        // 500 pending (unfulfilled) deposit + fulfilled/claimable-redeem money must
        // both stay untouchable by investInTBill.
        _mintAndApprove(alice, 500e6); // stays pending, never fulfilled
        vm.prank(alice);
        vault.requestDeposit(500e6, alice, alice);

        uint256 bobShares = _depositFulfillClaim(bob, 300e6);
        vm.prank(bob);
        vault.requestRedeem(bobShares, bob, bob);
        vm.prank(operator);
        vault.fulfillRedeem(bob, bobShares); // ~300e6 now earmarked as claimable

        // Vault's raw balance is 500 (pending) + ~300 (claimable redeem) = ~800; free
        // buffer must be ~0 since nothing was ever added on top.
        vm.prank(assetManager);
        vm.expectRevert();
        vault.investInTBill(1);
    }

    // =====================================================================
    // Previews are disabled by design (ERC-7540 requirement — pricing is fixed at
    // fulfill time, not at request/preview time)
    // =====================================================================

    function test_RevertWhen_PreviewDeposit() public {
        vm.expectRevert(RwaVault.PreviewDisabled.selector);
        vault.previewDeposit(1);
    }

    function test_RevertWhen_PreviewMint() public {
        vm.expectRevert(RwaVault.PreviewDisabled.selector);
        vault.previewMint(1);
    }

    function test_RevertWhen_PreviewWithdraw() public {
        vm.expectRevert(RwaVault.PreviewDisabled.selector);
        vault.previewWithdraw(1);
    }

    function test_RevertWhen_PreviewRedeem() public {
        vm.expectRevert(RwaVault.PreviewDisabled.selector);
        vault.previewRedeem(1);
    }

    // =====================================================================
    // Fuzz (512 runs, foundry.toml default): deposit/redeem with partial fulfills.
    // Conservation: pending + claimable + claimed == requested.
    // Rounding never favors the user: for any floor-rounded partial claim,
    // claimed_output * claimable_input_before <= input_consumed * claimable_output_before
    // (the arithmetic definition of "floor never rounds up"), and a full round trip
    // (deposit -> claim -> redeem -> claim, NAV untouched) never returns more assets
    // than were originally contributed.
    // =====================================================================

    function testFuzz_DepositConservation_PartialFulfillAndClaim(
        uint256 depositAmount,
        uint256 fulfillAmount,
        uint256 claimAmount
    ) public {
        depositAmount = bound(depositAmount, 2, 1_000_000_000e6);
        fulfillAmount = bound(fulfillAmount, 1, depositAmount);
        claimAmount = bound(claimAmount, 1, fulfillAmount);

        _mintAndApprove(alice, depositAmount);
        vm.prank(alice);
        vault.requestDeposit(depositAmount, alice, alice);

        vm.prank(operator);
        vault.fulfillDeposit(alice, fulfillAmount);

        assertEq(vault.pendingDeposit(alice), depositAmount - fulfillAmount);
        assertEq(vault.claimableDepositAssets(alice), fulfillAmount);
        assertEq(vault.totalPendingDepositAssets(), depositAmount - fulfillAmount);

        uint256 cSharesBefore = vault.claimableDepositShares(alice);
        uint256 cAssetsBefore = vault.claimableDepositAssets(alice);

        vm.prank(alice);
        uint256 sharesClaimed = vault.deposit(claimAmount, alice, alice);

        // Floor-rounding definition: sharesClaimed = floor(claimAmount * cShares / cAssets)
        // => sharesClaimed * cAssetsBefore <= claimAmount * cSharesBefore, never the reverse.
        assertLe(sharesClaimed * cAssetsBefore, claimAmount * cSharesBefore);

        // Conservation across the three buckets.
        assertEq(vault.pendingDeposit(alice) + vault.claimableDepositAssets(alice) + claimAmount, depositAmount);
        assertEq(vault.balanceOf(alice), sharesClaimed);
    }

    function testFuzz_RedeemConservation_PartialFulfillAndClaim(
        uint256 depositAmount,
        uint256 redeemFulfillAmount,
        uint256 claimShares
    ) public {
        depositAmount = bound(depositAmount, 2, 1_000_000_000e6);
        uint256 shares = _depositFulfillClaim(alice, depositAmount);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        redeemFulfillAmount = bound(redeemFulfillAmount, 1, shares);
        vm.prank(operator);
        uint256 assetsFulfilled = vault.fulfillRedeem(alice, redeemFulfillAmount);

        assertEq(vault.pendingRedeem(alice), shares - redeemFulfillAmount);
        assertEq(vault.claimableRedeemAssets(alice), assetsFulfilled);
        assertEq(vault.claimableRedeemShares(alice), redeemFulfillAmount);

        claimShares = bound(claimShares, 1, redeemFulfillAmount);
        uint256 cSharesBefore = vault.claimableRedeemShares(alice);
        uint256 cAssetsBefore = vault.claimableRedeemAssets(alice);

        vm.prank(alice);
        uint256 assetsClaimed = vault.redeem(claimShares, alice, alice);

        // Floor-rounding definition: assetsClaimed = floor(claimShares * cAssets / cShares)
        // => assetsClaimed * cSharesBefore <= claimShares * cAssetsBefore.
        assertLe(assetsClaimed * cSharesBefore, claimShares * cAssetsBefore);

        // Conservation.
        assertEq(vault.pendingRedeem(alice), shares - redeemFulfillAmount);
        assertEq(
            vault.claimableRedeemShares(alice) + claimShares, redeemFulfillAmount
        );

        // Never-favors-the-user, whole round trip: with NAV/tBill untouched, nobody
        // can walk away with more assets than they contributed.
        assertLe(assetsClaimed, depositAmount);
    }

    function testFuzz_MintClaim_RoundsAssetsConsumedUp_NeverExceedsClaimable(
        uint256 depositAmount,
        uint256 fulfillAmount,
        uint256 claimShares
    ) public {
        depositAmount = bound(depositAmount, 2, 1_000_000_000e6);
        fulfillAmount = bound(fulfillAmount, 1, depositAmount);

        _mintAndApprove(alice, depositAmount);
        vm.prank(alice);
        vault.requestDeposit(depositAmount, alice, alice);
        vm.prank(operator);
        vault.fulfillDeposit(alice, fulfillAmount);

        uint256 cSharesBefore = vault.claimableDepositShares(alice);
        uint256 cAssetsBefore = vault.claimableDepositAssets(alice);
        claimShares = bound(claimShares, 1, cSharesBefore);

        vm.prank(alice);
        uint256 assetsConsumed = vault.mint(claimShares, alice, alice);

        // Ceil-rounding definition: assetsConsumed = ceil(claimShares * cAssets / cShares)
        // => assetsConsumed * cSharesBefore >= claimShares * cAssetsBefore (rounds UP,
        // depleting the claimer's bucket at least as fast as proportional).
        assertGe(assetsConsumed * cSharesBefore, claimShares * cAssetsBefore);
        // ...but never more than what was actually fulfilled for this controller.
        assertLe(assetsConsumed, cAssetsBefore);
    }

    function testFuzz_WithdrawClaim_RoundsSharesConsumedUp_NeverExceedsClaimable(
        uint256 depositAmount,
        uint256 redeemFulfillAmount,
        uint256 claimAssets
    ) public {
        depositAmount = bound(depositAmount, 2, 1_000_000_000e6);
        uint256 shares = _depositFulfillClaim(alice, depositAmount);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        redeemFulfillAmount = bound(redeemFulfillAmount, 1, shares);
        vm.prank(operator);
        vault.fulfillRedeem(alice, redeemFulfillAmount);

        uint256 cSharesBefore = vault.claimableRedeemShares(alice);
        uint256 cAssetsBefore = vault.claimableRedeemAssets(alice);
        // A tiny `redeemFulfillAmount` can legitimately floor-round to 0 claimable
        // assets (rounding-favors-vault, ARCHITECTURE.md §4) — nothing to claim then.
        vm.assume(cAssetsBefore > 0);
        claimAssets = bound(claimAssets, 1, cAssetsBefore);

        vm.prank(alice);
        uint256 sharesConsumed = vault.withdraw(claimAssets, alice, alice);

        // Ceil-rounding definition, same shape as the mint-claim property above.
        assertGe(sharesConsumed * cAssetsBefore, claimAssets * cSharesBefore);
        assertLe(sharesConsumed, cSharesBefore);
    }
}
