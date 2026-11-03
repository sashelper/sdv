# Object-level conversion: decide how an arbitrary R object is shown in
# StatDataViewer -- as a table (.rds) or as a text document (.txt / .R).

sdv_table <- function(df, name) {
  structure(list(kind = "table", data = df, name = name), class = "sdv_payload")
}

sdv_text <- function(lines, name, ext = "txt") {
  structure(list(kind = "text", data = sdv_utf8(lines), name = name, ext = ext),
            class = "sdv_payload")
}

# Accept what a sdv_prepare() method returns: a payload, a data frame (cleaned
# here) or a character vector of text lines.
sdv_as_payload <- function(res, name) {
  if (is.null(res) || inherits(res, "sdv_payload")) return(res)
  if (is.data.frame(res)) return(sdv_table(sdv_clean_df(res), name))
  if (is.character(res)) return(sdv_text(res, name))
  stop("sdv_prepare() methods must return a data frame, a character vector or NULL.")
}

#' Convert an R object for display in StatDataViewer
#'
#' Generic used by [sdv_view()]. Methods may return a data frame (shown as a
#' table), a character vector (shown as text) or `NULL` (nothing to show).
#' The default method handles data frames, matrices, arrays, tables, time
#' series, vectors, lists, environments, functions, models and any other object.
#' @param x Object to convert.
#' @param name Display name.
#' @param ... Unused.
#' @export
sdv_prepare <- function(x, name = "object", ...) UseMethod("sdv_prepare")

#' @export
sdv_prepare.default <- function(x, name = "object", ...) {
  if (is.null(x)) return(NULL)
  if (is.data.frame(x)) return(sdv_table(sdv_clean_df(x), name))
  if (inherits(x, c("zoo", "xts"))) {
    res <- sdv_prepare_zoo(x)
    if (!is.null(res)) return(sdv_table(res, name))
  }
  if (stats::is.ts(x)) return(sdv_table(sdv_prepare_ts(x), name))
  if (inherits(x, "table")) return(sdv_table(sdv_prepare_table(x), name))
  if (inherits(x, "POSIXlt")) x <- as.POSIXct(x)
  if (is.atomic(x) && !isS4(x)) {
    d <- dim(x)
    if (length(d) == 2L) return(sdv_table(sdv_prepare_matrix(x), name))
    if (length(d) >= 3L) return(sdv_table(sdv_prepare_array(x), name))
    if (!length(x)) return(NULL)
    return(sdv_table(sdv_prepare_vector(x), name))
  }
  if (is.list(x) && length(dim(x)) == 2L && !is.object(x)) {
    return(sdv_table(sdv_prepare_matrix(x), name))
  }
  if (is.object(x) && !isS4(x) && sdv_has_df_method(x)) {
    df <- tryCatch(as.data.frame(x), error = function(e) NULL)
    if (is.data.frame(df)) return(sdv_table(sdv_clean_df(df), name))
  }
  if (is.function(x)) return(sdv_text(sdv_function_lines(x, name), name, "R"))
  if (is.language(x) || inherits(x, "formula")) {
    return(sdv_text(deparse(x, width.cutoff = 80L), name, "R"))
  }
  if (inherits(x, c("lm", "glm"))) {
    return(sdv_text(sdv_capture(print(summary(x))), name))
  }
  if (is.list(x) && !is.object(x)) {
    if (!length(x)) return(NULL)
    df <- sdv_list_as_df(x)
    if (!is.null(df)) return(sdv_table(df, name))
    return(sdv_table(sdv_flatten_list(x, name), name))
  }
  if (is.environment(x) && !is.object(x)) return(sdv_table(sdv_env_table(x), name))
  sdv_text(sdv_describe(x), name)
}

# ---- tabular helpers --------------------------------------------------------

sdv_prepare_vector <- function(x) {
  nms <- names(x)
  names(x) <- NULL
  cols <- if (!is.null(nms)) list(name = sdv_utf8(nms), value = x) else list(value = x)
  n <- length(x)
  sdv_make_df(unlist(lapply(names(cols), function(nm) sdv_clean_col(cols[[nm]], nm, n)),
                     recursive = FALSE), n)
}

sdv_prepare_matrix <- function(m) {
  n <- nrow(m)
  cn <- colnames(m)
  if (is.null(cn)) cn <- paste0("V", seq_len(ncol(m)))
  cols <- lapply(seq_len(ncol(m)), function(j) sdv_clean_vec(m[, j, drop = TRUE]))
  names(cols) <- cn
  rn <- rownames(m)
  if (!is.null(rn)) cols <- c(list(row_names = sdv_rownames_col(rn)), cols)
  sdv_make_df(cols, n)
}

sdv_prepare_array <- function(a) {
  tab <- as.data.frame.table(as.table(a), responseName = "value", stringsAsFactors = FALSE)
  sdv_clean_df(tab)
}

sdv_prepare_table <- function(x) {
  d <- dim(x)
  dn <- dimnames(x)
  dnn <- names(dn)
  if (length(d) == 1L) {
    lev <- dn[[1]] %||% as.character(seq_len(d[1]))
    first <- if (!is.null(dnn) && nzchar(dnn[1])) dnn[1] else "level"
    cols <- list(lev, as.vector(unclass(x)))
    names(cols) <- c(first, "Freq")
    return(sdv_make_df(lapply(cols, sdv_clean_vec), d[1]))
  }
  if (length(d) == 2L) {
    m <- unclass(x)
    rows <- dn[[1]] %||% as.character(seq_len(d[1]))
    cn <- dn[[2]] %||% as.character(seq_len(d[2]))
    first <- if (!is.null(dnn) && nzchar(dnn[1])) dnn[1] else "row"
    cols <- c(list(rows), lapply(seq_len(d[2]), function(j) as.vector(m[, j])))
    names(cols) <- c(first, cn)
    return(sdv_make_df(lapply(cols, sdv_clean_vec), d[1]))
  }
  sdv_clean_df(as.data.frame.table(x, responseName = "Freq", stringsAsFactors = FALSE))
}

sdv_prepare_ts <- function(x) {
  tt <- as.numeric(stats::time(x))
  cyc <- as.integer(stats::cycle(x))
  core <- unclass(x)
  attr(core, "tsp") <- NULL
  cols <- list(time = tt, cycle = cyc)
  if (is.matrix(core)) {
    cn <- colnames(core) %||% paste0("Series", seq_len(ncol(core)))
    for (j in seq_len(ncol(core))) cols[[cn[j]]] <- as.vector(core[, j])
  } else {
    cols$value <- as.vector(core)
  }
  sdv_make_df(lapply(cols, sdv_clean_vec), length(tt))
}

sdv_prepare_zoo <- function(x) {
  if (!requireNamespace("zoo", quietly = TRUE)) return(NULL)
  if (inherits(x, "xts")) requireNamespace("xts", quietly = TRUE)
  idx <- getExportedValue("zoo", "index")(x)
  core <- getExportedValue("zoo", "coredata")(x)
  n <- length(idx)
  cols <- list(index = idx)
  if (is.null(dim(core))) {
    cols$value <- core
  } else {
    cn <- colnames(core) %||% paste0("V", seq_len(ncol(core)))
    for (j in seq_len(ncol(core))) cols[[cn[j]]] <- core[, j]
  }
  sdv_make_df(lapply(cols, sdv_clean_vec), n)
}

# Classed objects with their own as.data.frame() method (tibble-like objects,
# numeric_version, ...). Lazy remote tables are skipped: converting them would
# pull the whole remote table.
sdv_has_df_method <- function(x) {
  cls <- class(x)
  if (any(cls %in% c("tbl_lazy", "tbl_sql"))) return(FALSE)
  for (cl in cls) {
    if (!is.null(utils::getS3method("as.data.frame", cl, optional = TRUE))) return(TRUE)
  }
  FALSE
}

# Plain list whose elements are atomic vectors of the same length -> data frame.
sdv_list_as_df <- function(x) {
  ok <- vapply(x, function(el) (is.atomic(el) || inherits(el, "POSIXlt")) &&
                 is.null(dim(el)) && !is.null(el), logical(1))
  if (!all(ok)) return(NULL)
  lens <- vapply(x, length, integer(1))
  if (length(unique(lens)) != 1L || lens[1] == 0L) return(NULL)
  n <- lens[1]
  nms <- names(x) %||% rep("", length(x))
  nms[is.na(nms) | !nzchar(nms)] <- paste0("V", which(is.na(nms) | !nzchar(nms)))
  cols <- unlist(lapply(seq_along(x), function(j) sdv_clean_col(x[[j]], nms[j], n)), recursive = FALSE)
  sdv_make_df(cols, n)
}

# Nested list -> one row per node: path, class, type, length/dim, preview.
sdv_flatten_list <- function(x, name = "x", max_depth = 6L,
                             max_rows = sdv_opt("list_max_rows", 10000L)) {
  st <- new.env(parent = emptyenv())
  st$n <- 0L
  st$truncated <- FALSE
  st$path <- st$class <- st$type <- st$size <- st$preview <- character(max_rows)
  st$depth <- integer(max_rows)
  syntactic <- function(s) grepl("^((([[:alpha:]]|[.][._[:alpha:]])[._[:alnum:]]*)|[.])$", s)
  walk <- function(obj, path, depth) {
    if (st$n >= max_rows) {
      st$truncated <- TRUE
      return(invisible())
    }
    i <- st$n <- st$n + 1L
    st$path[i] <- path
    st$class[i] <- paste(class(obj), collapse = "/")
    st$type[i] <- typeof(obj)
    st$size[i] <- if (!is.null(dim(obj)) && !is.data.frame(obj)) paste(dim(obj), collapse = " x ")
                  else if (is.data.frame(obj)) sprintf("%d x %d", nrow(obj), length(obj))
                  else as.character(length(obj))
    st$depth[i] <- depth
    recurse <- is.list(obj) && !is.data.frame(obj) && depth < max_depth
    st$preview[i] <- if (recurse && length(obj)) "" else sdv_preview(obj)
    if (recurse) {
      nms <- names(obj)
      for (k in seq_along(obj)) {
        nm <- if (!is.null(nms)) nms[k] else ""
        seg <- if (!is.na(nm) && nzchar(nm)) {
          if (syntactic(nm)) paste0("$", nm) else paste0("$`", nm, "`")
        } else {
          paste0("[[", k, "]]")
        }
        walk(obj[[k]], paste0(path, seg), depth + 1L)
      }
    }
  }
  walk(x, name, 0L)
  n <- st$n
  cols <- list(path = st$path[seq_len(n)], depth = st$depth[seq_len(n)],
               class = st$class[seq_len(n)], type = st$type[seq_len(n)],
               size = st$size[seq_len(n)], preview = st$preview[seq_len(n)])
  if (st$truncated) {
    warning(sprintf("List has more than %d nodes; only the first %d are shown.", max_rows, max_rows),
            call. = FALSE)
  }
  sdv_make_df(lapply(cols, sdv_bare), n)
}

# Environment -> inventory table like RStudio's Environment pane: one row per
# object with the pane's category (Data / Values / Functions), class,
# dimensions, size and the first line of str() as a one-line description.
sdv_env_table <- function(e) {
  recs <- sdv_env_records(e)
  col <- function(f, fv) vapply(recs, function(r) r[[f]], fv)
  cols <- list(name = col("name", character(1)),
               kind = col("kind", character(1)),
               class = col("class", character(1)),
               dim = col("dim", character(1)),
               size = col("size", character(1)),
               value = col("value", character(1)),
               type = col("type", character(1)),
               size_bytes = col("size_bytes", double(1)))
  sdv_make_df(lapply(cols, sdv_bare), length(recs))
}

# One record per object of `e`, sorted by name; the bridge sends these too.
# object.size() walks a list, so very long lists report no size.
sdv_env_records <- function(e) {
  nms <- sort(ls(e, all.names = FALSE))
  lapply(nms, function(nm) {
    if (bindingIsActive(nm, e)) {
      return(list(name = nm, kind = "Values", class = "active binding", type = "", dim = "",
                  size = "", size_bytes = NA_real_, value = "<active binding>"))
    }
    v <- get(nm, envir = e, inherits = FALSE)
    bytes <- if (is.list(v) && !is.data.frame(v) && length(v) > 1e5) NA_real_
             else as.double(utils::object.size(v))
    list(name = nm, kind = sdv_env_kind(v), class = paste(class(v), collapse = "/"),
         type = typeof(v), dim = sdv_dim_text(v), size = sdv_size_text(bytes),
         size_bytes = bytes, value = sdv_str_line(v))
  })
}

# RStudio's Environment pane groups: Data (tabular or hierarchical objects),
# Functions, and Values for everything else.
sdv_env_kind <- function(v) {
  if (is.function(v)) return("Functions")
  if (is.data.frame(v) || is.list(v) || is.environment(v) || isS4(v) ||
      length(dim(v)) >= 2L) return("Data")
  "Values"
}

# "200 x 4" for a data frame or matrix, "2 x 3 x 4" for an array, the length
# otherwise; nothing for functions.
sdv_dim_text <- function(v) {
  if (is.function(v)) return("")
  if (is.data.frame(v)) return(sprintf("%d x %d", nrow(v), length(v)))
  d <- dim(v)
  if (!is.null(d)) return(paste(d, collapse = " x "))
  as.character(length(v))
}

sdv_size_text <- function(bytes) {
  if (is.na(bytes)) return("")
  format(structure(bytes, class = "object_size"), units = "auto")
}

# The first line of str(): 'num [1:200] 57 57 64 61 ...', 'function (df, by = "ARM")',
# 'List of 3', "'data.frame': 200 obs. of 4 variables:".
sdv_str_line <- function(v) {
  out <- tryCatch(utils::capture.output(
    utils::str(v, max.level = 0L, give.attr = FALSE, vec.len = 4L)),
    error = function(e) character())
  line <- if (length(out)) gsub("[ \t]+", " ", trimws(out[1])) else ""
  if (!nzchar(line)) sdv_preview(v) else sdv_truncate(line, 200L)
}

# ---- text helpers -----------------------------------------------------------

sdv_capture <- function(expr) {
  out <- tryCatch(utils::capture.output(expr), error = function(e) {
    paste("Error while printing:", conditionMessage(e))
  })
  sdv_limit_lines(out)
}

sdv_limit_lines <- function(lines) {
  max_lines <- sdv_opt("max_text_lines", 100000L)
  if (length(lines) > max_lines) {
    lines <- c(lines[seq_len(max_lines)],
               sprintf("... [%d more lines truncated]", length(lines) - max_lines))
  }
  lines
}

sdv_function_lines <- function(f, name) {
  sr <- attr(f, "srcref", exact = TRUE)
  lines <- if (!is.null(sr)) as.character(sr) else deparse(f, width.cutoff = 80L)
  if (is.primitive(f)) return(lines)
  if (length(lines) && grepl("^([[:alpha:]]|[.][._[:alpha:]])[._[:alnum:]]*$", name)) {
    lines[1] <- paste(name, "<-", lines[1])
  }
  sdv_limit_lines(lines)
}

sdv_describe <- function(x) {
  header <- sprintf("# class: %s", paste(class(x), collapse = ", "))
  printed <- sdv_capture(if (isS4(x)) methods::show(x) else print(x))
  structure <- sdv_capture(utils::str(x, max.level = 2L))
  sdv_limit_lines(c(header, "", printed, "", "# ---- str() ----", structure))
}
