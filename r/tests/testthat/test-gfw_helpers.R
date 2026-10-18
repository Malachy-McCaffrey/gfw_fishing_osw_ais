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
