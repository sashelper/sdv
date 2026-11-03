# sdv — open R objects in StatDataViewer

<!-- badges: start -->
[![R-CMD-check](https://github.com/sashelper/sdv/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/sashelper/sdv/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

[中文说明](README.zh-CN.md)

An RStudio addin that sends objects from your R session to the
[StatDataViewer](https://statdataviewer.com/) desktop app: data frames and
matrices as tables, functions as code, lists as trees, models and anything
else as text, and the whole environment as an inventory. You can send them
with a keyboard shortcut, from the Addins menu, or through `View()`.

## Installation

```r
install.packages("sdv", repos = c("https://sashelper.r-universe.dev",
                                  "https://cloud.r-project.org"))
```

You can also install the development version from GitHub:

```r
# install.packages("pak")
pak::pak("sashelper/sdv")
```

You also need StatDataViewer itself, on macOS or Windows.

## Usage

| How | Setup |
|---|---|
| Keyboard shortcut **⌘⇧V** (Cmd+Shift+V; Ctrl+Shift+V on Windows) sends one object | Run `sdv::sdv_install_shortcut()` once, then restart RStudio. Pick another key with `sdv_install_shortcut("Cmd+Shift+K")`. |
| **⌥⌘⇧V** (Cmd+Alt+Shift+V; Ctrl+Alt+Shift+V on Windows) lists the whole global environment | Run `sdv::sdv_install_shortcut(binding = "sdv_addin_env")` once, then restart RStudio. |
| Addins menu / Command Palette (⇧⌘P) | Search for "StatDataViewer": one object, the global environment, or a prompt to type a name or expression. |
| `View(x)` and clicking a name in the Environment pane | Turn on with `sdv::sdv_use_as_viewer(TRUE)`; `FALSE` restores RStudio's viewer. |
| Console | `sdv::sdv_view(x)` for one object, `sdv::sdv_view_env()` for the global environment, or `library(sdv)` first and drop the `sdv::`. |

Every exported function starts with `sdv_`, so `library(sdv)` does not mask
functions from other packages.

The **Open in StatDataViewer** addin decides what to send in this order:

1. **Selected code**, in the editor or the console, is evaluated in the global
   environment and the result is sent. This works for `head(mtcars, 3)` or a
   whole pipeline.
2. **With nothing selected**, it sends the object name under the cursor. That
   can be `df`, `df$col`, `obj@slot`, `pkg::obj` or `` `a name with spaces` ``.
   With the cursor on `df` in `df$col` it sends `df`; on `col` it sends
   `df$col`.
3. **If neither works**, or evaluation fails, a prompt asks you for an object
   name or expression.

## Any object

Every kind of object opens, not only data frames (see the table below):
functions as R code, lists as trees, models and S4 objects as text. The
shortcut and the Addins menu take any object. So does `View()` once
`sdv_use_as_viewer(TRUE)` is on; pass `types = "tabular"` to keep functions,
lists and models in RStudio's own viewers.

RStudio does not let addins add items to its right-click menus. Taking over
`View()` is the closest substitute, because clicking an object's name in the
Environment pane runs `View()`. RStudio only makes the names of **Data** rows
(data frames, matrices, lists, environments, S4 objects, models) and
**Function** rows clickable; **Values** rows (vectors, factors, single values)
have no click target in RStudio at all. Send those with the shortcut, the
Addins menu or `sdv_view(x)`. To turn the `View()` takeover on in every
session, add the snippet that `sdv_use_as_viewer()` prints to your
`~/.Rprofile`.

## The whole environment

`sdv_view_env()`, the **Open Global Environment in StatDataViewer** addin and
its ⌥⌘⇧V shortcut open an inventory of the global environment, one row per
object: name, kind (Data, Values or Functions, as in RStudio's Environment
pane), class, dimensions, size and a one-line description. Sort and filter it
in StatDataViewer, and send it again after the environment has changed. Any
environment works: `sdv_view_env(environment(lm))`.

## Supported objects

| R object | Shown in StatDataViewer as |
|---|---|
| data.frame, tibble, data.table, sf | A table. Row names that aren't the default become a `row_names` column. |
| matrix, 2-D table / xtabs | A wide table |
| arrays and tables with 3+ dimensions | A long table |
| ts / mts, zoo / xts | A table with `time` and `cycle` columns (or `index`) plus the values |
| atomic vectors, factors, Dates | A `value` column, plus a `name` column for named vectors |
| lists | A table when all elements have the same length; otherwise a tree with path / class / type / size / preview columns |
| environments | An inventory of the objects they contain: name, kind, class, dimensions, size, description |
| functions, formulas, calls | `.R` text |
| lm / glm | Text of `summary()` |
| S4, R6, htest and anything else | Text of `print()` and `str()` |

StatDataViewer's R reader displays only a few column types, so each column is
converted first:

- **factor** → its labels.
- **POSIXct / POSIXlt** → the wall-clock time in the original time zone. The
  viewer always shows times in UTC, so the values are shifted, and the time zone
  is recorded in the column label.
- **Date** → stored as double. StatDataViewer versions before the fix mis-read
  integer-stored dates, such as those from `seq()` in recent R versions.
- **list columns, complex, raw** → short text summaries.
- **difftime** → a number, with the unit in the column label.
- **hms** → `HH:MM:SS` text.
- **integer64** → a number, or text when the value is beyond 2^53.
- **haven_labelled** → the codes, plus an extra `*_lbl` column holding the
  labels.
- **data frame and matrix columns** → several columns.

## Options

| Option | Purpose |
|---|---|
| `sdv.app` | Path to the `StatDataViewer.app` to use (macOS). Useful if several copies are installed. |
| `sdv.exe` | Path to `StatDataViewer.exe` (Windows) |
| `sdv.dir` | Folder for the temporary files; default `tempdir()/sdv` |
| `sdv.view_types` | `"all"` (default) or `"tabular"`: which objects `View()` sends |
| `sdv.max_text_lines` | Maximum number of lines in text output |
| `sdv.list_max_rows` | Maximum number of rows when a list is shown as a tree |

## How it works

1. `sdv_prepare()` converts the object into a plain data frame or into text.
2. The result is written to a new temporary folder with
   `saveRDS(version = 2)`, uncompressed. A new folder each time means the viewer
   never asks "Reload Dataset?". The file is named after the object, so that name
   is also the tab title.
3. **macOS:** `open -b com.statdataviewer <file>` hands the file to the running
   app, or starts it first.
4. **Windows:** runs `StatDataViewer.exe <file>`. The app passes the file on to
   the instance that is already running.

## Extending

Add an S3 method for your own class. It can return a data frame (shown as a
table), a character vector (shown as text) or `NULL`:

```r
sdv_prepare.myclass <- function(x, name = "object", ...) as.data.frame(x$data)
```

## Development

```sh
Rscript -e 'testthat::test_local()'
```

`test-librdata-compat.R` is optional. When the StatDataViewer source tree is
present (`SDV_SOURCE_DIR`), it compiles a small probe with the viewer's R
reader under AddressSanitizer. The probe checks, cell by cell, what the viewer
would display for every kind of output. The test is skipped everywhere else,
including CI.

See [RELEASING.md](RELEASING.md) for the release steps.

## License

MIT
