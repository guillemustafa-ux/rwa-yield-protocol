import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider } from 'wagmi'
import { RainbowKitProvider, darkTheme } from '@rainbow-me/rainbowkit'
import { sepolia } from 'wagmi/chains'
import '@rainbow-me/rainbowkit/styles.css'
import './styles/globals.css'
import { wagmiConfig } from './lib/wagmi'
import App from './App.tsx'

const queryClient = new QueryClient()

/**
 * Tema del modal de RainbowKit: dark + el mismo acento azul institucional
 * del resto del design system (ver `src/styles/globals.css`), sin el
 * violeta/glow de PULSO — este protocolo es RWA institucional, no un
 * exchange retail.
 */
const rainbowKitTheme = darkTheme({
  accentColor: '#4c7cf0',
  accentColorForeground: '#e7ebf3',
  borderRadius: 'medium',
  overlayBlur: 'small',
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {/* `WagmiProvider` es el nombre vigente en wagmi v2 (`WagmiConfig` quedó
        como alias deprecado del mismo componente). */}
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={rainbowKitTheme} initialChain={sepolia}>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </StrictMode>,
)
