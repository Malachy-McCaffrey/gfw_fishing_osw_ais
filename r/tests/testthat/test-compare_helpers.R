# Tests for r/compare_helpers.R: the v4-vs-v5 record join, the label
# transitions and the scoring of each version against the hand-made truth.

test_that("join_versions() sums duplicates and labels every status", {
  old <- tibble(k = c("a", "a", "b", "c"), hours = c(1, 1, 3, 2))
  new <- tibble(k = c("a", "b", "d"), hours = c(2, 2.5, 4))
  j <- join_versions(old, new, "k") |> arrange(k)
  expect_equal(j$h_old, c(2, 3, 2, NA))
  expect_equal(as.character(j$status), c("same", "changed", "old_only", "new_only"))

  s <- summarise_join(j)
  expect_equal(s$keys, c(1, 1, 1, 1))
  expect_equal(sum(s$h_old), 7)
  expect_equal(sum(s$pct_h_new), 100)
})

test_that("join_versions() keeps empty statuses in the summary", {
  j <- join_versions(tibble(k = "a", hours = 1), tibble(k = "a", hours = 1), "k")
  s <- summarise_join(j)
  expect_equal(as.character(s$status), join_status_levels)
  expect_equal(s$keys, c(1, 0, 0, 0))
})

test_that("join_versions() treats float noise in AFE hours as the same", {
  j <- join_versions(tibble(k = "a", hours = 0.1 + 0.2), tibble(k = "a", hours = 0.3), "k")
  expect_equal(as.character(j$status), "same")
})

# crosswalk-shaped and decision-shaped rows with defaults, for hull_truth()
cw_rows <- \(MMSI, hull_class, activity_excluded = "FALSE", gfw_pipeline = "v4")
  tibble(MMSI, Vessel_Name = paste("V", MMSI), hull_class, activity_excluded,
         Identified_By = "x", Operation = "", evidence_ref = NA_character_, Notes = NA_character_,
         gfw_pipeline)
dec_rows <- \(decision, MMSI, hull_class = "fishing", gfw_vessel_type = "PASSENGER",
              decided_on = "2026-10-14", gfw_pipeline = "v4")
  mutate(cw_rows(MMSI, hull_class, gfw_pipeline = gfw_pipeline),
         decision = decision, gfw_vessel_type = gfw_vessel_type, decided_on = decided_on)

test_that("hull_truth() takes crosswalk classes and rejected decisions' GFW labels", {
  # 1: survey-window fishing hull (crosswalk only); 9: malformed MMSI
  cw <- cw_rows(c("1", "1", "9"), c("fishing", "fishing", "unknown"),
                activity_excluded = c("TRUE", "FALSE", "FALSE"))
  dec <- dec_rows("reject", c("3", "4"), gfw_vessel_type = c("FISHING", "PASSENGER"))
  t <- hull_truth(cw, dec) |> arrange(MMSI)
  expect_equal(t$MMSI, c("1", "3", "4"))                # unknown dropped
  expect_equal(t$truth_fishing, c(TRUE, TRUE, FALSE))
  expect_equal(t$activity_excluded, c(TRUE, FALSE, FALSE))
  expect_equal(t$truth_source, c("accepted", "confirmed", "confirmed"))
})

test_that("hull_truth() counts a decision made against a newer version before its crosswalk exists", {
  # 5 is in the v4 crosswalk only through the removal list; 6 is not in it at
  # all. Both get v5 decisions that the v4 crosswalk does not yet carry.
  cw  <- cw_rows("5", "non_fishing")
  dec <- bind_rows(dec_rows("accept", "6", "fishing", gfw_pipeline = "v5"),
                   dec_rows("accept", "5", "fishing", gfw_pipeline = "v5"))
  t <- hull_truth(cw, dec) |> arrange(MMSI)
  expect_equal(t$MMSI, c("5", "6"))
  expect_equal(t$truth_fishing, c(TRUE, TRUE))          # the decision replaces 5's crosswalk row
  expect_equal(t$truth_pipeline, c("v5", "v5"))
})

test_that("hull_truth() lets an accept beat a reject and the latest reject beat older ones", {
  dec <- bind_rows(
    dec_rows("reject", "7", gfw_vessel_type = "FISHING"),
    dec_rows("accept", "7", "non_fishing", gfw_pipeline = "v5"),
    # 8: confirmed FISHING against v4, then confirmed PASSENGER against v5
    dec_rows("reject", "8", gfw_vessel_type = "FISHING", decided_on = "2026-10-14"),
    dec_rows("reject", "8", gfw_vessel_type = "PASSENGER", decided_on = "2026-11-02",
             gfw_pipeline = "v5"))
  t <- hull_truth(cw_rows(character(), character()), dec) |> arrange(MMSI)
  expect_equal(t$truth_hull, c("non_fishing", "non_fishing"))
  expect_equal(t$truth_source, c("accepted", "confirmed"))
})

test_that("hull_truth() refuses an MMSI with two hull classes", {
  cw <- cw_rows(c("1", "1"), c("fishing", "non_fishing"))
  expect_error(hull_truth(cw, dec_rows("accept", character())), "more than one hull class")
})

test_that("hull_outcome() and error_status() cover every case", {
  truth <- c(TRUE, TRUE, FALSE, FALSE, TRUE)
  type  <- c("FISHING", "PASSENGER", "FISHING", "CARGO", NA)
  expect_equal(hull_outcome(truth, type), c("TP", "FN", "FP", "TN", "absent"))

  old <- c("FP", "FN", "TP", "TN", "FN", "absent", "TP")
  new <- c("TN", "FN", "FN", "TN", "absent", "TP", "TP")
  expect_equal(error_status(old, new),
               c("corrected", "still wrong", "new error", "still correct",
                 "absent", "new vessel", "still correct"))
})

test_that("gear_truth() keeps accepted rows and resolvable rejected rows", {
  g <- tibble(decision = c("accept", "reject", "reject"), MMSI = c("1", "2", "3"),
              Vessel_Name = "x", gear_class = c("FIXED", NA, NA),
              gfw_gear_type = c("FISHING", "TRAWLERS", "FISHING"),
              basis = NA, evidence_ref = NA, Notes = NA)
  t <- gear_truth(g) |> arrange(MMSI)
  expect_equal(t$MMSI, c("1", "2"))
  expect_equal(t$truth_gear, c("FIXED", "MOBILE"))
})

test_that("gear_outcome() separates unresolved from wrong", {
  expect_equal(gear_outcome(c("FIXED", "FIXED", "FIXED", "FIXED"),
                            c("POTS_AND_TRAPS", "FISHING", "TRAWLERS", NA)),
               c("correct", "unresolved", "wrong", "absent"))
})

test_that("mmsi_transitions() flags type, gear and class changes", {
  rec <- \(m, t, g, h) tibble(MMSI = m, `Vessel Type` = t, `Gear Type` = g, hours = h)
  vp_old <- rec(c("1", "2"), c("FISHING", "OTHER"), c("SET_GILLNETS", "OTHER"), c(5, 3))
  vp_new <- rec(c("1", "3"), c("FISHING", "PASSENGER"), c("FISHING", "PASSENGER"), c(4, 1))
  afe_old <- rec("1", "FISHING", "SET_GILLNETS", 2)
  afe_new <- rec(character(), character(), character(), numeric())
  m <- mmsi_transitions(vp_old, afe_old, vp_new, afe_new) |> arrange(MMSI)
  expect_equal(m$class_old, c("FIXED", "UNRESOLVED", NA))
  expect_equal(m$class_new, c("UNRESOLVED", NA, "UNRESOLVED"))
  expect_equal(m$type_changed, c(FALSE, TRUE, TRUE))
  expect_equal(m$afe_new, c(0, 0, 0))

  tt <- transition_table(m, "type_old", "type_new", "vp_old")
  expect_true("(absent)" %in% tt$to)
})
