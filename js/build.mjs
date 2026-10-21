import { build } from 'esbuild'
import { writeFileSync, readFileSync, mkdirSync, rmSync } from 'fs'
import { bundledLanguages, bundledLanguagesInfo } from 'shiki/langs'
import { bundledThemesInfo } from 'shiki/themes'

const out = '../Resources'
rmSync(out, { recursive: true, force: true })
mkdirSync(`${out}/langs`, { recursive: true })
mkdirSync(`${out}/themes`, { recursive: true })

// alias -> canonical grammar id
const ALIAS = {}
for (const [key, load] of Object.entries(bundledLanguages)) {
  const arr = (await load()).default
  ALIAS[key] = arr[arr.length - 1].name
}
const ids = [...new Set(Object.values(ALIAS))]
const THEMES = bundledThemesInfo.map(t => t.id)
writeFileSync('index.gen.js', `export const ALIAS = ${JSON.stringify(ALIAS)}\nexport const THEMES = ${JSON.stringify(THEMES)}\n`)

const common = { bundle: true, minify: true, format: 'iife', platform: 'neutral', target: 'es2022', mainFields: ['module', 'main'], legalComments: 'none', logLevel: 'warning' }
await build({ ...common, entryPoints: ['entry.js'], outfile: `${out}/core.js`, banner: { js: readFileSync('polyfill.js', 'utf8') } })
await Promise.all([
  ...ids.map(id => build({ ...common, stdin: { contents: `import g from '@shikijs/langs/${id}'; (globalThis.__L = globalThis.__L || {})[${JSON.stringify(id)}] = g`, resolveDir: '.' }, outfile: `${out}/langs/${id}.js` })),
  ...THEMES.map(id => build({ ...common, stdin: { contents: `import t from '@shikijs/themes/${id}'; (globalThis.__T = globalThis.__T || {})[${JSON.stringify(id)}] = t`, resolveDir: '.' }, outfile: `${out}/themes/${id}.js` })),
])
writeFileSync(`${out}/themes.json`, JSON.stringify(bundledThemesInfo.map(t => ({ id: t.id, name: t.displayName, type: t.type }))))
writeFileSync(`${out}/langs.json`, JSON.stringify(bundledLanguagesInfo.filter(l => ids.includes(l.id)).map(l => ({ id: l.id, name: l.name }))))
console.log(ids.length, 'languages', THEMES.length, 'themes')
