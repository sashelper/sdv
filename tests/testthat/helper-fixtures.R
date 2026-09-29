# Objects of many shapes and classes, built without optional packages.

ny_times <- as.POSIXct(c("2024-03-10 01:30:00", "2024-03-10 03:30:00",
                         "1960-05-01 12:00:00", "2024-11-03 01:15:00", NA),
                       tz = "America/New_York") + c(0, 0.75, 0, 0, 0)

fixture_messy_df <- function() {
  n <- 5L
  df <- data.frame(id = seq_len(n))
  attr(df$id, "label") <- "Identifier"
  df$fac <- factor(c("lo", "hi", NA, "lo", "mid"), levels = c("lo", "mid", "hi"))
  df$ord <- factor(c("a", "b", "c", "a", "b"), ordered = TRUE)
  df$date_int <- seq(as.Date("2024-01-30"), by = "day", length.out = n)   # integer storage
  df$date_dbl <- as.Date(c(19000.7, -1, NA, 0, 2932896))
  df$ny <- ny_times
  df$lt <- as.POSIXlt(ny_times)
  df$utc <- as.POSIXct("2020-01-01 10:00:00", tz = "UTC") + 3600 * seq_len(n)
  df$dt <- as.difftime(c(1.5, 2, NA, 4, 5), units = "hours")
  df$hms <- structure(c(3661, 59, NA, 86399, 0.5), units = "secs", class = c("hms", "difftime"))
  df$lst <- list(1:3, "x", NULL, list(a = 1), mtcars)
  df$asis <- I(list(1:3, "x", NULL, list(a = 1), mtcars))
  df$cpl <- complex(real = 1:5, imaginary = c(1, -1, 0, NA, 2))
  df$raw <- as.raw(c(0, 1, 15, 16, 255))
  df$mat <- matrix(1:10, n, dimnames = list(NULL, c("p", "q")))
  df$sub <- data.frame(a = letters[1:n], b = n:1)
  df$lbl <- structure(c(1, 2, 1, NA, 3), labels = c(Male = 1, Female = 2),
                      label = "Sex", class = c("haven_labelled", "vctrs_vctr", "double"))
  df$latin <- iconv(c("café", "naïve", "a", NA, "b"), "UTF-8", "latin1")
  df$chr_na <- c("  padded  ", NA, "", "x", "y")
  df$lgl <- c(TRUE, FALSE, NA, TRUE, FALSE)
  df$dbl <- c(1.5, NA, Inf, -Inf, NaN)
  df$big <- c(.Machine$integer.max, NA, -5L, 0L, 1L)
  df
}

# integer64 values 5, -1, NA built from raw int64 bits (bit64 not required).
int64_fixture <- function() {
  bits <- writeBin(c(5L, 0L, -1L, -1L, 0L, NA_integer_), raw(), endian = "little")
  structure(readBin(bits, "double", n = 3, endian = "little"), class = "integer64")
}

fixture_objects <- function() {
  dt_like <- data.frame(x = 1:3, y = c("a", "b", "c"))
  class(dt_like) <- c("data.table", "data.frame")
  attr(dt_like, ".internal.selfref") <- new("externalptr")
  tbl <- data.frame(x = 1:3)
  class(tbl) <- c("tbl_df", "tbl", "data.frame")
  dup <- data.frame(1:2, 3:4, 5:6)
  names(dup) <- c("A", "a", "")
  env <- new.env()
  assign("v", 1:3, envir = env)
  assign("f", function() NULL, envir = env)
  methods::setClass("SdvTestS4", representation(x = "numeric"), where = globalenv())
  list(
    messy = fixture_messy_df(),
    mtcars = mtcars,
    iris = iris,
    iris_subset = iris[c(3, 7, 9), ],
    dt_like = dt_like,
    tibble_like = tbl,
    dup_names = dup,
    zero_row = mtcars[0, ],
    matrix_num = matrix(c(1.5, 2, 3, 4), 2, dimnames = list(c("r1", "r2"), c("A", "B"))),
    matrix_chr = matrix(letters[1:6], 3),
    matrix_list = matrix(list(1, "a", 1:3, NULL), 2),
    array3 = array(1:24, 2:4),
    table1 = table(mtcars$cyl),
    table2 = table(cyl = mtcars$cyl, gear = mtcars$gear),
    table3 = table(mtcars$cyl, mtcars$gear, mtcars$am),
    xtabs = xtabs(~ cyl + gear, mtcars),
    ts = AirPassengers,
    mts = ts(matrix(1:20, 10, dimnames = list(NULL, c("s1", "s2"))), start = c(2000, 1), frequency = 4),
    vec_num = c(1.5, 2.5, NA),
    vec_named = c(a = 1L, b = 2L),
    vec_chr = letters,
    vec_factor = factor(c("x", "y", "x")),
    vec_date = Sys.Date() + 0:2,
    vec_posixlt = as.POSIXlt(ny_times),
    vec_int64 = int64_fixture(),
    list_df = list(a = 1:3, b = c("x", "y", "z")),
    list_nested = list(a = 1, b = list(c = "x", d = mtcars, `odd name` = NULL), 3:5),
    list_ragged = list(1:3, letters),
    numeric_version = numeric_version(c("1.2.3", "4.5")),
    env = env,
    closure = function(x, y = 2) x + y,
    primitive = sum,
    formula = y ~ x + z,
    call = quote(f(x, y)),
    lm = lm(mpg ~ wt, data = mtcars),
    htest = t.test(1:10),
    s4 = methods::new("SdvTestS4", x = 1)
  )
}

# The kind of payload each fixture must produce.
fixture_kinds <- c(closure = "text", primitive = "text", formula = "text", call = "text",
                   lm = "text", htest = "text", s4 = "text")

local_launcher <- function(env = parent.frame()) {
  calls <- new.env()
  calls$paths <- character()
  old <- options(sdv.launcher = function(p) {
    calls$paths <- c(calls$paths, p)
    invisible(TRUE)
  }, sdv.dir = tempfile("sdv-test-"))
  withr::defer(options(old), envir = env)
  calls
}
