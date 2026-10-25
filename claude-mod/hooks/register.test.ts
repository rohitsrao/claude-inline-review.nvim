import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const TOP = '/repo'
const GIT_DIR = '/repo/.git'
const SESSION = `${GIT_DIR}/claude-inline-review/session.json`

type World = {
  files: Map<string, string>
  aborted: string[]
  failHashObject: boolean
  failMv: boolean
  isGitRepo: boolean
  // What git ignores, and what each fake Bash command writes.
  gitignored: Set<string>
  scripts: Map<string, Record<string, string>>
}

const TRACKED = new Set(['a.txt', 'b.txt'])

// The engine beneath the mod: an in-memory file system and just enough git.
function world(on: On): World {
  const w: World = {
    files: new Map([[`${TOP}/a.txt`, 'one\n'], [`${TOP}/b.txt`, 'two\n']]),
    aborted: [],
    failHashObject: false,
    failMv: false,
    isGitRepo: true,
    gitignored: new Set(),
    scripts: new Map(),
  }
  const ok = (stdout = '') => ({
    value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  })
  const fail = (stderr: string) => ({
    value: { exitCode: 1, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false },
  })

  on('fs.exists', (_, e) => ({ value: w.files.has(e.path) }))
  on('fs.read', (_, e) => {
    const text = e.path.endsWith('plugin.json') ? '{"version":"0.1.0"}' : w.files.get(e.path)
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_, e) => {
    w.files.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.list', (_, e) => ({
    value: [...w.files.keys()]
      .filter(path => path.startsWith(`${e.path}/`))
      .map(path => ({ name: path.slice(e.path.length + 1), kind: 'file' as const, size: 0, mtimeMs: 0, isLink: false })),
  }))
  on('fs.stat', () => {
    throw new Error('ENOENT')
  })
  on('process.run', (_, e) => {
    const [cmd, ...args] = e.argv

    if (cmd === 'mv') {
      if (w.failMv) return fail('disk full')
      const [, from, to] = args
      w.files.set(to!, w.files.get(from!)!)
      w.files.delete(from!)
      return ok()
    }
    if (cmd === 'rm') {
      w.files.delete(args[1]!)
      return ok()
    }
    if (!w.isGitRepo) return { value: { ...fail('fatal: not a git repository').value, exitCode: 128 } }
    if (args[0] === 'rev-parse' && args[1] === '--show-toplevel') return ok(`${TOP}\n${GIT_DIR}\n`)
    if (args[0] === 'rev-parse') return ok('headsha\n')
    if (args[0] === 'ls-files') {
      const listed = [...w.files.keys()]
        .filter(path => path.startsWith(`${TOP}/`) && !path.startsWith(`${GIT_DIR}/`))
        .map(path => path.slice(TOP.length + 1))
        .filter(rel => !TRACKED.has(rel) && !w.gitignored.has(rel))
      return ok(listed.map(rel => `${rel}\0`).join(''))
    }
    if (args[0] === 'hash-object') {
      if (w.failHashObject) return fail('fatal: unable to write object')
      const text = w.files.get(args[args.length - 1]!) ?? ''
      return ok(`sha-${text.trim()}\n`)
    }
    return fail(`unexpected ${e.argv.join(' ')}`)
  })
  on('turn.abort', (_, e) => {
    w.aborted.push(e.turnId)
    return { value: undefined }
  })
  on('ui.toast', () => ({ value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  // The Edit tool: replaces old_string in the file.
  on('tool.call', { tool: 'Edit' }, (_, e) => {
    const text = w.files.get(e.file_path)
    if (text === undefined || !text.includes(e.old_string)) {
      return { isError: true, result: 'String not found', text: 'String not found' }
    }
    w.files.set(e.file_path, text.replace(e.old_string, e.new_string))
    return { result: { filePath: e.file_path }, text: 'edited' } as never
  })
  on('tool.call', { tool: 'Write' }, (_, e) => {
    w.files.set(e.file_path, e.content)
    return { result: { filePath: e.file_path }, text: 'written' } as never
  })
  // The Bash tool: writes the files its command's script names.
  on('tool.call', { tool: 'Bash' }, (_, e) => {
    for (const [rel, text] of Object.entries(w.scripts.get(e.command) ?? {})) {
      w.files.set(`${TOP}/${rel}`, text)
    }
    return { result: { stdout: '', stderr: '' }, text: '' } as never
  })

  return w
}

function session(w: World) {
  const text = w.files.get(SESSION)
  return text === undefined ? undefined : JSON.parse(text)
}

const edit = (file: string, old_string: string, new_string: string, tool_use_id = crypto.randomUUID()) =>
  ({ tool: 'Edit' as const, file_path: `${TOP}/${file}`, old_string, new_string, replace_all: false, tool_use_id })

const bash = (command: string, tool_use_id = crypto.randomUUID()) =>
  ({ tool: 'Bash' as const, command, tool_use_id })

const start = (turnId: string) => ({ text: 'go', turnId })

const complete = (turnId: string, reason: 'answer' | 'aborted') =>
  ({ answer: '', durationMs: 1, isAborted: reason === 'aborted', turnId, reason })

test('a first edit is photographed and Claude reads the same output', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))

  const ran = await $.tool.call(edit('a.txt', 'one', 'ONE'))

  expect(ran.deny).toBeUndefined()
  expect(ran.text).toBe('edited')
  expect(w.files.get(`${TOP}/a.txt`)).toBe('ONE\n')
  expect(w.aborted).toEqual([])

  const s = session(w)
  expect(s.status).toBe('working')
  expect(s.head).toBe('headsha')
  expect(s.files['a.txt'].baseline).toBe('sha-one')
  expect(s.files['a.txt'].firstTurnId).toBe('t1')
  expect(s.files['a.txt'].events).toHaveLength(1)
})

test('later edits keep the first photo, and the turn end marks ready', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))
  await $.tool.call(edit('a.txt', 'ONE', 'uno'))
  await $.turn.complete(complete('t1', 'answer'))

  const s = session(w)
  expect(s.files['a.txt'].baseline).toBe('sha-one')
  expect(s.files['a.txt'].events).toHaveLength(2)
  expect(s.status).toBe('ready')
  expect(s.turnId).toBe('t1')
})

test('a new file has a null baseline', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call({ tool: 'Write', file_path: `${TOP}/new.txt`, content: 'hi\n', tool_use_id: 'w1' })

  expect(session(w).files['new.txt'].baseline).toBe(null)
})

test('a failed edit that changed nothing leaves no record', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))

  const ran = await $.tool.call(edit('a.txt', 'missing', 'x'))

  expect(ran.isError).toBe(true)
  expect(session(w)).toBeUndefined()
})

test('a file outside the repo passes through unrecorded', async ($, on) => {
  const w = world(on)
  w.files.set('/elsewhere/c.txt', 'three\n')
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))

  await $.tool.call({ ...edit('a.txt', 'three', '3'), file_path: '/elsewhere/c.txt' })

  expect(w.files.get('/elsewhere/c.txt')).toBe('3\n')
  expect(session(w)).toBeUndefined()
})

test('a photo that fails denies the call, stops the turn and keeps the record', async ($, on) => {
  const w = world(on)
  const rows = mock.session(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))

  w.failHashObject = true
  const ran = await $.tool.call(edit('b.txt', 'two', 'TWO'))

  expect(ran.deny).toMatch(/claude-inline-review failed: git hash-object on b.txt failed/)
  expect(w.files.get(`${TOP}/b.txt`)).toBe('two\n')
  expect(w.aborted).toEqual(['t1'])
  expect(JSON.stringify(rows.appended())).toMatch(/Claude was stopped/)

  // The stop it made itself is not an Esc: the record stays for recovery.
  await $.turn.complete(complete('t1', 'aborted'))
  expect(Object.keys(session(w).files)).toEqual(['a.txt'])
})

test('a save that fails after the edit returns the output unchanged and stops the turn', async ($, on) => {
  const w = world(on)
  const rows = mock.session(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))

  // The photo of a.txt is taken; only the save after the second edit fails.
  w.failMv = true
  const ran = await $.tool.call(edit('a.txt', 'ONE', 'uno'))

  expect(ran.deny).toBeUndefined()
  expect(ran.text).toBe('edited')
  expect(w.aborted).toEqual(['t1'])
  expect(JSON.stringify(rows.appended())).toMatch(/blob sha-one/)
})

test('Esc drops only the files first touched in the aborted turn', async ($, on) => {
  const w = world(on)
  const rows = mock.session(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })

  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))
  await $.turn.complete(complete('t1', 'answer'))

  await $.turn.start(start('t2'))
  await $.tool.call(edit('a.txt', 'ONE', 'uno'))
  await $.tool.call(edit('b.txt', 'two', 'TWO'))
  await $.turn.complete(complete('t2', 'aborted'))

  const s = session(w)
  expect(Object.keys(s.files)).toEqual(['a.txt'])
  expect(s.status).toBe('ready')
  // Claude's changes stay in the files.
  expect(w.files.get(`${TOP}/b.txt`)).toBe('TWO\n')

  const text = JSON.stringify(rows.appended())
  expect(text).toMatch(/dropped 1 file from review \(b.txt\)/)
  expect(text).toMatch(/still in review with this turn's changes: a.txt/)
})

test('Esc on a turn that first touched every file deletes the record', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))
  await $.turn.complete(complete('t1', 'aborted'))

  expect(session(w)).toBeUndefined()
  expect([...w.files.keys()].some(path => path.includes('claude-inline-review'))).toBe(false)
})

test('a failure stop does not protect a later turn ended with Esc', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))
  w.failHashObject = true
  await $.tool.call(edit('b.txt', 'two', 'TWO'))
  await $.turn.complete(complete('t1', 'aborted'))
  w.failHashObject = false

  await $.turn.start(start('t2'))
  await $.tool.call(edit('b.txt', 'two', 'TWO'))
  await $.turn.complete(complete('t2', 'aborted'))

  expect(Object.keys(session(w).files)).toEqual(['a.txt'])
})

test('a record deleted from outside starts a fresh review', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(edit('a.txt', 'one', 'ONE'))
  const first = session(w).reviewId

  // Neovim finishing the review deletes session.json.
  w.files.delete(SESSION)
  await $.tool.call(edit('b.txt', 'two', 'TWO'))

  const s = session(w)
  expect(s.reviewId).not.toBe(first)
  expect(Object.keys(s.files)).toEqual(['b.txt'])
})

test('outside a git repo the mod is off and never interrupts', async ($, on) => {
  const w = world(on)
  w.isGitRepo = false
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))

  const ran = await $.tool.call(edit('a.txt', 'one', 'ONE'))

  expect(ran.text).toBe('edited')
  expect(session(w)).toBeUndefined()
  expect(w.aborted).toEqual([])
})

test('a file Bash creates is recorded as new', async ($, on) => {
  const w = world(on)
  w.scripts.set('cat > src/new.ts', { 'src/new.ts': 'export const x = 1\n' })
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(bash('cat > src/new.ts'))

  const entry = session(w).files['src/new.ts']
  expect(entry.baseline).toBe(null)
  expect(entry.firstTurnId).toBe('t1')
  expect(entry.events[0].tool).toBe('Bash')
})

test('Bash leaves generated, gitignored, lock, binary and empty files out', async ($, on) => {
  const w = world(on)
  w.gitignored.add('dist/out.js')
  w.scripts.set('codegen', {
    'lib/model.g.dart': '// GENERATED CODE - DO NOT MODIFY BY HAND\npart of model;\n',
    'api/api.pb.go': '// Code generated by protoc-gen-go. DO NOT EDIT.\npackage api\n',
    'dist/out.js': 'console.log(1)\n',
    'package-lock.json': '{}\n',
    'Cargo.lock': 'version = 3\n',
    'logo.png': '\u0089PNG\0\0',
    'empty.ts': '',
    'src/hand.ts': 'export const y = 2\n',
  })
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(bash('codegen'))

  expect(Object.keys(session(w).files)).toEqual(['src/hand.ts'])
})

test('a file that was untracked before Bash ran is not recorded', async ($, on) => {
  const w = world(on)
  w.files.set(`${TOP}/notes.md`, 'mine\n')
  w.scripts.set('echo >> notes.md', { 'notes.md': 'mine\nmore\n' })
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(bash('echo >> notes.md'))

  expect(session(w)).toBe(undefined)
})

test('a later Edit of a file Bash created keeps its null baseline', async ($, on) => {
  const w = world(on)
  w.scripts.set('touch c.txt', { 'c.txt': 'three\n' })
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(bash('touch c.txt'))
  await $.tool.call(edit('c.txt', 'three', '3'))

  const entry = session(w).files['c.txt']
  expect(entry.baseline).toBe(null)
  expect(entry.events).toHaveLength(2)
})

test('Esc drops the files Bash created in the aborted turn', async ($, on) => {
  const w = world(on)
  w.scripts.set('make c', { 'c.txt': 'three\n' })
  await $.session.start({ cwd: TOP, surface: 'terminal', isInteractive: true })
  await $.turn.start(start('t1'))
  await $.tool.call(bash('make c'))
  await $.turn.complete(complete('t1', 'aborted'))

  expect(session(w)).toBe(undefined)
})
