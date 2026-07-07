// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainDepositRelay} from "../src/CrossChainDepositRelay.sol";

/// @title DeployRelay
/// @notice F3 (ARCHITECTURE.md §7.2): deploys `CrossChainDepositRelay` on SEPOLIA — the
///         receiving leg of the cross-chain deposit demo. Closes the gap flagged by the
///         F3 verifier ("no script deploys the Relay"; `SendCrossChainDeposit.s.sol`
///         only covers the Arbitrum Sepolia sender leg).
/// @dev Same conventions as `Deploy.s.sol`/`UpgradeToV2.s.sol`: `vm.startBroadcast()`
///      with no args (sender comes from the CLI), env-var wiring for addresses that
///      only exist post-deploy, never reads PRIVATE_KEY in code.
///
///      Env vars:
///        PROXY_ADDRESS        RwaVault proxy (0x48c78Ffe... on Sepolia, see deployments/sepolia.json)
///        SENDER_ADDRESS       (optional) CrossChainDepositSender already deployed on the
///                             source chain — if set, it gets allowlisted in the same run.
///        SOURCE_CHAIN_SELECTOR (optional, required with SENDER_ADDRESS) CCIP chain selector
///                             of the source chain. Arbitrum Sepolia = 3478487238524512106.
///
///      Usage (simulate first, broadcast from the main session after review):
///        export PROXY_ADDRESS=0x48c78Ffe5A882069FC81Fb866510FAAE625109C4
///        forge script script/DeployRelay.s.sol --rpc-url <SEPOLIA_RPC> --sender <addr>
///
///      After deploy, the demo still needs (runbook, in order):
///        1. relay funded with DemoUSDC:      usdc.faucet(...) then usdc.transfer(relay, ...)
///           (no manual approve needed — the relay forceApproves the vault for the exact
///            amount inside `_ccipReceive`, per message)
///        2. sender allowlisted:              done here if SENDER_ADDRESS is set
contract DeployRelay is Script {
    /// @dev CCIP Router on Ethereum Sepolia (verified with `cast code` — 22,263 bytes).
    address internal constant SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    function run() external returns (CrossChainDepositRelay relay) {
        address proxy = vm.envAddress("PROXY_ADDRESS");
        address sender = vm.envOr("SENDER_ADDRESS", address(0));
        uint64 sourceSelector = uint64(vm.envOr("SOURCE_CHAIN_SELECTOR", uint256(0)));

        vm.startBroadcast();
        address deployer = msg.sender;

        relay = new CrossChainDepositRelay(SEPOLIA_CCIP_ROUTER, proxy, deployer);
        console.log("CrossChainDepositRelay:", address(relay));
        console.log("  router:", SEPOLIA_CCIP_ROUTER);
        console.log("  vault :", proxy);
        console.log("  owner :", deployer);

        if (sender != address(0) && sourceSelector != 0) {
            relay.setSenderAllowlist(sourceSelector, sender, true);
            console.log("  allowlisted sender:", sender);
            console.log("  source selector   :", sourceSelector);
        } else {
            console.log("  (no SENDER_ADDRESS/SOURCE_CHAIN_SELECTOR - allowlist later via setSenderAllowlist)");
        }

        vm.stopBroadcast();
    }
}
