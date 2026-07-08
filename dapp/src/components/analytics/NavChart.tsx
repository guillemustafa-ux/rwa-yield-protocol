import type { JSX } from 'react'

export interface NavPoint {
  /** Unix seconds. */
  t: number
  /** NAV ya escalado a USD (ej. 100.0). */
  nav: number
}

/**
 * Gráfico de línea del historial de NAV, dibujado como SVG inline — a propósito
 * sin librería de charts: son pocos puntos y el activo (una vault RWA) tiene un
 * NAV que se mueve poco, así que un recharts/lightweight-charts sería sobrepeso.
 * Escala al alto/ancho del viewBox y es responsive (width 100%).
 */
export function NavChart({ points }: { points: NavPoint[] }): JSX.Element {
  if (points.length === 0) {
    return <p className="text-sm text-text-tertiary">Sin publicaciones de NAV indexadas todavía.</p>
  }

  const W = 720
  const H = 240
  const PAD = 36

  const navs = points.map((p) => p.nav)
  const ts = points.map((p) => p.t)
  const minNav = Math.min(...navs)
  const maxNav = Math.max(...navs)
  const minT = Math.min(...ts)
  const maxT = Math.max(...ts)
  // Evita dividir por cero con un solo punto o serie plana.
  const navRange = maxNav - minNav || 1
  const tRange = maxT - minT || 1

  const single = points.length === 1
  const x = (t: number): number => (single ? W / 2 : PAD + ((t - minT) / tRange) * (W - PAD * 2))
  const y = (nav: number): number =>
    single ? H / 2 : H - PAD - ((nav - minNav) / navRange) * (H - PAD * 2)

  const coords = points.map((p) => `${x(p.t).toFixed(1)},${y(p.nav).toFixed(1)}`)
  const linePath = coords.join(' ')
  // Área bajo la curva (cierra contra la base).
  const areaPath =
    points.length > 1
      ? `${coords[0]} ${linePath} ${x(maxT).toFixed(1)},${(H - PAD).toFixed(1)} ${x(minT).toFixed(
          1,
        )},${(H - PAD).toFixed(1)}`
      : ''

  const fmtDate = (t: number): string =>
    new Date(t * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
  const fmtUsd = (n: number): string =>
    `$${n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="none"
      className="h-56 w-full text-accent-strong"
      role="img"
      aria-label="Historial de NAV en el tiempo"
    >
      {/* Ejes / guías horizontales min-max */}
      <line x1={PAD} y1={PAD} x2={PAD} y2={H - PAD} stroke="currentColor" strokeOpacity="0.15" />
      <line x1={PAD} y1={H - PAD} x2={W - PAD} y2={H - PAD} stroke="currentColor" strokeOpacity="0.15" />

      {areaPath && <polygon points={areaPath} fill="currentColor" fillOpacity="0.08" />}
      {points.length > 1 && (
        <polyline points={linePath} fill="none" stroke="currentColor" strokeWidth="2" />
      )}

      {points.map((p) => (
        <circle key={`${p.t}-${p.nav}`} cx={x(p.t)} cy={y(p.nav)} r="3.5" fill="currentColor" />
      ))}

      {/* Etiquetas de rango NAV (arriba-izq = max, abajo-izq = min) */}
      <text x={4} y={PAD + 4} className="fill-text-tertiary" fontSize="11">
        {fmtUsd(maxNav)}
      </text>
      <text x={4} y={H - PAD + 4} className="fill-text-tertiary" fontSize="11">
        {fmtUsd(minNav)}
      </text>

      {/* Etiquetas de fecha (primera y última) */}
      <text x={PAD} y={H - 8} className="fill-text-tertiary" fontSize="11">
        {fmtDate(minT)}
      </text>
      <text x={W - PAD} y={H - 8} textAnchor="end" className="fill-text-tertiary" fontSize="11">
        {fmtDate(maxT)}
      </text>
    </svg>
  )
}
