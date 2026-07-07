// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Log} from "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";

import {RwaVault} from "../src/RwaVault.sol";
import {RwaNavFeed} from "../src/RwaNavFeed.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockUSDC} from "./utils/MockUSDC.sol";

import {RwaVaultKeeper} from "../src/RwaVaultKeeper.sol";

/// @title RwaVaultKeeperTest
/// @notice Covers ARCHITECTURE.md §7.1's acceptance bar: `checkLog` says true/false
///         correctly (fulfilled request / dried-up buffer), `performUpkeep` really
///         settles a request (real `fulfillDeposit`, claimable afterward), and
///         `performUpkeep` no-ops without reverting when the state changed between
///         `checkLog` and `performUpkeep` (both race conditions: another fulfill beat
///         it, and the buffer dried up) — plus the `OPERATOR_ROLE` gate.
/// @dev Every `Log` fed to `checkLog`/used to build `performData` in these tests is
///      built from a REAL log captured via `vm.recordLogs()`/`vm.getRecordedLogs()`
///      right after the vault emits it — never hand-invented topics/data.
contract RwaVaultKeeperTest is Test {
    RwaVault internal vault;
    RwaVault internal implementation;
    MockUSDC internal asset;
    TBillToken internal tBillToken;
    RwaNavFeed internal navFeed;
    RwaVaultKeeper internal keeper;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal assetManager = makeAddr("assetManager");
    address internal tBillAdmin = makeAddr("tBillAdmin");
    address internal navAdmin = makeAddr("navAdmin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal stranger = makeAddr("stranger");

    int256 internal constant INITIAL_NAV = 100e8; // 100.00000000, 8 decimals

    bytes32 internal constant DEPOSIT_REQUEST_TOPIC0 =
        keccak256("DepositRequest(address,address,uint256,address,uint256)");
    bytes32 internal constant REDEEM_REQUEST_TOPIC0 =
        keccak256("RedeemRequest(address,address,uint256,address,uint256)");

    function setUp() public {
        // Windows/foundry gotcha: local timestamp starts at 1 — warp in setUp.
        vm.warp(1_700_000_000);

        asset = new MockUSDC();
        tBillToken = new TBillToken(tBillAdmin);
        navFeed = new RwaNavFeed(navAdmin, "tBILL / USD NAV");

        implementation = new RwaVault();
        bytes memory initData = abi.encodeCall(
            RwaVault.initialize,
            (IERC20(address(asset)), tBillToken, AggregatorV3Interface(address(navFeed)), admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RwaVault(address(proxy));

        keeper = new RwaVaultKeeper(address(vault));

        vm.startPrank(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.OPERATOR_ROLE(), address(keeper));
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), assetManager);
        vm.stopPrank();

        // TBillToken is a SEPARATE AccessControl instance (RwaVault.sol NatSpec point
        // 4) — assetManager needs its OWN grant here too, so the buffer-manipulation
        // helper below can mint/burn tBILL to mirror a real off-chain purchase/sale
        // instead of just vanishing the vault's notional value.
        bytes32 tBillAssetManagerRole = tBillToken.ASSET_MANAGER_ROLE();
        vm.prank(tBillAdmin);
        tBillToken.grantRole(tBillAssetManagerRole, assetManager);

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

    /// @dev Converts a real `vm.getRecordedLogs()` entry into Chainlink Automation's
    ///      `Log` struct. Only `source`/`topics`/`data` feed `checkLog`'s decision
    ///      logic — the envelope fields (`index`/`timestamp`/`txHash`/`blockNumber`/
    ///      `blockHash`) are unused by `RwaVaultKeeper` and filled with harmless
    ///      placeholders, exactly like Chainlink's own log-trigger test helpers do.
    function _toLog(Vm.Log memory raw) internal view returns (Log memory) {
        return Log({
            index: 0,
            timestamp: block.timestamp,
            txHash: bytes32(0),
            blockNumber: block.number,
            blockHash: bytes32(0),
            source: raw.emitter,
            topics: raw.topics,
            data: raw.data
        });
    }

    /// @dev Scans recorded logs for the first entry whose topic0 matches `topic0`.
    function _findLog(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return logs[i];
            }
        }
        revert("log not found");
    }

    /// @dev Full deposit-request cycle up to (and including) the operator fulfilling
    ///      it directly (bypassing the keeper) — used to set up buffer/state for
    ///      later scenarios without re-testing the keeper's own deposit path again.
    function _depositFulfillClaim(address user, uint256 amount) internal returns (uint256 shares) {
        _mintAndApprove(user, amount);
        vm.prank(user);
        vault.requestDeposit(amount, user, user);

        vm.prank(operator);
        vault.fulfillDeposit(user, amount);

        vm.prank(user);
        shares = vault.deposit(amount, user, user);
    }

    /// @dev Realistically simulates the asset manager buying `assetAmount` worth of
    ///      tBILL off-chain: pulls the asset out via {investInTBill} AND mints the
    ///      equivalent tBILL to the vault at the current NAV (RwaVault.sol NatSpec
    ///      point 4 — the vault itself never does this second leg, the asset manager
    ///      does, via TBillToken's OWN `ASSET_MANAGER_ROLE`). Without the mint leg,
    ///      `totalAssets()` would simply crater (the vault would look like it lost
    ///      the money instead of having moved it off-book), which would make the
    ///      buffer-insufficiency scenarios below trivially true for the wrong reason.
    ///      `assetAmount * 1e8 / NAV` inverts `RwaVault._tBillValueInAsset` for this
    ///      test's fixed decimals (asset/tBILL both 6, NAV feed 8).
    function _investAndMintTBill(uint256 assetAmount) internal {
        vm.prank(assetManager);
        vault.investInTBill(assetAmount);

        uint256 tBillAmount = (assetAmount * 1e8) / uint256(INITIAL_NAV);
        vm.prank(assetManager);
        tBillToken.mint(address(vault), tBillAmount);
    }

    /// @dev Inverse of {_investAndMintTBill}: burns the tBILL leg and returns the
    ///      asset leg, mirroring a real off-chain sale.
    function _divestAndBurnTBill(uint256 assetAmount) internal {
        uint256 tBillAmount = (assetAmount * 1e8) / uint256(INITIAL_NAV);
        vm.prank(assetManager);
        tBillToken.burn(address(vault), tBillAmount);

        vm.prank(assetManager);
        asset.approve(address(vault), assetAmount);
        vm.prank(assetManager);
        vault.divestFromTBill(assetAmount);
    }

    // =====================================================================
    // Constructor
    // =====================================================================

    function test_Constructor_RevertWhen_ZeroVault() public {
        vm.expectRevert(RwaVaultKeeper.ZeroAddress.selector);
        new RwaVaultKeeper(address(0));
    }

    function test_Constructor_SetsVault() public view {
        assertEq(address(keeper.vault()), address(vault));
    }

    // =====================================================================
    // checkLog — filtering (wrong source / wrong topic count / unrelated topic0)
    // =====================================================================

    function test_CheckLog_False_WrongSource() public {
        vm.recordLogs();
        _mintAndApprove(alice, 1000e6);
        vm.prank(alice);
        vault.requestDeposit(1000e6, alice, alice);
        Vm.Log memory raw = _findLog(vm.getRecordedLogs(), DEPOSIT_REQUEST_TOPIC0);

        Log memory log = _toLog(raw);
        log.source = address(0xBEEF); // tamper with source

        (bool upkeepNeeded,) = keeper.checkLog(log, "");
        assertFalse(upkeepNeeded);
    }

    // =====================================================================
    // Deposit path: checkLog true -> performUpkeep really fulfills -> user claims
    // =====================================================================

    function test_Deposit_CheckLogTrue_PerformUpkeepFulfills_UserClaims() public {
        uint256 depositAmount = 1000e6;
        _mintAndApprove(alice, depositAmount);

        vm.recordLogs();
        vm.prank(alice);
        vault.requestDeposit(depositAmount, alice, alice);
        Vm.Log memory raw = _findLog(vm.getRecordedLogs(), DEPOSIT_REQUEST_TOPIC0);
        Log memory log = _toLog(raw);

        (bool upkeepNeeded, bytes memory performData) = keeper.checkLog(log, "");
        assertTrue(upkeepNeeded);

        (bool isDeposit, address controller, uint256 amount) = abi.decode(performData, (bool, address, uint256));
        assertTrue(isDeposit);
        assertEq(controller, alice);
        assertEq(amount, depositAmount);

        // Anyone can call performUpkeep (Chainlink forwarder or otherwise) — not
        // restricted to a specific caller.
        vm.prank(stranger);
        keeper.performUpkeep(performData);

        assertEq(vault.pendingDeposit(alice), 0);
        assertEq(vault.claimableDepositAssets(alice), depositAmount);

        // checkLog on the SAME log now says false — the request already settled.
        (bool upkeepNeededAfter,) = keeper.checkLog(log, "");
        assertFalse(upkeepNeededAfter);

        // The user really can claim afterward — proves performUpkeep did a REAL
        // fulfillDeposit, not just bookkeeping.
        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice, alice);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    // =====================================================================
    // performUpkeep no-op #1: another fulfill already processed the request
    // between checkLog and performUpkeep
    // =====================================================================

    function test_Deposit_PerformUpkeep_NoOp_WhenAlreadyFulfilled() public {
        uint256 depositAmount = 500e6;
        _mintAndApprove(bob, depositAmount);

        vm.recordLogs();
        vm.prank(bob);
        vault.requestDeposit(depositAmount, bob, bob);
        Vm.Log memory raw = _findLog(vm.getRecordedLogs(), DEPOSIT_REQUEST_TOPIC0);
        Log memory log = _toLog(raw);

        (bool upkeepNeeded, bytes memory performData) = keeper.checkLog(log, "");
        assertTrue(upkeepNeeded);

        // Race: a human operator (also OPERATOR_ROLE) fulfills it directly before
        // the keeper's performUpkeep transaction lands.
        vm.prank(operator);
        vault.fulfillDeposit(bob, depositAmount);
        uint256 claimableBefore = vault.claimableDepositAssets(bob);

        // performUpkeep must NOT revert, and must NOT double-fulfill.
        vm.expectEmit(true, true, false, true, address(keeper));
        emit RwaVaultKeeper.UpkeepSkipped(true, bob, depositAmount, "already fulfilled");
        keeper.performUpkeep(performData);

        assertEq(vault.claimableDepositAssets(bob), claimableBefore);
        assertEq(vault.pendingDeposit(bob), 0);
    }

    // =====================================================================
    // Redeem path: checkLog false when buffer is insufficient, true once restored,
    // performUpkeep really fulfills the redeem.
    // =====================================================================

    function test_Redeem_CheckLog_FalseWhenBufferInsufficient_TrueOnceRestored() public {
        uint256 depositAmount = 1000e6;
        uint256 shares = _depositFulfillClaim(alice, depositAmount);

        // Asset manager deploys most of the buffer off-chain (simulating a real
        // T-bill purchase: pulls 900e6 USDC out AND mints the equivalent 9e6 tBILL
        // at NAV=100 to the vault), leaving far less liquid buffer than a full
        // redeem would need even though the pool's notional value is unchanged.
        _investAndMintTBill(900e6);

        vm.recordLogs();
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        Vm.Log memory raw = _findLog(vm.getRecordedLogs(), REDEEM_REQUEST_TOPIC0);
        Log memory log = _toLog(raw);

        (bool upkeepNeeded,) = keeper.checkLog(log, "");
        assertFalse(upkeepNeeded, "should be false: buffer (100e6) < required (~1000e6)");

        // Asset manager returns the funds (and burns the tBILL leg) — buffer restored.
        _divestAndBurnTBill(900e6);

        (bool upkeepNeededAfter, bytes memory performData) = keeper.checkLog(log, "");
        assertTrue(upkeepNeededAfter, "should be true once buffer is restored");

        (bool isDeposit, address controller, uint256 amount) = abi.decode(performData, (bool, address, uint256));
        assertFalse(isDeposit);
        assertEq(controller, alice);
        assertEq(amount, shares);

        keeper.performUpkeep(performData);

        assertEq(vault.pendingRedeem(alice), 0);
        assertGt(vault.claimableRedeemAssets(alice), 0);

        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertGt(assetsOut, 0);
        assertEq(asset.balanceOf(alice), assetsOut);
    }

    // =====================================================================
    // performUpkeep no-op #2: buffer dries up between checkLog and performUpkeep
    // =====================================================================

    function test_Redeem_PerformUpkeep_NoOp_WhenBufferDriesUp() public {
        uint256 depositAmount = 500e6;
        uint256 shares = _depositFulfillClaim(bob, depositAmount);

        vm.recordLogs();
        vm.prank(bob);
        vault.requestRedeem(shares, bob, bob);
        Vm.Log memory raw = _findLog(vm.getRecordedLogs(), REDEEM_REQUEST_TOPIC0);
        Log memory log = _toLog(raw);

        (bool upkeepNeeded, bytes memory performData) = keeper.checkLog(log, "");
        assertTrue(upkeepNeeded, "buffer should cover the redeem right after request");

        // Race: the asset manager invests the buffer away right after checkLog ran,
        // before performUpkeep's transaction lands. Mints the tBILL leg too, so the
        // pool's notional value (and thus the assets bob's shares convert to) stays
        // put — only the LIQUID buffer dries up, which is the specific condition
        // {performUpkeep} must catch.
        _investAndMintTBill(400e6);

        uint256 pendingBefore = vault.pendingRedeem(bob);

        vm.expectEmit(true, true, false, true, address(keeper));
        emit RwaVaultKeeper.UpkeepSkipped(false, bob, shares, "insufficient buffer");
        keeper.performUpkeep(performData);

        // No-op: request still pending, nothing claimable, no revert.
        assertEq(vault.pendingRedeem(bob), pendingBefore);
        assertEq(vault.claimableRedeemAssets(bob), 0);
    }

    // =====================================================================
    // OPERATOR_ROLE gate
    // =====================================================================

    function test_PerformUpkeep_RevertWhen_KeeperLacksOperatorRole() public {
        // Fresh keeper instance, deliberately never granted OPERATOR_ROLE.
        RwaVaultKeeper keeperNoRole = new RwaVaultKeeper(address(vault));

        uint256 depositAmount = 250e6;
        _mintAndApprove(charlie, depositAmount);

        vm.recordLogs();
        vm.prank(charlie);
        vault.requestDeposit(depositAmount, charlie, charlie);
        Vm.Log memory raw = _findLog(vm.getRecordedLogs(), DEPOSIT_REQUEST_TOPIC0);
        Log memory log = _toLog(raw);

        // checkLog itself doesn't need the role — only performUpkeep's call into
        // the vault does.
        (bool upkeepNeeded, bytes memory performData) = keeperNoRole.checkLog(log, "");
        assertTrue(upkeepNeeded);

        bytes32 operatorRole = vault.OPERATOR_ROLE(); // cache before expectRevert, not needed here but consistent style
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(keeperNoRole), operatorRole
            )
        );
        keeperNoRole.performUpkeep(performData);
    }
}
