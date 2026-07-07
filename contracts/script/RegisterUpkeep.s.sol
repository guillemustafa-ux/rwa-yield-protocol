// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RwaVaultKeeper} from "../src/RwaVaultKeeper.sol";

/// @title IAutomationRegistrar2_3
/// @notice Minimal local re-declaration of `AutomationRegistrar2_3`'s external
///         surface (Sepolia registrar, real bytecode at {RegisterUpkeep-REGISTRAR}).
/// @dev Declared locally instead of importing the installed package's own
///      `automation/v2_3/AutomationRegistrar2_3.sol` directly on purpose: that file
///      (and its whole import chain, down to `AutomationRegistryBase2_3.sol`) is
///      pinned to an EXACT `pragma solidity 0.8.19;`, which conflicts with this
///      repo's own exact pin (`0.8.24`, `foundry.toml`'s `solc_version`) — pulling
///      it in would force a second solc install/toolchain split across the whole
///      multi-agent repo just for one script. `RegistrationParams`'s field
///      names/order/types below are copied
///      verbatim from the real contract (read before writing this file, per task
///      instructions) — `billingToken`'s type is widened from the vendored
///      `IERC20Metadata` the real contract uses to plain OZ `IERC20` (a strict
///      supertype covering everything this script calls: `approve`, and whatever
///      `registerUpkeep` needs internally), which is ABI-compatible for this
///      cross-contract call.
interface IAutomationRegistrar2_3 {
    struct RegistrationParams {
        address upkeepContract;
        uint96 amount;
        address adminAddress;
        uint32 gasLimit;
        uint8 triggerType;
        IERC20 billingToken;
        string name;
        bytes encryptedEmail;
        bytes checkData;
        bytes triggerConfig;
        bytes offchainConfig;
    }

    function registerUpkeep(RegistrationParams memory requestParams) external payable returns (uint256);
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
///      SIMULATION ONLY (per task spec — do not add `--broadcast` to the usage
///      below). `AutomationRegistrar2_3.registerUpkeep` requires the caller to
///      already hold, and have approved, `PLACEHOLDER_LINK_AMOUNT` of LINK per
///      registration (`_register` -> `billingToken.safeTransferFrom(msg.sender,
///      address(this), amount)`). The deployer (`0x40b282c45EE5667fB72b4D37a676A0110
///      cEe36d5`) has 0 LINK today (ARCHITECTURE.md §7.3: "el deployer tiene 0 LINK
///      hoy"), so running this script — even as a dry-run simulation against live
///      Sepolia state via `--sender`, no key, no `--broadcast` — is EXPECTED to
///      revert at the `transferFrom` step inside `registerUpkeep` with an ERC-20
///      insufficient-balance/allowance error. That failure is the correct, documented
///      outcome of a simulation with no LINK, not a bug in this script: it still
///      proves the `RegistrationParams`/`LogTriggerConfig` wiring type-checks and
///      ABI-encodes against the REAL, verified-by-bytecode registrar interface
///      (ARCHITECTURE.md §7: "las tres con bytecode real, no placeholders"). Once the
///      deployer is funded via the Sepolia LINK faucet, the exact same script (still
///      run with `--sender` first, then for real with `--broadcast` once reviewed)
///      completes both registrations.
///
///      Usage:
///        export VAULT_ADDRESS=<RwaVault proxy address> # optional, defaults below
///        forge script script/RegisterUpkeep.s.sol --rpc-url <SEPOLIA_RPC_URL> \
///          --sender 0x40b282c45EE5667fB72b4D37a676A0110cEe36d5
contract RegisterUpkeep is Script {
    /// @dev Chainlink Automation Registrar 2.3 on Sepolia — verified with `cast code`
    ///      before designing against it (ARCHITECTURE.md §7): real bytecode, not a
    ///      placeholder.
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

        IAutomationRegistrar2_3.RegistrationParams memory params = IAutomationRegistrar2_3.RegistrationParams({
            upkeepContract: keeperAddress,
            amount: PLACEHOLDER_LINK_AMOUNT,
            adminAddress: msg.sender,
            gasLimit: UPKEEP_GAS_LIMIT,
            triggerType: LOG_TRIGGER_TYPE,
            billingToken: IERC20(LINK),
            name: name,
            encryptedEmail: bytes(""),
            checkData: bytes(""),
            triggerConfig: abi.encode(cfg),
            offchainConfig: bytes("")
        });

        upkeepId = IAutomationRegistrar2_3(REGISTRAR).registerUpkeep(params);
    }
}

// BLOCKED ON LINK (ARCHITECTURE.md §7.3, documented, not an oversight): the deployer
// address (0x40b282c45EE5667fB72b4D37a676A0110cEe36d5) holds 0 LINK on Sepolia as of
// this writing. `run()` above WILL revert once it reaches `registerUpkeep`'s internal
// `billingToken.safeTransferFrom(msg.sender, address(this), amount)` for exactly that
// reason, whether invoked as a `--sender`-only dry run or (once someone tries it) with
// `--broadcast`. Construction and tests of `RwaVaultKeeper` do NOT depend on this —
// only the live on-chain registration does. Unblocking sequence, left for the session
// that has the deployer's key:
//   1. Fund the deployer with test LINK: https://faucets.chain.link/sepolia
//   2. Re-run this script with `--broadcast` (after a plain `--sender` dry run confirms
//      the simulation now gets past the `approve`/`transferFrom` step).
//   3. Grant `OPERATOR_ROLE` on the vault to the freshly deployed `RwaVaultKeeper`
//      address printed above — the upkeeps are registered but inert without it.
