# Package-level mutable state and default options.

.sdv_state <- new.env(parent = emptyenv())
.sdv_state$counter <- 0L
.sdv_state$last_expr <- ""
.sdv_state$orig_view <- NULL

.sdv_default_options <- list(
  sdv.bundle_id = "com.statdataviewer",
  sdv.view_types = "tabular",
  sdv.max_text_lines = 100000L,
  sdv.list_max_rows = 10000L
)

.onLoad <- function(libname, pkgname) {
  op <- options()
  toset <- !(names(.sdv_default_options) %in% names(op))
  if (any(toset)) options(.sdv_default_options[toset])
  invisible()
}

sdv_opt <- function(name, default = NULL) {
  getOption(paste0("sdv.", name), default)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

sdv_next_id <- function() {
  .sdv_state$counter <- .sdv_state$counter + 1L
  .sdv_state$counter
}
