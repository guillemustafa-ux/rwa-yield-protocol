import type { JSX } from 'react'
import { Badge } from '../ui/Badge'
import { formatTokenAmount, formatUnixSeconds, secondsSince } from '../../lib/format'

/**
 * Panel lateral del vault: NAV vigente + hace cuánto se actualizó (con
 * warning si se acerca al límite de staleness del contrato), share price, y
 * las shares del usuario conectado + su valor actual en assets.
 *
 * El umbral de warning (5/6 de `MAX_STALENESS`, es decir 20h de las 24h del
 * contrato — ARCHITECTURE.md §3.3/§4) se deriva del valor LEÍDO on-chain
 * (`maxStalenessSeconds`), no de un `24 * 3600` hardcodeado a ciegas: si el
 * contrato cambiara ese parámetro en una futura versión, este panel lo
 * sigue automáticamente.
 */
export function NavSidePanel({
  isLoading,
  navAnswer,
  navDecimals,
  navUpdatedAt,
  maxStalenessSeconds,
  sharePrice,
  assetDecimals,
  userShares,
  shareDecimals,
  userSharesValueAssets,
}: {
  isLoading: boolean
  navAnswer?: bigint
  navDecimals?: number
  navUpdatedAt?: bigint
  maxStalenessSeconds?: bigint
  sharePrice?: bigint
  assetDecimals?: number
  userShares?: bigint
  shareDecimals?: number
  userSharesValueAssets?: bigint
}): JSX.Element {
  const staleSeconds = navUpdatedAt !== undefined ? secondsSince(navUpdatedAt) : undefined
  const warnAfterSeconds =
    maxStalenessSeconds !== undefined ? Number((maxStalenessSeconds * 5n) / 6n) : undefined // 20h de 24h
  const isNearStale =
    staleSeconds !== undefined && warnAfterSeconds !== undefined && staleSeconds >= warnAfterSeconds
  const isHardStale =
    staleSeconds !== undefined && maxStalenessSeconds !== undefined && BigInt(staleSeconds) > maxStalenessSeconds

  return (
    <div className="flex flex-col gap-4 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Estado del vault</h2>

      <div className="flex flex-col gap-3">
        <div>
          <p className="text-xs text-text-tertiary">NAV vigente (tBILL)</p>
          {isLoading ? (
            <div className="mt-1 h-6 w-24 animate-pulse rounded bg-surface-3" />
          ) : (
            <p className="text-lg font-semibold text-text-primary">
              {navAnswer !== undefined && navDecimals !== undefined
                ? `$${formatTokenAmount(navAnswer, navDecimals)}`
                : '—'}
            </p>
          )}
          {navUpdatedAt !== undefined && (
            <p className="mt-0.5 text-xs text-text-tertiary">actualizado {formatUnixSeconds(navUpdatedAt)}</p>
          )}
          {isHardStale ? (
            <Badge tone="negative" dot className="mt-1.5">
              Stale — el oráculo lleva más de 24h sin update, las lecturas de NAV van a revertir
            </Badge>
          ) : (
            isNearStale && (
              <Badge tone="warning" dot className="mt-1.5">
                Se acerca al límite de staleness (24h) — pronto necesita un updateNav
              </Badge>
            )
          )}
        </div>

        <div className="h-px bg-border-subtle" />

        <div>
          <p className="text-xs text-text-tertiary">Share price</p>
          {isLoading ? (
            <div className="mt-1 h-6 w-24 animate-pulse rounded bg-surface-3" />
          ) : (
            <p className="text-lg font-semibold text-text-primary">
              {sharePrice !== undefined && assetDecimals !== undefined
                ? `$${formatTokenAmount(sharePrice, assetDecimals, 4)}`
                : '—'}
            </p>
          )}
          <p className="mt-0.5 text-xs text-text-tertiary">convertToAssets(1 share) — sube solo con el NAV</p>
        </div>

        <div className="h-px bg-border-subtle" />

        <div>
          <p className="text-xs text-text-tertiary">Tus shares</p>
          {isLoading ? (
            <div className="mt-1 h-6 w-24 animate-pulse rounded bg-surface-3" />
          ) : (
            <p className="text-lg font-semibold text-text-primary">
              {userShares !== undefined && shareDecimals !== undefined
                ? formatTokenAmount(userShares, shareDecimals, 4)
                : '— (conectá tu wallet)'}
            </p>
          )}
          {userSharesValueAssets !== undefined && assetDecimals !== undefined && (
            <p className="mt-0.5 text-xs text-text-tertiary">
              valor actual: ${formatTokenAmount(userSharesValueAssets, assetDecimals)}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
