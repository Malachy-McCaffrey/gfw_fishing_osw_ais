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

test_that("sfw_foundation_dates.csv is valid", {
  sfw <- read_chr(root_paths$sfw_pso_dates)
  expect_true(all(c("pso_id", "structure", "first_date", "last_date", "source") %in% names(sfw)))
  # 12 turbines and one substation (Z01), each listed once
  expect_equal(sum(sfw$structure == "WTG"), 12)
  expect_equal(sfw$pso_id[sfw$structure == "OSS"], "Z01")
  expect_false(anyDuplicated(sfw$pso_id) > 0)
  expect_true(all(iso_or_blank(sfw$first_date) & !is.na(sfw$first_date)))
  expect_true(all(as.Date(sfw$first_date) <= as.Date(sfw$last_date)))
  expect_false(anyNA(sfw$source))
})

test_that("the Ørsted SFW CSV covers the 13 foundations and agrees with PSO Table 3", {
  # the Ørsted file sits under data/ (not tracked), so it may be absent
  skip_if_not(file.exists(root_paths$sfw_foundations), "SFW Ørsted CSV not present")
  sfw <- read_sfw_csv(root_paths$sfw_foundations)
  expect_equal(nrow(sfw), 13)
  expect_equal(sum(sfw$structure == "WTG"), 12)
  expect_equal(sfw$foundation_id[sfw$structure == "OSS"], "Z01")
  # the substation sits where the export cable lands
  expect_equal(sfw$uscg_id[sfw$foundation_id == "Z01"], "AP06")
  # every position id is a complete grid name (A01's "AM0" corrected to AM05,
  # 2026-10-20), one per foundation
  expect_true(all(str_detect(sfw$uscg_id, "^[A-Z]{2}\\d{2}$")))
  expect_equal(sfw$uscg_id[sfw$foundation_id == "A01"], "AM05")
  expect_false(anyDuplicated(sfw$uscg_id) > 0)
  pso <- read_chr(root_paths$sfw_pso_dates)
  both <- inner_join(sfw, pso, by = c("foundation_id" = "pso_id"))
  expect_equal(nrow(both), 13)
  expect_equal(both$foundation_installed, as.Date(both$first_date))
  expect_equal(both$foundation_end, as.Date(both$last_date))
})

test_that("infra_safety_zones.csv is valid", {
  sz <- read_chr(root_paths$safety_zones)
  expect_true(all(c("project", "radius_m", "rule_start", "rule_end", "zones", "source") %in% names(sz)))
  expect_setequal(sz$project, c("SFW", "RWF", "SRW"))
  expect_true(all(as.numeric(sz$radius_m) == 500))
  expect_true(all(iso_or_blank(sz$rule_start) & iso_or_blank(sz$rule_end)))
  expect_true(all(as.Date(sz$rule_start) <= as.Date(sz$rule_end)))
  # one zone per foundation position: SFW 13, RWF 67 (65 WTG + 2 OSS sites), SRW 85
  expect_equal(as.integer(sz$zones[match(c("SFW", "RWF", "SRW"), sz$project)]), c(13L, 67L, 85L))
  expect_false(anyNA(sz$source))
})

test_that("infra_cable_windows.csv is valid", {
  cw <- read_chr(root_paths$cable_windows)
  expect_true(all(c("project", "asset_type", "lay_start", "lay_end", "date_basis", "source") %in% names(cw)))
  expect_true(all(cw$project %in% c("SFW", "RWF", "SRW")))
  expect_true(all(cw$asset_type %in% c("iac", "export_cable")))
  expect_false(anyDuplicated(paste(cw$project, cw$asset_type)) > 0)
  expect_true(all(cw$date_basis %in% c("project_window", "open_window", "complete_by", "unknown")))
  expect_true(all(iso_or_blank(cw$lay_start) & iso_or_blank(cw$lay_end)))
  both <- !is.na(cw$lay_start) & !is.na(cw$lay_end)
  expect_true(all(as.Date(cw$lay_start[both]) <= as.Date(cw$lay_end[both])))
  expect_false(anyNA(cw$source))
})
