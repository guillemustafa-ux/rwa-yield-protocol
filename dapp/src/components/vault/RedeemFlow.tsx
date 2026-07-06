import { useState, type JSX } from 'react'
import { parseUnits } from 'viem'
import { VAULT_ADDRESS } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { formatTokenAmount } from '../../lib/format'
import { Badge } from '../ui/Badge'
import { TextField } from '../ui/TextField'
import { TxAction } from '../tx/TxAction'

function parseAmount(raw: string, decimals: number | undefined): bigint | undefined {
  if (decimals === undefined) return undefined
  const trimmed = raw.trim()
  if (trimmed === '' || Number.isNaN(Number(trimmed))) return undefined
  try {
    const value = parseUnits(trimmed, decimals)
    return value > 0n ? value : undefined
  } catch {
    return undefined
  }
}

/**
 * Espejo de `DepositFlow`: requestRedeem → fulfillRedeem (operador) → claim.
 * Sin paso de approve — `requestRedeem` mueve las shares del `owner` con un
 * `_transfer` interno del propio contrato, no con `transferFrom`, así que no
 * hace falta autorizar nada cuando `owner === msg.sender` (self-serve).
 */
export function RedeemFlow({
  address,
  shareDecimals,
  assetDecimals,
  userShares,
  userPendingRedeem,
  userClaimableRedeemShares,
  userClaimableRedeemAssets,
  onChanged,
}: {
  address: `0x${string}` | undefined
  shareDecimals: number | undefined
  assetDecimals: number | undefined
  userShares: bigint | undefined
  userPendingRedeem: bigint | undefined
  userClaimableRedeemShares: bigint | undefined
  userClaimableRedeemAssets: bigint | undefined
  onChanged: () => void
}): JSX.Element {
  const [amountInput, setAmountInput] = useState('')

  const sharesToRedeem = parseAmount(amountInput, shareDecimals)
  const hasPending = userPendingRedeem !== undefined && userPendingRedeem > 0n
  const hasClaimable = userClaimableRedeemShares !== undefined && userClaimableRedeemShares > 0n

  return (
    <div className="flex flex-col gap-6 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">2. Rescatar</h2>
        <p className="mt-1 text-xs text-text-tertiary">requestRedeem → fulfillRedeem (operador) → claim</p>
      </div>

      <p className="text-xs text-text-tertiary">
        Shares disponibles para pedir rescate:{' '}
        {userShares !== undefined && shareDecimals !== undefined ? formatTokenAmount(userShares, shareDecimals, 4) : '—'}
      </p>

      <div className="flex flex-col gap-2">
        <TextField
          label="Shares a rescatar"
          placeholder="10.0000"
          inputMode="decimal"
          suffix="rwaYLD"
          value={amountInput}
          onChange={(e) => setAmountInput(e.target.value)}
          disabled={!address}
        />
        <TxAction
          label="Request redeem"
          disabled={
            !address ||
            sharesToRedeem === undefined ||
            (userShares !== undefined && sharesToRedeem > userShares)
          }
          disabledReason={
            !address
              ? 'Conectá tu wallet.'
              : sharesToRedeem === undefined
                ? 'Ingresá un monto válido.'
                : userShares !== undefined && sharesToRedeem > userShares
                  ? 'No tenés esa cantidad de shares.'
                  : undefined
          }
          buildParams={() => ({
            address: VAULT_ADDRESS,
            abi: RwaVaultV2Abi,
            functionName: 'requestRedeem',
            args: [sharesToRedeem ?? 0n, address!, address!],
          })}
          onConfirmed={() => {
            setAmountInput('')
            onChanged()
          }}
        />
      </div>

      {hasPending && shareDecimals !== undefined && (
        <Badge tone="warning" dot className="w-fit">
          Pendiente de fulfillment: {formatTokenAmount(userPendingRedeem!, shareDecimals, 4)} shares
        </Badge>
      )}

      {hasClaimable && assetDecimals !== undefined && (
        <div className="flex flex-col gap-2 rounded-lg border border-positive/30 bg-positive/5 p-3">
          <p className="text-sm text-text-primary">
            Claimable:{' '}
            <strong>
              ${userClaimableRedeemAssets !== undefined ? formatTokenAmount(userClaimableRedeemAssets, assetDecimals) : '—'}
            </strong>{' '}
            listos para retirar.
          </p>
          <TxAction
            label="Claim"
            variant="primary"
            buildParams={() => ({
              address: VAULT_ADDRESS,
              abi: RwaVaultV2Abi,
              functionName: 'redeem',
              args: [userClaimableRedeemShares!, address!, address!],
            })}
            onConfirmed={onChanged}
          />
        </div>
      )}
    </div>
  )
}
