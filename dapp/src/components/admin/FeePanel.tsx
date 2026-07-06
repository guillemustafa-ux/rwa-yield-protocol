import type { JSX } from 'react'
import { useReadContracts } from 'wagmi'
import { VAULT_ADDRESS } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { truncateAddress, formatUnixSeconds } from '../../lib/format'
import { TxAction } from '../tx/TxAction'

function ok<T>(r: { status: string; result?: T } | undefined): T | undefined {
  return r && r.status === 'success' ? r.result : undefined
}

/**
 * Fee config (V2, ARCHITECTURE.md §3.4) — solo lectura salvo `accrueFees`,
 * que es PERMISSIONLESS a propósito (RwaVaultV2.sol: "keeper-friendly", no
 * requiere ningún rol): la fórmula no toma ningún input del caller, solo
 * mintea a `feeRecipient` fijo, así que abrirla a cualquiera no agrega
 * superficie de ataque. Por eso este panel se muestra a cualquier wallet
 * con al menos un rol operativo, no solo a un rol específico.
 */
export function FeePanel({
  managementFeeBps,
  onChanged,
}: {
  managementFeeBps: bigint | undefined
  onChanged: () => void
}): JSX.Element {
  const reads = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'feeRecipient' },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'lastFeeAccrual' },
    ],
    query: { refetchInterval: 20_000 },
  })
  const [feeRecipientR, lastFeeAccrualR] = reads.data ?? []
  const feeRecipient = ok(feeRecipientR)
  const lastFeeAccrual = ok(lastFeeAccrualR)

  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Management fee (V2)</h2>

      <dl className="grid grid-cols-1 gap-2 text-xs sm:grid-cols-3">
        <div>
          <dt className="text-text-tertiary">Tasa anual</dt>
          <dd className="text-sm font-medium text-text-primary">
            {managementFeeBps !== undefined ? `${(Number(managementFeeBps) / 100).toFixed(2)}%` : '—'}
          </dd>
        </div>
        <div>
          <dt className="text-text-tertiary">Recipient</dt>
          <dd className="font-mono text-sm text-text-primary">
            {feeRecipient !== undefined ? truncateAddress(feeRecipient) : '—'}
          </dd>
        </div>
        <div>
          <dt className="text-text-tertiary">Último accrual</dt>
          <dd className="text-sm text-text-primary">
            {lastFeeAccrual !== undefined ? formatUnixSeconds(lastFeeAccrual) : '—'}
          </dd>
        </div>
      </dl>

      <TxAction
        label="accrueFees()"
        variant="secondary"
        size="sm"
        helperText="Permissionless — cualquiera puede accionarlo, solo mintea shares al feeRecipient fijo."
        buildParams={() => ({ address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'accrueFees', args: [] })}
        onConfirmed={() => {
          void reads.refetch()
          onChanged()
        }}
      />
    </div>
  )
}
