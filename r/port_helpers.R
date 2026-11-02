# Vessel home-port helpers for 03b_port_visits.qmd (D-080, D-081): typing and
# filtering the raw GFW port-visit events, assigning each visit to a port
# community by position, the home-port rule per MMSI x year and for Stage 1,
# and the checks against GARFO and on effort coverage. Source after the
# tidyverse, r/paths.R and r/gfw_helpers.R:
#   source("r/paths.R"); source("r/gfw_helpers.R"); source("r/port_helpers.R")
#
# The rules are fixed in planning/gfw_analysis_plan.qmd, @sec-ports, before any
# port-split result is seen. Their defaults live here as arguments so 03b can
# run the definition sensitivities (confidence 4 only, duration weighting)
# without editing a function. Port is never a model covariate (D-076): these
# tables feed the synthesis (14) and Phase 7 (13) only.

# D-080 defaults, in one place so 03b and the tests use the same numbers
port_rules <- list(
  min_confidence = 3,   # GFW port-visit confidence 3 or 4
  min_hours      = 2,   # at least 2 h in port (drops fuel, ice, weather stops)
  community_km   = 10,  # an anchorage within 10 km of a reference point is in that community
  region_km      = 50,  # beyond that but within 50 km: "other (<state>)"; farther: "outside region"
  min_visits     = 3,   # a home port needs at least 3 counted visits ...
  min_share      = 0.5, # ... and at least half of the unit's visits
  crs            = 32619 # UTM 19N, the project's metric CRS
)

# Label for a port outside every community but within region_km of one
other_port <- function(state) paste0("other (", state, ")")
outside_region <- "outside region"

# Reference points -----------------------------------------------------------

# references/port_communities.csv: one row per reference point (a harbour or
# village from USGS GNIS), several points per community where a community
# spans more than one harbour (e.g. New London / Mystic). `garfo_cities` lists
# the GARFO PRINCIPAL / HOME PORT CITY spellings nearest that point,
# '|'-separated, so a GARFO port maps to the same community as a GFW visit.
# Read and checked here, so a typo stops 03b instead of silently becoming
# "other".
read_port_communities <- function(path) {
  pc <- readr::read_csv(path, col_types = readr::cols(.default = "c", lat = "d", lon = "d"),
                        na = "", show_col_types = FALSE)
  stopifnot(
    "port_communities.csv is missing columns" =
      all(c("community", "state", "point", "lat", "lon", "gnis_id", "garfo_cities") %in% names(pc)),
    "every reference point needs a community, state and position" =
      !anyNA(pc[c("community", "state", "point", "lat", "lon")]),
    "states are two-letter codes" = all(grepl("^[A-Z]{2}$", pc$state)),
    "positions must be in the study region (lat 35-45, lon -77 to -66)" =
      all(dplyr::between(pc$lat, 35, 45) & dplyr::between(pc$lon, -77, -66)),
    "each community x point appears once" = !anyDuplicated(pc[c("community", "point")]))
  # a GARFO city (within its state) may belong to only one community
  cities <- garfo_city_lookup(pc)
  dup <- cities[duplicated(cities[c("city", "state")]), ]
  if (nrow(dup) > 0) {
    stop("GARFO cities listed under two communities: ",
         paste(dup$city, dup$state, collapse = ", "), call. = FALSE)
  }
  pc
}

# The GARFO city spellings as a lookup table: city, state, community
garfo_city_lookup <- function(communities) {
  communities |>
    dplyr::filter(!is.na(garfo_cities), garfo_cities != "") |>
    dplyr::select(community, state, garfo_cities) |>
    tidyr::separate_longer_delim(garfo_cities, "|") |>
    dplyr::transmute(city = stringr::str_squish(toupper(garfo_cities)), state, community)
}

# references/port_anchorages.csv: hand-curated anchorage ID -> community
# overrides, each with a reason and a source (e.g. an anchorage the distance
# rule puts in the wrong community). Every override must name a community in
# the reference points, or one of the "other"/"outside region" labels.
read_port_anchorages <- function(path, communities) {
  pa <- readr::read_csv(path, col_types = readr::cols(.default = "c"), na = "",
                        show_col_types = FALSE)
  stopifnot(
    "port_anchorages.csv is missing columns" =
      all(c("anchorage_id", "label", "community", "reason", "source") %in% names(pa)),
    "each anchorage is overridden once" = !anyDuplicated(pa$anchorage_id),
    "every override needs a reason and a source" = !anyNA(pa[c("reason", "source")]))
  allowed <- c(unique(communities$community), other_port(unique(communities$state)),
               outside_region)
  bad <- setdiff(pa$community, allowed)
  if (length(bad) > 0) {
    stop("port_anchorages.csv names unknown communities: ", paste(bad, collapse = ", "),
         call. = FALSE)
  }
  pa
}

# Visits ---------------------------------------------------------------------

# The raw cache (all character, as parse_port_visits() writes it) -> typed
# visits that count under the rules: confidence >= min_confidence and at
# least min_hours in port. Adds `year` (calendar year of the visit's start)
# and the position used to place the visit: the intermediate anchorage's,
# else the start anchorage's when GFW gives no intermediate one. A visit
# returned twice is kept once: re-pulls append, so the same event can be
# cached twice, and two vessel IDs of one MMSI that overlap in time can each
# return the same visit under a different event ID (same start and anchorage).
port_visit_filter <- function(raw, min_confidence = port_rules$min_confidence,
                              min_hours = port_rules$min_hours) {
  raw |>
    dplyr::distinct(MMSI, event_id, .keep_all = TRUE) |>
    dplyr::distinct(MMSI, start, int_anchorage_id, start_anchorage_id, .keep_all = TRUE) |>
    dplyr::mutate(
      start = lubridate::ymd_hms(start, quiet = TRUE),
      end = lubridate::ymd_hms(end, quiet = TRUE),
      confidence = as.integer(confidence),
      duration_hrs = as.numeric(duration_hrs),
      year = lubridate::year(start),
      anchorage_id = dplyr::coalesce(int_anchorage_id, start_anchorage_id),
      anchorage_label = dplyr::coalesce(int_label, start_label),
      lat = as.numeric(dplyr::coalesce(int_lat, start_lat)),
      lon = as.numeric(dplyr::coalesce(int_lon, start_lon))) |>
    dplyr::filter(confidence >= min_confidence, duration_hrs >= min_hours)
}

# Port community of each visit, from its anchorage's position (not its label,
# which can be wrong: probe, 2026-11-01). Each distinct anchorage goes to the
# nearest reference point; within community_km it takes that point's
# community; within region_km, "other (<state of the nearest point>)"; else
# "outside region". An override in `overrides` (read_port_anchorages()) wins
# over the distance rule. Adds community, port_state, port_km (distance to
# the nearest reference point) and port_rule ("distance", "other", "outside",
# "override" or "no position").
assign_port_community <- function(visits, communities, overrides = NULL,
                                  community_km = port_rules$community_km,
                                  region_km = port_rules$region_km,
                                  crs = port_rules$crs) {
  anch <- visits |>
    dplyr::filter(!is.na(lat), !is.na(lon)) |>
    dplyr::distinct(anchorage_id, lat, lon)

  placed <- if (nrow(anch) > 0) {
    to_m <- function(d) sf::st_transform(sf::st_as_sf(d, coords = c("lon", "lat"), crs = 4326,
                                                      remove = FALSE), crs)
    km <- units::drop_units(sf::st_distance(to_m(anch), to_m(communities))) / 1000
    nearest <- apply(km, 1, which.min)
    anch |>
      dplyr::mutate(
        port_km = km[cbind(seq_along(nearest), nearest)],
        near_community = communities$community[nearest],
        near_state = communities$state[nearest],
        port_rule = dplyr::case_when(port_km <= community_km ~ "distance",
                                     port_km <= region_km ~ "other",
                                     TRUE ~ "outside"),
        community = dplyr::case_when(port_rule == "distance" ~ near_community,
                                     port_rule == "other" ~ other_port(near_state),
                                     TRUE ~ outside_region),
        port_state = dplyr::if_else(port_rule == "outside", NA_character_, near_state)) |>
      dplyr::select(anchorage_id, lat, lon, community, port_state, port_km, port_rule)
  } else {
    tibble::tibble(anchorage_id = character(), lat = numeric(), lon = numeric(),
                   community = character(), port_state = character(),
                   port_km = numeric(), port_rule = character())
  }

  # hand overrides by anchorage ID; the state follows the overriding community
  if (!is.null(overrides) && nrow(overrides) > 0) {
    state_of <- dplyr::distinct(communities, community, state)
    ov <- overrides |>
      dplyr::select(anchorage_id, ov_community = community) |>
      dplyr::left_join(dplyr::rename(state_of, ov_state = state),
                       by = c(ov_community = "community"))
    placed <- placed |>
      dplyr::left_join(ov, by = "anchorage_id") |>
      dplyr::mutate(
        port_rule = dplyr::if_else(is.na(ov_community), port_rule, "override"),
        port_state = dplyr::case_when(
          is.na(ov_community) ~ port_state,
          !is.na(ov_state) ~ ov_state,
          ov_community == outside_region ~ NA_character_,
          # "other (RI)" -> RI
          TRUE ~ sub("^other \\(([A-Z]{2})\\)$", "\\1", ov_community)),
        community = dplyr::coalesce(ov_community, community)) |>
      dplyr::select(-ov_community, -ov_state)
  }

  visits |>
    dplyr::left_join(placed, by = c("anchorage_id", "lat", "lon")) |>
    dplyr::mutate(port_rule = dplyr::coalesce(port_rule, "no position"))
}

# Home port ------------------------------------------------------------------

# Home port per unit (by default MMSI x year) from assigned visits. The unit's
# top community is its home port ("port") if it has at least min_visits
# counted visits and at least min_share of the unit's visits (or of its
# hours in port, with weight = "duration_hrs", the duration sensitivity),
# and no other community ties it; a unit with fewer than min_visits visits in
# all is "unknown", and any other unit "multiple". Visits without a position
# are not counted. Returns the unit columns, community (the home port, NA
# unless status is "port"), top_community, port_state, visits, share, status.
home_port_of <- function(visits, by = c("MMSI", "year"),
                         min_visits = port_rules$min_visits,
                         min_share = port_rules$min_share, weight = NULL) {
  v <- dplyr::filter(visits, !is.na(community))
  v$w <- if (is.null(weight)) 1 else v[[weight]]
  v |>
    dplyr::group_by(dplyr::across(dplyr::all_of(c(by, "community")))) |>
    dplyr::summarise(n = dplyr::n(), w = sum(w), port_state = dplyr::first(port_state),
                     .groups = "drop") |>
    dplyr::group_by(dplyr::across(dplyr::all_of(by))) |>
    dplyr::arrange(dplyr::desc(w), dplyr::desc(n), .by_group = TRUE) |>
    dplyr::summarise(
      top_community = dplyr::first(community),
      port_state = dplyr::first(port_state),
      top_visits = dplyr::first(n),
      visits = sum(n),
      share = dplyr::first(w) / sum(w),
      # a tie for the top weight means no single dominant port
      tied = sum(w == max(w)) > 1,
      .groups = "drop") |>
    dplyr::mutate(
      status = dplyr::case_when(visits < min_visits ~ "unknown",
                                top_visits >= min_visits & share >= min_share & !tied ~ "port",
                                TRUE ~ "multiple"),
      community = dplyr::if_else(status == "port", top_community, NA_character_),
      port_state = dplyr::if_else(status == "port", port_state, NA_character_)) |>
    dplyr::select(dplyr::all_of(by), community, top_community, port_state, visits, share, status)
}

# The Stage 1 port group per MMSI, for Phase 7 (D-080): the home-port rule
# over every counted visit from Stage 1 (stage1_start to stage1_end). A
# vessel first active after Stage 1 (per `first_active`, MMSI -> first date
# in the pull) is grouped from the visits in its first 12 months instead, and
# flagged, since its port is measured after the projects began.
# Returns MMSI, community, top_community, port_state, visits, share, status,
# window ("stage1" or "first_12_months"), window_start, window_end.
home_port_stage1 <- function(visits, first_active,
                             stage1_start = dev_stages$start[1],
                             stage1_end = dev_stages$end[1], ...) {
  win <- first_active |>
    dplyr::transmute(
      MMSI,
      window = dplyr::if_else(as.Date(first) <= stage1_end, "stage1", "first_12_months"),
      window_start = dplyr::if_else(window == "stage1", as.Date(stage1_start), as.Date(first)),
      window_end = dplyr::if_else(window == "stage1", as.Date(stage1_end),
                                  as.Date(first) + lubridate::years(1) - 1))
  in_window <- visits |>
    dplyr::inner_join(win, by = "MMSI") |>
    dplyr::filter(as.Date(start) >= window_start, as.Date(start) <= window_end)
  # every vessel gets a row: one with no visits in its window is "unknown"
  home_port_of(in_window, by = "MMSI", ...) |>
    dplyr::right_join(win, by = "MMSI") |>
    dplyr::mutate(visits = dplyr::coalesce(visits, 0L),
                  status = dplyr::coalesce(status, "unknown")) |>
    dplyr::arrange(MMSI)
}

# Checks ---------------------------------------------------------------------

# GARFO port city + state -> port community, through the garfo_cities column
# of the reference points. A city not listed is "other (<state>)" if its
# state has a community, else "outside region"; a blank city is NA.
garfo_port_community <- function(city, state, communities) {
  lookup <- garfo_city_lookup(communities)
  key <- tibble::tibble(city = stringr::str_squish(toupper(city)), state = toupper(state))
  hit <- dplyr::left_join(key, lookup, by = c("city", "state"))$community
  dplyr::case_when(!is.na(hit) ~ hit,
                   is.na(key$city) | key$city == "" ~ NA_character_,
                   key$state %in% communities$state ~ other_port(key$state),
                   TRUE ~ outside_region)
}

# GFW home port vs GARFO, per MMSI x year. `gfw` is home_port_of() by MMSI x
# year; `garfo` has MMSI, year and the GARFO principal and home port city and
# state (one row per MMSI x permit year, from 03's unique name matches only).
# Returns the joined rows with each GARFO port as a community and whether it
# agrees with GFW's home port (NA where either side has no port), so 03b can
# report agreement rates and a confusion table.
port_agreement <- function(gfw, garfo, communities) {
  garfo |>
    dplyr::mutate(
      garfo_principal = garfo_port_community(principal_port_city, principal_port_state, communities),
      garfo_home = garfo_port_community(home_port_city, home_port_state, communities)) |>
    dplyr::inner_join(dplyr::select(gfw, MMSI, year, gfw_port = community, gfw_status = status),
                      by = c("MMSI", "year")) |>
    dplyr::mutate(
      agree_principal = dplyr::if_else(is.na(gfw_port) | is.na(garfo_principal), NA,
                                       gfw_port == garfo_principal),
      agree_home = dplyr::if_else(is.na(gfw_port) | is.na(garfo_home), NA,
                                  gfw_port == garfo_home))
}

# Crosswalk windows outside Primary (D-086) ---------------------------------
#
# A vessel's port visits during a charter (e.g. a safety vessel staged near
# the leases) say where its charter work was based, not its fishing port. So
# 03b drops visits, and effort hours, that fall in a crosswalk window that
# takes the vessel out of Primary, the same windows classify() applies
# (r/vessel_helpers.R): activity_excluded, or a non_fishing or gear_marker
# hull. Open window ends run to lo_date / hi_date, as in classify().

# The typed crosswalk (type_crosswalk()) -> MMSI, from, to of every window
# outside Primary
non_primary_windows <- function(cw) {
  cw |>
    dplyr::filter(activity_excluded %in% TRUE |
                    hull_class %in% c("non_fishing", "gear_marker")) |>
    dplyr::transmute(MMSI, from = dplyr::coalesce(valid_from, lo_date),
                     to = dplyr::coalesce(valid_to, hi_date))
}

# TRUE for each row of `df` whose `date_col` (a Date, or a time read as its
# UTC date) falls in one of its MMSI's windows
in_window <- function(df, windows, date_col) {
  if (nrow(df) == 0) return(logical())
  key <- tibble::tibble(.row = seq_len(nrow(df)), MMSI = df$MMSI,
                        .d = as.Date(df[[date_col]]))
  hit <- dplyr::inner_join(key, windows,
                           by = dplyr::join_by(MMSI, dplyr::between(.d, from, to)))
  key$.row %in% hit$.row
}

# Vessel-years whose counted visits all fell in a window outside Primary, as
# home-port rows with status "excluded" (no community), so the per-year
# table says why the year has no port instead of leaving it out. `dropped`
# are the visits removed for a window; `port_year` the home ports from the
# rest. A year with visits both inside and outside a window keeps the port
# its outside visits give.
excluded_port_years <- function(dropped, port_year) {
  dropped |>
    dplyr::count(MMSI, year, name = "visits") |>
    dplyr::anti_join(port_year, by = c("MMSI", "year")) |>
    dplyr::mutate(community = NA_character_, top_community = NA_character_,
                  port_state = NA_character_, share = NA_real_, status = "excluded") |>
    dplyr::select(dplyr::all_of(names(port_year)))
}

# GARFO port review findings (D-085) ----------------------------------------
#
# The GARFO review sheet (03b) is regenerated on every render, so findings
# are kept in references/port_garfo_findings.csv, one row per MMSI, shared by
# every pipeline version (the finding is about a vessel and its GARFO hull,
# not about a pull). 03b copies new findings from the sheet into the file;
# 03 reads `wrong_hull` findings and drops those links from the permit groups
# and garfo_match.csv, as D-084 does for links PSIX contradicts.

port_finding_cols <- c("MMSI", "Vessel_Name", "finding", "note", "checked_on")

# The allowed findings and what each means:
#   declared_port_differs  right hull; the vessel lands away from its declared
#                          GARFO port (descriptive; supports GFW as the source)
#   wrong_hull             the MMSI is not the GARFO hull (link dropped by 03)
#   gfw_port_wrong         GFW's port is wrong, e.g. a mislabelled anchorage
#                          (fix with an override in port_anchorages.csv)
#   seasonal               the vessel moves between ports with the season;
#                          both sources are right (descriptive)
#   unresolved             checked, but the evidence does not settle it
port_finding_values <- c("declared_port_differs", "wrong_hull", "gfw_port_wrong",
                         "seasonal", "unresolved")

# Checks a findings table (all character columns); stops naming the problem
validate_port_findings <- function(f, source = "port_garfo_findings.csv") {
  missing <- setdiff(port_finding_cols, names(f))
  if (length(missing) > 0) {
    stop(source, " is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  bad <- setdiff(f$finding, port_finding_values)
  if (length(bad) > 0) {
    stop(source, " has unknown findings: ", paste(bad, collapse = ", "),
         " (allowed: ", paste(port_finding_values, collapse = ", "), ")", call. = FALSE)
  }
  if (anyDuplicated(f$MMSI)) {
    stop(source, " lists an MMSI twice: ",
         paste(unique(f$MMSI[duplicated(f$MMSI)]), collapse = ", "), call. = FALSE)
  }
  if (any(f$finding %in% "wrong_hull" & is.na(f$note))) {
    stop(source, ": a wrong_hull finding needs a note giving the evidence", call. = FALSE)
  }
  invisible(f)
}

# Copies the rows with a `finding` in the review sheet into the findings
# file, skipping MMSIs the file already has (edit the file itself to change
# a finding), and returns the file's table. A blank checked_on becomes
# today. Mirrors collect_marked() in r/review_helpers.R for vessel decisions.
collect_port_findings <- function(sheet, input) {
  read <- \(p) readr::read_csv(p, col_types = readr::cols(.default = "c"), na = c("", "NA"),
                               show_col_types = FALSE)
  current <- if (file.exists(input)) read(input) else
    tibble::as_tibble(stats::setNames(rep(list(character()), length(port_finding_cols)),
                                      port_finding_cols))
  validate_port_findings(current, basename(input))

  if (file.exists(sheet)) {
    s <- read(sheet)
    for (col in setdiff(port_finding_cols, names(s))) s[[col]] <- NA_character_
    marked <- s |>
      dplyr::mutate(finding = stringr::str_trim(finding)) |>
      dplyr::filter(!is.na(finding), finding != "") |>
      dplyr::mutate(checked_on = dplyr::coalesce(checked_on, as.character(Sys.Date()))) |>
      dplyr::select(dplyr::all_of(port_finding_cols))
    validate_port_findings(marked, basename(sheet))

    new_rows <- dplyr::anti_join(marked, current, by = "MMSI")
    if (nrow(new_rows) > 0) {
      current <- dplyr::bind_rows(current, new_rows) |> dplyr::arrange(MMSI)
      readr::write_csv(current, input, na = "")
      message("Added ", nrow(new_rows), " findings to ", input)
    }
  }
  current
}

# Share of effort hours whose vessel has a home port, per group. `hours` has
# MMSI, the `join` columns, the `by` columns and `hours`; `ports` is a
# home-port table keyed by `join` (by default MMSI x year). Returns the `by`
# columns, hours, hours_with_port and coverage (their ratio). A vessel absent
# from `ports` counts as having no port.
port_coverage <- function(hours, ports, by = c("gear_class", "stage"),
                          join = c("MMSI", "year")) {
  hours |>
    dplyr::left_join(dplyr::select(ports, dplyr::all_of(join), status), by = join) |>
    dplyr::group_by(dplyr::across(dplyr::all_of(by))) |>
    dplyr::summarise(hours_with_port = sum(hours[status %in% "port"]),
                     hours = sum(hours), .groups = "drop") |>
    dplyr::mutate(coverage = hours_with_port / hours) |>
    dplyr::relocate(hours, .before = hours_with_port)
}
