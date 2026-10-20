# Helpers for the Ørsted foundation and cable data (05_prepare_analysis.qmd,
# step 8). Source after the tidyverse, sf and r/analysis_helpers.R:
#   source("r/analysis_helpers.R"); source("r/infra_helpers.R")
#
# The foundation tables (one CSV per project, from the Ørsted spreadsheets)
# give one row per installation day: a foundation installed over several days
# repeats its row with each date. Dates are mostly "10-May-24", with a few
# two-day cells ("19-20-Jul-25"); RWF coordinates are degree-minute-second
# text. These functions turn that into one row per foundation with a first
# and a last date, and then into per-cell, per-month exposure covariates.
#
# Everything here except read_foundation_csv() (which reads a file) is a
# pure function of its arguments, unit-tested in
# r/tests/testthat/test-infra_helpers.R.

# Dates ---------------------------------------------------------------------

# Excel's day 0 on Windows: serial 45422 is 2024-05-10
excel_origin <- as.Date("1899-12-30")

# Month name or abbreviation -> 1..12, independent of the session locale
# (format "%b" would read "Jun" only in an English locale). "Sept" -> 9.
month_num <- function(x) match(tolower(substr(x, 1, 3)), tolower(month.abb))

# Two-digit year, month name and day -> Date ("24", "Jun", "21" -> 2024-06-21)
ymd_short <- function(yy, mon, dd) {
  # explicit format: an impossible day ("2024-06-31") gives NA, not an error
  as.Date(sprintf("20%s-%02d-%02d", yy, month_num(mon), as.integer(dd)), format = "%Y-%m-%d")
}

# Parse one installation-date cell into its first and last day.
#
# `x`: character vector. Handles
#   - "D-Mon-YY" / "DD-Mon-YY" (one day; the usual form in the CSVs);
#   - "D-D-Mon-YY" and "D-D - Mon-YY" (two days of one month);
#   - "DD-Mon-YY to DD-Mon-YY", with any line break or spacing around "to";
#   - Excel serial numbers stored as text ("45422"), as in the original
#     spreadsheets.
# NA or empty input gives NA dates. Any other text is an error, so a new
# format in a future file cannot be dropped silently.
# Returns a tibble with columns `first` and `last` (Date), one row per input.
parse_install_dates <- function(x) {
  # collapse "\r\n" and runs of spaces so the patterns below see one line
  s <- stringr::str_squish(gsub("[\r\n]+", " ", x))
  first <- last <- rep(as.Date(NA), length(s))

  # Excel serial: integer text (45422; 45422.0 allowed too)
  serial <- !is.na(s) & grepl("^[0-9]+(\\.0+)?$", s)
  first[serial] <- last[serial] <- excel_origin + as.integer(as.numeric(s[serial]))

  # "10-May-24": one day
  one <- stringr::str_match(s, "^(\\d{1,2})-([A-Za-z]+)-(\\d{2})$")
  hit1 <- !is.na(one[, 1])
  first[hit1] <- last[hit1] <- ymd_short(one[hit1, 4], one[hit1, 3], one[hit1, 2])

  # "21-Jun-24 to 22-Jun-24"
  rng <- stringr::str_match(s, "^(\\d{1,2})-([A-Za-z]+)-(\\d{2}) ?to ?(\\d{1,2})-([A-Za-z]+)-(\\d{2})$")
  hit <- !is.na(rng[, 1])
  first[hit] <- ymd_short(rng[hit, 4], rng[hit, 3], rng[hit, 2])
  last[hit]  <- ymd_short(rng[hit, 7], rng[hit, 6], rng[hit, 5])

  # "19-20-Jul-25" and "7-8 - Sept-25": two days, one month and year
  two <- stringr::str_match(s, "^(\\d{1,2}) ?- ?(\\d{1,2}) ?- ?([A-Za-z]+)-(\\d{2})$")
  hit2 <- !is.na(two[, 1])
  first[hit2] <- ymd_short(two[hit2, 5], two[hit2, 4], two[hit2, 2])
  last[hit2]  <- ymd_short(two[hit2, 5], two[hit2, 4], two[hit2, 3])

  # anything non-empty that matched no pattern (or gave an impossible date)
  bad <- !is.na(s) & s != "" & (is.na(first) | is.na(last))
  if (any(bad)) stop("unparsed installation date(s): ", paste(unique(s[bad]), collapse = " | "))
  tibble::tibble(first = first, last = last)
}

# Coordinates ---------------------------------------------------------------

# Degree-minute-second text -> signed decimal degrees.
# "41-8-41.91N" -> 41.144975; "71-2-15.57W" -> -71.037658. South and west are
# negative. NA stays NA; anything else unparseable is an error.
dms_to_dd <- function(x) {
  m <- stringr::str_match(stringr::str_squish(x), "^(\\d+)-(\\d+)-([0-9.]+)([NSEW])$")
  bad <- !is.na(x) & is.na(m[, 1])
  if (any(bad)) stop("unparsed DMS coordinate(s): ", paste(x[bad], collapse = " | "))
  dd <- as.numeric(m[, 2]) + as.numeric(m[, 3]) / 60 + as.numeric(m[, 4]) / 3600
  ifelse(m[, 5] %in% c("S", "W"), -dd, dd)
}

# Coordinates as decimal degrees (SRW) or DMS text (RWF), decided per value
coord_to_dd <- function(x) {
  dec <- !is.na(x) & grepl("^-?[0-9.]+$", x)
  out <- rep(NA_real_, length(x))
  out[dec] <- as.numeric(x[dec])
  out[!dec & !is.na(x)] <- dms_to_dd(x[!dec & !is.na(x)])
  out
}

# Foundation CSVs -----------------------------------------------------------

# Collapse installation-day rows to one row per foundation.
#
# `rows`: one row per installation day (a foundation installed over several
#   days has one row per day, its other fields repeated), with columns
#   foundation_id, structure, date_first, date_last, lat, lon, depth_m.
# The foundation's `foundation_installed` is its earliest date and
# `foundation_end` its latest. Its repeated rows must agree on position,
# structure and depth, so a mistyped id cannot merge two foundations.
# Foundations keep the order of their first row.
collapse_foundation_rows <- function(rows) {
  stopifnot("a foundation id is missing" = !anyNA(rows$foundation_id),
            "an installation date is missing" = !anyNA(rows$date_first))
  agree <- rows |>
    dplyr::group_by(foundation_id) |>
    dplyr::summarise(ok = dplyr::n_distinct(structure, lat, lon, depth_m) == 1, .groups = "drop")
  if (!all(agree$ok)) stop("repeated rows disagree on structure, position or depth: ",
                           paste(agree$foundation_id[!agree$ok], collapse = ", "))
  rows |>
    dplyr::mutate(foundation_id = factor(foundation_id, levels = unique(foundation_id))) |>
    dplyr::group_by(foundation_id) |>
    dplyr::summarise(
      structure = structure[1],
      foundation_installed = min(date_first),
      foundation_end = max(date_last),
      n_date_rows = dplyr::n(),
      lat = lat[1], lon = lon[1], depth_m = depth_m[1], .groups = "drop") |>
    dplyr::mutate(foundation_id = as.character(foundation_id))
}

# Read one Ørsted foundation CSV (RWF or SRW) to one row per foundation.
# Columns are taken by position (#, Foundation ID, Structure Type, Install
# Date(s), Latitude, Longitude, Water Depth (m)); the SRW file's trailing
# empty columns, if any, are dropped. The files have been saved both as
# Latin-1 and as UTF-8, so the encoding is detected: UTF-8 if the bytes are
# valid UTF-8, else Latin-1. Some ids carry padding (spaces, non-breaking
# spaces, or the U+FFFD replacement character a non-breaking space becomes
# when a Latin-1 file is re-saved as UTF-8), which is removed.
read_foundation_csv <- function(path) {
  bytes <- readBin(path, "raw", file.info(path)$size)
  enc <- if (validUTF8(rawToChar(bytes))) "UTF-8" else "latin1"
  raw <- readr::read_csv(path, col_types = readr::cols(.default = "c"),
                         locale = readr::locale(encoding = enc),
                         name_repair = "minimal")
  stopifnot("expected at least 7 columns" = ncol(raw) >= 7)
  body <- raw[, 1:7]
  names(body) <- c("n", "foundation_id", "structure", "date", "lat", "lon", "depth_m")
  # non-breaking space (U+00A0) and replacement character (U+FFFD) -> space,
  # then trim and collapse runs
  clean <- \(x) stringr::str_squish(gsub("[ �]", " ", x))
  body <- body |>
    dplyr::mutate(dplyr::across(dplyr::everything(), clean)) |>
    dplyr::filter(!(is.na(foundation_id) & is.na(date)))  # blank lines

  dates <- parse_install_dates(body$date)
  body |>
    dplyr::transmute(foundation_id, structure,
                     date_first = dates$first, date_last = dates$last,
                     lat = coord_to_dd(lat), lon = coord_to_dd(lon),
                     depth_m = as.numeric(depth_m)) |>
    collapse_foundation_rows()
}

# Matching ------------------------------------------------------------------

# For each point in `a`, the nearest point in `b` and the distance in metres.
# `a`, `b`: sf POINT in the same projected CRS. Returns a tibble with `b_row`
# (row of `b`) and `dist_m`. The caller checks distances and one-to-one-ness.
nearest_point <- function(a, b) {
  stopifnot("a and b must share a CRS" = sf::st_crs(a) == sf::st_crs(b))
  i <- sf::st_nearest_feature(a, b)
  tibble::tibble(b_row = i,
                 dist_m = as.numeric(sf::st_distance(a, b[i, ], by_element = TRUE)))
}

# Exposure over time --------------------------------------------------------

# Last day of each month, for first-of-month Dates
month_end <- function(month) {
  as.Date(format(month + 31, "%Y-%m-01")) - 1
}

# Per-cell exposure to foundations, month by month.
#
# `d_km`: cells × foundations distance matrix (km), from cell centroids.
# `installed`, `end`: each foundation's first and last installation day
#   (NA for a foundation not installed in the window: it never counts).
# `months`: first-of-month Dates.
# A foundation counts as **installed in month t** once its last installation
# day falls on or before the end of t (it is in the water for good). It
# counts as **under construction in month t** if its installation days
# overlap t.
#
# Returns a tibble, one row per cell × month (cells in `d_km` row order, as
# `cell` = row index), with
#   d_found_km           distance to the nearest installed foundation, NA
#                        before any foundation is installed;
#   n_found_<r>km        installed foundations within `r_count_km`;
#   active_construction  TRUE if a foundation under construction that month
#                        lies within `r_active_km`.
foundation_exposure <- function(d_km, installed, end, months,
                                r_count_km = 2, r_active_km = 5) {
  stopifnot(ncol(d_km) == length(installed), length(installed) == length(end),
            "installed after end" = all(is.na(installed) | is.na(end) | installed <= end))
  me <- month_end(months)
  out <- lapply(seq_along(months), function(k) {
    inst <- !is.na(end) & end <= me[k]
    act  <- !is.na(installed) & installed <= me[k] & end >= months[k]
    d_in <- d_km[, inst, drop = FALSE]
    tibble::tibble(
      cell = seq_len(nrow(d_km)), year_month = months[k],
      # rowMins over the installed columns; no columns -> NA (nothing in the water)
      d_found_km = if (any(inst)) apply(d_in, 1, min) else NA_real_,
      n_found = as.integer(rowSums(d_in <= r_count_km)),
      active_construction = rowSums(d_km[, act, drop = FALSE] <= r_active_km) > 0)
  })
  out <- dplyr::bind_rows(out)
  names(out)[names(out) == "n_found"] <- sprintf("n_found_%gkm", r_count_km)
  out
}

# Per-cell exposure to cable works, month by month.
#
# `d_km`: cells × cable routes distance matrix (km). `start`, `end`: each
# route's works window (from its project × cable type; NA if unknown, in
# which case the route never counts). Returns a cells × months logical matrix,
# TRUE where a route whose window overlaps the month lies within `r_km`.
cable_works_exposure <- function(d_km, start, end, months, r_km = 2) {
  stopifnot(ncol(d_km) == length(start), length(start) == length(end))
  me <- month_end(months)
  near <- d_km <= r_km
  sapply(seq_along(months), function(k) {
    on <- !is.na(start) & !is.na(end) & start <= me[k] & end >= months[k]
    rowSums(near[, on, drop = FALSE]) > 0
  })
}

# Construction phase of a project in each month.
#
# `months`: first-of-month Dates. `works_start`: the project's first known
# works day (cable lay or foundation, whichever is earlier). `works_end`: its
# last known works day, or NA while work is ongoing or incomplete (it then
# stays in construction to the end of the window).
# Returns "pre", "construction" or "post_construction" per month.
project_phase <- function(months, works_start, works_end) {
  dplyr::case_when(
    is.na(works_start) | month_end(months) < works_start ~ "pre",
    is.na(works_end) | months <= works_end ~ "construction",
    TRUE ~ "post_construction")
}

# Whole months from the month containing `ref` to `month` (negative before).
months_between <- function(month, ref) {
  12L * (as.integer(format(month, "%Y")) - as.integer(format(ref, "%Y"))) +
    as.integer(format(month, "%m")) - as.integer(format(ref, "%m"))
}
