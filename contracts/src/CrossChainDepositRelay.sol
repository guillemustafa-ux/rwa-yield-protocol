// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

/// @dev Narrow, read/write surface of `RwaVault` this relay actually needs — deliberately NOT
///      importing the full `RwaVault.sol` (ownership boundary: this task never touches that
///      file, and the relay has no business depending on its whole ABI/import tree). Both
///      members mirror the real, already-shipped signatures in `RwaVault.sol` exactly:
///      `asset()` (inherited from `ERC4626Upgradeable`) and `requestDeposit(assets, controller,
///      owner)` (ARCHITECTURE.md §3.3 / §7.2).
interface IRwaVaultDeposit {
    function asset() external view returns (address);
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
}

/// @title CrossChainDepositRelay — CCIP message receiver, drives `RwaVault.requestDeposit`
/// @author RWA Yield Protocol
/// @notice Deployed on Sepolia (same chain as `RwaVault`). Receives a CCIP message from a
///         `CrossChainDepositSender` on another chain and, if the sender is allowlisted, calls
///         `requestDeposit` on the vault using ITS OWN pre-funded `DemoUSDC` balance.
/// @dev TRADE-OFF, documented on purpose (ARCHITECTURE.md §7.2, decided — not a bug): this is
///      CCIP *messaging*, not a token bridge. The cross-chain message never carries value —
///      only `(controller, assets)`. `DemoUSDC` is Sepolia-only; in production, the asset leg
///      would instead arrive via a registered CCIP Token Pool release, and this relay would
///      consume THAT instead of a pre-funded balance. Here, the deployer funds this contract's
///      `DemoUSDC` balance out-of-band (e.g. `demoUsdc.faucet(cap)` then a transfer), capped
///      exactly like any other use of the demo asset.
///
///      Trust model: `_ccipReceive` only proceeds for `(sourceChainSelector, sender)` pairs the
///      owner has explicitly allowlisted — without that gate, ANY contract on ANY CCIP-enabled
///      chain could drain this relay's pre-funded balance by sending an arbitrary message. Same
///      "never trust the input" discipline `RwaVault` already applies elsewhere in this
///      protocol (see e.g. its `InsufficientLiquidity` guard).
contract CrossChainDepositRelay is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The vault this relay drives `requestDeposit` calls against.
    IRwaVaultDeposit public immutable vault;

    /// @notice The underlying deposit asset the vault expects (cached from `vault.asset()` at
    ///         construction — `RwaVault`'s own `asset()` never changes post-`initialize`).
    IERC20 public immutable depositAsset;

    /// @notice `allowlistedSenders[sourceChainSelector][sender]` — the only `(chain, sender)`
    ///         pairs `_ccipReceive` will act on. Owner-configurable via {setSenderAllowlist}.
    mapping(uint64 sourceChainSelector => mapping(address sender => bool allowed)) public allowlistedSenders;

    error ZeroAddress();

    /// @notice The message's `(sourceChainSelector, sender)` pair is not allowlisted.
    /// @dev Explicit revert instead of silently dropping the message — a bad configuration
    ///      (or an attack attempt) should be loud, not swallowed.
    error SenderNotAllowlisted(uint64 sourceChainSelector, address sender);

    /// @notice This relay's own `depositAsset` balance can't cover the requested deposit.
    /// @dev Checked explicitly BEFORE calling `requestDeposit` so the failure names the actual
    ///      cause (relay under-funded) instead of surfacing as a generic ERC-20
    ///      `safeTransferFrom` revert three call-frames deep inside `RwaVault`.
    error InsufficientRelayBalance(uint256 requested, uint256 available);

    event SenderAllowlistUpdated(uint64 indexed sourceChainSelector, address indexed sender, bool allowed);

    /// @notice A cross-chain message was accepted and turned into a real `requestDeposit` call.
    event CrossChainDepositRelayed(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        address controller,
        uint256 assets
    );

    /// @param router_ CCIP router on this (destination) chain.
    /// @param vault_ The `RwaVault` proxy this relay will call `requestDeposit` on.
    /// @param initialOwner Recipient of ownership (allowlist administration).
    constructor(address router_, address vault_, address initialOwner) CCIPReceiver(router_) Ownable(initialOwner) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = IRwaVaultDeposit(vault_);
        depositAsset = IERC20(IRwaVaultDeposit(vault_).asset());
    }

    /// @notice Allowlists (or revokes) a `(sourceChainSelector, sender)` pair.
    /// @dev `sender` is the `CrossChainDepositSender` contract address on the source chain —
    ///      NEVER an end-user address (this is a chain+contract allowlist, not a per-depositor
    ///      one; individual depositors are identified by the `controller` field inside the
    ///      message payload, not by who is allowlisted to relay).
    function setSenderAllowlist(uint64 sourceChainSelector, address sender, bool allowed) external onlyOwner {
        if (sender == address(0)) revert ZeroAddress();
        allowlistedSenders[sourceChainSelector][sender] = allowed;
        emit SenderAllowlistUpdated(sourceChainSelector, sender, allowed);
    }

    /// @inheritdoc CCIPReceiver
    /// @dev Decodes `(controller, assets)`, enforces the allowlist, checks this relay's own
    ///      `depositAsset` balance explicitly, then approves the vault for exactly `assets` and
    ///      calls `requestDeposit(assets, controller, address(this))`. Passing `address(this)`
    ///      as BOTH the implicit `msg.sender` (this call) AND the explicit `owner` argument
    ///      satisfies `RwaVault.requestDeposit`'s `msg.sender == owner` check trivially — no
    ///      operator approval needed, because the relay is spending its own funds, not a third
    ///      party's.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        uint64 sourceChainSelector = message.sourceChainSelector;
        address sender = abi.decode(message.sender, (address));

        if (!allowlistedSenders[sourceChainSelector][sender]) {
            revert SenderNotAllowlisted(sourceChainSelector, sender);
        }

        (address controller, uint256 assets) = abi.decode(message.data, (address, uint256));

        uint256 available = depositAsset.balanceOf(address(this));
        if (assets > available) revert InsufficientRelayBalance(assets, available);

        // Exact-amount approval (not infinite) — no dangling allowance survives this call.
        depositAsset.forceApprove(address(vault), assets);
        vault.requestDeposit(assets, controller, address(this));

        emit CrossChainDepositRelayed(message.messageId, sourceChainSelector, sender, controller, assets);
    }
}
