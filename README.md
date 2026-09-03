# pointer.nvim

Claude points at code in your Neovim. Highlighted lines with a comment drawn above them, nothing written to the file.

## Install

```lua
{
    "vuki656/pointer.nvim",
    config = function()
        require("pointer").setup()
    end,
}
```

```sh
claude mcp add --scope user pointer -- node /path/to/pointer.nvim/mcp/server.mjs
```

Claude picks it up from the tool descriptions. Nudge it with "point at it" if it doesn't.

## Use

- `]a` / `[a` jump between points, across files
- `:Pointer clear` remove everything
- `:Pointer toggle` hide or show without removing
- `:Pointer next` / `:Pointer prev` same as the keymaps
- `:Pointer hover` show the comment under the cursor in a float
- `:Pointer style <chip|box|eol|float|loud>` change how comments are drawn
- `:Pointer qf` send points to quickfix

## Setup

```lua
require("pointer").setup({
    keymaps = true,
    style = "box",
    blend = 0.12,
    bar = "▎",
    colors = { note = "DiagnosticInfo", warn = "DiagnosticWarn" },
})
```

`colors` take a highlight group name or a hex string. Everything else derives from them and `Normal`. Set your own `Pointer*` groups on `ColorScheme` if you need finer control. Override any `Pointer{Note,Warn}{Line,Sign,Number,CardBar,CardText,Chip,Border,BoxText,Eol,LoudBar,LoudText}` group to change them.

## MCP tools

- `point` — `{ points: [{ file, line, end_line?, text, kind? }], focus? }`, files must exist
- `clear`
- `where` — current file, cursor line, last visual selection with its text

Picks the nvim in the same tmux window, then same session. `$NVIM` wins if set. With several nvims and no tmux match it refuses rather than guessing.
