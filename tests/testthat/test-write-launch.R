test_that("sdv_view writes a version-2 uncompressed rds and launches it", {
  calls <- local_launcher()
  p1 <- sdv_view(mtcars)
  p2 <- sdv_view(mtcars)
  expect_identical(basename(p1), "mtcars.rds")
  expect_false(identical(p1, p2))            # unique path: no "Reload Dataset?" prompt
  expect_identical(calls$paths, c(p1, p2))
  hdr <- readBin(p1, "raw", 14)
  expect_identical(rawToChar(hdr[1:2]), "X\n")
  expect_identical(readBin(hdr[3:6], "integer", size = 4, endian = "big"), 2L)
  expect_identical(readRDS(p1), sdv_prepare(mtcars, "mtcars")$data)
})

test_that("text payloads are written as UTF-8 .R / .txt files", {
  calls <- local_launcher()
  p <- sdv_view(function(x) "café", "fn")
  expect_identical(basename(p), "fn.R")
  expect_true(any(grepl("café", readLines(p, encoding = "UTF-8"), fixed = TRUE)))
  p2 <- sdv_view(lm(mpg ~ wt, mtcars), "fit")
  expect_identical(basename(p2), "fit.txt")
})

test_that("empty objects are not sent", {
  calls <- local_launcher()
  expect_message(res <- sdv_view(NULL), "nothing to show")
  expect_null(res)
  expect_length(calls$paths, 0)
})

test_that("open = FALSE only writes the file", {
  calls <- local_launcher()
  p <- sdv_view(iris, open = FALSE)
  expect_true(file.exists(p))
  expect_length(calls$paths, 0)
})

test_that("file names are sanitized", {
  expect_identical(sdv:::sdv_safe_name("mtcars$mpg"), "mtcars_mpg")
  expect_identical(sdv:::sdv_safe_name("head(mtcars, 3)"), "head_mtcars_3")
  expect_identical(sdv:::sdv_safe_name(".hidden"), "hidden")
  expect_identical(sdv:::sdv_safe_name("../../etc/passwd"), "etc_passwd")
  expect_identical(sdv:::sdv_safe_name("数据"), "数据")
  expect_identical(sdv:::sdv_safe_name(""), "object")
  expect_identical(nchar(sdv:::sdv_safe_name(strrep("a", 200))), 80L)
})

test_that("macOS open arguments use -a for a pinned app and -b otherwise", {
  args <- sdv:::sdv_mac_open_args("/tmp/x y.rds", app = "/Apps/SDV.app")
  expect_identical(args, c("-a", shQuote("/Apps/SDV.app"), shQuote("/tmp/x y.rds")))
  args <- sdv:::sdv_mac_open_args("/tmp/x.rds", bundle_id = "com.statdataviewer")
  expect_identical(args, c("-b", shQuote("com.statdataviewer"), shQuote("/tmp/x.rds")))
})

test_that("a wrong pinned app path gives an actionable error", {
  skip_on_os(c("windows", "linux", "solaris"))
  f <- tempfile(fileext = ".rds")
  saveRDS(data.frame(x = 1), f)
  withr::local_options(sdv.app = "/nonexistent/StatDataViewer.app",
                       sdv.launcher = NULL)
  expect_error(sdv:::sdv_launch(f), "File saved at")
})
