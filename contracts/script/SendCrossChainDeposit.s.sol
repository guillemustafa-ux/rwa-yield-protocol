// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {CrossChainDepositSender} from "../src/CrossChainDepositSender.sol";

/// @title SendCrossChainDeposit
/// @notice ARCHITECTURE.md §7.2/§7.3 — arms (and, once funded, sends) the CCIP message that
///         triggers a `RwaVault.requestDeposit` from Arbitrum Sepolia against a
///         `CrossChainDepositRelay` already deployed on Sepolia. Run this script WITH
///         `--rpc-url` pointed at Arbitrum Sepolia (the source chain `CrossChainDepositSender`
///         belongs on).
///
/// @dev Address provenance (per task instructions: "verificalos con cast code antes de
///      asumirlos válidos"). Both were checked TWO independent ways before use:
///        1. `cast code <addr> --rpc-url https://sepolia-rollup.arbitrum.io/rpc` returned
///           non-empty bytecode for both (i.e. real deployed contracts, not placeholders).
///        2. They match `smartcontractkit/chainlink-local`'s own `src/ccip/Register.sol`
///           network-config table for chain id 421614 (Arbitrum Sepolia) EXACTLY — the same
///           file this repo's `test/CrossChainDeposit.t.sol` transitively depends on for its
///           offline `CCIPLocalSimulator` — so the values below are the canonical ones a
///           freshly-installed Chainlink package agrees are correct, not hand-copied guesses.
///      Router:    0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165
///      LINK:      0xb1D4538B4571d411F07960EF2838Ce337FE1E80E
///      Destination (Ethereum Sepolia) chain selector 16015286601757825753 is the same
///      constant `Register.sol` lists for chain id 11155111, and matches the router/LINK
///      pair ARCHITECTURE.md §7 already cites for Sepolia (`0x0BF3...3A59` / `0x7798...4789`).
///
/// @dev SIMULATION ONLY, by design (task instructions: "SOLO simulación, sin --broadcast, sin
///      clave"). This script is never meant to be run with `--broadcast`/`--private-key` from
///      this workflow — the main session does that, after review, once BOTH of the following
///      are funded (a real, unavoidable prerequisite this script cannot skip or fake):
///        - `CrossChainDepositSender` (on Arbitrum Sepolia) needs a LINK balance to pay the
///          CCIP fee (`IRouterClient.getFee`) — see `CrossChainDepositSender.sol` NatSpec.
///        - `CrossChainDepositRelay` (on Sepolia) needs a `DemoUSDC` balance to fund the
///          `requestDeposit` call once the message arrives — see `CrossChainDepositRelay.sol`
///          NatSpec.
///      The deployer used across this repo has ZERO LINK today (ARCHITECTURE.md §7.3), so
///      running this against live Arbitrum Sepolia state is EXPECTED to revert at the
///      `sendDeposit` call with `InsufficientLinkBalance` until that LINK funding happens —
///      that is this script faithfully reporting a real, unfakeable constraint, not a bug.
///
///      Usage:
///        export RELAY_ADDRESS=<CrossChainDepositRelay address, already deployed on Sepolia>
///        # Optional — reuse an already-deployed sender instead of deploying a fresh one:
///        export SENDER_ADDRESS=<CrossChainDepositSender address, on Arbitrum Sepolia>
///        # Optional — defaults to 100.000000 (6-decimal DemoUSDC) if unset:
///        export DEPOSIT_ASSETS=100000000
///
///        Simulate (no key, no broadcast):
///          forge script script/SendCrossChainDeposit.s.sol \
///            --rpc-url <ARBITRUM_SEPOLIA_RPC_URL> --sender <address>
///        Broadcast for real (main session only, after review, AND after funding LINK on both
///        chains and DemoUSDC on the relay):
///          forge script script/SendCrossChainDeposit.s.sol \
///            --rpc-url <ARBITRUM_SEPOLIA_RPC_URL> --private-key <PK> --broadcast
contract SendCrossChainDeposit is Script {
    /// @dev CCIP router on Arbitrum Sepolia — see contract NatSpec for how this was verified.
    address internal constant ARBITRUM_SEPOLIA_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;

    /// @dev LINK token on Arbitrum Sepolia — see contract NatSpec for how this was verified.
    address internal constant ARBITRUM_SEPOLIA_LINK = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;

    /// @dev CCIP chain selector for Ethereum Sepolia — the destination chain `RwaVault` and
    ///      `CrossChainDepositRelay` live on in this protocol (ARCHITECTURE.md §7).
    uint64 internal constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    /// @dev Demo deposit size if `DEPOSIT_ASSETS` is not set: 100.000000 (DemoUSDC, 6 decimals).
    uint256 internal constant DEFAULT_DEPOSIT_ASSETS = 100e6;

    function run() external {
        address relay = vm.envAddress("RELAY_ADDRESS");
        address existingSender = vm.envOr("SENDER_ADDRESS", address(0));
        uint256 assets = vm.envOr("DEPOSIT_ASSETS", DEFAULT_DEPOSIT_ASSETS);

        console.log("---- SendCrossChainDeposit (ARCHITECTURE.md Sec7.2) ----");
        console.log("Arbitrum Sepolia CCIP router:", ARBITRUM_SEPOLIA_ROUTER);
        console.log("Arbitrum Sepolia LINK token :", ARBITRUM_SEPOLIA_LINK);
        console.log("Destination chain selector  :", SEPOLIA_CHAIN_SELECTOR, "(Ethereum Sepolia)");
        console.log("CrossChainDepositRelay (dest):", relay);
        console.log("Deposit amount (assets)     :", assets);

        vm.startBroadcast();
        address caller = msg.sender;

        CrossChainDepositSender sender;
        if (existingSender != address(0)) {
            sender = CrossChainDepositSender(existingSender);
            console.log("Reusing existing CrossChainDepositSender:", existingSender);
        } else {
            sender = new CrossChainDepositSender(ARBITRUM_SEPOLIA_ROUTER, ARBITRUM_SEPOLIA_LINK);
            console.log("Deployed new CrossChainDepositSender    :", address(sender));
        }

        // Informational only — read BEFORE the (possibly-reverting) send, so the simulation
        // output is legible even if `sendDeposit` itself reverts for lack of LINK funding (see
        // contract NatSpec: this is an expected, real constraint, not something to work around).
        uint256 linkBalance = IERC20(ARBITRUM_SEPOLIA_LINK).balanceOf(address(sender));
        console.log("Sender's current LINK balance:", linkBalance);
        console.log("Caller (controller on the destination request):", caller);

        bytes32 messageId = sender.sendDeposit(relay, SEPOLIA_CHAIN_SELECTOR, assets);

        vm.stopBroadcast();

        console.log("");
        console.log("---- Send summary ----");
        console.log("CCIP messageId:");
        console.logBytes32(messageId);
        console.log("Once the message is executed on Sepolia by the CCIP DON, verify with:");
        console.log("  cast call <RwaVault proxy> \"pendingDepositRequest(uint256,address)\" 0", caller);
    }
}
