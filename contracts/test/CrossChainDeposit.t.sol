// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {RwaVault} from "../src/RwaVault.sol";
import {RwaNavFeed} from "../src/RwaNavFeed.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {MockUSDC} from "./utils/MockUSDC.sol";

import {CrossChainDepositSender} from "../src/CrossChainDepositSender.sol";
import {CrossChainDepositRelay} from "../src/CrossChainDepositRelay.sol";

// Same `Client` library `CrossChainDepositSender`/`CrossChainDepositRelay` compile against
// (chainlink-brownie-contracts) — required so `Client.Any2EVMMessage` literals built here are
// the SAME nominal Solidity type as `CrossChainDepositRelay.ccipReceive`'s parameter, letting the
// negative-path tests call it directly (not just through a live `ccipSend` round trip).
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

// chainlink-local: offline CCIP simulator (two mock routers, same test chain — ARCHITECTURE.md
// §7.3 "todo con tests offline ... CCIPLocalSimulator para CCIP"). Re-exports `IRouterClient`,
// `WETH9`, `LinkToken`, `BurnMintERC677Helper` straight from this same import per its own README.
import {
    CCIPLocalSimulator,
    IRouterClient,
    WETH9,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
// Only needed to call the mock-only `setFee` (not part of `IRouterClient`) for the LINK-fee tests.
import {MockCCIPRouter} from "@chainlink/local/src/vendor/chainlink-ccip/test/mocks/MockRouter.sol";

/// @title CrossChainDepositTest
/// @notice Offline coverage for the CCIP cross-chain deposit trigger (ARCHITECTURE.md §7.2):
///         `CrossChainDepositSender` (source chain) -> CCIP message -> `CrossChainDepositRelay`
///         (destination chain, same chain as `RwaVault` in this demo) -> `requestDeposit`.
///         Uses `CCIPLocalSimulator` for two same-chain mock routers instead of two forked
///         networks, matching the "todo con tests offline" plan in ARCHITECTURE.md §7.3.
contract CrossChainDepositTest is Test {
    // --- CCIP local simulation ---
    CCIPLocalSimulator internal ccipLocalSimulator;
    uint64 internal chainSelector;
    IRouterClient internal sourceRouter;
    IRouterClient internal destRouter;
    LinkToken internal linkToken;

    // --- RwaVault stack (identical wiring to RwaVault.t.sol) ---
    RwaVault internal vault;
    RwaVault internal implementation;
    MockUSDC internal asset;
    TBillToken internal tBillToken;
    RwaNavFeed internal navFeed;

    // --- cross-chain contracts under test ---
    CrossChainDepositSender internal sender;
    CrossChainDepositRelay internal relay;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal tBillAdmin = makeAddr("tBillAdmin");
    address internal navAdmin = makeAddr("navAdmin");
    address internal relayOwner = makeAddr("relayOwner");
    address internal alice = makeAddr("alice"); // depositor on the SOURCE chain, controller on dest

    int256 internal constant INITIAL_NAV = 100e8;
    uint256 internal constant RELAY_USDC_FUNDING = 5_000e6;

    function setUp() public {
        // Windows/foundry gotcha: local timestamp starts at 1 — warp in setUp.
        vm.warp(1_700_000_000);

        // --- CCIP local simulator: one pair of mock routers shared by both "chains" ---
        ccipLocalSimulator = new CCIPLocalSimulator();
        (chainSelector, sourceRouter, destRouter,, linkToken,,) = ccipLocalSimulator.configuration();

        // --- RwaVault stack, wired exactly like RwaVault.t.sol's setUp ---
        asset = new MockUSDC();
        tBillToken = new TBillToken(tBillAdmin);
        navFeed = new RwaNavFeed(navAdmin, "tBILL / USD NAV");

        implementation = new RwaVault();
        bytes memory initData =
            abi.encodeCall(RwaVault.initialize, (IERC20(address(asset)), tBillToken, navFeed, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RwaVault(address(proxy));

        // Role hash cached BEFORE the prank — a view call sandwiched between vm.prank and the
        // intended call consumes the prank (Windows/foundry gotcha, same as RwaVault.t.sol).
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.prank(admin);
        vault.grantRole(operatorRole, operator);

        vm.prank(navAdmin);
        navFeed.updateNav(INITIAL_NAV);

        // --- cross-chain contracts (ARCHITECTURE.md §7.2) ---
        // Sender: "Arbitrum Sepolia" side. Relay: "Sepolia" side, same vault this repo deploys.
        sender = new CrossChainDepositSender(address(sourceRouter), address(linkToken));
        relay = new CrossChainDepositRelay(address(destRouter), address(vault), relayOwner);

        vm.prank(relayOwner);
        relay.setSenderAllowlist(chainSelector, address(sender), true);

        // Relay pre-funded with DemoUSDC-equivalent balance (ARCHITECTURE.md §7.2: "un balance
        // de DemoUSDC pre-fondeado que el relay mantiene").
        asset.mint(address(relay), RELAY_USDC_FUNDING);
    }

    // =====================================================================
    // Happy path: valid CCIP message -> real requestDeposit against the vault
    // =====================================================================

    function test_SendDeposit_CreatesRealPendingDepositOnVault() public {
        uint256 assets = 1_000e6;

        vm.prank(alice);
        bytes32 messageId = sender.sendDeposit(address(relay), chainSelector, assets);

        assertTrue(messageId != bytes32(0), "router should return a non-zero message id");
        assertEq(vault.pendingDepositRequest(0, alice), assets, "controller's pending deposit should grow");
        assertEq(asset.balanceOf(address(vault)), assets, "vault should hold the pulled USDC");
        assertEq(
            asset.balanceOf(address(relay)), RELAY_USDC_FUNDING - assets, "relay balance should be debited by assets"
        );
    }

    function test_FullCycle_RequestFulfillClaim_AfterCrossChainMessage() public {
        uint256 assets = 1_000e6;

        vm.prank(alice);
        sender.sendDeposit(address(relay), chainSelector, assets);
        assertEq(vault.pendingDepositRequest(0, alice), assets);

        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, assets);
        assertGt(shares, 0, "fulfilling a non-zero deposit must mint non-zero shares");
        assertEq(vault.pendingDepositRequest(0, alice), 0, "pending should clear after full fulfill");

        vm.prank(alice);
        uint256 claimedShares = vault.deposit(assets, alice, alice);

        assertEq(claimedShares, shares, "claim should deliver exactly the fulfilled shares");
        assertEq(vault.balanceOf(alice), shares, "alice should now hold the vault shares");
        assertEq(vault.maxDeposit(alice), 0, "nothing left claimable after full claim");
    }

    // =====================================================================
    // Sender: LINK fee handling
    // =====================================================================

    function test_SendDeposit_RevertsIfLinkFeeExceedsBalance() public {
        uint256 fee = 5 ether;
        MockCCIPRouter(address(sourceRouter)).setFee(fee);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrossChainDepositSender.InsufficientLinkBalance.selector, fee, 0));
        sender.sendDeposit(address(relay), chainSelector, 1_000e6);
    }

    function test_SendDeposit_PaysFeeInLinkWhenFunded() public {
        uint256 fee = 2 ether;
        uint256 assets = 750e6;
        MockCCIPRouter(address(sourceRouter)).setFee(fee);
        ccipLocalSimulator.requestLinkFromFaucet(address(sender), fee);

        vm.prank(alice);
        bytes32 messageId = sender.sendDeposit(address(relay), chainSelector, assets);

        assertTrue(messageId != bytes32(0));
        assertEq(linkToken.balanceOf(address(sender)), 0, "exact fee should be pulled, no dangling LINK");
        assertEq(
            linkToken.allowance(address(sender), address(sourceRouter)),
            0,
            "forceApprove should leave no leftover allowance beyond what the router consumed"
        );
        assertEq(vault.pendingDepositRequest(0, alice), assets, "deposit should still land despite a non-zero fee");
    }

    function test_SendDeposit_RevertsOnZeroAssetsOrZeroRelay() public {
        vm.startPrank(alice);

        vm.expectRevert(CrossChainDepositSender.ZeroAmount.selector);
        sender.sendDeposit(address(relay), chainSelector, 0);

        vm.expectRevert(CrossChainDepositSender.ZeroAddress.selector);
        sender.sendDeposit(address(0), chainSelector, 1_000e6);

        vm.stopPrank();
    }

    function test_SenderConstructor_RevertsOnZeroAddress() public {
        vm.expectRevert(CrossChainDepositSender.ZeroAddress.selector);
        new CrossChainDepositSender(address(0), address(linkToken));

        vm.expectRevert(CrossChainDepositSender.ZeroAddress.selector);
        new CrossChainDepositSender(address(sourceRouter), address(0));
    }

    // =====================================================================
    // Relay: allowlist gate
    // =====================================================================

    function test_CcipReceive_RevertsIfSenderNotAllowlisted() public {
        address evilSender = makeAddr("evilSender");
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("evil-message"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(evilSender),
            data: abi.encode(alice, uint256(1_000e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Only the router is allowed to call `ccipReceive` (CCIPReceiver.onlyRouter) — impersonate
        // the SAME mock router `configuration()` handed out, exactly as the real OffRamp would.
        vm.prank(address(destRouter));
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainDepositRelay.SenderNotAllowlisted.selector, chainSelector, evilSender)
        );
        relay.ccipReceive(message);
    }

    function test_CcipReceive_RevertsIfCallerIsNotRouter() public {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("not-router"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(sender)),
            data: abi.encode(alice, uint256(1_000e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(alice);
        vm.expectRevert(); // CCIPReceiver.InvalidRouter — inherited plumbing, not this task's code
        relay.ccipReceive(message);
    }

    // =====================================================================
    // Relay: DemoUSDC balance gate
    // =====================================================================

    function test_CcipReceive_RevertsIfRelayBalanceInsufficient() public {
        // Fresh relay, allowlisted, but deliberately NEVER funded with DemoUSDC.
        CrossChainDepositRelay poorRelay = new CrossChainDepositRelay(address(destRouter), address(vault), relayOwner);
        vm.prank(relayOwner);
        poorRelay.setSenderAllowlist(chainSelector, address(sender), true);

        uint256 assets = 500e6;
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("poor-relay"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(sender)),
            data: abi.encode(alice, assets),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(destRouter));
        vm.expectRevert(abi.encodeWithSelector(CrossChainDepositRelay.InsufficientRelayBalance.selector, assets, 0));
        poorRelay.ccipReceive(message);

        // Nothing should have reached the vault.
        assertEq(vault.pendingDepositRequest(0, alice), 0);
    }

    function test_RelayConstructor_RevertsOnZeroVault() public {
        vm.expectRevert(CrossChainDepositRelay.ZeroAddress.selector);
        new CrossChainDepositRelay(address(destRouter), address(0), relayOwner);
    }

    // =====================================================================
    // Relay: allowlist administration
    // =====================================================================

    function test_SetSenderAllowlist_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        relay.setSenderAllowlist(chainSelector, address(sender), true);
    }

    function test_SetSenderAllowlist_RevertsOnZeroSender() public {
        vm.prank(relayOwner);
        vm.expectRevert(CrossChainDepositRelay.ZeroAddress.selector);
        relay.setSenderAllowlist(chainSelector, address(0), true);
    }

    function test_SetSenderAllowlist_CanRevokeAccess() public {
        vm.prank(relayOwner);
        relay.setSenderAllowlist(chainSelector, address(sender), false);
        assertFalse(relay.allowlistedSenders(chainSelector, address(sender)));

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: keccak256("revoked"),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(sender)),
            data: abi.encode(alice, uint256(1_000e6)),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.prank(address(destRouter));
        vm.expectRevert(
            abi.encodeWithSelector(
                CrossChainDepositRelay.SenderNotAllowlisted.selector, chainSelector, address(sender)
            )
        );
        relay.ccipReceive(message);
    }
}
