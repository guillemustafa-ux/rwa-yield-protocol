// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title RwaNavFeed
/// @notice Oráculo de NAV (Net Asset Value) del tBILL sintético, compatible con la
/// interfaz `AggregatorV3Interface` de Chainlink. `RwaVault` lo consume exactamente
/// igual que a un feed real de Chainlink (misma interfaz, mismos chequeos de
/// staleness/decimales del lado del consumidor) — esa simetría permite un swap-in
/// directo el día que exista un feed oficial de T-bills en la red.
/// @dev El NAV lo publica un operador humano/proceso off-chain (`NAV_UPDATER_ROLE`),
/// no un nodo descentralizado. Por eso las guardas de `updateNav` no son opcionales:
/// son la única defensa on-chain contra dos escenarios reales de este diseño:
///   1. Fat-finger: el operador tipea mal el NAV (ej. le falta un cero) y en vez de
///      publicar 100.50 publica 10050. Sin banda de desviación esto se propaga
///      instantáneamente al `totalAssets()` del vault y puede gatillar liquidaciones
///      o permitir arbitraje contra los depositantes.
///   2. Key comprometida: si la clave del updater se filtra, un atacante con esa
///      key sola solo puede mover el NAV hasta ±5% por hora, no vaciar el vault
///      en una sola transacción — la banda de desviación y el rate limit convierten
///      un robo de key en un incidente detectable/parable, no en un evento catastrófico
///      instantáneo.
contract RwaNavFeed is AggregatorV3Interface, AccessControl {
    /// @notice Rol autorizado a publicar nuevos valores de NAV.
    bytes32 public constant NAV_UPDATER_ROLE = keccak256("NAV_UPDATER_ROLE");

    /// @notice Desviación máxima permitida entre un update y el anterior, en basis points.
    /// @dev 500 bps = 5%. Mitiga fat-finger: un typo que mueva el NAV un orden de
    /// magnitud (10x, 100x) revierte en vez de propagarse al accounting del vault.
    uint256 public constant MAX_DEVIATION_BPS = 500;

    /// @notice Denominador de basis points (100% = 10_000 bps).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Tiempo mínimo entre dos updates de NAV.
    /// @dev Rate limit temporal: aunque el atacante logre pasar la banda de desviación
    /// update tras update, el compromiso de la key deja de ser "vaciar el protocolo en
    /// un bloque" y pasa a ser "un proceso de horas" — ventana real para que el
    /// `PAUSER_ROLE` (fuera de este contrato) reaccione y pause el vault.
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;

    /// @notice Decimales del feed (igual que los feeds USD de Chainlink).
    uint8 private constant _DECIMALS = 8;

    /// @notice Versión del esquema de datos del feed (compatibilidad Chainlink).
    uint256 private constant _VERSION = 1;

    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    /// @notice Descripción humana del feed, fijada en el deploy.
    string private _description;

    /// @notice Id del round más reciente. 0 significa que todavía no hubo ningún update.
    uint80 public latestRoundId;

    /// @dev Historial completo de rounds, indexado por roundId.
    mapping(uint80 roundId => Round) private _rounds;

    /// @notice Se emite cada vez que se publica un nuevo NAV.
    /// @param roundId Id del nuevo round.
    /// @param nav Valor de NAV publicado.
    /// @param updatedAt Timestamp del update.
    event NavUpdated(uint80 indexed roundId, int256 nav, uint256 updatedAt);

    /// @notice El NAV publicado no es positivo.
    error InvalidNav(int256 nav);

    /// @notice La desviación contra el round anterior supera `MAX_DEVIATION_BPS`.
    error NavDeviationTooHigh(int256 previousNav, int256 newNav, uint256 deviationBps);

    /// @notice No pasó `MIN_UPDATE_INTERVAL` desde el último update.
    error TooFrequent(uint256 lastUpdatedAt, uint256 currentTimestamp, uint256 minInterval);

    /// @notice Todavía no se publicó ningún NAV.
    error NoDataPresent();

    /// @notice El `roundId` consultado no existe.
    error RoundNotFound(uint80 roundId);

    /// @param admin Cuenta que recibe `DEFAULT_ADMIN_ROLE` y `NAV_UPDATER_ROLE` iniciales.
    /// @param description_ Descripción legible del feed (ej. "tBILL / USD NAV").
    constructor(address admin, string memory description_) {
        _description = description_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(NAV_UPDATER_ROLE, admin);
    }

    /// @notice Publica un nuevo valor de NAV.
    /// @dev El primer update (cuando todavía no existe round anterior) queda exento
    /// de la banda de desviación y del rate limit: no hay un valor previo válido
    /// contra el cual medir "desviación" ni "frecuencia". A partir del segundo
    /// update ambas guardas aplican siempre.
    /// @param newNav Nuevo valor de NAV (8 decimales, igual que `decimals()`).
    function updateNav(int256 newNav) external onlyRole(NAV_UPDATER_ROLE) {
        if (newNav <= 0) revert InvalidNav(newNav);

        uint80 previousRoundId = latestRoundId;

        if (previousRoundId != 0) {
            Round memory previousRound = _rounds[previousRoundId];

            if (block.timestamp < previousRound.updatedAt + MIN_UPDATE_INTERVAL) {
                revert TooFrequent(previousRound.updatedAt, block.timestamp, MIN_UPDATE_INTERVAL);
            }

            uint256 deviationBps = _deviationBps(previousRound.answer, newNav);
            if (deviationBps > MAX_DEVIATION_BPS) {
                revert NavDeviationTooHigh(previousRound.answer, newNav, deviationBps);
            }
        }

        uint80 newRoundId = previousRoundId + 1;
        _rounds[newRoundId] =
            Round({answer: newNav, startedAt: block.timestamp, updatedAt: block.timestamp, answeredInRound: newRoundId});
        latestRoundId = newRoundId;

        emit NavUpdated(newRoundId, newNav, block.timestamp);
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure returns (uint8) {
        return _DECIMALS;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return _VERSION;
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory round = _rounds[_roundId];
        if (round.updatedAt == 0) revert RoundNotFound(_roundId);
        return (_roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (latestRoundId == 0) revert NoDataPresent();
        Round memory round = _rounds[latestRoundId];
        return (latestRoundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    /// @dev Calcula la desviación absoluta entre `previousNav` y `newNav` en basis points.
    /// `previousNav` siempre es > 0 (invariante mantenida por `updateNav`), por lo que
    /// la división es segura.
    function _deviationBps(int256 previousNav, int256 newNav) private pure returns (uint256) {
        int256 diff = newNav - previousNav;
        uint256 absDiff = diff >= 0 ? uint256(diff) : uint256(-diff);
        return (absDiff * BPS_DENOMINATOR) / uint256(previousNav);
    }
}
