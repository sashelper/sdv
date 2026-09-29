# Parses every prepared table with StatDataViewer's own reader (librdata, from
# the StatDataViewer source tree) through rds_probe, which mirrors the viewer's
# handlers and cell formatting. Built with AddressSanitizer so out-of-bounds
# reads in the viewer's code path fail the test.

# Set SDV_SOURCE_DIR to a StatDataViewer source checkout to run these tests.
sdv_source_dir <- function() path.expand(Sys.getenv("SDV_SOURCE_DIR", ""))

build_probe <- function() {
  skip_on_cran()
  skip_on_os(c("windows", "linux", "solaris"))
  d <- sdv_source_dir()
  skip_if_not(file.exists(file.path(d, "librdata", "rdata_read.c")),
              "StatDataViewer sources (librdata) not found; set SDV_SOURCE_DIR")
  skip_if(!nzchar(Sys.which("cc")), "no C compiler")
  exe <- file.path(tempdir(), "rds_probe")
  if (file.exists(exe)) return(exe)
  lib <- file.path(d, "librdata")
  src <- c(test_path("rds_probe", "rds_probe.c"),
           file.path(lib, c("CKHashTable.c", "rdata_error.c", "rdata_io_unistd.c",
                            "rdata_parser.c", "rdata_read.c", "rdata_bits.c")))
  args <- c("-std=c11", "-O1", "-g", "-w", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-DHAVE_ZLIB", "-DHAVE_BZIP2", "-DHAVE_LZMA",
            paste0("-I", c(lib, file.path(d, c("zlib-universal", "bzip2-universal", "xz-universal"), "include"))),
            shQuote(src),
            file.path(d, "zlib-universal", "lib", "libz.a"),
            file.path(d, "bzip2-universal", "lib", "libbz2.a"),
            file.path(d, "xz-universal", "lib", "liblzma.a"),
            "-liconv", "-o", shQuote(exe))
  out <- suppressWarnings(system2("cc", args, stdout = TRUE, stderr = TRUE))
  skip_if(!file.exists(exe), paste("could not build rds_probe:", paste(out, collapse = "\n")))
  exe
}

run_probe <- function(exe, path, max_rows = 20L) {
  # abort_on_error=0 makes ASan exit(1) instead of abort(), keeping the shell quiet.
  out <- suppressWarnings(system2(exe, c(shQuote(path), max_rows), stdout = TRUE, stderr = TRUE,
                                  env = "ASAN_OPTIONS=detect_leaks=0:abort_on_error=0"))
  status <- attr(out, "status") %||% 0L
  list(status = status, out = out)
}

parse_probe <- function(out) {
  cols <- regmatches(out, regexec("^COL ([0-9]+) (\\S+) ([^\t]*)\t(.*)$", out))
  cols <- do.call(rbind, lapply(cols[lengths(cols) > 0], function(m) m[-1]))
  cells <- regmatches(out, regexec("^CELL ([0-9]+) ([0-9]+) (.*)$", out))
  cells <- do.call(rbind, lapply(cells[lengths(cells) > 0], function(m) m[-1]))
  dim <- as.integer(strsplit(sub("^DIM ", "", grep("^DIM ", out, value = TRUE)), " ")[[1]])
  list(dim = dim, types = cols[, 2], names = cols[, 3], labels = cols[, 4],
       cells = cells)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# What the viewer shows for a cleaned column (C locale month names).
expected_cells <- function(v, rows) {
  v <- v[rows]
  esc <- function(s) gsub("\r", "\\r", gsub("\t", "\\t", gsub("\n", "\\n", gsub("\\", "\\\\", s, fixed = TRUE), fixed = TRUE), fixed = TRUE), fixed = TRUE)
  if (inherits(v, "Date")) return(ifelse(is.na(v), "NA", format(v, "%d%b%Y")))
  if (inherits(v, "POSIXct")) return(ifelse(is.na(v), "NA", format(v, "%d%b%Y:%H:%M:%S", tz = "UTC")))
  if (is.character(v)) return(ifelse(is.na(v), "<NA>", esc(trimws(v, whitespace = "[ \t\r\n\f\v]"))))
  if (is.logical(v)) return(ifelse(is.na(v), "NA", ifelse(v, "TRUE", "FALSE")))
  if (is.integer(v)) return(ifelse(is.na(v), "NA", as.character(v)))
  NULL  # doubles are compared numerically
}

type_of <- function(v) {
  if (inherits(v, "Date")) "Date" else if (inherits(v, "POSIXct")) "Timestamp"
  else switch(typeof(v), character = "String", integer = "Integer", double = "Real", logical = "Logical")
}

test_that("StatDataViewer's reader displays every prepared table correctly", {
  exe <- build_probe()
  withr::local_locale(LC_TIME = "C")
  calls <- local_launcher()
  objs <- fixture_objects()
  for (nm in names(objs)) {
    p <- suppressWarnings(sdv_prepare(objs[[nm]], nm))
    if (p$kind != "table") next
    path <- sdv_view(p$data, nm, open = FALSE)
    res <- run_probe(exe, path)
    expect_identical(res$status, 0L, info = paste(nm, paste(res$out, collapse = "\n")))
    expect_false(any(grepl("AddressSanitizer|runtime error", res$out)), info = nm)
    if (res$status != 0L) next
    df <- p$data
    got <- parse_probe(res$out)
    expect_identical(got$dim, c(nrow(df), ncol(df)), info = nm)
    expect_identical(got$names, gsub("\\", "\\\\", names(df), fixed = TRUE), info = nm)
    expect_identical(got$types, vapply(df, type_of, ""), ignore_attr = TRUE, info = nm)
    labels <- vapply(df, function(v) attr(v, "label", exact = TRUE) %||% "", "")
    expect_identical(got$labels, unname(labels), info = nm)
    expect_true(any(grepl("^VALUE_LABELS 0$", res$out)), info = nm)
    rows <- seq_len(min(nrow(df), 20L))
    if (!length(rows)) next
    for (j in seq_along(df)) {
      shown <- got$cells[as.integer(got$cells[, 2]) == j, 3]
      want <- expected_cells(df[[j]], rows)
      if (is.null(want)) {
        num <- suppressWarnings(as.numeric(shown))
        exp_num <- as.double(df[[j]][rows])
        expect_equal(num, ifelse(is.nan(exp_num), NA_real_, exp_num), info = paste(nm, names(df)[j]))
      } else {
        expect_identical(shown, unname(want), info = paste(nm, names(df)[j]))
      }
    }
  }
})

test_that("New York wall-clock times survive the round trip into the viewer", {
  exe <- build_probe()
  calls <- local_launcher()
  path <- sdv_view(data.frame(t = ny_times), "ny", open = FALSE)
  got <- parse_probe(run_probe(exe, path)$out)
  expect_identical(got$cells[, 3], c("10Mar2024:01:30:00", "10Mar2024:03:30:00",
                                     "01May1960:12:00:00", "03Nov2024:01:15:00", "NA"))
})

test_that("the viewer reads integer- and logical-stored dates without the plugin's help", {
  # Regression test for the librdata fix in read_value_vector_cb: these
  # columns used to be read through a double* past the end of an int buffer.
  exe <- build_probe()
  f <- tempfile(fileext = ".rds")
  saveRDS(data.frame(d = seq(as.Date("2024-01-30"), by = "day", length.out = 3),
                     n = .Date(c(0L, NA, -1L)),
                     t = .POSIXct(c(0L, 3600L, NA), tz = "UTC"),
                     l = .Date(rep(NA, 3))), f)
  res <- run_probe(exe, f)
  expect_identical(res$status, 0L)
  expect_false(any(grepl("AddressSanitizer|runtime error", res$out)))
  got <- parse_probe(res$out)
  expect_identical(got$types, c("Date", "Date", "Timestamp", "Date"))
  expect_identical(got$cells[, 3], c("30Jan2024", "01Jan1970", "01Jan1970:00:00:00", "NA",
                                     "31Jan2024", "NA", "01Jan1970:01:00:00", "NA",
                                     "01Feb2024", "31Dec1969", "NA", "NA"))
})
