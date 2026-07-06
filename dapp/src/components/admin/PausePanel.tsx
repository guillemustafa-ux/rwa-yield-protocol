import type { JSX } from 'react'
import { useReadContract } from 'wagmi'
import { VAULT_ADDRESS } from '../../contracts/addresses'
import { RwaVaultV2Abi } from '../../contracts/abis/RwaVaultV2'
import { Badge } from '../ui/Badge'
import { TxAction } from '../tx/TxAction'

/**
 * `PAUSER_ROLE`: pausa solo `requestDeposit`/`requestRedeem` (nuevos
 * requests) — `fulfillDeposit`/`fulfillRedeem`/claims siguen siempre
 * abiertos, la pausa nunca puede trabar plata ya comprometida
 * (RwaVault.sol NatSpec punto 6, ARCHITECTURE.md §4 "pausa como DoS").
 */
export function PausePanel({ onChanged }: { onChanged: () => void }): JSX.Element {
  const pausedRead = useReadContract({
    address: VAULT_ADDRESS,
    abi: RwaVaultV2Abi,
    functionName: 'paused',
    query: { refetchInterval: 15_000 },
  })
  const paused = pausedRead.data

  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">Pausa — PAUSER_ROLE</h2>
        {paused === undefined ? (
          <Badge tone="neutral">…</Badge>
        ) : paused ? (
          <Badge tone="negative" dot>
            Pausado
          </Badge>
        ) : (
          <Badge tone="positive" dot>
            Activo
          </Badge>
        )}
      </div>

      <p className="text-xs text-text-tertiary">
        Pausar solo bloquea requestDeposit/requestRedeem nuevos. Los claims y los fulfills de redeem NUNCA se
        pausan.
      </p>

      <div className="flex gap-2">
        <TxAction
          label="Pause"
          variant="danger"
          disabled={paused !== false}
          disabledReason={paused === undefined ? 'Cargando estado…' : paused === true ? 'Ya está pausado.' : undefined}
          buildParams={() => ({ address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'pause', args: [] })}
          onConfirmed={() => {
            void pausedRead.refetch()
            onChanged()
          }}
        />
        <TxAction
          label="Unpause"
          variant="secondary"
          disabled={paused !== true}
          disabledReason={paused === undefined ? 'Cargando estado…' : paused === false ? 'Ya está activo.' : undefined}
          buildParams={() => ({ address: VAULT_ADDRESS, abi: RwaVaultV2Abi, functionName: 'unpause', args: [] })}
          onConfirmed={() => {
            void pausedRead.refetch()
            onChanged()
          }}
        />
      </div>
    </div>
  )
}
