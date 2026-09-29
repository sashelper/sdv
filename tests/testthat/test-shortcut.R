local_config <- function(env = parent.frame()) {
  dir <- tempfile("rstudio-config-")
  withr::local_envvar(RSTUDIO_CONFIG_HOME = dir, .local_envir = env)
  file.path(dir, "keybindings", "addins.json")
}

test_that("the keybinding path follows RStudio's config rules", {
  withr::local_envvar(RSTUDIO_CONFIG_HOME = "/cfg")
  expect_identical(sdv_keybindings_path(), file.path("/cfg", "keybindings", "addins.json"))
  skip_on_os("windows")
  withr::local_envvar(RSTUDIO_CONFIG_HOME = "", XDG_CONFIG_HOME = "/xdg")
  expect_identical(sdv_keybindings_path(), file.path("/xdg", "rstudio", "keybindings", "addins.json"))
})

test_that("key strings are normalized", {
  nk <- sdv:::sdv_normalize_key
  expect_identical(nk("shift+ctrl+alt+v"), "Ctrl+Alt+Shift+V")
  expect_identical(nk("Command+Option+d"), "Alt+Cmd+D")
  expect_identical(nk("Ctrl+F10"), "Ctrl+F10")
  expect_error(nk("Hyper+X"), "Unknown modifier")
})

test_that("installing creates, merges and backs up addins.json", {
  path <- local_config()
  expect_message(sdv_install_shortcut(), "Restart RStudio")
  b <- sdv:::sdv_read_flat_json(path)
  expect_identical(b[["sdv::sdv_addin_view"]],
                   sdv:::sdv_normalize_key(sdv:::sdv_default_key()))

  # Existing bindings of other addins are kept; a backup is written.
  writeLines('{\n  "styler::style_selection": "Ctrl+Alt+Shift+A",\n  "x::y": "Cmd+\\"Q\\""\n}', path)
  expect_message(sdv_install_shortcut("Ctrl+Alt+Shift+O", binding = "sdv_addin_prompt"), "Bound")
  b <- sdv:::sdv_read_flat_json(path)
  expect_identical(b[["styler::style_selection"]], "Ctrl+Alt+Shift+A")
  expect_identical(b[["x::y"]], "Cmd+\"Q\"")
  expect_identical(b[["sdv::sdv_addin_prompt"]], "Ctrl+Alt+Shift+O")
  expect_true(file.exists(paste0(path, ".bak")))

  # Idempotent.
  expect_message(sdv_install_shortcut("Ctrl+Alt+Shift+O", binding = "sdv_addin_prompt"), "already")
})

test_that("conflicts are detected unless overwrite = TRUE", {
  path <- local_config()
  dir.create(dirname(path), recursive = TRUE)
  writeLines(sprintf('{"other::addin": "%s"}', sdv:::sdv_default_key()), path)
  expect_error(sdv_install_shortcut(), "already used by other::addin")
  expect_message(sdv_install_shortcut(overwrite = TRUE), "Bound")
  b <- sdv:::sdv_read_flat_json(path)
  expect_false("other::addin" %in% names(b))
  expect_identical(b[["sdv::sdv_addin_view"]],
                   sdv:::sdv_normalize_key(sdv:::sdv_default_key()))
})

test_that("the default key is two modifiers plus V", {
  key <- sdv:::sdv_default_key()
  expect_identical(key, if (Sys.info()[["sysname"]] == "Darwin") "Cmd+Shift+V" else "Ctrl+Shift+V")
  # Stored in RStudio's own modifier order (Ctrl, Alt, Shift, Cmd).
  expect_identical(sdv:::sdv_normalize_key(key),
                   if (Sys.info()[["sysname"]] == "Darwin") "Shift+Cmd+V" else "Ctrl+Shift+V")
})

test_that("files we don't understand are left alone", {
  path <- local_config()
  dir.create(dirname(path), recursive = TRUE)
  writeLines('{"a": {"nested": true}}', path)
  expect_error(sdv_install_shortcut(), "Unsupported")
  expect_identical(readLines(path), '{"a": {"nested": true}}')
})

test_that("shortcuts can be removed", {
  path <- local_config()
  expect_message(sdv_install_shortcut(), "Bound")
  expect_message(sdv_remove_shortcut(), "Removed")
  expect_length(sdv:::sdv_read_flat_json(path), 0)
  expect_message(sdv_remove_shortcut(), "No shortcut")
})
