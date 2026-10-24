# claude-inline-review.nvim

Review the file edits Claude Code makes, hunk by hunk, inside your real Neovim buffers. New lines are painted green and old lines red, and you accept or reject each hunk. Nothing is staged or committed for you.

The repo has two halves:

- **A Claude Code mod** (`claude-mod/`, installed as `nvim-inline-review`). Just before Claude's first `Edit`, `Write` or `NotebookEdit` of a file, it stores a snapshot of that file in git's object store with `git hash-object -w`. It records which files changed in `.git/claude-inline-review/session.json`. The mod passes every tool call through unchanged. It stops Claude only when it can't record a change.
- **A Neovim plugin** (repo root), which diffs each snapshot against your buffer and runs the review. *Work in progress.*

Changes Claude makes through `Bash` (`sed -i`, formatters, codegen) are not reviewed.

## Status

The mod (Milestones 1–2) works. The Neovim plugin is not built yet.

## Install the Claude Code mod

At the Claude Code prompt:

```
/plugin install nvim-inline-review --marketplace rohitsrao/claude-inline-review.nvim
```

Answer `y` to add the marketplace, then pick a scope. From a shell:

```
claude plugin install nvim-inline-review --marketplace rohitsrao/claude-inline-review.nvim
```

To try it from a local checkout: `claude --plugin-dir ./claude-mod`.

## Development

```
claude plugin validate ./claude-mod
claude plugin test ./claude-mod
```

## License

MIT
