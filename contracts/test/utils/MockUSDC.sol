// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Test-only 6-decimal ERC-20 double for `RwaVault`'s underlying deposit asset.
/// @dev `mint` is deliberately unrestricted — this contract exists solely so
///      `RwaVault.t.sol` can fund arbitrary test actors (including simulating the
///      off-chain custodian's cash proceeds on the redeem leg) without wiring up a
///      role system unrelated to what this task audits (RwaVault, not MockUSDC).
///      Never deployed outside tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Mirrors real USDC's 6 decimals — matches `TBillToken`'s decimals and the
    ///      `_decimalsOffset()` assumption baked into `RwaVault`'s inflation-attack guard.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
