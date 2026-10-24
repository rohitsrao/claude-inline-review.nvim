-- review.lua: the review itself. It follows your cursor: accept and reject act
-- on the hunk under (or next below) the cursor in whatever recorded file you
-- are in, and ]h / [h and auto-advance cross into the next file.
local config = require("claude-inline-review.config")
local git = require("claude-inline-review.git")
local hunks = require("claude-inline-review.hunks")
local render = require("claude-inline-review.render")
local store = require("claude-inline-review.store")

local M = {}

local QF_TITLE = "Claude inline review"
local EMPTY = "none"  -- a baseline meaning "the file does not exist"

-- One repo at a time: the one Neovim's working directory is in.
local S = {
  top = nil,           -- repo root
  git_dir = nil,
  session = nil,       -- session.json as last read (the mod's)
  review = nil,        -- review.json (ours): reviewId, lastSeenHead, baselines, reviewed
  ignored = {},        -- rel -> true, from .claudereviewignore
  binary = {},         -- rel -> true, can't be reviewed inline
  counts = {},         -- absolute path -> pending hunks, for nvim-tree
  attached = {},       -- buf -> rel, buffers with review keys and paint
  active = false,      -- a review is open
  notified_turn = nil, -- the turn whose changes were last announced
  finish_pending = false,
}
M.state = S

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "claude-inline-review" })
end

local function abs(rel)
  return S.top .. "/" .. rel
end

-- A buffer's or file's path relative to the repo root, or nil outside it.
local function rel_of(path)
  if path == nil or path == "" or S.top == nil then return nil end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  -- git's root has symlinks resolved (/tmp is /private/tmp on macOS).
  local real = vim.uv.fs_realpath(path)
  if not real then
    local dir = vim.uv.fs_realpath(vim.fs.dirname(path))
    real = dir and (dir .. "/" .. vim.fs.basename(path))
  end
  for _, candidate in ipairs({ path, real }) do
    if candidate and vim.startswith(candidate, S.top .. "/") then
      return candidate:sub(#S.top + 2)
    end
  end
  return nil
end

local function is_recorded(rel)
  return rel ~= nil and S.session ~= nil and S.session.files[rel] ~= nil
end

local refresh_tree = (function()
  local timer = vim.uv.new_timer()
  return function()
    timer:stop()
    timer:start(100, 0, vim.schedule_wrap(function()
      local ok, api = pcall(require, "nvim-tree.api")
      if ok then pcall(api.tree.reload) end
    end))
  end
end)()

---------------------------------------------------------------------------
-- Baselines and hunks

local function new_review()
  return { reviewId = S.session and S.session.reviewId, baselines = {}, reviewed = {} }
end

local function save_review()
  if S.review and S.git_dir then
    store.write_review(S.git_dir, S.review)
  end
end

-- The baseline in use: review.json's adjusted one, else the mod's photo.
function M.baseline_sha(rel)
  local adjusted = S.review and S.review.baselines[rel]
  if adjusted ~= nil then return adjusted ~= EMPTY and adjusted or nil end
  local entry = S.session and S.session.files[rel]
  return entry and entry.baseline or nil
end

function M.baseline_lines(rel)
  local sha = M.baseline_sha(rel)
  return sha and hunks.lines(git.cat_file(S.top, sha)) or {}
end

local function loaded_buf(rel)
  local buf = vim.fn.bufnr(abs(rel))
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then return buf end
  return nil
end

function M.current_lines(rel)
  local buf = loaded_buf(rel)
  if buf then return hunks.buf_lines(buf) end
  if vim.uv.fs_stat(abs(rel)) then return vim.fn.readfile(abs(rel)) end
  return {}
end

function M.hunks_of(rel)
  local old = M.baseline_lines(rel)
  local new = M.current_lines(rel)
  return hunks.compute(old, new), old, new
end

local function has_nul(text)
  return text ~= nil and text:find("\0", 1, true) ~= nil
end

local function check_binary(rel)
  if S.binary[rel] ~= nil then return S.binary[rel] end
  local sha = M.baseline_sha(rel)
  local is_binary = sha ~= nil and has_nul(git.cat_file(S.top, sha))
  if not is_binary then
    local file = io.open(abs(rel), "rb")
    if file then
      is_binary = has_nul(file:read(8000))
      file:close()
    end
  end
  S.binary[rel] = is_binary
  return is_binary
end

-- Recorded paths in the order Claude first touched them.
function M.files(opts)
  opts = opts or {}
  if not S.session then return {} end

  local list = {}
  for rel, entry in pairs(S.session.files) do
    local first = entry.events and entry.events[1] and entry.events[1].at or math.huge
    list[#list + 1] = { rel = rel, at = first }
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.rel < b.rel
  end)

  local result = {}
  for _, item in ipairs(list) do
    local skip = not opts.all and (S.ignored[item.rel] or check_binary(item.rel))
    if not skip then result[#result + 1] = item.rel end
  end
  return result
end

-- Reloads a recorded file's buffer when Claude changed the file on disk and
-- the buffer has no unsaved edits, so a review never diffs, or writes back,
-- text older than what Claude left. (:checktime is postponed when not typed.)
function M.sync_buffer(rel)
  local buf = loaded_buf(rel)
  if not buf or vim.bo[buf].modified or vim.bo[buf].buftype ~= "" then return end

  local on_disk = vim.uv.fs_stat(abs(rel)) and vim.fn.readfile(abs(rel)) or {}
  if vim.deep_equal(on_disk, hunks.buf_lines(buf)) then return end

  -- 'undoreload' keeps the reload as one undoable change.
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent keepjumps edit") end)
end

local function sync_buffers()
  for _, rel in ipairs(M.files()) do M.sync_buffer(rel) end
end

-- Recounts every file's hunks. Returns the files with hunks left, in order,
-- and the total number of hunks.
function M.refresh_counts()
  S.counts = {}
  local pending, total = {}, 0
  for _, rel in ipairs(M.files()) do
    local n = #M.hunks_of(rel)
    if n > 0 then
      pending[#pending + 1] = rel
      S.counts[abs(rel)] = n
      total = total + n
    elseif S.review then
      S.review.reviewed[rel] = true
    end
  end
  refresh_tree()
  return pending, total
end

function M.counts()
  return S.counts
end

---------------------------------------------------------------------------
-- Painting and buffer-local keys

local render_timers = {}

function M.render(buf)
  local rel = S.attached[buf]
  if not rel or not vim.api.nvim_buf_is_valid(buf) then return end

  local list, old = M.hunks_of(rel)
  local current
  if vim.api.nvim_get_current_buf() == buf then
    current = hunks.index_at(list, vim.api.nvim_win_get_cursor(0)[1])
  end
  render.draw(buf, list, old, current)

  local n = #list
  S.counts[abs(rel)] = n > 0 and n or nil
  refresh_tree()
end

local function render_later(buf)
  local timer = render_timers[buf]
  if not timer then
    timer = vim.uv.new_timer()
    render_timers[buf] = timer
  end
  timer:stop()
  timer:start(config.options.debounce_ms.render, 0, vim.schedule_wrap(function() M.render(buf) end))
end

local BUF_KEYS = {
  { "next_hunk", function() M.next_hunk() end, "Next Claude hunk" },
  { "prev_hunk", function() M.prev_hunk() end, "Previous Claude hunk" },
  { "accept", function() M.accept() end, "Accept Claude hunk" },
  { "reject", function() M.reject() end, "Reject Claude hunk" },
  { "accept_file", function() M.accept_file() end, "Accept Claude's changes to this file" },
  { "reject_file", function() M.reject_file() end, "Reject Claude's changes to this file" },
  { "list", function() M.list() end, "List Claude hunks in quickfix" },
  { "quit", function() M.quit() end, "End Claude review (keeps progress)" },
}

function M.attach(buf, rel)
  if S.attached[buf] then return end
  S.attached[buf] = rel

  for _, key in ipairs(BUF_KEYS) do
    local lhs = config.options.keymaps[key[1]]
    if lhs then
      vim.keymap.set("n", lhs, key[2], { buffer = buf, desc = key[3], silent = true })
    end
  end

  local group = vim.api.nvim_create_augroup("claude_inline_review_buf_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "FileChangedShellPost" }, {
    group = group,
    buffer = buf,
    callback = function() render_later(buf) end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function() render_later(buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    buffer = buf,
    callback = function() M.detach(buf) end,
  })

  M.render(buf)
end

function M.detach(buf)
  if not S.attached[buf] then return end
  S.attached[buf] = nil

  if vim.api.nvim_buf_is_valid(buf) then
    for _, key in ipairs(BUF_KEYS) do
      local lhs = config.options.keymaps[key[1]]
      if lhs then pcall(vim.keymap.del, "n", lhs, { buffer = buf }) end
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, "claude_inline_review_buf_" .. buf)
  render.clear(buf)

  if render_timers[buf] then
    render_timers[buf]:stop()
    render_timers[buf]:close()
    render_timers[buf] = nil
  end
end

local function detach_all()
  for buf in pairs(S.attached) do M.detach(buf) end
end

local function attach_loaded()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local rel = rel_of(vim.api.nvim_buf_get_name(buf))
      if is_recorded(rel) and not S.ignored[rel] and not check_binary(rel) then
        M.attach(buf, rel)
      end
    end
  end
end

-- BufEnter: during a review, any recorded file you open joins it.
function M.on_buf_enter(buf)
  if not S.active or S.attached[buf] then return end
  local rel = rel_of(vim.api.nvim_buf_get_name(buf))
  if is_recorded(rel) and not S.ignored[rel] and not check_binary(rel) then
    M.attach(buf, rel)
  end
end

---------------------------------------------------------------------------
-- Moving around

local function jump(row)
  local line_count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(math.min(row, line_count), 1), 0 })
  vim.cmd("normal! zz")
end

-- Opens `rel` and puts the cursor on its first (or last) hunk.
local function open_file(rel, which)
  if rel_of(vim.api.nvim_buf_get_name(0)) ~= rel then
    vim.cmd.edit(vim.fn.fnameescape(abs(rel)))
  end
  local buf = vim.api.nvim_get_current_buf()
  M.attach(buf, rel)

  local list = M.hunks_of(rel)
  local h = which == "last" and list[#list] or list[1]
  if h then jump((hunks.rows(h))) end
  M.render(buf)
end

-- The next file with hunks left after `rel` (wrapping round, `rel` itself last).
local function next_pending(rel, step)
  local pending = M.refresh_counts()
  if #pending == 0 then return nil end

  local index = 0
  for i, path in ipairs(pending) do
    if path == rel then index = i end
  end
  if index == 0 then
    return step > 0 and pending[1] or pending[#pending]
  end
  local n = #pending
  return pending[((index - 1 + step) % n) + 1]
end

local function current_rel()
  local buf = vim.api.nvim_get_current_buf()
  return S.attached[buf], buf
end

function M.next_hunk()
  local rel = current_rel()
  if not rel then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, h in ipairs(M.hunks_of(rel)) do
    local first = hunks.rows(h)
    if first > row then return jump(first) end
  end
  local target = next_pending(rel, 1)
  if target then open_file(target, "first") end
end

function M.prev_hunk()
  local rel = current_rel()
  if not rel then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local list = M.hunks_of(rel)
  for i = #list, 1, -1 do
    local first = hunks.rows(list[i])
    if first < row then return jump(first) end
  end
  local target = next_pending(rel, -1)
  if target then open_file(target, "last") end
end

-- After a decision: the next hunk at or below `row`, else the next file,
-- else the review is finished.
local function advance(buf, rel, row)
  M.render(buf)
  local list = M.hunks_of(rel)
  for _, h in ipairs(list) do
    local first = hunks.rows(h)
    if first >= row then
      jump(first)
      return M.render(buf)
    end
  end

  local target = next_pending(rel, 1)
  if target then
    open_file(target, "first")
  else
    M.maybe_finish()
  end
end

---------------------------------------------------------------------------
-- Accept and reject

local function set_baseline(rel, lines)
  S.review.baselines[rel] = git.store_text(S.top, rel, hunks.text(lines))
  save_review()
end

local function write(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd write") end)
end

-- Q7: a file Claude created that a reject leaves empty is deleted. Its buffer
-- stays open, so `u` then `:w` brings it back.
local function empty_file_rule(buf, rel)
  local entry = S.session.files[rel]
  if entry and entry.baseline == nil and #hunks.buf_lines(buf) == 0 then
    os.remove(abs(rel))
    vim.bo[buf].modified = false
    notify(("Deleted %s (Claude created it; rejected to empty)"):format(rel))
  end
end

local function target()
  local rel, buf = current_rel()
  if not rel then
    notify("Not a file in the Claude review", vim.log.levels.WARN)
    return nil
  end
  M.sync_buffer(rel)
  local list, old, new = M.hunks_of(rel)
  local index = hunks.index_at(list, vim.api.nvim_win_get_cursor(0)[1])
  return rel, buf, list[index], old, new
end

-- Accept moves the baseline forward: the buffer is not touched and nothing
-- is staged.
function M.accept()
  local rel, buf, h, old, new = target()
  if not rel then return end
  if not h then return advance(buf, rel, 1) end

  set_baseline(rel, hunks.accept(old, new, h))
  advance(buf, rel, (hunks.rows(h)))
end

-- Reject moves the file backward: the baseline's lines go back into the
-- buffer (one undo step) and the file is saved without autocommands, so a
-- formatter cannot make new differences.
function M.reject()
  local rel, buf, h, old, new = target()
  if not rel then return end
  if not h then return advance(buf, rel, 1) end

  local lines = hunks.old_slice(old, h)
  if #new == 0 then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  elseif h.new_count > 0 then
    vim.api.nvim_buf_set_lines(buf, h.new_start - 1, h.new_start - 1 + h.new_count, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, h.new_start, h.new_start, false, lines)
  end
  write(buf)
  empty_file_rule(buf, rel)
  advance(buf, rel, (hunks.rows(h)))
end

function M.accept_file()
  local rel, buf, _, _, new = target()
  if not rel then return end
  set_baseline(rel, new)
  advance(buf, rel, math.huge)
end

function M.reject_file()
  local rel, buf, _, old = target()
  if not rel then return end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, old)
  write(buf)
  empty_file_rule(buf, rel)
  advance(buf, rel, math.huge)
end

function M.list()
  local items = {}
  for _, rel in ipairs(M.files()) do
    for _, h in ipairs(M.hunks_of(rel)) do
      items[#items + 1] = {
        filename = abs(rel),
        lnum = (hunks.rows(h)),
        text = ("+%d -%d"):format(h.new_count, h.old_count),
      }
    end
  end
  vim.fn.setqflist({}, " ", { title = QF_TITLE, items = items })
  vim.cmd("copen")
end

local function clear_quickfix()
  if vim.fn.getqflist({ title = 0 }).title == QF_TITLE then
    vim.fn.setqflist({}, "r", { title = "", items = {} })
    vim.cmd("cclose")
  end
end

---------------------------------------------------------------------------
-- Starting, pausing, finishing

function M.start()
  if not S.top then
    return notify("Not in a git repo", vim.log.levels.WARN)
  end

  M.reload()
  sync_buffers()
  require("claude-inline-review.commits").check()
  if not S.session then
    return notify("No Claude changes to review")
  end

  local pending = M.refresh_counts()
  if #pending == 0 then
    return M.maybe_finish()
  end

  S.active = true
  attach_loaded()

  local rel = rel_of(vim.api.nvim_buf_get_name(0))
  if rel and S.counts[abs(rel)] then
    M.attach(vim.api.nvim_get_current_buf(), rel)
    M.render(vim.api.nvim_get_current_buf())
  else
    open_file(pending[1], "first")
  end
end

-- Ends the review; accepts are kept in review.json and <leader>rr resumes.
function M.quit()
  S.active = false
  detach_all()
  clear_quickfix()
  notify("Review paused — " .. (config.options.keymaps.start or ":ClaudeInlineReview") .. " to resume")
end

-- Deletes the whole record and everything held in memory. Buffer text and
-- undo history are left alone.
function M.cleanup(msg)
  detach_all()
  clear_quickfix()
  if S.git_dir then store.delete_all(S.git_dir) end
  S.session, S.review = nil, nil
  S.active, S.finish_pending = false, false
  S.counts, S.binary = {}, {}
  refresh_tree()
  if msg then notify(msg) end
end

-- Finished when no file has hunks left. While Claude is working, cleanup
-- waits for its turn to end, so it never races a write the mod is making.
function M.maybe_finish()
  if not S.session then return end
  local pending = M.refresh_counts()
  if #pending > 0 then return false end

  if S.session.status == "working" then
    S.finish_pending = true
    detach_all()
    S.active = false
    notify("Review done — cleaning up when Claude's turn ends")
    return true
  end

  M.cleanup("Review complete — stage with git when ready")
  return true
end

---------------------------------------------------------------------------
-- The record changing on disk

-- Reads session.json and review.json. Returns the paths that were in the
-- review before and are gone now (an Esc dropped them), or nil when the
-- whole record went away.
function M.reload()
  local before = S.session
  local session = store.read_session(S.git_dir)

  if not session then
    local had = before ~= nil
    S.session = nil
    if had or store.read_review(S.git_dir) then
      M.cleanup()
    end
    return nil, had
  end

  -- A review.json of another review is stale.
  if S.review == nil or S.review.reviewId ~= session.reviewId then
    local saved = store.read_review(S.git_dir)
    if saved and saved.reviewId == session.reviewId then
      S.review = saved
      S.review.baselines = S.review.baselines or {}
      S.review.reviewed = S.review.reviewed or {}
    else
      if saved then store.delete_review(S.git_dir) end
      if before and before.reviewId ~= session.reviewId then detach_all() end
      S.session = session
      S.review = new_review()
    end
  end
  S.session = session

  local dropped = {}
  if before and before.reviewId == session.reviewId then
    for rel in pairs(before.files) do
      if not session.files[rel] then dropped[#dropped + 1] = rel end
    end
  end
  for rel in pairs(S.review.baselines) do
    if not session.files[rel] then S.review.baselines[rel] = nil end
  end
  for rel in pairs(S.review.reviewed) do
    if not session.files[rel] then S.review.reviewed[rel] = nil end
  end
  if #dropped > 0 then
    for buf, rel in pairs(S.attached) do
      if not session.files[rel] then M.detach(buf) end
    end
    save_review()
  end

  local paths = vim.tbl_keys(session.files)
  S.ignored = git.ignored(S.top, paths)
  return dropped
end

-- The watcher's handler: session.json was written, renamed or deleted.
function M.on_record_change(opts)
  opts = opts or {}
  if not S.git_dir then return end

  local dropped, had = M.reload()
  if dropped == nil then
    if had then notify("Claude turn aborted — review discarded") end
    return
  end

  if #dropped > 0 then
    table.sort(dropped)
    notify(("Claude turn aborted — %d file%s dropped from review (%s)"):format(
      #dropped, #dropped == 1 and "" or "s", table.concat(dropped, ", ")))
  end

  local session = S.session
  if session.status ~= "ready" then return end

  -- Git calls below may pause this job while a key you press changes the
  -- review; it stops when the review it started on is gone.
  require("claude-inline-review.commits").check()
  if S.session ~= session then return end

  sync_buffers()
  local pending, total = M.refresh_counts()
  if S.session ~= session then return end

  if S.finish_pending or (S.active and #pending == 0) then
    S.finish_pending = false
    if M.maybe_finish() then return end
  end

  if S.session.turnId ~= S.notified_turn then
    S.notified_turn = S.session.turnId
    if not opts.startup and #pending > 0 then
      local ignored = vim.tbl_count(S.ignored)
      notify(("Claude changed %d file%s (%d hunk%s%s) — %s to review"):format(
        #pending, #pending == 1 and "" or "s", total, total == 1 and "" or "s",
        ignored > 0 and (", %d ignored"):format(ignored) or "",
        config.options.keymaps.start or ":ClaudeInlineReview"))
    end
  end

  if S.active then
    attach_loaded()
    for buf in pairs(S.attached) do M.render(buf) end
  end
end

-- Points the plugin at the repo containing `dir` (nil to turn it off).
function M.set_repo(top, git_dir)
  if S.top == top and S.git_dir == git_dir then return end
  detach_all()
  S.top, S.git_dir = top, git_dir
  S.session, S.review = nil, nil
  S.ignored, S.binary, S.counts = {}, {}, {}
  S.active, S.notified_turn, S.finish_pending = false, nil, false
end

M.EMPTY = EMPTY
M.abs = abs
M.rel_of = rel_of
M.save_review = save_review

return M
