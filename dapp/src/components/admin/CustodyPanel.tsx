import { useState, type JSX } from 'react'
import { maxUint256, parseUnits } from 'viem'
import { useAccount, useReadContracts } from 'wagmi'
import { CONTRACT_ADDRESSES, VAULT_ADDRESS } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { TBillTokenAbi } from '../../contracts/abis/TBillToken'
import { DemoUSDCAbi } from '../../contracts/abis/DemoUSDC'
import { formatTokenAmount } from '../../lib/format'
import { TextField } from '../ui/TextField'
import { TxAction } from '../tx/TxAction'

const ASSET_ADDRESS = CONTRACT_ADDRESSES.DemoUSDC
const TBILL_ADDRESS = CONTRACT_ADDRESSES.TBillToken

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
 * Flujo de custodio demo (ARCHITECTURE.md §3.3 punto 4 del NatSpec de
 * `RwaVault.sol`): el `ASSET_MANAGER_ROLE` del vault mueve el leg de USDC
 * (`investInTBill`/`divestFromTBill`) y, POR SEPARADO, el `ASSET_MANAGER_ROLE`
 * de `TBillToken` mintea/quema las unidades sintéticas — dos roles, dos
 * contratos, aunque el mismo wallet suele tener ambos en la demo.
 *
 * `mint`/`burn` están fijados a `to`/`from = VAULT_ADDRESS` a propósito (sin
 * input libre): mintear a cualquier otra dirección no las contaría en
 * `totalAssets()` (que lee `tBillToken.balanceOf(vault)`) — sería plata
 * fantasma que nunca respalda a los depositantes.
 */
export function CustodyPanel({
  isVaultAssetManager,
  isTBillAssetManager,
  assetDecimals,
  freeAssetBuffer,
  onChanged,
}: {
  isVaultAssetManager: boolean
  isTBillAssetManager: boolean
  assetDecimals: number | undefined
  freeAssetBuffer: bigint | undefined
  onChanged: () => void
}): JSX.Element | null {
  const { address } = useAccount()

  const reads = useReadContracts({
    contracts: [
      { address: TBILL_ADDRESS, abi: TBillTokenAbi, functionName: 'balanceOf', args: [VAULT_ADDRESS] },
      { address: TBILL_ADDRESS, abi: TBillTokenAbi, functionName: 'decimals' },
      { address: ASSET_ADDRESS, abi: DemoUSDCAbi, functionName: 'balanceOf', args: [address!] },
      { address: ASSET_ADDRESS, abi: DemoUSDCAbi, functionName: 'allowance', args: [address!, VAULT_ADDRESS] },
    ],
    query: {
      enabled: address !== undefined && (isVaultAssetManager || isTBillAssetManager),
      refetchInterval: 15_000,
    },
  })
  const [vaultTBillBalanceR, tBillDecimalsR, ownAssetBalanceR, ownAllowanceR] = reads.data ?? []
  const vaultTBillBalance = ok(vaultTBillBalanceR)
  const tBillDecimals = ok(tBillDecimalsR)
  const ownAssetBalance = ok(ownAssetBalanceR)
  const ownAllowance = ok(ownAllowanceR)

  const [investInput, setInvestInput] = useState('')
  const [divestInput, setDivestInput] = useState('')
  const [mintInput, setMintInput] = useState('')
  const [burnInput, setBurnInput] = useState('')

  const investAmount = parseAmount(investInput, assetDecimals)
  const divestAmount = parseAmount(divestInput, assetDecimals)
  const mintAmount = parseAmount(mintInput, tBillDecimals)
  const burnAmount = parseAmount(burnInput, tBillDecimals)

  const needsDivestApproval =
    divestAmount !== undefined && (ownAllowance === undefined || ownAllowance < divestAmount)

  if (!isVaultAssetManager && !isTBillAssetManager) return null

  return (
    <div className="flex flex-col gap-5 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Custodio / tBILL</h2>
        <p className="mt-1 text-xs text-text-tertiary">
          Flujo demo: 1) investInTBill saca USDC del vault a tu wallet. 2) mint acredita tBILL sintético EN EL
          VAULT (no en tu wallet) representando la compra off-chain. Para vender: burn quita tBILL del vault, luego
          divestFromTBill devuelve el USDC (necesita approve primero).
        </p>
        <p className="mt-1 text-xs text-text-tertiary">
          Holdings de tBILL en el vault:{' '}
          {vaultTBillBalance !== undefined && tBillDecimals !== undefined
            ? formatTokenAmount(vaultTBillBalance, tBillDecimals, 4)
            : '—'}
        </p>
      </div>

      {isVaultAssetManager && (
        <div className="flex flex-col gap-4 rounded-lg border border-border-subtle/60 bg-surface-2/40 p-3">
          <p className="text-xs font-medium text-text-secondary">ASSET_MANAGER_ROLE (Vault)</p>

          <div className="flex flex-col gap-2">
            <p className="text-xs text-text-tertiary">
              Buffer libre disponible para invertir:{' '}
              {freeAssetBuffer !== undefined && assetDecimals !== undefined
                ? `$${formatTokenAmount(freeAssetBuffer, assetDecimals)}`
                : '—'}
            </p>
            <TextField
              label="investInTBill — monto"
              placeholder="0.00"
              inputMode="decimal"
              suffix="dUSDC"
              value={investInput}
              onChange={(e) => setInvestInput(e.target.value)}
            />
            <TxAction
              label="investInTBill"
              disabled={
                investAmount === undefined || (freeAssetBuffer !== undefined && investAmount > freeAssetBuffer)
              }
              disabledReason={
                investAmount === undefined
                  ? 'Ingresá un monto válido.'
                  : freeAssetBuffer !== undefined && investAmount > freeAssetBuffer
                    ? 'Supera el buffer libre (InsufficientFreeBuffer).'
                    : undefined
              }
              buildParams={() => ({
                address: VAULT_ADDRESS,
                abi: RwaVaultV2Abi,
                functionName: 'investInTBill',
                args: [investAmount ?? 0n],
              })}
              onConfirmed={() => {
                setInvestInput('')
                void reads.refetch()
                onChanged()
              }}
            />
          </div>

          <div className="h-px bg-border-subtle" />

          <div className="flex flex-col gap-2">
            <p className="text-xs text-text-tertiary">
              Tu dUSDC: {ownAssetBalance !== undefined && assetDecimals !== undefined ? `$${formatTokenAmount(ownAssetBalance, assetDecimals)}` : '—'}
              {' · '}allowance al vault:{' '}
              {ownAllowance === undefined ? 'cargando…' : ownAllowance === 0n ? 'sin allowance' : ownAllowance >= maxUint256 / 2n ? 'ilimitado ✓' : `$${assetDecimals !== undefined ? formatTokenAmount(ownAllowance, assetDecimals) : '…'}`}
            </p>
            <TxAction
              label="Aprobar dUSDC al vault (ilimitado)"
              variant="secondary"
              size="sm"
              buildParams={() => ({
                address: ASSET_ADDRESS,
                abi: DemoUSDCAbi,
                functionName: 'approve',
                args: [VAULT_ADDRESS, maxUint256],
              })}
              onConfirmed={() => void reads.refetch()}
            />
            <TextField
              label="divestFromTBill — monto"
              placeholder="0.00"
              inputMode="decimal"
              suffix="dUSDC"
              value={divestInput}
              onChange={(e) => setDivestInput(e.target.value)}
            />
            <TxAction
              label="divestFromTBill"
              disabled={
                divestAmount === undefined ||
                needsDivestApproval ||
                (ownAssetBalance !== undefined && divestAmount > ownAssetBalance)
              }
              disabledReason={
                divestAmount === undefined
                  ? 'Ingresá un monto válido.'
                  : needsDivestApproval
                    ? 'Falta aprobar dUSDC al vault desde tu propia wallet.'
                    : ownAssetBalance !== undefined && divestAmount > ownAssetBalance
                      ? 'No tenés ese dUSDC en tu wallet (conseguilo del faucet en /vault).'
                      : undefined
              }
              buildParams={() => ({
                address: VAULT_ADDRESS,
                abi: RwaVaultV2Abi,
                functionName: 'divestFromTBill',
                args: [divestAmount ?? 0n],
              })}
              onConfirmed={() => {
                setDivestInput('')
                void reads.refetch()
                onChanged()
              }}
            />
          </div>
        </div>
      )}

      {isTBillAssetManager && (
        <div className="flex flex-col gap-4 rounded-lg border border-border-subtle/60 bg-surface-2/40 p-3">
          <p className="text-xs font-medium text-text-secondary">ASSET_MANAGER_ROLE (TBillToken)</p>

          <div className="flex flex-col gap-2">
            <TextField
              label="mint tBILL al vault — monto"
              placeholder="0.0000"
              inputMode="decimal"
              suffix="tBILL"
              value={mintInput}
              onChange={(e) => setMintInput(e.target.value)}
            />
            <TxAction
              label="mint(vault, monto)"
              disabled={mintAmount === undefined}
              disabledReason={mintAmount === undefined ? 'Ingresá un monto válido.' : undefined}
              buildParams={() => ({
                address: TBILL_ADDRESS,
                abi: TBillTokenAbi,
                functionName: 'mint',
                args: [VAULT_ADDRESS, mintAmount ?? 0n],
              })}
              onConfirmed={() => {
                setMintInput('')
                void reads.refetch()
                onChanged()
              }}
            />
          </div>

          <div className="h-px bg-border-subtle" />

          <div className="flex flex-col gap-2">
            <TextField
              label="burn tBILL del vault — monto"
              placeholder="0.0000"
              inputMode="decimal"
              suffix="tBILL"
              value={burnInput}
              onChange={(e) => setBurnInput(e.target.value)}
            />
            <TxAction
              label="burn(vault, monto)"
              disabled={
                burnAmount === undefined || (vaultTBillBalance !== undefined && burnAmount > vaultTBillBalance)
              }
              disabledReason={
                burnAmount === undefined
                  ? 'Ingresá un monto válido.'
                  : vaultTBillBalance !== undefined && burnAmount > vaultTBillBalance
                    ? 'Supera el holding de tBILL del vault.'
                    : undefined
              }
              buildParams={() => ({
                address: TBILL_ADDRESS,
                abi: TBillTokenAbi,
                functionName: 'burn',
                args: [VAULT_ADDRESS, burnAmount ?? 0n],
              })}
              onConfirmed={() => {
                setBurnInput('')
                void reads.refetch()
                onChanged()
              }}
            />
          </div>
        </div>
      )}
    </div>
  )
}
