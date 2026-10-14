# verilog.nvim

Tree-sitter powered helpers for writing Verilog / SystemVerilog in Neovim: instantiate modules from a file
picker, keep instantiations in sync with their source, connect ports and parameters, expand `.*` wildcards,
auto-declare wires, wire flat ports to an interface, and edit synthesis attributes.

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [How modules are located](#how-modules-are-located)
- [Commands](#commands)
  - [`:AutoInst`](#autoinst): instantiate a module, import a package, or update an instantiation
  - [`:ConnectPorts`](#connectports): connect ports and parameters
  - [`:ExpandWildcards`](#expandwildcards): expand `.*` port connections
  - [`:AutoWire`](#autowire): declare nets used by instantiations
  - [`:WireInterface`](#wireinterface): connect flat ports to an interface
  - [`:ToggleAttribute` / `:SetAttribute`](#toggleattribute--setattribute): edit `(* ... *)` attributes
- [Suggested keymaps](#suggested-keymaps)
- [Expanding wildcards on save](#expanding-wildcards-on-save)
- [Health check](#health-check)
- [Running the tests](#running-the-tests)

## Requirements

- Neovim **0.10+**
- The tree-sitter `systemverilog` parser. The plugin only uses Neovim's built-in `vim.treesitter` API, so any way of
  installing the parser works; the usual one is [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
  with `:TSInstall systemverilog`. The plugin always parses with `systemverilog`, including in `verilog` buffers.
  Older nvim-treesitter versions call the same parser `verilog`; the plugin falls back to it when `systemverilog` is
  not installed
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (and its dependency
  [plenary.nvim](https://github.com/nvim-lua/plenary.nvim))
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) on your `PATH`, used by the `:AutoInst` file picker

## Installation

The Lua module is named `verilog`. The plugin has no `plugin/` directory, so commands only exist after you call
`require("verilog").setup()`.

Replace `OWNER/verilog.nvim` below with the repository's actual location.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "OWNER/verilog.nvim",
  ft = { "verilog", "systemverilog" },
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" }, -- provides the systemverilog parser
  },
  config = function()
    require("verilog").setup({
      -- cmd = "AutoInst",                 -- rename the :AutoInst command
      -- expand_wildcards_on_save = false, -- expand .* on every write (see below)
    })
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use({
  "OWNER/verilog.nvim",
  requires = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    { "nvim-treesitter/nvim-treesitter", run = ":TSUpdate" }, -- provides the systemverilog parser
  },
  config = function()
    require("verilog").setup()
  end,
})
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-treesitter/nvim-treesitter', { 'do': ':TSUpdate' }
Plug 'OWNER/verilog.nvim'

" after plug#end()
lua require("verilog").setup()
```

### Native packages (no plugin manager)

```sh
git clone https://github.com/OWNER/verilog.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/verilog.nvim
```

```lua
-- init.lua
require("verilog").setup()
```

## Configuration

`setup()` takes an optional table:

| Option                     | Default      | Description                                                                  |
| -------------------------- | ------------ | ---------------------------------------------------------------------------- |
| `cmd`                      | `"AutoInst"` | Name of the instantiate/update command.                                      |
| `expand_wildcards_on_save` | `false`      | Run `:ExpandWildcards` in a `BufWritePre` autocmd for `*.v,*.sv,*.svh,*.vh`. |

```lua
require("verilog").setup({
  cmd = "Inst",
  expand_wildcards_on_save = true,
})
```

## How modules are located

Most commands need to read the source of a module or interface that's instantiated in the current buffer. The
plugin finds it by **file name**: for an instance of `fifo`, it searches recursively from Neovim's current working
directory for the first file named `fifo.v`, `fifo.sv`, `fifo.svh`, or `fifo.vh`. Two consequences:

- Keep each module in a file with the same name as the module.
- Start Neovim (or `:cd`) at your project root.

When a source file can't be found, the command skips that instantiation and leaves it alone.

The `:AutoInst` file picker is different: it lists every Verilog file under the project root (found through LSP
workspace folders, then a `.git` directory, then the cwd) using `rg -tverilog --files`.

## Commands

The examples below use these source files:

```systemverilog
// simple.sv
module simple (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data_in,
    output logic [7:0] data_out
);
endmodule
```

```systemverilog
// parameterized.sv
module parameterized #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic              clk,
    input  logic [WIDTH-1:0]  data_in,
    output logic [WIDTH-1:0]  data_out
);
endmodule
```

### `:AutoInst`

`:AutoInst` does different things depending on its argument and where the cursor is.

#### Instantiate a module from a picker

With no argument and the cursor **outside** any instantiation, `:AutoInst` opens a Telescope picker of the
project's Verilog files. Pick one and an instantiation of its first module (or interface) goes below the cursor
line, with parameter defaults filled in and every port left unconnected:

```systemverilog
parameterized # ( .WIDTH(8), .DEPTH(16)) u_parameterized( .clk(), .data_in(), .data_out());
```

The instance is named `u_<module>`. Run your formatter afterwards if you want it split across lines.

#### Instantiate from a path

Pass a file path to skip the picker:

```vim
:AutoInst rtl/fifo/simple.sv
```

#### Import a package

If the chosen file has no module or interface but does declare one or more packages, `:AutoInst` adds an import
for each package to the module under the cursor instead. Imports that are already there aren't added twice:

```systemverilog
// before                         // after :AutoInst rtl/pkg/my_pkg.sv
module top (input clk);           module top import my_pkg::*; (input clk);
```

If the module already has an import list, `my_pkg::*` is appended to it. Inside a `package` the plugin inserts an
`import my_pkg::*;` line.

#### Update an existing instantiation

With no argument and the cursor **inside** an instantiation, `:AutoInst` re-reads the module's source and
reconciles the instance with it:

- Ports and parameters that are missing get added (parameters use the source default).
- Ports and parameters that no longer exist get removed.
- Existing connections, overrides, and comments are kept.

```systemverilog
// before
simple u_simple ();

// after :AutoInst
simple u_simple (
.clk(),
.rst_n(),
.data_in(),
.data_out()
);
```

If a port or parameter was **renamed** in the source (so the instance has a stale name *and* the source has a new
one), you get a `vim.ui.select` prompt for each stale entry:

```text
Rename stale port .old_clk to:
  rename → .clk
  [delete]
```

Choose a rename to keep the existing connection under the new name (`.old_clk(parent_clk)` becomes
`.clk(parent_clk)`). Choose `[delete]` or cancel to drop it.

### `:ConnectPorts`

`:ConnectPorts` checks what's under the cursor and runs the matching flow:

| Cursor position                                  | Action                                      |
| ------------------------------------------------ | ------------------------------------------- |
| On a parameter override, e.g. `.WIDTH(8)`        | Connect that parameter                      |
| On a port connection, e.g. `.data_in(...)`       | Connect that port                           |
| Anywhere else inside a module instantiation      | Pick a parameter to connect, then connect it |

#### Connecting a port

Put the cursor on a named port connection and run `:ConnectPorts`. A Telescope picker lists the **ports with the
same type** as the selected one:

- ports on other instances in the current module (if a source file can't be found, all of that instance's ports
  are listed),
- ports of the current module,
- **Breakout Port**, which adds the port to the current module's port list and connects it.

Each entry shows `instance | module | port`. What happens next depends on the pick:

- **Another instance's port.** Both connections get the same net. If the selected port is already connected, its
  net name is used. Otherwise, if the target port is connected, its net name is used. If neither is connected, you
  are asked for a net name and the plugin declares it as `<type> <net>;`. The declaration goes directly above whichever
  of the two instantiations comes first. For an interface port it declares an interface instance instead.
- **A current-module port.** The selected port is connected to it.
- **Breakout Port.** A port with the same direction and type is appended to the module header (ANSI or non-ANSI,
  e.g. `output logic [7:0] data_out`) and connected.

```systemverilog
module top (input clk);
    simple u_a (.clk(clk), .rst_n(), .data_in(), .data_out());   // cursor on .data_out
    simple u_b (.clk(clk), .rst_n(), .data_in(), .data_out());
endmodule
// :ConnectPorts → pick "u_b | simple | data_in" → enter "a_to_b"
module top (input clk);
logic [7:0] a_to_b;
    simple u_a (.clk(clk), .rst_n(), .data_in(), .data_out(a_to_b));
    simple u_b (.clk(clk), .rst_n(), .data_in(a_to_b), .data_out());
endmodule
```

#### Connecting parameters

With the cursor elsewhere inside an instantiation, the first picker lists the module's parameters with their type
and either the current override (`override=…`) or the default (`default=…`). If the cursor is already on a
`.PARAM(...)` override, the plugin skips this step.

The second picker lists where to connect it:

- an existing `parameter` or `localparam` in the current module,
- `[new parameter]`: adds `parameter <type> <name> = <default>` to the module's `#(...)` list, creating the list if
  needed,
- `[new localparam]`: adds `localparam <type> <name> = <default>;` right after the module header.

For the two "new" options you are asked for a name, pre-filled with the source parameter's name. The instance's
override is then set, replaced, or created:

```systemverilog
// before
module parent (input clk);
    parameterized u_p (.clk(clk));
endmodule

// :ConnectPorts → WIDTH → [new parameter] → OUTER_WIDTH
module parent #(parameter int OUTER_WIDTH = 8) (input clk);
    parameterized #(.WIDTH(OUTER_WIDTH)) u_p (.clk(clk));
endmodule
```

### `:ExpandWildcards`

Expands every `.*` implicit connection in the buffer into explicit same-name connections, using the port list
from each module's source. Ports you've already connected by name are kept as they are and aren't repeated:

```systemverilog
// before
simple u_b (.clk(my_clk), .*);

// after :ExpandWildcards
simple u_b (.clk(my_clk), .rst_n(rst_n), .data_in(data_in), .data_out(data_out));
```

If every port is already explicit, the redundant `.*` (and its comma) is removed.

### `:AutoWire`

Declares the nets that instantiations in the current module connect to but that aren't declared yet. The plugin
uses the module under the cursor, or the first module in the buffer. The declarations go just above the first
instantiation, typed from the source port:

```systemverilog
// before
module parent (input clk);
    simple u_simple (.clk(clk), .rst_n(my_rst), .data_in(my_data), .data_out(my_out));
endmodule

// after :AutoWire
module parent (input clk);
logic my_rst;
logic [7:0] my_data;
logic [7:0] my_out;
    simple u_simple (.clk(clk), .rst_n(my_rst), .data_in(my_data), .data_out(my_out));
endmodule
```

Details:

- Only connections to a bare identifier are considered. Slices, concatenations, literals, hierarchical references,
  and empty `()` are skipped.
- Names that are already declared aren't declared again: ports, `logic`/`wire` declarations, and instance names.
  A net shared by several instances is declared once.
- Parameters in the port width are substituted: the instance's override is used first, then the source default.
  For example, `parameterized #(.WIDTH(16))` gives `logic [16-1:0] my_in;`, and if the override is a parameter of
  the parent (`.WIDTH(WIDTH)`), that name is kept.
- If a width would still reference an identifier that isn't in scope, that net is skipped rather than declared
  with a broken type.

### `:WireInterface`

Connects an instance's flat ports to the signals of a SystemVerilog interface that's in scope. Put the cursor
inside the instantiation and run `:WireInterface`.

Candidate interfaces are:

- interface ports of the current module (e.g. `axis_if.s s_axis`),
- interface instances in the module body (e.g. `axis_if axis_inst();`).

Port names are matched to interface signals after stripping an `i_`, `o_`, or `b_` direction prefix. A port
matches a signal when the stripped name equals it or ends in `_<signal>`, so `i_axis_rdy` matches `rdy`. A
Telescope picker shows each candidate with its match count (`match 3/4`), best first. The plugin then adds the
missing connections and fills empty `.port()` slots. Ports that are already connected to something are left alone.

```systemverilog
// axis_if.sv
interface axis_if;
    logic [31:0] data;
    logic        vld;
    logic        rdy;
    modport m(output data, vld, input rdy);
    modport s(input data, vld, output rdy);
endinterface

// axis_master.sv
module axis_master (
    input  logic        i_clk,
    input  logic        i_axis_rdy,
    output logic        o_axis_vld,
    output logic [31:0] o_axis_data
);
endmodule
```

```systemverilog
// before
module top (axis_if.s s_axis, input clk);
    axis_master u_master (.i_clk(clk));
endmodule

// :WireInterface → pick "s_axis"
module top (axis_if.s s_axis, input clk);
    axis_master u_master (.i_clk(clk), .i_axis_rdy(s_axis.rdy), .o_axis_data(s_axis.data), .o_axis_vld(s_axis.vld));
endmodule
```

### `:ToggleAttribute` / `:SetAttribute`

These commands edit Verilog attributes (`(* name = value *)`) on a declaration. Put the cursor on **any use** of a
signal or instance name. The plugin finds the declaration in the current module and edits the attribute there.

`:ToggleAttribute <name>` flips a boolean-style attribute:

| Current value             | New value |
| ------------------------- | --------- |
| *(absent)* or `"FALSE"`   | `"TRUE"`  |
| `"TRUE"`                  | `"FALSE"` |
| `"YES"` / `"yes"`         | `"no"`    |
| `"NO"` / `"no"`           | `"yes"`   |

`:SetAttribute <name> <value>` sets any value. Quote string values yourself:

```vim
:ToggleAttribute MARK_DEBUG
:SetAttribute ASYNC_REG "TRUE"
:SetAttribute KEEP_HIERARCHY "yes"
```

```systemverilog
// before                    // after :ToggleAttribute MARK_DEBUG (cursor on a use of `valid`)
logic valid;                 (* MARK_DEBUG = "TRUE" *) logic valid;
```

If the declaration already has an attribute instance, the new attribute is added to it, or the existing value is
replaced if the attribute is already there.

## Suggested keymaps

The plugin doesn't define any mappings. For example:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "verilog", "systemverilog" },
  callback = function(ev)
    local map = function(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, desc = desc })
    end
    map("<leader>vi", "<cmd>AutoInst<cr>", "Instantiate / update module")
    map("<leader>vc", "<cmd>ConnectPorts<cr>", "Connect port / parameter")
    map("<leader>ve", "<cmd>ExpandWildcards<cr>", "Expand .* connections")
    map("<leader>vw", "<cmd>AutoWire<cr>", "Declare undeclared nets")
    map("<leader>vI", "<cmd>WireInterface<cr>", "Wire ports to interface")
    map("<leader>vd", "<cmd>ToggleAttribute MARK_DEBUG<cr>", "Toggle MARK_DEBUG")
  end,
})
```

## Expanding wildcards on save

`expand_wildcards_on_save = true` registers a `BufWritePre` autocmd. That autocmd **races with async formatters**
(LSP format-on-save, conform.nvim with `async = true`, …): the formatter captures the buffer before expansion and
then writes that old text back, so the expansion is lost.

If you format on save, leave the option off and run the expansion inside your formatter's pipeline instead. With
[conform.nvim](https://github.com/stevearc/conform.nvim):

```lua
require("conform").setup({
  formatters_by_ft = {
    verilog = { "verible" },
    systemverilog = { "verible" },
  },
  format_on_save = function(bufnr)
    local ft = vim.bo[bufnr].filetype
    if ft == "verilog" or ft == "systemverilog" then
      require("verilog.wildcard").expand_file(bufnr)
    end
    return { timeout_ms = 500, lsp_format = "fallback" }
  end,
})
```

`require("verilog.wildcard").expand_file(bufnr)` returns the number of `.*` connections it changed.

## Health check

```vim
:checkhealth verilog
```

This checks the Neovim version, telescope.nvim, the `systemverilog` parser, and `rg`.

## Running the tests

The tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted runner. `plenary.nvim`,
`telescope.nvim`, and `nvim-treesitter` (for the `systemverilog` parser) must be installed somewhere `tests/minimal_init.lua`
can find them (lazy.nvim's data directory or `site/pack/*/{start,opt}`).

```sh
make test
```
