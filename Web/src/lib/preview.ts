// Builds the document shown in the chat's sandboxed preview frame.
//
// Agent-written HTML is untrusted, so it only ever runs inside a sandboxed frame (an opaque origin with no
// access to this app, its cookies, or its API). The frame loads the server's preview shell, whose own CSP
// carries the sandbox, and receives the document over postMessage. Local CSS/JS siblings are inlined because
// the shell can't fetch them, and a small bridge forwards the page's console to the chat.

export type PreviewSource =
  | { kind: 'code'; title: string; language: string; code: string }
  | { kind: 'mission'; missionID: string; entry?: string }
  | { kind: 'chat'; conversationID: string; entry?: string }

export type ConsoleLevel = 'log' | 'info' | 'warn' | 'error' | 'debug'

export interface PageConsoleMessage {
  level: ConsoleLevel
  text: string
  time: number
}

export const BRIDGE_TAG = '__agentsamPreview'
/** Must match PreviewFrame in Server/Sources/AgentSamServer/WebApp.swift. */
export const FRAME_URL = '/api/preview-frame'
export const FRAME_READY_TAG = '__agentsamPreviewReady'
export const FRAME_LOAD_TAG = '__agentsamPreviewLoad'

/** Extensions the preview reads from a mission's files. */
export const PREVIEW_TEXT_EXTENSIONS = new Set(['html', 'htm', 'css', 'js', 'mjs', 'json', 'svg', 'txt', 'md', 'csv', 'xml'])

export function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot < 0 ? '' : name.slice(dot + 1).toLowerCase()
}

export function isHTML(name: string): boolean {
  const ext = extensionOf(name)
  return ext === 'html' || ext === 'htm'
}

export function isPreviewableLanguage(language: string): boolean {
  return ['html', 'htm', 'svg', 'xml+svg'].includes(language.toLowerCase())
}

/** The page to open first: index.html at the shallowest depth, else the first HTML file. */
export function pickEntry(names: string[]): string | null {
  const pages = names.filter(isHTML).sort((a, b) => a.split('/').length - b.split('/').length || a.localeCompare(b))
  return pages.find((name) => /(^|\/)index\.html?$/i.test(name)) ?? pages[0] ?? null
}

const bridge = `<script>(function(){
  var tag=${JSON.stringify(BRIDGE_TAG)};
  function fmt(v){try{if(v instanceof Error)return v.name+': '+v.message;if(typeof v==='object'&&v!==null)return JSON.stringify(v);return String(v)}catch(e){return String(v)}}
  function send(level,args){try{parent.postMessage({tag:tag,level:level,text:Array.prototype.map.call(args,fmt).join(' ').slice(0,4000),time:Date.now()},'*')}catch(e){}}
  ['log','info','warn','error','debug'].forEach(function(level){var original=console[level];console[level]=function(){send(level,arguments);if(original)original.apply(console,arguments)}});
  addEventListener('error',function(e){send('error',[e.message+(e.lineno?' (line '+e.lineno+')':'')])});
  addEventListener('unhandledrejection',function(e){send('error',['Unhandled promise rejection: '+fmt(e.reason)])});
})();</script>`

/** Resolves `href` relative to the folder of `from`; null for remote, absolute, or escaping paths. */
export function resolveLocal(from: string, href: string): string | null {
  const clean = href.trim().split(/[?#]/)[0]
  if (!clean || /^[a-z][a-z0-9+.-]*:/i.test(clean) || clean.startsWith('//') || clean.startsWith('/')) return null
  const parts = from.split('/').slice(0, -1)
  for (const part of clean.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (!parts.length) return null
      parts.pop()
    } else parts.push(part)
  }
  return parts.join('/')
}

function attr(tag: string, name: string): string | null {
  const match = tag.match(new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i'))
  return match ? (match[2] ?? match[3] ?? match[4] ?? '') : null
}

function injectBridge(html: string): string {
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (head) => `${head}${bridge}`)
  if (/<html[^>]*>/i.test(html)) return html.replace(/<html[^>]*>/i, (open) => `${open}<head>${bridge}</head>`)
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">${bridge}</head><body>${html}</body></html>`
}

/** Inlines local stylesheets and scripts referenced by `entry`, then adds the console bridge. */
export function buildPreviewDocument(entry: string, files: Record<string, string>): string {
  let html = files[entry] ?? ''
  html = html.replace(/<link\b[^>]*>/gi, (tag) => {
    if (!/rel\s*=\s*["']?stylesheet/i.test(tag)) return tag
    const target = resolveLocal(entry, attr(tag, 'href') ?? '')
    if (!target || files[target] === undefined) return tag
    return `<style data-from="${target}">\n${files[target].replace(/<\/style/gi, '<\\/style')}\n</style>`
  })
  html = html.replace(/<script\b([^>]*)>\s*<\/script>/gi, (tag, attrs: string) => {
    const target = resolveLocal(entry, attr(` ${attrs}`, 'src') ?? '')
    if (!target || files[target] === undefined) return tag
    const type = attr(` ${attrs}`, 'type')
    return `<script${type ? ` type="${type}"` : ''} data-from="${target}">\n${files[target].replace(/<\/script/gi, '<\\/script')}\n</script>`
  })
  return injectBridge(html)
}

/** A code block from chat, as a full preview document. */
export function codePreviewDocument(language: string, code: string): string {
  const lang = language.toLowerCase()
  if (lang === 'svg' || lang === 'xml+svg') {
    return injectBridge(`<style>html,body{margin:0;min-height:100%;display:grid;place-items:center;background:#fff}svg{max-width:100%;height:auto}</style>${code}`)
  }
  return injectBridge(code)
}

export function isConsoleMessage(data: unknown): data is PageConsoleMessage & { tag: string } {
  if (!data || typeof data !== 'object') return false
  const value = data as Record<string, unknown>
  return value.tag === BRIDGE_TAG && typeof value.text === 'string' && typeof value.level === 'string'
}
