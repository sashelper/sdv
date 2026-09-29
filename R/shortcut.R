# Keyboard shortcut installation.
#
# RStudio keeps user-assigned addin shortcuts in a flat JSON object,
# <config>/keybindings/addins.json, e.g.
#   {"sdv::sdv_addin_view": "Cmd+Shift+V"}
# where <config> is $RSTUDIO_CONFIG_HOME, else $XDG_CONFIG_HOME/rstudio or
# ~/.config/rstudio (%APPDATA%/RStudio on Windows). RStudio reads it at startup.

# Cmd+Shift+V on macOS, Ctrl+Shift+V elsewhere: neither RStudio's commands nor
# its Ace editor bind it, and V is easy to remember (View).
sdv_default_key <- function() {
  if (identical(Sys.info()[["sysname"]], "Darwin")) "Cmd+Shift+V" else "Ctrl+Shift+V"
}

#' Path of RStudio's addin keybinding file
#' @return File path (may not exist yet).
#' @export
sdv_keybindings_path <- function() {
  base <- Sys.getenv("RSTUDIO_CONFIG_HOME", "")
  if (!nzchar(base)) {
    if (.Platform$OS.type == "windows") {
      base <- file.path(Sys.getenv("APPDATA", ""), "RStudio")
    } else {
      xdg <- Sys.getenv("XDG_CONFIG_HOME", "")
      if (!nzchar(xdg)) xdg <- "~/.config"
      base <- file.path(xdg, "rstudio")
    }
  }
  file.path(path.expand(base), "keybindings", "addins.json")
}

sdv_json_unescape <- function(s) {
  vapply(s, function(x) {
    if (!grepl("\\", x, fixed = TRUE)) return(x)
    chars <- strsplit(x, "", fixed = TRUE)[[1]]
    out <- character()
    i <- 1L
    while (i <= length(chars)) {
      ch <- chars[i]
      if (ch == "\\" && i < length(chars)) {
        nx <- chars[i + 1L]
        if (nx == "u" && i + 5L <= length(chars)) {
          out <- c(out, intToUtf8(strtoi(paste(chars[(i + 2L):(i + 5L)], collapse = ""), 16L)))
          i <- i + 6L
          next
        }
        out <- c(out, switch(nx, n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", nx))
        i <- i + 2L
        next
      }
      out <- c(out, ch)
      i <- i + 1L
    }
    paste(out, collapse = "")
  }, character(1), USE.NAMES = FALSE)
}

sdv_json_escape <- function(s) {
  s <- gsub("\\", "\\\\", s, fixed = TRUE)
  s <- gsub("\"", "\\\"", s, fixed = TRUE)
  s <- gsub("\n", "\\n", s, fixed = TRUE)
  s <- gsub("\t", "\\t", s, fixed = TRUE)
  gsub("\r", "\\r", s, fixed = TRUE)
}

# Read a JSON object whose values are all strings. Returns a named character
# vector; errors on anything else so we never clobber a file we don't understand.
sdv_read_flat_json <- function(path) {
  if (!file.exists(path)) return(stats::setNames(character(), character()))
  txt <- trimws(paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
  if (!nzchar(txt)) return(stats::setNames(character(), character()))
  if (!grepl("^\\{.*\\}$", txt)) stop("Not a JSON object: ", path, call. = FALSE)
  inner <- trimws(substr(txt, 2L, nchar(txt) - 1L))
  if (!nzchar(inner)) return(stats::setNames(character(), character()))
  str <- "\"((?:[^\"\\\\]|\\\\.)*)\""
  pair <- paste0(str, "\\s*:\\s*", str)
  full <- paste0("^\\s*", pair, "\\s*(?:,\\s*", pair, "\\s*)*$")
  if (!grepl(full, inner, perl = TRUE)) {
    stop("Unsupported keybinding file format (expected string values only): ", path,
         call. = FALSE)
  }
  m <- regmatches(inner, gregexpr(pair, inner, perl = TRUE))[[1]]
  keys <- sdv_json_unescape(sub(paste0("^", pair, "$"), "\\1", m, perl = TRUE))
  vals <- sdv_json_unescape(sub(paste0("^", pair, "$"), "\\2", m, perl = TRUE))
  stats::setNames(vals, keys)
}

sdv_write_flat_json <- function(x, path) {
  body <- if (length(x)) {
    paste0("    \"", sdv_json_escape(names(x)), "\": \"", sdv_json_escape(unname(x)), "\"",
           collapse = ",\n")
  } else ""
  txt <- if (nzchar(body)) paste0("{\n", body, "\n}") else "{\n}"
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(path, ".tmp")
  writeLines(enc2utf8(txt), tmp, useBytes = TRUE)
  if (!file.rename(tmp, path)) {
    unlink(tmp)
    stop("Could not write ", path, call. = FALSE)
  }
  invisible(path)
}

#' Normalize a shortcut string to RStudio's spelling
#' @param key e.g. `"ctrl+alt+shift+v"`, `"Cmd+Shift+D"`.
#' @return Canonical form such as `"Ctrl+Alt+Shift+V"`.
#' @keywords internal
sdv_normalize_key <- function(key) {
  parts <- trimws(strsplit(key, "+", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts)]
  if (!length(parts)) stop("Empty shortcut.", call. = FALSE)
  mods <- tolower(parts[-length(parts)])
  k <- parts[length(parts)]
  canon <- c(ctrl = "Ctrl", control = "Ctrl", alt = "Alt", option = "Alt", opt = "Alt",
             shift = "Shift", cmd = "Cmd", command = "Cmd", meta = "Cmd")
  unknown <- setdiff(mods, names(canon))
  if (length(unknown)) stop("Unknown modifier: ", paste(unknown, collapse = ", "), call. = FALSE)
  mods <- unique(canon[mods])
  mods <- mods[order(match(mods, c("Ctrl", "Alt", "Shift", "Cmd")))]
  if (nchar(k) == 1L) k <- toupper(k)
  paste(c(mods, k), collapse = "+")
}

sdv_binding_id <- function(binding) paste0("sdv::", binding)

#' Assign a keyboard shortcut to a StatDataViewer addin
#'
#' Writes RStudio's `keybindings/addins.json` (backing up the previous file to
#' `addins.json.bak`). Restart RStudio afterwards. The default
#' Cmd+Shift+V (Ctrl+Shift+V on Windows/Linux) is not used by RStudio's
#' built-in shortcuts.
#' @param key Shortcut, e.g. `"Cmd+Shift+V"` or `"Ctrl+Alt+Shift+V"`.
#' @param binding `"sdv_addin_view"` or `"sdv_addin_prompt"`.
#' @param overwrite Take the key even if another addin already uses it.
#' @return Path of the keybinding file, invisibly.
#' @export
sdv_install_shortcut <- function(key = sdv_default_key(),
                                 binding = c("sdv_addin_view", "sdv_addin_prompt"),
                                 overwrite = FALSE) {
  binding <- match.arg(binding)
  key <- sdv_normalize_key(key)
  path <- sdv_keybindings_path()
  current <- sdv_read_flat_json(path)
  id <- sdv_binding_id(binding)
  if (identical(unname(current[id]), key)) {
    message(sprintf("%s is already bound to %s.", key, id))
    return(invisible(path))
  }
  norm <- vapply(current, function(k) tryCatch(sdv_normalize_key(k), error = function(e) k),
                 character(1))
  clash <- setdiff(names(current)[norm == key], id)
  if (length(clash) && !overwrite) {
    stop(sprintf("%s is already used by %s. Choose another key or use overwrite = TRUE.",
                 key, paste(clash, collapse = ", ")), call. = FALSE)
  }
  others <- file.path(dirname(path), c("rstudio_bindings.json", "editor_bindings.json"))
  for (f in others[file.exists(others)]) {
    b <- tryCatch(sdv_read_flat_json(f), error = function(e) character())
    hit <- names(b)[vapply(b, function(k) tryCatch(sdv_normalize_key(k) == key,
                                                   error = function(e) FALSE), logical(1))]
    if (length(hit)) {
      warning(sprintf("%s is also assigned to RStudio command(s) %s in %s.",
                      key, paste(hit, collapse = ", "), basename(f)), call. = FALSE)
    }
  }
  if (file.exists(path)) file.copy(path, paste0(path, ".bak"), overwrite = TRUE)
  updated <- current[setdiff(names(current), clash)]
  updated[id] <- key
  sdv_write_flat_json(updated, path)
  message(sprintf("Bound %s to %s in %s.\nRestart RStudio for the shortcut to take effect.",
                  key, id, path))
  invisible(path)
}

#' Remove a StatDataViewer addin shortcut
#' @inheritParams sdv_install_shortcut
#' @export
sdv_remove_shortcut <- function(binding = c("sdv_addin_view", "sdv_addin_prompt")) {
  binding <- match.arg(binding)
  path <- sdv_keybindings_path()
  current <- sdv_read_flat_json(path)
  id <- sdv_binding_id(binding)
  if (!id %in% names(current)) {
    message("No shortcut is assigned to ", id, ".")
    return(invisible(path))
  }
  file.copy(path, paste0(path, ".bak"), overwrite = TRUE)
  sdv_write_flat_json(current[setdiff(names(current), id)], path)
  message("Removed the shortcut for ", id, ". Restart RStudio for it to take effect.")
  invisible(path)
}
