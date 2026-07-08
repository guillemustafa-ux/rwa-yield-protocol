import { useMemo } from 'react'
import type { JSX } from 'react'
import { formatUnits } from 'viem'
import { Badge } from '../components/ui/Badge'
import { StatCard } from '../components/ui/StatCard'
import { NavChart, type NavPoint } from '../components/analytics/NavChart'
import { useActivity } from '../hooks/useActivity'
import { useVaultData } from '../hooks/useVaultData'
import { formatTokenAmount } from '../lib/format'

// Fallbacks mientras las lecturas on-chain no llegaron (dUSDC=6, shares=18, NAV=8).
const FALLBACK_ASSET_DECIMALS = 6
const FALLBACK_SHARE_DECIMALS = 18
const FALLBACK_NAV_DECIMALS = 8

/** `$1,234.56` o `—` si el valor todavía no llegó (undefined). */
function money(value: bigint | undefined, decimals: number, displayDecimals = 2): string {
  return value === undefined ? '—' : `$${formatTokenAmount(value, decimals, displayDecimals)}`
}

function sumBigInt(values: string[]): bigint {
  return values.reduce((acc, v) => acc + BigInt(v), 0n)
}

export function Analytics(): JSX.Element {
  const vault = useVaultData()
  const { data, isLoading, isError, error } = useActivity(100)

  const assetDecimals = vault.assetDecimals ?? FALLBACK_ASSET_DECIMALS
  const shareDecimals = vault.shareDecimals ?? FALLBACK_SHARE_DECIMALS
  const navDecimals = vault.navDecimals ?? FALLBACK_NAV_DECIMALS

  // Puntos del gráfico de NAV: el subgraph los devuelve desc, los damos vuelta a cronológico.
  const navPoints: NavPoint[] = useMemo(() => {
    if (!data) return []
    return [...data.navUpdates]
      .reverse()
      .map((u) => ({ t: Number(u.blockTimestamp), nav: Number(formatUnits(BigInt(u.nav), navDecimals)) }))
  }, [data, navDecimals])

  // Agregados del historial indexado (hasta 100 eventos por colección).
  const flows = useMemo(() => {
    if (!data) return undefined
    const participants = new Set<string>()
    for (const r of data.depositRequests) participants.add(r.owner.toLowerCase())
    for (const r of data.redeemRequests) participants.add(r.owner.toLowerCase())
    return {
      totalDeposited: sumBigInt(data.depositFulfilleds.map((r) => r.assets)),
      totalRedeemed: sumBigInt(data.redeemFulfilleds.map((r) => r.assets)),
      depositRequestCount: data.depositRequests.length,
      depositFulfilledCount: data.depositFulfilleds.length,
      redeemRequestCount: data.redeemRequests.length,
      redeemFulfilledCount: data.redeemFulfilleds.length,
      navUpdateCount: data.navUpdates.length,
      participants: participants.size,
    }
  }, [data])

  const feePct =
    vault.managementFeeBps === undefined ? '—' : `${(Number(vault.managementFeeBps) / 100).toFixed(2)}%`

  return (
    <div className="flex flex-col gap-14">
      {/* Hero */}
      <section className="flex flex-col gap-5">
        <Badge tone="neutral" dot className="w-fit">
          Métricas del protocolo · on-chain + subgraph
        </Badge>

        <h1 className="max-w-2xl text-3xl font-semibold tracking-tight text-text-primary sm:text-4xl">
          Analytics del vault, en tiempo real.
        </h1>

        <p className="max-w-2xl text-sm leading-relaxed text-text-secondary sm:text-base">
          El estado vivo del protocolo leído directo de la chain (TVL, share price, fee, NAV vigente) combinado con el
          historial que indexa el subgraph (evolución del NAV y flujos agregados). Dos fuentes, ninguna intermediada
          por un backend propio.
        </p>
      </section>

      {/* Snapshot on-chain */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Estado on-chain</h2>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <StatCard
            label="TVL"
            value={money(vault.totalAssets, assetDecimals)}
            hint="total assets bajo custodia del vault"
            isLoading={vault.isLoading && vault.totalAssets === undefined}
          />
          <StatCard
            label="NAV vigente"
            value={money(vault.navAnswer, navDecimals)}
            hint="última ronda del oráculo RwaNavFeed"
            isLoading={vault.isLoading && vault.navAnswer === undefined}
          />
          <StatCard
            label="Share price"
            value={money(vault.sharePrice, assetDecimals, 4)}
            hint="convertToAssets(1 share)"
            isLoading={vault.isLoading && vault.sharePrice === undefined}
          />
          <StatCard
            label="Shares en circulación"
            value={vault.totalSupply === undefined ? '—' : formatTokenAmount(vault.totalSupply, shareDecimals, 4)}
            hint="totalSupply del ERC-4626"
            isLoading={vault.isLoading && vault.totalSupply === undefined}
          />
          <StatCard
            label="Management fee"
            value={feePct}
            hint="anual, devengada en shares (V2)"
            isLoading={vault.isLoading && vault.managementFeeBps === undefined}
          />
          <StatCard
            label="Depósitos pendientes"
            value={money(vault.totalPendingDepositAssets, assetDecimals)}
            hint="requests aún sin liquidar"
            isLoading={vault.isLoading && vault.totalPendingDepositAssets === undefined}
          />
        </div>
      </section>

      {/* Gráfico de NAV */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Historial de NAV</h2>
        <div className="rounded-xl border border-border-subtle bg-surface-1 p-5">
          {isError ? (
            <div>
              <p className="text-sm text-negative">No se pudo consultar el subgraph.</p>
              <p className="mt-1 text-xs text-text-tertiary">
                {error instanceof Error ? error.message : String(error)}
              </p>
            </div>
          ) : isLoading ? (
            <div className="h-56 w-full animate-pulse rounded bg-surface-3" />
          ) : (
            <NavChart points={navPoints} />
          )}
        </div>
      </section>

      {/* Flujos agregados */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Flujos indexados</h2>
        {isError ? (
          <p className="text-sm text-text-tertiary">Flujos no disponibles (subgraph inaccesible).</p>
        ) : (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <StatCard
              label="Total depositado"
              value={money(flows?.totalDeposited, assetDecimals)}
              hint="depósitos liquidados"
              isLoading={isLoading}
            />
            <StatCard
              label="Total redimido"
              value={money(flows?.totalRedeemed, assetDecimals)}
              hint="redenciones liquidadas"
              isLoading={isLoading}
            />
            <StatCard
              label="Participantes"
              value={flows?.participants ?? '—'}
              hint="direcciones únicas con actividad"
              isLoading={isLoading}
            />
            <StatCard
              label="Publicaciones de NAV"
              value={flows?.navUpdateCount ?? '—'}
              hint="rondas del oráculo indexadas"
              isLoading={isLoading}
            />
            <StatCard
              label="Solicitudes de depósito"
              value={flows?.depositRequestCount ?? '—'}
              hint={`${flows?.depositFulfilledCount ?? 0} liquidadas`}
              isLoading={isLoading}
            />
            <StatCard
              label="Solicitudes de redención"
              value={flows?.redeemRequestCount ?? '—'}
              hint={`${flows?.redeemFulfilledCount ?? 0} liquidadas`}
              isLoading={isLoading}
            />
          </div>
        )}
        <p className="text-xs text-text-tertiary">
          Los flujos agregan hasta los últimos 100 eventos indexados por colección.
        </p>
      </section>
    </div>
  )
}
