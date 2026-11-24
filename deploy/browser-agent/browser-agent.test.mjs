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
import { BrowserAgent, allowedURL, controlProblem, keyFor, forbiddenShortcut, splitRef, pointProblem, serve } from './browser-agent.mjs'

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
  assert.equal(keyFor('F5').key, 'F5')
  const selectAll = keyFor('Control+A')
  assert.equal(selectAll.modifiers, 2)
  assert.deepEqual(selectAll.commands, ['selectAll'])
  assert.equal(selectAll.text, undefined)
  assert.equal(keyFor('shift+tab').modifiers, 8)
  assert.equal(keyFor('ctrl+shift+z').commands[0], 'redo')
  assert.equal(keyFor('hyper+a'), null)
  // Pasting the clipboard by shortcut could put what the person copied into a page.
  assert.match(forbiddenShortcut(keyFor('ctrl+v')), /browser_paste/)
  assert.match(forbiddenShortcut(keyFor('Control+Shift+V')), /browser_paste/)
  assert.equal(forbiddenShortcut(keyFor('ctrl+c')), null)
})

test('refs name elements in the page or in a frame, and points must be in the window', () => {
  assert.deepEqual(splitRef('12'), { frame: 0, ref: '12' })
  assert.deepEqual(splitRef('[2.5]'), { frame: 2, ref: '5' })
  assert.equal(splitRef('a'), null)
  assert.equal(splitRef('1.2.3'), null)
  const window = { width: 1280, height: 800 }
  assert.equal(pointProblem(10, 10, window), null)
  assert.match(pointProblem(1280, 10, window), /outside the window/)
  assert.match(pointProblem(Number.NaN, 10, window), /must be numbers/)
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
  // An editor page like CryptPad's: the writing happens inside a frame from another site.
  '/editor': `<!doctype html><title>Editor</title><style>body{margin:0}iframe{position:absolute;border:0}</style>
    <h1>Pad</h1>
    <iframe id="same" src="/inner" title="Toolbar" style="left:0;top:100px;width:600px;height:150px"></iframe>
    <iframe id="other" src="OTHER/pad" title="Pad body" style="left:0;top:300px;width:800px;height:400px"></iframe>`,
  '/inner': '<!doctype html><title>Toolbar</title><button onclick="document.body.dataset.n=(+document.body.dataset.n||0)+1;this.textContent=\'Bold \'+document.body.dataset.n">Bold</button>',
  '/pad': `<!doctype html><title>Pad</title><style>body{margin:0}#ed{position:absolute;left:20px;top:20px;width:500px;height:150px;border:1px solid}#pad{position:absolute;left:20px;top:200px;width:300px;height:100px;background:#eee}</style>
    <div id="ed" contenteditable="true" aria-label="Pad text"></div>
    <div id="pad" onmousedown="this.dataset.down=event.offsetX+','+event.offsetY" onmouseup="document.getElementById('log').textContent='down '+this.dataset.down+' up '+event.offsetX+','+event.offsetY"></div>
    <p id="log">nothing yet</p>
    <button onclick="this.textContent='Sent'" style="position:absolute;left:400px;top:220px">Send</button>
    <input type="password" aria-label="Secret" style="position:absolute;left:600px;top:220px">`,
}

test('the agent reads, clicks, types and refuses password fields in a real Chromium', async (t) => {
  const binary = findChromium()
  if (!binary) { t.skip('no Chromium here'); return }
  const site = createServer((req, res) => {
    const page = PAGES[new URL(req.url, 'http://x').pathname]
    res.writeHead(page ? 200 : 404, { 'content-type': 'text/html' })
    res.end(page ? page.replace('OTHER', `http://localhost:${site.address().port}`) : 'missing')
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
    assert.equal(tabs.tabs[1].current, true, JSON.stringify(tabs.tabs))

    const shot = await call({ op: 'screenshot' })
    assert.ok(shot.jpeg.length > 1000)

    const blocked = await call({ op: 'open', url: 'chrome://settings' })
    assert.equal(blocked.ok, false)

    // Frames: the outline reads inside them, from this site and from another one.
    await call({ op: 'tabs', action: 'close', tab: 2 })
    const editor = await call({ op: 'open', url: base + '/editor' })
    assert.equal(editor.ok, true, editor.message)
    const outline = editor.page.text
    assert.match(outline, /── Frame \d+ "Toolbar"/)
    assert.match(outline, /── Frame \d+ "Pad" \(localhost:\d+\)/)
    assert.doesNotMatch(outline, /contents are not readable/)
    const frameRef = (pattern) => outline.split('\n').find((l) => pattern.test(l)).match(/^\[(\d+\.\d+)\]/)[1]
    const bold = await call({ op: 'click', ref: frameRef(/button "Bold"/) })
    assert.equal(bold.ok, true, bold.message)
    assert.match(bold.page.text, /button "Bold 1"/)
    const sendInFrame = await call({ op: 'describe', ref: frameRef(/button "Send"/) })
    assert.equal(sendInFrame.element.name, 'Send')
    assert.equal(sendInFrame.element.inFrame, true)

    // The mouse: what is at a point, clicking and dragging there, inside the other site's frame.
    const at = await call({ op: 'describe_point', x: 410, y: 530 })
    assert.equal(at.ok, true, at.message)
    assert.equal(at.element.name, 'Send')
    const outside = await call({ op: 'mouse', action: 'click', x: 5000, y: 10 })
    assert.match(outside.message, /outside the window/)
    const drag = await call({ op: 'mouse', action: 'drag', x: 50, y: 530, toX: 150, toY: 560 })
    assert.equal(drag.ok, true, drag.message)
    assert.match(drag.page.text, /down 30,30 up 130,60/)
    // An approved point-click runs only if the same thing is still there.
    const moved = await call({ op: 'mouse', action: 'click', x: 410, y: 530, expect: { url: base + '/elsewhere', name: 'Send', x: 410, y: 530 } })
    assert.match(moved.message, /page changed/)

    // Writing in the frame's editor: click into it, then type and paste into what has the focus.
    const into = await call({ op: 'mouse', action: 'click', x: 100, y: 360 })
    assert.equal(into.ok, true, into.message)
    const focus = await call({ op: 'describe' })
    assert.equal(focus.element.name, 'Pad text')
    assert.equal(focus.element.editable, true)
    const typedIn = await call({ op: 'type', text: 'Hello ' })
    assert.equal(typedIn.ok, true, typedIn.message)
    const pasted = await call({ op: 'paste', text: 'first line\nsecond line' })
    assert.equal(pasted.ok, true, pasted.message)
    assert.match(pasted.message, /Pasted 22 characters with Ctrl\+V/)
    const pad = await call({ op: 'look', query: 'Pad text' })
    assert.match(pad.page.text, /Hello first line/)
    assert.match(pad.page.text, /second line/)
    const all = await call({ op: 'key', key: 'Control+A' })
    assert.equal(all.ok, true, all.message)
    await call({ op: 'key', key: 'Backspace' })
    const empty = await call({ op: 'look', query: 'Pad text' })
    assert.doesNotMatch(empty.page.text, /second line/)
    const noPaste = await call({ op: 'key', key: 'ctrl+v' })
    assert.match(noPaste.message, /browser_paste/)

    // A password field inside a frame is refused too.
    const onSecret = await call({ op: 'describe_point', x: 610, y: 530 })
    assert.equal(onSecret.element?.isPassword, true, JSON.stringify(onSecret))
    await call({ op: 'mouse', action: 'click', x: 610, y: 530 })
    const focusedSecret = await call({ op: 'describe' })
    assert.equal(focusedSecret.element.isPassword, true, JSON.stringify(focusedSecret))
    const secret = await call({ op: 'paste', text: 'hunter2' })
    assert.equal(secret.ok, false)
    assert.match(secret.message, /never types into password/)

    const byRef = await call({ op: 'type', ref: frameRef(/textbox "Pad text"/), text: 'via ref' })
    assert.equal(byRef.ok, true, byRef.message)
    assert.match(byRef.page.text, /textbox "Pad text" text="via ref"/)
    const scrolled = await call({ op: 'scroll', direction: 'down', x: 100, y: 360 })
    assert.equal(scrolled.ok, true, scrolled.message)

    const gridShot = await call({ op: 'screenshot', grid: true })
    assert.equal(gridShot.width, 1280)
    assert.equal(gridShot.grid, true)
    const afterGrid = await call({ op: 'look' })
    assert.doesNotMatch(afterGrid.page.text, /__ada_grid/)
  } finally {
    control.close()
    agent.stop()
    site.close()
    await new Promise((r) => setTimeout(r, 500))
    rmSync(profile, { recursive: true, force: true })
  }
})
