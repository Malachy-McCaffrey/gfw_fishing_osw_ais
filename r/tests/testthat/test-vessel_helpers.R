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
