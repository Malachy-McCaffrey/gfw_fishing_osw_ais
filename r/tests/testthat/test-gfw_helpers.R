test_that("stage_of() puts each boundary day in the right stage", {
  d <- as.Date(c("2015-12-31", "2016-01-01", "2020-09-30", "2020-10-01",
                 "2023-03-31", "2023-04-01", "2026-08-31", "2026-09-01", NA))
  expect_equal(stage_of(d),
               c(NA, "Stage 1", "Stage 1", "Stage 2", "Stage 2", "Stage 3",
                 "Stage 3", NA, NA))
})

test_that("stage months match the stage windows", {
  months <- with(dev_stages, (as.integer(format(end, "%Y")) - as.integer(format(start, "%Y"))) * 12 +
                   as.integer(format(end, "%m")) - as.integer(format(start, "%m")) + 1)
  expect_equal(dev_stages$months, months)
})

test_that("stages are contiguous and span the analysis window", {
  expect_equal(dev_stages$start[-1], dev_stages$end[-nrow(dev_stages)] + 1)
  expect_equal(analysis_start, as.Date("2016-01-01"))
  expect_equal(analysis_end, as.Date("2026-08-31"))
})

test_that("in_analysis_window() drops records outside the window and says so", {
  d <- tibble(date = as.Date(c("2015-12-31", "2016-01-01", "2026-08-31", "2026-09-01", NA)))
  expect_message(out <- in_analysis_window(d), "Dropped 3 records")
  expect_equal(out$date, as.Date(c("2016-01-01", "2026-08-31")))
  expect_silent(in_analysis_window(out))
})

test_that("read_gfw() snaps float32-noisy lower-left corners with round()", {
  path <- write_raw(Lat = c(41.0699999, 41.07, 40.999999),
                    Lon = c(-71.209999, -71.21, -71.0000001),
                    `Time Range` = c("2020-09-30", "2020-10-01", "2026-08-15"),
                    MMSI = c("012345678", "367000001", "367000002"))
  d <- read_gfw(path)
  expect_equal(d$iy, c(4107L, 4107L, 4100L))
  expect_equal(d$ix, c(-7121L, -7121L, -7100L))
  expect_equal(d$cell_id, c("-7121_4107", "-7121_4107", "-7100_4100"))
  # floor() would have put the first record one cell south and east
  expect_false(floor(41.0699999 / 0.01) == d$iy[1])
})

test_that("read_gfw() keeps IDs as text and derives month and stage", {
  path <- write_raw(Lat = 41, Lon = -71, `Time Range` = "2020-10-15",
                    MMSI = "012345678", `Development Stage` = "Stage 1")
  d <- read_gfw(path)
  expect_identical(d$MMSI, "012345678")
  expect_equal(d$`Year Month`, as.Date("2020-10-01"))
  # recomputed from the date, whatever the file says
  expect_equal(d$`Development Stage`, "Stage 2")
  expect_equal(d$hours, 1)
})

test_that("read_gfw() needs exactly one hours column", {
  path <- write_raw(Lat = 41, Lon = -71, `Time Range` = "2020-10-15",
                    `Apparent Fishing Hours` = 2)
  expect_error(read_gfw(path), "exactly one hours column")
})

test_that("gear_class_of() maps GFW gear and leaves the rest unresolved", {
  expect_equal(gear_class_of(c("TRAWLERS", "POTS_AND_TRAPS", "POLE_AND_LINE",
                               "FISHING", "INCONCLUSIVE", NA)),
               c("MOBILE", "FIXED", "POLE_AND_LINE", "UNRESOLVED", "UNRESOLVED", "UNRESOLVED"))
})

# Pinned 4Wings pulls: built requests only, nothing is sent ------------------

# a small AOI-like polygon in WGS 84, as 01 passes the Ørsted AOI
test_region <- function() {
  sf::st_sf(geometry = sf::st_sfc(sf::st_polygon(list(rbind(
    c(-71.5, 41.0), c(-71.0, 41.0), c(-71.0, 41.3), c(-71.5, 41.3), c(-71.5, 41.0)))),
    crs = 4326))
}

test_that("gfw_dataset_id() pins a release and refuses latest", {
  expect_equal(gfw_dataset_id("presence", "v5.0"), "public-global-presence:v5.0")
  expect_equal(gfw_dataset_id("fishing-effort", "v4.0"), "public-global-fishing-effort:v4.0")
  expect_error(gfw_dataset_id("presence", "latest"), "must look like v5.0")
  expect_error(gfw_dataset_id("presence", "v5"), "must look like v5.0")
  expect_error(gfw_dataset_id("events", "v5.0"))
})

test_that("gfw_4wings_request() sends what gfwr sends, with the dataset version pinned", {
  args <- list(`spatial-resolution` = "HIGH", `temporal-resolution` = "DAILY",
               `filters[0]` = NULL, `group-by` = "VESSEL_ID",
               `date-range` = "2020-01-01,2021-01-01", format = "CSV")
  # gfwr's internal dataset type for each 4Wings dataset
  types <- c(presence = "raster-pres", `fishing-effort` = "raster")
  for (ds in names(types)) {
    # gfwr builds the URL for ":latest"; ours, asked for ":latest", must equal it
    theirs <- do.call(gfwr:::gfw_endpoint, c(list(dataset_type = types[[ds]]), args))
    latest <- sprintf("public-global-%s:latest", ds)
    ours <- gfw_4wings_request(latest, "2020-01-01", "2021-01-01", test_region(), key = "k")
    expect_equal(ours$url, theirs$url)
  }
  pinned <- gfw_4wings_request(gfw_dataset_id("presence", "v5.0"), "2020-01-01", "2021-01-01",
                               test_region(), key = "k")
  expect_match(pinned$url, "datasets%5B0%5D=public-global-presence%3Av5.0", fixed = TRUE)
  expect_equal(pinned$body$data, gfwr:::sf_to_geojson(test_region(), endpoint = "raster"))
  expect_equal(pinned$options$useragent, gfwr::gfw_user_agent())
})

test_that("gfw_4wings_request() keeps gfwr's checks on dates and region", {
  expect_error(gfw_4wings_request("public-global-presence:v5.0", "2020-01-01", "2021-01-03",
                                  test_region(), key = "k"), "366 days or less")
  expect_error(gfw_4wings_request("public-global-presence:v5.0", "2020-01-01", "2021-01-01",
                                  sf::st_centroid(test_region()), key = "k"), "sf polygon")
})

test_that("pull_versions() finds pulls by their VP file and orders by version number", {
  root <- file.path(tempfile(), "gfw")
  for (v in c("v10", "v4", "v5")) {
    dir.create(file.path(root, v), recursive = TRUE)
    writeLines("x", file.path(root, v, "gfw_vp_id.csv"))
  }
  dir.create(file.path(root, "scratch"))          # no VP file: not a pull
  expect_equal(pull_versions(root), c("v4", "v5", "v10"))
})

test_that("union_grid_cells() unions cells across pulls and records which pull has each", {
  # float32-noisy corners must snap to the same cell as clean ones
  f4 <- write_raw(Lat = c(41.0699999, 41.25), Lon = c(-71.209999, -71.30))
  f5 <- write_raw(Lat = c("41.070000", "40.990000"), Lon = c("-71.210000", "-71.000000"))
  u <- union_grid_cells(c(v4 = f4, v5 = f5))
  expect_equal(nrow(u), 3)
  expect_equal(u$in_pulls[u$cell_id == "-7121_4107"], "v4;v5")
  expect_equal(u$in_pulls[u$cell_id == "-7130_4125"], "v4")
  expect_equal(u$in_pulls[u$cell_id == "-7100_4099"], "v5")
  expect_error(union_grid_cells(c(f4, f5)), "named by pipeline version")
})

# Pinned port-visit events: built requests and parsing only, nothing is sent --

test_that("port_visits_dataset() pins a release and refuses latest", {
  expect_equal(port_visits_dataset("v5.0"), "public-global-port-visits-events:v5.0")
  expect_error(port_visits_dataset("latest"), "must look like v5.0")
})

test_that("gfw_port_visits_request() asks the Events API for one pinned vessel ID", {
  r <- gfw_port_visits_request("abc-123", port_visits_dataset("v5.0"),
                               "2016-01-01", "2026-09-01", offset = 500, key = "k")
  expect_match(r$url, "^https://gateway.api.globalfishingwatch.org/v3/events[?]")
  expect_match(r$url, "datasets%5B0%5D=public-global-port-visits-events%3Av5.0", fixed = TRUE)
  expect_match(r$url, "vessels%5B0%5D=abc-123", fixed = TRUE)
  expect_match(r$url, "start-date=2016-01-01&end-date=2026-09-01&limit=500&offset=500", fixed = TRUE)
  # httr2 redacts the token in the request object; reveal it to check it
  expect_equal(httr2::req_get_headers(r, "reveal")$Authorization, "Bearer k")
  expect_null(r$body)   # a GET, unlike the 4Wings report
  expect_error(gfw_port_visits_request(c("a", "b"), "d", "2016-01-01", "2017-01-01"), "one vessel ID")
  expect_error(gfw_port_visits_request("a", "d", "2017-01-01", "2016-01-01"), "before end_date")
})

# one API entry shaped as the Events API returns it (probe, 2026-11-01)
api_entry <- function(ssvid = "367000001", id = "e1", int = list(
  anchorageId = "89e5be27", atDock = FALSE, id = "usa-judithpoint", lat = 41.37,
  lon = -71.51, name = "JUDITH POINT")) {
  list(id = id, start = "2018-06-01T10:00:00.000Z", end = "2018-06-02T08:00:00.000Z",
       vessel = list(id = "vid-1", name = "LADY X", ssvid = ssvid, type = "passenger"),
       port_visit = list(visitId = paste0("v", id), confidence = "4", durationHrs = 22,
                         startAnchorage = int, intermediateAnchorage = int,
                         endAnchorage = int))
}

test_that("parse_port_visits() keeps one character row per visit, with the dataset", {
  # an unnamed anchorage (name null in the JSON) gives NA, not a dropped column
  unnamed <- list(anchorageId = "aa11", atDock = TRUE, id = "usa-usa-1225",
                  lat = 41.3, lon = -72.1, name = NULL)
  p <- parse_port_visits(list(api_entry(), api_entry(id = "e2", int = unnamed)),
                         "vid-1", "367000001", "public-global-port-visits-events:v5.0",
                         pulled_on = as.Date("2026-11-01"))
  expect_equal(names(p), port_visit_cols)
  expect_true(all(map_lgl(p, is.character)))
  expect_equal(p$int_label, c("usa-judithpoint", "usa-usa-1225"))
  expect_equal(p$int_name, c("JUDITH POINT", NA))
  expect_equal(p$int_at_dock, c("FALSE", "TRUE"))
  expect_equal(unique(p$dataset), "public-global-port-visits-events:v5.0")
  expect_equal(unique(p$pulled_on), "2026-11-01")
  # the GFW vessel type is not kept (the roster's classification is used)
  expect_false(any(grepl("type", names(p))))
})

test_that("parse_port_visits() stops when an event belongs to another MMSI", {
  expect_error(parse_port_visits(list(api_entry(ssvid = "367999999")), "vid-1", "367000001", "d"),
               "queried for MMSI 367000001")
})

test_that("parse_port_visits() gives an empty table with the cache's columns for no visits", {
  p <- parse_port_visits(list(), "vid-1", "367000001", "d")
  expect_equal(names(p), port_visit_cols)
  expect_equal(nrow(p), 0)
})
