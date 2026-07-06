// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {RwaVault} from "../src/RwaVault.sol";
import {RwaVaultV2} from "../src/RwaVaultV2.sol";

/// @title UpgradeToV2
/// @notice D4 live upgrade script (ARCHITECTURE.md §3.4 / §6): pushes `RwaVaultV2`
///         (management-fee feature, `reinitializer(2)`) onto the ALREADY-DEPLOYED
///         `RwaVault` proxy from `Deploy.s.sol`, via UUPS `upgradeToAndCall`. The
///         proxy address, storage and outstanding deposits are untouched — only the
///         implementation slot changes and `initializeV2` runs once, gated by
///         `reinitializer(2)`.
/// @dev Expected `RwaVaultV2` interface (per this task's spec, written against it
///      before V2 landed — see NOTE at the bottom if this file doesn't compile yet):
///
///        function initializeV2(uint16 feeBps, address feeRecipient) external reinitializer(2);
///
///      Caller of `run()` (resolved via `--sender`/`--private-key`/`--account`, same
///      as `Deploy.s.sol` — this script never touches `PRIVATE_KEY` directly) MUST
///      already hold `UPGRADER_ROLE` on the target proxy: `Deploy.s.sol`'s
///      single-operator demo grants that role to `deployer`, so running this script
///      with the same sender works out of the box in the demo. A real deployment
///      would run this from whichever distinct account/multisig actually holds
///      `UPGRADER_ROLE` (see `Deploy.s.sol` contract NatSpec).
///
///      Usage:
///        export PROXY_ADDRESS=<RwaVault proxy address from Deploy.s.sol's log>
///        Simulate (no key, no broadcast):
///          forge script script/UpgradeToV2.s.sol --rpc-url <RPC_URL> --sender <address>
///        Broadcast for real (main session only, after review):
///          forge script script/UpgradeToV2.s.sol --rpc-url <RPC_URL> --private-key <PK> \
///            --broadcast --verify
contract UpgradeToV2 is Script {
    /// @dev 100 bps = 1% annual management fee — the demo figure from
    ///      ARCHITECTURE.md §3.4 ("1% anual demo").
    uint16 internal constant DEMO_FEE_BPS = 100;

    function run() external {
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        console.log("Target RwaVault proxy (PROXY_ADDRESS env):", proxyAddress);

        RwaVault vault = RwaVault(proxyAddress);

        vm.startBroadcast();
        address caller = msg.sender;

        // Pre-upgrade snapshot, purely informational: proves state (roles) survives
        // the swap once compared against the post-upgrade log below.
        bool callerIsUpgraderBefore = vault.hasRole(vault.UPGRADER_ROLE(), caller);
        console.log("Caller:                                   ", caller);
        console.log("Caller holds UPGRADER_ROLE (pre-upgrade):  ", callerIsUpgraderBefore);

        RwaVaultV2 newImplementation = new RwaVaultV2();
        console.log("RwaVaultV2 implementation:                 ", address(newImplementation));

        // feeRecipient = caller in this single-operator demo (ARCHITECTURE.md §3.4);
        // production would point this at a dedicated treasury/multisig address.
        bytes memory initV2Data = abi.encodeCall(RwaVaultV2.initializeV2, (DEMO_FEE_BPS, caller));
        vault.upgradeToAndCall(address(newImplementation), initV2Data);

        vm.stopBroadcast();

        console.log("");
        console.log("---- Upgrade summary (ARCHITECTURE.md Sec3.4/Sec6 D4) ----");
        console.log("RwaVault proxy (unchanged): ", proxyAddress);
        console.log("New implementation (V2)   : ", address(newImplementation));
        console.log("feeBps (demo)             : ", uint256(DEMO_FEE_BPS));
        console.log("feeRecipient (demo)       : ", caller);
    }
}

// NOTE (handoff, do not remove until resolved): at authoring time `src/RwaVaultV2.sol`
// was being written by a parallel agent and did not exist yet, so this file may fail
// to compile with "File not found" / "Identifier not found" for `RwaVaultV2` until
// that file lands with AT LEAST:
//   contract RwaVaultV2 is RwaVault {
//       function initializeV2(uint16 feeBps, address feeRecipient) external reinitializer(2) { ... }
//   }
// If the signature ends up different, update the `abi.encodeCall` call above to match
// — do not change `Deploy.s.sol`'s role wiring to compensate, this script only needs
// `UPGRADER_ROLE` on the proxy, which `Deploy.s.sol` already grants to `deployer`.
