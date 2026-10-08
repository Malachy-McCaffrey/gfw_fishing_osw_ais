# Helpers shared by the GFW qmds. Source after loading the tidyverse:
#   source("r/R/paths.R"); source("r/R/gfw_helpers.R")

# Development stages -------------------------------------------------------
# The single definition used by every script. A record's stage comes from its
# `Year Month` (the first day of its month).

dev_stages <- tibble::tribble(
  ~stage,    ~start,       ~end,         ~months, ~description,
  "Stage 1", "2016-01-01", "2019-08-31", 44L,     "Pre-monitoring baseline",
  "Stage 2", "2019-09-01", "2023-03-31", 43L,     "Pre-construction monitoring; protected species surveys began 09/2019",
  "Stage 3", "2023-04-01", "2026-09-30", 42L,     "Construction and operation across SFW, RWF and SRW; SFW seabed prep began 04/2023"
) |>
  dplyr::mutate(start = as.Date(start), end = as.Date(end))

stage_of <- function(date) {
  out <- rep(NA_character_, length(date))
  for (i in seq_len(nrow(dev_stages))) {
    hit <- !is.na(date) & date >= dev_stages$start[i] & date <= dev_stages$end[i]
    out[hit] <- dev_stages$stage[i]
  }
  out
}

# GFW records --------------------------------------------------------------
# Reads a raw or processed 4Wings CSV. Everything is read as character first
# (MMSI, IMO and call signs must never become numbers), then the analysis
# columns are typed and derived:
#   hours                  the file's hours column (VP or AFE), numeric
#   date, Year Month       from `Time Range`
#   Development Stage      from stage_of(); recomputed even if the file has one
#   ix, iy, cell_id        0.01 degree cell. GFW Lat/Lon mark the lower-left
#                          corner and carry float32 noise (e.g. -71.209999), so
#                          round() -- never floor() -- to the lattice.

read_gfw <- function(path) {
  d <- readr::read_csv(path, show_col_types = FALSE,
                       col_types = readr::cols(.default = readr::col_character()))

  hours_col <- intersect(c("Vessel Presence Hours", "Apparent Fishing Hours"), names(d))
  stopifnot("file needs exactly one hours column" = length(hours_col) == 1)

  d |>
    dplyr::mutate(
      Lat = as.numeric(Lat),
      Lon = as.numeric(Lon),
      dplyr::across(dplyr::all_of(hours_col), as.numeric),
      hours = .data[[hours_col]],
      date = as.Date(`Time Range`),
      `Year Month` = lubridate::floor_date(date, "month"),
      `Development Stage` = stage_of(`Year Month`),
      ix = as.integer(round(Lon / 0.01)),
      iy = as.integer(round(Lat / 0.01)),
      cell_id = sprintf("%d_%d", ix, iy))
}

# Gear classes -------------------------------------------------------------
# GFW `Gear Type` -> analysis gear class (references/data_dictionary.md)

gear_class_map <- c(
  TRAWLERS = "MOBILE", DREDGE_FISHING = "MOBILE", OTHER_PURSE_SEINES = "MOBILE",
  TUNA_PURSE_SEINES = "MOBILE", PURSE_SEINES = "MOBILE", TROLLERS = "MOBILE",
  DRIFTING_LONGLINES = "MOBILE",
  SET_GILLNETS = "FIXED", POTS_AND_TRAPS = "FIXED", SET_LONGLINES = "FIXED",
  FIXED_GEAR = "FIXED",
  POLE_AND_LINE = "POLE_AND_LINE")

gear_class_of <- function(g) dplyr::coalesce(unname(gear_class_map[g]), "UNRESOLVED")

fishing_gear_codes <- c(names(gear_class_map), "FISHING", "INCONCLUSIVE")
