token <- function(line, col) sdv:::sdv_token_at(line, col)

test_that("the object under the cursor is found", {
  cases <- list(
    list("mtcars", 1, "mtcars"),
    list("mtcars", 4, "mtcars"),
    list("mtcars", 7, "mtcars"),           # cursor right after the name
    list("head(df, 3)", 6, "df"),
    list("head(df, 3)", 2, "head"),
    list("x <- df$col + 1", 6, "df"),      # cursor on df
    list("x <- df$col + 1", 10, "df$col"), # cursor on col
    list("obj@slot", 6, "obj@slot"),
    list("datasets::mtcars", 3, "datasets::mtcars"),
    list("`my df`$x", 3, "`my df`"),
    list("`my df`$x", 9, "`my df`$x"),
    list("my.data_1[1:3, ]", 4, "my.data_1"),
    list("数据 + 1", 1, "数据")
  )
  for (cs in cases) expect_identical(token(cs[[1]], cs[[2]]), cs[[3]], info = cs[[1]])
})

test_that("non-objects under the cursor return NA", {
  expect_true(is.na(token("", 1)))
  expect_true(is.na(token("x + 1e5", 6)))   # inside a number
  expect_true(is.na(token("   ", 2)))
  expect_true(is.na(token("if (a) b", 1)))  # reserved word
  expect_true(is.na(token("f(TRUE)", 4)))
  expect_true(is.na(token("x[1]", 4)))
})

test_that("selections are evaluated in the global environment", {
  assign(".sdv_test_obj", data.frame(a = 1:3), envir = globalenv())
  withr::defer(rm(".sdv_test_obj", envir = globalenv()))
  expect_identical(sdv:::sdv_eval_text("head(.sdv_test_obj, 2)"), data.frame(a = 1:2))
  expect_identical(sdv:::sdv_eval_text("x <- 1\n.sdv_test_obj$a * 2"), c(2, 4, 6))
  expect_error(sdv:::sdv_eval_text("no_such_object_zz"))
})

test_that("display names come from simple expressions", {
  nm <- sdv:::sdv_name_from_text
  expect_identical(nm("mtcars"), "mtcars")
  expect_identical(nm("df$col"), "df$col")
  expect_identical(nm("head(mtcars, 3)"), "head(mtcars, 3)")
  expect_identical(nm("mtcars |>\n  subset(cyl == 4)"), "selection")
})

test_that("the addin needs RStudio", {
  skip_if(rstudioapi::isAvailable())
  expect_error(sdv_addin_view(), "RStudio")
})
