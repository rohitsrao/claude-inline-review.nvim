local hunks = require("claude-inline-review.hunks")

describe("hunks", function()
  local old = { "a", "b", "c", "d" }

  it("finds a change, an insertion and a deletion", function()
    local list = hunks.compute(old, { "a", "B", "c", "d", "e" })
    assert.are.same({
      { old_start = 2, old_count = 1, new_start = 2, new_count = 1 },
      { old_start = 4, old_count = 0, new_start = 5, new_count = 1 },
    }, list)

    assert.are.same(
      { { old_start = 2, old_count = 1, new_start = 1, new_count = 0 } },
      hunks.compute(old, { "a", "c", "d" }))
  end)

  it("accepting every hunk turns the baseline into the current text", function()
    local new = { "x", "a", "B", "d", "e", "f" }
    local base = old
    while true do
      local list = hunks.compute(base, new)
      if #list == 0 then break end
      base = hunks.accept(base, new, list[1])
    end
    assert.are.same(new, base)
  end)

  it("rejecting every hunk turns the current text back into the baseline", function()
    local new = { "x", "a", "B", "d", "e", "f" }
    while true do
      local list = hunks.compute(old, new)
      if #list == 0 then break end
      new = hunks.reject(old, new, list[#list])
    end
    assert.are.same(old, new)
  end)

  it("accepts one hunk and leaves the other pending", function()
    local new = { "a", "B", "c", "d", "e" }
    local list = hunks.compute(old, new)
    local base = hunks.accept(old, new, list[2])
    assert.are.same({ "a", "b", "c", "d", "e" }, base)
    assert.are.same(1, #hunks.compute(base, new))
  end)

  it("picks the hunk under the cursor, else the next below, else the first", function()
    local list = hunks.compute({ "1", "2", "3", "4", "5", "6" }, { "1", "X", "3", "4", "Y", "6" })
    assert.are.equal(1, hunks.index_at(list, 1))
    assert.are.equal(1, hunks.index_at(list, 2))
    assert.are.equal(2, hunks.index_at(list, 3))
    assert.are.equal(2, hunks.index_at(list, 5))
    assert.are.equal(1, hunks.index_at(list, 6))
  end)

  it("treats a final newline as no extra line", function()
    assert.are.same({ "a", "b" }, hunks.lines("a\nb\n"))
    assert.are.same({}, hunks.lines(""))
    assert.are.equal("a\nb\n", hunks.text({ "a", "b" }))
  end)
end)
