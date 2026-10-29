# Tests for r/infra_helpers.R (Ørsted foundations and cables, 02a).
# The date and coordinate examples are copied from the supplied foundation files.

test_that("parse_install_dates() reads every date form in the foundation files", {
  x <- c("10-May-24",                   # CSV single day
         "01-May-25",                   # CSV single day, zero-padded
         "19-20-Jul-25",                # SRW two days
         "7-8 - Sept-25",               # SRW two days, spaced, 4-letter month
         "45422",                       # Excel serial (original spreadsheets)
         "21-Jun-24 to \r\n22-Jun-24",  # range with a line break (original spreadsheets)
         NA)
  d <- parse_install_dates(x)
  expect_equal(d$first, as.Date(c("2024-05-10", "2025-05-01", "2025-07-19",
                                  "2025-09-07", "2024-05-10", "2024-06-21", NA)))
  expect_equal(d$last,  as.Date(c("2024-05-10", "2025-05-01", "2025-07-20",
                                  "2025-09-08", "2024-05-10", "2024-06-22", NA)))
})

test_that("parse_install_dates() fails loudly on a format it does not know", {
  expect_error(parse_install_dates("mid-July"), "unparsed installation date")
  # an impossible day is an error too, not a silent NA
  expect_error(parse_install_dates("31-Jun-24 to 01-Jul-24"), "unparsed")
})

test_that("month_num() is locale independent and accepts 'Sept'", {
  expect_equal(month_num(c("Jan", "jun", "Sept", "DEC")), c(1L, 6L, 9L, 12L))
})

test_that("dms_to_dd() signs south and west negative", {
  expect_equal(dms_to_dd("41-8-41.91N"), 41 + 8 / 60 + 41.91 / 3600)
  expect_equal(dms_to_dd("71-2-15.57W"), -(71 + 2 / 60 + 15.57 / 3600))
  # zero-padded minutes, as on the later RWF rows
  expect_equal(dms_to_dd("41-05-45.63N"), 41 + 5 / 60 + 45.63 / 3600)
  expect_true(is.na(dms_to_dd(NA)))
  expect_error(dms_to_dd("41 8 41.91 N"), "unparsed DMS")
  # comma-separated, as in the SFW CSV, including a space before the hemisphere
  expect_equal(dms_to_dd("41, 06, 31.782N"), 41 + 6 / 60 + 31.782 / 3600)
  expect_equal(dms_to_dd("71, 10, 4.620 W"), -(71 + 10 / 60 + 4.62 / 3600))
})

test_that("read_sfw_csv() collapses day rows and keeps the position id", {
  f <- tempfile(fileext = ".csv")
  writeLines(c(
    "USCG_ID,Orsted_ID,Install_Dates,Latitude,Longitude,Source",
    'AM0,A01,2023-08-04,"41, 06, 31.782N","71, 11, 23.401W",Orsted',
    'AN08,A10,2023-07-08,"41, 05, 36.168N","71, 07, 24.229W",Orsted',
    'AN08,A10,2023-07-09,"41, 05, 36.168N","71, 07, 24.229W",Orsted',
    'AP06,Z01,2023-06-19,"41, 04, 33.450N","71, 10, 4.620 W",Orsted'), f)
  out <- read_sfw_csv(f)
  expect_equal(out$foundation_id, c("A01", "A10", "Z01"))
  expect_equal(out$structure, c("WTG", "WTG", "OSS"))
  # A10's two installation days become one foundation spanning both
  expect_equal(out$foundation_installed[2], as.Date("2023-07-08"))
  expect_equal(out$foundation_end[2], as.Date("2023-07-09"))
  expect_equal(out$n_date_rows, c(1L, 2L, 1L))
  # the truncated id is kept as given; 05 resolves it by position
  expect_equal(out$uscg_id, c("AM0", "AN08", "AP06"))
  expect_equal(out$lon[3], -(71 + 10 / 60 + 4.62 / 3600))

  # repeated day rows naming two positions are an error
  bad <- tempfile(fileext = ".csv")
  writeLines(c(
    "USCG_ID,Orsted_ID,Install_Dates,Latitude,Longitude,Source",
    'AN08,A10,2023-07-08,"41, 05, 36.168N","71, 07, 24.229W",Orsted',
    'AN09,A10,2023-07-09,"41, 05, 36.168N","71, 07, 24.229W",Orsted'), bad)
  expect_error(read_sfw_csv(bad), "disagree on USCG_ID")
  # a non-ISO date is an error, not a silent NA
  writeLines(c(
    "USCG_ID,Orsted_ID,Install_Dates,Latitude,Longitude,Source",
    'AN08,A10,8-Jul-23,"41, 05, 36.168N","71, 07, 24.229W",Orsted'), bad)
  expect_error(read_sfw_csv(bad), "unparsed SFW installation date")
})

test_that("coord_to_dd() passes decimals through and converts DMS", {
  expect_equal(coord_to_dd(c("40.96081", "-71.032157")), c(40.96081, -71.032157))
  expect_equal(coord_to_dd("41-8-41.91N"), dms_to_dd("41-8-41.91N"))
})

test_that("collapse_foundation_rows() spans a foundation's repeated day rows", {
  d <- as.Date(c("2024-06-08", "2024-06-11", "2024-06-13", "2024-10-04", "2024-10-21"))
  rows <- tibble(foundation_id = c("B13/AF05", "B13/AF05", "B70/AN13", "Z01a/AL11", "Z01a/AL11"),
                 structure = c("WTG FOU", "WTG FOU", "WTG FOU", "OSS FOU", "OSS FOU"),
                 date_first = d, date_last = d,
                 lat = c(41.2, 41.2, 41.1, 41.13, 41.13), lon = c(-71.2, -71.2, -71.0, -71.06, -71.06),
                 depth_m = c(42.9, 42.9, 36.2, 34.28, 34.28))
  out <- collapse_foundation_rows(rows)
  expect_equal(out$foundation_id, c("B13/AF05", "B70/AN13", "Z01a/AL11"))
  expect_equal(out$foundation_installed, d[c(1, 3, 4)])
  expect_equal(out$foundation_end, d[c(2, 3, 5)])
  expect_equal(out$n_date_rows, c(2L, 1L, 2L))
  # repeated rows that disagree on position point to a mistyped id
  bad <- rows; bad$lat[2] <- 41.3
  expect_error(collapse_foundation_rows(bad), "disagree.*B13/AF05")
  expect_error(collapse_foundation_rows(mutate(rows, date_first = replace(date_first, 1, NA))),
               "date is missing")
})

test_that("read_foundation_csv() cleans Latin-1 padding and collapses day rows", {
  f <- tempfile(fileext = ".csv")
  lines <- c("#,Foundation ID,Structure Type ,Install Date(s),Latitude,Longitude,Water Depth (m),,",
             "1, B08/AE07,WTG FOU,24-May-24,41-13-34.5N,71-9-2.99W,41,,",
             "2,OCS-DC\xa0Pin Pile B2S1\xa0,Jacket Foundation Pin Pile,7-8 - Sept-25,40.99,-71.12,50.1,,",
             "3,B13/AF05,WTG FOU,8-Jun-24,41-12-31.69N,71-11-38.82W,42.9,,",
             "3,B13/AF05,WTG FOU,11-Jun-24,41-12-31.69N,71-11-38.82W,42.9,,")
  writeBin(charToRaw(paste0(paste(lines, collapse = "\n"), "\n")), f)
  out <- read_foundation_csv(f)
  expect_equal(out$foundation_id, c("B08/AE07", "OCS-DC Pin Pile B2S1", "B13/AF05"))
  expect_equal(out$foundation_end, as.Date(c("2024-05-24", "2025-09-08", "2024-06-11")))
  expect_equal(out$lon[1], dms_to_dd("71-9-2.99W"))

  # the same id re-saved as UTF-8, its non-breaking spaces turned into U+FFFD
  f8 <- tempfile(fileext = ".csv")
  writeBin(charToRaw(enc2utf8(paste0(
    "#,Foundation ID,Structure Type ,Install Date(s),Latitude,Longitude,Water Depth (m)\n",
    "2,OCS-DC�Pin Pile B2S1�,Jacket Foundation Pin Pile,6-Sep-25,40.99,-71.12,50.1\n"))), f8)
  expect_equal(read_foundation_csv(f8)$foundation_id, "OCS-DC Pin Pile B2S1")
})

test_that("month_end() and months_between() handle month lengths and years", {
  m <- as.Date(c("2024-02-01", "2023-12-01", "2026-08-01"))
  expect_equal(month_end(m), as.Date(c("2024-02-29", "2023-12-31", "2026-08-31")))
  expect_equal(months_between(as.Date("2024-05-01"), as.Date("2023-07-02")), 10L)
  expect_equal(months_between(as.Date("2023-05-01"), as.Date("2023-07-31")), -2L)
})

test_that("foundation_exposure() counts a foundation once its last day has passed", {
  # 2 cells × 2 foundations, km
  d_km <- matrix(c(1, 6,
                   3, 0.5), nrow = 2, byrow = TRUE)
  installed <- as.Date(c("2024-05-30", "2024-07-10"))
  end       <- as.Date(c("2024-06-02", "2024-07-10"))
  months    <- as.Date(c("2024-04-01", "2024-05-01", "2024-06-01", "2024-07-01"))
  ex <- foundation_exposure(d_km, installed, end, months, r_count_km = 2, r_active_km = 5)

  expect_equal(nrow(ex), 2 * 4)
  expect_true("n_found_2km" %in% names(ex))
  by_m <- split(ex, ex$year_month)
  # April and May: nothing has finished installing, so no distance yet
  expect_true(all(is.na(by_m[["2024-04-01"]]$d_found_km)))
  expect_true(all(is.na(by_m[["2024-05-01"]]$d_found_km)))
  # June: foundation 1 is in (last day 2 June)
  expect_equal(by_m[["2024-06-01"]]$d_found_km, c(1, 3))
  expect_equal(by_m[["2024-06-01"]]$n_found_2km, c(1L, 0L))
  # July: both in; cell 2 is now 0.5 km from foundation 2
  expect_equal(by_m[["2024-07-01"]]$d_found_km, c(1, 0.5))
  expect_equal(by_m[["2024-07-01"]]$n_found_2km, c(1L, 1L))
  # construction: foundation 1 straddles May–June; foundation 2 is July only
  expect_equal(by_m[["2024-05-01"]]$active_construction, c(TRUE, TRUE))  # 1 and 3 km
  expect_equal(by_m[["2024-06-01"]]$active_construction, c(TRUE, TRUE))
  expect_equal(by_m[["2024-07-01"]]$active_construction, c(FALSE, TRUE)) # 6 km vs 0.5 km
  expect_equal(by_m[["2024-04-01"]]$active_construction, c(FALSE, FALSE))
})

test_that("foundation_exposure() is nested across radii (02a's sensitivity tables, D-066)", {
  # 3 cells × 3 foundations at a spread of distances, km, so each radius step
  # adds some cells: 02a's gate relies on a larger radius never losing exposure
  d_km <- matrix(c(0.5, 3,   9,
                   1.5, 4.5, 12,
                   3.5, 8,   20), nrow = 3, byrow = TRUE)
  installed <- as.Date(c("2024-01-05", "2024-02-10", "2024-02-20"))
  end       <- as.Date(c("2024-01-06", "2024-02-11", "2024-03-02"))
  months    <- as.Date(c("2024-01-01", "2024-02-01", "2024-03-01"))
  at <- \(rc, ra) foundation_exposure(d_km, installed, end, months, r_count_km = rc, r_active_km = ra)
  n1 <- at(1, 5)$n_found_1km; n2 <- at(2, 5)$n_found_2km; n4 <- at(4, 5)$n_found_4km
  a2 <- at(2, 2)$active_construction; a5 <- at(2, 5)$active_construction
  a10 <- at(2, 10)$active_construction
  expect_true(all(n1 <= n2 & n2 <= n4))
  expect_true(all(a5 | !a2) && all(a10 | !a5))
  # and each step adds something here, so the test is not vacuous
  expect_true(sum(n4) > sum(n2) && sum(n2) > sum(n1))
  expect_true(sum(a10) > sum(a5) && sum(a5) > sum(a2))
  # the radius changes only its own column: the count is the same whatever
  # the active radius, and vice versa
  expect_identical(at(2, 2)$n_found_2km, at(2, 10)$n_found_2km)
  expect_identical(at(1, 5)$active_construction, at(4, 5)$active_construction)
})

test_that("foundation_exposure() ignores foundations with no dates (planned)", {
  d_km <- matrix(c(1, 0.1), nrow = 1)
  ex <- foundation_exposure(d_km, as.Date(c("2024-01-05", NA)), as.Date(c("2024-01-05", NA)),
                            as.Date("2024-02-01"))
  expect_equal(ex$d_found_km, 1)
  expect_equal(ex$n_found_2km, 1L)
})

test_that("safety_zone_share() gives the area share of active zones per cell and month", {
  # two 1 km × 1 km cells side by side (metres), in a projected CRS
  sq <- \(x0) sf::st_polygon(list(rbind(c(x0, 0), c(x0 + 1000, 0), c(x0 + 1000, 1000),
                                        c(x0, 1000), c(x0, 0))))
  cells <- sf::st_sf(id = 1:2, geometry = sf::st_sfc(sq(0), sq(1000), crs = 32619))
  # one foundation in the middle of cell 1, and two co-located on the shared edge
  pts <- sf::st_sf(geometry = sf::st_sfc(sf::st_point(c(500, 500)), sf::st_point(c(1000, 500)),
                                         sf::st_point(c(1000, 500)), crs = 32619))
  months <- as.Date(c("2024-01-01", "2024-02-01", "2024-03-01"))
  # zone 1 active Jan only (one day is enough); zones 2–3 from Feb, open to Mar
  start <- as.Date(c("2024-01-31", "2024-02-10", "2024-02-10"))
  end   <- as.Date(c("2024-01-31", "2024-03-31", "2024-03-31"))
  out <- safety_zone_share(cells, pts, start, end, months, radius_m = 500)
  expect_equal(nrow(out), 6)
  get <- \(cl, m) out$sz_share[out$cell == cl & out$year_month == as.Date(m)]
  # January: a 500 m circle wholly inside cell 1 (π · 0.25 km² of 1 km²); polygon
  # approximation of the circle keeps it within 0.1%
  expect_equal(get(1, "2024-01-01"), pi / 4, tolerance = 1e-3)
  expect_equal(get(2, "2024-01-01"), 0)
  # February: the co-located pair counts once, half in each cell
  expect_equal(get(1, "2024-02-01"), pi / 8, tolerance = 1e-3)
  expect_equal(get(2, "2024-02-01"), pi / 8, tolerance = 1e-3)
  expect_equal(get(1, "2024-03-01"), get(1, "2024-02-01"))
  # a zone never active (NA dates) contributes nothing
  none <- safety_zone_share(cells, pts, rep(as.Date(NA), 3), rep(as.Date(NA), 3), months)
  expect_equal(none$sz_share, rep(0, 6))
  # months with and without zones mixed: every cell × month keeps its row
  mixed <- safety_zone_share(cells, pts, start, end, c(as.Date("2023-12-01"), months))
  expect_equal(nrow(mixed), 8)
  expect_equal(mixed$sz_share[mixed$year_month == as.Date("2023-12-01")], c(0, 0))
})

test_that("cable_works_exposure() needs a known window and the radius", {
  d_km <- matrix(c(1, 1, 3), nrow = 1)
  start <- as.Date(c("2023-03-01", NA, "2023-03-01"))
  end   <- as.Date(c("2023-09-30", "2025-12-31", "2023-09-30"))
  months <- as.Date(c("2023-02-01", "2023-03-01", "2023-10-01"))
  w <- cable_works_exposure(d_km, start, end, months, r_km = 2)
  # route 2 has no start, route 3 is beyond 2 km: only route 1, Mar–Sep
  expect_equal(c(w), c(FALSE, TRUE, FALSE))
})

test_that("project_phase() runs pre → construction → post_construction", {
  m <- as.Date(c("2023-02-01", "2023-03-01", "2023-09-01", "2023-10-01"))
  expect_equal(project_phase(m, as.Date("2023-03-01"), as.Date("2023-09-30")),
               c("pre", "construction", "construction", "post_construction"))
  # unfinished project: construction to the end
  expect_equal(project_phase(m, as.Date("2023-03-15"), as.Date(NA)),
               c("pre", "construction", "construction", "construction"))
})

test_that("nearest_point() returns the row and distance of the nearest match", {
  a <- sf::st_sf(geometry = sf::st_sfc(sf::st_point(c(0, 0)), sf::st_point(c(100, 0)), crs = 32619))
  b <- sf::st_sf(geometry = sf::st_sfc(sf::st_point(c(95, 3)), sf::st_point(c(1, 1)), crs = 32619))
  nb <- nearest_point(a, b)
  expect_equal(nb$b_row, c(2L, 1L))
  expect_equal(nb$dist_m, c(sqrt(2), sqrt(25 + 9)))
})
