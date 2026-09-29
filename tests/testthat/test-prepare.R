test_that("every fixture becomes a viewer-safe table or a text document", {
  objs <- fixture_objects()
  for (nm in names(objs)) {
    p <- suppressWarnings(sdv_prepare(objs[[nm]], nm))
    expect_s3_class(p, "sdv_payload")
    expected <- if (nm %in% names(fixture_kinds)) fixture_kinds[[nm]] else "table"
    expect_identical(p$kind, expected, info = nm)
    if (p$kind == "table") {
      chk <- sdv_is_clean(p$data)
      expect_true(isTRUE(chk), info = paste(nm, paste(attr(chk, "problems"), collapse = "; ")))
    } else {
      expect_type(p$data, "character")
      expect_true(all(validUTF8(p$data)), info = nm)
    }
  }
})

test_that("NULL and empty vectors produce nothing", {
  expect_null(sdv_prepare(NULL))
  expect_null(sdv_prepare(integer()))
  expect_null(sdv_prepare(list()))
})

test_that("messy data frame columns are converted as documented", {
  d <- suppressWarnings(sdv_prepare(fixture_messy_df(), "messy"))$data
  expect_identical(attr(d$id, "label"), "Identifier")
  expect_identical(d$fac, c("lo", "hi", NA, "lo", "mid"))
  expect_identical(d$ord, c("a", "b", "c", "a", "b"))
  # Dates always stored as double (the viewer reads them through a double*).
  expect_type(unclass(d$date_int), "double")
  expect_identical(format(d$date_int), format(seq(as.Date("2024-01-30"), by = "day", length.out = 5)))
  expect_identical(format(d$date_dbl), c("2022-01-08", "1969-12-31", NA, "1970-01-01", "9999-12-31"))
  expect_identical(d$lst[1:4], c("1, 2, 3", "x", NA, "<list [1]>"))
  expect_identical(d$lst[5], "<data.frame [32 x 11]>")
  expect_identical(d$asis, d$lst)
  expect_identical(d$cpl[1:2], c("1+1i", "2-1i"))
  expect_true(is.na(d$cpl[4]))
  expect_identical(d$raw, c("00", "01", "0f", "10", "ff"))
  expect_identical(d$mat.p, 1:5)
  expect_identical(d$mat.q, 6:10)
  expect_identical(d$sub.a, letters[1:5])
  expect_identical(d$lbl, c(1, 2, 1, NA, 3), ignore_attr = TRUE)
  expect_identical(attr(d$lbl, "label"), "Sex")
  expect_identical(d$lbl_lbl, c("Male", "Female", "Male", NA, NA), ignore_attr = TRUE)
  expect_identical(d$latin[1:2], c("café", "naïve"))
  expect_true(all(validUTF8(d$latin[!is.na(d$latin)])))
  expect_identical(d$dt, c(1.5, 2, NA, 4, 5), ignore_attr = TRUE)
  expect_identical(attr(d$dt, "label"), "[hours]")
  expect_identical(d$hms, c("01:01:01", "00:00:59", NA, "23:59:59", "00:00:00.500"))
  expect_identical(d$big, c(.Machine$integer.max, NA, -5L, 0L, 1L))
})

test_that("POSIXct keeps the wall-clock time of its original time zone", {
  d <- sdv_prepare(data.frame(t = ny_times, lt = as.POSIXlt(ny_times)), "t")$data
  expected <- format(trunc(ny_times), "%Y-%m-%d %H:%M:%S", tz = "America/New_York")
  expect_identical(format(d$t, "%Y-%m-%d %H:%M:%S", tz = "UTC"), expected)
  expect_identical(format(d$lt, "%Y-%m-%d %H:%M:%S", tz = "UTC"), expected)
  expect_identical(attr(d$t, "tzone"), "UTC")
  expect_identical(attr(d$t, "label"), "Local time (America/New_York)")
  utc <- sdv_prepare(data.frame(t = as.POSIXct("2020-01-01 10:00:00", tz = "UTC")), "u")$data
  expect_null(attr(utc$t, "label"))
  expect_identical(format(utc$t, tz = "UTC"), "2020-01-01 10:00:00")
})

test_that("row names become a leading column", {
  d <- sdv_prepare(mtcars, "mtcars")$data
  expect_identical(names(d)[1], "row_names")
  expect_identical(d$row_names, rownames(mtcars))
  s <- sdv_prepare(iris[c(3, 7, 9), ], "s")$data
  expect_identical(s$row_names, c(3L, 7L, 9L))
  expect_false("row_names" %in% names(sdv_prepare(iris, "iris")$data))
})

test_that("column names are unique ignoring case and never empty", {
  d <- sdv_prepare(fixture_objects()$dup_names, "dup")$data
  expect_identical(names(d), c("A", "a_2", "V3"))
})

test_that("data.table internals are dropped", {
  d <- sdv_prepare(fixture_objects()$dt_like, "dt")$data
  expect_identical(names(attributes(d)), c("names", "class", "row.names"))
  expect_identical(d$y, c("a", "b", "c"))
})

test_that("matrices, arrays and tables are laid out as expected", {
  m <- sdv_prepare(fixture_objects()$matrix_num, "m")$data
  expect_identical(names(m), c("row_names", "A", "B"))
  t2 <- sdv_prepare(table(cyl = mtcars$cyl, gear = mtcars$gear), "t2")$data
  expect_identical(names(t2), c("cyl", "3", "4", "5"))
  expect_identical(t2$`3`, c(1L, 2L, 12L))
  t1 <- sdv_prepare(table(mtcars$cyl), "t1")$data
  expect_identical(names(t1), c("level", "Freq"))
  a <- sdv_prepare(array(1:24, 2:4), "a")$data
  expect_identical(nrow(a), 24L)
  expect_identical(a$value, 1:24)
})

test_that("time series get time and cycle columns", {
  d <- sdv_prepare(AirPassengers, "ap")$data
  expect_identical(names(d), c("time", "cycle", "value"))
  expect_identical(d$cycle[1:3], 1:3)
  m <- sdv_prepare(fixture_objects()$mts, "m")$data
  expect_identical(names(m), c("time", "cycle", "s1", "s2"))
})

test_that("vectors, integer64 and lists are tabulated", {
  expect_identical(names(sdv_prepare(c(a = 1, b = 2), "v")$data), c("name", "value"))
  expect_identical(sdv_prepare(factor(c("x", "y")), "f")$data$value, c("x", "y"))
  expect_identical(sdv_prepare(int64_fixture(), "i")$data$value, c(5, -1, NA))
  l <- sdv_prepare(list(a = 1:3, b = c("x", "y", "z")), "l")$data
  expect_identical(names(l), c("a", "b"))
  n <- sdv_prepare(fixture_objects()$list_nested, "cfg")$data
  expect_identical(n$path[1:4], c("cfg", "cfg$a", "cfg$b", "cfg$b$c"))
  expect_true("cfg$b$`odd name`" %in% n$path)
  expect_true("cfg[[3]]" %in% n$path)
  expect_identical(n$preview[n$path == "cfg$b$d"], "<data.frame [32 x 11]>")
})

test_that("functions and other objects become text", {
  f <- sdv_prepare(function(x, y = 2) x + y, "add")
  expect_identical(f$ext, "R")
  expect_match(f$data[1], "^add <- function")
  lm_txt <- sdv_prepare(lm(mpg ~ wt, data = mtcars), "fit")
  expect_true(any(grepl("Coefficients", lm_txt$data)))
  s4 <- sdv_prepare(fixture_objects()$s4, "s4")
  expect_match(s4$data[1], "SdvTestS4")
})

test_that("custom methods can return a data frame or text", {
  sdv_prepare.sdv_test_obj <- function(x, name = "object", ...) data.frame(v = unclass(x))
  registerS3method("sdv_prepare", "sdv_test_obj", sdv_prepare.sdv_test_obj)
  calls <- local_launcher()
  path <- sdv_view(structure(1:3, class = "sdv_test_obj"), "custom")
  expect_identical(readRDS(path)$v, 1:3)
})
