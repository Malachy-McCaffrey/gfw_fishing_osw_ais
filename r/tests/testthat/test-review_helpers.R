# Tests for r/review_helpers.R (the vessel review in 03_review_vessels.qmd).
# None of these needs the GARFO files, the evidence caches or an API: each
# function gets small hand-made inputs.

# Phase 1: collecting marked review rows ------------------------------------

test_that("collect_marked() adds new marked rows and skips MMSIs already decided", {
  cols  <- c("decision", "decided_on", "MMSI", "gfw_pipeline", "Notes")
  input <- tempfile(fileext = ".csv")
  sheet <- tempfile(fileext = ".csv")
  write_csv(tibble(decision = "accept", decided_on = "2026-10-01", MMSI = "367000001",
                   gfw_pipeline = "v4", Notes = "already decided"), input, na = "")
  # the sheet predates gfw_pipeline: its rows take the version passed in
  write_csv(tibble(decision = c("accept", "reject", "", "reject"),
                   decided_on = c("2026-10-02", NA, NA, NA),
                   MMSI = c("367000001", "367000002", "367000003", "367000004"),
                   Notes = c("changed", "new", "unmarked", "new too")), sheet, na = "")

  out <- expect_warning(collect_marked(sheet, input, cols, pipeline = "v5"),
                        "1 rows .* were skipped")
  expect_equal(out$MMSI, c("367000001", "367000002", "367000004"))
  expect_equal(out$Notes[1], "already decided")          # the input file wins
  expect_equal(out$gfw_pipeline[2:3], c("v5", "v5"))
  expect_false(anyNA(out$decided_on))                    # blank dates filled
  expect_equal(read_chr(input)$MMSI, out$MMSI)           # and written back
})

test_that("collect_marked() returns the input unchanged when there is no sheet", {
  cols  <- c("decision", "decided_on", "MMSI", "gfw_pipeline")
  input <- tempfile(fileext = ".csv")
  write_csv(tibble(decision = "reject", decided_on = "2026-10-01", MMSI = "367000001",
                   gfw_pipeline = "v4"), input, na = "")
  before <- readLines(input)
  out <- collect_marked(tempfile(), input, cols, pipeline = "v4")
  expect_equal(nrow(out), 1)
  expect_equal(readLines(input), before)
})

# Phase 2: profile and screens ----------------------------------------------

test_that("profile_mmsi() splits hours by stage and lease, and joins AFE and labels", {
  rec <- function(mmsi, date, stage, cell, hours) {
    tibble(MMSI = mmsi, `Vessel Name` = "TEST", Flag = "USA", CallSign = "WDA1234",
           date = as.Date(date), `Development Stage` = stage, cell_id = cell, hours = hours)
  }
  vp <- bind_rows(rec("367000001", "2019-06-01", "Stage 1", "a", 10),
                  rec("367000001", "2024-06-01", "Stage 3", "b", 30),
                  rec("367000001", "2024-06-02", "Stage 3", "a", 10))
  afe <- rec("367000001", "2024-06-01", "Stage 3", "b", 5)
  cell_lease <- tibble(cell_id = c("a", "b"), in_lease = c(FALSE, TRUE))
  labels <- tibble(MMSI = "367000001", gfw_vessel_type = "FISHING")

  p <- profile_mmsi(vp, afe, cell_lease, labels)
  expect_equal(c(p$vp_hours, p$s1, p$s3, p$days), c(50, 10, 40, 3))
  expect_equal(p$lease_share, 30 / 50)
  expect_equal(p$lease_share_s12, 0)
  expect_equal(p$lease_share_s3, 30 / 40)
  expect_equal(p$s3_lease_first, as.Date("2024-06-01"))
  expect_equal(c(p$afe_hours, p$afe_s3), c(5, 5))
  expect_equal(p$gfw_vessel_type, "FISHING")
  expect_true(p$mmsi_valid)
})

test_that("charter_screen() flags a lease burst and a lease shift, given enough Stage 3 hours", {
  screen <- list(min_s3_hours = 50, min_lease_share = 0.25, max_prior_hours = 0,
                 min_lease_shift = 0.25)
  p <- tibble(
    s1 = c(0, 100, 100, 0), s2 = c(0, 0, 0, 0), s3 = c(60, 60, 60, 40),
    lease_share     = c(0.5, 0.3, 0.1, 0.9),
    lease_share_s12 = c(NA, 0.0, 0.1, NA),
    lease_share_s3  = c(0.5, 0.5, 0.1, 0.9))
  out <- charter_screen(p, screen)
  expect_equal(out$burst, c(TRUE, FALSE, FALSE, TRUE))
  expect_equal(out$shift, c(FALSE, TRUE, FALSE, FALSE))
  # the last is a burst, but below min_s3_hours
  expect_equal(out$charter_flag, c(TRUE, TRUE, FALSE, FALSE))
})

# Phase 2: GARFO matching ---------------------------------------------------

test_that("norm_name() makes vessel names comparable", {
  expect_equal(norm_name(c("F/V Cailyn & Maren", "FV LADY ANN", "f.v. sea-hawk II")),
               c("CAILYNANDMAREN", "LADYANN", "SEAHAWKII"))
})

test_that("read_garfo() never reads personal fields and splits fishery codes", {
  f <- tempfile(fileext = ".csv")
  write_csv(tibble(PERMIT = "123", `PERMIT YEAR` = "2022", `VESSEL NAME` = "LADY ANN",
                   `HULL ID` = "555555", LENGTH = "40", `OWNER NAME` = "A PERSON",
                   TELEPHONE = "000", LOBSTER = "A1, A2", SCALLOP = NA), f, na = "")
  g <- read_garfo(f)
  expect_false(any(c("OWNER NAME", "TELEPHONE") %in% c(names(g$permits), names(g$codes))))
  expect_equal(g$permits$source, "garfo_permits")
  expect_equal(g$permits$permit_year, 2022L)
  expect_equal(sort(g$codes$code), c("A1", "A2"))
  expect_equal(unique(g$codes$fishery), "LOBSTER")
})

# Phase 3: caches and identity evidence -------------------------------------

test_that("read_ev() gives an empty table with the cache's columns before any lookup", {
  e <- read_ev(tempfile(), queried_cols)
  expect_equal(names(e), queried_cols)
  expect_equal(nrow(e), 0)
})

test_that("col_chr() collapses list columns and fills missing columns with NA", {
  df <- tibble(a = list(c("X", "Y", "X"), "Z"), b = 1:2)
  expect_equal(col_chr(df, "a"), c("X|Y", "Z"))
  expect_equal(col_chr(df, "b"), c("1", "2"))
  expect_equal(col_chr(df, "missing"), c(NA_character_, NA_character_))
})

test_that("has_fishing_gear() and has_rfmo_source() read '|'-separated codes", {
  expect_equal(has_fishing_gear(c("TRAWLERS|CARGO", "CARGO", NA)), c(TRUE, FALSE, FALSE))
  expect_equal(has_rfmo_source(c("USCG|ICCAT", "USCG", NA)), c(TRUE, FALSE, FALSE))
})

# Phase 4: review sheet and PSIX --------------------------------------------

test_that("length_agrees() compares feet with metres within the tolerance", {
  # 40 ft = 12.19 m
  expect_equal(length_agrees(c(40, 40, NA), c(12, 15, 12), tolerance = 0.15),
               c(TRUE, FALSE, FALSE))
})

test_that("us_call_sign() keeps US-format call signs only", {
  expect_equal(us_call_sign(c("wda 1234", "KX99", "AB12CD", "VA1234", NA)),
               c("WDA1234", "KX99", "AB12CD", NA, NA))
})

test_that("psix_keys() looks up US call signs and numeric hull IDs of reliable GARFO matches", {
  df <- tibble(MMSI = c("1", "2", "3"), flag = c("USA", "CAN", "USA"),
               call_sign = c("WDA1234", "WDA1234", NA),
               garfo_match = c("unique_years", "unique_years", "ambiguous"),
               garfo_hull_id = c("555555", "MS6930PP", "555556"))
  k <- psix_keys(df)
  expect_equal(k$ais_cs, c("WDA1234", NA, NA))
  expect_equal(k$hull, c("555555", NA, NA))
})

test_that("psix_evaluate() matches a hull to its call sign and flags a non-fishing service", {
  psix <- tibble(
    key_type = c("official_no", "call_sign", "official_no", "call_sign"),
    key      = c("555555", "WDA1234", "777777", "WDB7777"),
    status   = "ok",
    psix_official_no = c("555555", "555555", "777777", "777777"),
    psix_name = c("LADY ANN", "LADY ANN", "TUG ONE", "TUG ONE"),
    psix_call_sign = c("WDA1234", "WDA1234", "WDB7777", "WDB7777"),
    psix_service = c("Commercial Fishing Vessel", "Commercial Fishing Vessel",
                     "Towing Vessel", "Towing Vessel"),
    psix_status = "Active")
  targets <- tibble(MMSI = c("1", "2", "3"), ais_cs = c("WDA1234", "WDB7777", "WDA1234"),
                    hull = c("555555", "777777", NA))
  out <- psix_evaluate(targets, psix)
  expect_equal(out$psix_link, c("match", "match", NA))
  expect_equal(out$psix_contradicts, c(FALSE, TRUE, FALSE))
  expect_match(out$psix_note[2], "service type is not fishing")
})

test_that("psix_evaluate() reports a hull not yet looked up", {
  targets <- tibble(MMSI = "1", ais_cs = NA_character_, hull = "999999")
  out <- psix_evaluate(targets, empty_tbl(psix_cols))
  expect_equal(out$psix_link, "not_queried")
})

test_that("reg_gear_class() returns one class only when the registry codes agree", {
  expect_equal(reg_gear_class(c("TRAWLERS|DREDGE_FISHING", "TRAWLERS|POTS_AND_TRAPS",
                                "FISHING", NA)),
               c("MOBILE", NA, NA, NA))
})
