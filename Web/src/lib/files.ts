// How to show and download a deliverable, decided by its file extension.

export type FileKind = 'markdown' | 'text'

const MIME: Record<string, string> = {
  md: 'text/markdown',
  markdown: 'text/markdown',
  json: 'application/json',
  csv: 'text/csv',
  tsv: 'text/tab-separated-values',
  html: 'text/html',
  htm: 'text/html',
  xml: 'application/xml',
  yaml: 'application/yaml',
  yml: 'application/yaml',
  js: 'text/javascript',
  ts: 'text/plain',
  py: 'text/x-python',
  svg: 'image/svg+xml',
}

export function extension(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot < 0 ? '' : name.slice(dot + 1).toLowerCase()
}

export function fileKind(name: string): FileKind {
  const ext = extension(name)
  return ext === 'md' || ext === 'markdown' || ext === '' ? 'markdown' : 'text'
}

export function mimeType(name: string): string {
  return `${MIME[extension(name)] ?? 'text/plain'};charset=utf-8`
}

/** Pretty-prints JSON so it reads well; anything else is shown as written. */
export function displayText(name: string, text: string): string {
  if (extension(name) !== 'json') return text
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}

export function saveFile(name: string, data: BlobPart, type: string): void {
  const url = URL.createObjectURL(new Blob([data], { type }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
}
