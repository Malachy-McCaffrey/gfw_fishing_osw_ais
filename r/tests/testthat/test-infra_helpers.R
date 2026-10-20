# Tests for r/infra_helpers.R (Ørsted foundations and cables, 05 step 8).
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

test_that("foundation_exposure() ignores foundations with no dates (planned)", {
  d_km <- matrix(c(1, 0.1), nrow = 1)
  ex <- foundation_exposure(d_km, as.Date(c("2024-01-05", NA)), as.Date(c("2024-01-05", NA)),
                            as.Date("2024-02-01"))
  expect_equal(ex$d_found_km, 1)
  expect_equal(ex$n_found_2km, 1L)
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
