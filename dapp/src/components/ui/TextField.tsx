import type { InputHTMLAttributes, JSX, ReactNode } from 'react'
import { cn } from '../../lib/cn'

/**
 * Input de texto/número genérico con label + hint + error, estilo
 * consistente con el resto del design system (`StatCard`/`Badge`). Se usa
 * tanto para montos (depósito, redeem, NAV) como para addresses (controller
 * lookup en Admin) — el caller decide `type`/`inputMode`.
 */
export function TextField({
  label,
  hint,
  error,
  suffix,
  className,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & {
  label?: ReactNode
  hint?: ReactNode
  error?: ReactNode
  suffix?: ReactNode
}): JSX.Element {
  return (
    <label className={cn('flex flex-col gap-1.5', className)}>
      {label && <span className="text-xs font-medium text-text-secondary">{label}</span>}
      <span className="relative flex items-center">
        <input
          className={cn(
            'h-10 w-full rounded-lg border bg-surface-2 px-3 text-sm text-text-primary placeholder:text-text-muted',
            'outline-none transition-colors focus:border-accent',
            error ? 'border-negative/50' : 'border-border-default',
            suffix ? 'pr-14' : undefined,
          )}
          {...props}
        />
        {suffix && (
          <span className="pointer-events-none absolute right-3 text-xs font-medium text-text-tertiary">
            {suffix}
          </span>
        )}
      </span>
      {error ? (
        <span className="text-xs text-negative">{error}</span>
      ) : (
        hint && <span className="text-xs text-text-tertiary">{hint}</span>
      )}
    </label>
  )
}
