// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RwaNavFeed} from "../src/RwaNavFeed.sol";

contract RwaNavFeedTest is Test {
    RwaNavFeed internal feed;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    int256 internal constant INITIAL_NAV = 100e8; // 100.00000000, 8 decimales
    uint256 internal constant ONE_HOUR = 1 hours;

    function setUp() public {
        // El timestamp local de Foundry arranca en 1: sin este warp, block.timestamp +
        // MIN_UPDATE_INTERVAL en el primer test podría dar comparaciones sin sentido.
        vm.warp(1_700_000_000);
        feed = new RwaNavFeed(admin, "tBILL / USD NAV");
    }

    // ---------------------------------------------------------------------
    // Metadata / interfaz AggregatorV3
    // ---------------------------------------------------------------------

    function test_Decimals() public view {
        assertEq(feed.decimals(), 8);
    }

    function test_Description() public view {
        assertEq(feed.description(), "tBILL / USD NAV");
    }

    function test_Version() public view {
        assertEq(feed.version(), 1);
    }

    function test_RevertWhen_NoDataPresent() public {
        vm.expectRevert(RwaNavFeed.NoDataPresent.selector);
        feed.latestRoundData();
    }

    function test_RevertWhen_RoundNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(RwaNavFeed.RoundNotFound.selector, uint80(1)));
        feed.getRoundData(1);
    }

    // ---------------------------------------------------------------------
    // Guarda: rol
    // ---------------------------------------------------------------------

    function test_RevertWhen_CallerLacksRole() public {
        // Se lee el rol ANTES del prank: `vm.prank` solo afecta a la próxima llamada,
        // y una lectura view de por medio la consumiría (falso positivo con el
        // msg.sender equivocado en el error esperado).
        bytes32 navUpdaterRole = feed.NAV_UPDATER_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, navUpdaterRole)
        );
        feed.updateNav(INITIAL_NAV);
    }

    // ---------------------------------------------------------------------
    // Guarda: NAV > 0
    // ---------------------------------------------------------------------

    function test_RevertWhen_NavIsZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RwaNavFeed.InvalidNav.selector, int256(0)));
        feed.updateNav(0);
    }

    function test_RevertWhen_NavIsNegative() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RwaNavFeed.InvalidNav.selector, int256(-1)));
        feed.updateNav(-1);
    }

    // ---------------------------------------------------------------------
    // Primer update: sin guarda de desviación ni frecuencia
    // ---------------------------------------------------------------------

    function test_FirstUpdate_CreatesRoundOne() public {
        vm.prank(admin);
        feed.updateNav(INITIAL_NAV);

        assertEq(feed.latestRoundId(), 1);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, INITIAL_NAV);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_FirstUpdate_SkipsDeviationCheck() public {
        // No hay round anterior: un salto "enorme" (10x) tiene que pasar sin revert,
        // porque todavía no hay contra qué medir desviación.
        vm.prank(admin);
        feed.updateNav(INITIAL_NAV * 10);

        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, INITIAL_NAV * 10);
    }

    function test_FirstUpdate_SkipsFrequencyCheck() public {
        // El primer update no tiene "último update" contra el cual chequear frecuencia.
        vm.prank(admin);
        feed.updateNav(INITIAL_NAV);
        assertEq(feed.latestRoundId(), 1);
    }

    // ---------------------------------------------------------------------
    // Guarda: frecuencia mínima (1 hora)
    // ---------------------------------------------------------------------

    function test_RevertWhen_TooFrequent_SameBlock() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);

        vm.expectRevert(
            abi.encodeWithSelector(RwaNavFeed.TooFrequent.selector, block.timestamp, block.timestamp, ONE_HOUR)
        );
        feed.updateNav(INITIAL_NAV);
        vm.stopPrank();
    }

    function test_RevertWhen_TooFrequent_OneSecondShort() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        uint256 firstUpdateAt = block.timestamp;

        vm.warp(firstUpdateAt + ONE_HOUR - 1);
        vm.expectRevert(
            abi.encodeWithSelector(RwaNavFeed.TooFrequent.selector, firstUpdateAt, block.timestamp, ONE_HOUR)
        );
        feed.updateNav(INITIAL_NAV);
        vm.stopPrank();
    }

    function test_Update_SucceedsExactlyAtOneHourBoundary() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        uint256 firstUpdateAt = block.timestamp;

        vm.warp(firstUpdateAt + ONE_HOUR);
        feed.updateNav(INITIAL_NAV); // 0% desviación, exactamente a la hora: debe pasar
        vm.stopPrank();

        assertEq(feed.latestRoundId(), 2);
    }

    // ---------------------------------------------------------------------
    // Guarda: desviación máxima (±5% = 500 bps)
    // ---------------------------------------------------------------------

    function test_Update_SucceedsAtExactlyMaxDeviationUp() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        vm.warp(block.timestamp + ONE_HOUR);

        int256 newNav = INITIAL_NAV + (INITIAL_NAV * 500) / 10_000; // +5.00% exacto
        feed.updateNav(newNav);
        vm.stopPrank();

        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, newNav);
    }

    function test_Update_SucceedsAtExactlyMaxDeviationDown() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        vm.warp(block.timestamp + ONE_HOUR);

        int256 newNav = INITIAL_NAV - (INITIAL_NAV * 500) / 10_000; // -5.00% exacto
        feed.updateNav(newNav);
        vm.stopPrank();

        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, newNav);
    }

    function test_RevertWhen_DeviationTooHighUp() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        vm.warp(block.timestamp + ONE_HOUR);

        int256 newNav = INITIAL_NAV + (INITIAL_NAV * 501) / 10_000; // 5.01%, por encima
        vm.expectRevert(abi.encodeWithSelector(RwaNavFeed.NavDeviationTooHigh.selector, INITIAL_NAV, newNav, 501));
        feed.updateNav(newNav);
        vm.stopPrank();
    }

    function test_RevertWhen_DeviationTooHighDown() public {
        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        vm.warp(block.timestamp + ONE_HOUR);

        int256 newNav = INITIAL_NAV - (INITIAL_NAV * 501) / 10_000; // -5.01%, por debajo
        vm.expectRevert(abi.encodeWithSelector(RwaNavFeed.NavDeviationTooHigh.selector, INITIAL_NAV, newNav, 501));
        feed.updateNav(newNav);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // roundId monotónico + historial correcto
    // ---------------------------------------------------------------------

    function test_RoundId_MonotonicAcrossUpdates() public {
        vm.startPrank(admin);

        int256 nav = INITIAL_NAV;
        for (uint80 i = 1; i <= 5; i++) {
            feed.updateNav(nav);
            assertEq(feed.latestRoundId(), i);

            (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.getRoundData(i);
            assertEq(roundId, i);
            assertEq(answer, nav);
            assertEq(updatedAt, block.timestamp);
            assertEq(answeredInRound, i);

            vm.warp(block.timestamp + ONE_HOUR);
            // +1% cada round: dentro de la banda, no acumula error de redondeo relevante.
            nav = nav + (nav * 100) / 10_000;
        }

        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Fuzz: desviación dentro y fuera de banda
    // ---------------------------------------------------------------------

    /// @notice Cualquier desviación calculada dentro de [0, MAX_DEVIATION_BPS] tiene
    /// que pasar, en ambas direcciones.
    function testFuzz_DeviationWithinBand_Succeeds(uint256 deviationBps, bool increase) public {
        deviationBps = bound(deviationBps, 0, feed.MAX_DEVIATION_BPS());

        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        vm.warp(block.timestamp + ONE_HOUR);

        int256 delta = (INITIAL_NAV * int256(deviationBps)) / 10_000;
        int256 newNav = increase ? INITIAL_NAV + delta : INITIAL_NAV - delta;

        feed.updateNav(newNav);
        vm.stopPrank();

        assertEq(feed.latestRoundId(), 2);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, newNav);
    }

    /// @notice Cualquier desviación calculada claramente por encima de MAX_DEVIATION_BPS
    /// (con margen para evitar ambigüedad de redondeo en el límite) tiene que revertir,
    /// en ambas direcciones.
    function testFuzz_DeviationOutsideBand_Reverts(uint256 deviationBps, bool increase) public {
        // Margen de +100bps sobre el máximo para que el redondeo entero de
        // `_deviationBps` nunca lo haga caer de nuevo dentro de la banda permitida.
        deviationBps = bound(deviationBps, feed.MAX_DEVIATION_BPS() + 100, 9_000);

        vm.startPrank(admin);
        feed.updateNav(INITIAL_NAV);
        vm.warp(block.timestamp + ONE_HOUR);

        int256 delta = (INITIAL_NAV * int256(deviationBps)) / 10_000;
        int256 newNav = increase ? INITIAL_NAV + delta : INITIAL_NAV - delta;

        vm.expectRevert();
        feed.updateNav(newNav);
        vm.stopPrank();
    }
}
