# Loaded by testthat before the tests. Run the suite from the repo root with
#   testthat::test_dir("r/tests/testthat")
# test_dir() runs from this folder, so the repo root is three levels up.

suppressPackageStartupMessages(library(tidyverse))

root <- normalizePath(file.path("..", "..", ".."), winslash = "/")

source(file.path(root, "r/paths.R"))
source(file.path(root, "r/gfw_helpers.R"))
source(file.path(root, "r/vessel_helpers.R"))

# project paths made absolute, for the reference-file tests
root_paths <- lapply(gfw_paths, \(p) file.path(root, p))

# a raw-pull-shaped CSV, written to a temporary file; returns its path
write_raw <- function(..., hours_col = "Vessel Presence Hours") {
  d <- tibble(...)
  if (!hours_col %in% names(d)) d[[hours_col]] <- 1
  path <- tempfile(fileext = ".csv")
  write_csv(d, path)
  path
}

# a typed crosswalk row, with defaults for the columns a test does not set
cw_row <- function(MMSI, valid_from = NA, valid_to = NA, hull_class = "fishing",
                   activity_excluded = FALSE) {
  tibble(MMSI, valid_from = as.Date(valid_from), valid_to = as.Date(valid_to),
         hull_class, activity_excluded, Identified_By = "test")
}
