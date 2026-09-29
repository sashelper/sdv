local_stub_view <- function(env = parent.frame()) {
  utils_env <- as.environment("package:utils")
  real <- get("View", envir = utils_env)
  seen <- new.env()
  seen$calls <- list()
  stub <- function(x, title) {
    seen$calls <- c(seen$calls, list(list(expr = substitute(x), title = title)))
    invisible(NULL)
  }
  sdv:::sdv_rebind(utils_env, "View", stub)
  withr::defer({
    sdv:::sdv_rebind(utils_env, "View", real)
    assign("orig_view", NULL, envir = sdv:::.sdv_state)
  }, envir = env)
  seen
}

test_that("View() routes tabular objects to StatDataViewer and others to the original", {
  seen <- local_stub_view()
  calls <- local_launcher()
  expect_message(sdv_use_as_viewer(TRUE), "sdv_use_as_viewer\\(FALSE\\)")
  expect_true(sdv:::sdv_is_our_view(get("View", envir = as.environment("package:utils"))))

  View(mtcars)
  expect_identical(basename(calls$paths), "mtcars.rds")

  f <- function(x) x
  View(f)
  expect_length(calls$paths, 1)
  expect_length(seen$calls, 1)
  expect_identical(seen$calls[[1]]$expr, quote(f))
  expect_identical(seen$calls[[1]]$title, "f")
})

test_that("types = 'all' sends everything", {
  seen <- local_stub_view()
  calls <- local_launcher()
  sdv_use_as_viewer(TRUE, types = "all", quiet = TRUE)
  withr::defer(options(sdv.view_types = "tabular"))
  View(function(x) x, "fn")
  expect_identical(basename(calls$paths), "fn.R")
  expect_length(seen$calls, 0)
})

test_that("disabling restores the original binding only when it is ours", {
  seen <- local_stub_view()
  utils_env <- as.environment("package:utils")
  stub <- get("View", envir = utils_env)
  sdv_use_as_viewer(TRUE, quiet = TRUE)
  expect_message(sdv_use_as_viewer(TRUE), "already")
  sdv_use_as_viewer(FALSE, quiet = TRUE)
  expect_identical(get("View", envir = utils_env), stub)
  expect_message(sdv_use_as_viewer(FALSE), "nothing to undo")
  expect_identical(get("View", envir = utils_env), stub)
})

test_that("the binding stays locked after rebinding", {
  seen <- local_stub_view()
  utils_env <- as.environment("package:utils")
  was_locked <- bindingIsLocked("View", utils_env)
  sdv_use_as_viewer(TRUE, quiet = TRUE)
  expect_identical(bindingIsLocked("View", utils_env), was_locked)
  sdv_use_as_viewer(FALSE, quiet = TRUE)
})
