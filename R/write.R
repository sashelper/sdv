# Writing payloads to disk. Every send gets its own directory so the viewer
# never sees the same path twice (re-opening a path triggers its
# "Reload Dataset?" prompt) while the file name, which becomes the tab title,
# stays the object name.

sdv_safe_name <- function(name) {
  s <- if (is.null(name) || !length(name) || is.na(name[1])) "" else sdv_utf8(name[1])
  s <- gsub("[^\\p{L}\\p{N}._-]+", "_", s, perl = TRUE)
  s <- gsub("^[._-]+|[._-]+$", "", s, perl = TRUE)
  if (nchar(s) > 80L) s <- substr(s, 1L, 80L)
  if (!nzchar(s)) "object" else s
}

sdv_output_dir <- function() {
  base <- sdv_opt("dir") %||% file.path(tempdir(), "sdv")
  sub <- sprintf("%s-%04d", format(Sys.time(), "%Y%m%d-%H%M%S"), sdv_next_id())
  d <- file.path(path.expand(base), sub)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(d)) stop("Cannot create output directory: ", d, call. = FALSE)
  normalizePath(d, mustWork = TRUE)
}

#' Write a prepared object to a file StatDataViewer can open
#'
#' @param payload Result of [sdv_prepare()].
#' @return Path of the written file.
#' @keywords internal
sdv_write <- function(payload) {
  stopifnot(inherits(payload, "sdv_payload"))
  dir <- sdv_output_dir()
  safe <- sdv_safe_name(payload$name)
  if (payload$kind == "table") {
    chk <- sdv_is_clean(payload$data)
    if (!isTRUE(chk)) {
      stop("Internal error: prepared table is not viewer-safe:\n  ",
           paste(attr(chk, "problems"), collapse = "\n  "), call. = FALSE)
    }
    path <- file.path(dir, paste0(safe, ".rds"))
    # Version 2 serialization never writes ALTREP objects, which librdata can't read.
    saveRDS(payload$data, path, version = 2L, compress = FALSE)
  } else {
    path <- file.path(dir, paste0(safe, ".", payload$ext))
    writeLines(sdv_utf8(payload$data), path, useBytes = TRUE)
  }
  path
}
