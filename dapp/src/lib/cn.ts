export type ClassValue = string | number | null | false | undefined | ClassValue[]

/**
 * Concatenador de clases minimalista (sin dependencias externas), portado
 * de PULSO. Acepta strings, condicionales (`cond && 'clase'`) y arrays
 * anidados.
 */
export function cn(...values: ClassValue[]): string {
  const out: string[] = []
  for (const value of values) {
    if (!value) continue
    if (Array.isArray(value)) {
      const nested = cn(...value)
      if (nested) out.push(nested)
      continue
    }
    out.push(String(value))
  }
  return out.join(' ')
}
