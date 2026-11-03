# The live connection to StatDataViewer (doc/RSTUDIO_BRIDGE.md).
#
# StatDataViewer listens on 127.0.0.1:53211; this session connects as a
# WebSocket client, announces itself (r.hello), pushes the global environment's
# inventory after every top-level command (addTaskCallback), answers the
# viewer's object requests by writing the object with sdv_write(), and sends
# the objects the user views from RStudio (r.open) instead of running `open`.
# Everything runs through later's event loop, so it only happens while the
# console is idle; a running computation delays, never breaks, the bridge.
# The packages behind it, websocket and later, are Suggests: nothing here is
# touched unless sdv_connect() is called.

.sdv_bridge <- new.env(parent = emptyenv())
.sdv_bridge$ws <- NULL
.sdv_bridge$connected <- FALSE
.sdv_bridge$wanted <- FALSE      # the user asked for a connection (auto-reconnect)
.sdv_bridge$port <- 53211L
.sdv_bridge$token <- ""
.sdv_bridge$session_id <- NULL
.sdv_bridge$seq <- 0L
.sdv_bridge$last_digest <- NULL
.sdv_bridge$acks <- character()
.sdv_bridge$delay <- 5
.sdv_bridge$quiet <- FALSE
.sdv_bridge$viewer_version <- ""
.sdv_bridge$hello_said <- FALSE

sdv_bridge_packages_ok <- function() {
  requireNamespace("websocket", quietly = TRUE) && requireNamespace("later", quietly = TRUE)
}

sdv_session_id <- function() {
  if (is.null(.sdv_bridge$session_id)) {
    # Unique per R session, stable across reconnects within it.
    .sdv_bridge$session_id <- paste0(basename(tempdir()), "-", Sys.getpid())
  }
  .sdv_bridge$session_id
}

sdv_session_info <- function() {
  project <- ""
  ide <- ""
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    project <- tryCatch(rstudioapi::getActiveProject(), error = function(e) NULL)
    project <- if (is.null(project) || !nzchar(project)) "" else basename(project)
    ide <- tryCatch(paste("RStudio", as.character(rstudioapi::versionInfo()$version)),
                    error = function(e) "RStudio")
  }
  list(id = sdv_session_id(), pid = Sys.getpid(), project = project, cwd = getwd(), ide = ide)
}

sdv_bridge_say <- function(...) if (!isTRUE(.sdv_bridge$quiet)) message(...)

sdv_bridge_send <- function(msg) {
  ws <- .sdv_bridge$ws
  if (is.null(ws) || ws$readyState() != 1L) return(invisible(FALSE))
  ok <- tryCatch({
    ws$send(jsonlite::toJSON(msg, auto_unbox = TRUE, null = "null", digits = NA))
    TRUE
  }, error = function(e) FALSE)
  invisible(ok)
}

#' Connect this R session to StatDataViewer
#'
#' Opens a live connection to the StatDataViewer app on this computer. The
#' app then shows this session as "RStudio: <project>" in its Library tree,
#' with every object of the global environment under it, refreshed after each
#' command; double-clicking an object there opens a snapshot of it. While
#' connected, objects sent from RStudio (the shortcut, the addins, `View()`)
#' travel over the connection too, and the viewer brings itself to your
#' current Space. If the app is not running the connection is retried in the
#' background; nothing else changes, every function keeps working through
#' files as before.
#'
#' Needs the packages websocket and later (`install.packages(c("websocket",
#' "later"))`). To connect in every session, add to `~/.Rprofile`:
#'
#' ```r
#' setHook("rstudio.sessionInit", function(newSession) {
#'   if (requireNamespace("sdv", quietly = TRUE)) sdv::sdv_connect(quiet = TRUE)
#' }, action = "append")
#' ```
#'
#' @param port StatDataViewer's RStudio port (Options > RStudio), 53211 by
#'   default; option `sdv.port`.
#' @param token The token set in StatDataViewer's Options, if any; option
#'   `sdv.token` or the `SDV_TOKEN` environment variable.
#' @param quiet Suppress the connection messages.
#' @return Whether the connection attempt was started, invisibly.
#' @seealso [sdv_disconnect()], [sdv_connected()]
#' @export
sdv_connect <- function(port = getOption("sdv.port", 53211L),
                        token = getOption("sdv.token", Sys.getenv("SDV_TOKEN", "")),
                        quiet = FALSE) {
  if (!sdv_bridge_packages_ok()) {
    stop("sdv_connect() needs the packages websocket and later:\n",
         "  install.packages(c(\"websocket\", \"later\"))", call. = FALSE)
  }
  port <- as.integer(port)
  if (is.na(port) || port < 1L || port > 65535L) stop("Invalid port.", call. = FALSE)
  .sdv_bridge$port <- port
  .sdv_bridge$token <- if (is.null(token)) "" else as.character(token)
  .sdv_bridge$quiet <- isTRUE(quiet)
  .sdv_bridge$wanted <- TRUE
  .sdv_bridge$delay <- 5
  if (sdv_connected()) {
    sdv_bridge_say("Already connected to StatDataViewer on port ", port, ".")
    return(invisible(TRUE))
  }
  sdv_bridge_open()
  invisible(TRUE)
}

#' @rdname sdv_connect
#' @export
sdv_disconnect <- function() {
  .sdv_bridge$wanted <- FALSE
  sdv_bridge_remove_callback()
  ws <- .sdv_bridge$ws
  .sdv_bridge$ws <- NULL
  .sdv_bridge$connected <- FALSE
  if (!is.null(ws)) {
    if (ws$readyState() == 1L) {
      tryCatch(ws$send(jsonlite::toJSON(list(type = "r.bye"), auto_unbox = TRUE)),
               error = function(e) NULL)
    }
    tryCatch(ws$close(), error = function(e) NULL)
  }
  invisible(FALSE)
}

#' @rdname sdv_connect
#' @export
sdv_connected <- function() {
  ws <- .sdv_bridge$ws
  isTRUE(.sdv_bridge$connected) && !is.null(ws) && ws$readyState() == 1L
}

sdv_bridge_open <- function() {
  url <- sprintf("ws://127.0.0.1:%d/v1/r", .sdv_bridge$port)
  ws <- tryCatch(websocket::WebSocket$new(url, autoConnect = FALSE,
                                          accessLogChannels = "none",
                                          errorLogChannels = "none"),
                 error = function(e) NULL)
  if (is.null(ws)) {
    sdv_bridge_schedule_reconnect()
    return(invisible(FALSE))
  }
  .sdv_bridge$ws <- ws
  .sdv_bridge$connected <- FALSE
  ws$onOpen(function(event) {
    tryCatch(sdv_bridge_hello(), error = function(e) NULL)
  })
  ws$onMessage(function(event) {
    tryCatch(sdv_bridge_dispatch(event$data), error = function(e) {
      sdv_bridge_say("sdv: ", conditionMessage(e))
    })
  })
  ws$onClose(function(event) {
    if (!identical(.sdv_bridge$ws, ws)) return(invisible())   # an old socket
    was <- .sdv_bridge$connected
    .sdv_bridge$connected <- FALSE
    .sdv_bridge$ws <- NULL
    sdv_bridge_remove_callback()
    if (was) sdv_bridge_say("StatDataViewer disconnected.")
    if (isTRUE(event$code == 1008)) {
      .sdv_bridge$wanted <- FALSE
      message("StatDataViewer refused the connection: wrong token. ",
              "Set options(sdv.token = ...) to the token in its Options and call sdv_connect() again.")
      return(invisible())
    }
    sdv_bridge_schedule_reconnect()
  })
  ws$onError(function(event) {
    # Connection refused while the app is not running: onClose follows.
    invisible()
  })
  tryCatch(ws$connect(), error = function(e) sdv_bridge_schedule_reconnect())
  invisible(TRUE)
}

sdv_bridge_schedule_reconnect <- function() {
  if (!isTRUE(.sdv_bridge$wanted)) return(invisible())
  delay <- .sdv_bridge$delay
  .sdv_bridge$delay <- min(60, delay * 2)
  later::later(function() {
    if (isTRUE(.sdv_bridge$wanted) && !sdv_connected() && is.null(.sdv_bridge$ws)) {
      sdv_bridge_open()
    }
  }, delay)
  invisible()
}

sdv_bridge_hello <- function() {
  sdv_bridge_send(list(
    type = "r.hello",
    token = .sdv_bridge$token,
    pkgVersion = as.character(utils::packageVersion("sdv")),
    rVersion = paste(R.version$major, R.version$minor, sep = "."),
    session = sdv_session_info()))
}

# ---- inbound ----------------------------------------------------------------

sdv_bridge_dispatch <- function(text) {
  msg <- tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.list(msg) || is.null(msg$type)) return(invisible())
  type <- msg$type
  if (type == "viewer.hello") {
    .sdv_bridge$connected <- TRUE
    .sdv_bridge$delay <- 5
    .sdv_bridge$viewer_version <- msg$viewerVersion %||% ""
    if (!.sdv_bridge$hello_said) {
      sdv_bridge_say("Connected to StatDataViewer ", .sdv_bridge$viewer_version,
                     ": this session's objects are listed in its Library tree.")
      .sdv_bridge$hello_said <- TRUE
    }
    sdv_bridge_install_callback()
    sdv_bridge_push_inventory(force = TRUE)
  } else if (type == "viewer.object.open") {
    sdv_bridge_answer_open(msg$requestId %||% "", msg$name %||% "")
  } else if (type == "viewer.inventory.request") {
    sdv_bridge_push_inventory(force = TRUE)
  } else if (type == "viewer.ping") {
    sdv_bridge_send(list(type = "r.pong", requestId = msg$requestId %||% ""))
  } else if (type == "viewer.opened") {
    .sdv_bridge$acks <- c(.sdv_bridge$acks, msg$requestId %||% "")
  }
  invisible()
}

sdv_bridge_answer_open <- function(request_id, name) {
  fail <- function(code, text) {
    sdv_bridge_send(list(type = "r.error", requestId = request_id, code = code, message = text))
  }
  if (!nzchar(name) || !exists(name, envir = globalenv(), inherits = FALSE)) {
    return(fail("not_found", sprintf("object '%s' not found in the global environment", name)))
  }
  res <- tryCatch({
    x <- get(name, envir = globalenv(), inherits = FALSE)
    payload <- sdv_as_payload(sdv_prepare(x, name = name), name)
    if (is.null(payload)) stop("nothing to show (NULL or empty)")
    path <- sdv_write(payload)
    list(path = path, payload = payload)
  }, error = function(e) e)
  if (inherits(res, "error")) return(fail("convert_failed", conditionMessage(res)))
  payload <- res$payload
  msg <- list(type = "r.object.ready", requestId = request_id, name = name,
              path = res$path, kind = payload$kind,
              ext = if (payload$kind == "table") "rds" else payload$ext)
  if (payload$kind == "table") {
    msg$rows <- nrow(payload$data)
    msg$cols <- length(payload$data)
  }
  sdv_bridge_send(msg)
}

# ---- inventory --------------------------------------------------------------

sdv_bridge_install_callback <- function() {
  if (!"sdv_bridge" %in% getTaskCallbackNames()) {
    addTaskCallback(function(expr, value, ok, visible) {
      tryCatch(sdv_bridge_push_inventory(), error = function(e) NULL)
      TRUE
    }, name = "sdv_bridge")
  }
  invisible()
}

sdv_bridge_remove_callback <- function() {
  if ("sdv_bridge" %in% getTaskCallbackNames()) removeTaskCallback("sdv_bridge")
  .sdv_bridge$last_digest <- NULL
  invisible()
}

# Sends the inventory when it changed since the last push (or force = TRUE).
sdv_bridge_push_inventory <- function(force = FALSE) {
  if (!sdv_connected()) return(invisible(FALSE))
  max_objects <- getOption("sdv.inventory_max", 5000L)
  recs <- sdv_env_records(globalenv())
  truncated <- length(recs) > max_objects
  if (truncated) recs <- recs[seq_len(max_objects)]
  digest <- paste(vapply(recs, function(r) {
    paste(r$name, r$class, r$dim, r$size_bytes, sep = "\r")
  }, character(1)), collapse = "\n")
  if (!force && identical(digest, .sdv_bridge$last_digest)) return(invisible(FALSE))
  .sdv_bridge$last_digest <- digest
  .sdv_bridge$seq <- .sdv_bridge$seq + 1L
  objects <- lapply(recs, function(r) {
    list(name = r$name, kind = r$kind, class = r$class, dim = r$dim, size = r$size,
         sizeBytes = if (is.na(r$size_bytes)) NULL else r$size_bytes, value = r$value)
  })
  sdv_bridge_send(list(type = "r.inventory", seq = .sdv_bridge$seq,
                       objects = objects, truncated = truncated))
}

# ---- r.open: sending an object from RStudio ----------------------------------

# Hands a written file to the viewer over the connection and waits up to
# `timeout` seconds for viewer.opened. FALSE when not connected or not
# acknowledged in time, so the caller falls back to `open`.
sdv_bridge_open_file <- function(path, name, kind, timeout = getOption("sdv.open_timeout", 2)) {
  if (!sdv_connected()) return(FALSE)
  request_id <- paste0("open-", sdv_next_id(), "-", as.integer(Sys.time()))
  ok <- sdv_bridge_send(list(type = "r.open", requestId = request_id, name = name,
                             path = path, kind = kind, ext = tools::file_ext(path)))
  if (!ok) return(FALSE)
  deadline <- Sys.time() + timeout
  while (Sys.time() < deadline) {
    later::run_now(timeoutSecs = 0.05)
    if (request_id %in% .sdv_bridge$acks) {
      .sdv_bridge$acks <- setdiff(.sdv_bridge$acks, request_id)
      return(TRUE)
    }
    if (!sdv_connected()) return(FALSE)
  }
  FALSE
}
