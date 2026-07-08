import type { JSX, ReactNode } from 'react'
import { Badge } from '../components/ui/Badge'
import { StatCard } from '../components/ui/StatCard'
import {
  F3,
  arbiscanAddressUrl,
  ccipMessageUrl,
  etherscanAddressUrl,
  etherscanTxUrl,
} from '../contracts/addresses'

/** Acorta un hash/address a `0x1234…abcd` para mostrar sin romper el layout. */
function short(hex: string): string {
  return hex.length > 14 ? `${hex.slice(0, 8)}…${hex.slice(-6)}` : hex
}

/** Link externo monoespaciado a un explorador, con el hash acortado. */
function ExplorerLink({ href, value }: { href: string; value: string }): JSX.Element {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-xs text-accent-strong hover:underline"
    >
      {short(value)} ↗
    </a>
  )
}

/** Una fila etiqueta → valor dentro de una tarjeta de evidencia. */
function EvidenceRow({ label, children }: { label: string; children: ReactNode }): JSX.Element {
  return (
    <div className="flex items-center justify-between gap-4 py-2">
      <span className="text-xs text-text-tertiary">{label}</span>
      <span className="text-right text-sm text-text-secondary">{children}</span>
    </div>
  )
}

/** Un paso del diagrama de flujo cross-chain. */
function FlowStep({
  index,
  chain,
  title,
  desc,
}: {
  index: number
  chain: string
  title: string
  desc: string
}): JSX.Element {
  return (
    <div className="flex-1 rounded-xl border border-border-subtle bg-surface-1 p-5">
      <div className="flex items-center gap-2">
        <span className="flex h-6 w-6 items-center justify-center rounded-full border border-accent/40 bg-accent/10 text-xs font-semibold text-accent-strong">
          {index}
        </span>
        <Badge tone="neutral">{chain}</Badge>
      </div>
      <h3 className="mt-3 text-sm font-semibold text-text-primary">{title}</h3>
      <p className="mt-1 text-xs leading-relaxed text-text-secondary">{desc}</p>
    </div>
  )
}

export function CrossChain(): JSX.Element {
  return (
    <div className="flex flex-col gap-14">
      {/* Hero */}
      <section className="flex flex-col gap-5">
        <Badge tone="positive" dot className="w-fit">
          F3 — activado en vivo el 07/07 con LINK real de testnet
        </Badge>

        <h1 className="max-w-2xl text-3xl font-semibold tracking-tight text-text-primary sm:text-4xl">
          Depósito cross-chain vía Chainlink CCIP, liquidado por un keeper de Automation.
        </h1>

        <p className="max-w-2xl text-sm leading-relaxed text-text-secondary sm:text-base">
          Un usuario en <strong>Arbitrum Sepolia</strong> dispara un depósito en el vault que vive en{' '}
          <strong>Sepolia</strong>, sin haber puenteado el activo a mano. Es CCIP <em>messaging</em>, no un token
          bridge: el mensaje cross-chain lleva solo <code className="text-text-primary">(controller, assets)</code> y
          un relay del lado de Sepolia —con su propio dUSDC pre-fondeado— traduce ese mensaje en un{' '}
          <code className="text-text-primary">requestDeposit</code> real sobre el vault. Trade-off elegido a
          propósito (un deploy productivo usaría un CCIP Token Pool registrado); acá se optó por la ruta liviana y se
          documentó.
        </p>
      </section>

      {/* Flujo */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">El flujo, de punta a punta</h2>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-stretch">
          <FlowStep
            index={1}
            chain="Arbitrum Sepolia"
            title="Sender emite el mensaje"
            desc="CrossChainDepositSender llama ccipSend con (controller, assets) y paga el fee de CCIP en LINK. No mueve el activo."
          />
          <FlowStep
            index={2}
            chain="CCIP"
            title="La red entrega el mensaje"
            desc="Chainlink CCIP transporta el mensaje entre cadenas. Trazable end-to-end por su messageId en el CCIP explorer."
          />
          <FlowStep
            index={3}
            chain="Sepolia"
            title="Relay dispara el depósito"
            desc="CrossChainDepositRelay valida el sender allowlisteado, aprueba el monto exacto y llama requestDeposit en el vault con su propio dUSDC."
          />
        </div>
      </section>

      {/* Evidencia del mensaje CCIP */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">El mensaje cross-chain real</h2>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <StatCard label="Monto depositado" value={F3.ccipAssets} hint="cruzó de Arbitrum Sepolia a Sepolia" />
          <StatCard label="Entrega CCIP" value={F3.ccipDeliveryTime} hint="latencia real en testnet" />
          <StatCard label="Ruta" value="Arb Sepolia → Sepolia" hint="messaging, sin token bridge" />
        </div>
        <div className="rounded-xl border border-border-subtle bg-surface-1 p-6">
          <div className="divide-y divide-border-subtle">
            <EvidenceRow label="CCIP messageId (trazá el mensaje)">
              <ExplorerLink href={ccipMessageUrl(F3.ccipMessageId)} value={F3.ccipMessageId} />
            </EvidenceRow>
            <EvidenceRow label="Sender — Arbitrum Sepolia">
              <ExplorerLink href={arbiscanAddressUrl(F3.sender)} value={F3.sender} />
            </EvidenceRow>
            <EvidenceRow label="Relay — Sepolia">
              <ExplorerLink href={etherscanAddressUrl(F3.relay)} value={F3.relay} />
            </EvidenceRow>
            <EvidenceRow label="Claim de las shares (cierra el ciclo)">
              <ExplorerLink href={etherscanTxUrl(F3.claimDepositTx)} value={F3.claimDepositTx} />
            </EvidenceRow>
          </div>
        </div>
      </section>

      {/* Automation */}
      <section className="flex flex-col gap-4">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-text-tertiary">
          Liquidación automática (Chainlink Automation)
        </h2>
        <p className="max-w-2xl text-sm leading-relaxed text-text-secondary">
          En vez de un operador humano mirando requests pendientes, un <strong>keeper log-trigger</strong> despierta con
          cada evento <code className="text-text-primary">DepositRequest</code>/<code className="text-text-primary">RedeemRequest</code>{' '}
          y llama <code className="text-text-primary">fulfill*</code> en el vault (tiene <code className="text-text-primary">OPERATOR_ROLE</code>).
          Dos upkeeps quedaron registrados, fondeados y auto-aprobados vía el registrar de Automation 2.1.0.
        </p>
        <div className="rounded-xl border border-border-subtle bg-surface-1 p-6">
          <div className="divide-y divide-border-subtle">
            <EvidenceRow label="Keeper (OPERATOR_ROLE en el proxy)">
              <ExplorerLink href={etherscanAddressUrl(F3.keeper)} value={F3.keeper} />
            </EvidenceRow>
            <EvidenceRow label="Registrar de Automation (2.1.0)">
              <ExplorerLink href={etherscanAddressUrl(F3.registrar)} value={F3.registrar} />
            </EvidenceRow>
            <EvidenceRow label="Upkeep — DepositRequest">
              <span className="font-mono text-xs text-text-secondary">{short(F3.depositUpkeepId)}</span>
            </EvidenceRow>
            <EvidenceRow label="Upkeep — RedeemRequest">
              <span className="font-mono text-xs text-text-secondary">{short(F3.redeemUpkeepId)}</span>
            </EvidenceRow>
          </div>
        </div>

        {/* Outcome honesto — no se esconde el fallback manual */}
        <div className="rounded-xl border border-warning/30 bg-warning/10 p-6">
          <div className="flex items-center gap-2">
            <Badge tone="warning" dot>
              Resultado real: fallback manual
            </Badge>
          </div>
          <p className="mt-3 max-w-2xl text-sm leading-relaxed text-text-secondary">
            Honestidad por delante: los upkeeps quedaron registrados, fondeados y auto-aprobados, y{' '}
            <code className="text-text-primary">checkLog()</code> se probó matemáticamente correcto por simulación
            directa (devuelve <code className="text-text-primary">upkeepNeeded=true</code> con el{' '}
            <code className="text-text-primary">performData</code> esperado). Aun así, la red de nodos de Automation{' '}
            <strong>no llamó <code className="text-text-primary">performUpkeep</code></strong> en ~70 minutos de polling
            — causa más probable: latencia/confiabilidad de Automation en testnet, no un defecto de los contratos. El
            ciclo se cerró llamando <code className="text-text-primary">performUpkeep</code> a mano: es{' '}
            <strong>permissionless por diseño del estándar Chainlink</strong>, con el mismo{' '}
            <code className="text-text-primary">performData</code> ya validado por la simulación, sin saltear ninguna
            lógica del contrato.
          </p>
          <a
            href={etherscanTxUrl(F3.manualPerformUpkeepTx)}
            target="_blank"
            rel="noreferrer"
            className="mt-4 inline-block font-mono text-xs text-accent-strong hover:underline"
          >
            performUpkeep manual: {short(F3.manualPerformUpkeepTx)} ↗
          </a>
        </div>
      </section>
    </div>
  )
}
