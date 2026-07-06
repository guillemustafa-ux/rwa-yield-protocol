import { useState, type JSX } from 'react'
import { parseUnits } from 'viem'
import { useReadContracts } from 'wagmi'
import { CONTRACT_ADDRESSES } from '../../contracts/addresses'
import { RwaNavFeedAbi } from '../../contracts/abis/RwaNavFeed'
import { formatTokenAmount, formatUnixSeconds, secondsSince } from '../../lib/format'
import { TextField } from '../ui/TextField'
import { Badge } from '../ui/Badge'
import { TxAction } from '../tx/TxAction'

const NAV_FEED_ADDRESS = CONTRACT_ADDRESSES.RwaNavFeed

function ok<T>(r: { status: string; result?: T } | undefined): T | undefined {
  return r && r.status === 'success' ? r.result : undefined
}

/**
 * `NAV_UPDATER_ROLE` (en `RwaNavFeed`, no en el vault): publica un nuevo
 * NAV con validación CLIENT-SIDE de las dos bandas que el contrato aplica
 * (RwaNavFeed.sol): desviación máxima ±5% contra el round anterior y rate
 * limit de 1h entre updates. El contrato es la autoridad final — esto es
 * solo para no hacer firmar una tx que se sabe de antemano que va a revertir.
 */
export function NavUpdatePanel({
  navAnswer,
  navDecimals,
  navUpdatedAt,
  onChanged,
}: {
  navAnswer: bigint | undefined
  navDecimals: number | undefined
  navUpdatedAt: bigint | undefined
  onChanged: () => void
}): JSX.Element {
  const [navInput, setNavInput] = useState('')

  const reads = useReadContracts({
    contracts: [
      { address: NAV_FEED_ADDRESS, abi: RwaNavFeedAbi, functionName: 'MAX_DEVIATION_BPS' },
      { address: NAV_FEED_ADDRESS, abi: RwaNavFeedAbi, functionName: 'MIN_UPDATE_INTERVAL' },
    ],
  })
  const [maxDeviationBpsR, minUpdateIntervalR] = reads.data ?? []
  const maxDeviationBps = ok(maxDeviationBpsR)
  const minUpdateInterval = ok(minUpdateIntervalR)

  let newNavCandidate: bigint | undefined
  try {
    newNavCandidate = navDecimals !== undefined && navInput.trim() !== '' ? parseUnits(navInput.trim(), navDecimals) : undefined
  } catch {
    newNavCandidate = undefined
  }
  const invalidInput = navInput.trim() !== '' && newNavCandidate === undefined

  const deviationBps =
    newNavCandidate !== undefined && navAnswer !== undefined && navAnswer > 0n
      ? ((newNavCandidate > navAnswer ? newNavCandidate - navAnswer : navAnswer - newNavCandidate) * 10_000n) /
        navAnswer
      : undefined
  const exceedsDeviation = deviationBps !== undefined && maxDeviationBps !== undefined && deviationBps > maxDeviationBps

  const secondsSinceUpdate = navUpdatedAt !== undefined ? secondsSince(navUpdatedAt) : undefined
  const secondsUntilAllowed =
    minUpdateInterval !== undefined && secondsSinceUpdate !== undefined
      ? Number(minUpdateInterval) - secondsSinceUpdate
      : undefined
  const tooFrequent = secondsUntilAllowed !== undefined && secondsUntilAllowed > 0

  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div>
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">
          Oráculo NAV — NAV_UPDATER_ROLE
        </h2>
        <p className="mt-1 text-xs text-text-tertiary">
          Bandas del contrato: máximo ±
          {maxDeviationBps !== undefined ? `${(Number(maxDeviationBps) / 100).toFixed(1)}%` : '5%'} por update,
          mínimo {minUpdateInterval !== undefined ? `${Number(minUpdateInterval) / 3600}h` : '1h'} entre updates.
        </p>
      </div>

      <p className="text-xs text-text-secondary">
        NAV actual: {navAnswer !== undefined && navDecimals !== undefined ? `$${formatTokenAmount(navAnswer, navDecimals)}` : '—'}
        {navUpdatedAt !== undefined && ` · actualizado ${formatUnixSeconds(navUpdatedAt)}`}
      </p>

      {tooFrequent && (
        <Badge tone="warning" dot className="w-fit">
          Faltan ~{Math.ceil((secondsUntilAllowed ?? 0) / 60)} min para poder actualizar de nuevo (TooFrequent)
        </Badge>
      )}

      <TextField
        label="Nuevo NAV"
        placeholder="100.50"
        inputMode="decimal"
        suffix="USD"
        value={navInput}
        onChange={(e) => setNavInput(e.target.value)}
        error={invalidInput ? 'Monto inválido.' : undefined}
      />

      {exceedsDeviation && deviationBps !== undefined && (
        <Badge tone="negative" dot className="w-fit">
          Se desvía {(Number(deviationBps) / 100).toFixed(2)}% del NAV anterior — supera la banda permitida
          (NavDeviationTooHigh)
        </Badge>
      )}

      <TxAction
        label="updateNav"
        disabled={newNavCandidate === undefined || exceedsDeviation || tooFrequent}
        disabledReason={
          newNavCandidate === undefined
            ? 'Ingresá un NAV válido.'
            : exceedsDeviation
              ? 'Supera la banda de desviación permitida.'
              : tooFrequent
                ? 'Todavía no pasó el intervalo mínimo entre updates.'
                : undefined
        }
        buildParams={() => ({
          address: NAV_FEED_ADDRESS,
          abi: RwaNavFeedAbi,
          functionName: 'updateNav',
          args: [newNavCandidate ?? 0n],
        })}
        onConfirmed={() => {
          setNavInput('')
          onChanged()
        }}
      />
    </div>
  )
}
