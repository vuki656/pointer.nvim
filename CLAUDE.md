# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Neovim plugin plus an MCP server. Claude calls the MCP `point` tool, the server forwards it to a running nvim over its socket, and the plugin draws highlighted lines with a comment above them using extmarks. Nothing is written to files. No persistence: points live in nvim memory until `:Pointer clear`.

## Commands

- `stylua lua plugin` — format Lua (config in `stylua.toml`)
- `node --check mcp/server.mjs` — syntax-check the server
- Manual test of the plugin without your config:
  `nvim --headless --clean -c 'set rtp+=. | runtime plugin/pointer.lua' -c 'lua local p = require("pointer") p.setup() ...' -c 'qa!'`
- Manual test of the server against a live nvim: pipe newline-delimited JSON-RPC (`initialize`, `tools/list`, `tools/call`) into `node mcp/server.mjs`. Set `TMUX_PANE` so socket discovery matches the right nvim.

No automated tests.

## Architecture

`lua/pointer/init.lua` is the whole plugin. Module-level state: `points` (ordered list, insertion order is the `]a` order), `config`, `hidden`, `float_win`, `last_selection`. Each point holds one extmark id (`mark`) with `end_row`, so the live extmark position is the truth for the range; `detach` writes it back into `point.line`/`point.end_line` before removing the mark, and `BufUnload` detaches so positions survive `:bd` and reopen. Points for files not yet open are rendered on `BufWinEnter`.

Rendering goes through `render` → `build_virt_lines`, keyed on `config.style` (`chip`, `box`, `eol`, `float`, `loud`). `float` and `eol` open a floating window on focus instead of virt lines. Colors are computed in `set_colors` by blending `DiagnosticInfo`/`DiagnosticWarn` into `Normal` bg, all `default = true` so users can override.

`M.rpc(json)` is the single entry point the server calls via `nvim --server <sock> --remote-expr "v:lua.require('pointer').rpc('<json>')"`. It calls `setup()` if the user never did, decodes with `luanil`, dispatches on `method`, and always returns a JSON string, with `{ error }` on failure. `M.add` validates and renders before inserting into `points`, so a failing point in a batch never leaves partial state.

`mcp/server.mjs` is zero-dependency stdio JSON-RPC written by hand (no MCP SDK). Socket discovery: `$NVIM`, else live sockets in `$XDG_RUNTIME_DIR` filtered by a 1.5s probe, preferring the nvim in the same tmux window, then session; several candidates with no tmux match is an error, not a guess. Every `execFileSync` to nvim has a timeout because a nvim sitting at a hit-enter prompt blocks `--remote-expr` forever. Payload single quotes are doubled for the vim string literal; that is the only escaping needed.

`plugin/pointer.lua` defines `:Pointer <clear|toggle|next|prev|qf|hover|style>` and reads the style list from `require("pointer").styles`.

## Conventions

- No code comments.
- Keep the feature set small on purpose; the README lists everything the user is expected to remember.
- `dvnotes/` is local notes, ignored by git.
