import type { EngineInterface, Register } from 'claude-code'

// The record this mod writes to <git-dir>/claude-inline-review/session.json.
// Neovim reads it and never writes it; the file on disk is the source of
// truth, so every change is a read-modify-write under one lock.
type FileEvent = { tool: string; at: number; turnId: string | null }

type FileEntry = {
  // Blob SHA of the file just before Claude's first touch; null: did not exist.
  baseline: string | null
  // The main-loop turn of that first touch: an Esc on it drops the file.
  firstTurnId: string | null
  events: FileEvent[]
}

type Session = {
  reviewId: string
  modVersion: string
  head: string | null
  status: 'working' | 'ready'
  turnId: string | null
  files: Record<string, FileEntry>
}

type Repo = { top: string; gitDir: string }

type Photo = { baseline: string | null; isNew: boolean }

// The tool's name as people know it; the mod itself is nvim-inline-review.
const NAME = 'claude-inline-review'
const GIT_TIMEOUT_MS = 10_000
const SESSION_FILE = 'session.json'
const TOAST_MS = 10_000

class RecordError extends Error {}

// Module state is lost on every reload: none of it is the record itself.
let repo: Repo | undefined
let cwd = '/'
let modVersion = '0.0.0'
let mainTurnId: string | undefined
let selfAborted = false
let lock: Promise<unknown> = Promise.resolve()

// Runs record changes one at a time: parallel tool calls and turn events
// each read, change and write session.json whole.
function serial<T>(work: () => Promise<T>): Promise<T> {
  const run = lock.then(work, work)
  lock = run.catch(() => undefined)

  return run
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

function recordDir(r: Repo): string {
  return `${r.gitDir}/${NAME}`
}

function sessionPath(r: Repo): string {
  return `${recordDir(r)}/${SESSION_FILE}`
}

async function run(
  $: EngineInterface,
  argv: string[],
  what: string,
): Promise<string> {
  const ran = await $.process
    .run(argv, { cwd: repo?.top ?? cwd, timeoutMs: GIT_TIMEOUT_MS })
    .catch(err => {
      throw new RecordError(`${what}: ${messageOf(err)}`)
    })

  if (ran.exitCode !== 0) {
    throw new RecordError(`${what} exited ${ran.exitCode}: ${ran.stderr.trim()}`)
  }

  return ran.stdout.trim()
}

async function headOf($: EngineInterface): Promise<string | null> {
  const ran = await $.process.run(['git', 'rev-parse', '-q', '--verify', 'HEAD'], {
    cwd: repo?.top ?? cwd,
    timeoutMs: GIT_TIMEOUT_MS,
  })

  // A repo with no commits yet has no HEAD to verify.
  return ran.exitCode === 0 ? ran.stdout.trim() : null
}

async function readSession($: EngineInterface, r: Repo): Promise<Session | undefined> {
  const path = sessionPath(r)

  if (!(await $.fs.exists(path))) return undefined

  try {
    return JSON.parse(await $.fs.read(path)) as Session
  } catch (err) {
    throw new RecordError(`could not read ${SESSION_FILE} (${messageOf(err)})`)
  }
}

// Writes a temp file and renames it into place, so Neovim never reads half
// a record.
async function writeSession($: EngineInterface, r: Repo, s: Session): Promise<void> {
  const path = sessionPath(r)
  const tmp = `${path}.tmp-${crypto.randomUUID()}`

  try {
    await $.fs.write(tmp, `${JSON.stringify(s, null, 2)}\n`)
    await run($, ['mv', '-f', tmp, path], `could not save ${SESSION_FILE}`)
  } catch (err) {
    await $.process.run(['rm', '-f', tmp]).catch(() => undefined)
    throw err instanceof RecordError
      ? err
      : new RecordError(`could not save ${SESSION_FILE} (${messageOf(err)})`)
  }
}

// Deletes this mod's own files by exact name: session.json and any temp
// file left by an interrupted write. Neovim deletes its own files.
async function deleteSession($: EngineInterface, r: Repo): Promise<void> {
  const dir = recordDir(r)
  const entries = await $.fs.list(dir).catch(() => [])
  const ours = entries
    .map(entry => entry.name)
    .filter(name => name === SESSION_FILE || name.startsWith(`${SESSION_FILE}.tmp-`))

  for (const name of ours) {
    await run($, ['rm', '-f', `${dir}/${name}`], `could not delete ${name}`)
  }
}

function under(top: string, path: string): string | undefined {
  return path.startsWith(`${top}/`) ? path.slice(top.length + 1) : undefined
}

// The file's path relative to the repo root, or undefined when it is outside
// this repo (or inside its .git folder): such files are left alone.
async function repoPath($: EngineInterface, r: Repo, filePath: string): Promise<string | undefined> {
  const abs = filePath.startsWith('/') ? filePath : `${cwd}/${filePath}`
  let rel = under(r.top, abs)

  if (rel === undefined) {
    // git's toplevel has symlinks resolved (/tmp is /private/tmp on macOS).
    const own = await $.fs.stat(abs, { resolve: true }).catch(() => undefined)
    let real = own?.realPath

    if (real === undefined) {
      const cut = abs.lastIndexOf('/')
      const dir = await $.fs.stat(abs.slice(0, cut) || '/', { resolve: true }).catch(() => undefined)
      real = dir?.realPath === undefined ? undefined : `${dir.realPath.replace(/\/$/, '')}${abs.slice(cut)}`
    }

    rel = real === undefined ? undefined : under(r.top, real)
  }

  if (rel === undefined || rel === '.git' || rel.startsWith('.git/')) return undefined

  return rel
}

async function hashFile($: EngineInterface, r: Repo, rel: string, write: boolean): Promise<string | null> {
  const abs = `${r.top}/${rel}`

  if (!(await $.fs.exists(abs))) return null

  const argv = write ? ['git', 'hash-object', '-w', '--', abs] : ['git', 'hash-object', '--', abs]

  return run($, argv, `git hash-object on ${rel} failed`)
}

// Before a tool runs: photographs the file on Claude's first touch of it in
// this review and saves the entry, so even a crash mid-turn keeps the photo.
async function photograph($: EngineInterface, r: Repo, rel: string): Promise<Photo> {
  const existing = await readSession($, r)
  const known = existing?.files[rel]

  if (known !== undefined) return { baseline: known.baseline, isNew: false }

  const session: Session = existing ?? {
    reviewId: crypto.randomUUID(),
    modVersion,
    head: await headOf($),
    status: 'working',
    turnId: mainTurnId ?? null,
    files: {},
  }
  const baseline = await hashFile($, r, rel, true)

  session.files[rel] = { baseline, firstTurnId: mainTurnId ?? null, events: [] }
  session.status = 'working'
  await writeSession($, r, session)

  return { baseline, isNew: true }
}

// After a tool ran: logs a change, or drops the entry this call made when
// the tool changed nothing.
async function afterRun(
  $: EngineInterface,
  r: Repo,
  rel: string,
  tool: string,
  photo: Photo,
  hasFailed: boolean,
): Promise<void> {
  const session = await readSession($, r)
  const entry = session?.files[rel]

  // Gone: an Esc dropped it, or the review was cleaned up meanwhile.
  if (session === undefined || entry === undefined) return

  if (hasFailed) {
    const isUntouched = photo.isNew && entry.events.length === 0
      && (await hashFile($, r, rel, false)) === entry.baseline

    if (!isUntouched) return

    delete session.files[rel]
    if (Object.keys(session.files).length === 0) return deleteSession($, r)

    return writeSession($, r, session)
  }

  entry.events.push({ tool, at: Date.now(), turnId: mainTurnId ?? null })
  await writeSession($, r, session)
}

async function notice($: EngineInterface, text: string): Promise<void> {
  await $.session
    .append({ message: { type: 'system', content: [{ type: 'text', text }] } })
    .catch(() => undefined)
}

// The one interruption this mod makes: a change it could not record must
// not slip past review, so Claude is stopped and told nothing.
async function stopClaude($: EngineInterface, reason: string, rel: string, photo?: Photo): Promise<void> {
  selfAborted = true

  const first = `${NAME} failed: ${reason}. Claude was stopped.`
  const recovery = photo === undefined
    ? ''
    : photo.baseline === null
      ? ` ${rel} did not exist before Claude's first touch.`
      : ` Before-snapshot of ${rel}: blob ${photo.baseline}, recover with :ClaudeInlineReview recover ${rel} ${photo.baseline}`

  await notice($, first + recovery)
  $.ui.toast(first, { timeoutMs: TOAST_MS })

  if (mainTurnId !== undefined) {
    await $.turn.abort({ turnId: mainTurnId }).catch(() => undefined)
  }
}

// Headers code generators write at the top of their output: Go's
// "Code generated ... DO NOT EDIT.", Dart's "GENERATED CODE - DO NOT MODIFY",
// protoc's "Generated by the protocol buffer compiler", @generated, ...
const GENERATED_MARK = /@generated|\bdo not (edit|modify)\b|\bauto-?generated\b|\bcode generated\b|\bgenerated by\b/i
const GENERATED_HEAD_LINES = 10
// Lockfiles package managers write, most without a generated header.
const LOCKFILE = /(^|\/)([^/]+\.lock|[^/]+-lock\.(json|yaml)|npm-shrinkwrap\.json|go\.sum)$/

// An inline Python script fed through a heredoc (python3 - <<'EOF'). It can
// rewrite any tracked file, so after it runs git tells which ones changed.
const PYTHON_HEREDOC = /\bpython3?\s+-\s*<</

// A file Bash changed, with its content from just before (null: created).
type Change = { rel: string; baseline: string | null }

// The NUL-separated paths a git listing prints, relative to the repo root.
async function gitList($: EngineInterface, r: Repo, args: string[]): Promise<Set<string>> {
  const what = `git ${args[0]}`
  const ran = await $.process
    .run(['git', ...args, '-z'], { cwd: r.top, timeoutMs: GIT_TIMEOUT_MS })
    .catch(err => {
      throw new RecordError(`${what}: ${messageOf(err)}`)
    })

  if (ran.exitCode !== 0) {
    throw new RecordError(`${what} exited ${ran.exitCode}: ${ran.stderr.trim()}`)
  }
  if (ran.isStdoutTruncated) throw new RecordError(`${what} listed too many files`)

  return new Set(ran.stdout.split('\0').filter(path => path !== ''))
}

// The untracked files git sees (gitignored ones left out).
function untracked($: EngineInterface, r: Repo): Promise<Set<string>> {
  return gitList($, r, ['ls-files', '--others', '--exclude-standard'])
}

// The tracked files whose working copy differs from the index, each with
// its blob SHA (written, so it can be recovered); null: deleted.
async function photographModified($: EngineInterface, r: Repo): Promise<Map<string, string | null>> {
  const photos = new Map<string, string | null>()

  for (const rel of await gitList($, r, ['diff', '--name-only'])) {
    photos.set(rel, await hashFile($, r, rel, true))
  }

  return photos
}

// The tracked files a command changed, each with its content from just
// before: the photo for a file already modified, the index blob for the rest
// (their working copy matched the index).
async function changedTracked(
  $: EngineInterface,
  r: Repo,
  before: Map<string, string | null>,
): Promise<Change[]> {
  const after = await gitList($, r, ['diff', '--name-only'])
  const changes: Change[] = []

  for (const rel of new Set([...before.keys(), ...after])) {
    const photo = before.get(rel)

    if (photo === undefined) {
      const baseline = await run($, ['git', 'rev-parse', `:${rel}`], `git rev-parse on ${rel} failed`)
      changes.push({ rel, baseline })
    } else if ((await hashFile($, r, rel, false)) !== photo) {
      changes.push({ rel, baseline: photo })
    }
  }

  return changes
}

// A file Bash created that is worth reviewing: text, not empty, and neither a
// lockfile nor a code generator's output.
async function isReviewable($: EngineInterface, r: Repo, rel: string): Promise<boolean> {
  if (LOCKFILE.test(rel)) return false

  // Over fs.read's 4 MiB, or unreadable: not code anyone wrote by hand.
  const text = await $.fs.read(`${r.top}/${rel}`).catch(() => undefined)
  if (text === undefined || text === '' || text.includes('\0') || text.includes('�')) return false

  const head = text.split('\n', GENERATED_HEAD_LINES).join('\n')

  return !GENERATED_MARK.test(head)
}

// After Bash ran: logs a change to each file already in review, and records
// the rest with their baseline, the way a first Edit or Write is recorded.
async function recordChanged(
  $: EngineInterface,
  r: Repo,
  changes: Change[],
): Promise<void> {
  const existing = await readSession($, r)
  const session: Session = existing ?? {
    reviewId: crypto.randomUUID(),
    modVersion,
    head: await headOf($),
    status: 'working',
    turnId: mainTurnId ?? null,
    files: {},
  }
  const event: FileEvent = { tool: 'Bash', at: Date.now(), turnId: mainTurnId ?? null }

  for (const { rel, baseline } of changes) {
    const known = session.files[rel]

    if (known !== undefined) known.events.push(event)
    else session.files[rel] = { baseline, firstTurnId: mainTurnId ?? null, events: [event] }
  }
  session.status = 'working'
  await writeSession($, r, session)
}

type FileToolCall = { tool: string; tool_use_id?: string }

// Set before next(e) so a .catch knows what to report, keyed by tool_use_id.
const pending = new Map<string, { rel: string; photo?: Photo }>()

// The hook for one file tool: photograph, run the tool untouched, log it.
async function recordCall<E extends FileToolCall, R extends { deny?: string; isError?: true }>(
  $: EngineInterface,
  e: E,
  next: (e: E) => Promise<R>,
  filePath: string,
): Promise<R | { deny: string }> {
  const r = repo
  if (r === undefined) return next(e)

  const rel = await repoPath($, r, filePath)
  if (rel === undefined) return next(e)

  const key = e.tool_use_id ?? crypto.randomUUID()
  pending.set(key, { rel })

  let photo: Photo
  try {
    photo = await serial(() => photograph($, r, rel))
  } catch (err) {
    pending.delete(key)
    const reason = `${messageOf(err)} before ${e.tool} on ${rel}`
    await stopClaude($, reason, rel)

    return { deny: `${NAME} failed: ${reason}` }
  }

  pending.set(key, { rel, photo })
  const ran = await next(e)

  try {
    const hasFailed = ran.deny !== undefined || ran.isError === true
    await serial(() => afterRun($, r, rel, e.tool, photo, hasFailed))
  } catch (err) {
    await stopClaude($, `${messageOf(err)} after ${e.tool} on ${rel}`, rel, photo)
  } finally {
    pending.delete(key)
  }

  // The same object next(e) gave: Claude reads exactly what it would have.
  return ran
}

const BASH_FILES = 'the files Bash creates or changes'

// The hook for Bash: the untracked files before and after the command; the
// new ones Claude wrote by hand go into review. An inline Python script also
// puts the tracked files it changed into review.
async function recordBash<E extends FileToolCall & { command: string }, R extends { deny?: string }>(
  $: EngineInterface,
  e: E,
  next: (e: E) => Promise<R>,
): Promise<R | { deny: string }> {
  const r = repo
  if (r === undefined) return next(e)

  const key = e.tool_use_id ?? crypto.randomUUID()
  pending.set(key, { rel: BASH_FILES })

  const isPythonScript = PYTHON_HEREDOC.test(e.command)
  let before: Set<string>
  let modified = new Map<string, string | null>()
  try {
    before = await untracked($, r)
    if (isPythonScript) modified = await photographModified($, r)
  } catch (err) {
    pending.delete(key)
    const reason = `${messageOf(err)} before Bash`
    await stopClaude($, reason, BASH_FILES)

    return { deny: `${NAME} failed: ${reason}` }
  }

  const ran = await next(e)

  try {
    if (ran.deny === undefined) {
      const after = await untracked($, r)
      const changes: Change[] = []
      for (const rel of after) {
        if (!before.has(rel) && (await isReviewable($, r, rel))) changes.push({ rel, baseline: null })
      }
      if (isPythonScript) changes.push(...(await changedTracked($, r, modified)))
      if (changes.length > 0) await serial(() => recordChanged($, r, changes))
    }
  } catch (err) {
    await stopClaude($, `${messageOf(err)} after Bash`, BASH_FILES)
  } finally {
    pending.delete(key)
  }

  return ran
}

// The hook threw or overran its budget: the change must not go unrecorded.
async function recordFailed<E extends FileToolCall, R>(
  $: EngineInterface,
  e: E,
  next: ((e: E) => Promise<R>) & { called: boolean; error: { kind: string; message?: string } },
  filePath: string,
): Promise<R | { deny: string }> {
  const key = e.tool_use_id
  const known = key === undefined ? undefined : pending.get(key)
  if (key !== undefined) pending.delete(key)

  const rel = known?.rel ?? filePath
  const why = next.error.message ?? next.error.kind

  if (!next.called) {
    const reason = `${why} before ${e.tool} on ${rel}`
    await stopClaude($, reason, rel, known?.photo)

    return { deny: `${NAME} failed: ${reason}` }
  }

  const ran = await next(e)
  await stopClaude($, `${why} after ${e.tool} on ${rel}`, rel, known?.photo)

  return ran
}

export const register: Register = on => {
  on('tool.call', { tool: 'Edit' }, ($, e, next) => recordCall($, e, next, e.file_path))
    .catch(($, e, next) => recordFailed($, e, next, e.file_path))
  on('tool.call', { tool: 'Write' }, ($, e, next) => recordCall($, e, next, e.file_path))
    .catch(($, e, next) => recordFailed($, e, next, e.file_path))
  on('tool.call', { tool: 'NotebookEdit' }, ($, e, next) => recordCall($, e, next, e.notebook_path))
    .catch(($, e, next) => recordFailed($, e, next, e.notebook_path))
  on('tool.call', { tool: 'Bash' }, ($, e, next) => recordBash($, e, next))
    .catch(($, e, next) => recordFailed($, e, next, BASH_FILES))

  on('session.start', async ($, e, next) => {
    cwd = e.cwd
    repo = undefined

    const manifest = await $.fs
      .read(`${$.plugin.root}/.claude-plugin/plugin.json`)
      .catch(() => '{}')
    modVersion = (JSON.parse(manifest) as { version?: string }).version ?? modVersion

    const found = await $.process
      .run(['git', 'rev-parse', '--show-toplevel', '--absolute-git-dir'], {
        cwd: e.cwd,
        timeoutMs: GIT_TIMEOUT_MS,
      })
      .catch(() => undefined)
    const [top, gitDir] = found?.exitCode === 0 ? found.stdout.trim().split('\n') : []

    if (top === undefined || gitDir === undefined) {
      $.ui.status(`${NAME}: off (not a git repo)`)

      return next(e)
    }

    repo = { top, gitDir }
    $.ui.status(undefined)

    // A session that ended mid-turn left "working"; nothing is working now.
    await serial(async () => {
      const s = await readSession($, repo!)
      if (s?.status !== 'working') return
      s.status = 'ready'
      await writeSession($, repo!, s)
    }).catch(err => $.ui.toast(`${NAME}: ${messageOf(err)}`, { timeoutMs: TOAST_MS }))

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)

    mainTurnId = e.turnId
    selfAborted = false

    const r = repo
    if (r !== undefined) {
      await serial(async () => {
        const s = await readSession($, r)
        if (s === undefined) return
        s.status = 'working'
        s.turnId = e.turnId
        await writeSession($, r, s)
      }).catch(err => $.ui.toast(`${NAME}: ${messageOf(err)}`, { timeoutMs: TOAST_MS }))
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const r = repo
    if (e.agentId !== undefined || r === undefined) return next(e)

    // Esc, as opposed to this mod stopping the turn after a failure (which
    // keeps the whole record for recovery).
    const isEscAbort = e.reason === 'aborted' && !selfAborted

    await serial(async () => {
      const s = await readSession($, r)
      if (s === undefined) return

      s.status = 'ready'
      s.turnId = e.turnId

      if (!isEscAbort) return writeSession($, r, s)

      const paths = Object.keys(s.files)
      const dropped = paths.filter(path => s.files[path]?.firstTurnId === e.turnId)
      const kept = paths.filter(path =>
        !dropped.includes(path) && s.files[path]?.events.some(ev => ev.turnId === e.turnId))

      for (const path of dropped) delete s.files[path]

      if (Object.keys(s.files).length === 0) await deleteSession($, r)
      else await writeSession($, r, s)

      if (dropped.length === 0 && kept.length === 0) return

      const parts = [`${NAME}: turn aborted`]
      if (dropped.length > 0) {
        parts.push(`dropped ${dropped.length} file${dropped.length === 1 ? '' : 's'} from review (${dropped.join(', ')})`)
      }
      if (kept.length > 0) {
        parts.push(`still in review with this turn's changes: ${kept.join(', ')}`)
      }
      await notice($, `${parts.join(' — ')}. Claude's changes are still in your files.`)
    }).catch(err => $.ui.toast(`${NAME}: ${messageOf(err)}`, { timeoutMs: TOAST_MS }))

    return next(e)
  })
}
