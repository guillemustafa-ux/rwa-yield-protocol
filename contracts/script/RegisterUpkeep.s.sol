// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RwaVaultKeeper} from "../src/RwaVaultKeeper.sol";

/// @title IAutomationRegistrar2_1
/// @notice Minimal local re-declaration of `AutomationRegistrar2_1`'s external
///         surface (Sepolia registrar, real bytecode at {RegisterUpkeep-REGISTRAR}).
/// @dev CORRECTED after a live dry-run revert: `cast call typeAndVersion()` against
///      the real deployed registrar returned "AutomationRegistrar 2.1.0", NOT 2.3 as
///      first assumed. The field that broke everything: 2.1's `RegistrationParams`
///      has NO `billingToken` field at all — 2.1 only bills in LINK (multi-asset
///      billing/`billingToken` was added in 2.3). Including it shifted every field
///      after it by one ABI slot, so the registrar decoded garbage and reverted deep
///      inside the call. Struct order below matches the real, public
///      `AutomationRegistrar2_1.sol` source exactly.
///      Declared locally (not imported) for the same reason as before: the real
///      package's registrar files are pinned to `pragma solidity 0.8.19;`, which
///      conflicts with this repo's `0.8.24` pin.
interface IAutomationRegistrar2_1 {
    struct RegistrationParams {
        string name;
        bytes encryptedEmail;
        address upkeepContract;
        uint32 gasLimit;
        address adminAddress;
        uint8 triggerType;
        bytes checkData;
        bytes triggerConfig;
        bytes offchainConfig;
        uint96 amount;
    }

    function registerUpkeep(RegistrationParams memory requestParams) external returns (uint256);
}

/// @title RegisterUpkeep
/// @notice F3 (ARCHITECTURE.md §7.1/§7.3): deploys `RwaVaultKeeper` and registers TWO
///         log-trigger Chainlink Automation upkeeps against it on Sepolia — one
///         filtered on `RwaVault`'s `DepositRequest` topic0, one on `RedeemRequest`'s.
///         Same one `RwaVaultKeeper` contract serves both; `checkLog` already
///         branches on `log.topics[0]` internally.
/// @dev WHY TWO UPKEEPS, NOT ONE: a Chainlink log-trigger's `triggerConfig`
///      (`LogTriggerConfig`, ABI-encoded into `RegistrationParams.triggerConfig`) has
///      room for exactly ONE `topic0` per registration — see the installed package's
///      own reference (`automation/testhelpers/DummyProtocol.sol`'s
///      `LogTriggerConfig{contractAddress, filterSelector, topic0, topic1, topic2,
///      topic3}`, identical layout to `IAutomationV21PlusCommon.LogTriggerConfig`).
///      There is no OR-of-two-signatures option, so `DepositRequest` and
///      `RedeemRequest` — two different event signatures — need two separate
///      registrations, both pointed at the vault's address and the same keeper.
///
///      `AutomationRegistrar2_1.registerUpkeep` requires the caller to already hold,
///      and have approved, `PLACEHOLDER_LINK_AMOUNT` of LINK per registration
///      (`_register` -> `LINK.transferFrom(msg.sender, address(this), amount)`).
///      Once the deployer is funded via the Sepolia LINK faucet, run with
///      `--sender` first to confirm the simulation clears the ABI-decode step (a
///      first attempt at this hit a real revert here: the registrar turned out to
///      be v2.1, not v2.3, and v2.1's `RegistrationParams` has no `billingToken`
///      field — see the interface's NatSpec), then for real with `--broadcast`.
///
///      Usage:
///        export VAULT_ADDRESS=<RwaVault proxy address> # optional, defaults below
///        forge script script/RegisterUpkeep.s.sol --rpc-url <SEPOLIA_RPC_URL> \
///          --sender 0x40b282c45EE5667fB72b4D37a676A0110cEe36d5
contract RegisterUpkeep is Script {
    /// @dev Chainlink Automation Registrar on Sepolia — verified with `cast code`
    ///      (real bytecode, not a placeholder) AND `cast call typeAndVersion()`
    ///      (returns "AutomationRegistrar 2.1.0" — confirmed live, not assumed).
    address internal constant REGISTRAR = 0xb0E49c5D0d05cbc241d68c05BC5BA1d1B7B72976;

    /// @dev LINK token on Sepolia (ARCHITECTURE.md §7: "LINK `0x7798...4789`").
    address internal constant LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    /// @dev `RwaVault_proxy` from `deployments/sepolia.json` (D4 deploy) — the address
    ///      that "survived the V1->V2 upgrade without changing". Override via the
    ///      `VAULT_ADDRESS` env var if a newer deploy exists.
    address internal constant DEFAULT_VAULT = 0x48c78Ffe5A882069FC81Fb866510FAAE625109C4;

    /// @dev `Trigger.LOG` — see the installed package's
    ///      `automation/v2_3/AutomationRegistryBase2_3.sol`'s
    ///      `enum Trigger { CONDITION, LOG }` (CONDITION=0, LOG=1).
    uint8 internal constant LOG_TRIGGER_TYPE = 1;

    /// @dev Placeholder LINK amount per upkeep for this SIMULATION's
    ///      `RegistrationParams.amount` — never actually transferred (see contract
    ///      NatSpec: the deployer has 0 LINK). A real registration would size this
    ///      against the registrar's `getMinimumRegistrationAmount(LINK)` plus enough
    ///      runway for expected `fulfillDeposit`/`fulfillRedeem` gas.
    uint96 internal constant PLACEHOLDER_LINK_AMOUNT = 5 ether;

    /// @dev Gas limit passed to the registry for each `performUpkeep` call — generous
    ///      headroom over `fulfillDeposit`/`fulfillRedeem`'s actual cost (well under
    ///      100k gas per the D2/D3 `forge snapshot` figures), before this repo has its
    ///      own Automation-specific gas profiling.
    uint32 internal constant UPKEEP_GAS_LIMIT = 500_000;

    /// @dev MUST match `RwaVault.sol`'s event signature exactly (verified against the
    ///      source, not invented) — same constant as `RwaVaultKeeper.sol`.
    bytes32 internal constant DEPOSIT_REQUEST_TOPIC0 =
        keccak256("DepositRequest(address,address,uint256,address,uint256)");
    bytes32 internal constant REDEEM_REQUEST_TOPIC0 =
        keccak256("RedeemRequest(address,address,uint256,address,uint256)");

    /// @dev Mirrors the registry's own `LogTriggerConfig` layout (same field order as
    ///      `IAutomationV21PlusCommon.LogTriggerConfig` / the installed package's
    ///      `testhelpers/DummyProtocol.sol` reference) — this is what gets
    ///      ABI-encoded into `RegistrationParams.triggerConfig` for a log-trigger
    ///      registration.
    struct LogTriggerConfig {
        address contractAddress;
        uint8 filterSelector; // 0 = only filter on source + topic0, ignore topic1/2/3
        bytes32 topic0;
        bytes32 topic1;
        bytes32 topic2;
        bytes32 topic3;
    }

    function run() external {
        address vaultAddress = vm.envOr("VAULT_ADDRESS", DEFAULT_VAULT);
        console.log("Target RwaVault proxy:  ", vaultAddress);

        vm.startBroadcast();

        RwaVaultKeeper keeper = new RwaVaultKeeper(vaultAddress);
        console.log("RwaVaultKeeper deployed:", address(keeper));

        // Approve the registrar to pull LINK for BOTH registrations up front. On a
        // real (funded) run this succeeds; in today's 0-LINK simulation this call
        // itself is harmless (an ERC-20 `approve` never checks balance), the revert
        // happens one step later inside `registerUpkeep`'s `transferFrom` — see
        // contract NatSpec.
        IERC20(LINK).approve(REGISTRAR, uint256(PLACEHOLDER_LINK_AMOUNT) * 2);

        uint256 depositUpkeepId = _registerLogTrigger(
            vaultAddress, address(keeper), "RwaVaultKeeper - DepositRequest", DEPOSIT_REQUEST_TOPIC0
        );
        console.log("DepositRequest upkeepId:", depositUpkeepId);

        uint256 redeemUpkeepId =
            _registerLogTrigger(vaultAddress, address(keeper), "RwaVaultKeeper - RedeemRequest", REDEEM_REQUEST_TOPIC0);
        console.log("RedeemRequest upkeepId: ", redeemUpkeepId);

        vm.stopBroadcast();

        console.log("");
        console.log("---- RegisterUpkeep summary (ARCHITECTURE.md Sec7.1/Sec7.3) ----");
        console.log("RwaVault proxy   :", vaultAddress);
        console.log("RwaVaultKeeper   :", address(keeper));
        console.log("Deposit upkeepId :", depositUpkeepId);
        console.log("Redeem upkeepId  :", redeemUpkeepId);
        console.log("");
        console.log("REMINDER: grant OPERATOR_ROLE on the vault to the keeper address");
        console.log("above before either upkeep can actually settle anything:");
        console.log("  vault.grantRole(vault.OPERATOR_ROLE(), <RwaVaultKeeper address>)");
    }

    function _registerLogTrigger(address vaultAddress, address keeperAddress, string memory name, bytes32 topic0)
        internal
        returns (uint256 upkeepId)
    {
        LogTriggerConfig memory cfg = LogTriggerConfig({
            contractAddress: vaultAddress,
            filterSelector: 0,
            topic0: topic0,
            topic1: bytes32(0),
            topic2: bytes32(0),
            topic3: bytes32(0)
        });

        IAutomationRegistrar2_1.RegistrationParams memory params = IAutomationRegistrar2_1.RegistrationParams({
            name: name,
            encryptedEmail: bytes(""),
            upkeepContract: keeperAddress,
            gasLimit: UPKEEP_GAS_LIMIT,
            adminAddress: msg.sender,
            triggerType: LOG_TRIGGER_TYPE,
            checkData: bytes(""),
            triggerConfig: abi.encode(cfg),
            offchainConfig: bytes(""),
            amount: PLACEHOLDER_LINK_AMOUNT
        });

        upkeepId = IAutomationRegistrar2_1(REGISTRAR).registerUpkeep(params);
    }
}

// STATUS (updated after the live registrar-version fix): the deployer
// (0x40b282c45EE5667fB72b4D37a676A0110cEe36d5) is now funded with 25 LINK on
// Sepolia. Construction and tests of `RwaVaultKeeper` never depended on any of
// this — only the live on-chain registration did. Remaining sequence:
//   1. Run this script with `--broadcast` for real.
//   2. Grant `OPERATOR_ROLE` on the vault to the freshly deployed `RwaVaultKeeper`
//      address printed above — the upkeeps are registered but inert without it.
