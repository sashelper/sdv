# Optional View() takeover.
#
# RStudio has no API for adding items to its right-click menus. Its
# Environment pane sends `View(<name>)` to the console when the name of a
# Data row (data frames, matrices, lists, environments, S4 objects) or a
# Function row is clicked; atomic vectors, factors and single values are
# "Values" rows there and have no click target at all. RStudio itself
# installs its data viewer by replacing the `View` binding in the attached
# "package:utils" environment (.rs.registerReplaceHook). Replacing that same
# binding routes those clicks, and plain View(x) calls, to StatDataViewer.

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
    types <- getOption("sdv.view_types", "all")
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

sdv_rprofile_snippet <- function(types = "all") {
  arg <- if (identical(types, "tabular")) "TRUE, types = \"tabular\"" else "TRUE"
  paste0(
    "setHook(\"rstudio.sessionInit\", function(newSession) {\n",
    "  if (requireNamespace(\"sdv\", quietly = TRUE))\n",
    "    sdv::sdv_use_as_viewer(", arg, ", quiet = TRUE)\n",
    "}, action = \"append\")")
}

#' Route View() and the Environment pane to StatDataViewer
#'
#' When enabled, `View(x)` opens `x` in StatDataViewer whatever `x` is:
#' data frames, matrices, tables and vectors as data tables, functions as R
#' code, lists as trees, models and other objects as text (see
#' [sdv_prepare()]). Clicking an object's name in RStudio's Environment pane
#' runs `View()` too, so data frames, matrices, lists, environments, models
#' and functions open in StatDataViewer from there. Vectors, factors and
#' single values are "Values" rows in that pane and have no click target in
#' RStudio: send them with the shortcut, the Addins menu or [sdv_view()].
#'
#' The change lasts for the current R session. To enable it automatically,
#' add the snippet printed by this function to `~/.Rprofile`.
#' @param enable `TRUE` to enable, `FALSE` to restore RStudio's viewer.
#' @param types `"all"` (the default) sends every object. `"tabular"` sends
#'   only data frames, matrices, arrays, tables, time series and atomic
#'   vectors, and leaves functions, lists and models to RStudio's own viewers.
#' @param quiet Suppress messages.
#' @return Whether the override is active, invisibly.
#' @export
sdv_use_as_viewer <- function(enable = TRUE, types = c("all", "tabular"), quiet = FALSE) {
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
    say("View() and the Environment pane now open ",
        if (types == "all") "every object" else "tabular objects",
        " in StatDataViewer. Undo with sdv_use_as_viewer(FALSE).\n",
        "Vectors and single values have no click target in the Environment pane; ",
        "send them with the shortcut, the Addins menu or sdv_view(x).\n",
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
