import { formatUnits } from 'viem'

/** Trunca una address estilo `0x1234…abcd` para mostrar en UI. */
export function truncateAddress(address: string, chars = 4): string {
  if (address.length <= chars * 2 + 2) return address
  return `${address.slice(0, chars + 2)}…${address.slice(-chars)}`
}

/**
 * Formatea un bigint on-chain (assets, shares, NAV) a un string legible con
 * cantidad fija de decimales de display. `undefined` (todavía no llegó el
 * read) se distingue de `0n` (leyó y es cero) — el caller decide qué mostrar
 * para cada caso, acá solo formateamos lo que YA es un bigint.
 */
export function formatTokenAmount(value: bigint, decimals: number, displayDecimals = 2): string {
  const asNumber = Number(formatUnits(value, decimals))
  return new Intl.NumberFormat('en-US', {
    minimumFractionDigits: displayDecimals,
    maximumFractionDigits: displayDecimals,
  }).format(asNumber)
}

/** Timestamp unix (segundos, como devuelve `latestRoundData`) a fecha/hora local legible. */
export function formatUnixSeconds(seconds: bigint): string {
  return new Date(Number(seconds) * 1000).toLocaleString('en-US', {
    dateStyle: 'medium',
    timeStyle: 'short',
  })
}

/** Segundos transcurridos desde un timestamp unix — para mostrar "hace Xm" y detectar staleness a ojo. */
export function secondsSince(seconds: bigint): number {
  return Math.max(0, Math.floor(Date.now() / 1000) - Number(seconds))
}
