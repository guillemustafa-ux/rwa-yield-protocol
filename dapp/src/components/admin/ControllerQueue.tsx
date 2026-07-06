import { useState, type JSX } from 'react'
import { formatUnits, isAddress, parseUnits, zeroAddress } from 'viem'
import { useReadContracts } from 'wagmi'
import { VAULT_ADDRESS } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { formatTokenAmount } from '../../lib/format'
import { TextField } from '../ui/TextField'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'
import { TxAction } from '../tx/TxAction'

function ok<T>(r: { status: string; result?: T } | undefined): T | undefined {
  return r && r.status === 'success' ? r.result : undefined
}

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
 * `OPERATOR_ROLE`: cola de pending por controller (lookup por address — no
 * hay indexer wireado en esta dApp, D4/subgraph es tema aparte) +
 * fulfillDeposit/fulfillRedeem, con el aviso del cap `InsufficientLiquidity`
 * (ARCHITECTURE.md §4, hallazgo (c) de invariantes D3) y el buffer libre de
 * USDC visible ANTES de firmar.
 */
export function ControllerQueue({
  assetDecimals,
  shareDecimals,
  freeAssetBuffer,
  onChanged,
}: {
  assetDecimals: number | undefined
  shareDecimals: number | undefined
  freeAssetBuffer: bigint | undefined
  onChanged: () => void
}): JSX.Element {
  const [controllerInput, setControllerInput] = useState('')
  const controller = isAddress(controllerInput) ? (controllerInput as `0x${string}`) : undefined

  const queueReads = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'pendingDeposit', args: [controller ?? zeroAddress] },
      { address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'pendingRedeem', args: [controller ?? zeroAddress] },
    ],
    query: { enabled: controller !== undefined, refetchInterval: 10_000 },
  })
  const [pendingDepositR, pendingRedeemR] = queueReads.data ?? []
  const pendingDeposit = ok(pendingDepositR)
  const pendingRedeem = ok(pendingRedeemR)

  const [depositAmountInput, setDepositAmountInput] = useState('')
  const [redeemAmountInput, setRedeemAmountInput] = useState('')

  const depositAssets = parseAmount(depositAmountInput, assetDecimals)
  const redeemShares = parseAmount(redeemAmountInput, shareDecimals)

  // Estimación de cuántos assets implica fulfillear `redeemShares` AHORA (NAV
  // vigente en el momento de la lectura — puede variar levemente para cuando
  // se mine la tx, pero alcanza como aviso preventivo antes de firmar).
  const estimateReads = useReadContracts({
    contracts: [{ address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'convertToAssets', args: [redeemShares ?? 0n] }],
    query: { enabled: redeemShares !== undefined },
  })
  const [estimatedAssetsR] = estimateReads.data ?? []
  const estimatedAssets = ok(estimatedAssetsR)

  const exceedsBuffer =
    estimatedAssets !== undefined && freeAssetBuffer !== undefined && estimatedAssets > freeAssetBuffer

  return (
    <div className="flex flex-col gap-5 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">
          Cola de pending — OPERATOR_ROLE
        </h2>
        <p className="mt-1 text-xs text-text-tertiary">
          Buscá un controller por address y fulfilleá su depósito/redeem pendiente.
        </p>
      </div>

      <TextField
        label="Controller (address)"
        placeholder="0x…"
        value={controllerInput}
        onChange={(e) => setControllerInput(e.target.value)}
        error={controllerInput.length > 0 && controller === undefined ? 'Address inválida.' : undefined}
      />

      {controller && (
        <div className="flex flex-col gap-5">
          {/* Fulfill deposit */}
          <div className="flex flex-col gap-2 rounded-lg border border-border-subtle/60 bg-surface-2/40 p-3">
            <p className="text-xs text-text-secondary">
              Pending deposit:{' '}
              <strong className="text-text-primary">
                {pendingDeposit !== undefined && assetDecimals !== undefined
                  ? `$${formatTokenAmount(pendingDeposit, assetDecimals)}`
                  : '—'}
              </strong>
            </p>
            <div className="flex flex-wrap items-end gap-2">
              <TextField
                label="Assets a fulfillear"
                placeholder="0.00"
                inputMode="decimal"
                suffix="dUSDC"
                value={depositAmountInput}
                onChange={(e) => setDepositAmountInput(e.target.value)}
                className="min-w-[200px] flex-1"
              />
              {pendingDeposit !== undefined && pendingDeposit > 0n && assetDecimals !== undefined && (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => setDepositAmountInput(formatUnits(pendingDeposit, assetDecimals))}
                >
                  Usar todo
                </Button>
              )}
            </div>
            <TxAction
              label="fulfillDeposit"
              disabled={
                depositAssets === undefined || (pendingDeposit !== undefined && depositAssets > pendingDeposit)
              }
              disabledReason={
                depositAssets === undefined
                  ? 'Ingresá un monto válido.'
                  : pendingDeposit !== undefined && depositAssets > pendingDeposit
                    ? 'Supera el pending deposit de este controller (ExceedsPending).'
                    : undefined
              }
              buildParams={() => ({
                address: VAULT_ADDRESS,
                abi: RwaVaultV2Abi,
                functionName: 'fulfillDeposit',
                args: [controller, depositAssets ?? 0n],
              })}
              onConfirmed={() => {
                setDepositAmountInput('')
                void queueReads.refetch()
                onChanged()
              }}
            />
          </div>

          {/* Fulfill redeem */}
          <div className="flex flex-col gap-2 rounded-lg border border-border-subtle/60 bg-surface-2/40 p-3">
            <p className="text-xs text-text-secondary">
              Pending redeem:{' '}
              <strong className="text-text-primary">
                {pendingRedeem !== undefined && shareDecimals !== undefined
                  ? `${formatTokenAmount(pendingRedeem, shareDecimals, 4)} shares`
                  : '—'}
              </strong>
            </p>
            <p className="text-xs text-text-tertiary">
              Buffer libre de USDC en el vault:{' '}
              {freeAssetBuffer !== undefined && assetDecimals !== undefined
                ? `$${formatTokenAmount(freeAssetBuffer, assetDecimals)}`
                : '—'}{' '}
              — todo claim de redeem tiene que quedar 100% respaldado por este buffer.
            </p>
            <div className="flex flex-wrap items-end gap-2">
              <TextField
                label="Shares a fulfillear"
                placeholder="0.0000"
                inputMode="decimal"
                suffix="rwaYLD"
                value={redeemAmountInput}
                onChange={(e) => setRedeemAmountInput(e.target.value)}
                className="min-w-[200px] flex-1"
              />
              {pendingRedeem !== undefined && pendingRedeem > 0n && shareDecimals !== undefined && (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => setRedeemAmountInput(formatUnits(pendingRedeem, shareDecimals))}
                >
                  Usar todo
                </Button>
              )}
            </div>
            {estimatedAssets !== undefined && assetDecimals !== undefined && (
              <p className="text-xs text-text-tertiary">
                Estimado a comprometer: ${formatTokenAmount(estimatedAssets, assetDecimals)}
              </p>
            )}
            {exceedsBuffer && (
              <Badge tone="negative" dot className="w-fit">
                Supera el buffer libre — va a revertir con InsufficientLiquidity. Hacé divestFromTBill primero.
              </Badge>
            )}
            <TxAction
              label="fulfillRedeem"
              disabled={
                redeemShares === undefined ||
                (pendingRedeem !== undefined && redeemShares > pendingRedeem) ||
                exceedsBuffer
              }
              disabledReason={
                redeemShares === undefined
                  ? 'Ingresá un monto válido.'
                  : pendingRedeem !== undefined && redeemShares > pendingRedeem
                    ? 'Supera el pending redeem de este controller (ExceedsPending).'
                    : exceedsBuffer
                      ? 'Supera el buffer libre de USDC (InsufficientLiquidity).'
                      : undefined
              }
              buildParams={() => ({
                address: VAULT_ADDRESS,
                abi: RwaVaultV2Abi,
                functionName: 'fulfillRedeem',
                args: [controller, redeemShares ?? 0n],
              })}
              onConfirmed={() => {
                setRedeemAmountInput('')
                void queueReads.refetch()
                onChanged()
              }}
            />
          </div>
        </div>
      )}
    </div>
  )
}
