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
