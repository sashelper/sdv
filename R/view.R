#' Open an R object in StatDataViewer
#'
#' Converts `x` with [sdv_prepare()], writes it to a temporary file and asks
#' StatDataViewer to open it. Data frames, matrices, arrays, tables, time
#' series, vectors and lists open as data tables; functions, models and other
#' objects open as text.
#'
#' @param x Any R object.
#' @param name Name shown in StatDataViewer. Defaults to the expression passed
#'   as `x`.
#' @param open If `FALSE`, only write the file.
#' @return The path of the written file, invisibly.
#' @examples
#' \dontrun{
#' sdv_view(mtcars)
#' sdv_view(split(iris, iris$Species), "iris_by_species")
#' }
#' @export
sdv_view <- function(x, name = NULL, open = TRUE) {
  if (is.null(name)) name <- deparse1(substitute(x), collapse = " ")
  payload <- sdv_as_payload(sdv_prepare(x, name = name), name)
  if (is.null(payload)) {
    message(sprintf("'%s' is empty (NULL or length 0); nothing to show.", name))
    return(invisible(NULL))
  }
  if (payload$kind == "table") {
    cells <- as.double(nrow(payload$data)) * max(1, length(payload$data))
    if (cells > 5e7) {
      warning(sprintf("'%s' has %s cells; StatDataViewer may take a while to load it.",
                      name, format(cells, big.mark = ",", scientific = FALSE)), call. = FALSE)
    }
  }
  path <- sdv_write(payload)
  if (open) sdv_launch(path)
  invisible(path)
}
