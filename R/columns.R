# Column cleaning.
#
# StatDataViewer reads .rds files with librdata,
# which only understands a small subset of R: bare logical / integer / double /
# character vectors, Date and POSIXct stored as double, and a per-column
# "label" attribute. Everything else (factors, list columns, complex, raw,
# integer-stored dates, ALTREP, extra attributes) is either shown wrongly or
# makes the whole file unreadable. The helpers here turn arbitrary data frame
# columns into that subset.

# Date range the viewer can format safely: 0001-01-01 .. 9999-12-31.
.sdv_min_day <- -719162
.sdv_max_day <- 2932896
.sdv_min_sec <- .sdv_min_day * 86400
.sdv_max_sec <- (.sdv_max_day + 1) * 86400 - 1

sdv_utf8 <- function(x) {
  x <- as.character(x)
  if (!length(x)) return(x)
  x <- tryCatch(enc2utf8(x), error = function(e) x)
  bad <- !is.na(x) & !validUTF8(x)
  if (any(bad)) {
    fixed <- iconv(x[bad], from = "latin1", to = "UTF-8")
    fixed[is.na(fixed)] <- iconv(x[bad][is.na(fixed)], from = "", to = "UTF-8", sub = "?")
    x[bad] <- fixed
  }
  x
}

sdv_label_of <- function(x) {
  lab <- attr(x, "label", exact = TRUE)
  if (is.null(lab) || !length(lab)) return(NULL)
  lab <- sdv_utf8(as.character(unname(lab))[1])
  if (is.na(lab) || !nzchar(lab)) NULL else lab
}

# Strip every attribute except the ones the viewer understands.
sdv_bare <- function(v, label = NULL) {
  kind <- if (inherits(v, "Date")) "Date" else if (inherits(v, "POSIXct")) "POSIXct" else ""
  v <- unclass(v)
  attributes(v) <- NULL
  if (is.character(v)) v <- sdv_utf8(v)
  if (kind == "Date") {
    class(v) <- "Date"
  } else if (kind == "POSIXct") {
    class(v) <- c("POSIXct", "POSIXt")
    attr(v, "tzone") <- "UTC"
  }
  if (!is.null(label)) attr(v, "label") <- label
  v
}

sdv_clean_date <- function(x) {
  v <- floor(as.double(unclass(x)))
  v[!is.finite(v) | v < .sdv_min_day | v > .sdv_max_day] <- NA_real_
  structure(v, class = "Date")
}

# The viewer always shows POSIXct in UTC. Shift each instant by its UTC offset
# in the original time zone so the wall-clock time the user sees in R is what
# the viewer shows. Fractional seconds are floored because the viewer truncates.
sdv_clean_posixct <- function(x) {
  if (inherits(x, "POSIXlt")) x <- as.POSIXct(x)
  tz <- attr(x, "tzone", exact = TRUE)
  tz <- if (is.null(tz) || !length(tz) || is.na(tz[1])) "" else tz[1]
  v <- as.double(unclass(x))
  ok <- is.finite(v)
  off <- rep(0, length(v))
  if (any(ok) && !(tz %in% c("UTC", "GMT", "Etc/UTC", "Etc/GMT"))) {
    fl <- floor(v[ok])
    lt <- as.POSIXlt(.POSIXct(fl, tz = tz), tz = tz)
    o <- lt$gmtoff
    if (is.null(o) || anyNA(o)) {
      wall <- format(.POSIXct(fl, tz = tz), "%Y-%m-%d %H:%M:%S", tz = tz)
      o <- as.double(as.POSIXct(wall, tz = "UTC", format = "%Y-%m-%d %H:%M:%S")) - fl
    }
    off[ok] <- as.double(o)
  }
  w <- floor(v + off)
  w[!is.finite(w) | w < .sdv_min_sec | w > .sdv_max_sec] <- NA_real_
  zone <- if (nzchar(tz)) tz else (Sys.timezone() %||% "local")
  label <- if (tz %in% c("UTC", "GMT", "Etc/UTC", "Etc/GMT")) NULL else paste0("Local time (", zone, ")")
  list(value = .POSIXct(w, tz = "UTC"), label = label)
}

sdv_hms_format <- function(x) {
  v <- as.double(unclass(x))
  out <- rep(NA_character_, length(v))
  ok <- is.finite(v)
  a <- abs(v[ok])
  h <- floor(a / 3600)
  m <- floor((a - h * 3600) / 60)
  s <- a - h * 3600 - m * 60
  sec <- ifelse(s == floor(s), sprintf("%02d", as.integer(s)), sprintf("%06.3f", s))
  out[ok] <- paste0(ifelse(v[ok] < 0, "-", ""), sprintf("%02.0f:%02d:", h, as.integer(m)), sec)
  out
}

# integer64 (bit64) stores int64 bits inside a double. Decode them without
# requiring bit64: exact to 2^53, which covers practically all ids and counts.
sdv_int64_to_double <- function(x) {
  n <- length(x)
  if (!n) return(double())
  bytes <- writeBin(as.double(unclass(x)), raw(), size = 8, endian = "little")
  lo <- readBin(bytes[rep(c(TRUE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE), n)],
                "integer", n = n, size = 4, endian = "little")
  hi <- readBin(bytes[rep(c(FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, TRUE, TRUE), n)],
                "integer", n = n, size = 4, endian = "little")
  lo_u <- ifelse(is.na(lo), 2^31, ifelse(lo < 0, lo + 2^32, lo))
  hi_d <- ifelse(is.na(hi), -2^31, hi)
  out <- hi_d * 2^32 + lo_u
  out[is.na(hi) & !is.na(lo) & lo == 0L] <- NA_real_   # INT64_MIN is NA_integer64_
  out
}

sdv_clean_int64 <- function(x) {
  d <- sdv_int64_to_double(x)
  if (all(is.na(d) | abs(d) <= 2^53)) return(d)
  if (requireNamespace("bit64", quietly = TRUE)) return(as.character(x))
  warning("integer64 values beyond 2^53 were rounded; install 'bit64' for exact values.",
          call. = FALSE)
  format(d, scientific = FALSE, trim = TRUE)
}

sdv_type_abbrev <- function(v) {
  if (is.object(v)) return(class(v)[1])
  switch(typeof(v), logical = "lgl", integer = "int", double = "dbl",
         character = "chr", complex = "cpl", raw = "raw", list = "list",
         typeof(v))
}

sdv_truncate <- function(s, width = 200L) {
  s <- sdv_utf8(s)
  long <- !is.na(s) & nchar(s, type = "chars", allowNA = TRUE) > width
  long[is.na(long)] <- FALSE
  if (any(long)) s[long] <- paste0(substr(s[long], 1L, width - 1L), "\u2026")
  s
}

# One-line summary of an arbitrary R value (used for list cells and list trees).
sdv_preview <- function(v, width = 200L) {
  out <- tryCatch({
    if (is.null(v)) {
      "NULL"
    } else if (is.data.frame(v)) {
      sprintf("<data.frame [%d x %d]>", nrow(v), length(v))
    } else if (is.environment(v)) {
      sprintf("<%s>", if (is.object(v)) class(v)[1] else "environment")
    } else if (is.function(v)) {
      "<function>"
    } else if (isS4(v)) {
      sprintf("<S4 %s>", class(v)[1])
    } else if ((is.atomic(v) || inherits(v, "POSIXlt")) && is.null(dim(v)) &&
               length(v) <= 10L && !inherits(v, "integer64")) {
      s <- if (is.factor(v)) as.character(v) else if (is.character(v)) v else format(v, trim = TRUE)
      s[is.na(s)] <- "NA"
      if (!length(s)) sprintf("<%s [0]>", sdv_type_abbrev(v)) else paste(s, collapse = ", ")
    } else {
      size <- if (!is.null(dim(v))) paste(dim(v), collapse = " x ") else length(v)
      sprintf("<%s [%s]>", sdv_type_abbrev(v), size)
    }
  }, error = function(e) sprintf("<%s>", class(v)[1]))
  sdv_truncate(paste(out, collapse = " "), width)
}

sdv_list_column <- function(x) {
  if (is.object(x)) {
    f <- tryCatch(format(x), error = function(e) NULL)
    if (is.character(f) && length(f) == length(x)) {
      miss <- tryCatch(is.na(x), error = function(e) rep(FALSE, length(x)))
      if (length(miss) == length(x)) f[miss] <- NA_character_
      return(sdv_truncate(f))
    }
  }
  vapply(unclass(x), function(el) {
    if (is.null(el)) return(NA_character_)
    if (is.atomic(el) && length(el) == 1L && is.na(el) && !is.object(el)) return(NA_character_)
    sdv_preview(el)
  }, character(1), USE.NAMES = FALSE)
}

# Convert one vector (no data-frame / matrix structure) to a clean vector.
sdv_clean_vec <- function(x) {
  lab <- sdv_label_of(x)
  # I() only protects columns from data.frame(); format.AsIs would deparse them.
  if (inherits(x, "AsIs")) {
    cls <- setdiff(oldClass(x), "AsIs")
    oldClass(x) <- if (length(cls)) cls else NULL
  }
  if (inherits(x, "POSIXt")) {
    res <- sdv_clean_posixct(x)
    return(sdv_bare(res$value, lab %||% res$label))
  }
  if (inherits(x, "Date")) return(sdv_bare(sdv_clean_date(x), lab))
  if (inherits(x, "hms")) return(sdv_bare(sdv_hms_format(x), lab))
  if (inherits(x, "difftime")) {
    unit <- attr(x, "units", exact = TRUE) %||% ""
    lab <- if (is.null(lab)) sprintf("[%s]", unit) else sprintf("%s [%s]", lab, unit)
    return(sdv_bare(as.double(unclass(x)), lab))
  }
  if (inherits(x, "integer64")) return(sdv_bare(sdv_clean_int64(x), lab))
  if (is.factor(x)) return(sdv_bare(as.character(x), lab))
  if (is.list(x)) return(sdv_bare(sdv_list_column(x), lab))
  if (is.complex(x)) {
    f <- format(x, trim = TRUE)
    f[is.na(x)] <- NA_character_
    return(sdv_bare(f, lab))
  }
  if (is.raw(x)) return(sdv_bare(as.character(x), lab))
  # Other classed logical / integer / double / character vectors keep their data.
  if (typeof(x) %in% c("logical", "integer", "double", "character")) return(sdv_bare(x, lab))
  # Anything else that slipped into a column (symbols, calls, ...).
  sdv_bare(vapply(as.list(x), sdv_preview, character(1)), lab)
}

# Clean one data-frame column. Returns a named list because data-frame and
# matrix columns expand into several columns, and labelled vectors add a
# companion column with the value labels.
sdv_clean_col <- function(x, name, n) {
  if (is.data.frame(x)) {
    sub <- sdv_df_columns(x)
    if (!length(sub)) return(list())
    names(sub) <- paste(name, names(sub), sep = ".")
    return(sub)
  }
  d <- dim(x)
  if (!is.null(d) && length(d) >= 2L) {
    lab <- sdv_label_of(x)
    m <- if (length(d) == 2L) x else array(x, dim = c(d[1], prod(d[-1])))
    cn <- if (length(d) == 2L) colnames(m) else NULL
    if (is.null(cn)) cn <- as.character(seq_len(ncol(m)))
    cols <- lapply(seq_len(ncol(m)), function(j) {
      v <- m[, j, drop = TRUE]
      if (!is.null(lab) && is.null(attr(v, "label", exact = TRUE))) attr(v, "label") <- lab
      sdv_clean_vec(v)
    })
    names(cols) <- paste(name, cn, sep = ".")
    return(cols)
  }
  if (inherits(x, c("haven_labelled", "labelled")) && !is.null(attr(x, "labels", exact = TRUE))) {
    labels <- attr(x, "labels", exact = TRUE)
    codes <- unclass(x)
    txt <- names(labels)[match(codes, unclass(labels))]
    lab <- sdv_label_of(x)
    attributes(codes) <- NULL
    out <- list(sdv_bare(codes, lab), sdv_bare(as.character(txt), if (!is.null(lab)) paste(lab, "(value label)")))
    names(out) <- c(name, paste0(name, "_lbl"))
    return(out)
  }
  out <- list(sdv_clean_vec(x))
  names(out) <- name
  out
}

sdv_unique_names <- function(nms) {
  nms <- sdv_utf8(nms)
  blank <- is.na(nms) | !nzchar(trimws(nms))
  nms[blank] <- paste0("V", which(blank))
  seen <- character()
  for (i in seq_along(nms)) {
    cand <- nms[i]
    k <- 1L
    while (tolower(cand) %in% seen) {
      k <- k + 1L
      cand <- paste0(nms[i], "_", k)
    }
    nms[i] <- cand
    seen <- c(seen, tolower(cand))
  }
  nms
}

sdv_make_df <- function(cols, n) {
  names(cols) <- sdv_unique_names(names(cols) %||% rep("", length(cols)))
  structure(cols, class = "data.frame", row.names = .set_row_names(as.integer(n)))
}

sdv_has_real_rownames <- function(x) {
  is.data.frame(x) && .row_names_info(x, type = 1L) > 0L
}

sdv_rownames_col <- function(rn) {
  if (length(rn) && all(grepl("^-?[0-9]{1,9}$", rn))) return(as.integer(rn))
  sdv_utf8(rn)
}

# Cleaned columns of a data frame, as a named list.
sdv_df_columns <- function(x) {
  n <- .row_names_info(x, type = 2L)
  xs <- unclass(x)
  nms <- names(xs) %||% rep("", length(xs))
  vlab <- attr(x, "variable.labels", exact = TRUE)
  cols <- list()
  for (j in seq_along(xs)) {
    col <- xs[[j]]
    if (!is.null(vlab) && is.null(attr(col, "label", exact = TRUE))) {
      vl <- if (!is.null(names(vlab)) && nms[j] %in% names(vlab)) vlab[[nms[j]]] else if (j <= length(vlab)) vlab[[j]] else NULL
      if (!is.null(vl) && !is.na(vl) && nzchar(vl)) attr(col, "label") <- vl
    }
    nm <- if (is.na(nms[j]) || !nzchar(nms[j])) paste0("V", j) else nms[j]
    cols <- c(cols, sdv_clean_col(col, nm, n))
  }
  cols
}

#' Clean a data frame for StatDataViewer
#'
#' Rebuilds `x` as a plain data frame whose columns only use types the viewer's
#' R reader understands. Non-automatic row names become a leading `row_names`
#' column.
#' @param x A data frame.
#' @param row_names Keep non-automatic row names as a column.
#' @return A plain `data.frame`.
#' @export
sdv_clean_df <- function(x, row_names = TRUE) {
  n <- .row_names_info(x, type = 2L)
  cols <- sdv_df_columns(x)
  if (row_names && sdv_has_real_rownames(x)) {
    cols <- c(list(row_names = sdv_rownames_col(row.names(x))), cols)
  }
  sdv_make_df(cols, n)
}

#' Check that a data frame is safe for StatDataViewer's R reader
#'
#' @param df A data frame.
#' @return `TRUE`, or `FALSE` with a `"problems"` attribute describing why.
#' @export
sdv_is_clean <- function(df) {
  p <- character()
  if (!identical(class(df), "data.frame")) p <- c(p, "class is not exactly 'data.frame'")
  extra <- setdiff(names(attributes(df)), c("names", "class", "row.names"))
  if (length(extra)) p <- c(p, paste("extra data frame attributes:", paste(extra, collapse = ", ")))
  n <- .row_names_info(df, type = 2L)
  nms <- names(df)
  if (is.null(nms) || anyNA(nms) || any(!nzchar(nms))) p <- c(p, "empty column names")
  if (!is.null(nms) && anyDuplicated(tolower(nms))) p <- c(p, "column names not unique (case-insensitive)")
  if (!is.null(nms) && !all(validUTF8(nms))) p <- c(p, "column names not valid UTF-8")
  for (j in seq_along(df)) {
    v <- unclass(df)[[j]]
    nm <- if (!is.null(nms)) nms[j] else j
    if (!typeof(v) %in% c("logical", "integer", "double", "character")) {
      p <- c(p, sprintf("column '%s' has type %s", nm, typeof(v)))
      next
    }
    if (length(v) != n) p <- c(p, sprintf("column '%s' has length %d, expected %d", nm, length(v), n))
    a <- attributes(v)
    bad <- setdiff(names(a), c("class", "tzone", "label"))
    if (length(bad)) p <- c(p, sprintf("column '%s' has attributes %s", nm, paste(bad, collapse = ", ")))
    cls <- a$class
    if (!is.null(cls)) {
      if (identical(cls, "Date")) {
        if (!is.double(v)) p <- c(p, sprintf("Date column '%s' is not stored as double", nm))
      } else if (identical(cls, c("POSIXct", "POSIXt"))) {
        if (!is.double(v)) p <- c(p, sprintf("POSIXct column '%s' is not stored as double", nm))
        if (!identical(a$tzone, "UTC")) p <- c(p, sprintf("POSIXct column '%s' tzone is not UTC", nm))
      } else {
        p <- c(p, sprintf("column '%s' has class %s", nm, paste(cls, collapse = "/")))
      }
    } else if (!is.null(a$tzone)) {
      p <- c(p, sprintf("column '%s' has a tzone without POSIXct class", nm))
    }
    if (!is.null(a$label) && !(is.character(a$label) && length(a$label) == 1L)) {
      p <- c(p, sprintf("column '%s' label is not a single string", nm))
    }
    if (is.character(v) && !all(validUTF8(v[!is.na(v)]))) {
      p <- c(p, sprintf("column '%s' has invalid UTF-8", nm))
    }
  }
  if (length(p)) structure(FALSE, problems = p) else TRUE
}
