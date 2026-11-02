# r/port_helpers.R: vessel home ports from GFW port visits (D-080, D-081).
# Synthetic visits only; no GFW data or API calls.

# three communities, one with two reference points (as New London / Mystic)
test_communities <- function() {
  tribble(
    ~community,             ~state, ~point,              ~lat,    ~lon,     ~gnis_id, ~garfo_cities,
    "Point Judith / Galilee", "RI", "Galilee",           41.3772, -71.5103, "1",      "POINT JUDITH|GALILEE",
    "Newport",              "RI",   "Newport Harbor",    41.4826, -71.3256, "2",      "NEWPORT",
    "New London / Mystic",  "CT",   "New London Harbor", 41.3345, -72.0906, "3",      "NEW LONDON|GROTON",
    "New London / Mystic",  "CT",   "Mystic",            41.3543, -71.9665, "4",      "MYSTIC")
}

# raw cache rows (all character, as parse_port_visits() writes them); one
# visit per row of the arguments, with the intermediate anchorage given
raw_visits <- function(MMSI, start, int_anchorage_id, int_lat, int_lon,
                       confidence = "4", duration_hrs = "10", int_label = "usa-x") {
  n <- max(lengths(list(MMSI, start, int_anchorage_id, confidence, duration_hrs)))
  d <- tibble(MMSI = rep_len(MMSI, n), start = rep_len(start, n),
              int_anchorage_id = rep_len(int_anchorage_id, n),
              int_lat = as.character(rep_len(int_lat, n)), int_lon = as.character(rep_len(int_lon, n)),
              confidence = rep_len(confidence, n), duration_hrs = rep_len(duration_hrs, n),
              int_label = rep_len(int_label, n))
  d$event_id <- paste0("e", seq_len(n))
  d$end <- d$start
  for (col in setdiff(port_visit_cols, names(d))) d[[col]] <- NA_character_
  d[port_visit_cols]
}

test_that("read_port_communities() checks the schema and GARFO city uniqueness", {
  f <- tempfile(fileext = ".csv")
  pc <- test_communities()
  write_csv(pc, f, na = "")
  expect_equal(nrow(read_port_communities(f)), 4)

  # a GARFO city under two communities in the same state is refused
  bad <- pc; bad$garfo_cities[2] <- "NEWPORT|GALILEE"
  write_csv(bad, f, na = "")
  expect_error(read_port_communities(f), "GALILEE RI")
  # a position outside the study region (e.g. a sign error) is refused
  bad <- pc; bad$lon[1] <- 71.5103
  write_csv(bad, f, na = "")
  expect_error(read_port_communities(f), "study region")
})

test_that("port_visit_filter() keeps confidence 3-4 and >= 2 h, once per event", {
  raw <- raw_visits("1", "2019-05-01T10:00:00.000Z", "a1", 41.37, -71.51,
                    confidence = c("4", "3", "2", "4"), duration_hrs = c("2", "5", "9", "1.9"))
  raw <- raw |> mutate(start = sprintf("2019-05-0%dT10:00:00.000Z", 1:4))
  raw <- bind_rows(raw, raw[1, ])   # a re-pull caches the same event twice
  # a second vessel ID of the same MMSI returns visit e2 under another event ID
  raw <- bind_rows(raw, mutate(raw[2, ], event_id = "e9", vessel_id = "other-id"))
  v <- port_visit_filter(raw)
  expect_equal(v$event_id, c("e1", "e2"))
  expect_equal(v$year, c(2019, 2019))
  expect_equal(v$lat, c(41.37, 41.37))
  # the confidence-4-only sensitivity
  expect_equal(port_visit_filter(raw, min_confidence = 4)$event_id, "e1")
})

test_that("port_visit_filter() places a visit at its start anchorage when there is no intermediate one", {
  raw <- raw_visits("1", "2019-05-01T10:00:00.000Z", NA, NA, NA)
  raw$start_anchorage_id <- "s1"; raw$start_lat <- "41.48"; raw$start_lon <- "-71.33"
  v <- port_visit_filter(raw)
  expect_equal(v$anchorage_id, "s1")
  expect_equal(v$lon, -71.33)
})

test_that("assign_port_community() goes by position, not label", {
  pc <- test_communities()
  raw <- raw_visits("1", "2019-05-01T10:00:00.000Z",
                    int_anchorage_id = c("a1", "a2", "a3", "a4", "a5"),
                    # Galilee; a mislabel at Newport (as LAHAINA at Shinnecock);
                    # an unnamed anchorage off Mystic; ~25 km out from Galilee;
                    # far away (Boston)
                    int_lat = c(41.378, 41.483, 41.350, 41.15, 42.35),
                    int_lon = c(-71.512, -71.327, -71.970, -71.51, -71.05),
                    int_label = c("usa-judithpoint", "usa-lahainaanchorage", "usa-usa-1225",
                                  "usa-x", "usa-boston"))
  a <- assign_port_community(port_visit_filter(raw), pc)
  expect_equal(a$community, c("Point Judith / Galilee", "Newport", "New London / Mystic",
                              "other (RI)", "outside region"))
  expect_equal(a$port_rule, c("distance", "distance", "distance", "other", "outside"))
  expect_equal(a$port_state, c("RI", "RI", "CT", "RI", NA))
  expect_lt(a$port_km[1], 1)
})

test_that("assign_port_community() applies overrides by anchorage ID", {
  pc <- test_communities()
  raw <- raw_visits("1", "2019-05-01T10:00:00.000Z", c("a1", "a4"),
                    c(41.378, 41.15), c(-71.512, -71.51))
  ov <- tibble(anchorage_id = c("a1", "a4"), label = "x",
               community = c("Newport", "other (CT)"), reason = "test", source = "test")
  a <- assign_port_community(port_visit_filter(raw), pc, ov)
  expect_equal(a$community, c("Newport", "other (CT)"))
  expect_equal(a$port_state, c("RI", "CT"))
  expect_equal(a$port_rule, c("override", "override"))
  # an override naming a community that is not in the reference points is refused
  f <- tempfile(fileext = ".csv")
  write_csv(mutate(ov, community = "Atlantis"), f)
  expect_error(read_port_anchorages(f, pc), "unknown communities: Atlantis")
})

# assigned visits for the home-port tests: MMSI, year, community, port_state
assigned <- function(MMSI, year, community, duration_hrs = 10, start = NULL) {
  tibble(MMSI, year, community, duration_hrs,
         start = start %||% as.POSIXct(sprintf("%d-06-01", year), tz = "UTC"),
         port_state = if_else(community == "Newport", "RI", "CT"))
}

test_that("home_port_of() applies the 3-visit and 50% rule", {
  v <- bind_rows(
    assigned("1", 2019, c(rep("Newport", 3), "New London / Mystic")),    # 3 of 4: port
    assigned("2", 2019, c(rep("Newport", 2), rep("New London / Mystic", 2), "x")), # tie: multiple
    assigned("3", 2019, c("Newport", "Newport")),                        # 2 visits: unknown
    assigned("4", 2019, c(rep("Newport", 3), rep("New London / Mystic", 2), "x", "y")), # 3/7: multiple
    assigned("5", 2019, c("Newport", "Newport", "x", "y")))              # top has 2 visits: multiple
  h <- home_port_of(v)
  expect_equal(h$status, c("port", "multiple", "unknown", "multiple", "multiple"))
  expect_equal(h$community, c("Newport", NA, NA, NA, NA))
  expect_equal(h$share[1], 0.75)
  expect_equal(h$visits, c(4L, 5L, 2L, 7L, 4L))
})

test_that("home_port_of() weights by duration for the sensitivity", {
  v <- assigned("1", 2019, c(rep("Newport", 3), rep("New London / Mystic", 3)),
                duration_hrs = c(1, 1, 1, 30, 30, 30))
  expect_equal(home_port_of(v)$status, "multiple")   # counted: a 3-3 tie
  w <- home_port_of(v, weight = "duration_hrs")
  expect_equal(w$community, "New London / Mystic")
  expect_equal(w$share, 90 / 93)
})

test_that("home_port_stage1() uses Stage 1, or a later vessel's first 12 months", {
  v <- bind_rows(
    # vessel 1: Newport in Stage 1, New London afterwards (a post-treatment change)
    assigned("1", 2018, rep("Newport", 4)),
    assigned("1", 2022, rep("New London / Mystic", 9)),
    # vessel 2: first active 2021-03; New London in its first year, Newport later
    assigned("2", 2021, rep("New London / Mystic", 3),
             start = as.POSIXct("2021-07-01", tz = "UTC")),
    assigned("2", 2023, rep("Newport", 5)))
  first <- tibble(MMSI = c("1", "2", "3"), first = c("2016-02-01", "2021-03-01", "2017-01-01"))
  s <- home_port_stage1(v, first)
  expect_equal(s$community, c("Newport", "New London / Mystic", NA))
  expect_equal(s$window, c("stage1", "first_12_months", "stage1"))
  expect_equal(s$window_end[2], as.Date("2022-02-28"))
  # a vessel with no visits in its window is unknown, not dropped
  expect_equal(s$status[3], "unknown")
  expect_equal(s$visits[3], 0L)
})

test_that("garfo_port_community() maps GARFO spellings to communities", {
  pc <- test_communities()
  expect_equal(garfo_port_community(c("Point Judith ", "GROTON", "STONINGTON", "GLOUCESTER", NA),
                                    c("RI", "CT", "CT", "MA", "RI"), pc),
               c("Point Judith / Galilee", "New London / Mystic", "other (CT)",
                 "outside region", NA))
  # the same city name in another state is not that community
  expect_equal(garfo_port_community("NEWPORT", "NY", pc), "outside region")
})

test_that("port_agreement() compares GFW and GARFO ports per MMSI x year", {
  pc <- test_communities()
  gfw <- tibble(MMSI = c("1", "2", "3"), year = 2019,
                community = c("Newport", "Newport", NA), status = c("port", "port", "multiple"))
  garfo <- tibble(MMSI = c("1", "2", "3"), year = 2019,
                  principal_port_city = c("NEWPORT", "MYSTIC", "NEWPORT"),
                  principal_port_state = c("RI", "CT", "RI"),
                  home_port_city = c("NEWPORT", "NEWPORT", "NEWPORT"),
                  home_port_state = "RI")
  a <- port_agreement(gfw, garfo, pc)
  expect_equal(a$agree_principal, c(TRUE, FALSE, NA))
  expect_equal(a$agree_home, c(TRUE, TRUE, NA))
  expect_equal(a$garfo_principal[2], "New London / Mystic")
})

test_that("port_coverage() gives the share of hours with a known port", {
  hours <- tibble(MMSI = c("1", "2", "3"), year = 2019, gear_class = "FIXED",
                  stage = "Stage 1", hours = c(60, 30, 10))
  ports <- tibble(MMSI = c("1", "2"), year = 2019, status = c("port", "multiple"))
  cv <- port_coverage(hours, ports)
  expect_equal(cv$hours, 100)
  expect_equal(cv$hours_with_port, 60)
  expect_equal(cv$coverage, 0.6)
})

# GARFO port review findings (D-085) -----------------------------------------

# a review sheet with the findings columns first, as 03b writes it
test_sheet <- function(path, finding, note = NA_character_, checked_on = NA_character_) {
  write_csv(tibble(MMSI = c("1", "2", "3"), Vessel_Name = c("A", "B", "C"), finding, note,
                   checked_on, link_tier = "name_only", vp_hours = "10"), path, na = "")
}

test_that("collect_port_findings() copies marked rows and keeps existing ones", {
  sheet <- tempfile(fileext = ".csv"); input <- tempfile(fileext = ".csv")
  test_sheet(sheet, c("declared_port_differs", NA, "wrong_hull"),
             note = c(NA, NA, "PSIX call sign is another hull"))
  f <- collect_port_findings(sheet, input)
  expect_equal(f$MMSI, c("1", "3"))
  expect_equal(names(f), port_finding_cols)
  expect_equal(f$checked_on, rep(as.character(Sys.Date()), 2))   # blank -> today
  expect_true(file.exists(input))

  # a second sheet: an MMSI already in the file is not overwritten
  test_sheet(sheet, c("seasonal", "unresolved", NA))
  f <- collect_port_findings(sheet, input)
  expect_equal(f$finding, c("declared_port_differs", "unresolved", "wrong_hull"))
})

test_that("collect_port_findings() refuses unknown findings and bare wrong_hull rows", {
  sheet <- tempfile(fileext = ".csv"); input <- tempfile(fileext = ".csv")
  test_sheet(sheet, c("wrong hull", NA, NA))
  expect_error(collect_port_findings(sheet, input), "unknown findings: wrong hull")
  test_sheet(sheet, c("wrong_hull", NA, NA))
  expect_error(collect_port_findings(sheet, input), "needs a note")
  expect_false(file.exists(input))   # nothing written when the sheet is invalid
})

test_that("collect_port_findings() works with no sheet and no file yet", {
  f <- collect_port_findings(tempfile(), tempfile())
  expect_equal(names(f), port_finding_cols)
  expect_equal(nrow(f), 0)
})

# Crosswalk windows outside Primary (D-086) ----------------------------------

test_that("non_primary_windows() keeps charters, non-fishing hulls and gear markers", {
  cw <- bind_rows(
    cw_row("1", valid_from = "2021-05-01", activity_excluded = TRUE),   # open-ended charter
    cw_row("2", hull_class = "non_fishing"),                            # whole record
    cw_row("3", valid_from = "2020-01-01", valid_to = "2020-12-31"),    # fishing, kept in
    cw_row("4", hull_class = "gear_marker"))
  w <- non_primary_windows(cw)
  expect_equal(w$MMSI, c("1", "2", "4"))
  expect_equal(w$from, c(as.Date("2021-05-01"), lo_date, lo_date))
  expect_equal(w$to, rep(hi_date, 3))
})

test_that("in_window() flags rows inside their own MMSI's window only", {
  w <- tibble(MMSI = "1", from = as.Date("2021-05-01"), to = as.Date("2021-12-31"))
  d <- tibble(MMSI = c("1", "1", "1", "2"),
              start = as.POSIXct(c("2021-04-30 23:00", "2021-05-01 01:00", "2022-01-01 00:00",
                                   "2021-06-01 00:00"), tz = "UTC"))
  expect_equal(in_window(d, w, "start"), c(FALSE, TRUE, FALSE, FALSE))
  expect_equal(in_window(d[0, ], w, "start"), logical())
})

test_that("excluded_port_years() lists years with only excluded visits", {
  port_year <- tibble(MMSI = "1", year = 2021, community = "Newport", top_community = "Newport",
                      port_state = "RI", visits = 4L, share = 1, status = "port")
  dropped <- tibble(MMSI = "1", year = c(2021, 2024, 2024))
  ex <- excluded_port_years(dropped, port_year)
  # 2021 keeps the port from its visits outside the window; 2024 is excluded
  expect_equal(ex$year, 2024)
  expect_equal(ex$status, "excluded")
  expect_equal(ex$visits, 2L)
  expect_true(is.na(ex$community))
  expect_equal(names(ex), names(port_year))
})

# assigned visits with an anchorage and its position, for the distance origin
anchored <- function(MMSI, year, community, anchorage_id, lat = 41.48, lon = -71.33) {
  tibble(MMSI, year, community, anchorage_id, lat, lon,
         duration_hrs = 10, port_state = "RI")
}

test_that("distance_origin() follows the D-088 rule for years without a port", {
  v <- bind_rows(
    # 1: a home port; a1 is its most-visited anchorage there
    anchored("1", 2019, "Newport", c("a1", "a1", "a1", "a2")),
    # 2: multiple, top community 3 of 7 visits with no tie
    anchored("2", 2019, c(rep("Newport", 3), rep("New London / Mystic", 2), "x", "y"),
             c("a1", "a1", "a1", "b1", "b1", "c1", "d1")),
    # 3: Stage 1 visits at b2 in New London, then a 2-2 tie in 2019
    anchored("3", 2018, "New London / Mystic", c("b2", "b2", "b2"), lat = 41.35, lon = -71.97),
    anchored("3", 2019, c("Newport", "Newport", "New London / Mystic", "New London / Mystic"),
             c("a1", "a1", "b1", "b1")))
  port_year <- home_port_of(v) |>
    bind_rows(tibble(MMSI = "3", year = 2021, status = "excluded"))  # D-086
  port_stage1 <- tibble(MMSI = c("1", "3", "4"), community = c("Newport", "New London / Mystic", NA),
                        status = c("port", "port", "unknown"))
  # vessel 4 has effort in 2020 but no visits and no Stage 1 port
  units <- tibble(MMSI = c("1", "2", "3", "3", "4"), year = c(2019, 2019, 2019, 2021, 2020))

  o <- distance_origin(units, port_year, port_stage1, v)
  expect_equal(o$origin_source, c("year", "top_community", "stage1", "stage1", "none"))
  expect_equal(o$origin_community,
               c("Newport", "Newport", "New London / Mystic", "New London / Mystic", NA))
  # the year's anchorage for rules 1-2; the vessel's over all years for Stage 1
  # (b2 has 3 visits against b1's 2)
  expect_equal(o$origin_anchorage_id, c("a1", "a1", "b2", "b2", NA))
  expect_equal(o$origin_lon[3], -71.97)
})

test_that("distance_origin() leaves a short multiple year to the Stage 1 port", {
  # the top community has only 2 visits: below min_visits, so no top_community
  v <- anchored("1", 2019, c("Newport", "Newport", "x", "y"), c("a1", "a1", "c1", "d1"))
  o <- distance_origin(tibble(MMSI = "1", year = 2019), home_port_of(v),
                       tibble(MMSI = "1", community = "Newport", status = "port"), v)
  expect_equal(o$origin_source, "stage1")
})

test_that("port_distance() weights the distance to effort by hours", {
  origins <- tibble(MMSI = c("1", "2"), year = 2019, origin_community = c("Newport", NA),
                    origin_source = c("year", "none"), origin_anchorage_id = c("a1", NA),
                    origin_lat = c(41, NA), origin_lon = c(-71, NA))
  # vessel 1: 1 h at the origin, 3 h 0.1 degree north (about 11.1 km)
  effort <- tibble(MMSI = c("1", "1", "2"), year = 2019, stage = "Stage 1", dataset = "VP",
                   lat = c(41, 41.1, 41), lon = -71, hours = c(1, 3, 5))
  d <- port_distance(effort, origins)
  expect_equal(d$hours, c(4, 5))
  expect_equal(d$mean_km[1], 0.75 * 11.12, tolerance = 0.01)
  # no origin: hours counted, no distance
  expect_equal(d$hours_with_origin, c(4, 0))
  expect_true(is.na(d$mean_km[2]))
  expect_equal(d$origin_source, c("year", "none"))
})
