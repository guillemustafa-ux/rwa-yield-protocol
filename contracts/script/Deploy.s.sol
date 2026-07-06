// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TBillToken} from "../src/TBillToken.sol";
import {RwaNavFeed} from "../src/RwaNavFeed.sol";
import {RwaVault} from "../src/RwaVault.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @title DemoUSDC
/// @notice 6-decimal USDC-like ERC-20, deployed ONLY because Sepolia has no canonical
///         USDC address for this demo to point `RwaVault.initialize`'s `asset_` at
///         (ARCHITECTURE.md §3.3 assumes "a USDC-like ERC-20", it doesn't mandate the
///         real mainnet USDC). A production deploy against an actual chain with a real
///         USDC address SKIPS this contract entirely and passes that address in.
/// @dev Lives inside `Deploy.s.sol` (not `src/`) on purpose: this is deploy tooling for
///      the demo, not protocol logic — keeping it out of `src/` keeps the audited
///      contract surface exactly {TBillToken, RwaNavFeed, RwaVault}.
contract DemoUSDC is ERC20 {
    /// @notice Maximum amount {faucet} will mint in a single call (6 decimals).
    /// @dev Public and unauthenticated by design (demo asset, no real value) — the cap
    ///      only exists so the faucet can't be turned into an unbounded free-mint for
    ///      whoever finds the address, which would make demo TVL numbers meaningless.
    uint256 public constant FAUCET_CAP = 10_000e6; // 10,000.000000 dUSDC

    error FaucetCapExceeded(uint256 requested, uint256 cap);

    constructor() ERC20("Demo USD Coin", "dUSDC") {}

    /// @notice Mints up to {FAUCET_CAP} of dUSDC to the caller.
    /// @param amount Amount to mint (6 decimals), must be <= {FAUCET_CAP}.
    function faucet(uint256 amount) external {
        if (amount > FAUCET_CAP) revert FaucetCapExceeded(amount, FAUCET_CAP);
        _mint(msg.sender, amount);
    }

    /// @dev Matches `TBillToken`'s 6 decimals and the `_decimalsOffset()` assumption in
    ///      `RwaVault` (inflation-attack guard), same convention as the test double
    ///      `test/utils/MockUSDC.sol`.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title Deploy
/// @notice D4 deploy script (ARCHITECTURE.md §6): stands up the full protocol on
///         Sepolia in the exact sequence the design calls for:
///         DemoUSDC -> TBillToken -> RwaNavFeed (seeded) -> RwaVault implementation
///         -> ERC1967Proxy(initialize) -> role wiring.
/// @dev SINGLE-OPERATOR DEMO: every operational role — the vault's OPERATOR_ROLE,
///      ASSET_MANAGER_ROLE, PAUSER_ROLE, UPGRADER_ROLE, AND TBillToken's own (separate)
///      ASSET_MANAGER_ROLE — is granted to the SAME `deployer` address for simplicity.
///      A real deployment MUST split these across distinct accounts: DEFAULT_ADMIN_ROLE
///      and UPGRADER_ROLE behind a timelocked multisig, OPERATOR_ROLE on a dedicated
///      keeper/bot key, ASSET_MANAGER_ROLE(s) on whoever custodies the off-chain T-bill
///      purchases — see `RwaVault`'s contract NatSpec point 2 and ARCHITECTURE.md §3.3.
///
///      Usage:
///        Simulate (no key, no broadcast):
///          forge script script/Deploy.s.sol --rpc-url <RPC_URL> --sender <address>
///        Broadcast for real (main session only, after review):
///          forge script script/Deploy.s.sol --rpc-url <RPC_URL> --private-key <PK> \
///            --broadcast --verify
///      The script itself never reads `PRIVATE_KEY` — `vm.startBroadcast()` (no args)
///      resolves the sender from whatever `--sender`/`--private-key`/`--account` the
///      CLI invocation provides, so simulation and real broadcast run the identical
///      script body (same convention as `pulso-exchange/contracts/script/Deploy.s.sol`).
contract Deploy is Script {
    /// @dev 100.00000000 in RwaNavFeed's 8 decimals — first NAV round, exempt from the
    ///      deviation/frequency guards (RwaNavFeed.updateNav, no previous round yet).
    int256 internal constant INITIAL_NAV = 100e8;

    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        // 1. Demo deposit asset -------------------------------------------------
        DemoUSDC usdc = new DemoUSDC();
        console.log("DemoUSDC (demo asset):        ", address(usdc));

        // 2. Synthetic RWA leg ----------------------------------------------------
        // admin (deployer) gets DEFAULT_ADMIN_ROLE on TBillToken's OWN AccessControl
        // instance; ASSET_MANAGER_ROLE there is granted further down, separately from
        // the vault's role of the same name (RwaVault contract NatSpec point 4).
        TBillToken tBillToken = new TBillToken(deployer);
        console.log("TBillToken:                   ", address(tBillToken));

        // 3. NAV oracle, seeded with an initial round ------------------------------
        RwaNavFeed navFeed = new RwaNavFeed(deployer, "tBILL / USD NAV");
        console.log("RwaNavFeed:                   ", address(navFeed));

        navFeed.updateNav(INITIAL_NAV);
        console.log("RwaNavFeed seeded NAV (8 dec):", uint256(INITIAL_NAV));

        // 4. Vault implementation + UUPS proxy -------------------------------------
        RwaVault implementation = new RwaVault();
        console.log("RwaVault implementation:      ", address(implementation));

        bytes memory initData = abi.encodeCall(
            RwaVault.initialize,
            (
                IERC20(address(usdc)),
                IERC20Metadata(address(tBillToken)),
                AggregatorV3Interface(address(navFeed)),
                deployer
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        RwaVault vault = RwaVault(address(proxy));
        console.log("RwaVault proxy:               ", address(vault));

        // 5. Role wiring ------------------------------------------------------------
        // 5a. Vault-side operational roles (demo single-operator — see contract NatSpec
        //     above for what a real deployment must do instead).
        vault.grantRole(vault.OPERATOR_ROLE(), deployer);
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), deployer);
        vault.grantRole(vault.PAUSER_ROLE(), deployer);
        vault.grantRole(vault.UPGRADER_ROLE(), deployer);
        console.log("Vault roles (OPERATOR/ASSET_MANAGER/PAUSER/UPGRADER) -> deployer:", deployer);

        // 5b. TBillToken's ASSET_MANAGER_ROLE: a SEPARATE AccessControl instance from
        //     the vault's role of the same name (RwaVault contract NatSpec point 4).
        //     RwaVault deliberately NEVER calls tBillToken.mint/burn itself, so this
        //     role is NOT granted to the vault proxy. It must go to whichever account
        //     actually executes the off-chain purchase/sale leg. In this single-operator
        //     demo that is the SAME `deployer` that also holds the vault's own
        //     ASSET_MANAGER_ROLE, so the deployer can:
        //       (a) vault.investInTBill(amount)      -- pull USDC out of the vault
        //       (b) tBillToken.mint(vault, tBillAmt)  -- mint tBILL straight into the
        //                                                 vault, mirroring "custodian
        //                                                 bought T-bills with that cash"
        //     A production deploy would grant this to the actual custodian/operator
        //     account instead of reusing `deployer`.
        tBillToken.grantRole(tBillToken.ASSET_MANAGER_ROLE(), deployer);
        console.log("TBillToken ASSET_MANAGER_ROLE -> deployer:                       ", deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("---- Deploy summary (ARCHITECTURE.md Sec6 D4) ----");
        console.log("DemoUSDC        :", address(usdc));
        console.log("TBillToken      :", address(tBillToken));
        console.log("RwaNavFeed      :", address(navFeed));
        console.log("RwaVault impl   :", address(implementation));
        console.log("RwaVault proxy  :", address(vault));
        console.log("Deployer/admin  :", deployer);
    }
}
