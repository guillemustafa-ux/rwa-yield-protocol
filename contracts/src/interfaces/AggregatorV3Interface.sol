// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AggregatorV3Interface
/// @notice Interfaz estándar de Chainlink para price/data feeds (definida localmente
/// porque no existe un feed oficial de T-bills en Sepolia). Es idéntica en firma a la
/// interfaz publicada por el paquete de contratos oficial de Chainlink, para que
/// `RwaVault` la consuma exactamente igual que a un feed real y el swap-in del día
/// que exista un feed oficial de T-bills sea un simple cambio de dirección.
interface AggregatorV3Interface {
    /// @notice Cantidad de decimales de las respuestas del feed.
    function decimals() external view returns (uint8);

    /// @notice Descripción legible del feed (ej. "tBILL / USD NAV").
    function description() external view returns (string memory);

    /// @notice Versión del esquema del feed.
    function version() external view returns (uint256);

    /// @notice Devuelve los datos de un round específico.
    /// @param _roundId Id del round consultado.
    /// @return roundId Id del round devuelto.
    /// @return answer Valor reportado en ese round.
    /// @return startedAt Timestamp en que comenzó el round.
    /// @return updatedAt Timestamp en que se actualizó el round.
    /// @return answeredInRound Id del round en que se respondió (compatibilidad Chainlink).
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Devuelve los datos del round más reciente.
    /// @return roundId Id del último round.
    /// @return answer Último valor reportado.
    /// @return startedAt Timestamp en que comenzó el último round.
    /// @return updatedAt Timestamp en que se actualizó el último round.
    /// @return answeredInRound Id del round en que se respondió (compatibilidad Chainlink).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
