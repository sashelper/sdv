# Handing a file to StatDataViewer.
#
# macOS: the app handles the "open document" Apple event (QFileOpenEvent), so
# `open -b com.statdataviewer <file>` delivers the file to the running
# instance, launching it first if needed. Command-line arguments are ignored
# on macOS.
# Windows: the app opens argv[1]; a second instance forwards the path to the
# running one over its single-instance local socket.

#' Open a file in StatDataViewer
#'
#' @param path File to open (.rds, .txt, .R, or any format the app reads).
#' @return `TRUE` invisibly; errors with a hint when the app can't be found.
#' @export
sdv_open_file <- function(path) {
  sdv_launch(path)
}

sdv_launch <- function(path) {
  path <- normalizePath(path, mustWork = TRUE)
  # Connected to the viewer (sdv_connect()): hand the file over the connection,
  # and let the viewer bring itself to the user. Falls through to `open` when
  # the viewer does not acknowledge in time.
  ext <- tolower(tools::file_ext(path))
  name <- sub("\\.[^.]*$", "", basename(path))
  if (sdv_bridge_open_file(path, name, if (ext == "rds") "table" else "text")) {
    return(invisible(TRUE))
  }
  launcher <- sdv_opt("launcher")
  if (is.function(launcher)) return(invisible(launcher(path)))
  if (.Platform$OS.type == "windows") return(sdv_launch_windows(path))
  if (identical(Sys.info()[["sysname"]], "Darwin")) return(sdv_launch_mac(path))
  stop("StatDataViewer integration supports macOS and Windows only. File saved at: ",
       path, call. = FALSE)
}

sdv_run <- function(cmd, args) {
  out <- tryCatch(suppressWarnings(system2(cmd, args, stdout = TRUE, stderr = TRUE)),
                  error = function(e) structure(conditionMessage(e), status = 127L))
  status <- attr(out, "status") %||% 0L
  list(ok = identical(as.integer(status), 0L), output = paste(out, collapse = "\n"))
}

sdv_mac_open_args <- function(path, app = NULL, bundle_id = NULL) {
  if (!is.null(app)) c("-a", shQuote(app), shQuote(path))
  else c("-b", shQuote(bundle_id), shQuote(path))
}

sdv_mac_candidates <- function(bundle_id) {
  cands <- c("/Applications/StatDataViewer.app",
             path.expand("~/Applications/StatDataViewer.app"))
  found <- tryCatch(suppressWarnings(system2(
    "mdfind", shQuote(sprintf("kMDItemCFBundleIdentifier == '%s'", bundle_id)),
    stdout = TRUE, stderr = FALSE)), error = function(e) character())
  unique(c(cands[dir.exists(cands)], found[nzchar(found) & dir.exists(found)]))
}

sdv_launch_mac <- function(path) {
  app <- sdv_opt("app") %||% Sys.getenv("STATDATAVIEWER_APP", "")
  if (nzchar(app)) {
    app <- path.expand(app)
    r <- sdv_run("open", sdv_mac_open_args(path, app = app))
    if (r$ok) return(invisible(TRUE))
    stop(sprintf("Could not open StatDataViewer at '%s': %s\nFile saved at: %s",
                 app, r$output, path), call. = FALSE)
  }
  bundle_id <- sdv_opt("bundle_id", "com.statdataviewer")
  r <- sdv_run("open", sdv_mac_open_args(path, bundle_id = bundle_id))
  if (r$ok) return(invisible(TRUE))
  for (cand in sdv_mac_candidates(bundle_id)) {
    if (sdv_run("open", sdv_mac_open_args(path, app = cand))$ok) return(invisible(TRUE))
  }
  stop(paste0(
    "StatDataViewer was not found (", r$output, ").\n",
    "Install it, or point to the app with\n",
    "  options(sdv.app = \"/path/to/StatDataViewer.app\")\n",
    "File saved at: ", path), call. = FALSE)
}

sdv_windows_candidates <- function() {
  env <- function(v) Sys.getenv(v, "")
  roots <- c(file.path(env("LOCALAPPDATA"), "Programs", "StatDataViewer"),
             file.path(env("ProgramFiles"), "StatDataViewer"),
             file.path(env("ProgramFiles(x86)"), "StatDataViewer"),
             file.path(env("USERPROFILE"), "SASHelper"))
  roots <- roots[nzchar(roots) & dir.exists(roots)]
  c(unname(Sys.which("StatDataViewer")),
    file.path(roots, "StatDataViewer.exe"),
    unlist(lapply(roots, function(r) Sys.glob(file.path(r, "*", "StatDataViewer.exe")))))
}

sdv_find_exe <- function() {
  cands <- c(sdv_opt("exe"), Sys.getenv("STATDATAVIEWER_EXE", ""), sdv_windows_candidates())
  cands <- cands[!is.na(cands) & nzchar(cands)]
  hit <- cands[file.exists(cands)]
  if (length(hit)) normalizePath(hit[1]) else NULL
}

sdv_launch_windows <- function(path) {
  exe <- sdv_find_exe()
  if (is.null(exe)) {
    stop(paste0(
      "StatDataViewer.exe was not found.\n",
      "Point to it with options(sdv.exe = \"C:/path/to/StatDataViewer.exe\")\n",
      "File saved at: ", path), call. = FALSE)
  }
  # The app decodes argv with the local 8-bit code page; short (8.3) paths
  # avoid mangling non-ASCII user or object names.
  short <- tryCatch(getExportedValue("utils", "shortPathName")(path), error = function(e) path)
  system2(exe, shQuote(short), wait = FALSE)
  invisible(TRUE)
}
