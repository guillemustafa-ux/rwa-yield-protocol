// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TBillToken
/// @author RWA Yield Protocol
/// @notice Synthetic representation of a tokenized T-bill unit ("tBILL"). This
///         token is the RWA leg of the protocol: it stands in for a custodian
///         actually buying/selling short-term treasury bills off-chain.
/// @dev IMPORTANT — this token holds NO pricing logic and NO yield logic on
///      purpose. It is a plain ERC-20 whose supply is minted/burned by the
///      protocol's `ASSET_MANAGER_ROLE` to mirror real-world purchases and
///      redemptions of the underlying T-bill. The *value* of 1 tBILL (its NAV)
///      is never derived from this contract — it lives exclusively in
///      `RwaNavFeed`, the Chainlink-compatible oracle described in
///      ARCHITECTURE.md §3.2. `RwaVault` reads that feed to price holdings;
///      this contract only tracks unit accounting (how many synthetic T-bill
///      units the vault currently holds), never their dollar value.
///
///      Decimals are fixed at 6 to mirror how real tokenized T-bill products
///      (e.g. BUIDL, USDY-style rebasers) are typically denominated, and to
///      match the USDC leg of the vault's accounting.
///
///      Access control: the deployer receives `DEFAULT_ADMIN_ROLE` at
///      construction and is expected to grant `ASSET_MANAGER_ROLE` to the
///      protocol's asset-manager operator (or another contract) post-deploy.
///      The admin role itself mints/burns nothing — only holders of
///      `ASSET_MANAGER_ROLE` can.
contract TBillToken is ERC20, AccessControl {
    /// @notice Role allowed to mint and burn tBILL, simulating the custodian
    ///         buying (`mint`) or selling (`burn`) the underlying T-bill.
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");

    /// @notice Thrown when `burn` is attempted for more tokens than `from` holds.
    /// @param account The account whose balance was insufficient.
    /// @param balance The account's current balance.
    /// @param amount The amount that was attempted to be burned.
    error InsufficientBalance(address account, uint256 balance, uint256 amount);

    /// @notice Thrown when `mint` or `burn` is called with the zero address.
    error ZeroAddress();

    /// @notice Thrown when `mint` or `burn` is called with a zero amount.
    error ZeroAmount();

    /// @param admin Address granted `DEFAULT_ADMIN_ROLE`. Expected to be the
    ///        protocol deployer/multisig, which can later grant
    ///        `ASSET_MANAGER_ROLE` to the vault or an operator EOA.
    constructor(address admin) ERC20("Synthetic T-Bill", "tBILL") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mints `amount` of tBILL to `to`, representing the custodian
    ///         having purchased that much of the underlying T-bill.
    /// @dev Only callable by `ASSET_MANAGER_ROLE`. Pricing/valuation of this
    ///      amount happens entirely off this contract, in `RwaNavFeed`.
    /// @param to Recipient of the newly minted synthetic units.
    /// @param amount Amount of tBILL units to mint (6 decimals).
    function mint(address to, uint256 amount) external onlyRole(ASSET_MANAGER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @notice Burns `amount` of tBILL from `from`, representing the custodian
    ///         having sold/redeemed that much of the underlying T-bill.
    /// @dev Only callable by `ASSET_MANAGER_ROLE`. Does not require allowance:
    ///      the asset manager is a trusted protocol role acting on custody
    ///      holdings, not on arbitrary user balances via approval.
    /// @param from Account whose synthetic units are burned.
    /// @param amount Amount of tBILL units to burn (6 decimals).
    function burn(address from, uint256 amount) external onlyRole(ASSET_MANAGER_ROLE) {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 balance = balanceOf(from);
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        _burn(from, amount);
    }

    /// @notice Synthetic T-bill units are denominated with 6 decimals, matching
    ///         the USDC leg of the vault and common real-world tokenized
    ///         T-bill conventions.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc AccessControl
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
