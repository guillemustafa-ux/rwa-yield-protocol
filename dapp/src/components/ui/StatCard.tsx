import type { JSX, ReactNode } from 'react'

export function StatCard({
  label,
  value,
  hint,
  isLoading,
}: {
  label: string
  value: ReactNode
  hint?: ReactNode
  isLoading?: boolean
}): JSX.Element {
  return (
    <div className="rounded-xl border border-border-subtle bg-surface-1 px-5 py-4">
      <p className="text-xs font-medium uppercase tracking-wide text-text-tertiary">{label}</p>
      {isLoading ? (
        <div className="mt-2 h-7 w-24 animate-pulse rounded bg-surface-3" />
      ) : (
        <p className="mt-1 text-2xl font-semibold text-text-primary">{value}</p>
      )}
      {hint && <p className="mt-1 text-xs text-text-tertiary">{hint}</p>}
    </div>
  )
}
