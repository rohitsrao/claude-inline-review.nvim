-- git.lua: every git call the plugin makes.
--
-- Inside a job started with M.async, a call waits without blocking Neovim (the
-- job is a coroutine resumed when git exits). Anywhere else it blocks, which is
-- what the accept/reject keys want: they finish before you press the next key.
local M = {}

local TIMEOUT_MS = 10000

local owned = {}  -- the coroutines M.async started
local queue = {}
local busy = false

local step

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.notify("claude-inline-review: " .. tostring(err), vim.log.levels.ERROR)
  end
  if coroutine.status(co) == "dead" then
    owned[co] = nil
    busy = false
    vim.schedule(step)
  end
end

step = function()
  if busy then return end
  local job = table.remove(queue, 1)
  if not job then return end

  busy = true
  local co = coroutine.create(function()
    local ok, err = xpcall(job, debug.traceback)
    if not ok then error(err, 0) end
  end)
  owned[co] = true
  resume(co)
end

-- Queues a background job. Jobs run one at a time, in order.
function M.async(job)
  table.insert(queue, job)
  step()
end

-- Runs argv and returns vim.system's result: { code, stdout, stderr }.
function M.system(argv, opts)
  opts = opts or {}
  local sysopts = { cwd = opts.cwd, stdin = opts.stdin, text = true, timeout = TIMEOUT_MS }
  local co = coroutine.running()

  if co and owned[co] then
    vim.system(argv, sysopts, function(result)
      vim.schedule(function() resume(co, result) end)
    end)
    return coroutine.yield()
  end

  return vim.system(argv, sysopts):wait()
end

-- Runs git in the repo; returns stdout, or nil and stderr when git fails.
function M.git(top, args, stdin)
  local argv = { "git" }
  vim.list_extend(argv, args)
  local result = M.system(argv, { cwd = top, stdin = stdin })
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end
  return result.stdout or ""
end

-- The repo's top folder and git-dir for `dir`, or nil outside a work tree.
function M.repo(dir)
  local out = M.git(dir, { "rev-parse", "--show-toplevel", "--absolute-git-dir" })
  if not out then return nil end
  local lines = vim.split(vim.trim(out), "\n", { plain = true })
  if #lines < 2 then return nil end
  return lines[1], lines[2]
end

local blobs = {}  -- sha -> text; a blob never changes

function M.cat_file(top, sha)
  if blobs[sha] == nil then
    local out, err = M.git(top, { "cat-file", "blob", sha })
    if not out then
      error(("git cat-file blob %s failed: %s"):format(sha, err))
    end
    blobs[sha] = out
  end
  return blobs[sha]
end

-- Stores text in git's object store (no commit, index untouched) and returns
-- its SHA. `rel` applies that path's filters, as the mod's snapshots do.
function M.store_text(top, rel, text)
  local out, err = M.git(top, { "hash-object", "-w", "--stdin", "--path=" .. rel }, text)
  if not out then
    error(("git hash-object failed: %s"):format(err))
  end
  local sha = vim.trim(out)
  blobs[sha] = text
  return sha
end

-- The working copy's SHA, or nil when the file is missing.
function M.worktree_sha(top, rel)
  if not vim.uv.fs_stat(top .. "/" .. rel) then return nil end
  local out = M.git(top, { "hash-object", "--", rel })
  return out and vim.trim(out) or nil
end

-- The SHA of `rel` as HEAD holds it, or nil when HEAD lacks it.
function M.committed(top, rel)
  local out = M.git(top, { "rev-parse", "-q", "--verify", "HEAD:" .. rel })
  return out and vim.trim(out) or nil
end

function M.head(top)
  local out = M.git(top, { "rev-parse", "-q", "--verify", "HEAD" })
  return out and vim.trim(out) or nil
end

function M.is_ancestor(top, older, newer)
  return M.git(top, { "merge-base", "--is-ancestor", older, newer }) ~= nil
end

-- The set of paths that differ between two commits.
function M.changed_between(top, older, newer)
  local out = M.git(top, { "diff", "--name-only", "-z", older, newer }) or ""
  local set = {}
  for _, path in ipairs(vim.split(out, "\0", { plain = true, trimempty = true })) do
    set[path] = true
  end
  return set
end

-- The set of `paths` that .claudereviewignore matches, by git's own rules.
function M.ignored(top, paths)
  local set = {}
  local file = top .. "/.claudereviewignore"
  if #paths == 0 or not vim.uv.fs_stat(file) then return set end

  local args = { "ls-files", "--cached", "--others", "--ignored", "--exclude-from=" .. file, "-z", "--" }
  vim.list_extend(args, paths)
  local out = M.git(top, args) or ""
  for _, path in ipairs(vim.split(out, "\0", { plain = true, trimempty = true })) do
    set[path] = true
  end
  return set
end

return M
