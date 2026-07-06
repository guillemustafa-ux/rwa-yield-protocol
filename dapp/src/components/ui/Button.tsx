import type { ButtonHTMLAttributes, JSX } from 'react'
import { cn } from '../../lib/cn'

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger'
export type ButtonSize = 'sm' | 'md'

const variantClasses: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-white hover:bg-accent-strong disabled:hover:bg-accent',
  secondary:
    'bg-surface-2 text-text-primary border border-border-default hover:border-border-emphasis disabled:hover:border-border-default',
  ghost: 'bg-transparent text-text-secondary hover:text-text-primary hover:bg-surface-2',
  danger: 'bg-negative/15 text-negative border border-negative/40 hover:bg-negative/25',
}

const sizeClasses: Record<ButtonSize, string> = {
  sm: 'h-8 px-3 text-xs',
  md: 'h-10 px-4 text-sm',
}

/**
 * Clases del botón, expuestas por separado de `<Button>` para poder aplicar
 * el mismo look a elementos que NO son un `<button>` (p. ej. un `<Link>` de
 * react-router que navega a `/vault`) sin anidar un `<a>` dentro de un
 * `<button>` (HTML inválido) ni depender de un patrón `asChild`/Slot.
 */
export function buttonClassName(
  variant: ButtonVariant = 'secondary',
  size: ButtonSize = 'md',
  className?: string,
): string {
  return cn(
    'inline-flex items-center justify-center gap-2 rounded-lg font-medium transition-colors',
    'disabled:cursor-not-allowed disabled:opacity-50',
    variantClasses[variant],
    sizeClasses[size],
    className,
  )
}

export function Button({
  variant = 'secondary',
  size = 'md',
  className,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: ButtonVariant; size?: ButtonSize }): JSX.Element {
  return <button className={buttonClassName(variant, size, className)} {...props} />
}
