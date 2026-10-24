-- commits.lua: commits close the review. After each move of HEAD (and once
-- Claude is idle), every recorded file whose working copy is exactly what HEAD
-- holds leaves the review; once all have, the whole record is deleted.
local git = require("claude-inline-review.git")
local review = require("claude-inline-review.review")

local M = {}

function M.check()
  local S = review.state
  local session, rv = S.session, S.review
  if not session or not rv then return end
  -- While Claude works, wait: on_record_change runs this again at "ready".
  if session.status ~= "ready" then return end

  -- Git calls here may pause this job while you accept, reject or finish the
  -- review; it gives up when the review it started on is gone.
  local function is_stale()
    return S.session ~= session or S.review ~= rv
  end

  local head = git.head(S.top)
  if is_stale() then return end
  local last = rv.lastSeenHead or session.head
  if head == last then return end

  -- A committed version is a new baseline only when HEAD moved forward;
  -- after a reset or a branch switch it is not something you just committed.
  local is_forward = last ~= nil and head ~= nil and git.is_ancestor(S.top, last, head)
  local changed = is_forward and git.changed_between(S.top, last, head) or {}

  local is_all_in = true
  local baselines, integrated = {}, {}
  for rel in pairs(session.files) do
    if not S.ignored[rel] then
      local working = git.worktree_sha(S.top, rel)
      local committed = head and git.committed(S.top, rel) or nil

      if working == committed then
        -- Integrated (both missing counts too): nothing left to review.
        baselines[rel] = committed or review.EMPTY
        integrated[rel] = true
      else
        is_all_in = false
        if is_forward and changed[rel] and committed then
          -- Partly committed: only the uncommitted hunks stay pending.
          baselines[rel] = committed
        end
      end
    end
  end
  if is_stale() then return end

  if is_all_in then
    return review.cleanup("Claude's changes are committed — review record cleaned up.")
  end

  for rel, sha in pairs(baselines) do
    rv.baselines[rel] = sha
    if integrated[rel] then rv.reviewed[rel] = true end
  end
  rv.lastSeenHead = head
  review.save_review()
  review.refresh_counts()
  for buf in pairs(S.attached) do review.render(buf) end
end

return M
