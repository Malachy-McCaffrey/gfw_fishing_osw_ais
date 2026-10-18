# Schema checks on the tracked files in references/. They need no GFW data,
# so they run on a bare clone and in CI.

iso_or_blank <- function(x) is.na(x) | grepl("^\\d{4}-\\d{2}-\\d{2}$", x) & !is.na(as.Date(x, optional = TRUE))
mmsi_ok      <- function(x) grepl("^[0-9]{9}$", x)

test_that("vessel_removals.csv is valid", {
  rm <- read_chr(root_paths$removals)
  expect_true(all(c("Vessel_Name", "MMSI", "Operation", "Scope", "Identified_By") %in% names(rm)))
  expect_false(anyNA(rm$Vessel_Name))
  expect_true(all(mmsi_ok(rm$MMSI)), info = paste(rm$MMSI[!mmsi_ok(rm$MMSI)], collapse = ", "))
  expect_false(anyDuplicated(rm$MMSI) > 0)
  expect_true(all(rm$Scope %in% removal_scopes))
})

test_that("vessel_decisions.csv is valid", {
  d <- read_chr(root_paths$decisions)
  expect_true(all(decision_cols %in% names(d)))
  expect_true(all(d$decision %in% c("accept", "reject")))
  expect_true(all(d$hull_class %in% hull_classes))
  expect_true(all(d$activity_excluded %in% c("TRUE", "FALSE")))
  expect_true(all(iso_or_blank(d$valid_from) & iso_or_blank(d$valid_to) & iso_or_blank(d$decided_on)))
  # each MMSI's accepted windows must not overlap
  acc <- filter(d, decision == "accept")
  expect_length(overlapping_mmsi(acc$MMSI, as.Date(acc$valid_from), as.Date(acc$valid_to)), 0)
})

test_that("vessel_gear.csv is valid", {
  g <- read_chr(root_paths$gear)
  expect_true(all(gear_cols %in% names(g)))
  expect_true(all(iso_or_blank(g$valid_from) & iso_or_blank(g$valid_to) & iso_or_blank(g$decided_on)))
  expect_no_error(validate_gear(g, source = "vessel_gear.csv"))
})

test_that("orsted_survey_vessels.csv maps names to MMSIs", {
  s <- read_chr(root_paths$survey_vessels)
  expect_true(all(c("survey_name", "MMSI", "Vessel_Name") %in% names(s)))
  expect_false(anyDuplicated(s$survey_name) > 0)
  expect_true(all(mmsi_ok(s$MMSI)))
  # names are stored normalised, as norm_survey_name() makes them
  expect_equal(s$survey_name, norm_survey_name(s$survey_name))
})

test_that("garfo_permit_codes.csv is valid", {
  p <- read_csv(root_paths$permit_codes, col_types = cols(.default = col_character()), na = "")
  expect_true(all(c("fishery", "code", "permit_type", "gear_hint", "open_access") %in% names(p)))
  expect_false(anyDuplicated(p[c("fishery", "code")]) > 0)
  expect_true(all(p$permit_type %in% c("commercial", "for_hire", "recreational", "unknown")))
  expect_true(all(is.na(p$gear_hint) | p$gear_hint %in% c("FIXED", "MOBILE")))
})

test_that("the tracked crosswalk is current with its tracked inputs", {
  # build_crosswalk() also checks the survey-date files (names mapped, ISO
  # dates, trips within survey_dates_through). GFW's labels and the pull date
  # come from the raw pull, which is not tracked, so they are not compared.
  no_labels <- tibble(MMSI = character(), gfw_vessel_type = character(),
                      gfw_gear_type = character())
  decisions <- read_chr(root_paths$decisions)
  built <- suppressMessages(build_crosswalk(root_paths, decisions, no_labels, as.Date(NA)))
  expect_no_error(type_crosswalk(built))

  from_pull <- c("gfw_vessel_type", "gfw_gear_type", "pull_date")
  key <- \(d) d |> select(-all_of(from_pull)) |> arrange(across(everything())) |> as.data.frame()
  tracked <- read_chr(root_paths$crosswalk) |> select(all_of(cw_cols))
  expect_equal(key(built), key(tracked), ignore_attr = TRUE)
})

test_that("vessel_permit_groups.csv is valid", {
  skip_if_not(file.exists(root_paths$permit_groups), "permit groups not generated yet")
  pg <- read_chr(root_paths$permit_groups)
  expect_true(all(c("MMSI", "permit_group") %in% names(pg)))
  expect_false(anyDuplicated(pg$MMSI) > 0)
  expect_true(all(pg$permit_group %in% c("commercial + for-hire", "for-hire + open-access commercial",
                                         "for-hire", "commercial", "recreational only",
                                         "unmapped codes only")))
})
