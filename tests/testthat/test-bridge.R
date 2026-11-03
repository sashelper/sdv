# The live connection (R/bridge.R) against a fake StatDataViewer: an httpuv
# WebSocket server in this process. Both ends run on later's event loop, so
# the tests pump it with later::run_now() until the expected message arrives.

skip_if_no_bridge <- function() {
  skip_if_not_installed("websocket")
  skip_if_not_installed("later")
  skip_if_not_installed("httpuv")
}

fake_viewer <- function(token = "", ack_opens = TRUE) {
  st <- new.env()
  st$received <- list()
  st$ws <- NULL
  st$token <- token
  st$ack_opens <- ack_opens
  send <- function(ws, msg) ws$send(jsonlite::toJSON(msg, auto_unbox = TRUE))
  app <- list(
    call = function(req) list(status = 404L, headers = list("Content-Type" = "text/plain"), body = "no"),
    onWSOpen = function(ws) {
      st$ws <- ws
      ws$onMessage(function(binary, message) {
        msg <- jsonlite::fromJSON(message, simplifyVector = FALSE)
        st$received <- c(st$received, list(msg))
        if (identical(msg$type, "r.hello")) {
          send(ws, list(type = "viewer.hello", viewerVersion = "fake"))
          if (nzchar(st$token) && !identical(msg$token, st$token)) {
            tryCatch(ws$close(1008L, "invalid token"), error = function(e) ws$close())
          }
        } else if (identical(msg$type, "r.open") && isTRUE(st$ack_opens)) {
          send(ws, list(type = "viewer.opened", requestId = msg$requestId))
        }
      })
      ws$onClose(function() st$ws <- NULL)
    })
  st$port <- httpuv::randomPort()
  st$server <- httpuv::startServer("127.0.0.1", st$port, app)
  st$send <- function(msg) send(st$ws, msg)
  st$types <- function() vapply(st$received, function(m) m$type %||% "", character(1))
  st$last <- function(type) {
    hits <- Filter(function(m) identical(m$type, type), st$received)
    if (length(hits)) hits[[length(hits)]] else NULL
  }
  st
}

pump <- function(until, timeout = 5) {
  deadline <- Sys.time() + timeout
  while (!isTRUE(until()) && Sys.time() < deadline) later::run_now(timeoutSecs = 0.05)
  isTRUE(until())
}

local_viewer <- function(..., env = parent.frame()) {
  viewer <- fake_viewer(...)
  withr::defer({
    sdv_disconnect()
    later::run_now(0.1)
    viewer$server$stop()
    assign("hello_said", FALSE, envir = sdv:::.sdv_bridge)
  }, envir = env)
  viewer
}

local_global <- function(name, value, env = parent.frame()) {
  assign(name, value, envir = globalenv())
  withr::defer(if (exists(name, envir = globalenv(), inherits = FALSE)) rm(list = name, envir = globalenv()),
               envir = env)
}

test_that("sdv_connect() says hello, lists the global environment and keeps it current", {
  skip_if_no_bridge()
  viewer <- local_viewer()
  calls <- local_launcher()
  local_global("sdv_bridge_df_", data.frame(a = 1:3))
  expect_false(sdv_connected())
  sdv_connect(port = viewer$port, quiet = TRUE)
  expect_true(pump(function() "r.hello" %in% viewer$types()))
  hello <- viewer$last("r.hello")
  expect_identical(hello$pkgVersion, as.character(packageVersion("sdv")))
  expect_identical(hello$session$pid, Sys.getpid())
  expect_identical(hello$session$id, sdv:::sdv_session_id())
  expect_true(pump(function() sdv_connected()))
  expect_true("sdv_bridge" %in% getTaskCallbackNames())

  expect_true(pump(function() "r.inventory" %in% viewer$types()))
  inv <- viewer$last("r.inventory")
  names_sent <- vapply(inv$objects, function(o) o$name, character(1))
  expect_true("sdv_bridge_df_" %in% names_sent)
  obj <- inv$objects[[match("sdv_bridge_df_", names_sent)]]
  expect_identical(obj$kind, "Data")
  expect_identical(obj$dim, "3 x 1")
  expect_match(obj$value, "^'data.frame': 3 obs")
  expect_false(isTRUE(inv$truncated))

  # Unchanged environment: nothing is pushed; a new object is.
  n <- length(viewer$received)
  sdv:::sdv_bridge_push_inventory()
  later::run_now(0.2)
  expect_identical(length(viewer$received), n)
  local_global("sdv_bridge_v_", c(1.5, 2.5))
  sdv:::sdv_bridge_push_inventory()
  expect_true(pump(function() length(viewer$received) > n))
  inv <- viewer$last("r.inventory")
  expect_true("sdv_bridge_v_" %in% vapply(inv$objects, function(o) o$name, character(1)))
  expect_identical(inv$seq, 2L)

  # The viewer can ask for a fresh list and for a ping.
  viewer$send(list(type = "viewer.inventory.request", requestId = "i1"))
  expect_true(pump(function() identical(viewer$last("r.inventory")$seq, 3L)))
  viewer$send(list(type = "viewer.ping", requestId = "p1"))
  expect_true(pump(function() identical(viewer$last("r.pong")$requestId, "p1")))
})

test_that("the viewer's object requests are answered with a written file", {
  skip_if_no_bridge()
  viewer <- local_viewer()
  calls <- local_launcher()
  local_global("sdv_bridge_df_", data.frame(a = 1:3, b = c("x", "y", "z")))
  local_global("sdv_bridge_fn_", function(x) x + 1)
  sdv_connect(port = viewer$port, quiet = TRUE)
  expect_true(pump(function() "r.inventory" %in% viewer$types()))

  viewer$send(list(type = "viewer.object.open", requestId = "o1", name = "sdv_bridge_df_"))
  expect_true(pump(function() !is.null(viewer$last("r.object.ready"))))
  ready <- viewer$last("r.object.ready")
  expect_identical(ready$requestId, "o1")
  expect_identical(ready$kind, "table")
  expect_identical(ready$rows, 3L)
  expect_identical(ready$cols, 2L)
  expect_true(file.exists(ready$path))
  expect_identical(basename(ready$path), "sdv_bridge_df.rds")   # sdv_safe_name drops the trailing _
  expect_identical(readRDS(ready$path)$b, c("x", "y", "z"))
  expect_length(calls$paths, 0)   # nothing was launched

  viewer$send(list(type = "viewer.object.open", requestId = "o2", name = "sdv_bridge_fn_"))
  expect_true(pump(function() identical(viewer$last("r.object.ready")$requestId, "o2")))
  expect_identical(viewer$last("r.object.ready")$kind, "text")
  expect_identical(viewer$last("r.object.ready")$ext, "R")

  viewer$send(list(type = "viewer.object.open", requestId = "o3", name = "no_such_object_zz"))
  expect_true(pump(function() !is.null(viewer$last("r.error"))))
  expect_identical(viewer$last("r.error")$code, "not_found")
  expect_identical(viewer$last("r.error")$requestId, "o3")
})

test_that("sdv_view() travels over the connection, and falls back to open when unanswered", {
  skip_if_no_bridge()
  viewer <- local_viewer(ack_opens = TRUE)
  calls <- local_launcher()
  withr::local_options(sdv.open_timeout = 0.5)
  sdv_connect(port = viewer$port, quiet = TRUE)
  expect_true(pump(function() sdv_connected()))

  path <- sdv_view(mtcars)
  expect_true(pump(function() !is.null(viewer$last("r.open"))))
  open <- viewer$last("r.open")
  expect_identical(open$name, "mtcars")
  expect_identical(open$kind, "table")
  expect_identical(open$path, normalizePath(path))
  expect_length(calls$paths, 0)   # acknowledged: `open` was not run

  viewer$ack_opens <- FALSE
  sdv_view(iris)
  expect_true(pump(function() identical(viewer$last("r.open")$name, "iris")))
  expect_identical(basename(calls$paths), "iris.rds")   # fell back after the timeout
})

test_that("disconnecting says goodbye and a wrong token is refused", {
  skip_if_no_bridge()
  viewer <- local_viewer(token = "secret")
  calls <- local_launcher()
  sdv_connect(port = viewer$port, token = "secret", quiet = TRUE)
  expect_true(pump(function() sdv_connected()))
  sdv_disconnect()
  expect_true(pump(function() "r.bye" %in% viewer$types()))
  expect_false(sdv_connected())
  expect_false("sdv_bridge" %in% getTaskCallbackNames())
  # Not connected: sdv_view() goes through files as before.
  sdv_view(mtcars)
  expect_identical(basename(calls$paths), "mtcars.rds")

  sdv_connect(port = viewer$port, token = "wrong", quiet = TRUE)
  expect_message(pump(function() !isTRUE(sdv:::.sdv_bridge$wanted)), "wrong token")
  expect_false(sdv_connected())
  expect_false(isTRUE(sdv:::.sdv_bridge$wanted))
})

test_that("sdv_connect() explains the missing packages", {
  skip_if(sdv:::sdv_bridge_packages_ok())
  expect_error(sdv_connect(), "websocket")
})
