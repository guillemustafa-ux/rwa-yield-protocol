import type { JSX, ReactNode } from 'react'
import { cn } from '../../lib/cn'

type Tone = 'neutral' | 'positive' | 'warning' | 'negative'

const toneClasses: Record<Tone, string> = {
  neutral: 'bg-surface-2 text-text-secondary border-border-default',
  positive: 'bg-positive/10 text-positive border-positive/30',
  warning: 'bg-warning/10 text-warning border-warning/30',
  negative: 'bg-negative/10 text-negative border-negative/30',
}

const dotClasses: Record<Tone, string> = {
  neutral: 'bg-text-tertiary',
  positive: 'bg-positive',
  warning: 'bg-warning',
  negative: 'bg-negative',
}

export function Badge({
  children,
  tone = 'neutral',
  dot = false,
  className,
}: {
  children: ReactNode
  tone?: Tone
  dot?: boolean
  className?: string
}): JSX.Element {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-medium',
        toneClasses[tone],
        className,
      )}
    >
      {dot && <span className={cn('h-1.5 w-1.5 rounded-full', dotClasses[tone])} />}
      {children}
    </span>
  )
}
