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
import { readFileSync, rmSync, mkdirSync, chmodSync, existsSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, basename } from 'node:path'
import { pathToFileURL } from 'node:url'

// ---------------------------------------------------------------------------------------------
// Page scripts. They run inside the page, so they must be self-contained functions.

/**
 * Gives every visible interactive element a stable number and returns the page as an outline.
 * Each frame of the page runs it on its own; `prefix` is the frame's number ("2.") so refs inside
 * frames read like [2.5].
 */
export function snapshotScript(maxChars, query, prefix) {
  prefix = prefix || ''
  if (prefix && (innerWidth < 2 || innerHeight < 2)) return { url: location.href, title: document.title, text: '', cut: false, position: '' }
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
    let line = `[${prefix}${ref}] ${kind} "${nameOf(el)}"`
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
      if (el.tagName === 'IFRAME') { flush(); push(`[frame "${clean(el.title || el.name || el.src, 80)}": its contents are listed after the page]`); return }
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

/**
 * What an element is, so Ada's server can decide whether acting on it needs an approval. With
 * `climb`, a point that hit text inside a button or link describes that button or link.
 */
export function describeElement(el, climb) {
  if (el && el.nodeType === 3) el = el.parentElement
  if (!el || el.nodeType !== 1 || !el.isConnected) return { found: false }
  if (climb && el.closest) {
    el = el.closest('a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=menuitem],[role=tab],[role=checkbox],[role=radio],[role=option],[role=switch],[contenteditable=""],[contenteditable=true]') || el
  }
  const clean = (t, n = 160) => { t = (t || '').replace(/\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n - 1) + '…' : t }
  const sensitiveField = (input) => {
    const t = (input.type || '').toLowerCase()
    const a = (input.getAttribute('autocomplete') || '').toLowerCase()
    return (t === 'password' || a.includes('password') || a.includes('one-time-code'))
  }
  // A password field shows its own label only, never its value.
  const name = sensitiveField(el)
    ? clean(el.getAttribute('aria-label') || (el.labels && el.labels[0]?.innerText) || el.placeholder || el.getAttribute('name') || '')
    : clean(el.getAttribute('aria-label') || (el.labels && el.labels[0]?.innerText) || (el.tagName === 'INPUT' ? el.value || el.placeholder : '') || el.innerText || el.textContent || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || '')
  const type = (el.type || '').toLowerCase()
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
    origin: location.origin,
    title: document.title,
    inFrame: window !== window.top,
    inForm: !!form,
    formMethod: form ? (form.getAttribute('method') || 'get').toLowerCase() : '',
    formAction: form ? (form.action || '') : '',
    formHasPassword: fields.some((f) => (f.type || '').toLowerCase() === 'password'),
    formHasCard: fields.some(card),
    isSubmit,
    isPassword: sensitiveField(el),
    isCard: el.tagName === 'INPUT' && card(el),
    editable: el.tagName === 'TEXTAREA' || el.isContentEditable || (el.tagName === 'INPUT' && !['submit', 'button', 'reset', 'image', 'checkbox', 'radio', 'file', 'hidden'].includes(type)),
  }
}

/** Describes a numbered element, or the focused one when `ref` is empty. */
export function describeScript(ref) {
  const el = ref ? window.__ada?.refs.get(String(ref)) : document.activeElement
  return describeElement(el, false)
}
describeScript.helpers = [describeElement]

/**
 * The element that has the keyboard focus, followed into same-origin frames and shadow roots.
 * A cross-origin frame stops it; the agent then carries on inside that frame.
 */
export function activeScript() {
  let a = document.activeElement
  for (let i = 0; i < 10 && a; i++) {
    if (a.tagName === 'IFRAME' || a.tagName === 'FRAME') {
      let inner = null
      try { inner = a.contentDocument } catch {}
      if (!inner || !inner.activeElement) break
      a = inner.activeElement
    } else if (a.shadowRoot && a.shadowRoot.activeElement) {
      a = a.shadowRoot.activeElement
    } else break
  }
  return a
}

/** Draws (or removes) a labelled 100-pixel grid over the window, for a screenshot meant for finding positions. */
export function gridScript(on) {
  const id = '__ada_grid'
  document.getElementById(id)?.remove()
  if (!on) return true
  const ns = 'http://www.w3.org/2000/svg'
  const w = innerWidth
  const h = innerHeight
  const box = document.createElement('div')
  box.id = id
  Object.assign(box.style, { position: 'fixed', left: '0', top: '0', width: w + 'px', height: h + 'px', pointerEvents: 'none', zIndex: '2147483647' })
  const svg = document.createElementNS(ns, 'svg')
  svg.setAttribute('width', String(w))
  svg.setAttribute('height', String(h))
  const line = (x1, y1, x2, y2, strong) => {
    const l = document.createElementNS(ns, 'line')
    for (const [k, v] of Object.entries({ x1, y1, x2, y2, stroke: strong ? 'rgba(255,0,80,0.55)' : 'rgba(255,0,80,0.25)', 'stroke-width': '1' })) l.setAttribute(k, String(v))
    svg.appendChild(l)
  }
  const label = (x, y, text) => {
    const t = document.createElementNS(ns, 'text')
    for (const [k, v] of Object.entries({ x, y, fill: '#d00040', stroke: 'white', 'stroke-width': '3', 'paint-order': 'stroke', 'font-size': '11', 'font-family': 'monospace' })) t.setAttribute(k, String(v))
    t.textContent = text
    svg.appendChild(t)
  }
  for (let x = 50; x < w; x += 50) line(x, 0, x, h, x % 100 === 0)
  for (let y = 50; y < h; y += 50) line(0, y, w, y, y % 100 === 0)
  for (let x = 100; x < w; x += 100) { label(x + 2, 11, String(x)); label(x + 2, h - 3, String(x)) }
  for (let y = 100; y < h; y += 100) { label(2, y - 2, String(y)); label(w - 30, y - 2, String(y)) }
  box.appendChild(svg)
  document.documentElement.appendChild(box)
  return true
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

/** Largest file Ada may upload or paste. */
export const MAX_FILE_BYTES = 15 * 1024 * 1024

const MIME_BY_EXTENSION = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', svg: 'image/svg+xml', bmp: 'image/bmp', pdf: 'application/pdf', txt: 'text/plain', csv: 'text/csv', md: 'text/markdown', json: 'application/json', zip: 'application/zip', docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }

/** A safe file name for something Ada uploads: the last part of a path or address, plain characters only. */
export function fileNameFor(raw, mime) {
  let name = basename(String(raw || '').split(/[?#]/)[0] || '')
  try { name = decodeURIComponent(name) } catch {}
  name = name.replace(/[^A-Za-z0-9._ -]/g, '_').replace(/^\.+/, '').slice(0, 120)
  if (!name) name = 'file'
  if (!/\.[A-Za-z0-9]{1,5}$/.test(name)) {
    const ext = Object.keys(MIME_BY_EXTENSION).find((k) => MIME_BY_EXTENSION[k] === mime)
    if (ext) name += '.' + ext
  }
  return name
}

export function mimeFor(name, fallback) {
  const ext = String(name).toLowerCase().split('.').pop()
  return MIME_BY_EXTENSION[ext] || fallback || 'application/octet-stream'
}

/** Turns an image into PNG (the one picture type the clipboard takes) and puts it on the clipboard. */
export async function clipboardImageScript(base64, mime) {
  const bytes = Uint8Array.from(atob(base64), (ch) => ch.charCodeAt(0))
  let blob = new Blob([bytes], { type: mime })
  if (mime !== 'image/png') {
    const bitmap = await createImageBitmap(blob)
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height)
    canvas.getContext('2d').drawImage(bitmap, 0, 0)
    blob = await canvas.convertToBlob({ type: 'image/png' })
  }
  await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
  return true
}

/** Offers a file to the focused element as a paste, for editors where the clipboard is not available. */
export function pasteFileScript(el, base64, mime, name) {
  const bytes = Uint8Array.from(atob(base64), (ch) => ch.charCodeAt(0))
  const data = new DataTransfer()
  data.items.add(new File([bytes], name, { type: mime }))
  const event = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true, composed: true })
  el.dispatchEvent(event)
  return event.defaultPrevented
}

/** "12" names element 12 of the page; "2.5" names element 5 inside frame 2. */
export function splitRef(raw) {
  const match = /^\[?\s*(?:(\d+)\.)?(\d+)\s*\]?$/.exec(String(raw ?? '').trim())
  return match ? { frame: match[1] ? Number(match[1]) : 0, ref: match[2] } : null
}

/** A point Ada gave, checked against the window: whole page pixels from its top-left corner. */
export function pointProblem(x, y, viewport) {
  if (!Number.isFinite(x) || !Number.isFinite(y)) return 'x and y must be numbers: page pixels from the top-left corner of the window.'
  if (x < 0 || y < 0 || x >= viewport.width || y >= viewport.height) return `(${Math.round(x)}, ${Math.round(y)}) is outside the window, which is ${viewport.width}×${viewport.height}. Take a screenshot to find the right place.`
  return null
}

export const CONTROL_STATES = ['ada', 'paused', 'person']

/** Operations that only read the page, and so also run while Ada is paused. */
export const READ_OPS = new Set(['look', 'describe', 'describe_point', 'tabs', 'screenshot', 'wait', 'status'])

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

const MODIFIERS = { alt: 1, option: 1, ctrl: 2, control: 2, meta: 4, cmd: 4, command: 4, super: 4, shift: 8 }

// Editing commands Chromium runs for these shortcuts, since a synthetic key press alone does not
// trigger them everywhere.
const SHORTCUT_COMMANDS = { 'ctrl+a': 'selectAll', 'ctrl+c': 'copy', 'ctrl+x': 'cut', 'ctrl+z': 'undo', 'ctrl+y': 'redo', 'ctrl+shift+z': 'redo' }

/**
 * A key or a shortcut such as "Control+A" or "shift+tab": the key, its modifier bits (Alt 1,
 * Control 2, Meta 4, Shift 8) and any editing command it stands for. Null when it is not known.
 */
export function keyFor(name) {
  const raw = String(name || '').trim()
  const parts = raw.length > 1 ? raw.split(/\s*\+\s*/).filter(Boolean) : [raw]
  if (!parts.length) return null
  let modifiers = 0
  const names = []
  for (const part of parts.slice(0, -1)) {
    const bit = MODIFIERS[part.toLowerCase()]
    if (!bit) return null
    if (!(modifiers & bit)) names.push(Object.keys(MODIFIERS).find((k) => MODIFIERS[k] === bit && ['alt', 'ctrl', 'meta', 'shift'].includes(k)))
    modifiers |= bit
  }
  const last = parts[parts.length - 1]
  let key = KEYS[last.toLowerCase().replace(/[\s_-]/g, '')]
  if (!key && /^[a-z0-9]$/i.test(last)) {
    const upper = last.toUpperCase()
    const letter = /[A-Z]/.test(upper)
    const char = letter ? ((modifiers & 8) ? upper : upper.toLowerCase()) : last
    key = { key: char, code: letter ? `Key${upper}` : `Digit${last}`, keyCode: upper.charCodeAt(0), text: char }
  }
  if (!key && /^f([1-9]|1[0-2])$/i.test(last)) {
    const n = Number(last.slice(1))
    key = { key: `F${n}`, code: `F${n}`, keyCode: 111 + n }
  }
  if (!key) return null
  if (!modifiers) return key
  const combo = [...names.sort((a, b) => ['ctrl', 'alt', 'shift', 'meta'].indexOf(a) - ['ctrl', 'alt', 'shift', 'meta'].indexOf(b)), key.key.toLowerCase()].join('+')
  // With Control, Alt or Meta held, a key types nothing.
  const result = { ...key, modifiers, combo }
  if (modifiers & 7) delete result.text
  const command = SHORTCUT_COMMANDS[combo]
  if (command) result.commands = [command]
  return result
}

/** Shortcuts Ada may not press: pasting would put whatever the person last copied into the page. */
export function forbiddenShortcut(key) {
  if (!key?.modifiers) return null
  if (key.combo === 'ctrl+v' || key.combo === 'ctrl+shift+v' || key.combo === 'shift+insert' || key.combo === 'meta+v') {
    return 'Ada cannot paste the clipboard with a shortcut, because it may hold what the person copied. Use browser_paste with the text instead.'
  }
  return null
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
    // Frames from other sites run in processes of their own (out-of-process iframes), each with its
    // own DevTools session attached under its parent's.
    this.children = new Map() // child sessionId -> { parent: sessionId, frameId }
    this.contexts = new Map() // `${sessionId}|${frameId}` -> the frame's main script context
    this.current = null
    this.order = [] // targetIds in the order they opened, so tab numbers follow the tab strip
    this.listeners = new Set() // short-lived waiters for DevTools events
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
      if (message.method) for (const listener of this.listeners) { try { listener(message) } catch {} }
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id)
        this.pending.delete(message.id)
        if (message.error) reject(new Error(message.error.message || 'DevTools error'))
        else resolve(message.result || {})
      } else if (message.method === 'Target.detachedFromTarget') {
        const gone = message.params.sessionId
        for (const [target, session] of this.sessions) if (session === gone) this.sessions.delete(target)
        this.children.delete(gone)
        for (const key of [...this.contexts.keys()]) if (key.startsWith(gone + '|')) this.contexts.delete(key)
      } else if (message.method === 'Target.attachedToTarget') {
        const { sessionId, targetInfo } = message.params
        if (message.sessionId && targetInfo?.type === 'iframe') {
          this.children.set(sessionId, { parent: message.sessionId, frameId: targetInfo.targetId })
          this.prepare(sessionId).catch(() => {})
        }
      } else if (message.method === 'Runtime.executionContextCreated') {
        const context = message.params.context
        if (message.sessionId && context?.auxData?.isDefault && context.auxData.frameId) this.contexts.set(`${message.sessionId}|${context.auxData.frameId}`, context.id)
      } else if (message.method === 'Runtime.executionContextDestroyed') {
        for (const [key, id] of this.contexts) if (key.startsWith(message.sessionId + '|') && id === message.params.executionContextId) this.contexts.delete(key)
      } else if (message.method === 'Runtime.executionContextsCleared') {
        for (const key of [...this.contexts.keys()]) if (key.startsWith(message.sessionId + '|')) this.contexts.delete(key)
      } else if (message.method === 'Target.targetCreated') {
        if (!this.order.includes(message.params.targetInfo.targetId)) this.order.push(message.params.targetInfo.targetId)
      } else if (message.method === 'Target.targetDestroyed') {
        this.order = this.order.filter((id) => id !== message.params.targetId)
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
    const rank = (t) => { const i = this.order.indexOf(t.targetId); return i < 0 ? Infinity : i }
    return targetInfos.filter((t) => t.type === 'page' && !t.url.startsWith('devtools://')).sort((a, b) => rank(a) - rank(b))
  }

  async session(targetId) {
    if (this.sessions.has(targetId)) return this.sessions.get(targetId)
    const { sessionId } = await this.send('Target.attachToTarget', { targetId, flatten: true })
    this.sessions.set(targetId, sessionId)
    await this.send('Page.enable', {}, sessionId).catch(() => {})
    await this.prepare(sessionId)
    return sessionId
  }

  /** Reports the session's script contexts and attaches its out-of-process frames as they appear. */
  async prepare(sessionId) {
    await this.send('Page.enable', {}, sessionId).catch(() => {})
    await this.send('Runtime.enable', {}, sessionId).catch(() => {})
    await this.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId).catch(() => {})
  }

  /** Every frame of a page: its main frame first, then the frames inside it, near and far. */
  frames(pageSession) {
    const sessions = [pageSession]
    for (let i = 0; i < sessions.length; i++) {
      for (const [child, info] of this.children) if (info.parent === sessions[i]) sessions.push(child)
    }
    const main = [...this.sessions].find(([, s]) => s === pageSession)?.[0]
    const out = []
    for (const session of sessions) {
      for (const [key, contextId] of this.contexts) {
        const cut = key.indexOf('|')
        if (key.slice(0, cut) !== session) continue
        const frameId = key.slice(cut + 1)
        out.push({ session, frameId, contextId, main: session === pageSession && frameId === main })
      }
    }
    return out.sort((a, b) => (b.main ? 1 : 0) - (a.main ? 1 : 0))
  }

  /** The frame `frameId` as seen from `session`: in the same process, or the root of a child session. */
  frameByID(session, frameId) {
    const key = `${session}|${frameId}`
    if (this.contexts.has(key)) return { session, frameId, contextId: this.contexts.get(key) }
    for (const [child, info] of this.children) {
      if (info.parent === session && info.frameId === frameId) return { session: child, frameId, contextId: this.contexts.get(`${child}|${frameId}`) }
    }
    return null
  }

  /** Where an out-of-process frame's top-left corner is in the window, so points inside it can be clicked. */
  async offset(session) {
    let x = 0
    let y = 0
    let s = session
    for (let i = 0; i < 8 && this.children.has(s); i++) {
      const { parent, frameId } = this.children.get(s)
      const { backendNodeId } = await this.send('DOM.getFrameOwner', { frameId }, parent)
      const { model } = await this.send('DOM.getBoxModel', { backendNodeId }, parent)
      x += model.content[0]
      y += model.content[1]
      s = parent
    }
    return { x, y }
  }

  /** Runs a function on a remote object (`this` is the first argument) and returns its value. */
  async callOn(session, objectId, fn, ...args) {
    const helpers = (fn.helpers || []).map((h) => `const ${h.name} = ${h.toString()};`).join('\n')
    const result = await this.send('Runtime.callFunctionOn', {
      objectId,
      functionDeclaration: `function (...args) { ${helpers}\n return (${fn.toString()})(this, ...args) }`,
      arguments: args.map((value) => ({ value: value ?? null })),
      returnByValue: true,
      awaitPromise: true,
    }, session)
    if (result.exceptionDetails) throw new Error('The page refused the script: ' + (result.exceptionDetails.exception?.description || result.exceptionDetails.text || 'error').slice(0, 200))
    return result.result?.value
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

  /** Runs a page script in the page's main frame, or in `frame` ({ session, contextId }) when given one. */
  async evaluate(session, fn, ...args) {
    return this.evaluateIn({ session }, fn, ...args)
  }

  async evaluateIn(frame, fn, ...args) {
    const helpers = (fn.helpers || []).map((h) => `const ${h.name} = ${h.toString()};`).join('\n')
    const call = `(${fn.toString()})(${args.map((a) => JSON.stringify(a ?? null)).join(',')})`
    const expression = helpers ? `(() => { ${helpers}\n return ${call} })()` : call
    const params = { expression, returnByValue: true, awaitPromise: true }
    if (frame.contextId) params.contextId = frame.contextId
    const result = await this.send('Runtime.evaluate', params, frame.session)
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
    this.frameNumbers = new Map() // frameId -> the number Ada sees
    this.nextFrame = 2
    this.mouse = null
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

  /** The page as Ada reads it: the main frame, then each frame inside it that has something to read. */
  async outline(session, maxChars = 6000, query) {
    const snap = await this.chromium.evaluate(session, snapshotScript, maxChars, query || null, '')
    const parts = [snap.text]
    let left = maxChars - snap.text.length
    for (const frame of this.chromium.frames(session)) {
      if (frame.main) continue
      if (left < 300) { snap.cut = true; break }
      const number = this.frameNumber(frame.frameId)
      let sub
      try { sub = await this.chromium.evaluateIn(frame, snapshotScript, left - 100, query || null, number + '.') } catch { continue }
      if (!sub?.text) continue
      let host = ''
      try { host = new URL(sub.url).host } catch {}
      const header = `── Frame ${number}${sub.title ? ` "${sub.title.slice(0, 80)}"` : ''}${host ? ` (${host})` : ''}: its elements are numbered [${number}.N] ──`
      parts.push(header, sub.text)
      left -= header.length + sub.text.length + 2
      if (sub.cut) snap.cut = true
    }
    snap.text = parts.filter(Boolean).join('\n')
    return snap
  }

  /** Checks that an approved action still meets the same page and element it was approved on. */
  async checkExpected(session, request) {
    const expect = request.expect
    if (!expect) return null
    let info
    try {
      info = Number.isFinite(expect.x) && Number.isFinite(expect.y)
        ? (await this.hitTest(session, expect.x, expect.y)).info
        : (await this.describeTarget(session, request.ref)).info
    } catch { info = null }
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
        return { element: (await this.describeTarget(session, request.ref)).info }
      }
      case 'describe_point': {
        const { session } = await c.page()
        const x = Number(request.x)
        const y = Number(request.y)
        const problem = pointProblem(x, y, await this.viewport(session))
        if (problem) throw new Error(problem)
        return { element: (await this.hitTest(session, x, y)).info }
      }
      case 'click': {
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const { frame, ref } = await this.resolve(session, request.ref)
        await this.pointOf(session, frame, ref)
        await sleep(150)
        const again = await this.pointOf(session, frame, ref)
        if (!again.reaches) throw new Error(`Element [${request.ref}] is covered by "${again.cover}". Close or accept that first.`)
        const before = new Set((await c.pages()).map((p) => p.targetId))
        await this.clickAt(session, again.x, again.y)
        await c.settle(session)
        const { session: after } = await this.followNewTab(session, before)
        return { page: await this.outline(after, request.maxChars) }
      }
      case 'mouse': {
        // Ada's hand on the mouse: points are page pixels from the window's top-left corner, as in a screenshot.
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const action = String(request.action || '')
        const viewport = await this.viewport(session)
        const x = Number(request.x)
        const y = Number(request.y)
        const problem = pointProblem(x, y, viewport)
        if (problem) throw new Error(problem)
        const before = new Set((await c.pages()).map((p) => p.targetId))
        let message = ''
        if (action === 'move') {
          await this.moveMouse(session, x, y)
          await sleep(300)
          message = `Moved the mouse to (${Math.round(x)}, ${Math.round(y)}).`
        } else if (action === 'click' || action === 'double' || action === 'right') {
          await this.clickAt(session, x, y, { button: action === 'right' ? 'right' : 'left', clicks: action === 'double' ? 2 : 1 })
          await c.settle(session, 4000)
          message = `${action === 'double' ? 'Double-clicked' : action === 'right' ? 'Right-clicked' : 'Clicked'} at (${Math.round(x)}, ${Math.round(y)}).`
        } else if (action === 'drag') {
          const toX = Number(request.toX)
          const toY = Number(request.toY)
          const end = pointProblem(toX, toY, viewport)
          if (end) throw new Error(end)
          await this.moveMouse(session, x, y)
          await c.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 }, session)
          await sleep(80)
          await this.moveMouse(session, toX, toY, 1)
          await sleep(80)
          await c.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: toX, y: toY, button: 'left', buttons: 0, clickCount: 1 }, session)
          await sleep(400)
          message = `Dragged from (${Math.round(x)}, ${Math.round(y)}) to (${Math.round(toX)}, ${Math.round(toY)}).`
        } else {
          throw new Error('Unknown mouse action. Use move, click, double, right or drag.')
        }
        const { session: after } = await this.followNewTab(session, before)
        return { message, page: await this.outline(after, request.maxChars) }
      }
      case 'paste': {
        // One step for long text: put it on the clipboard and press Ctrl+V, as a person would, so
        // rich editors (Google Docs, CryptPad) keep its lines and paragraphs.
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const text = String(request.text ?? '')
        const image = !text && (request.url || request.files)
        if (!text && !image) throw new Error('There is no text or picture to paste.')
        if (request.ref) {
          const { frame, ref, info } = await this.describeTarget(session, request.ref)
          if (!info?.found) throw new Error(`There is no element [${request.ref}] on this page any more. Look at the page again.`)
          if (info.isPassword) throw new Error('Ada never types into password or code fields. Ask the person to take over the browser and sign in themselves.')
          const focus = await c.evaluateIn(frame, focusScript, ref, !!request.clear)
          if (!focus?.focused) throw new Error(`Element [${request.ref}] could not be focused.`)
        }
        const target = await this.focused(session)
        if (!target.info?.found || !target.info.editable) throw new Error('No text field has the focus. Click into the place to write first (browser_click, or browser_click_at for editors inside frames), then paste.')
        if (target.info.isPassword) throw new Error('Ada never types into password or code fields. Ask the person to take over the browser and sign in themselves.')
        if (image) return { message: await this.pasteImage(session, target, (await this.loadFiles(request))[0]), page: await this.outline(session, request.maxChars) }
        let how = 'with Ctrl+V'
        try {
          await this.writeClipboard(target, text)
          await this.press(session, { key: 'v', code: 'KeyV', keyCode: 86, modifiers: 2, commands: ['paste'] })
        } catch (error) {
          if (process.env.ADA_BROWSER_DEBUG) console.error('paste fallback:', error?.message)
          // No clipboard here (an http site, or one that blocks it): insert the text in one step instead.
          how = 'in one step'
          await c.send('Input.insertText', { text }, session)
        }
        await sleep(500)
        return { message: `Pasted ${text.length} characters ${how} into ${target.info.name ? `"${target.info.name.slice(0, 60)}"` : `a ${target.info.tag}`}.`, page: await this.outline(session, request.maxChars) }
      }
      case 'upload': {
        // Gives files to a file field, or to the file chooser that clicking a button opens.
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const files = await this.loadFiles(request)
        const paths = this.stage(files)
        const names = files.map((f) => f.name).join(', ')
        if (request.ref) {
          const { frame, ref, info } = await this.describeTarget(session, request.ref)
          if (!info?.found) throw new Error(`There is no element [${request.ref}] on this page any more. Look at the page again.`)
          if (info.tag === 'input' && info.type === 'file') {
            const params = { expression: `window.__ada?.refs.get(${JSON.stringify(ref)})`, returnByValue: false }
            if (frame.contextId) params.contextId = frame.contextId
            const { result } = await c.send('Runtime.evaluate', params, frame.session)
            await c.send('DOM.setFileInputFiles', { files: paths, objectId: result.objectId }, frame.session)
            await c.settle(session, 4000)
            return { message: `Gave ${names} to the file field.`, page: await this.outline(session, request.maxChars) }
          }
        }
        // A button or drop area: catch the file chooser its click opens, in whichever frame it is.
        const sessions = [...new Set(this.chromium.frames(session).map((f) => f.session).concat(session))]
        for (const s of sessions) await c.send('Page.setInterceptFileChooserDialog', { enabled: true }, s).catch(() => {})
        try {
          const opened = this.waitFor((m) => m.method === 'Page.fileChooserOpened', 5000)
          if (request.ref) {
            const { frame, ref } = await this.resolve(session, request.ref)
            const point = await this.pointOf(session, frame, ref)
            await this.clickAt(session, point.x, point.y)
          } else {
            const x = Number(request.x)
            const y = Number(request.y)
            const problem = pointProblem(x, y, await this.viewport(session))
            if (problem) throw new Error(problem)
            await this.clickAt(session, x, y)
          }
          const event = await opened
          if (!event) throw new Error('Clicking there did not open a file chooser. Find the upload button or file field (browser_look, or a screenshot) and try that.')
          if (event.params.mode === 'selectSingle' && paths.length > 1) paths.length = 1
          await c.send('DOM.setFileInputFiles', { files: paths, backendNodeId: event.params.backendNodeId }, event.sessionId)
        } finally {
          for (const s of sessions) await c.send('Page.setInterceptFileChooserDialog', { enabled: false }, s).catch(() => {})
        }
        await c.settle(session, 4000)
        return { message: `Gave ${names} to the file chooser.`, page: await this.outline(session, request.maxChars) }
      }
      case 'type': {
        const { session } = await c.page()
        const changed = await this.checkExpected(session, request)
        if (changed) return { ok: false, message: changed }
        const hasRef = request.ref !== undefined && request.ref !== null && request.ref !== ''
        const { frame, ref, info } = await this.describeTarget(session, hasRef ? request.ref : null)
        if (!info?.found) throw new Error(hasRef ? `There is no element [${request.ref}] on this page any more. Look at the page again.` : 'No text field has the focus. Click into the place to write first.')
        if (info.isPassword) throw new Error('Ada never types into password or code fields. Ask the person to take over the browser and sign in themselves.')
        if (!info.editable) throw new Error(hasRef ? `Element [${request.ref}] is not a text field.` : 'What has the focus is not a text field. Click into the place to write first.')
        if (hasRef) {
          const focus = await c.evaluateIn(frame, focusScript, ref, !!request.clear)
          if (!focus?.focused) throw new Error(`Element [${request.ref}] could not be focused.`)
        }
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
        const { frame, ref } = await this.resolve(session, request.ref)
        const result = await c.evaluateIn(frame, selectScript, ref, String(request.option ?? ''))
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
        if (!key) throw new Error('Unknown key. Use Enter, Tab, Escape, Backspace, Delete, Space, an arrow key, PageUp, PageDown, Home, End, F1 to F12, a letter or digit, or a shortcut like Control+A or Shift+Tab.')
        const forbidden = forbiddenShortcut(key)
        if (forbidden) throw new Error(forbidden)
        await this.press(session, key)
        await c.settle(session, key.key === 'Enter' ? 10000 : 2000)
        return { page: await this.outline(session, request.maxChars) }
      }
      case 'scroll': {
        const { session } = await c.page()
        const pages = Math.max(0.25, Math.min(10, Number(request.pages) || 1))
        const viewport = await this.viewport(session)
        const direction = ['up', 'down', 'left', 'right'].includes(request.direction) ? request.direction : 'down'
        const sideways = direction === 'left' || direction === 'right'
        const amount = (direction === 'up' || direction === 'left' ? -1 : 1) * Math.round((sideways ? viewport.width : viewport.height) * 0.8 * pages)
        // At a point, the wheel scrolls whatever is under it (a panel, an editor in a frame); else the page.
        let x = Math.round(viewport.width / 2)
        let y = Math.round(viewport.height / 2)
        if (request.x !== undefined && request.y !== undefined) {
          const problem = pointProblem(Number(request.x), Number(request.y), viewport)
          if (problem) throw new Error(problem)
          x = Number(request.x)
          y = Number(request.y)
          await this.moveMouse(session, x, y)
        }
        await c.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: sideways ? amount : 0, deltaY: sideways ? 0 : amount }, session)
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
        const viewport = await this.viewport(session)
        const grid = !!request.grid
        if (grid) await c.evaluate(session, gridScript, true).catch(() => {})
        let shot
        try {
          shot = await c.send('Page.captureScreenshot', { format: 'jpeg', quality: 75 }, session)
        } finally {
          if (grid) await c.evaluate(session, gridScript, false).catch(() => {})
        }
        const info = await c.evaluate(session, () => ({ url: location.href, title: document.title }))
        return { jpeg: shot.data, url: info.url, title: info.title, width: viewport.width, height: viewport.height, scale: viewport.dpr, grid, mouse: this.mouse }
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
    const base = { key: key.key, code: key.code, windowsVirtualKeyCode: key.keyCode, nativeVirtualKeyCode: key.keyCode, modifiers: key.modifiers || 0 }
    const down = { type: key.text ? 'keyDown' : 'rawKeyDown', ...base, ...(key.text ? { text: key.text, unmodifiedText: key.text } : {}) }
    if (key.commands) down.commands = key.commands
    await this.chromium.send('Input.dispatchKeyEvent', down, session)
    await this.chromium.send('Input.dispatchKeyEvent', { type: 'keyUp', ...base }, session)
  }

  /**
   * Puts text on the browser's clipboard: from the focused frame, or from the page itself when a
   * frame from another site may not use the clipboard.
   */
  async writeClipboard(target, text) {
    const c = this.chromium
    const { session } = await c.page()
    const tries = [target.frame, { session, main: true }]
    let last = 'no clipboard'
    for (const frame of tries) {
      const params = { expression: `(async (t) => { await navigator.clipboard.writeText(t); return location.origin })(${JSON.stringify(text)})`, awaitPromise: true, returnByValue: true, userGesture: true }
      if (frame.contextId) params.contextId = frame.contextId
      const origin = await c.send('Runtime.evaluate', { expression: 'location.origin', returnByValue: true, ...(frame.contextId ? { contextId: frame.contextId } : {}) }, frame.session).then((r) => r.result?.value).catch(() => null)
      if (!origin || origin === 'null') continue
      await c.send('Browser.grantPermissions', { origin, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] }).catch(() => {})
      const wrote = await c.send('Runtime.evaluate', params, frame.session).catch((e) => ({ exceptionDetails: { text: e.message } }))
      if (!wrote.exceptionDetails && wrote.result?.value) return
      last = wrote.exceptionDetails?.exception?.description || wrote.exceptionDetails?.text || last
    }
    throw new Error(last)
  }

  /**
   * The files of an upload or image paste, from Ada's server (base64, from the chat's files) or
   * downloaded here from a public web address. Returns { name, mime, base64, bytes }.
   */
  async loadFiles(request) {
    const out = []
    for (const file of Array.isArray(request.files) ? request.files.slice(0, 10) : []) {
      const bytes = Buffer.from(String(file.data || ''), 'base64')
      if (!bytes.length) throw new Error(`The file ${file.name || ''} is empty.`)
      if (bytes.length > MAX_FILE_BYTES) throw new Error(`The file ${file.name || ''} is larger than 15 MB.`)
      const name = fileNameFor(file.name, file.mime)
      out.push({ name, mime: file.mime || mimeFor(name), bytes })
    }
    if (request.url) {
      const url = allowedURL(request.url)
      if (!url || url === 'about:blank') throw new Error('Files can only be downloaded from http and https addresses.')
      const response = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(30000) })
      if (!response.ok) throw new Error(`Downloading ${url} failed: HTTP ${response.status}.`)
      if (!allowedURL(response.url)) throw new Error('The download was redirected to an address that is not allowed.')
      const declared = Number(response.headers.get('content-length') || 0)
      if (declared > MAX_FILE_BYTES) throw new Error('That file is larger than 15 MB.')
      const bytes = Buffer.from(await response.arrayBuffer())
      if (bytes.length > MAX_FILE_BYTES) throw new Error('That file is larger than 15 MB.')
      const type = (response.headers.get('content-type') || '').split(';')[0].trim()
      const name = fileNameFor(new URL(response.url).pathname, type)
      out.push({ name, mime: type && type !== 'application/octet-stream' ? type : mimeFor(name), bytes })
    }
    if (!out.length) throw new Error('No file was given: pass a file from the chat or a web address.')
    return out
  }

  /** Writes files to a private folder of the browser's own, for a file chooser. */
  stage(files) {
    const dir = mkdtempSync(join(tmpdir(), 'ada-upload-'))
    chmodSync(dir, 0o700)
    return files.map((f) => {
      const path = join(dir, f.name)
      writeFileSync(path, f.bytes, { mode: 0o600 })
      return path
    })
  }

  /** Waits for one DevTools event that `match` accepts. */
  waitFor(match, timeout) {
    const c = this.chromium
    let listener
    const promise = new Promise((resolve) => {
      const timer = setTimeout(() => { c.listeners.delete(listener); resolve(null) }, timeout)
      listener = (message) => { if (match(message)) { clearTimeout(timer); c.listeners.delete(listener); resolve(message) } }
      c.listeners.add(listener)
    })
    return promise
  }

  /** Pastes a picture: through the clipboard and Ctrl+V, else as a paste event the editor can take. */
  async pasteImage(session, target, file) {
    const c = this.chromium
    if (!file.mime.startsWith('image/')) throw new Error(`${file.name} is not a picture (${file.mime}). Use browser_upload_file for other files.`)
    const base64 = file.bytes.toString('base64')
    try {
      const { session: top } = await c.page()
      const origin = await c.evaluate(top, () => location.origin)
      await c.send('Browser.grantPermissions', { origin, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] }).catch(() => {})
      const params = { expression: `(${clipboardImageScript.toString()})(${JSON.stringify(base64)}, ${JSON.stringify(file.mime)})`, awaitPromise: true, returnByValue: true, userGesture: true }
      const wrote = await c.send('Runtime.evaluate', params, top)
      if (wrote.exceptionDetails || wrote.result?.value !== true) throw new Error(wrote.exceptionDetails?.exception?.description || 'clipboard refused')
      await this.press(session, { key: 'v', code: 'KeyV', keyCode: 86, modifiers: 2, commands: ['paste'] })
      await sleep(800)
      return `Pasted the picture ${file.name} with Ctrl+V. Take a screenshot to check that it landed.`
    } catch (error) {
      if (process.env.ADA_BROWSER_DEBUG) console.error('image paste fallback:', error?.message)
    }
    const params = { expression: `(${activeScript.toString()})()`, returnByValue: false }
    if (target.frame.contextId) params.contextId = target.frame.contextId
    const { result } = await c.send('Runtime.evaluate', params, target.frame.session)
    if (!result?.objectId) throw new Error('The picture could not be pasted: nothing has the focus.')
    const taken = await c.callOn(target.frame.session, result.objectId, pasteFileScript, base64, file.mime, file.name)
    await sleep(800)
    return taken
      ? `Offered the picture ${file.name} to the editor as a paste, and it took it. Take a screenshot to check that it landed.`
      : `Offered the picture ${file.name} to the editor as a paste, but it may have ignored it. Take a screenshot to check; if it is not there, look for the editor's own "insert image" or upload button and use browser_upload_file.`
  }

  /** The number Ada sees for a frame ([2.5] is element 5 in frame 2). It stays the same while the frame lives. */
  frameNumber(frameId) {
    if (!this.frameNumbers.has(frameId)) this.frameNumbers.set(frameId, this.nextFrame++)
    return this.frameNumbers.get(frameId)
  }

  /** The frame and element number a ref names: "12" is in the page itself, "2.5" is element 5 in frame 2. */
  async resolve(session, rawRef) {
    const parsed = splitRef(rawRef)
    if (!parsed) throw new Error(`"${rawRef}" is not an element number from the page outline.`)
    if (!parsed.frame) return { frame: { session, main: true }, ref: parsed.ref }
    const frame = this.chromium.frames(session).find((f) => !f.main && this.frameNumbers.get(f.frameId) === parsed.frame)
    if (!frame) throw new Error(`Frame ${parsed.frame} is not on this page any more. Look at the page again.`)
    return { frame, ref: parsed.ref }
  }

  /** What an element is: a numbered one, or the one with the keyboard focus, in whichever frame it is. */
  async describeTarget(session, rawRef) {
    if (rawRef !== undefined && rawRef !== null && rawRef !== '') {
      const { frame, ref } = await this.resolve(session, rawRef)
      return { frame, ref, info: await this.chromium.evaluateIn(frame, describeScript, ref) }
    }
    return this.focused(session)
  }

  /** The element with the keyboard focus, followed into frames from other sites. */
  async focused(session) {
    const c = this.chromium
    let frame = { session, main: true }
    for (let depth = 0; depth < 8; depth++) {
      const params = { expression: `(${activeScript.toString()})()`, returnByValue: false }
      if (frame.contextId) params.contextId = frame.contextId
      const { result } = await c.send('Runtime.evaluate', params, frame.session)
      if (!result?.objectId) return { frame, info: { found: false } }
      const { node } = await c.send('DOM.describeNode', { objectId: result.objectId }, frame.session)
      if ((node.nodeName === 'IFRAME' || node.nodeName === 'FRAME') && node.frameId) {
        const inner = c.frameByID(frame.session, node.frameId)
        if (inner) { frame = inner; continue }
      }
      return { frame, info: await c.callOn(frame.session, result.objectId, describeElement, false) }
    }
    return { frame, info: { found: false } }
  }

  /** What is at a point of the window (in page pixels), followed into frames from other sites. */
  async hitTest(session, x, y) {
    const c = this.chromium
    let s = session
    let lx = x
    let ly = y
    for (let depth = 0; depth < 8; depth++) {
      const location = await c.send('DOM.getNodeForLocation', { x: Math.round(lx), y: Math.round(ly), includeUserAgentShadowDOM: false, ignorePointerEventsNone: true }, s)
      const { node } = await c.send('DOM.describeNode', { backendNodeId: location.backendNodeId }, s)
      if ((node.nodeName === 'IFRAME' || node.nodeName === 'FRAME') && node.frameId) {
        const inner = [...c.children].find(([, info]) => info.parent === s && info.frameId === node.frameId)
        if (inner) {
          const { model } = await c.send('DOM.getBoxModel', { backendNodeId: location.backendNodeId }, s)
          lx -= model.content[0]
          ly -= model.content[1]
          s = inner[0]
          continue
        }
      }
      const { object } = await c.send('DOM.resolveNode', { backendNodeId: location.backendNodeId }, s)
      return { session: s, info: await c.callOn(s, object.objectId, describeElement, true) }
    }
    return { session: s, info: { found: false } }
  }

  /** Where to click a numbered element, in window pixels, after scrolling it into view. */
  async pointOf(session, frame, ref) {
    const c = this.chromium
    const point = await c.evaluateIn(frame, pointScript, ref)
    if (!point?.found) throw new Error(`There is no element [${frame.main ? '' : this.frameNumbers.get(frame.frameId) + '.'}${ref}] on this page any more. Look at the page again.`)
    if (frame.main) return point
    const params = { expression: `window.__ada?.refs.get(${JSON.stringify(String(ref))})`, returnByValue: false }
    if (frame.contextId) params.contextId = frame.contextId
    const { result } = await c.send('Runtime.evaluate', params, frame.session)
    const { quads } = await c.send('DOM.getContentQuads', { objectId: result.objectId }, frame.session)
    if (!quads?.length) throw new Error('That element is not visible on the screen.')
    const q = quads[0]
    const offset = await c.offset(frame.session)
    return { ...point, x: (q[0] + q[2] + q[4] + q[6]) / 4 + offset.x, y: (q[1] + q[3] + q[5] + q[7]) / 4 + offset.y }
  }

  async viewport(session) {
    return this.chromium.evaluate(session, () => ({ width: innerWidth, height: innerHeight, dpr: devicePixelRatio }))
  }

  /** Moves the mouse like a hand would: in a few steps from where it last was. */
  async moveMouse(session, x, y, buttons = 0) {
    const from = this.mouse || { x, y }
    const steps = buttons ? 12 : 4
    for (let i = 1; i <= steps; i++) {
      const px = from.x + ((x - from.x) * i) / steps
      const py = from.y + ((y - from.y) * i) / steps
      await this.chromium.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: px, y: py, buttons, ...(buttons ? { button: 'left' } : {}) }, session)
      if (buttons) await sleep(16)
    }
    this.mouse = { x, y }
  }

  async clickAt(session, x, y, { button = 'left', clicks = 1 } = {}) {
    await this.moveMouse(session, x, y)
    const buttons = button === 'right' ? 2 : 1
    for (let i = 1; i <= clicks; i++) {
      await this.chromium.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, buttons, clickCount: i }, session)
      await this.chromium.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, buttons: 0, clickCount: i }, session)
    }
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
      if (data.length > 25_000_000) { socket.destroy(); return }
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
