// Tests for Ada's browser agent. The rules run everywhere; the browser tests need a Chromium
// (ADA_BROWSER_CHROMIUM, or chromium / google-chrome on the PATH) and are skipped without one.
//     node --test deploy/browser-agent/browser-agent.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { connect } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { BrowserAgent, allowedURL, controlProblem, keyFor, serve } from './browser-agent.mjs'

test('only public web addresses open', () => {
  assert.equal(allowedURL('https://example.com/a'), 'https://example.com/a')
  assert.equal(allowedURL('example.com'), 'https://example.com/')
  assert.equal(allowedURL('about:blank'), 'about:blank')
  for (const bad of ['chrome://settings', 'file:///etc/passwd', 'javascript:alert(1)', 'devtools://x', 'https://user:pw@example.com', 'data:text/html,hi']) {
    assert.equal(allowedURL(bad), null, bad)
  }
})

test('the person in control locks Ada out, and pausing allows only reading', () => {
  assert.equal(controlProblem('ada', 'click'), null)
  assert.match(controlProblem('person', 'look'), /taken control/)
  assert.match(controlProblem('person', 'click'), /taken control/)
  assert.equal(controlProblem('paused', 'look'), null)
  assert.match(controlProblem('paused', 'type'), /paused/)
  assert.equal(controlProblem('person', 'status'), null)
})

test('keys have names', () => {
  assert.equal(keyFor('Enter').keyCode, 13)
  assert.equal(keyFor('page down').key, 'PageDown')
  assert.equal(keyFor('F13'), null)
})

function findChromium() {
  const candidates = [process.env.ADA_BROWSER_CHROMIUM, 'chromium', 'chromium-browser', 'google-chrome', '/opt/pw-browsers/chromium-1243/chrome-linux64/chrome'].filter(Boolean)
  for (const binary of candidates) {
    try { execFileSync(binary, ['--version'], { stdio: 'ignore' }); return binary } catch {}
  }
  return null
}

const PAGES = {
  '/': `<!doctype html><title>Home</title><h1>Shop</h1><p>Welcome to the test shop.</p>
    <a href="/second">Second page</a>
    <form action="/search" method="get"><input name="q" aria-label="Search"><button>Search</button></form>
    <form action="/login" method="post"><label>Email <input name="email"></label><label>Password <input type="password" name="pw" value="secret-value"></label><button>Sign in</button></form>
    <select aria-label="Size"><option>Small</option><option>Large</option></select>
    <div style="display:none"><button>Hidden button</button></div>
    <button onclick="document.getElementById('out').textContent='clicked!'">Do it</button>
    <p id="out"></p>`,
  '/second': '<!doctype html><title>Second</title><h1>Second page</h1>',
  '/search': '<!doctype html><title>Results</title><h1>Results</h1>',
}

test('the agent reads, clicks, types and refuses password fields in a real Chromium', async (t) => {
  const binary = findChromium()
  if (!binary) { t.skip('no Chromium here'); return }
  const site = createServer((req, res) => {
    const page = PAGES[new URL(req.url, 'http://x').pathname]
    res.writeHead(page ? 200 : 404, { 'content-type': 'text/html' })
    res.end(page || 'missing')
  })
  await new Promise((r) => site.listen(0, '127.0.0.1', r))
  const base = `http://127.0.0.1:${site.address().port}`
  const profile = mkdtempSync(join(tmpdir(), 'ada-browser-test-'))
  const agent = new BrowserAgent({ binary, profile, size: '1280x800', headless: true, quiet: true })
  await agent.start()
  const control = serve(agent, { port: 0, token: 'tok' })
  await new Promise((r) => control.once('listening', r))
  const call = (request) => new Promise((resolve, reject) => {
    const socket = connect(control.address().port, '127.0.0.1')
    let data = ''
    socket.on('data', (c) => { data += c })
    socket.on('end', () => { try { resolve(JSON.parse(data)) } catch (e) { reject(e) } })
    socket.on('error', reject)
    socket.write(JSON.stringify({ token: 'tok', ...request }) + '\n')
  })
  try {
    assert.match((await call({ token: 'wrong', op: 'status' })).message, /Wrong browser token/)
    const opened = await call({ op: 'open', url: base + '/' })
    assert.equal(opened.ok, true, opened.message)
    const text = opened.page.text
    assert.match(text, /# Shop/)
    assert.match(text, /Welcome to the test shop/)
    assert.doesNotMatch(text, /Hidden button/)
    assert.doesNotMatch(text, /secret-value/)
    assert.match(text, /password field "Password" \(Ada cannot type here/)
    const ref = (pattern) => text.split('\n').find((l) => pattern.test(l)).match(/^\[(\d+)\]/)[1]

    const password = ref(/password field/)
    const refused = await call({ op: 'type', ref: password, text: 'x' })
    assert.equal(refused.ok, false)
    assert.match(refused.message, /never types into password/)

    const signIn = await call({ op: 'describe', ref: ref(/button "Sign in"/) })
    assert.equal(signIn.element.formHasPassword, true)
    assert.equal(signIn.element.isSubmit, true)
    assert.equal(signIn.element.formMethod, 'post')

    const doIt = await call({ op: 'click', ref: ref(/button "Do it"/) })
    assert.equal(doIt.ok, true, doIt.message)
    assert.match(doIt.page.text, /clicked!/)

    const size = await call({ op: 'select', ref: ref(/select "Size"/), option: 'large' })
    assert.equal(size.chosen, 'Large')

    // Refs stay the same between looks of one page.
    const again = await call({ op: 'look' })
    assert.equal(again.page.text.split('\n').find((l) => /button "Do it"/.test(l)).match(/^\[(\d+)\]/)[1], ref(/button "Do it"/))

    const typed = await call({ op: 'type', ref: ref(/textbox "Search"/), text: 'shoes', submit: true })
    assert.equal(typed.ok, true, typed.message)
    assert.match(typed.page.url, /\/search\?q=shoes/)

    const back = await call({ op: 'history', action: 'back' })
    assert.match(back.page.title, /Home/)

    // An approval only runs on the page it was approved on.
    const stale = await call({ op: 'click', ref: '1', expect: { url: base + '/elsewhere', name: 'x' } })
    assert.equal(stale.ok, false)
    assert.match(stale.message, /page changed/)

    await call({ op: 'control', state: 'person' })
    const locked = await call({ op: 'look' })
    assert.equal(locked.refused, true)
    await call({ op: 'control', state: 'ada' })

    const tab = await call({ op: 'open', url: base + '/second', newTab: true })
    assert.match(tab.page.title, /Second/)
    const tabs = await call({ op: 'tabs' })
    assert.equal(tabs.tabs.length, 2)
    assert.equal(tabs.tabs[1].current, true)

    const shot = await call({ op: 'screenshot' })
    assert.ok(shot.jpeg.length > 1000)

    const blocked = await call({ op: 'open', url: 'chrome://settings' })
    assert.equal(blocked.ok, false)
  } finally {
    control.close()
    agent.stop()
    site.close()
    await new Promise((r) => setTimeout(r, 500))
    rmSync(profile, { recursive: true, force: true })
  }
})
