// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

/// @title CrossChainDepositSender — CCIP message originator (ARCHITECTURE.md §7.2)
/// @author RWA Yield Protocol
/// @notice Deployed on Arbitrum Sepolia (or any CCIP-enabled source chain). Lets any account
///         trigger a `RwaVault.requestDeposit` on the destination chain (Sepolia) by sending a
///         CCIP *message* (no token transfer) to a `CrossChainDepositRelay` there.
/// @dev TRADE-OFF, documented on purpose (ARCHITECTURE.md §7.2, decided — not a bug): this is
///      CCIP *messaging*, NOT a token bridge. `DemoUSDC` never leaves Sepolia — bridging the
///      real asset would require registering a CCIP Token Pool (permissioned, out of scope for
///      a demo). The message only carries `(controller, assets)`; the relay on the destination
///      spends ITS OWN pre-funded `DemoUSDC` balance to actually call `requestDeposit`. In a
///      production deployment this contract's message would instead accompany (or be replaced
///      by) a real CCIP token transfer released by a registered Token Pool on the destination.
///
///      Fee model: this contract must hold LINK itself (see {sendDeposit}) — CCIP's router
///      pulls the fee via `safeTransferFrom(address(this), ...)`, i.e. from the contract that
///      calls `ccipSend`, not from the original caller's own wallet. Fund this contract with
///      LINK before calling {sendDeposit} (e.g. via the Chainlink faucet on testnets).
contract CrossChainDepositSender {
    using SafeERC20 for IERC20;

    /// @notice The CCIP router on this (source) chain.
    IRouterClient public immutable router;

    /// @notice The LINK token on this (source) chain, used to pay CCIP fees.
    IERC20 public immutable linkToken;

    /// @notice Gas limit handed to the destination chain's `ccipReceive` callback.
    /// @dev `CrossChainDepositRelay._ccipReceive` does an allowlist check, an ERC-20 balance
    ///      check, an `approve`, and a call into `RwaVault.requestDeposit` — 300k is a
    ///      generous, fixed budget for that fixed code path (no user-controlled loops).
    uint256 public constant CALLBACK_GAS_LIMIT = 300_000;

    error ZeroAddress();
    error ZeroAmount();

    /// @notice The CCIP fee for this message exceeds this contract's own LINK balance.
    /// @dev Checked explicitly BEFORE calling `ccipSend` so the failure is legible — letting the
    ///      router's internal `safeTransferFrom` revert instead would surface as an opaque
    ///      ERC-20 error with no indication of *why* (same "explicit revert over ERC-20 default"
    ///      discipline as the rest of this protocol, see `RwaVault.InsufficientLiquidity`).
    error InsufficientLinkBalance(uint256 fee, uint256 balance);

    /// @notice A deposit-triggering CCIP message was sent toward `relay` on `destChainSelector`.
    event DepositMessageSent(
        bytes32 indexed messageId,
        uint64 indexed destChainSelector,
        address indexed relay,
        address controller,
        uint256 assets,
        uint256 fee
    );

    /// @param router_ CCIP router on the chain this contract is deployed to.
    /// @param linkToken_ LINK token on the chain this contract is deployed to.
    constructor(address router_, address linkToken_) {
        if (router_ == address(0)) revert ZeroAddress();
        if (linkToken_ == address(0)) revert ZeroAddress();
        router = IRouterClient(router_);
        linkToken = IERC20(linkToken_);
    }

    /// @notice Sends a CCIP message that asks `relay` (on `destChainSelector`) to request a
    ///         deposit of `assets` into `RwaVault` on behalf of `msg.sender` (the controller).
    /// @dev No tokens move here — `data` carries only `(msg.sender, assets)`. The relay is
    ///      trusted (via its own allowlist of `(sourceChainSelector, sender)`, where `sender`
    ///      is THIS contract's address) to fund the actual `requestDeposit` from its own
    ///      pre-funded `DemoUSDC` balance. Fee is paid in LINK, pulled by the router from this
    ///      contract's own balance — see contract-level NatSpec.
    /// @param relay Address of `CrossChainDepositRelay` on the destination chain.
    /// @param destChainSelector CCIP chain selector of the destination chain.
    /// @param assets Amount of the vault's underlying asset the controller wants to deposit.
    /// @return messageId The CCIP message ID returned by the router.
    function sendDeposit(address relay, uint64 destChainSelector, uint256 assets)
        external
        returns (bytes32 messageId)
    {
        if (relay == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(relay),
            data: abi.encode(msg.sender, assets),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: CALLBACK_GAS_LIMIT, allowOutOfOrderExecution: true})
            ),
            feeToken: address(linkToken)
        });

        uint256 fee = router.getFee(destChainSelector, message);
        uint256 balance = linkToken.balanceOf(address(this));
        if (fee > balance) revert InsufficientLinkBalance(fee, balance);

        // Exact-amount approval (not infinite) — no dangling allowance survives this call.
        linkToken.forceApprove(address(router), fee);
        messageId = router.ccipSend(destChainSelector, message);

        emit DepositMessageSent(messageId, destChainSelector, relay, msg.sender, assets, fee);
    }
}
