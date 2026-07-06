// Genera src/contracts/abis/*.ts a partir de los artifacts de forge en
// ../contracts/out. Lee SOLO el campo `abi` de cada JSON (el resto del
// artifact — bytecode, ast, storage layout — no le sirve al frontend y
// infla el bundle si se importa entero).
//
// Uso: node scripts/generate-abis.mjs   (o `npm run generate:abis`)
//
// Nota Windows: node, no sed/heredoc, para evitar problemas de quoting
// (lección heredada de los otros repos del portfolio).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dirname = dirname(fileURLToPath(import.meta.url))
const OUT_DIR = join(__dirname, '..', '..', 'contracts', 'out')
const DEST_DIR = join(__dirname, '..', 'src', 'contracts', 'abis')

// name: nombre exportado; artifactPath: ruta relativa dentro de contracts/out
const TARGETS = [
  { name: 'RwaVaultV2', artifactPath: 'RwaVaultV2.sol/RwaVaultV2.json' },
  { name: 'RwaNavFeed', artifactPath: 'RwaNavFeed.sol/RwaNavFeed.json' },
  { name: 'TBillToken', artifactPath: 'TBillToken.sol/TBillToken.json' },
  { name: 'DemoUSDC', artifactPath: 'Deploy.s.sol/DemoUSDC.json' },
]

mkdirSync(DEST_DIR, { recursive: true })

const exportedNames = []

for (const { name, artifactPath } of TARGETS) {
  const fullPath = join(OUT_DIR, artifactPath)
  const artifact = JSON.parse(readFileSync(fullPath, 'utf8'))
  const abi = artifact.abi
  if (!Array.isArray(abi)) {
    throw new Error(`No se encontró "abi" en ${fullPath}`)
  }

  const header = `// AUTO-GENERADO por scripts/generate-abis.mjs desde\n// contracts/out/${artifactPath.replace(/\\/g, '/')}\n// No editar a mano — correr \`npm run generate:abis\` tras recompilar contratos.\n\n`
  const body = `export const ${name}Abi = ${JSON.stringify(abi, null, 2)} as const\n`
  writeFileSync(join(DEST_DIR, `${name}.ts`), header + body)
  exportedNames.push(name)
  console.log(`  ${name}.ts <- ${artifactPath} (${abi.length} entradas ABI)`)
}

const indexContent =
  '// AUTO-GENERADO por scripts/generate-abis.mjs — barrel de re-exports.\n\n' +
  exportedNames.map((n) => `export { ${n}Abi } from './${n}'`).join('\n') +
  '\n'
writeFileSync(join(DEST_DIR, 'index.ts'), indexContent)

console.log(`\nOK: ${exportedNames.length} ABIs generados en ${DEST_DIR}`)
