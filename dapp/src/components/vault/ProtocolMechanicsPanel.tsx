import type { JSX, ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { Badge } from '../ui/Badge'
import { TxAction } from '../tx/TxAction'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { F3, VAULT_ADDRESS, etherscanAddressUrl } from '../../contracts/addresses'
import { formatTokenAmount, formatUnixSeconds, secondsSince } from '../../lib/format'

/** Constantes del contrato (RwaVaultV2) — fijas, no cambian en runtime. */
const BPS_DENOMINATOR = 10_000n
const SECONDS_PER_YEAR = 31_536_000n // 365 días

function short(hex: string): string {
  return hex.length > 14 ? `${hex.slice(0, 8)}…${hex.slice(-6)}` : hex
}

function Row({ label, children }: { label: string; children: ReactNode }): JSX.Element {
  return (
    <div className="flex items-center justify-between gap-4 py-2">
      <span className="text-xs text-text-tertiary">{label}</span>
      <span className="text-right text-sm text-text-secondary">{children}</span>
    </div>
  )
}

/**
 * Panel de mecánicas del protocolo que el flujo de deposit/redeem no muestra:
 *
 *  1. Management fee (V2) — la tasa, el recipient, cuándo se devengó por última
 *     vez, y una ESTIMACIÓN en vivo de cuánto se devengaría ahora mismo (misma
 *     fórmula lineal del contrato: totalAssets · feeBps · elapsed / (1e4 · 1año)).
 *     El botón `accrueFees()` es permissionless por diseño (keeper-friendly):
 *     cualquiera puede gatillar el devengo, solo mintea dilución al recipient fijo.
 *
 *  2. Keeper de Automation — confirma on-chain (`hasRole`) que el keeper del F3
 *     tiene `OPERATOR_ROLE`, o sea que la liquidación automática está realmente
 *     cableada, no solo deployada. Linkea a la página Cross-chain.
 */
export function ProtocolMechanicsPanel({
  managementFeeBps,
  maxFeeBps,
  feeRecipient,
  lastFeeAccrual,
  totalAssets,
  assetDecimals,
  keeperHasOperatorRole,
  onAccrued,
}: {
  managementFeeBps: bigint | undefined
  maxFeeBps: bigint | undefined
  feeRecipient: string | undefined
  lastFeeAccrual: bigint | undefined
  totalAssets: bigint | undefined
  assetDecimals: number | undefined
  keeperHasOperatorRole: boolean | undefined
  onAccrued: () => void
}): JSX.Element {
  const feePct = managementFeeBps !== undefined ? (Number(managementFeeBps) / 100).toFixed(2) : undefined
  const capPct = maxFeeBps !== undefined ? (Number(maxFeeBps) / 100).toFixed(2) : undefined

  // Estimación en vivo de la fee que se devengaría si se llamara accrueFees() ahora.
  const nowSec = BigInt(Math.floor(Date.now() / 1000))
  const elapsed = lastFeeAccrual !== undefined && nowSec > lastFeeAccrual ? nowSec - lastFeeAccrual : 0n
  const pendingFeeAssets =
    totalAssets !== undefined && managementFeeBps !== undefined
      ? (totalAssets * managementFeeBps * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR)
      : undefined

  return (
    <section className="grid grid-cols-1 gap-6 lg:grid-cols-2">
      {/* Management fee V2 */}
      <div className="rounded-xl border border-border-subtle bg-surface-1 p-6">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Management fee (V2)</h2>
          <Badge tone="neutral">llegó por upgrade UUPS</Badge>
        </div>

        <div className="mt-3 divide-y divide-border-subtle">
          <Row label="Tasa anual">
            {feePct !== undefined ? (
              <span className="font-semibold text-text-primary">
                {feePct}%{capPct !== undefined && <span className="text-text-tertiary"> · cap {capPct}%</span>}
              </span>
            ) : (
              '—'
            )}
          </Row>
          <Row label="Fee recipient">
            {feeRecipient ? (
              <a
                href={etherscanAddressUrl(feeRecipient)}
                target="_blank"
                rel="noreferrer"
                className="font-mono text-xs text-accent-strong hover:underline"
              >
                {short(feeRecipient)} ↗
              </a>
            ) : (
              '—'
            )}
          </Row>
          <Row label="Último devengo">
            {lastFeeAccrual !== undefined ? (
              <span>
                {formatUnixSeconds(lastFeeAccrual)}{' '}
                <span className="text-text-tertiary">
                  (hace {Math.max(0, Math.round(secondsSince(lastFeeAccrual) / 60))}m)
                </span>
              </span>
            ) : (
              '—'
            )}
          </Row>
          <Row label="Se devengaría ahora (est.)">
            {pendingFeeAssets !== undefined && assetDecimals !== undefined ? (
              <span className="font-semibold text-text-primary">
                ~${formatTokenAmount(pendingFeeAssets, assetDecimals, 6)}
              </span>
            ) : (
              '—'
            )}
          </Row>
        </div>

        <p className="mt-3 text-xs leading-relaxed text-text-tertiary">
          La fee se cobra como <strong>dilución de shares</strong> al recipient, no como transferencia. Lineal, no
          compuesta. <code className="text-text-secondary">accrueFees()</code> es permissionless — cualquiera puede
          gatillar el devengo; solo mintea al recipient fijo.
        </p>

        <TxAction
          className="mt-4"
          label="Devengar fee ahora (accrueFees)"
          variant="secondary"
          size="sm"
          disabled={managementFeeBps === 0n}
          disabledReason={managementFeeBps === 0n ? 'La fee está en 0 — no hay nada que devengar.' : undefined}
          buildParams={() => ({ address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'accrueFees' })}
          onConfirmed={onAccrued}
        />
      </div>

      {/* Keeper de Automation */}
      <div className="rounded-xl border border-border-subtle bg-surface-1 p-6">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">
            Liquidación automática
          </h2>
          {keeperHasOperatorRole === true ? (
            <Badge tone="positive" dot>
              keeper con OPERATOR_ROLE
            </Badge>
          ) : keeperHasOperatorRole === false ? (
            <Badge tone="warning" dot>
              keeper sin rol
            </Badge>
          ) : (
            <Badge tone="neutral">verificando…</Badge>
          )}
        </div>

        <div className="mt-3 divide-y divide-border-subtle">
          <Row label="Keeper (Chainlink Automation)">
            <a
              href={etherscanAddressUrl(F3.keeper)}
              target="_blank"
              rel="noreferrer"
              className="font-mono text-xs text-accent-strong hover:underline"
            >
              {short(F3.keeper)} ↗
            </a>
          </Row>
          <Row label="OPERATOR_ROLE en el vault">
            {keeperHasOperatorRole === undefined ? (
              '—'
            ) : keeperHasOperatorRole ? (
              <span className="text-positive">confirmado on-chain ✓</span>
            ) : (
              <span className="text-warning">no otorgado</span>
            )}
          </Row>
        </div>

        <p className="mt-3 text-xs leading-relaxed text-text-tertiary">
          Un keeper log-trigger despierta con cada <code className="text-text-secondary">DepositRequest</code>/
          <code className="text-text-secondary">RedeemRequest</code> y llama{' '}
          <code className="text-text-secondary">fulfill*</code> — reemplaza al operador humano. El{' '}
          <code className="text-text-secondary">hasRole</code> de arriba prueba que está realmente cableado, no solo
          deployado.
        </p>

        <Link
          to="/cross-chain"
          className="mt-4 inline-block text-sm font-medium text-accent-strong hover:underline"
        >
          Ver el flujo cross-chain + evidencia F3 →
        </Link>
      </div>
    </section>
  )
}
