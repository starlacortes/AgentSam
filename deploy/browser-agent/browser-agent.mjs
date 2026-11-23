#!/usr/bin/env node
// Ada's browser agent: starts Chromium in the visible window and carries out Ada's browser actions
// in it. It needs nothing but Node itself.
//
// - Chromium is driven over --remote-debugging-pipe, so the DevTools protocol is reachable only
//   through this process: no debugging port is open to other users on the machine.
// - Ada's server reaches the agent on 127.0.0.1 only, through the workstation's SSH link
//   (`ssh -W 127.0.0.1:5978`). Every request carries the browser's VNC password as its token,
//   the same secret that already gives full control of the window.
// - One request per connection: a JSON line in, a JSON line out.
// - The agent keeps who is in control (ada, paused, person) and refuses Ada's actions unless she is.
// - It never types into password or one-time-code fields and never reports what they hold.
//   There is no way to read cookies or run arbitrary scripts through it.

import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { readFileSync, rmSync, mkdirSync, chmodSync, existsSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

// ---------------------------------------------------------------------------------------------
// Page scripts. They run inside the page, so they must be self-contained functions.

/** Gives every visible interactive element a stable number and returns the page as an outline. */
export function snapshotScript(maxChars, query) {
  const state = (window.__ada = window.__ada || { next: 1, refs: new Map() })
  const lines = []
  let size = 0
  let cut = false
  const push = (line) => {
    if (cut) return
    if (size + line.length > maxChars) { cut = true; return }
    lines.push(line)
    size += line.length + 1
  }
  const clean = (text, limit = 160) => {
    const t = (text || '').replace(/\s+/g, ' ').trim()
    return t.length > limit ? t.slice(0, limit - 1) + '…' : t
  }
  const visible = (el) => {
    if (el.getAttribute && el.getAttribute('aria-hidden') === 'true') return false
    const style = getComputedStyle(el)
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false
    if (Number(style.opacity) === 0 && el.tagName !== 'INPUT') return false
    const rects = el.getClientRects()
    if (!rects.length) return false
    const r = el.getBoundingClientRect()
    return r.width > 1 && r.height > 1
  }
  const roles = new Set(['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'switch', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton', 'treeitem'])
  const interactive = (el) => {
    const tag = el.tagName
    if (tag === 'A' && el.hasAttribute('href')) return true
    if (tag === 'BUTTON' || tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'SUMMARY') return true
    if (tag === 'INPUT') return el.type !== 'hidden'
    if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) return true
    const role = el.getAttribute('role')
    return !!role && roles.has(role)
  }
  const sensitive = (el) => {
    if (el.tagName !== 'INPUT') return false
    const type = (el.type || '').toLowerCase()
    const auto = (el.getAttribute('autocomplete') || '').toLowerCase()
    return type === 'password' || auto.includes('one-time-code') || auto.includes('current-password') || auto.includes('new-password')
  }
  const nameOf = (el) => {
    const aria = el.getAttribute('aria-label')
    if (aria) return clean(aria)
    const labelled = el.getAttribute('aria-labelledby')
    if (labelled) {
      const text = labelled.split(/\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' ')
      if (text.trim()) return clean(text)
    }
    if (el.labels && el.labels.length) return clean(el.labels[0].innerText)
    if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type)) return clean(el.value)
    if (el.tagName === 'INPUT' && el.type === 'image') return clean(el.alt)
    const text = el.innerText || el.textContent
    if (text && text.trim()) return clean(text)
    return clean(el.getAttribute('placeholder') || el.getAttribute('title') || el.getAttribute('alt') || el.querySelector?.('img[alt]')?.alt || el.getAttribute('name') || '')
  }
  const kindOf = (el) => {
    const role = el.getAttribute('role')
    if (role) return role
    const tag = el.tagName
    if (tag === 'A') return 'link'
    if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button'
    if (tag === 'SELECT') return 'select'
    if (tag === 'TEXTAREA') return 'textbox'
    if (tag === 'INPUT') {
      const type = (el.type || 'text').toLowerCase()
      if (['submit', 'button', 'reset', 'image'].includes(type)) return 'button'
      if (type === 'checkbox' || type === 'radio') return type
      if (type === 'password') return 'password field'
      return type === 'text' ? 'textbox' : type + ' field'
    }
    if (el.isContentEditable) return 'textbox'
    return tag.toLowerCase()
  }
  const refOf = (el) => {
    let ref = el.getAttribute('data-ada-ref')
    if (!ref || state.refs.get(ref) !== el) {
      ref = String(state.next++)
      el.setAttribute('data-ada-ref', ref)
      state.refs.set(ref, el)
    }
    return ref
  }
  const describe = (el) => {
    const ref = refOf(el)
    const kind = kindOf(el)
    let line = `[${ref}] ${kind} "${nameOf(el)}"`
    if (sensitive(el)) return line + ' (Ada cannot type here; the person signs in)'
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
      const type = (el.type || '').toLowerCase()
      if (type === 'checkbox' || type === 'radio') line += el.checked ? ' checked' : ' unchecked'
      else if (!['submit', 'button', 'reset', 'image', 'file'].includes(type)) {
        if (el.value) line += ` value="${clean(el.value, 80)}"`
        else if (el.placeholder && !line.includes(clean(el.placeholder))) line += ` placeholder="${clean(el.placeholder, 60)}"`
      }
    } else if (el.tagName === 'SELECT') {
      const options = Array.from(el.options).slice(0, 12).map((o) => clean(o.text, 40))
      line += ` selected="${clean(el.selectedOptions[0]?.text || '', 60)}" options: ${options.join(' | ')}${el.options.length > 12 ? ' | …' : ''}`
    } else if (el.isContentEditable) {
      const text = clean(el.innerText, 80)
      if (text) line += ` text="${text}"`
    } else if (el.tagName === 'A') {
      const href = el.getAttribute('href') || ''
      if (href && !href.startsWith('javascript:') && href !== '#') {
        try {
          const url = new URL(href, location.href)
          if (url.host !== location.host) line += ` → ${url.host}`
        } catch {}
      }
    }
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' (disabled)'
    if (el.getAttribute('aria-expanded') === 'true') line += ' (expanded)'
    if (el.getAttribute('aria-selected') === 'true' || el.getAttribute('aria-current')) line += ' (current)'
    return line
  }
  const blocks = new Set(['P', 'DIV', 'LI', 'TR', 'TD', 'TH', 'SECTION', 'ARTICLE', 'HEADER', 'FOOTER', 'NAV', 'MAIN', 'ASIDE', 'FORM', 'TABLE', 'UL', 'OL', 'DL', 'DT', 'DD', 'BLOCKQUOTE', 'PRE', 'FIGURE', 'FIGCAPTION', 'LABEL', 'FIELDSET', 'BR', 'HR'])
  const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'CANVAS', 'HEAD', 'META', 'LINK'])
  let text = ''
  const flush = () => {
    const t = clean(text, 600)
    if (t) push(t)
    text = ''
  }
  const walk = (node) => {
    if (cut) return
    if (node.nodeType === Node.TEXT_NODE) { text += ' ' + node.nodeValue; return }
    if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return
    const el = node
    if (el.nodeType === Node.ELEMENT_NODE) {
      if (skip.has(el.tagName)) return
      if (!visible(el)) return
      if (el.tagName === 'IFRAME') { flush(); push(`[frame ${clean(el.title || el.name || el.src, 80)}: its contents are not readable]`); return }
      if (interactive(el)) { flush(); push(describe(el)); return }
      const heading = /^H[1-6]$/.test(el.tagName)
      if (heading) { flush(); const h = clean(el.innerText, 200); if (h) push('#'.repeat(Number(el.tagName[1])) + ' ' + h); return }
      if (el.tagName === 'IMG') { const alt = clean(el.alt, 100); if (alt) text += ` [image: ${alt}]`; return }
      if (blocks.has(el.tagName)) flush()
    }
    for (const child of el.childNodes) walk(child)
    if (el.shadowRoot) for (const child of el.shadowRoot.childNodes) walk(child)
    if (el.nodeType === Node.ELEMENT_NODE && blocks.has(el.tagName)) flush()
  }
  if (document.body) walk(document.body)
  flush()
  let out = lines
  if (query) {
    const q = String(query).toLowerCase()
    out = lines.filter((line) => line.toLowerCase().includes(q))
  }
  const scrolled = Math.round(window.scrollY)
  const height = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)
  return {
    url: location.href,
    title: document.title,
    text: out.join('\n'),
    cut,
    position: height > innerHeight ? `${Math.min(100, Math.round(((scrolled + innerHeight) / height) * 100))}% of the page is above the bottom of the window` : 'the whole page fits in the window',
  }
}

/** What an element is, so Ada's server can decide whether acting on it needs an approval. */
export function describeScript(ref) {
  const state = window.__ada
  const el = ref ? state?.refs.get(String(ref)) : document.activeElement
  if (!el || !el.isConnected) return { found: false }
  const clean = (t, n = 160) => { t = (t || '').replace(/\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n - 1) + '…' : t }
  const name = clean(el.getAttribute('aria-label') || (el.labels && el.labels[0]?.innerText) || (el.tagName === 'INPUT' ? el.value || el.placeholder : '') || el.innerText || el.textContent || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || '')
  const type = (el.type || '').toLowerCase()
  const auto = (el.getAttribute('autocomplete') || '').toLowerCase()
  const form = el.form || el.closest('form')
  const fields = form ? Array.from(form.querySelectorAll('input')) : []
  const card = (input) => {
    const a = (input.getAttribute('autocomplete') || '').toLowerCase()
    const key = `${input.name} ${input.id} ${input.getAttribute('aria-label') || ''}`.toLowerCase()
    return a.startsWith('cc-') || /card.?num|cc.?num|cvv|cvc|security.?code|expir/.test(key)
  }
  const isSubmit = (el.tagName === 'BUTTON' && (!el.getAttribute('type') || el.getAttribute('type').toLowerCase() === 'submit') && !!form)
    || (el.tagName === 'INPUT' && (type === 'submit' || type === 'image'))
  let href = ''
  if (el.tagName === 'A') {
    const raw = el.getAttribute('href') || ''
    try { href = raw && !raw.startsWith('javascript:') ? new URL(raw, location.href).href : '' } catch {}
  }
  return {
    found: true,
    ref: el.getAttribute('data-ada-ref') || '',
    tag: el.tagName.toLowerCase(),
    type,
    role: el.getAttribute('role') || '',
    name,
    href,
    url: location.href,
    title: document.title,
    inForm: !!form,
    formMethod: form ? (form.getAttribute('method') || 'get').toLowerCase() : '',
    formAction: form ? (form.action || '') : '',
    formHasPassword: fields.some((f) => (f.type || '').toLowerCase() === 'password'),
    formHasCard: fields.some(card),
    isSubmit,
    isPassword: type === 'password' || auto.includes('password') || auto.includes('one-time-code'),
    isCard: el.tagName === 'INPUT' && card(el),
    editable: el.tagName === 'TEXTAREA' || el.isContentEditable || (el.tagName === 'INPUT' && !['submit', 'button', 'reset', 'image', 'checkbox', 'radio', 'file', 'hidden'].includes(type)),
  }
}

/** Scrolls an element into view and says where to click it, or what covers it. */
export function pointScript(ref) {
  const el = window.__ada?.refs.get(String(ref))
  if (!el || !el.isConnected) return { found: false }
  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
  const r = el.getBoundingClientRect()
  const x = r.left + r.width / 2
  const y = r.top + r.height / 2
  const top = document.elementFromPoint(x, y)
  const reaches = !!top && (top === el || el.contains(top) || top.contains(el) || (top.closest && top.closest('label') && top.closest('label').control === el))
  let cover = ''
  if (!reaches && top) cover = ((top.getAttribute('aria-label') || top.innerText || top.tagName) + '').replace(/\s+/g, ' ').trim().slice(0, 80)
  return { found: true, x, y, reaches, cover }
}

/** Focuses a field, and empties it first when asked. */
export function focusScript(ref, clear) {
  const el = window.__ada?.refs.get(String(ref))
  if (!el || !el.isConnected) return { found: false }
  el.scrollIntoView({ block: 'center', behavior: 'instant' })
  el.focus()
  if (clear) {
    if ('value' in el && el.tagName !== 'SELECT') {
      el.select?.()
      el.value = ''
      el.dispatchEvent(new Event('input', { bubbles: true }))
    } else if (el.isContentEditable) {
      document.getSelection()?.selectAllChildren(el)
      document.execCommand('delete')
    }
  }
  return { found: true, focused: document.activeElement === el || el.contains(document.activeElement) }
}

/** Picks an option in a select by its visible text or value. */
export function selectScript(ref, option) {
  const el = window.__ada?.refs.get(String(ref))
  if (!el || !el.isConnected) return { found: false }
  if (el.tagName !== 'SELECT') return { found: true, ok: false, message: 'That element is not a drop-down list; click it instead.' }
  const wanted = String(option).trim().toLowerCase()
  const options = Array.from(el.options)
  const match = options.find((o) => o.text.trim().toLowerCase() === wanted) || options.find((o) => o.value.toLowerCase() === wanted) || options.find((o) => o.text.toLowerCase().includes(wanted))
  if (!match) return { found: true, ok: false, message: 'No option matches. Options: ' + options.slice(0, 30).map((o) => o.text.trim()).join(' | ') }
  el.value = match.value
  el.dispatchEvent(new Event('input', { bubbles: true }))
  el.dispatchEvent(new Event('change', { bubbles: true }))
  return { found: true, ok: true, chosen: match.text.trim() }
}

// ---------------------------------------------------------------------------------------------
// Rules that need no browser, exported for the tests.

/** Addresses Ada may open: the public web only, never browser-internal or local pages. */
export function allowedURL(raw) {
  let url
  try { url = new URL(String(raw).trim()) } catch {
    try { url = new URL('https://' + String(raw).trim()) } catch { return null }
  }
  if (url.protocol === 'about:' && url.href === 'about:blank') return url.href
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null
  if (url.username || url.password) return null
  return url.href
}

export const CONTROL_STATES = ['ada', 'paused', 'person']

/** Operations that only read the page, and so also run while Ada is paused. */
export const READ_OPS = new Set(['look', 'describe', 'tabs', 'screenshot', 'wait', 'status'])

/** Why Ada may not run `op` right now, or null when she may. */
export function controlProblem(control, op) {
  if (op === 'status' || op === 'control') return null
  if (control === 'person') return 'The person has taken control of the browser. Stop using it now and tell them you will continue when they hand it back.'
  if (control === 'paused' && !READ_OPS.has(op)) return 'The browser is paused. You can look at the page, but wait for the person to resume before you act.'
  return null
}

const KEYS = {
  enter: { key: 'Enter', code: 'Enter', keyCode: 13, text: '\r' },
  tab: { key: 'Tab', code: 'Tab', keyCode: 9 },
  escape: { key: 'Escape', code: 'Escape', keyCode: 27 },
  backspace: { key: 'Backspace', code: 'Backspace', keyCode: 8 },
  delete: { key: 'Delete', code: 'Delete', keyCode: 46 },
  space: { key: ' ', code: 'Space', keyCode: 32, text: ' ' },
  arrowup: { key: 'ArrowUp', code: 'ArrowUp', keyCode: 38 },
  arrowdown: { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40 },
  arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37 },
  arrowright: { key: 'ArrowRight', code: 'ArrowRight', keyCode: 39 },
  pageup: { key: 'PageUp', code: 'PageUp', keyCode: 33 },
  pagedown: { key: 'PageDown', code: 'PageDown', keyCode: 34 },
  home: { key: 'Home', code: 'Home', keyCode: 36 },
  end: { key: 'End', code: 'End', keyCode: 35 },
}

export function keyFor(name) {
  return KEYS[String(name || '').toLowerCase().replace(/[\s_-]/g, '')] || null
}

// ---------------------------------------------------------------------------------------------
// The DevTools connection over the pipe.

class Chromium {
  constructor({ binary, profile, display, size, headless, quiet = false, extraArgs = [] }) {
    this.quiet = quiet
    this.binary = binary
    this.profile = profile
    this.display = display
    this.size = size
    this.headless = headless
    this.extraArgs = extraArgs
    this.nextID = 1
    this.pending = new Map()
    this.buffer = ''
    this.sessions = new Map() // targetId -> sessionId
    this.current = null
    this.onExit = () => {}
  }

  start() {
    const [w, h] = this.size.split('x')
    const args = [
      `--user-data-dir=${this.profile}`,
      '--remote-debugging-pipe',
      '--no-first-run', '--no-default-browser-check',
      '--password-store=basic',
      '--window-position=0,0', `--window-size=${w},${h}`,
      '--disable-features=Translate',
      ...(this.headless ? ['--headless=new', '--no-sandbox'] : []),
      ...this.extraArgs,
      'about:blank',
    ]
    const env = { ...process.env }
    if (this.display) env.DISPLAY = this.display
    this.child = spawn(this.binary, args, { env, stdio: ['ignore', 'ignore', this.quiet ? 'ignore' : 'inherit', 'pipe', 'pipe'] })
    this.child.on('exit', (code, signal) => {
      for (const { reject } of this.pending.values()) reject(new Error('The browser closed.'))
      this.pending.clear()
      this.onExit(code, signal)
    })
    this.writer = this.child.stdio[3]
    this.child.stdio[4].on('data', (chunk) => this.read(chunk))
  }

  read(chunk) {
    this.buffer += chunk.toString('utf8')
    let end
    while ((end = this.buffer.indexOf('\0')) >= 0) {
      const raw = this.buffer.slice(0, end)
      this.buffer = this.buffer.slice(end + 1)
      let message
      try { message = JSON.parse(raw) } catch { continue }
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id)
        this.pending.delete(message.id)
        if (message.error) reject(new Error(message.error.message || 'DevTools error'))
        else resolve(message.result || {})
      } else if (message.method === 'Target.detachedFromTarget') {
        for (const [target, session] of this.sessions) if (session === message.params.sessionId) this.sessions.delete(target)
      } else if (message.method === 'Target.targetDestroyed') {
        this.sessions.delete(message.params.targetId)
        if (this.current === message.params.targetId) this.current = null
      }
    }
  }

  send(method, params = {}, sessionId, timeout = 30000) {
    return new Promise((resolve, reject) => {
      const id = this.nextID++
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`The browser did not answer ${method} in time.`))
      }, timeout)
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      const message = { id, method, params }
      if (sessionId) message.sessionId = sessionId
      this.writer.write(JSON.stringify(message) + '\0')
    })
  }

  async ready() {
    for (let i = 0; i < 100; i++) {
      try {
        await this.send('Browser.getVersion', {}, undefined, 2000)
        await this.send('Target.setDiscoverTargets', { discover: true })
        return
      } catch { await sleep(100) }
    }
    throw new Error('Chromium did not start.')
  }

  async pages() {
    const { targetInfos } = await this.send('Target.getTargets')
    return targetInfos.filter((t) => t.type === 'page' && !t.url.startsWith('devtools://'))
  }

  async session(targetId) {
    if (this.sessions.has(targetId)) return this.sessions.get(targetId)
    const { sessionId } = await this.send('Target.attachToTarget', { targetId, flatten: true })
    this.sessions.set(targetId, sessionId)
    await this.send('Page.enable', {}, sessionId).catch(() => {})
    await this.send('Runtime.enable', {}, sessionId).catch(() => {})
    return sessionId
  }

  /** The tab Ada works in: the one she last chose, else the first open page. */
  async page() {
    const pages = await this.pages()
    let target = pages.find((p) => p.targetId === this.current) || pages[0]
    if (!target) {
      const { targetId } = await this.send('Target.createTarget', { url: 'about:blank' })
      target = { targetId }
    }
    this.current = target.targetId
    return { targetId: target.targetId, session: await this.session(target.targetId) }
  }

  async evaluate(session, fn, ...args) {
    const expression = `(${fn.toString()})(${args.map((a) => JSON.stringify(a ?? null)).join(',')})`
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, session)
    if (result.exceptionDetails) throw new Error('The page refused the script: ' + (result.exceptionDetails.exception?.description || result.exceptionDetails.text || 'error').slice(0, 200))
    return result.result?.value
  }

  async settle(session, timeout = 10000) {
    const start = Date.now()
    await sleep(250)
    while (Date.now() - start < timeout) {
      try {
        const state = await this.send('Runtime.evaluate', { expression: 'document.readyState', returnByValue: true }, session, 3000)
        if (state.result?.value === 'complete') break
      } catch { /* navigating */ }
      await sleep(200)
    }
    await sleep(300)
  }

  stop() {
    try { this.child?.kill('SIGTERM') } catch {}
  }
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)) }

// ---------------------------------------------------------------------------------------------
// The agent: one browser, one control state, and the operations Ada's server may ask for.

export class BrowserAgent {
  constructor(options) {
    this.options = options
    this.control = 'ada'
    this.chromium = null
    this.restarting = false
    this.queue = Promise.resolve()
  }

  async start() {
    this.chromium = new Chromium(this.options)
    this.chromium.onExit = () => {
      if (!this.restarting && this.options.onBrowserExit) this.options.onBrowserExit()
    }
    this.chromium.start()
    await this.chromium.ready()
  }

  stop() { this.chromium?.stop() }

  /** Runs requests one at a time, so two calls never interleave their clicks. */
  handle(request) {
    const run = this.queue.then(() => this.run(request))
    this.queue = run.catch(() => {})
    return run
  }

  async run(request) {
    const op = String(request.op || '')
    const problem = request.override ? null : controlProblem(this.control, op)
    if (problem) return { ok: false, refused: true, control: this.control, message: problem }
    try {
      const result = await this.dispatch(op, request)
      return { ok: true, control: this.control, ...result }
    } catch (error) {
      return { ok: false, control: this.control, message: String(error?.message || error) }
    }
  }

  async outline(session, maxChars = 6000, query) {
    const snap = await this.chromium.evaluate(session, snapshotScript, maxChars, query || null)
    return snap
  }

  /** Checks that an approved action still meets the same page and element it was approved on. */
  async checkExpected(session, request) {
    const expect = request.expect
    if (!expect) return null
    const info = await this.chromium.evaluate(session, describeScript, request.ref ?? null)
    const sameURL = (a, b) => String(a || '').split('#')[0] === String(b || '').split('#')[0]
    if (!info?.found || !sameURL(info.url, expect.url) || (expect.name !== undefined && info.name !== expect.name)) {
      return 'The page changed after this was approved, so nothing was done. Look at the page again and ask again if it is still needed.'
    }
    return null
  }

  async dispatch(op, request) {
    const c = this.chromium
    switch (op) {
      case 'status': {
        const pages = await c.pages()
        const current = pages.find((p) => p.targetId === c.current) || pages[0]
        return { tabs: pages.length, url: current?.url || '', title: current?.title || '' }
      }
      case 'control': {
        const state = String(request.state || '')
        if (!CONTROL_STATES.includes(state)) throw new Error('Unknown control state.')
        this.control = state
        return {}
      }
      case 'open': {
        const url = allowedURL(request.url)
        if (!url) throw new Error('Only http and https addresses can be opened.')
        if (request.newTab) {
          const { targetId } = await c.send('Target.createTarget', { url })
          c.current = targetId
          await c.send('Target.activateTarget', { targetId }).catch(() => {})
          const session = await c.session(targetId)
          await c.settle(session, 15000)
          return { page: await this.outline(session, request.maxChars) }
        }
        const { session } = await c.page()
        const nav = await c.send('Page.navigate', { url }, session)
        if (nav.errorText) throw new Error(`The page did not open: ${nav.errorText}`)
        await c.settle(session, 15000)
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'look': {
        const { session } = await c.page()
        return { page: await this.outline(session, request.maxChars || 12000, request.query) }
      }
      case 'describe': {
        const { session } = await c.page()
        return { element: await c.evaluate(session, describeScript, request.ref ?? null) }
      }
      case 'click': {
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const point = await c.evaluate(session, pointScript, request.ref)
        if (!point?.found) throw new Error(`There is no element [${request.ref}] on this page any more. Look at the page again.`)
        await sleep(150)
        const again = await c.evaluate(session, pointScript, request.ref)
        if (!again.reaches) throw new Error(`Element [${request.ref}] is covered by "${again.cover}". Close or accept that first.`)
        const before = new Set((await c.pages()).map((p) => p.targetId))
        const base = { x: again.x, y: again.y, button: 'left', clickCount: 1 }
        await c.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: base.x, y: base.y }, session)
        await c.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...base }, session)
        await c.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...base }, session)
        await c.settle(session)
        const { session: after } = await this.followNewTab(session, before)
        return { page: await this.outline(after, request.maxChars) }
      }
      case 'type': {
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const info = await c.evaluate(session, describeScript, request.ref)
        if (!info?.found) throw new Error(`There is no element [${request.ref}] on this page any more. Look at the page again.`)
        if (info.isPassword) throw new Error('Ada never types into password or code fields. Ask the person to take over the browser and sign in themselves.')
        if (!info.editable) throw new Error(`Element [${request.ref}] is not a text field.`)
        const focus = await c.evaluate(session, focusScript, request.ref, !!request.clear)
        if (!focus?.focused) throw new Error(`Element [${request.ref}] could not be focused.`)
        const text = String(request.text ?? '')
        if (text) await c.send('Input.insertText', { text }, session)
        if (request.submit) {
          await this.press(session, KEYS.enter)
          await c.settle(session)
        } else {
          await sleep(200)
        }
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'select': {
        const { session } = await c.page()
        const result = await c.evaluate(session, selectScript, request.ref, String(request.option ?? ''))
        if (!result?.found) throw new Error(`There is no element [${request.ref}] on this page any more. Look at the page again.`)
        if (!result.ok) throw new Error(result.message)
        await c.settle(session, 4000)
        return { chosen: result.chosen, page: await this.outline(session, request.maxChars) }
      }
      case 'key': {
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const key = keyFor(request.key)
        if (!key) throw new Error('Unknown key. Use Enter, Tab, Escape, Backspace, Delete, Space, an arrow key, PageUp, PageDown, Home or End.')
        await this.press(session, key)
        await c.settle(session, key.key === 'Enter' ? 10000 : 2000)
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'scroll': {
        const { session } = await c.page()
        const pages = Math.max(0.25, Math.min(10, Number(request.pages) || 1))
        const [w, h] = this.options.size.split('x').map(Number)
        const dy = (request.direction === 'up' ? -1 : 1) * Math.round(h * 0.8 * pages)
        await c.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: Math.round(w / 2), y: Math.round(h / 2), deltaX: 0, deltaY: dy }, session)
        await sleep(500)
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'history': {
        const { session } = await c.page()
        const action = String(request.action || '')
        if (action === 'reload') {
          await c.send('Page.reload', {}, session)
        } else {
          const { currentIndex, entries } = await c.send('Page.getNavigationHistory', {}, session)
          const index = currentIndex + (action === 'back' ? -1 : action === 'forward' ? 1 : 0)
          if (!['back', 'forward'].includes(action)) throw new Error('Use back, forward or reload.')
          if (index < 0 || index >= entries.length) throw new Error(`There is no page to go ${action} to.`)
          await c.send('Page.navigateToHistoryEntry', { entryId: entries[index].id }, session)
        }
        await c.settle(session)
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'tabs': {
        const pages = await c.pages()
        if (!c.current && pages[0]) c.current = pages[0].targetId
        const action = String(request.action || 'list')
        const index = Number(request.tab)
        if (action === 'switch' || action === 'close') {
          const target = pages[index - 1]
          if (!target) throw new Error(`There is no tab ${request.tab}. Tabs are numbered from 1.`)
          if (controlProblem(this.control, 'click') && !request.override) throw new Error(controlProblem(this.control, 'click'))
          if (action === 'switch') {
            c.current = target.targetId
            await c.send('Target.activateTarget', { targetId: target.targetId })
          } else {
            if (pages.length === 1) {
              const { session } = await c.page()
              await c.send('Page.navigate', { url: 'about:blank' }, session)
            } else {
              await c.send('Target.closeTarget', { targetId: target.targetId })
              if (c.current === target.targetId) c.current = null
            }
          }
        }
        const now = await c.pages()
        const current = c.current || now[0]?.targetId
        return { tabs: now.map((p, i) => ({ number: i + 1, title: p.title, url: p.url, current: p.targetId === current })) }
      }
      case 'wait': {
        const { session } = await c.page()
        const seconds = Math.max(0, Math.min(30, Number(request.seconds) || (request.text ? 15 : 2)))
        const deadline = Date.now() + seconds * 1000
        if (request.text) {
          const wanted = String(request.text).toLowerCase()
          while (Date.now() < deadline) {
            const text = await c.evaluate(session, () => document.body ? document.body.innerText : '').catch(() => '')
            if (String(text).toLowerCase().includes(wanted)) return { found: true, page: await this.outline(session, request.maxChars) }
            await sleep(500)
          }
          return { found: false, page: await this.outline(session, request.maxChars) }
        }
        await sleep(seconds * 1000)
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'screenshot': {
        const { session } = await c.page()
        const shot = await c.send('Page.captureScreenshot', { format: 'jpeg', quality: 70 }, session)
        const info = await c.evaluate(session, () => ({ url: location.href, title: document.title }))
        return { jpeg: shot.data, url: info.url, title: info.title }
      }
      case 'erase': {
        // Signs out of everything by deleting the profile, then starts a fresh window.
        this.restarting = true
        try {
          c.stop()
          await sleep(1500)
          rmSync(this.options.profile, { recursive: true, force: true })
          mkdirSync(this.options.profile, { recursive: true })
          chmodSync(this.options.profile, 0o700)
          await this.start()
        } finally {
          this.restarting = false
        }
        this.control = 'ada'
        return { message: 'Every sign-in in the browser was erased and a fresh window was opened.' }
      }
      default:
        throw new Error(`Unknown browser operation: ${op}`)
    }
  }

  async press(session, key) {
    const base = { key: key.key, code: key.code, windowsVirtualKeyCode: key.keyCode, nativeVirtualKeyCode: key.keyCode }
    await this.chromium.send('Input.dispatchKeyEvent', { type: key.text ? 'keyDown' : 'rawKeyDown', ...base, ...(key.text ? { text: key.text, unmodifiedText: key.text } : {}) }, session)
    await this.chromium.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base }, session)
  }

  /** A click that opened a new tab moves Ada there, as it would move a person. */
  async followNewTab(session, before) {
    const pages = await this.chromium.pages()
    const fresh = pages.filter((p) => !before.has(p.targetId))
    if (fresh.length === 1) {
      this.chromium.current = fresh[0].targetId
      const next = await this.chromium.session(fresh[0].targetId)
      await this.chromium.settle(next)
      return { session: next }
    }
    return { session }
  }
}

// ---------------------------------------------------------------------------------------------
// The control socket.

export function serve(agent, { port, host = '127.0.0.1', token }) {
  const server = createServer({ allowHalfOpen: true }, (socket) => {
    let data = ''
    socket.setEncoding('utf8')
    socket.setTimeout(120000, () => socket.destroy())
    socket.on('data', async (chunk) => {
      data += chunk
      if (data.length > 1_000_000) { socket.destroy(); return }
      const end = data.indexOf('\n')
      if (end < 0) return
      const line = data.slice(0, end)
      data = ''
      socket.removeAllListeners('data')
      let request
      try { request = JSON.parse(line) } catch { socket.end(JSON.stringify({ ok: false, message: 'Bad request.' }) + '\n'); return }
      if (!token || typeof request.token !== 'string' || !safeEqual(request.token, token)) {
        socket.end(JSON.stringify({ ok: false, message: 'Wrong browser token.' }) + '\n')
        return
      }
      const reply = await agent.handle(request)
      socket.end(JSON.stringify(reply) + '\n')
    })
    socket.on('error', () => {})
  })
  server.listen(port, host)
  return server
}

function safeEqual(a, b) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

async function main() {
  const home = process.env.ADA_BROWSER_HOME || '/var/lib/ada-browser'
  const tokenFile = process.env.ADA_BROWSER_TOKEN_FILE || `${home}/vnc-password.txt`
  const token = readFileSync(tokenFile, 'utf8').trim()
  if (!token) throw new Error(`${tokenFile} is empty.`)
  const profile = process.env.ADA_BROWSER_PROFILE || `${home}/profiles/main`
  if (!existsSync(profile)) mkdirSync(profile, { recursive: true })
  chmodSync(profile, 0o700)
  const agent = new BrowserAgent({
    binary: process.env.ADA_BROWSER_CHROMIUM || 'chromium',
    profile,
    display: process.env.DISPLAY,
    size: process.env.ADA_BROWSER_SIZE || '1280x800',
    headless: process.env.ADA_BROWSER_HEADLESS === '1',
    onBrowserExit: () => { console.error('Chromium exited.'); process.exit(1) },
  })
  await agent.start()
  const server = serve(agent, { port: Number(process.env.ADA_BROWSER_AGENT_PORT || 5978), token })
  const quit = () => { server.close(); agent.stop(); setTimeout(() => process.exit(0), 500) }
  process.on('SIGTERM', quit)
  process.on('SIGINT', quit)
  console.error('Ada\'s browser agent is ready.')
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  main().catch((error) => { console.error(String(error?.message || error)); process.exit(1) })
}
