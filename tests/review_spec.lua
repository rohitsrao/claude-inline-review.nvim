local review = require("claude-inline-review.review")
local commits = require("claude-inline-review.commits")
local store = require("claude-inline-review.store")
local config = require("claude-inline-review.config")

config.set({})

local function sh(cwd, ...)
  local result = vim.system({ ... }, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat({ ... }, " ") .. ": " .. (result.stderr or ""))
  return vim.trim(result.stdout or "")
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

-- A repo with a.txt committed, and a helper that plays the mod: photograph a
-- file, let "Claude" change it, and record it in session.json.
local function repo()
  local top = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
  vim.fn.mkdir(top, "p")
  top = vim.uv.fs_realpath(top)
  sh(top, "git", "init", "-q")
  sh(top, "git", "config", "user.email", "t@t")
  sh(top, "git", "config", "user.name", "t")
  write_file(top .. "/a.txt", "one\ntwo\nthree\nfour\nfive\n")
  sh(top, "git", "add", ".")
  sh(top, "git", "commit", "-qm", "init")
  local git_dir = sh(top, "git", "rev-parse", "--absolute-git-dir")

  local r = { top = top, git_dir = git_dir, files = {}, order = 0 }

  function r.claude(rel, text, turn)
    local path = top .. "/" .. rel
    if not r.files[rel] then
      local baseline = vim.uv.fs_stat(path) and sh(top, "git", "hash-object", "-w", "--", path) or nil
      r.order = r.order + 1
      r.files[rel] = { baseline = baseline, firstTurnId = turn, at = r.order, turns = {} }
    end
    table.insert(r.files[rel].turns, turn)
    write_file(path, text)
  end

  function r.session(status, turn)
    local files = {}
    for rel, f in pairs(r.files) do
      local events = {}
      for _, t in ipairs(f.turns) do events[#events + 1] = { tool = "Edit", at = f.at, turnId = t } end
      files[rel] = { baseline = f.baseline or vim.NIL, firstTurnId = f.firstTurnId, events = events }
    end
    local session = {
      reviewId = r.reviewId or "rev-1", modVersion = "0.1.0",
      head = sh(top, "git", "rev-parse", "HEAD"), status = status, turnId = turn,
      files = next(files) and files or vim.empty_dict(),
    }
    write_file(store.dir(git_dir) .. "/session.json", vim.json.encode(session))
  end

  review.set_repo(top, git_dir)
  return r
end

local function buf_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") .. "\n"
end

describe("review", function()
  before_each(function()
    vim.cmd("silent! %bwipeout!")
  end)

  it("accepts a hunk without touching the file, rejects one by restoring it", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nFIVE\n", "t1")
    r.session("ready", "t1")

    review.on_record_change()
    review.start()
    assert.are.equal(r.top .. "/a.txt", vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])

    review.accept()
    assert.are.equal("one\nTWO\nthree\nfour\nFIVE\n", read_file(r.top .. "/a.txt"))
    -- The cursor stays on the accepted code.
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    assert.are.equal(1, #review.hunks_of("a.txt"))

    review.reject()
    assert.are.equal("one\nTWO\nthree\nfour\nfive\n", read_file(r.top .. "/a.txt"))
    -- Nothing was staged.
    assert.are.equal("", sh(r.top, "git", "diff", "--cached", "--name-only"))
    -- Every hunk decided: the whole record is gone.
    assert.is_nil(vim.uv.fs_stat(store.dir(r.git_dir)))
  end)

  it("accepting a whole file stays there; next_file moves on", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.claude("b.txt", "bee\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()

    review.accept_file()
    assert.are.equal(r.top .. "/a.txt", vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])

    review.next_file()
    assert.are.equal(r.top .. "/b.txt", vim.api.nvim_buf_get_name(0))
  end)

  it("u after a reject brings the hunk back", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nFIVE\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()

    review.reject()
    assert.are.equal(1, #review.hunks_of("a.txt"))
    vim.cmd("silent undo")
    assert.are.equal(2, #review.hunks_of("a.txt"))
    assert.are.equal("one\nTWO\nthree\nfour\nFIVE\n", buf_text())
  end)

  it("a whole-file reject is one undo step", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nFIVE\n", "t1")
    r.claude("b.txt", "new\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()

    review.reject_file()
    assert.are.equal("one\ntwo\nthree\nfour\nfive\n", read_file(r.top .. "/a.txt"))
    -- Auto-advance moved on to b.txt.
    assert.are.equal(r.top .. "/b.txt", vim.api.nvim_buf_get_name(0))
    vim.cmd("buffer " .. vim.fn.fnameescape(r.top .. "/a.txt"))
    vim.cmd("silent undo")
    assert.are.equal("one\nTWO\nthree\nfour\nFIVE\n", buf_text())
  end)

  it("deletes a new file a reject leaves empty, and u + :w brings it back", function()
    local r = repo()
    r.claude("new.txt", "hello\n", "t1")
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()
    assert.are.equal(r.top .. "/new.txt", vim.api.nvim_buf_get_name(0))

    review.reject()
    assert.is_nil(vim.uv.fs_stat(r.top .. "/new.txt"))

    vim.cmd("buffer " .. vim.fn.fnameescape(r.top .. "/new.txt"))
    vim.cmd("silent undo")
    vim.cmd("silent write")
    assert.are.equal("hello\n", read_file(r.top .. "/new.txt"))
  end)

  it("never deletes a file that existed before", function()
    local r = repo()
    r.claude("a.txt", "", "t1")
    write_file(r.top .. "/a.txt", "")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()
    review.accept_file()
    assert.is_not_nil(vim.uv.fs_stat(r.top .. "/a.txt"))
  end)

  it("your own edits to accepted code show up as a new hunk", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.claude("b.txt", "keep\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()
    review.accept()

    vim.cmd("buffer " .. vim.fn.fnameescape(r.top .. "/a.txt"))
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "TWO!" })
    assert.are.equal(1, #review.hunks_of("a.txt"))
  end)

  it("leaves .claudereviewignore matches out", function()
    local r = repo()
    write_file(r.top .. "/.claudereviewignore", "*.g.dart\n")
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.claude("x.g.dart", "generated\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    assert.are.same({ "a.txt" }, review.files())
  end)

  it("an Esc that dropped some files prunes them and keeps the rest", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()
    review.accept()

    -- Turn t2 first touched b.txt, then you pressed Esc: the mod dropped it.
    r.claude("b.txt", "bee\n", "t2")
    r.session("working", "t2")
    review.on_record_change()
    r.files["b.txt"] = nil
    r.session("ready", "t2")
    review.on_record_change()

    assert.are.same({ "a.txt" }, review.files())
    -- The accept on a.txt survived.
    assert.are.equal(1, #review.hunks_of("a.txt"))
  end)

  it("an Esc that dropped every file discards the review", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nFIVE\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()
    review.accept()
    assert.is_not_nil(store.read_review(r.git_dir))

    os.remove(store.dir(r.git_dir) .. "/session.json")
    review.on_record_change()
    assert.is_nil(store.read_review(r.git_dir))
    assert.is_nil(review.state.session)
  end)

  it("a stale review.json from an older review is deleted", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    store.write_review(r.git_dir, { reviewId = "old", baselines = { ["a.txt"] = "deadbeef" }, reviewed = {} })
    r.session("ready", "t1")
    review.on_record_change({ startup = true })
    assert.are.equal("rev-1", review.state.review.reviewId)
    assert.is_nil(store.read_review(r.git_dir))
    -- The old review's adjusted baseline is not used.
    assert.are.equal(1, #review.hunks_of("a.txt"))
  end)

  it("finishing while Claude works waits for the turn to end", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()
    review.start()
    r.session("working", "t2")
    review.on_record_change()

    review.accept_file()
    assert.is_not_nil(vim.uv.fs_stat(store.dir(r.git_dir) .. "/session.json"))

    r.session("ready", "t2")
    review.on_record_change()
    assert.is_nil(vim.uv.fs_stat(store.dir(r.git_dir)))
  end)

  it("a commit holding all of Claude's changes cleans up", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.claude("b.txt", "bee\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()

    sh(r.top, "git", "add", "a.txt")
    sh(r.top, "git", "commit", "-qm", "part")
    commits.check()
    -- a.txt is in; b.txt is still pending.
    assert.are.same({}, review.hunks_of("a.txt"))
    assert.are.equal(1, #review.hunks_of("b.txt"))

    sh(r.top, "git", "add", "b.txt")
    sh(r.top, "git", "commit", "-qm", "rest")
    commits.check()
    assert.is_nil(vim.uv.fs_stat(store.dir(r.git_dir)))
  end)

  it("a partial commit leaves only the uncommitted hunks", function()
    local r = repo()
    r.claude("a.txt", "one\nTWO\nthree\nfour\nFIVE\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()

    -- Commit only the first hunk, as git add -p would.
    write_file(r.top .. "/a.txt", "one\nTWO\nthree\nfour\nfive\n")
    sh(r.top, "git", "commit", "-qam", "first hunk")
    write_file(r.top .. "/a.txt", "one\nTWO\nthree\nfour\nFIVE\n")
    commits.check()

    local list = review.hunks_of("a.txt")
    assert.are.equal(1, #list)
    assert.are.equal(5, list[1].new_start)
  end)

  it("reloads an open buffer Claude changed on disk before diffing it", function()
    local r = repo()
    vim.cmd.edit(vim.fn.fnameescape(r.top .. "/a.txt"))
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.session("ready", "t1")

    review.on_record_change()
    assert.are.equal("one\nTWO\nthree\nfour\nfive\n", buf_text())
    assert.are.equal(1, #review.hunks_of("a.txt"))

    -- A reject writes the buffer: it must not write back the stale text.
    review.start()
    review.reject()
    assert.are.equal("one\ntwo\nthree\nfour\nfive\n", read_file(r.top .. "/a.txt"))
  end)

  it("git reset never wrongly drops a file", function()
    local r = repo()
    sh(r.top, "git", "commit", "-q", "--allow-empty", "-m", "second")
    r.claude("a.txt", "one\nTWO\nthree\nfour\nfive\n", "t1")
    r.session("ready", "t1")
    review.on_record_change()

    sh(r.top, "git", "reset", "-q", "--soft", "HEAD~1")
    commits.check()
    assert.are.equal(1, #review.hunks_of("a.txt"))
  end)
end)
