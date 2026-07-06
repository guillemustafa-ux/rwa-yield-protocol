// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RwaVault} from "../../src/RwaVault.sol";
import {RwaNavFeed} from "../../src/RwaNavFeed.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {MockUSDC} from "../utils/MockUSDC.sol";

/// @title RwaVaultForkTest
/// @notice Fork test against REAL Sepolia (ARCHITECTURE.md §5, "Fork test contra Sepolia
///         real leyendo el feed Chainlink ... staleness handling con datos reales"). The
///         central claim under test is ARCHITECTURE.md §3.2: `RwaVault` consumes
///         `RwaNavFeed` "exactamente igual que a un feed de Chainlink" — this file proves
///         that by pointing a REAL vault deployment at the REAL Sepolia ETH/USD
///         `AggregatorV3Interface` feed (`0x694AA...5306`) and exercising the exact same
///         `_latestNav()`/`totalAssets()` code path the unit suite already exercises
///         against the mock `RwaNavFeed`.
/// @dev OWNERSHIP: this file is exclusively owned by the fork-test task; no other test
///      file should be touched from here.
///
///      NETWORK SAFETY: every test calls {_requireFork} as its first line, which tries
///      the primary public Sepolia RPC and falls back to a secondary one. If NEITHER is
///      reachable it calls `vm.skip(true, ...)` and returns — this suite must NEVER break
///      an offline `forge test` run. `_requireFork`'s network attempt lives entirely inside
///      a `try/catch` so a DNS failure/timeout/rate-limit cannot bubble up as a test
///      failure; only the explicit, uncaught `vm.skip` call (which must never itself sit
///      inside a try/catch, per the cheatcode's "must be called at the top level of a
///      test" contract) marks the test skipped.
contract RwaVaultForkTest is Test {
    /// @dev Public, no-key-required Sepolia RPC (per task spec).
    string internal constant PRIMARY_RPC = "https://ethereum-sepolia-rpc.publicnode.com";

    /// @dev Fallback if the primary is unreachable/rate-limited (per task spec).
    string internal constant FALLBACK_RPC = "https://rpc.sepolia.org";

    /// @dev REAL Chainlink ETH/USD feed on Sepolia (per task spec). Used as a stand-in
    ///      `navFeed` purely to prove `RwaVault` can consume a genuine, independently
    ///      deployed `AggregatorV3Interface` implementation — the USD value of ETH has no
    ///      economic meaning as a T-bill NAV here, only the wiring/decoding is under test.
    address internal constant REAL_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal assetManager = makeAddr("assetManager");
    address internal navAdmin = makeAddr("navAdmin");
    address internal alice = makeAddr("alice");

    MockUSDC internal asset;
    TBillToken internal tBillToken;

    // ------------------------------------------------------------------
    // Fork bootstrap
    // ------------------------------------------------------------------

    /// @dev Tries the primary RPC, then the fallback. Returns false (never reverts) if
    ///      neither is reachable.
    function _trySelectSepoliaFork() private returns (bool) {
        try vm.createSelectFork(PRIMARY_RPC) returns (uint256) {
            return true;
        } catch {
            try vm.createSelectFork(FALLBACK_RPC) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// @dev Call as the FIRST line of every test in this file. `vm.skip` is intentionally
    ///      NOT inside the try/catch above (it must run at the top level of the test to be
    ///      recognized as a skip rather than a failure).
    function _requireFork() private {
        bool ok = _trySelectSepoliaFork();
        if (!ok) {
            vm.skip(true, "no network reachable (tried publicnode + rpc.sepolia.org): skipping fork test");
        }
    }

    /// @dev Deploys a fresh RwaVault stack (MockUSDC asset + TBillToken + RwaVault behind
    ///      an ERC1967Proxy, per the repo-wide "deploy SOLO vía proxy + initialize" gotcha)
    ///      on whatever fork is currently selected, wired to `navFeedAddr` — which may be
    ///      the REAL Chainlink feed or our own `RwaNavFeed`. Exercising both through this
    ///      one helper is itself part of the "misma interfaz" proof: no branch in this
    ///      deploy path cares which kind of `AggregatorV3Interface` it received.
    function _deployVault(AggregatorV3Interface navFeedAddr) private returns (RwaVault vault) {
        asset = new MockUSDC();
        tBillToken = new TBillToken(admin);

        RwaVault implementation = new RwaVault();
        bytes memory initData = abi.encodeCall(
            RwaVault.initialize, (IERC20(address(asset)), IERC20Metadata(address(tBillToken)), navFeedAddr, admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = RwaVault(address(proxy));

        // admin appoints operational roles post-deploy (contract NatSpec point 2).
        vm.startPrank(admin);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.ASSET_MANAGER_ROLE(), assetManager);
        vm.stopPrank();

        // TBillToken is a separate AccessControl instance — cache the role hash BEFORE
        // the prank (a view call sandwiched between vm.prank and the intended call
        // consumes the prank — Windows/foundry gotcha already bitten 3x in this repo).
        bytes32 tBillAssetManagerRole = tBillToken.ASSET_MANAGER_ROLE();
        vm.prank(admin);
        tBillToken.grantRole(tBillAssetManagerRole, assetManager);
    }

    // ==================================================================
    // 1) Real feed wiring + decimals
    // ==================================================================

    /// @notice The vault deploys cleanly against the REAL Sepolia Chainlink feed, and that
    ///         feed reports `decimals() == 8` exactly like `RwaNavFeed` does.
    function test_Fork_Vault_DeploysAgainstRealChainlinkFeed_WhichReports8Decimals() public {
        _requireFork();

        AggregatorV3Interface realFeed = AggregatorV3Interface(REAL_ETH_USD_FEED);
        assertEq(realFeed.decimals(), 8, "real Sepolia ETH/USD feed must report 8 decimals");

        RwaVault vault = _deployVault(realFeed);
        assertEq(address(vault.navFeed()), REAL_ETH_USD_FEED);
    }

    /// @notice `totalAssets()` reading the REAL feed matches a manual replica of
    ///         `_tBillValueInAsset`'s math (assetDec=6, tBillDec=6, navDec=8 => divide by
    ///         1e8) — proving `_latestNav()` decodes the real feed's `latestRoundData()`
    ///         correctly, not just "doesn't revert".
    function test_Fork_TotalAssets_ConsumesRealFeed_MatchesManualNavComputation() public {
        _requireFork();

        RwaVault vault = _deployVault(AggregatorV3Interface(REAL_ETH_USD_FEED));

        // Non-zero tBILL holding forces an oracle read (zero balance short-circuits it).
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6); // 10 tBILL units, 6 decimals

        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(REAL_ETH_USD_FEED).latestRoundData();
        assertGt(answer, 0, "real feed answer must be positive at the forked block");

        // numeratorExp = assetDec(6); denominatorExp = tBillDec(6) + navDec(8) = 14;
        // numeratorExp < denominatorExp => tBillAmount * nav / 10**(14-6) = .../1e8.
        uint256 expected = (uint256(10e6) * uint256(answer)) / 1e8;
        assertEq(vault.totalAssets(), expected);

        // Sanity for the staleness tests below: the block we forked from must not already
        // be past MAX_STALENESS, otherwise "fresh" below would be self-contradictory.
        assertLt(block.timestamp - updatedAt, vault.MAX_STALENESS());
    }

    // ==================================================================
    // 2) Staleness handling with the REAL feed's REAL updatedAt — both sides.
    // ==================================================================

    /// @notice Warping to one second BEFORE the real feed's staleness cutoff must NOT
    ///         revert.
    function test_Fork_TotalAssets_SucceedsWhenRealFeedIsJustBeforeStale() public {
        _requireFork();

        RwaVault vault = _deployVault(AggregatorV3Interface(REAL_ETH_USD_FEED));
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        (,,, uint256 updatedAt,) = AggregatorV3Interface(REAL_ETH_USD_FEED).latestRoundData();

        vm.warp(updatedAt + vault.MAX_STALENESS() - 1);
        uint256 total = vault.totalAssets();
        assertGt(total, 0);
    }

    /// @notice Warping to one second AFTER the real feed's `updatedAt + MAX_STALENESS`
    ///         must revert with `StaleNav(updatedAt, currentTimestamp)` — same guard,
    ///         same revert shape as the mock-feed unit tests, now against a genuine
    ///         Chainlink `updatedAt` instead of one we control.
    function test_Fork_TotalAssets_RevertsWhenRealFeedIsStale() public {
        _requireFork();

        RwaVault vault = _deployVault(AggregatorV3Interface(REAL_ETH_USD_FEED));
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        (,,, uint256 updatedAt,) = AggregatorV3Interface(REAL_ETH_USD_FEED).latestRoundData();

        uint256 staleTimestamp = updatedAt + vault.MAX_STALENESS() + 1;
        vm.warp(staleTimestamp);

        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.totalAssets();
    }

    /// @notice Same staleness guard, hit via `fulfillDeposit` (the other call site that
    ///         needs a NAV price once the vault already holds tBILL) instead of the plain
    ///         `totalAssets()` view — confirms {_latestNav} is the single funnel point in
    ///         practice, not just in NatSpec, against real oracle data.
    function test_Fork_FulfillDeposit_RevertsWhenRealFeedIsStale() public {
        _requireFork();

        RwaVault vault = _deployVault(AggregatorV3Interface(REAL_ETH_USD_FEED));
        vm.prank(assetManager);
        tBillToken.mint(address(vault), 10e6);

        asset.mint(alice, 1_000e6);
        vm.prank(alice);
        asset.approve(address(vault), 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        (,,, uint256 updatedAt,) = AggregatorV3Interface(REAL_ETH_USD_FEED).latestRoundData();
        uint256 staleTimestamp = updatedAt + vault.MAX_STALENESS() + 1;
        vm.warp(staleTimestamp);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(RwaVault.StaleNav.selector, updatedAt, staleTimestamp));
        vault.fulfillDeposit(alice, 1_000e6);
    }

    // ==================================================================
    // 3) Full request/fulfill/claim flow against the real feed (before any tBILL is
    //    minted, so totalAssets() is pure buffer and the oracle isn't even consulted —
    //    proves the deposit rail works end to end on a real fork, not just totalAssets()).
    // ==================================================================

    function test_Fork_FulfillDeposit_And_Claim_WorkAgainstRealFeedWiredVault() public {
        _requireFork();

        RwaVault vault = _deployVault(AggregatorV3Interface(REAL_ETH_USD_FEED));

        asset.mint(alice, 1_000e6);
        vm.prank(alice);
        asset.approve(address(vault), 1_000e6);
        vm.prank(alice);
        vault.requestDeposit(1_000e6, alice, alice);

        vm.prank(operator);
        uint256 shares = vault.fulfillDeposit(alice, 1_000e6);
        assertGt(shares, 0);

        vm.prank(alice);
        uint256 claimed = vault.deposit(1_000e6, alice, alice);
        assertEq(claimed, shares);
        assertEq(vault.balanceOf(alice), shares);
    }

    // ==================================================================
    // 4) Our own RwaNavFeed, deployed on the SAME fork, answers byte-compatible with the
    //    real Chainlink feed at the raw ABI level — the central §3.2 claim, checked below
    //    the Solidity type system instead of just "both compile against the interface".
    // ==================================================================

    function test_Fork_OwnNavFeed_IsByteCompatibleWithRealFeed_LatestRoundData() public {
        _requireFork();

        RwaNavFeed ownFeed = new RwaNavFeed(navAdmin, "tBILL / USD NAV");
        vm.prank(navAdmin);
        ownFeed.updateNav(100e8);

        (bool okReal, bytes memory dataReal) =
            REAL_ETH_USD_FEED.staticcall(abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector));
        (bool okOwn, bytes memory dataOwn) =
            address(ownFeed).staticcall(abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector));

        assertTrue(okReal, "real Chainlink feed call must succeed");
        assertTrue(okOwn, "own RwaNavFeed call must succeed");

        // Same ABI shape: (uint80, int256, uint256, uint256, uint80) => 5 static words,
        // byte-for-byte the same LENGTH even though the VALUES differ (different oracles).
        assertEq(dataReal.length, 5 * 32, "real feed return data must be 5 words");
        assertEq(dataOwn.length, 5 * 32, "own feed return data must be 5 words");

        // Both decode cleanly into the interface's declared return types — if either feed
        // used a different tuple shape (e.g. a packed struct) this abi.decode would revert.
        (uint80 rId1, int256 ans1,, uint256 upd1,) = abi.decode(dataReal, (uint80, int256, uint256, uint256, uint80));
        (uint80 rId2, int256 ans2,, uint256 upd2,) = abi.decode(dataOwn, (uint80, int256, uint256, uint256, uint80));

        assertGt(rId1, 0);
        assertGt(rId2, 0);
        assertGt(ans1, 0);
        assertGt(ans2, 0);
        assertGt(upd1, 0);
        assertGt(upd2, 0);

        // decimals() is byte-compatible too: both single uint8 words, both equal to 8.
        (bool okRealDec, bytes memory decReal) =
            REAL_ETH_USD_FEED.staticcall(abi.encodeWithSelector(AggregatorV3Interface.decimals.selector));
        (bool okOwnDec, bytes memory decOwn) =
            address(ownFeed).staticcall(abi.encodeWithSelector(AggregatorV3Interface.decimals.selector));
        assertTrue(okRealDec && okOwnDec, "decimals() must succeed on both feeds");
        assertEq(decReal.length, 32);
        assertEq(decOwn.length, 32);
        assertEq(abi.decode(decReal, (uint8)), abi.decode(decOwn, (uint8)));
    }

    /// @notice Two vaults on the SAME fork, one wired to our own `RwaNavFeed`, one wired to
    ///         the REAL Chainlink feed, both go through the exact same `totalAssets()` /
    ///         `_latestNav()` implementation with no special-casing — the "swap-in real
    ///         possible" claim from the contract NatSpec on `RwaNavFeed`, demonstrated with
    ///         a genuine external contract instead of a mock standing in for "a Chainlink
    ///         feed".
    function test_Fork_Vault_TreatsOwnFeedAndRealFeedIdentically_ThroughSameCodePath() public {
        _requireFork();

        RwaNavFeed ownFeed = new RwaNavFeed(navAdmin, "tBILL / USD NAV");
        vm.prank(navAdmin);
        ownFeed.updateNav(100e8);

        RwaVault vaultOwn = _deployVault(ownFeed);
        vm.prank(assetManager);
        tBillToken.mint(address(vaultOwn), 10e6);
        assertEq(vaultOwn.totalAssets(), 1_000e6); // 10 tBILL * 100.00000000 NAV, navDec=8

        RwaVault vaultReal = _deployVault(AggregatorV3Interface(REAL_ETH_USD_FEED));
        vm.prank(assetManager);
        tBillToken.mint(address(vaultReal), 10e6);
        // Doesn't revert, doesn't special-case: same totalAssets()/_latestNav() code,
        // now running against a real external contract instead of `RwaNavFeed`.
        uint256 realTotal = vaultReal.totalAssets();
        assertGt(realTotal, 0);
    }
}
