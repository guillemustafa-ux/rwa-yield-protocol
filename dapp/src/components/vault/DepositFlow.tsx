import { useState, type JSX } from 'react'
import { maxUint256, parseUnits } from 'viem'
import { VAULT_ADDRESS, CONTRACT_ADDRESSES } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { DemoUSDCAbi } from '../../contracts/abis/DemoUSDC'
import { formatTokenAmount } from '../../lib/format'
import { Badge } from '../ui/Badge'
import { TextField } from '../ui/TextField'
import { TxAction } from '../tx/TxAction'

const ASSET_ADDRESS = CONTRACT_ADDRESSES.DemoUSDC

/** Parsea un string de monto a bigint en `decimals` — `undefined` si no es un número válido o es <= 0. */
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
 * Flujo de depósito (ERC-7540, ARCHITECTURE.md §3.3): faucet DemoUSDC →
 * approve → requestDeposit → estado pending → (operador fulfillea) →
 * claimable → claim. Cada paso es su propio `TxAction` (su propio
 * `useTxAction`, lección PULSO).
 */
export function DepositFlow({
  address,
  faucetCap,
  assetDecimals,
  userAssetBalance,
  userAllowance,
  userPendingDeposit,
  userClaimableDepositAssets,
  onChanged,
}: {
  address: `0x${string}` | undefined
  faucetCap: bigint | undefined
  assetDecimals: number | undefined
  userAssetBalance: bigint | undefined
  userAllowance: bigint | undefined
  userPendingDeposit: bigint | undefined
  userClaimableDepositAssets: bigint | undefined
  onChanged: () => void
}): JSX.Element {
  const [amountInput, setAmountInput] = useState('')

  const assetsToDeposit = parseAmount(amountInput, assetDecimals)
  const hasPending = userPendingDeposit !== undefined && userPendingDeposit > 0n
  const hasClaimable = userClaimableDepositAssets !== undefined && userClaimableDepositAssets > 0n

  // Gotcha de PULSO reusado: `userAllowance === undefined` es "todavía no
  // leí", NO "es cero" — solo con `0n` explícito mostramos "sin allowance".
  const allowanceLabel =
    userAllowance === undefined
      ? 'cargando…'
      : userAllowance === 0n
        ? 'sin allowance'
        : userAllowance >= maxUint256 / 2n
          ? 'ilimitado ✓'
          : `$${assetDecimals !== undefined ? formatTokenAmount(userAllowance, assetDecimals) : '…'}`

  const needsApproval =
    assetsToDeposit !== undefined && (userAllowance === undefined || userAllowance < assetsToDeposit)

  return (
    <div className="flex flex-col gap-6 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">1. Depositar</h2>
        <p className="mt-1 text-xs text-text-tertiary">requestDeposit → fulfillDeposit (operador) → claim</p>
      </div>

      {/* Paso 0: faucet */}
      <div className="flex flex-col gap-2 rounded-lg border border-border-subtle/60 bg-surface-2/40 p-3">
        <p className="text-xs text-text-secondary">
          <strong className="text-text-primary">DemoUSDC</strong> es el asset de demo de este protocolo (6
          decimales, sin valor real) — un deploy real apunta el vault al USDC canónico de la chain. El faucet está
          capado{faucetCap !== undefined && assetDecimals !== undefined ? ` a ${formatTokenAmount(faucetCap, assetDecimals, 0)} dUSDC` : ''}{' '}
          por llamada.
        </p>
        <p className="text-xs text-text-tertiary">
          Tu balance: {userAssetBalance !== undefined && assetDecimals !== undefined ? `$${formatTokenAmount(userAssetBalance, assetDecimals)}` : '—'}
        </p>
        <TxAction
          label="Pedir dUSDC del faucet"
          variant="secondary"
          size="sm"
          disabled={!address || faucetCap === undefined}
          disabledReason={!address ? 'Conectá tu wallet.' : undefined}
          buildParams={() => ({
            address: ASSET_ADDRESS,
            abi: DemoUSDCAbi,
            functionName: 'faucet',
            args: [faucetCap ?? 0n],
          })}
          onConfirmed={onChanged}
        />
      </div>

      {/* Paso 1: approve */}
      <div className="flex flex-col gap-2 rounded-lg border border-border-subtle/60 bg-surface-2/40 p-3">
        <p className="text-xs text-text-secondary">
          Aprobación <strong className="text-text-primary">infinita</strong> (mismo patrón que PULSO): autorizás al
          vault a mover tu dUSDC sin tener que re-firmar un approve en cada depósito. Es un asset de demo — sin
          riesgo real.
        </p>
        <p className="text-xs text-text-tertiary">Allowance actual: {allowanceLabel}</p>
        <TxAction
          label="Aprobar USDC (ilimitado)"
          variant="secondary"
          size="sm"
          disabled={!address}
          disabledReason={!address ? 'Conectá tu wallet.' : undefined}
          buildParams={() => ({
            address: ASSET_ADDRESS,
            abi: DemoUSDCAbi,
            functionName: 'approve',
            args: [VAULT_ADDRESS, maxUint256],
          })}
          onConfirmed={onChanged}
        />
      </div>

      {/* Paso 2: requestDeposit */}
      <div className="flex flex-col gap-2">
        <TextField
          label="Monto a depositar"
          placeholder="100.00"
          inputMode="decimal"
          suffix="dUSDC"
          value={amountInput}
          onChange={(e) => setAmountInput(e.target.value)}
          disabled={!address}
        />
        <TxAction
          label="Request deposit"
          disabled={
            !address ||
            assetsToDeposit === undefined ||
            needsApproval ||
            (userAssetBalance !== undefined && assetsToDeposit > userAssetBalance)
          }
          disabledReason={
            !address
              ? 'Conectá tu wallet.'
              : assetsToDeposit === undefined
                ? 'Ingresá un monto válido.'
                : needsApproval
                  ? 'Falta aprobar (o aumentar) el allowance de dUSDC.'
                  : userAssetBalance !== undefined && assetsToDeposit > userAssetBalance
                    ? 'No tenés balance de dUSDC suficiente.'
                    : undefined
          }
          buildParams={() => ({
            address: VAULT_ADDRESS,
            abi: RwaVaultV2Abi,
            functionName: 'requestDeposit',
            args: [assetsToDeposit ?? 0n, address!, address!],
          })}
          onConfirmed={() => {
            setAmountInput('')
            onChanged()
          }}
        />
      </div>

      {/* Estado pending */}
      {hasPending && assetDecimals !== undefined && (
        <Badge tone="warning" dot className="w-fit">
          Pendiente de fulfillment: ${formatTokenAmount(userPendingDeposit!, assetDecimals)}
        </Badge>
      )}

      {/* Claim */}
      {hasClaimable && assetDecimals !== undefined && (
        <div className="flex flex-col gap-2 rounded-lg border border-positive/30 bg-positive/5 p-3">
          <p className="text-sm text-text-primary">
            Claimable: <strong>${formatTokenAmount(userClaimableDepositAssets!, assetDecimals)}</strong> en shares
            listas para reclamar.
          </p>
          <TxAction
            label="Claim"
            variant="primary"
            buildParams={() => ({
              address: VAULT_ADDRESS,
              abi: RwaVaultV2Abi,
              functionName: 'deposit',
              args: [userClaimableDepositAssets!, address!, address!],
            })}
            onConfirmed={onChanged}
          />
        </div>
      )}
    </div>
  )
}
