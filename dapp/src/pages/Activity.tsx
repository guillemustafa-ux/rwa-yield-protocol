import type { JSX, ReactNode } from 'react'
import { Badge } from '../components/ui/Badge'
import { useActivity } from '../hooks/useActivity'
import { useVaultData } from '../hooks/useVaultData'
import { etherscanAddressUrl, etherscanTxUrl } from '../contracts/addresses'
import { formatTokenAmount, formatUnixSeconds, truncateAddress } from '../lib/format'

// Decimales de fallback mientras las lecturas on-chain (useVaultData) no llegaron.
// Son los valores fijos de los contratos demo (dUSDC=6, shares ERC-4626=18,
// RwaNavFeed=8); el hook los confirma dinámicamente apenas resuelve.
const FALLBACK_ASSET_DECIMALS = 6
const FALLBACK_SHARE_DECIMALS = 18
const FALLBACK_NAV_DECIMALS = 8

/** Link externo monoespaciado a Etherscan (Sepolia), con el hash acortado. */
function TxLink({ hash }: { hash: string }): JSX.Element {
  return (
    <a
      href={etherscanTxUrl(hash)}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-xs text-accent-strong hover:underline"
    >
      {truncateAddress(hash, 5)} ↗
    </a>
  )
}

/** Link externo a la address (wallet/contrato) en Etherscan Sepolia. */
function AddressLink({ address }: { address: string }): JSX.Element {
  return (
    <a
      href={etherscanAddressUrl(address)}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-xs text-text-secondary hover:text-text-primary hover:underline"
    >
      {truncateAddress(address)} ↗
    </a>
  )
}

/** Card contenedora de una sección de la timeline, con título y contador. */
function Section({
  title,
  count,
  description,
  children,
}: {
  title: string
  count: number
  description: string
  children: ReactNode
}): JSX.Element {
  return (
    <section className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">{title}</h2>
          <Badge tone="neutral">{count}</Badge>
        </div>
        <p className="text-xs text-text-tertiary">{description}</p>
      </div>
      <div className="overflow-x-auto rounded-xl border border-border-subtle bg-surface-1">{children}</div>
    </section>
  )
}

/** Fila de encabezado de tabla, con columnas dadas. */
function TableHead({ cols }: { cols: string[] }): JSX.Element {
  return (
    <thead>
      <tr className="border-b border-border-subtle text-left text-xs text-text-tertiary">
        {cols.map((c) => (
          <th key={c} className="px-4 py-3 font-medium">
            {c}
          </th>
        ))}
      </tr>
    </thead>
  )
}

const cellClass = 'px-4 py-3 align-middle text-sm text-text-secondary'

export function Activity(): JSX.Element {
  const { data, isLoading, isError, error } = useActivity(25)
  const vault = useVaultData()

  const assetDecimals = vault.assetDecimals ?? FALLBACK_ASSET_DECIMALS
  const shareDecimals = vault.shareDecimals ?? FALLBACK_SHARE_DECIMALS
  const navDecimals = vault.navDecimals ?? FALLBACK_NAV_DECIMALS

  const totalEvents =
    (data?.depositRequests.length ?? 0) +
    (data?.redeemRequests.length ?? 0) +
    (data?.depositFulfilleds.length ?? 0) +
    (data?.redeemFulfilleds.length ?? 0) +
    (data?.navUpdates.length ?? 0)

  return (
    <div className="flex flex-col gap-14">
      {/* Hero */}
      <section className="flex flex-col gap-5">
        <Badge tone="positive" dot className="w-fit">
          Indexado en vivo por The Graph
        </Badge>

        <h1 className="max-w-2xl text-3xl font-semibold tracking-tight text-text-primary sm:text-4xl">
          Actividad on-chain del vault, leída del subgraph.
        </h1>

        <p className="max-w-2xl text-sm leading-relaxed text-text-secondary sm:text-base">
          Todo el ciclo de vida ERC-7540 del vault —solicitudes de depósito y redención, sus liquidaciones por el{' '}
          <code className="text-text-primary">OPERATOR_ROLE</code>, y cada publicación de NAV del oráculo— indexado por
          un subgraph en The Graph Studio y consultado directo desde acá vía GraphQL. Sin backend propio: los datos
          salen del índice descentralizado, no de un servidor central.
        </p>
      </section>

      {/* Estados */}
      {isLoading && (
        <p className="text-sm text-text-tertiary">Cargando actividad desde el subgraph…</p>
      )}

      {isError && (
        <div className="rounded-xl border border-negative/30 bg-negative/10 p-4">
          <p className="text-sm text-negative">No se pudo consultar el subgraph.</p>
          <p className="mt-1 text-xs text-text-tertiary">{error instanceof Error ? error.message : String(error)}</p>
        </div>
      )}

      {!isLoading && !isError && totalEvents === 0 && (
        <p className="text-sm text-text-tertiary">
          Todavía no hay actividad indexada. En cuanto se registre un depósito, redención o actualización de NAV en el
          vault, aparecerá acá.
        </p>
      )}

      {!isLoading && !isError && data && totalEvents > 0 && (
        <div className="flex flex-col gap-12">
          {/* Solicitudes de depósito */}
          <Section
            title="Solicitudes de depósito"
            count={data.depositRequests.length}
            description="requestDeposit — el asset se movió a custodia del vault y queda pendiente hasta que el operador liquide."
          >
            <table className="w-full min-w-[640px]">
              <TableHead cols={['Owner', 'Assets (dUSDC)', 'Fecha', 'Tx']} />
              <tbody>
                {data.depositRequests.map((r) => (
                  <tr key={r.id} className="border-b border-border-subtle/60 last:border-0">
                    <td className={cellClass}>
                      <AddressLink address={r.owner} />
                    </td>
                    <td className={cellClass}>${formatTokenAmount(BigInt(r.assets), assetDecimals)}</td>
                    <td className={cellClass}>{formatUnixSeconds(BigInt(r.blockTimestamp))}</td>
                    <td className={cellClass}>
                      <TxLink hash={r.transactionHash} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>

          {/* Depósitos liquidados */}
          <Section
            title="Depósitos liquidados"
            count={data.depositFulfilleds.length}
            description="fulfillDeposit — el operador fijó las shares al NAV vigente; pasan a claimable para el controller."
          >
            <table className="w-full min-w-[640px]">
              <TableHead cols={['Controller', 'Assets (dUSDC)', 'Shares', 'Fecha', 'Tx']} />
              <tbody>
                {data.depositFulfilleds.map((r) => (
                  <tr key={r.id} className="border-b border-border-subtle/60 last:border-0">
                    <td className={cellClass}>
                      <AddressLink address={r.controller} />
                    </td>
                    <td className={cellClass}>${formatTokenAmount(BigInt(r.assets), assetDecimals)}</td>
                    <td className={cellClass}>{formatTokenAmount(BigInt(r.shares), shareDecimals, 4)}</td>
                    <td className={cellClass}>{formatUnixSeconds(BigInt(r.blockTimestamp))}</td>
                    <td className={cellClass}>
                      <TxLink hash={r.transactionHash} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>

          {/* Solicitudes de redención */}
          <Section
            title="Solicitudes de redención"
            count={data.redeemRequests.length}
            description="requestRedeem — las shares pasan a custodia del vault y quedan pendientes hasta la liquidación."
          >
            <table className="w-full min-w-[640px]">
              <TableHead cols={['Owner', 'Shares', 'Fecha', 'Tx']} />
              <tbody>
                {data.redeemRequests.map((r) => (
                  <tr key={r.id} className="border-b border-border-subtle/60 last:border-0">
                    <td className={cellClass}>
                      <AddressLink address={r.owner} />
                    </td>
                    <td className={cellClass}>{formatTokenAmount(BigInt(r.shares), shareDecimals, 4)}</td>
                    <td className={cellClass}>{formatUnixSeconds(BigInt(r.blockTimestamp))}</td>
                    <td className={cellClass}>
                      <TxLink hash={r.transactionHash} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>

          {/* Redenciones liquidadas */}
          <Section
            title="Redenciones liquidadas"
            count={data.redeemFulfilleds.length}
            description="fulfillRedeem — el operador quemó las shares custodiadas y earmarkeó el asset al NAV vigente."
          >
            <table className="w-full min-w-[640px]">
              <TableHead cols={['Controller', 'Shares', 'Assets (dUSDC)', 'Fecha', 'Tx']} />
              <tbody>
                {data.redeemFulfilleds.map((r) => (
                  <tr key={r.id} className="border-b border-border-subtle/60 last:border-0">
                    <td className={cellClass}>
                      <AddressLink address={r.controller} />
                    </td>
                    <td className={cellClass}>{formatTokenAmount(BigInt(r.shares), shareDecimals, 4)}</td>
                    <td className={cellClass}>${formatTokenAmount(BigInt(r.assets), assetDecimals)}</td>
                    <td className={cellClass}>{formatUnixSeconds(BigInt(r.blockTimestamp))}</td>
                    <td className={cellClass}>
                      <TxLink hash={r.transactionHash} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>

          {/* Historial de NAV */}
          <Section
            title="Historial de NAV"
            count={data.navUpdates.length}
            description="NavUpdated — cada ronda publicada por el NAV_UPDATER_ROLE, ya pasada la banda de desvío (±5%) y el rate-limit del feed."
          >
            <table className="w-full min-w-[560px]">
              <TableHead cols={['Ronda', 'NAV (USD)', 'Fecha', 'Tx']} />
              <tbody>
                {data.navUpdates.map((r) => (
                  <tr key={r.id} className="border-b border-border-subtle/60 last:border-0">
                    <td className={cellClass}>#{r.roundId}</td>
                    <td className={cellClass}>${formatTokenAmount(BigInt(r.nav), navDecimals)}</td>
                    <td className={cellClass}>{formatUnixSeconds(BigInt(r.updatedAt))}</td>
                    <td className={cellClass}>
                      <TxLink hash={r.transactionHash} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Section>
        </div>
      )}
    </div>
  )
}
