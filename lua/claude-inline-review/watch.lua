-- watch.lua: file-system doorbells. One on the record folder (session.json
-- written, renamed or deleted), one on logs/HEAD (git's diary of HEAD moves,
-- so commits are noticed with no git hook installed), and one on the git-dir
-- itself so the record folder appearing or vanishing is seen too.
local config = require("claude-inline-review.config")
local store = require("claude-inline-review.store")

local M = {}

local handles = {}
local record_handle

local function debounce(ms, fn)
  local timer = vim.uv.new_timer()
  return function()
    timer:stop()
    timer:start(ms, 0, vim.schedule_wrap(fn))
  end
end

local function watch(path, on_change)
  local handle = vim.uv.new_fs_event()
  if not handle then return nil end
  local ok = handle:start(path, {}, function(err, name)
    if not err then on_change(name or "") end
  end)
  if not ok then
    handle:close()
    return nil
  end
  return handle
end

function M.stop()
  for _, handle in ipairs(handles) do
    if not handle:is_closing() then handle:stop() handle:close() end
  end
  handles = {}
  if record_handle and not record_handle:is_closing() then
    record_handle:stop()
    record_handle:close()
  end
  record_handle = nil
end

-- on_record and on_reflog run on the main loop, debounced.
function M.start(git_dir, on_record, on_reflog)
  M.stop()
  local ms = config.options.debounce_ms
  local record = debounce(ms.record, on_record)
  local reflog = debounce(ms.reflog, on_reflog)
  local dir = store.dir(git_dir)

  local function ensure_record_watch()
    local exists = vim.uv.fs_stat(dir) ~= nil
    if exists and not record_handle then
      record_handle = watch(dir, function() record() end)
    elseif not exists and record_handle then
      record_handle:stop()
      record_handle:close()
      record_handle = nil
    end
  end

  -- macOS reports nested names (claude-inline-review/session.json, logs/HEAD);
  -- Linux reports only direct children, hence the folder watchers.
  local top = watch(git_dir, function(name)
    if name:find("claude-inline-review", 1, true) then
      vim.schedule(ensure_record_watch)
      record()
    elseif name == "HEAD" or name:find("logs", 1, true) then
      reflog()
    end
  end)
  if top then handles[#handles + 1] = top end

  local logs = watch(git_dir .. "/logs", function(name)
    if name:find("HEAD", 1, true) then reflog() end
  end)
  if logs then handles[#handles + 1] = logs end

  ensure_record_watch()
end

return M
