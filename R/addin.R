# RStudio addin entry points (see inst/rstudio/addins.dcf).

.sdv_reserved <- c("if", "else", "repeat", "while", "function", "for", "next", "break",
                   "in", "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "NA_integer_",
                   "NA_real_", "NA_character_", "NA_complex_", "T", "F")

.sdv_id_re <- "(?:`(?:[^`\\\\]|\\\\.)+`|(?:\\p{L}|[.](?![0-9]))[\\p{L}\\p{N}._]*)"
.sdv_sep_re <- "(?:\\$|@|:::|::)"
# The look-behind stops "e5" in "1e5" or "b" in "a.b" from matching on their own.
.sdv_chain_re <- paste0("(?<![\\p{L}\\p{N}._])", .sdv_id_re, "(?:", .sdv_sep_re, .sdv_id_re, ")*")

#' Find the R object reference under the cursor
#'
#' Returns the identifier chain (`df`, `df$col`, `obj@slot`, `pkg::obj`,
#' `` `odd name` ``) touching the cursor, cut after the segment the cursor is
#' on: with the cursor on `df` in `df$col` the result is `df`.
#' @param line Text of the line.
#' @param col 1-based column of the cursor as reported by rstudioapi (the
#'   cursor sits just before character `col`).
#' @return A string, or `NA` when no object reference is under the cursor.
#' @keywords internal
sdv_token_at <- function(line, col) {
  if (is.null(line) || is.na(line) || !nzchar(line)) return(NA_character_)
  m <- gregexpr(.sdv_chain_re, line, perl = TRUE)[[1]]
  if (m[1] == -1L) return(NA_character_)
  starts <- as.integer(m)
  ends <- starts + attr(m, "match.length") - 1L
  inside <- which(starts <= col & col <= ends)
  after <- which(ends == col - 1L)
  hit <- c(inside, after)
  if (!length(hit)) return(NA_character_)
  k <- hit[1]
  chain <- substr(line, starts[k], ends[k])
  # Cut the chain after the segment the cursor is on (but keep pkg::obj together).
  seg <- gregexpr(.sdv_id_re, chain, perl = TRUE)[[1]]
  seg_start <- as.integer(seg) + starts[k] - 1L
  seg_end <- seg_start + attr(seg, "match.length") - 1L
  j <- max(which(seg_start <= max(col, starts[k])))
  while (j < length(seg_start)) {
    between <- substr(line, seg_end[j] + 1L, seg_start[j + 1L] - 1L)
    if (!between %in% c("::", ":::")) break
    j <- j + 1L
  }
  tok <- substr(line, starts[k], seg_end[j])
  first <- substr(line, seg_start[1], seg_end[1])
  if (first %in% .sdv_reserved && tok == first) return(NA_character_)
  tok
}

sdv_eval_text <- function(text, envir = globalenv()) {
  exprs <- parse(text = text, keep.source = FALSE)
  if (!length(exprs)) stop("nothing to evaluate", call. = FALSE)
  val <- NULL
  for (e in exprs) val <- eval(e, envir)
  val
}

sdv_name_from_text <- function(text) {
  text <- trimws(text)
  if (grepl(paste0("^", .sdv_chain_re, "$"), text, perl = TRUE)) return(text)
  if (!grepl("\n", text, fixed = TRUE) && nchar(text) <= 40L) return(text)
  "selection"
}

sdv_require_rstudio <- function() {
  if (!rstudioapi::isAvailable()) {
    stop("This addin must be run from RStudio. Use sdv_view(x) elsewhere.", call. = FALSE)
  }
}

sdv_show_error <- function(msg) {
  if (rstudioapi::isAvailable()) {
    tryCatch(rstudioapi::showDialog("StatDataViewer", msg), error = function(e) message(msg))
  } else {
    message(msg)
  }
  invisible(NULL)
}

# Evaluate `text` in the global environment and send the result.
sdv_send_text <- function(text, prompt_on_error = TRUE) {
  .sdv_state$last_expr <- text
  val <- tryCatch(sdv_eval_text(text), error = function(e) e)
  if (inherits(val, "error")) {
    if (prompt_on_error) {
      return(sdv_addin_prompt(default = text, error = conditionMessage(val)))
    }
    return(sdv_show_error(conditionMessage(val)))
  }
  res <- tryCatch(sdv_view(val, name = sdv_name_from_text(text)), error = function(e) e)
  if (inherits(res, "error")) return(sdv_show_error(conditionMessage(res)))
  invisible(res)
}

#' Addin: open the selection or the object under the cursor
#'
#' With a selection in the editor or console, the selected code is evaluated
#' in the global environment and the result is sent to StatDataViewer.
#' Without a selection, the object name under the cursor is used. If there is
#' nothing usable, a prompt asks for a name or expression.
#' @export
sdv_addin_view <- function() {
  sdv_require_rstudio()
  ctx <- rstudioapi::getActiveDocumentContext()
  sel <- ctx$selection[[1]]
  text <- trimws(sel$text %||% "")
  if (nzchar(text)) return(sdv_send_text(text))
  pos <- sel$range$start
  row <- pos[[1]]
  col <- pos[[2]]
  line <- if (row >= 1 && row <= length(ctx$contents)) ctx$contents[[row]] else ""
  tok <- sdv_token_at(line, col)
  if (is.na(tok)) return(sdv_addin_prompt())
  sdv_send_text(tok)
}

#' Addin: type an object name or expression to open in StatDataViewer
#'
#' @param default Text pre-filled in the prompt.
#' @param error Optional error message shown above the prompt.
#' @export
sdv_addin_prompt <- function(default = NULL, error = NULL) {
  sdv_require_rstudio()
  msg <- "Object name or R expression:"
  if (!is.null(error)) msg <- paste0("Error: ", error, "\n\n", msg)
  ans <- rstudioapi::showPrompt("Open in StatDataViewer", msg,
                                default = default %||% .sdv_state$last_expr)
  if (is.null(ans) || !nzchar(trimws(ans))) return(invisible(NULL))
  sdv_send_text(trimws(ans))
}
