test_that("validate_crosswalk() accepts adjacent windows for one MMSI", {
  cw <- bind_rows(
    cw_row("367000001", valid_to = "2020-09-30"),
    cw_row("367000001", valid_from = "2020-10-01", activity_excluded = TRUE))
  expect_silent(validate_crosswalk(cw))
})

test_that("validate_crosswalk() lists every problem", {
  cw <- bind_rows(
    cw_row("367000001", valid_to = "2021-01-01"),
    cw_row("367000001", valid_from = "2020-10-01", activity_excluded = NA),
    cw_row("367000002", hull_class = "boat"),
    cw_row("367000003", valid_from = "2022-01-01", valid_to = "2021-01-01"))
  err <- tryCatch(validate_crosswalk(cw), error = conditionMessage)
  expect_match(err, "overlapping windows for MMSI: 367000001")
  expect_match(err, "unknown hull_class")
  expect_match(err, "activity_excluded must be TRUE or FALSE")
  expect_match(err, "valid_from after valid_to")
})

test_that("validate_crosswalk() checks malformed MMSIs against the pull only when given it", {
  cw <- cw_row("3.67E+08")
  expect_silent(validate_crosswalk(cw))
  expect_error(validate_crosswalk(cw, gfw_labels = tibble(MMSI = "367000001")),
               "not 9 digits and not in the GFW pull")
  expect_silent(validate_crosswalk(cw, gfw_labels = tibble(MMSI = "3.67E+08")))
  # gear markers may carry any MMSI
  expect_silent(validate_crosswalk(cw_row("12345", hull_class = "gear_marker"),
                                   gfw_labels = tibble(MMSI = "367000001")))
})

test_that("validate_gear() returns accepted rows and checks them", {
  g <- tibble(decision = c("accept", "reject"), MMSI = c("367000001", "367000002"),
              valid_from = NA_character_, valid_to = NA_character_,
              gear_class = c("FIXED", NA), basis = "test")
  out <- validate_gear(g)
  expect_equal(out$MMSI, "367000001")
  expect_s3_class(out$valid_from, "Date")

  expect_error(validate_gear(mutate(g, gear_class = "TRAPS")), "gear_class must be")
  expect_error(validate_gear(mutate(g, decision = c("accept", "maybe"))), "accept or reject")
})

test_that("norm_survey_name() normalises Ørsted vessel names", {
  expect_equal(norm_survey_name(c("F/V Heather Lynn", "FV  Cailyn and Maren ", "Arch Angel")),
               c("HEATHER LYNN", "CAILYN AND MAREN", "ARCH ANGEL"))
})

test_that("classify() applies crosswalk windows, gear windows and the two sets", {
  records <- tibble(
    MMSI          = c("1", "1", "2", "3", "4", "5"),
    date          = as.Date(c("2020-09-30", "2020-10-01", "2024-01-01", "2024-01-01",
                              "2024-01-01", "2024-01-01")),
    `Vessel Type` = c("FISHING", "FISHING", "OTHER", "FISHING", "FISHING", "FISHING"),
    `Gear Type`   = c("FISHING", "FISHING", "OTHER", "TRAWLERS", "TRAWLERS", "POTS_AND_TRAPS"),
    hours         = 1)

  cw <- bind_rows(
    cw_row("1", valid_from = "2020-10-01", activity_excluded = TRUE), # charter from Stage 2
    cw_row("2"),                                                       # fishing hull GFW missed
    cw_row("3", hull_class = "non_fishing"),
    cw_row("4", hull_class = "gear_marker"))

  gear <- tibble(MMSI = "1", valid_from = as.Date(NA), valid_to = as.Date("2020-09-30"),
                 gear_class = "FIXED")

  out <- classify(records, cw, gear)

  expect_equal(nrow(out), nrow(records))
  expect_equal(out$in_strict,  c(TRUE, TRUE, FALSE, TRUE, TRUE, TRUE))
  expect_equal(out$in_primary, c(TRUE, FALSE, TRUE, FALSE, FALSE, TRUE))
  expect_equal(out$added,      c(FALSE, FALSE, TRUE, FALSE, FALSE, FALSE))
  # the gear correction covers only the first record's date
  expect_equal(out$gear_class,  c("FIXED", "UNRESOLVED", "UNRESOLVED", "MOBILE", "MOBILE", "FIXED"))
  expect_equal(out$gear_source, c("vessel_gear", "gfw", "gfw", "gfw", "gfw", "gfw"))
  expect_equal(out$gear_class_gfw[1], "UNRESOLVED")
})

test_that("classify() stops when a record matches two crosswalk rows", {
  records <- tibble(MMSI = "1", date = as.Date("2024-01-01"), `Vessel Type` = "FISHING",
                    `Gear Type` = "TRAWLERS", hours = 1)
  cw <- bind_rows(cw_row("1"), cw_row("1", activity_excluded = TRUE))
  gear <- tibble(MMSI = character(), valid_from = as.Date(character()),
                 valid_to = as.Date(character()), gear_class = character())
  expect_error(classify(records, cw, gear), "more than one crosswalk or gear row")
})

# Fishing roster ---------------------------------------------------------------

# toy records in read_gfw() layout, with the columns build_fishing_roster() reads
roster_records <- function(MMSI, date, type, gear_type = "TRAWLERS", hours = 1,
                           name = "BOAT", vessel_id = paste0("id", MMSI)) {
  date <- as.Date(date)
  tibble(MMSI, date, `Vessel Type` = type, `Gear Type` = gear_type, hours,
         `Vessel Name` = name, `Vessel ID` = vessel_id,
         `Development Stage` = stage_of(date))
}

no_gear <- tibble(MMSI = character(), valid_from = as.Date(character()),
                  valid_to = as.Date(character()), gear_class = character())

test_that("build_fishing_roster() flags each source and drops non-fishing MMSIs", {
  vp <- bind_rows(
    roster_records("1", "2018-01-01", "FISHING"),               # GFW FISHING only
    roster_records("2", "2021-01-01", "OTHER"),                 # crosswalk fishing hull
    roster_records("3", "2024-01-01", "PASSENGER"),             # gear correction only
    roster_records("4", "2024-01-01", "OTHER"),                 # fishing GARFO permit group
    roster_records("5", "2024-01-01", "OTHER"),                 # recreational permit: not fishing
    roster_records("6", "2024-01-01", "CARGO"))                 # no source at all
  afe <- roster_records("1", "2018-01-01", "FISHING", hours = 2.5)

  cw   <- cw_row("2")
  gear <- tibble(MMSI = "3", valid_from = as.Date(NA), valid_to = as.Date(NA),
                 gear_class = "FIXED")
  pg   <- tibble(MMSI = c("4", "5"), permit_group = c("commercial", "recreational only"))

  r <- build_fishing_roster(vp, afe, cw, gear, pg, gfw_labels_of(vp, afe),
                            pull_date = as.Date("2026-10-06"), pipeline = "v4",
                            source_commit = "abc1234")

  expect_equal(names(r), roster_cols)
  expect_equal(r$MMSI, c("1", "2", "3", "4"))
  expect_equal(r$src_gfw_fishing,     c(TRUE, FALSE, FALSE, FALSE))
  expect_equal(r$src_cw_fishing,      c(FALSE, TRUE, FALSE, FALSE))
  expect_equal(r$src_gear_correction, c(FALSE, FALSE, TRUE, FALSE))
  expect_equal(r$src_garfo_permit,    c(FALSE, FALSE, FALSE, TRUE))
  # Primary: GFW FISHING (1) and the added crosswalk hull (2); the others are
  # on the roster but GFW does not type them FISHING and the crosswalk does not add them
  expect_equal(r$in_primary, c(TRUE, TRUE, FALSE, FALSE))
  expect_equal(r$gear_class[r$MMSI == "3"], "FIXED")
  expect_equal(r$gear_source[r$MMSI == "3"], "vessel_gear")
  expect_equal(unique(r$pipeline), "v4")
  expect_equal(unique(r$source_commit), "abc1234")
})

test_that("build_fishing_roster() splits hours by dataset and stage, one row per MMSI", {
  vp <- bind_rows(
    roster_records("1", "2018-01-01", "FISHING", vessel_id = "a"),   # Stage 1
    roster_records("1", "2021-01-01", "FISHING", vessel_id = "b"),   # Stage 2
    roster_records("1", "2024-01-01", "FISHING", hours = 3, vessel_id = "a")) # Stage 3
  afe <- roster_records("1", "2024-01-01", "FISHING", hours = 0.5)

  r <- build_fishing_roster(vp, afe, cw_row("9")[0, ], no_gear,
                            tibble(MMSI = character(), permit_group = character()),
                            gfw_labels_of(vp, afe), as.Date("2026-10-06"), "v4")

  expect_equal(nrow(r), 1)
  expect_equal(c(r$vp_hours_s1, r$vp_hours_s2, r$vp_hours_s3), c(1, 1, 3))
  expect_equal(c(r$afe_hours_s1, r$afe_hours_s2, r$afe_hours_s3), c(0, 0, 0.5))
  expect_equal(r$vessel_ids, "a|b|id1")
  expect_equal(c(r$first, r$last), c("2018-01-01", "2024-01-01"))
})

test_that("write_roster_once() writes a roster and refuses to replace it", {
  vp <- roster_records("1", "2018-01-01", "FISHING")
  r  <- build_fishing_roster(vp, vp[0, ], cw_row("9")[0, ], no_gear,
                             tibble(MMSI = character(), permit_group = character()),
                             gfw_labels_of(vp, vp[0, ]), as.Date("2026-10-06"), "v4")
  path <- tempfile(fileext = ".csv")

  expect_message(write_roster_once(r, path), "Wrote 1 MMSIs")
  expect_equal(read_chr(path)$MMSI, "1")
  expect_error(write_roster_once(r, path), "already exists")
})

# Roster check -----------------------------------------------------------------

# a toy roster as read from fishing_roster_*.csv (every column text), one row
# per MMSI with the labels and gear class it had in the previous version
toy_roster <- function(MMSI, type = "FISHING", gear_type = "TRAWLERS",
                       gear_class = "MOBILE", in_primary = "TRUE", afe = "1") {
  tibble(MMSI, Vessel_Name = paste("BOAT", MMSI), gfw_vessel_type = type,
         gfw_gear_type = gear_type, gear_class, in_primary,
         vp_hours_s1 = "1", vp_hours_s2 = "0", vp_hours_s3 = "0",
         afe_hours_s1 = afe, afe_hours_s2 = "0", afe_hours_s3 = "0")
}

test_that("roster_changes() finds type, gear-class and missing changes, and marks protected ones", {
  roster <- toy_roster(c("1", "2", "3", "4", "5", "6"))
  # current labels: 1 unchanged, 2 retyped, 3 retyped but has a crosswalk row,
  # 4 same type with another gear class, 5 gear changed but corrected, 6 absent
  labels <- tibble(MMSI = c("1", "2", "3", "4", "5"),
                   gfw_vessel_type = c("FISHING", "PASSENGER", "PASSENGER", "FISHING", "FISHING"),
                   gfw_gear_type   = c("TRAWLERS", "PASSENGER", "PASSENGER", "POTS_AND_TRAPS", "FISHING"))
  gear_now <- tibble(MMSI = c("1", "2", "3", "4", "5"),
                     gear_class = c("MOBILE", "UNRESOLVED", "UNRESOLVED", "FIXED", "UNRESOLVED"))
  cw   <- cw_row("3")
  gear <- tibble(MMSI = "5", gear_class = "MOBILE")

  out <- roster_changes(roster, labels, gear_now, cw, gear)

  expect_equal(paste(out$change, out$MMSI),
               c("type 2", "type 3", "gear_class 2", "gear_class 3", "gear_class 4",
                 "gear_class 5", "missing 6"))
  expect_equal(out$protected, c(FALSE, TRUE, FALSE, FALSE, FALSE, TRUE, FALSE))
  expect_equal(out$type_new[out$MMSI == "2" & out$change == "type"], "PASSENGER")
  expect_equal(out$class_new[out$MMSI == "4"], "FIXED")
  expect_true(is.na(out$type_new[out$change == "missing"]))
  expect_type(out$in_primary, "logical")
  expect_equal(out$afe_hours_old[1], 1)
})

test_that("roster_changes() returns no rows when nothing changed", {
  roster <- toy_roster("1")
  out <- roster_changes(roster,
                        tibble(MMSI = "1", gfw_vessel_type = "FISHING", gfw_gear_type = "TRAWLERS"),
                        tibble(MMSI = "1", gear_class = "MOBILE"),
                        cw_row("9")[0, ], tibble(MMSI = character()))
  expect_equal(nrow(out), 0)
})

test_that("previous_roster_path() picks the newest roster of another version", {
  dir <- tempfile(); dir.create(dir)
  template <- file.path(dir, "fishing_roster_%s.csv")
  expect_null(previous_roster_path(template, "v4"))
  for (v in c("v4", "v9", "v10")) writeLines("MMSI", sprintf(template, v))
  # numeric order, not text order: v10 is newer than v9
  expect_equal(basename(previous_roster_path(template, "v11")), "fishing_roster_v10.csv")
  expect_equal(basename(previous_roster_path(template, "v10")), "fishing_roster_v9.csv")
  unlink(c(sprintf(template, c("v9", "v10"))))
  expect_null(previous_roster_path(template, "v4"))
  expect_equal(basename(previous_roster_path(template, "v5")), "fishing_roster_v4.csv")
})
