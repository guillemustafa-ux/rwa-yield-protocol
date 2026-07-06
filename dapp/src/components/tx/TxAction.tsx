import { useEffect, useRef, type JSX, type ReactNode } from 'react'
import { useTxAction } from '../../hooks/useTxAction'
import { Button, type ButtonVariant } from '../ui/Button'
import { etherscanTxUrl } from '../../contracts/addresses'
import { humanizeTxError } from './errors'

type ExecuteParams = Parameters<ReturnType<typeof useTxAction>['execute']>[0]

/**
 * Botón de acción de escritura on-chain: envuelve `useTxAction` (patrón
 * PULSO — reusado, no reinventado) con el estado visual completo (idle →
 * confirmá en tu wallet → confirmando → confirmado/error), link a Etherscan
 * de la tx enviada, y el error decodificado a español (`humanizeTxError`).
 *
 * Cada `<TxAction>` es SU PROPIA instancia de `useTxAction` — esa es la
 * razón de ser del hook (un hook por acción, no un estado global
 * compartido): un click en "fulfillDeposit" no pisa el spinner de "pause".
 */
export function TxAction({
  label,
  confirmingLabel = 'Confirmando…',
  confirmedLabel = 'Confirmado ✓',
  variant = 'primary',
  size = 'md',
  disabled,
  disabledReason,
  buildParams,
  onConfirmed,
  helperText,
  className,
}: {
  label: ReactNode
  confirmingLabel?: ReactNode
  confirmedLabel?: ReactNode
  variant?: ButtonVariant
  size?: 'sm' | 'md'
  disabled?: boolean
  /** Motivo (opcional) por el que el botón está deshabilitado — se muestra debajo. */
  disabledReason?: ReactNode
  /** Arma los params de `writeContractAsync` recién al click (lee inputs frescos). */
  buildParams: () => ExecuteParams
  onConfirmed?: () => void
  helperText?: ReactNode
  className?: string
}): JSX.Element {
  const { execute, status, hash, errorMessage, reset } = useTxAction()
  const notifiedRef = useRef(false)

  useEffect(() => {
    if (status === 'confirmed' && !notifiedRef.current) {
      notifiedRef.current = true
      onConfirmed?.()
    }
    if (status !== 'confirmed') notifiedRef.current = false
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status])

  const isBusy = status === 'pending' || status === 'confirming'

  return (
    <div className={className}>
      <Button
        type="button"
        variant={status === 'error' ? 'danger' : variant}
        size={size}
        disabled={disabled || isBusy}
        onClick={() => {
          if (status === 'error' || status === 'confirmed') reset()
          void execute(buildParams())
        }}
      >
        {status === 'pending'
          ? 'Confirmá en tu wallet…'
          : status === 'confirming'
            ? confirmingLabel
            : status === 'confirmed'
              ? confirmedLabel
              : label}
      </Button>

      {disabled && disabledReason && <p className="mt-1 text-xs text-text-tertiary">{disabledReason}</p>}
      {helperText && !disabled && <p className="mt-1 text-xs text-text-tertiary">{helperText}</p>}

      {hash && (
        <a
          href={etherscanTxUrl(hash)}
          target="_blank"
          rel="noreferrer"
          className="mt-1 inline-block text-xs font-medium text-accent-strong hover:underline"
        >
          Ver tx en Etherscan ↗
        </a>
      )}

      {status === 'error' && errorMessage && (
        <p className="mt-1 max-w-md text-xs text-negative">{humanizeTxError(errorMessage)}</p>
      )}
    </div>
  )
}
