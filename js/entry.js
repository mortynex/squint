// Only Shiki's tokenizer core: the full `shiki/core` and its pure-JS regex engine cost ~30 ms to evaluate on every launch.
import { Registry, Resolver, tokenizeWithTheme, resolveColorReplacements, applyColorReplacements } from '@shikijs/primitive'
import { INITIAL } from '@shikijs/vscode-textmate'
import { ALIAS, THEMES } from './index.gen.js'

// Filename (lower-cased basename) -> shiki language
const FILENAMES = {
  'dockerfile': 'docker', 'containerfile': 'docker',
  'makefile': 'make', 'gnumakefile': 'make', 'bsdmakefile': 'make',
  'cmakelists.txt': 'cmake',
  '.env': 'dotenv', '.envrc': 'bash',
  '.gitignore': 'gitignore', '.dockerignore': 'gitignore', '.npmignore': 'gitignore', '.gitattributes': 'gitignore',
  '.bashrc': 'bash', '.bash_profile': 'bash', '.bash_aliases': 'bash', '.profile': 'bash', '.zshrc': 'bash', '.zshenv': 'bash', '.zprofile': 'bash',
  '.editorconfig': 'ini', '.gitconfig': 'ini', '.npmrc': 'ini', '.prettierrc': 'json', '.eslintrc': 'json', '.babelrc': 'json',
  'gemfile': 'ruby', 'rakefile': 'ruby', 'podfile': 'ruby', 'fastfile': 'ruby', 'vagrantfile': 'ruby', 'brewfile': 'ruby',
  'procfile': 'yaml', 'jenkinsfile': 'groovy', 'justfile': 'just', 'package.json': 'json', 'tsconfig.json': 'jsonc',
  'go.mod': 'go', 'go.sum': 'text', 'cargo.lock': 'toml', 'poetry.lock': 'toml', 'pipfile': 'toml',
  'nginx.conf': 'nginx', 'ssh_config': 'ssh-config', 'sshd_config': 'ssh-config', 'hosts': 'text',
  'requirements.txt': 'text', 'license': 'text', 'readme': 'text',
}
const EXTENSIONS = {
  env: 'dotenv', sh: 'bash', command: 'bash', zsh: 'bash', bash: 'bash', fish: 'fish', ksh: 'bash',
  yml: 'yaml', htm: 'html', mjs: 'javascript', cjs: 'javascript', h: 'c', hpp: 'cpp', hh: 'cpp', cc: 'cpp', cxx: 'cpp', mm: 'objective-cpp',
  m: 'objective-c', pyw: 'python', rb: 'ruby', rs: 'rust', kt: 'kotlin', kts: 'kotlin', tf: 'terraform', tfvars: 'terraform',
  plist: 'xml', xib: 'xml', storyboard: 'xml', xcconfig: 'ini', entitlements: 'xml', strings: 'ini', conf: 'ini', cfg: 'ini', properties: 'properties',
  jsonl: 'jsonl', json5: 'json5', geojson: 'json', ipynb: 'json', webmanifest: 'json', lock: 'text', log: 'log', txt: 'text', text: 'text',
  gitignore: 'gitignore', dockerfile: 'docker', containerfile: 'docker', mk: 'make', mak: 'make', patch: 'diff', rej: 'diff',
  ps1: 'powershell', psm1: 'powershell', bat: 'bat', cmd: 'bat', vue: 'vue', svelte: 'svelte', astro: 'astro', gradle: 'groovy', cs: 'csharp',
  fs: 'fsharp', ex: 'elixir', exs: 'elixir', erl: 'erlang', hs: 'haskell', pl: 'perl', pm: 'perl', tex: 'latex', md: 'markdown', mdx: 'mdx',
  sol: 'solidity', proto: 'proto', graphql: 'graphql', gql: 'graphql', prisma: 'prisma', scss: 'scss', sass: 'sass', less: 'less',
}
const SHEBANGS = [
  [/^#!.*\b(ba|z|k|da|a)?sh\b/, 'bash'], [/^#!.*\bpython/, 'python'], [/^#!.*\bnode\b|^#!.*\bdeno\b|^#!.*\bbun\b/, 'javascript'],
  [/^#!.*\bruby\b/, 'ruby'], [/^#!.*\bperl\b/, 'perl'], [/^#!.*\bphp\b/, 'php'], [/^#!.*\blua\b/, 'lua'], [/^#!.*\bfish\b/, 'fish'],
]

function detectLang(name, code) {
  const base = (name || '').split('/').pop().toLowerCase()
  if (FILENAMES[base]) return FILENAMES[base]
  if (base.startsWith('dockerfile.') || base.endsWith('.dockerfile')) return 'docker'
  if (base.startsWith('.env')) return 'dotenv'
  const dot = base.lastIndexOf('.')
  const ext = dot >= 0 ? base.slice(dot + 1) : ''
  if (ext && EXTENSIONS[ext]) return EXTENSIONS[ext]
  if (ext && ALIAS[ext]) return ext
  if (base && ALIAS[base]) return base
  if (base.startsWith('.') && ALIAS[base.slice(1)]) return base.slice(1)
  const first = code.slice(0, 200).split('\n', 1)[0]
  for (const [re, lang] of SHEBANGS) if (re.test(first)) return lang
  const t = code.trimStart()
  if (/^[\[{]/.test(t) && !/^\[\w[\w .-]*\]\s*$/m.test(t.slice(0, 200))) return 'json'
  if (/^<\?xml|^<!doctype html|^<html/i.test(t)) return /^<\?xml/i.test(t) ? 'xml' : 'html'
  return 'text'
}

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

// opts: { name, light, dark, fontSize, fontFamily, lineNumbers, wrap, maxLines }
// The theme to use: one theme only (chosen by the system appearance), since each extra theme means re-tokenizing.
function pickTheme(opts) {
  const want = opts.appearance === 'dark' ? opts.dark : opts.light
  return THEMES.includes(want) ? want : (opts.appearance === 'dark' ? 'github-dark' : 'github-light')
}

// Resolve which grammar/theme are needed, so the host can load just those files.
globalThis.shikiPlan = function (code, opts) {
  const lang = detectLang(opts.name || '', code)
  return JSON.stringify({ lang: lang === 'text' ? '' : (ALIAS[lang] || ''), theme: pickTheme(opts) })
}

// Native Oniguruma, provided by the host.
function nativeEngine() {
  return {
    createString: s => ({ content: s, id: globalThis.__onigString(s) }),
    createScanner(patterns) {
      const sc = globalThis.__onigScanner(patterns.map(String))
      return {
        findNextMatchSync(str, start) {
          const sid = typeof str === 'string' ? globalThis.__onigString(str) : str.id
          const r = globalThis.__onigFind(sc, sid, start)
          if (!r.length) return null
          const captureIndices = []
          for (let i = 1; i < r.length; i += 2) captureIndices.push({ start: r[i], end: r[i + 1], length: r[i + 1] - r[i] })
          return { index: r[0], captureIndices }
        },
      }
    },
  }
}
let engine
// Per language: a textmate registry with its compiled grammar and regex scanners, kept for the next file.
const registries = {}
function registryFor(lang) {
  let r = registries[lang]
  if (!r) {
    const list = globalThis.__L[lang]
    const main = list[list.length - 1]
    // Embedded grammars are only made known to the resolver, so they are built when the code first needs them
    // (a Ruby file would otherwise build all 30 grammars its bundle embeds).
    engine = engine || nativeEngine()
    r = registries[lang] = new Registry(new Resolver(engine, list), [], [{ ...main, embeddedLangs: undefined }])
  }
  return r
}

// Theme colours for the preview UI (gutter, find widget), with VS Code defaults where a theme is silent.
function uiColors(theme) {
  const c = theme.colors || {}
  const dark = theme.type !== 'light'
  const widgetFg = c['editorWidget.foreground'] || c.foreground || (dark ? '#cccccc' : '#616161')
  return {
    bg: theme.bg || c['editor.background'] || (dark ? '#1e1e1e' : '#ffffff'),
    fg: theme.fg || c['editor.foreground'] || (dark ? '#d4d4d4' : '#000000'),
    gutter: c['editorLineNumber.foreground'] || (dark ? '#858585' : '#237893'),
    widgetBg: c['editorWidget.background'] || (dark ? '#252526' : '#f3f3f3'),
    widgetBorder: c['editorWidget.border'] || c['widget.border'] || (dark ? '#454545' : '#c8c8c8'),
    widgetFg,
    inputBg: c['input.background'] || (dark ? '#3c3c3c' : '#ffffff'),
    inputFg: c['input.foreground'] || widgetFg,
    focus: c.focusBorder || (dark ? '#007fd4' : '#0090f1'),
    match: c['editor.findMatchBackground'] || (dark ? '#515c6a' : '#a8ac94'),
    matchHL: c['editor.findMatchHighlightBackground'] || '#ea5c0055',
    error: c['inputValidation.errorBorder'] || '#be1100',
    selection: c['editor.selectionBackground'] || (dark ? '#264f78' : '#add6ff'),
    // Editor-only colours.
    cursor: c['editorCursor.foreground'] || (dark ? '#aeafad' : '#000000'),
    lineHighlight: c['editor.lineHighlightBackground'] || (dark ? '#ffffff0a' : '#0000000a'),
    lineNumberActive: c['editorLineNumber.activeForeground'] || (dark ? '#c6c6c6' : '#0b216f'),
    indentGuide: c['editorIndentGuide.background1'] || c['editorIndentGuide.background'] || (dark ? '#404040' : '#d3d3d3'),
    bracketMatch: c['editorBracketMatch.background'] || (dark ? '#0064001a' : '#0064001a'),
    bracketMatchBorder: c['editorBracketMatch.border'] || (dark ? '#888888' : '#b9b9b9'),
    selectionHighlight: c['editor.selectionHighlightBackground'] || (dark ? '#add6ff26' : '#add6ff80'),
    findRange: c['editor.findRangeHighlightBackground'] || (dark ? '#3a3d4166' : '#b4b4b44d'),
  }
}

// Tokenizes the start of `code` (within the line budget) and returns flat spans for the host to colour:
// spans = [start, length, colourIndex, fontStyle, ...] in UTF-16 units; colourIndex -1 = default foreground.
// Grammar/theme scripts must already be loaded (see shikiPlan).
globalThis.shikiTokens = function (code, opts) {
  const budget = opts.highlightLines || 1200
  const lines = code.split('\n')
  const head = lines.length > budget ? lines.slice(0, budget).join('\n') : code
  const plan = JSON.parse(globalThis.shikiPlan(head, opts))
  const theme = globalThis.__T[plan.theme]
  const ui = uiColors(theme)
  const colors = [], index = {}, spans = []
  try {
    if (plan.lang && globalThis.__L[plan.lang]) {
      const registry = registryFor(plan.lang)
      const shikiTheme = registry.getTheme(theme.name) || registry.loadTheme(theme)
      registry.setTheme(shikiTheme)
      const tokens = tokenizeWithTheme(head, registry.getGrammar(plan.lang), shikiTheme, registry.getColorMap(), { tokenizeMaxLineLength: 10000 })
      const fg = ui.fg.toLowerCase()
      let lineStart = 0
      for (let i = 0; i < tokens.length; i++) {
        let off = lineStart
        for (const t of tokens[i]) {
          const len = t.content.length
          const col = t.color ? t.color.toLowerCase() : fg
          const style = t.fontStyle > 0 ? t.fontStyle : 0
          if (len && (col !== fg || style)) {
            let ci = -1
            if (col !== fg) { ci = index[col]; if (ci === undefined) { ci = index[col] = colors.length; colors.push(col) } }
            spans.push(off, len, ci, style)
          }
          off += len
        }
        lineStart += lines[i].length + 1
      }
    }
  } catch (e) { /* unhighlighted */ }
  return JSON.stringify({ lang: plan.lang, dark: theme.type !== 'light', colors, spans, ui })
}

// ---- Editor documents ----
// The editor keeps every line with the grammar state at its end, so an edit re-tokenizes from the edited line only
// until a line ends in the same state as before: every line after it then tokenizes exactly as it did.
const docs = {}
const MAX_LINE = 10000

globalThis.shikiLanguages = function () {
  return JSON.stringify(Object.keys(globalThis.__L || {}))
}

// `lang` is a grammar id (already loaded by the host) or '' for plain text.
globalThis.shikiDocOpen = function (id, lang, themeName, text) {
  const theme = globalThis.__T[themeName]
  const ui = uiColors(theme)
  const lines = text.split('\n')
  const doc = { lang: '', lines, states: new Array(lines.length), dirty: new Array(lines.length).fill(1), first: 0, colors: [] }
  if (lang && globalThis.__L[lang]) {
    try {
      const registry = registryFor(lang)
      doc.registry = registry
      doc.theme = registry.getTheme(theme.name) || registry.loadTheme(theme)
      registry.setTheme(doc.theme)
      doc.grammar = registry.getGrammar(lang)
      const replacements = resolveColorReplacements(doc.theme, {})
      doc.colors = registry.getColorMap().map(c => c ? applyColorReplacements(c, replacements) : null)
      doc.lang = lang
    } catch (e) { doc.grammar = null }
  }
  docs[id] = doc
  return JSON.stringify({ lang: doc.lang, dark: theme.type !== 'light', colors: doc.colors, ui })
}

globalThis.shikiDocClose = function (id) { delete docs[id] }

function spliceInto(arr, start, removed, items) {
  if (items.length < 50000) { arr.splice(start, removed, ...items); return arr }
  return arr.slice(0, start).concat(items, arr.slice(start + removed))
}

// Lines start ..< start+removed were replaced by `text` (the new lines joined by \n).
globalThis.shikiDocEdit = function (id, start, removed, text) {
  const d = docs[id]
  if (!d) return
  const ins = text.split('\n')
  if (ins.length === removed) {
    for (let k = 0; k < ins.length; k++) { d.lines[start + k] = ins[k]; d.dirty[start + k] = 1 }
  } else {
    d.lines = spliceInto(d.lines, start, removed, ins)
    d.states = spliceInto(d.states, start, removed, new Array(ins.length))
    d.dirty = spliceInto(d.dirty, start, removed, new Array(ins.length).fill(1))
  }
  if (start < d.first) d.first = start
}

// Tokenizes dirty lines from the first one down, for about `budget` ms. Returns an Int32Array:
// [more, rangeCount, (from, to)…, (line, column, length, colour, fontStyle)…]: `ranges` are the lines that were
// re-tokenized (the host resets them to the default colour first), spans only cover non-default tokens.
globalThis.shikiDocTokenize = function (id, budget) {
  const d = docs[id]
  if (!d || !d.grammar) return new Int32Array([0, 0])
  if (d.registry._squintTheme !== d.theme) { d.registry.setTheme(d.theme); d.registry._squintTheme = d.theme }
  const ranges = [], spans = []
  const n = d.lines.length
  const t0 = Date.now()
  let i = d.first, from = -1, work = 0
  while (i < n) {
    if (!d.dirty[i]) {
      if (from >= 0) { ranges.push(from, i); from = -1 }
      while (i < n && !d.dirty[i]) i++
      if (i >= n) break
      if (work > 0 && Date.now() - t0 > budget) break
    }
    if (from < 0) from = i
    const line = d.lines[i]
    const start = i === 0 ? INITIAL : d.states[i - 1]
    let next = start
    if (line.length > 0 && line.length < MAX_LINE) {
      const r = d.grammar.tokenizeLine2(line, start, 500)
      const t = r.tokens, count = t.length / 2
      for (let j = 0; j < count; j++) {
        const s = t[2 * j], e = j + 1 < count ? t[2 * j + 2] : line.length
        if (s >= e) continue
        const m = t[2 * j + 1]
        const fg = (m & 0x00FF8000) >>> 15, fs = (m & 0x00007800) >>> 11
        if (fg !== 1 || fs > 0) spans.push(i, s, e - s, fg, fs)
      }
      next = r.ruleStack
    } else if (line.length === 0) {
      next = d.grammar.tokenizeLine2('', start, 500).ruleStack
    }
    const old = d.states[i]
    d.states[i] = next
    d.dirty[i] = 0
    if (i + 1 < n && !(old && old.equals(next))) d.dirty[i + 1] = 1
    i++
    if ((++work & 15) === 0 && Date.now() - t0 > budget) break
  }
  if (from >= 0) ranges.push(from, i)
  d.first = i
  let more = 0
  for (let k = i; k < n; k++) if (d.dirty[k]) { more = 1; break }
  const out = new Int32Array(2 + ranges.length + spans.length)
  out[0] = more; out[1] = ranges.length / 2
  out.set(ranges, 2); out.set(spans, 2 + ranges.length)
  return out
}
