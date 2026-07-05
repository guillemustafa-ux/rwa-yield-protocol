// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TBillToken} from "../src/TBillToken.sol";

/// @title TBillTokenTest
/// @notice Unit + fuzz coverage for TBillToken per ARCHITECTURE.md §3.1.
contract TBillTokenTest is Test {
    TBillToken internal token;

    address internal admin = makeAddr("admin");
    address internal assetManager = makeAddr("assetManager");
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        // Windows/foundry gotcha: local timestamp starts at 1, warp in setUp.
        vm.warp(1_700_000_000);

        token = new TBillToken(admin);

        // NOTE: fetch the role hash *before* pranking — an extra external call
        // (even a view call) placed between vm.prank and the intended call
        // consumes the prank, so the role must be cached first.
        bytes32 assetManagerRole = token.ASSET_MANAGER_ROLE();
        vm.prank(admin);
        token.grantRole(assetManagerRole, assetManager);
    }

    // ---------------------------------------------------------------------
    // Constructor / roles
    // ---------------------------------------------------------------------

    function test_ConstructorGrantsAdminRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ConstructorRevertsOnZeroAdmin() public {
        vm.expectRevert(TBillToken.ZeroAddress.selector);
        new TBillToken(address(0));
    }

    function test_AdminCanGrantAssetManagerRole() public {
        address newManager = makeAddr("newManager");
        bytes32 role = token.ASSET_MANAGER_ROLE();
        assertFalse(token.hasRole(role, newManager));

        vm.prank(admin);
        token.grantRole(role, newManager);

        assertTrue(token.hasRole(role, newManager));
    }

    // ---------------------------------------------------------------------
    // Metadata
    // ---------------------------------------------------------------------

    function test_NameAndSymbol() public view {
        assertEq(token.name(), "Synthetic T-Bill");
        assertEq(token.symbol(), "tBILL");
    }

    function test_Decimals() public view {
        assertEq(token.decimals(), 6);
    }

    // ---------------------------------------------------------------------
    // mint
    // ---------------------------------------------------------------------

    function test_MintByAssetManager() public {
        vm.prank(assetManager);
        token.mint(user, 1_000e6);

        assertEq(token.balanceOf(user), 1_000e6);
        assertEq(token.totalSupply(), 1_000e6);
    }

    function test_RevertMintWithoutRole() public {
        bytes32 role = token.ASSET_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        token.mint(user, 1_000e6);
    }

    function test_RevertMintToZeroAddress() public {
        vm.prank(assetManager);
        vm.expectRevert(TBillToken.ZeroAddress.selector);
        token.mint(address(0), 1_000e6);
    }

    function test_RevertMintZeroAmount() public {
        vm.prank(assetManager);
        vm.expectRevert(TBillToken.ZeroAmount.selector);
        token.mint(user, 0);
    }

    // ---------------------------------------------------------------------
    // burn
    // ---------------------------------------------------------------------

    function test_BurnByAssetManager() public {
        vm.prank(assetManager);
        token.mint(user, 1_000e6);

        vm.prank(assetManager);
        token.burn(user, 400e6);

        assertEq(token.balanceOf(user), 600e6);
        assertEq(token.totalSupply(), 600e6);
    }

    function test_RevertBurnWithoutRole() public {
        vm.prank(assetManager);
        token.mint(user, 1_000e6);

        bytes32 role = token.ASSET_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        token.burn(user, 400e6);
    }

    function test_RevertBurnFromZeroAddress() public {
        vm.prank(assetManager);
        vm.expectRevert(TBillToken.ZeroAddress.selector);
        token.burn(address(0), 1);
    }

    function test_RevertBurnZeroAmount() public {
        vm.prank(assetManager);
        token.mint(user, 1_000e6);

        vm.prank(assetManager);
        vm.expectRevert(TBillToken.ZeroAmount.selector);
        token.burn(user, 0);
    }

    function test_RevertBurnInsufficientBalance() public {
        vm.prank(assetManager);
        token.mint(user, 100e6);

        vm.prank(assetManager);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.InsufficientBalance.selector, user, 100e6, 101e6));
        token.burn(user, 101e6);
    }

    function test_BurnDoesNotRequireAllowance() public {
        // ASSET_MANAGER_ROLE burns directly on custody holdings, no approve needed.
        vm.prank(assetManager);
        token.mint(user, 500e6);

        assertEq(token.allowance(user, assetManager), 0);

        vm.prank(assetManager);
        token.burn(user, 500e6);

        assertEq(token.balanceOf(user), 0);
    }

    // ---------------------------------------------------------------------
    // Fuzz: supply conservation
    // ---------------------------------------------------------------------

    /// @notice For any sequence of mint(amount) then burn(burnAmount <= amount),
    ///         total supply and the user's balance must always equal exactly
    ///         mintAmount - burnAmount — no drift, no phantom minting.
    function testFuzz_SupplyConservation(uint128 mintAmount, uint128 burnAmount) public {
        vm.assume(mintAmount > 0);
        burnAmount = uint128(bound(burnAmount, 0, mintAmount));

        vm.prank(assetManager);
        token.mint(user, mintAmount);
        assertEq(token.totalSupply(), mintAmount);
        assertEq(token.balanceOf(user), mintAmount);

        if (burnAmount > 0) {
            vm.prank(assetManager);
            token.burn(user, burnAmount);
        }

        uint256 expected = uint256(mintAmount) - uint256(burnAmount);
        assertEq(token.totalSupply(), expected);
        assertEq(token.balanceOf(user), expected);
    }
}
