# Helpers shared by the GFW qmds. Source after loading the tidyverse:
#   source("r/paths.R"); source("r/gfw_helpers.R")

# Development stages -------------------------------------------------------
# The single definition used by every script. A record's stage comes from its
# `Year Month` (the first day of its month).

dev_stages <- tibble::tribble(
  ~stage,    ~start,       ~end,         ~months, ~description,
  "Stage 1", "2016-01-01", "2020-09-30", 57L,     "Pre-monitoring baseline",
  "Stage 2", "2020-10-01", "2023-03-31", 30L,     "Pre-construction monitoring; SFW fisheries monitoring began 10/2020",
  "Stage 3", "2023-04-01", "2026-08-31", 41L,     "Construction and operation across SFW, RWF and SRW; SFW seabed prep began 04/2023"
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

# Analysis window ----------------------------------------------------------
# The stages span the analysis window. The pull runs past its end (to
# 2026-09-30), but the window stops at 2026-08-31, the last day the Ørsted
# survey-date files cover: after it, survey trips are undated and would count
# as fishing. Every qmd drops records outside the window after reading them.

analysis_start <- min(dev_stages$start)
analysis_end   <- max(dev_stages$end)

in_analysis_window <- function(d) {
  keep <- !is.na(d$date) & d$date >= analysis_start & d$date <= analysis_end
  if (any(!keep)) {
    message("Dropped ", sum(!keep), " records outside the analysis window (",
            analysis_start, " to ", analysis_end, ")")
  }
  d[keep, ]
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

# Combined grid across pipeline versions -------------------------------------
# GFW reprocesses its history at each pipeline release, and the cells a pull
# returns at the AOI edge differ slightly between versions (v4 and v5 each
# have 4 one-to-four-hour VP cells the other lacks, all at or just outside the
# AOI boundary). So that every version's tables and spatial weights share one
# cell set and can be compared cell for cell, 02 builds the grid from the
# union of the VP cells in every pull filed under data/raw/gfw/ (decision
# D-069; planning/gfw_pipeline_v5_plan.qmd, Section 2.2). A cell with no
# records in one version is zero-filled in that version's tables, the same
# "GFW served no records here" zero as any other empty cell.

# The pipeline versions that have a raw VP pull under `raw_root` (the parent
# of paths$raw_gfw, i.e. data/raw/gfw), sorted by version number (v10 after
# v9). Folders without a gfw_vp_id.csv are not pulls and are skipped.
pull_versions <- function(raw_root) {
  files <- Sys.glob(file.path(raw_root, "*", "gfw_vp_id.csv"))
  versions <- basename(dirname(files))
  num <- suppressWarnings(as.numeric(sub("^v", "", versions)))
  versions[order(num, versions)]
}

# Distinct cells (cell_id, ix, iy) across several raw VP files, with
# `in_pulls`, the versions whose pull has records in the cell ("v4;v5").
# `vp_files` is a named vector, version -> path to that version's
# gfw_vp_id.csv. Only the coordinate columns are needed, so only they are
# read, to keep memory down on the full pulls.
union_grid_cells <- function(vp_files) {
  stopifnot("vp_files must be named by pipeline version" =
              !is.null(names(vp_files)) && all(nzchar(names(vp_files))))
  purrr::imap(vp_files, \(f, v) {
    readr::read_csv(f, col_select = c(Lat, Lon), show_col_types = FALSE,
                    col_types = readr::cols(.default = readr::col_character())) |>
      dplyr::distinct() |>
      # the same lattice snap as read_gfw(): round(), never floor()
      dplyr::transmute(ix = as.integer(round(as.numeric(Lon) / 0.01)),
                       iy = as.integer(round(as.numeric(Lat) / 0.01))) |>
      dplyr::distinct() |>
      dplyr::mutate(version = v)
  }) |>
    purrr::list_rbind() |>
    dplyr::mutate(cell_id = sprintf("%d_%d", ix, iy)) |>
    dplyr::group_by(cell_id, ix, iy) |>
    dplyr::summarise(in_pulls = paste(version, collapse = ";"), .groups = "drop") |>
    dplyr::arrange(iy, ix)
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

# gear codes that mark a fishing vessel; OTHER_FISHING appears in GFW registry
# records (e.g. ICCAT) but not in the AIS Gear Type field
fishing_gear_codes <- c(names(gear_class_map), "FISHING", "INCONCLUSIVE", "OTHER_FISHING")

# Pinned 4Wings pulls --------------------------------------------------------
# gfwr 3.0's gfw_ais_presence() and gfw_ais_fishing_hours() always request a
# dataset's ":latest" version, so the pipeline version a pull came from cannot
# be chosen or read back (planning/gfw_pipeline_v5_plan.qmd, Section 3.2).
# These functions send the same 4Wings report request with the dataset ID
# given explicitly, e.g. "public-global-presence:v5.0". The request mirrors
# gfwr:::gfw_4wings() and gfwr:::gfw_endpoint() for a user-shapefile region;
# r/tests/testthat/test-gfw_helpers.R checks it against gfwr's own URL and
# body, so a gfwr change that alters the request shows up as a failing test.
# Only the region encoding (gfwr:::sf_to_geojson()) is borrowed from gfwr's
# internals; renv pins gfwr, so it changes only with a deliberate upgrade.

gfw_api_base <- "https://gateway.api.globalfishingwatch.org/v3/"

# 4Wings dataset ID at a pinned version: gfw_dataset_id("presence", "v5.0")
# -> "public-global-presence:v5.0". `version` must name a release (vN.N);
# ":latest" is refused, since it is what pinning replaces.
gfw_dataset_id <- function(dataset = c("presence", "fishing-effort"), version) {
  dataset <- match.arg(dataset)
  if (!grepl("^v[0-9]+\\.[0-9]+$", version)) {
    stop("dataset version must look like v5.0, not '", version, "'", call. = FALSE)
  }
  sprintf("public-global-%s:%s", dataset, version)
}

# The httr2 request for one 4Wings report, built but not sent. `region` is an
# sf polygon (the AOI); dates are "YYYY-MM-DD", start included and end
# excluded, at most 366 days apart (the API's limit, checked as gfwr does).
gfw_4wings_request <- function(dataset, start_date, end_date, region,
                               spatial_resolution = "HIGH",
                               temporal_resolution = "DAILY",
                               group_by = "VESSEL_ID",
                               key = Sys.getenv("GFW_TOKEN")) {
  if (as.numeric(as.Date(end_date) - as.Date(start_date)) > 366) {
    stop("the start and end dates should be apart 366 days or less", call. = FALSE)
  }
  if (!inherits(region, "sf") ||
      !inherits(sf::st_geometry(region), c("sfc_POLYGON", "sfc_MULTIPOLYGON"))) {
    stop("region must be an sf polygon", call. = FALSE)
  }
  httr2::request(gfw_api_base) |>
    httr2::req_url_path_append("4wings/report") |>
    # same query parameters, in the same order, as gfwr:::gfw_endpoint()
    httr2::req_url_query(`datasets[0]` = dataset,
                         `spatial-resolution` = spatial_resolution,
                         `temporal-resolution` = temporal_resolution,
                         `group-by` = group_by,
                         `date-range` = paste(start_date, end_date, sep = ","),
                         format = "CSV") |>
    httr2::req_headers(Authorization = paste("Bearer", key),
                       `Content-Type` = "application/json") |>
    # the AOI as {"geojson": ...}; a body makes the request a POST, as in gfwr
    httr2::req_body_raw(gfwr:::sf_to_geojson(region, endpoint = "raster")) |>
    httr2::req_user_agent(gfwr::gfw_user_agent())
}

# Send one pinned 4Wings report request and return its records. The response
# is a zip holding one CSV, as for gfwr. Every column is read as character, so
# the raw text (MMSI, IMO, timestamps) is written back unchanged; read_gfw()
# types the columns later. Transient failures (HTTP 429/503) are retried, and
# an API error stops with GFW's own message.
gfw_4wings_pinned <- function(dataset, start_date, end_date, region, ...) {
  resp <- gfw_4wings_request(dataset, start_date, end_date, region, ...) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_error(body = \(resp) tryCatch(
      paste(unlist(httr2::resp_body_json(resp)$messages), collapse = "; "),
      error = \(e) NULL)) |>
    httr2::req_perform()

  zip <- tempfile(fileext = ".zip")
  on.exit(unlink(zip), add = TRUE)
  writeBin(httr2::resp_body_raw(resp), zip)
  csv <- grep("\\.csv$", utils::unzip(zip, list = TRUE)$Name, value = TRUE)
  stopifnot("expected one CSV in the 4Wings response" = length(csv) == 1)
  readr::read_csv(unz(zip, csv), show_col_types = FALSE,
                  col_types = readr::cols(.default = readr::col_character()))
}

# Port visits from the GFW Events API (03b_port_visits.qmd, D-080) -------------
#
# gfwr 3.0's get_event(event_type = "PORT_VISIT") asks for
# "public-global-port-visits-c2-events:latest", which the API now answers with
# HTTP 404 (probe, 2026-11-01). The working dataset is
# "public-global-port-visits-events", served at ":latest" and at pinned
# versions, and v4.0 and v5.0 differ slightly for the same vessel ID. So, as
# for 4Wings above, the request is built here with the version pinned to the
# pipeline's, and every parsed row records the dataset it came from.

# Port-visit dataset ID at a pinned version: port_visits_dataset("v5.0") ->
# "public-global-port-visits-events:v5.0". ":latest" is refused, as above.
port_visits_dataset <- function(version) {
  if (!grepl("^v[0-9]+[.][0-9]+$", version)) {
    stop("dataset version must look like v5.0, not '", version, "'", call. = FALSE)
  }
  sprintf("public-global-port-visits-events:%s", version)
}

# The httr2 request for one page of one vessel ID's port visits, built but not
# sent. Dates are "YYYY-MM-DD"; `offset` pages through the results (the API
# returns `nextOffset` while more remain). One vessel ID per request, so a
# failure or an empty answer is recorded against that ID in the queried log.
gfw_port_visits_request <- function(vessel_id, dataset, start_date, end_date,
                                    offset = 0, limit = 500,
                                    key = Sys.getenv("GFW_TOKEN")) {
  stopifnot("one vessel ID per request" = is.character(vessel_id) && length(vessel_id) == 1,
            "start_date must come before end_date" = as.Date(start_date) < as.Date(end_date))
  httr2::request(gfw_api_base) |>
    httr2::req_url_path_append("events") |>
    httr2::req_url_query(`datasets[0]` = dataset, `vessels[0]` = vessel_id,
                         `start-date` = start_date, `end-date` = end_date,
                         limit = limit, offset = offset) |>
    httr2::req_headers(Authorization = paste("Bearer", key)) |>
    httr2::req_user_agent(gfwr::gfw_user_agent())
}

# Every port visit of one vessel ID: sends the request page by page and returns
# the API's entries as a list (one element per visit), for parse_port_visits().
# Transient failures (HTTP 429/503) are retried; an API error stops with GFW's
# own message, which 03b catches and logs as an error for that ID.
gfw_port_visits <- function(vessel_id, dataset, start_date, end_date,
                            key = Sys.getenv("GFW_TOKEN"), pause = 0.3) {
  entries <- list()
  offset <- 0
  repeat {
    page <- gfw_port_visits_request(vessel_id, dataset, start_date, end_date,
                                    offset = offset, key = key) |>
      httr2::req_retry(max_tries = 3) |>
      httr2::req_error(body = \(resp) tryCatch(
        paste(unlist(httr2::resp_body_json(resp)$messages), collapse = "; "),
        error = \(e) NULL)) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    entries <- c(entries, page$entries)
    if (is.null(page$nextOffset)) break
    offset <- page$nextOffset
    Sys.sleep(pause)   # be gentle with the API between pages
  }
  entries
}

# Columns of the raw port-visit cache, in order (one row per visit)
port_visit_cols <- c("event_id", "visit_id", "vessel_id", "MMSI", "vessel_name",
                     "start", "end", "confidence", "duration_hrs",
                     paste0(rep(c("start", "int", "end"), each = 6),
                            c("_anchorage_id", "_label", "_name", "_lat", "_lon", "_at_dock")),
                     "dataset", "pulled_on")

# API entries for one vessel ID -> one row per visit, every column character
# (as the other raw caches are; port_visit_filter() types what it needs). The
# GFW vessel type on the events is not kept: the roster's classification is
# used instead (D-080). Stops if any event's MMSI (`ssvid`) differs from
# `mmsi`, the MMSI the vessel ID was queried for, since a mismatch means the
# vessel ID does not belong to that MMSI in this pipeline.
parse_port_visits <- function(entries, vessel_id, mmsi, dataset, pulled_on = Sys.Date()) {
  if (length(entries) == 0) {
    # no visits: an empty table with the cache's columns, so appends line up
    return(tibble::as_tibble(stats::setNames(
      rep(list(character()), length(port_visit_cols)), port_visit_cols)))
  }
  # a JSON field as text; absent or null fields (e.g. an unnamed anchorage's
  # `name`) become NA rather than dropping the column
  chr <- function(x) if (is.null(x)) NA_character_ else as.character(x)
  # the six fields kept for one anchorage (start, intermediate or end)
  anchorage <- function(a, prefix) {
    stats::setNames(list(chr(a$anchorageId), chr(a$id), chr(a$name), chr(a$lat),
                         chr(a$lon), chr(a$atDock)),
                    paste0(prefix, c("_anchorage_id", "_label", "_name", "_lat", "_lon",
                                     "_at_dock")))
  }
  rows <- lapply(entries, \(e) {
    pv <- e$port_visit
    tibble::as_tibble(c(
      list(event_id = chr(e$id), visit_id = chr(pv$visitId),
           vessel_id = vessel_id, MMSI = chr(e$vessel$ssvid),
           vessel_name = chr(e$vessel$name), start = chr(e$start), end = chr(e$end),
           confidence = chr(pv$confidence), duration_hrs = chr(pv$durationHrs)),
      anchorage(pv$startAnchorage, "start"),
      anchorage(pv$intermediateAnchorage, "int"),
      anchorage(pv$endAnchorage, "end"),
      list(dataset = dataset, pulled_on = as.character(pulled_on))))
  })
  out <- dplyr::bind_rows(rows)
  wrong <- setdiff(unique(out$MMSI), mmsi)
  if (length(wrong) > 0) {
    stop("vessel ID ", vessel_id, " was queried for MMSI ", mmsi,
         " but its events carry ", paste(wrong, collapse = ", "), call. = FALSE)
  }
  out[port_visit_cols]
}
