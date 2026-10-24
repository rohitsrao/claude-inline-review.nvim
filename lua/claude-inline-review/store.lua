-- store.lua: the record in <git-dir>/claude-inline-review/.
--
-- The mod writes session.json; this plugin only reads it. This plugin writes
-- review.json. Each file has one writer, and every write is a temp file
-- renamed into place.
local M = {}

local DIR = "claude-inline-review"
local SESSION = "session.json"
local REVIEW = "review.json"

function M.dir(git_dir)
  return git_dir .. "/" .. DIR
end

local function read_json(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()

  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(value) == "table" and value or nil
end

function M.read_session(git_dir)
  return read_json(M.dir(git_dir) .. "/" .. SESSION)
end

function M.read_review(git_dir)
  return read_json(M.dir(git_dir) .. "/" .. REVIEW)
end

function M.write_review(git_dir, review)
  local dir = M.dir(git_dir)
  vim.fn.mkdir(dir, "p")

  local path = dir .. "/" .. REVIEW
  local tmp = ("%s.tmp-%d-%d"):format(path, vim.uv.os_getpid(), vim.uv.hrtime())
  local file = assert(io.open(tmp, "w"))
  file:write(vim.json.encode(review))
  file:close()
  assert(os.rename(tmp, path))
end

local function is_ours(name)
  return name == SESSION or name == REVIEW
    or vim.startswith(name, SESSION .. ".tmp-") or vim.startswith(name, REVIEW .. ".tmp-")
end

-- Deletes review.json alone (a review whose reviewId no longer matches).
function M.delete_review(git_dir)
  os.remove(M.dir(git_dir) .. "/" .. REVIEW)
end

-- Deletes every record file by exact name, then the folder if it is empty.
-- Git's objects are left for `git gc`: removing them could break commits.
function M.delete_all(git_dir)
  local dir = M.dir(git_dir)
  for name in vim.fs.dir(dir) do
    if is_ours(name) then
      os.remove(dir .. "/" .. name)
    end
  end
  vim.uv.fs_rmdir(dir)
end

return M
