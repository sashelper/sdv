# Optional View() takeover.
#
# RStudio has no API for adding items to its right-click menus. Its
# Environment pane grid icon sends `View(<name>)` to the console, and RStudio
# itself installs its data viewer by replacing the `View` binding in the
# attached "package:utils" environment (.rs.registerReplaceHook). Replacing that
# same binding routes those clicks, and plain View(x) calls, to StatDataViewer.

sdv_is_our_view <- function(f) isTRUE(attr(f, "sdv_view_hook", exact = TRUE))

sdv_is_tabular <- function(x) {
  is.data.frame(x) || is.matrix(x) || is.array(x) || inherits(x, c("table", "ts", "zoo")) ||
    ((is.atomic(x) || inherits(x, "POSIXlt")) && !is.null(x))
}

sdv_original_view <- function() {
  .sdv_state$orig_view %||% get("View", envir = asNamespace("utils"))
}

sdv_make_view <- function() {
  f <- function(x, title) {
    if (missing(title)) title <- deparse1(substitute(x), collapse = " ")
    types <- getOption("sdv.view_types", "tabular")
    if (identical(types, "all") || sdv_is_tabular(x)) {
      res <- tryCatch(sdv_view(x, name = title), error = function(e) e)
      if (!inherits(res, "error")) return(invisible(NULL))
      warning("StatDataViewer: ", conditionMessage(res),
              "\nFalling back to the RStudio viewer.", call. = FALSE)
    }
    # Call the original viewer with the original expression so RStudio still
    # knows which object is being viewed.
    eval(as.call(list(sdv_original_view(), substitute(x), title)), parent.frame())
  }
  attr(f, "sdv_view_hook") <- TRUE
  f
}

sdv_rebind <- function(env, sym, value) {
  locked <- bindingIsLocked(sym, env)
  if (locked) unlockBinding(sym, env)
  on.exit(if (locked) lockBinding(sym, env), add = TRUE)
  assign(sym, value, envir = env)
}

sdv_rprofile_snippet <- function(types = "tabular") {
  arg <- if (identical(types, "all")) "TRUE, types = \"all\"" else "TRUE"
  paste0(
    "setHook(\"rstudio.sessionInit\", function(newSession) {\n",
    "  if (requireNamespace(\"sdv\", quietly = TRUE))\n",
    "    sdv::sdv_use_as_viewer(", arg, ", quiet = TRUE)\n",
    "}, action = \"append\")")
}

#' Route View() and the Environment pane's grid icon to StatDataViewer
#'
#' When enabled, `View(x)` (and clicking the table icon next to an object in
#' RStudio's Environment pane) opens the object in StatDataViewer. Objects
#' that are not tabular (functions, lists, environments, ...) still open in
#' RStudio unless `types = "all"`.
#'
#' The change lasts for the current R session. To enable it automatically,
#' add the snippet printed by this function to `~/.Rprofile`.
#' @param enable `TRUE` to enable, `FALSE` to restore RStudio's viewer.
#' @param types `"tabular"` (data frames, matrices, arrays, tables, time
#'   series, atomic vectors) or `"all"`.
#' @param quiet Suppress messages.
#' @return Whether the override is active, invisibly.
#' @export
sdv_use_as_viewer <- function(enable = TRUE, types = c("tabular", "all"), quiet = FALSE) {
  types <- match.arg(types)
  env <- as.environment("package:utils")
  current <- get("View", envir = env)
  say <- function(...) if (!quiet) message(...)
  if (enable) {
    options(sdv.view_types = types)
    if (sdv_is_our_view(current)) {
      say("View() already opens objects in StatDataViewer.")
      return(invisible(TRUE))
    }
    .sdv_state$orig_view <- current
    sdv_rebind(env, "View", sdv_make_view())
    say("View() and the Environment pane grid icon now open ",
        if (types == "all") "all objects" else "tabular objects",
        " in StatDataViewer. Undo with sdv_use_as_viewer(FALSE).\n",
        "To enable this in every session, add to ~/.Rprofile:\n\n",
        sdv_rprofile_snippet(types))
    return(invisible(TRUE))
  }
  if (!sdv_is_our_view(current)) {
    say("View() is not currently redirected by sdv; nothing to undo.")
    return(invisible(FALSE))
  }
  sdv_rebind(env, "View", sdv_original_view())
  .sdv_state$orig_view <- NULL
  say("View() restored.")
  invisible(FALSE)
}
