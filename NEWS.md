# sdv 0.3.1

* The path `sdv_view()` returns is the one handed to the viewer: on Windows it
  mixed `\\` and `/` (the test for it failed there on CI).

# sdv 0.3.0

* `sdv_connect()`: a live connection to StatDataViewer. The app lists this
  session's global environment in its Library tree, refreshed after every
  command, and opens snapshots on double-click; objects sent from RStudio
  travel over the connection and the viewer comes to the current Space.
  Needs the Suggests websocket and later; without a connection nothing
  changes. `sdv_disconnect()`, `sdv_connected()`, options `sdv.port`,
  `sdv.token`, `sdv.inventory_max`, `sdv.open_timeout`.
* jsonlite is imported.

# sdv 0.2.0

* `sdv_use_as_viewer()` now sends every object to StatDataViewer by default:
  functions as R code, lists as trees, models and other objects as text.
  `types = "tabular"` keeps the old behaviour.
* New addin "Open Global Environment in StatDataViewer" and `sdv_view_env()`:
  an inventory of an environment with each object's kind (Data, Values or
  Functions, as in RStudio's Environment pane), class, dimensions, size and a
  one-line description. `sdv_install_shortcut(binding = "sdv_addin_env")`
  binds it to Cmd+Alt+Shift+V (Ctrl+Alt+Shift+V on Windows/Linux).
* `sdv_install_shortcut()` and `sdv_remove_shortcut()` accept
  `binding = "sdv_addin_env"`; the prompt addin needs an explicit key.
* The README explains which Environment pane rows RStudio makes clickable
  and how to send the others.

# sdv 0.1.0

* First release.
* RStudio addins "Open in StatDataViewer" and "Open object in StatDataViewer…":
  they send the selected code's result, or the object under the cursor, to
  StatDataViewer.
* `sdv_view()` sends any R object from the console. Tabular objects open as
  data tables; functions, models and other objects open as text.
* `sdv_use_as_viewer()` makes `View()` and the Environment pane's grid icon open
  objects in StatDataViewer. It can be turned off again.
* `sdv_install_shortcut()` binds the addin to Cmd+Shift+V (Ctrl+Shift+V on
  Windows/Linux).
* Columns are converted so that StatDataViewer's R reader shows them correctly.
  This covers factors, time zones, integer-stored dates, list columns,
  integer64, labelled vectors and more.
