import type { JSX } from 'react'
import { Link } from 'react-router-dom'
import { useVaultData } from '../hooks/useVaultData'
import { StatCard } from '../components/ui/StatCard'
import { buttonClassName } from '../components/ui/Button'
import { Badge } from '../components/ui/Badge'
import { LIVE_UPGRADE_FEE_BPS, LIVE_UPGRADE_TX_HASH, etherscanTxUrl } from '../contracts/addresses'
import { formatTokenAmount, formatUnixSeconds, secondsSince } from '../lib/format'

export function Home(): JSX.Element {
  const {
    isLoading,
    totalAssets,
    assetDecimals,
    sharePrice,
    navAnswer,
    navDecimals,
    navUpdatedAt,
    managementFeeBps,
  } = useVaultData()

  const staleSeconds = navUpdatedAt !== undefined ? secondsSince(navUpdatedAt) : undefined

  return (
    <div className="flex flex-col gap-14">
      {/* Hero */}
      <section className="flex flex-col gap-5">
        <Badge tone="positive" dot className="w-fit">
          Live en Sepolia — proxy sobrevivió el upgrade V1→V2
        </Badge>

        <h1 className="max-w-2xl text-3xl font-semibold tracking-tight text-text-primary sm:text-4xl">
          Un T-bill tokenizado, valuado por oráculo, en un vault ERC-7540.
        </h1>

        <p className="max-w-2xl text-sm leading-relaxed text-text-secondary sm:text-base">
          RWA Yield Protocol tokeniza un activo del mundo real que rinde (tBILL sintético) y lo distribuye vía un
          vault asíncrono ERC-7540 <em>valuado por oráculo</em> (NAV), con roles operativos reales, upgradeable por
          UUPS. El accounting es por NAV, no por balance: nadie transfiere yield — el precio de la share sube solo
          cuando el NAV del oráculo sube.
        </p>

        <div className="flex flex-wrap items-center gap-3 pt-2">
          <Link to="/vault" className={buttonClassName('primary', 'md')}>
            Ir al vault
          </Link>
          <a
            href={etherscanTxUrl(LIVE_UPGRADE_TX_HASH)}
            target="_blank"
            rel="noreferrer"
            className="text-sm font-medium text-accent-strong hover:underline"
          >
            Ver el upgrade UUPS en vivo (tx) ↗
          </a>
        </div>
      </section>

      {/* Stats vivas */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Estado del protocolo</h2>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <StatCard
            label="Total Value Locked"
            isLoading={isLoading}
            value={
              totalAssets !== undefined && assetDecimals !== undefined
                ? `$${formatTokenAmount(totalAssets, assetDecimals)}`
                : '—'
            }
            hint="totalAssets() — holdings de tBILL × NAV + buffer USDC"
          />
          <StatCard
            label="NAV vigente (tBILL)"
            isLoading={isLoading}
            value={navAnswer !== undefined && navDecimals !== undefined ? `$${formatTokenAmount(navAnswer, navDecimals)}` : '—'}
            hint={
              navUpdatedAt !== undefined
                ? `actualizado ${formatUnixSeconds(navUpdatedAt)}${
                    staleSeconds !== undefined ? ` (hace ${Math.round(staleSeconds / 60)}m)` : ''
                  }`
                : 'RwaNavFeed — interfaz AggregatorV3'
            }
          />
          <StatCard
            label="Share price"
            isLoading={isLoading}
            value={
              sharePrice !== undefined && assetDecimals !== undefined
                ? `$${formatTokenAmount(sharePrice, assetDecimals, 4)}`
                : '—'
            }
            hint={
              managementFeeBps !== undefined
                ? `management fee: ${(Number(managementFeeBps) / 100).toFixed(2)}% anual (V2)`
                : 'convertToAssets(1 share)'
            }
          />
        </div>
      </section>

      {/* Pitch del upgrade */}
      <section className="rounded-xl border border-border-subtle bg-surface-1 p-6">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">El upgrade en vivo</h2>
        <p className="mt-3 max-w-2xl text-sm leading-relaxed text-text-secondary">
          El vault se deployó como proxy UUPS y después se upgradeó de V1 a V2 <strong>en producción, sobre Sepolia</strong>
          , agregando un management fee de {LIVE_UPGRADE_FEE_BPS / 100}% anual — sin migrar de dirección, sin perder
          depositantes: las shares y el totalAssets de antes del upgrade sobrevivieron intactos, verificado con cast
          leyendo el storage slot de implementation antes y después.
        </p>
        <a
          href={etherscanTxUrl(LIVE_UPGRADE_TX_HASH)}
          target="_blank"
          rel="noreferrer"
          className="mt-4 inline-block text-sm font-medium text-accent-strong hover:underline"
        >
          {LIVE_UPGRADE_TX_HASH}
        </a>
      </section>
    </div>
  )
}
