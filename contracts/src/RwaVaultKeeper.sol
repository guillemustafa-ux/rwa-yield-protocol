// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILogAutomation, Log} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";

/// @title IRwaVaultView — minimal read/write surface `RwaVaultKeeper` needs from `RwaVault`
/// @notice Deliberately narrow: only the public getters/fulfill entrypoints already
///         documented in ARCHITECTURE.md §7.1 (`pendingDepositRequest`,
///         `pendingRedeemRequest`, `totalPendingDepositAssets`,
///         `totalClaimableRedeemAssets`, `asset`, plus the standard ERC-4626
///         `convertToAssets` view and the two fulfill entrypoints). `RwaVault.sol` is
///         not imported directly to keep this file's compilation fully decoupled from
///         it (ownership boundary: this task never touches `RwaVault.sol`). Every
///         signature below is copied verbatim from the deployed `RwaVault.sol`.
interface IRwaVaultView {
    function asset() external view returns (address);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function totalPendingDepositAssets() external view returns (uint256);
    function totalClaimableRedeemAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function fulfillDeposit(address controller, uint256 assets) external returns (uint256 shares);
    function fulfillRedeem(address controller, uint256 shares) external returns (uint256 assets);
}

/// @title RwaVaultKeeper — Chainlink Automation log-trigger keeper for `RwaVault`
/// @author RWA Yield Protocol
/// @notice Wakes up on every `DepositRequest`/`RedeemRequest` log emitted by `RwaVault`
///         (ARCHITECTURE.md §7.1) and, if it is still safe to do so, settles the request
///         by calling `fulfillDeposit`/`fulfillRedeem`. Replaces "an operator manually
///         watching for pending requests" with a log-trigger Automation upkeep — no
///         polling, no on-chain enumeration of pending controllers (the vault
///         deliberately doesn't expose one; adding it would touch an already-audited
///         contract, see ARCHITECTURE.md §7.1's design note).
/// @dev This contract must be granted `OPERATOR_ROLE` on the target `RwaVault` to do
///      anything useful — see {performUpkeep}. It never mints, burns, transfers, or
///      otherwise touches funds directly: every state change happens inside `RwaVault`
///      itself, gated by that role. `RwaVaultKeeper` is pure orchestration.
///
///      TRUST MODEL — why `performUpkeep` re-verifies instead of trusting `performData`:
///      Chainlink's own docs are explicit that `performData` "should not be trusted" —
///      it can be replayed, delayed, or reordered by a racing keeper/reorg. This mirrors
///      the exact reasoning `RwaVault.fulfillRedeem` already applies on-chain (the
///      `InsufficientLiquidity` cap from the D3 invariant campaign, ARCHITECTURE.md §4):
///      never assume a snapshot taken earlier is still true now.
///
///      NO-OP DESIGN DECISION (documented per the task spec): if re-verification in
///      {performUpkeep} finds the request is no longer safe to fulfill (already
///      fulfilled by someone else since `checkLog` ran, or the free asset buffer dried
///      up in the redeem case), this contract returns WITHOUT reverting and WITHOUT
///      calling the vault. A reverted `performUpkeep` transaction still burns the
///      upkeep's LINK balance on gas with nothing to show for it and can make
///      Chainlink's own retry heuristics misbehave; a silent no-op costs a little gas
///      and leaves the request pending for the next log-triggered attempt (or a human
///      operator) to pick up — never money at risk either way. This is a deliberate,
///      narrow no-op: it ONLY covers the two specific race conditions above. Any other
///      revert (e.g. this contract missing `OPERATOR_ROLE`, or `RwaVault` reverting for
///      an unanticipated reason) is NOT swallowed — {performUpkeep} calls the vault
///      directly, with no try/catch, so an unexpected revert propagates and fails the
///      upkeep transaction loudly instead of being hidden as a false "did nothing".
contract RwaVaultKeeper is ILogAutomation {
    /// @notice The vault this keeper watches and operates on.
    IRwaVaultView public immutable vault;

    /// @dev `REQUEST_ID` is always 0 in `RwaVault`'s aggregated (non-per-request-id)
    ///      ERC-7540 model — same constant name/value as `RwaVault.REQUEST_ID`.
    uint256 private constant REQUEST_ID = 0;

    /// @dev `keccak256("DepositRequest(address,address,uint256,address,uint256)")` —
    ///      MUST match `RwaVault.sol`'s event signature exactly; verified against the
    ///      source (see ARCHITECTURE.md §7.1, task instructions: "las firmas EXACTAS
    ///      están en RwaVault.sol").
    bytes32 public constant DEPOSIT_REQUEST_TOPIC0 =
        keccak256("DepositRequest(address,address,uint256,address,uint256)");

    /// @dev `keccak256("RedeemRequest(address,address,uint256,address,uint256)")`.
    bytes32 public constant REDEEM_REQUEST_TOPIC0 =
        keccak256("RedeemRequest(address,address,uint256,address,uint256)");

    /// @notice Emitted when {performUpkeep} actually settled a request.
    event UpkeepPerformed(bool indexed isDeposit, address indexed controller, uint256 amount);

    /// @notice Emitted when {performUpkeep} deliberately did nothing (see contract
    ///         NatSpec, "NO-OP DESIGN DECISION").
    event UpkeepSkipped(bool indexed isDeposit, address indexed controller, uint256 amount, string reason);

    error ZeroAddress();

    /// @param vault_ The `RwaVault` (proxy) address this keeper watches.
    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = IRwaVaultView(vault_);
    }

    // ------------------------------------------------------------------
    // checkLog — off-chain simulated by Chainlink Automation, never an on-chain state
    // change here; marked `view` (a strictly stronger guarantee than the interface's
    // plain, non-payable `checkLog`, which Solidity allows an override to narrow to).
    // ------------------------------------------------------------------

    /// @inheritdoc ILogAutomation
    /// @dev Decodes `controller` straight from the indexed log topic (cheaper and more
    ///      direct than re-deriving it from `log.data`) and independently re-derives,
    ///      from the vault's own public getters only, whether the request is still
    ///      pending and — for redeems — whether there is enough free asset buffer to
    ///      settle it without tripping `RwaVault.fulfillRedeem`'s own
    ///      `InsufficientLiquidity` guard. Never trusts anything from the log besides
    ///      "which controller, which event type" — the actual pending amount is read
    ///      live from the vault, not decoded from `log.data`, so a stale/replayed log
    ///      can never cause a stale amount to be acted on.
    function checkLog(Log calldata log, bytes memory /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (log.source != address(vault)) return (false, "");
        // topics = [topic0, controller, owner, requestId] for both event shapes.
        if (log.topics.length != 4) return (false, "");

        bytes32 topic0 = log.topics[0];
        if (topic0 != DEPOSIT_REQUEST_TOPIC0 && topic0 != REDEEM_REQUEST_TOPIC0) {
            return (false, "");
        }

        address controller = address(uint160(uint256(log.topics[1])));
        bool isDeposit = topic0 == DEPOSIT_REQUEST_TOPIC0;

        if (isDeposit) {
            uint256 pendingAssets = vault.pendingDepositRequest(REQUEST_ID, controller);
            if (pendingAssets == 0) return (false, "");
            return (true, abi.encode(true, controller, pendingAssets));
        }

        uint256 pendingShares = vault.pendingRedeemRequest(REQUEST_ID, controller);
        if (pendingShares == 0) return (false, "");

        uint256 requiredAssets = vault.convertToAssets(pendingShares);
        if (requiredAssets > _freeAssetBuffer()) return (false, "");

        return (true, abi.encode(false, controller, pendingShares));
    }

    // ------------------------------------------------------------------
    // performUpkeep — re-verifies everything, calls the vault directly (no try/catch,
    // see contract NatSpec) so this contract's own `OPERATOR_ROLE` failures still
    // revert loudly.
    // ------------------------------------------------------------------

    /// @inheritdoc ILogAutomation
    function performUpkeep(bytes calldata performData) external override {
        (bool isDeposit, address controller, uint256 amount) = abi.decode(performData, (bool, address, uint256));

        if (controller == address(0) || amount == 0) {
            emit UpkeepSkipped(isDeposit, controller, amount, "invalid performData");
            return;
        }

        if (isDeposit) {
            uint256 pendingAssets = vault.pendingDepositRequest(REQUEST_ID, controller);
            if (pendingAssets < amount) {
                emit UpkeepSkipped(true, controller, amount, "already fulfilled");
                return;
            }
            vault.fulfillDeposit(controller, amount);
            emit UpkeepPerformed(true, controller, amount);
            return;
        }

        uint256 pendingShares = vault.pendingRedeemRequest(REQUEST_ID, controller);
        if (pendingShares < amount) {
            emit UpkeepSkipped(false, controller, amount, "already fulfilled");
            return;
        }

        uint256 requiredAssets = vault.convertToAssets(amount);
        uint256 available = _freeAssetBuffer();
        if (requiredAssets > available) {
            emit UpkeepSkipped(false, controller, amount, "insufficient buffer");
            return;
        }

        vault.fulfillRedeem(controller, amount);
        emit UpkeepPerformed(false, controller, amount);
    }

    // ------------------------------------------------------------------
    // Independent re-derivation of `RwaVault._freeAssetBuffer()` from public getters
    // only (this contract has no privileged/internal access to the vault).
    // ------------------------------------------------------------------

    /// @dev Mirrors `RwaVault._freeAssetBuffer()` exactly: raw asset balance held by
    ///      the vault, minus assets still owed to un-fulfilled depositors, minus
    ///      assets already earmarked for a fulfilled-but-unclaimed redeem. Saturates
    ///      at zero instead of underflowing, same as the vault's own implementation.
    function _freeAssetBuffer() private view returns (uint256) {
        uint256 assetBalance = IERC20(vault.asset()).balanceOf(address(vault));
        uint256 reserved = vault.totalPendingDepositAssets() + vault.totalClaimableRedeemAssets();
        return assetBalance > reserved ? assetBalance - reserved : 0;
    }
}
