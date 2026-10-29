# Helpers for comparing two GFW pipeline versions of the same pull (v4 vs v5;
# planning/gfw_pipeline_v5_plan.qmd, Sections 3.4 and 4). Used by the
# GFW-facing comparison report (reports/pipeline_compare/), and meant to be
# reused by r/01a_compare_pipelines.qmd when it is written. Source after the
# tidyverse, r/paths.R, r/gfw_helpers.R and r/vessel_helpers.R:
#   source("r/paths.R"); source("r/gfw_helpers.R"); source("r/vessel_helpers.R")
#   source("r/compare_helpers.R")
#
# The functions are generic in the two versions: "old" and "new" mean the
# earlier and the later pipeline, so the same code serves v5 vs v6.
#
# What the "truth" is. GFW publishes no precision or recall for its vessel
# classes, so the comparison scores both versions against the hull and gear
# decisions this project made by hand (references/vessel_decisions.csv,
# vessel_gear.csv, vessel_removals.csv and the Ørsted survey dates, combined
# in the crosswalk). Those decisions were made while reviewing *v4*
# candidates, so the reference set is enriched for v4's errors; the report
# states that bias wherever the scores appear.

# Record-level join ----------------------------------------------------------

# Full join of two versions' records on `key`, summing hours on each side first
# so the join is one-to-one. Returns the key columns, h_old, h_new and a
# `status`:
#   same      in both, hours equal (to 1e-9, since AFE hours are fractions)
#   changed   in both, hours differ
#   old_only  only the earlier version has the key
#   new_only  only the later version has it
# `old` and `new` are read_gfw() tables (or anything with an `hours` column
# and the key columns). The useful keys are Vessel ID × cell_id × date (a
# record), Vessel ID × date (a vessel-day) and cell_id (a cell total).
# Lat/Lon are never part of the key: the two pulls format them differently
# ("41.25" in v4, "41.250000" in v5), so cells are matched on cell_id, which
# read_gfw() derives from the snapped lattice indices.
join_versions <- function(old, new, key) {
  stopifnot("both tables need an hours column" =
              "hours" %in% names(old) && "hours" %in% names(new),
            "every key column must be in both tables" =
              all(key %in% names(old)) && all(key %in% names(new)))

  sum_by <- \(d, nm) d |>
    group_by(across(all_of(key))) |>
    summarise("{nm}" := sum(hours), .groups = "drop")

  full_join(sum_by(old, "h_old"), sum_by(new, "h_new"), by = key) |>
    mutate(status = case_when(
      is.na(h_old)                 ~ "new_only",  # no old record: only the new version has it
      is.na(h_new)                 ~ "old_only",
      abs(h_old - h_new) < 1e-9    ~ "same",
      TRUE                         ~ "changed"),
      status = factor(status, levels = join_status_levels))
}

join_status_levels <- c("same", "changed", "old_only", "new_only")

# Keys, hours and shares by status for a join_versions() result: how much of
# each version's hours sits on keys the other version also has
summarise_join <- function(j) {
  j |>
    group_by(status, .drop = FALSE) |>
    summarise(keys = n(),
              h_old = sum(h_old, na.rm = TRUE),
              h_new = sum(h_new, na.rm = TRUE),
              .groups = "drop") |>
    mutate(pct_keys  = 100 * keys / sum(keys),
           pct_h_old = 100 * h_old / sum(h_old),
           pct_h_new = 100 * h_new / sum(h_new))
}

# Label transitions ----------------------------------------------------------

# Hours by MMSI × GFW vessel type × gear type for one version: the weights for
# the transition tables. An MMSI's label can differ between its records, so
# hours are split by label rather than assigned to the MMSI's main label.
label_hours <- function(d) {
  d |>
    filter(!is.na(MMSI)) |>
    group_by(MMSI, type = `Vessel Type`, gear = `Gear Type`) |>
    summarise(hours = sum(hours), .groups = "drop")
}

# One row per MMSI seen in either version: its main GFW labels in each
# (gfw_labels_of(), the most frequent label across VP and AFE records), its VP
# and AFE hours in each, and whether it changed type, gear code or analysis
# gear class (gear_class_of()). `vp_*` and `afe_*` are read_gfw() tables.
mmsi_transitions <- function(vp_old, afe_old, vp_new, afe_new) {
  labs <- \(vp, afe, sfx) gfw_labels_of(vp, afe) |>
    rename_with(\(n) paste0(sub("gfw_vessel_type", "type", sub("gfw_gear_type", "gear", n)), sfx),
                -MMSI)
  hrs <- \(d, nm) d |>
    filter(!is.na(MMSI)) |>
    group_by(MMSI) |>
    summarise("{nm}" := sum(hours), .groups = "drop")

  reduce(list(labs(vp_old, afe_old, "_old"), labs(vp_new, afe_new, "_new"),
              hrs(vp_old, "vp_old"), hrs(vp_new, "vp_new"),
              hrs(afe_old, "afe_old"), hrs(afe_new, "afe_new")),
         full_join, by = "MMSI") |>
    mutate(across(c(vp_old, vp_new, afe_old, afe_new), \(x) coalesce(x, 0)),
           class_old = if_else(is.na(gear_old), NA_character_, gear_class_of(gear_old)),
           class_new = if_else(is.na(gear_new), NA_character_, gear_class_of(gear_new)),
           fishing_old = type_old %in% "FISHING",
           fishing_new = type_new %in% "FISHING",
           # NA-safe "differs": a label that appears or disappears is a change
           type_changed  = coalesce(type_old != type_new, !(is.na(type_old) & is.na(type_new))),
           gear_changed  = coalesce(gear_old != gear_new, !(is.na(gear_old) & is.na(gear_new))),
           class_changed = coalesce(class_old != class_new, !(is.na(class_old) & is.na(class_new))))
}

# A from × to transition table: MMSIs and the summed `weight` hours for each
# pair of labels, with each pair's share of the `from` label's total. `from`
# and `to` are column names; NA labels (MMSI absent from a version) are shown
# as "(absent)".
transition_table <- function(d, from, to, weight) {
  d |>
    mutate(from = coalesce(.data[[from]], "(absent)"),
           to   = coalesce(.data[[to]], "(absent)")) |>
    group_by(from, to) |>
    summarise(mmsi = n(), hours = sum(.data[[weight]]), .groups = "drop") |>
    group_by(from) |>
    mutate(pct_of_from = 100 * hours / sum(hours)) |>
    ungroup() |>
    arrange(desc(hours))
}

# Validation truth -----------------------------------------------------------

# One row per reviewed MMSI with its reference hull class. Sources, in order
# of precedence (the same order build_crosswalk() applies):
#   1. accepted decisions (vessel_decisions.csv): hull_class as decided;
#   2. rejected decisions, for MMSIs with no accepted one: the analyst checked
#      GFW's label and let it stand, so the truth is the label GFW gave the
#      vessel in the pull the decision was made against (its
#      gfw_vessel_type: FISHING -> fishing hull, anything else ->
#      non-fishing). With several rejects, the latest (decided_on) counts;
#   3. crosswalk rows (removal list, Ørsted survey dates) for MMSIs with no
#      decision at all.
# Decisions are read directly rather than through the crosswalk, so a
# decision made against a newer pipeline version (gfw_pipeline = "v5")
# counts as soon as it is in vessel_decisions.csv, before that version's
# crosswalk is built. On decisions made against one version only, this gives
# the same truth as the crosswalk itself, since the crosswalk's decision rows
# are the accepted decisions.
# `unknown` hulls (MMSIs that are not 9 digits) are dropped: they have no
# truth to score against. Columns: MMSI, Vessel_Name, truth_hull (fishing /
# non_fishing / gear_marker), truth_fishing, activity_excluded (any window of
# known non-fishing work by a fishing hull), truth_source (accepted /
# confirmed), truth_pipeline (the GFW version(s) the truth was checked
# against), Identified_By, Operation, evidence_ref, Notes. cw and decisions
# are read with read_chr().
hull_truth <- function(cw, decisions) {
  collapse <- \(x) paste(sort(unique(na.omit(x[x != ""]))), collapse = "; ")
  # gfw_pipeline is in every tracked file; minimal test tables may leave it out
  pipeline_of <- \(d) if ("gfw_pipeline" %in% names(d)) d$gfw_pipeline else NA_character_

  # one row per MMSI from accepted rows: crosswalk rows and accepted decisions
  # share the crosswalk columns
  summarise_hull <- \(d, source) d |>
    mutate(truth_pipeline = pipeline_of(d)) |>
    group_by(MMSI) |>
    summarise(Vessel_Name = first(na.omit(Vessel_Name)),
              truth_hull = collapse(hull_class),
              activity_excluded = any(activity_excluded %in% "TRUE"),
              truth_pipeline = collapse(truth_pipeline),
              Identified_By = collapse(Identified_By),
              Operation = collapse(Operation),
              evidence_ref = collapse(evidence_ref),
              Notes = collapse(Notes),
              .groups = "drop") |>
    mutate(truth_source = source)

  accepted <- decisions |> filter(decision == "accept")
  rejected <- decisions |> filter(decision == "reject", !MMSI %in% accepted$MMSI)

  from_accept <- accepted |> summarise_hull("accepted")

  # the latest reject per MMSI; ties (same day) keep the first in file order
  from_reject <- rejected |>
    mutate(truth_pipeline = pipeline_of(rejected)) |>
    arrange(MMSI, desc(coalesce(decided_on, ""))) |>
    distinct(MMSI, .keep_all = TRUE) |>
    transmute(MMSI, Vessel_Name,
              truth_hull = if_else(gfw_vessel_type %in% "FISHING", "fishing", "non_fishing"),
              activity_excluded = FALSE, truth_pipeline,
              Identified_By = coalesce(Identified_By, ""), Operation = "",
              evidence_ref = coalesce(evidence_ref, ""), Notes = coalesce(Notes, ""),
              truth_source = "confirmed")

  # crosswalk rows stand only where no decision exists: a decision replaces a
  # vessel's removal-list and survey-date rows, and a reject removes them
  from_cw <- cw |>
    filter(!MMSI %in% decisions$MMSI) |>
    summarise_hull("accepted")

  out <- bind_rows(from_accept, from_reject, from_cw) |>
    filter(truth_hull != "unknown")

  # a hull has one class in every window; two would make the truth ambiguous
  stopifnot("an MMSI has more than one hull class in the review" =
              !any(grepl(";", out$truth_hull)))

  out |>
    mutate(truth_fishing = truth_hull == "fishing") |>
    relocate(truth_fishing, .after = truth_hull)
}

# Hull-level outcome of one version's GFW label against the truth:
#   TP fishing hull typed FISHING     FN fishing hull typed something else
#   FP non-fishing hull (or gear buoy) typed FISHING   TN otherwise
#   absent  the MMSI has no records in that version (inside the window)
hull_outcome <- function(truth_fishing, gfw_type) {
  typed_fishing <- gfw_type %in% "FISHING"
  case_when(is.na(gfw_type)                     ~ "absent",
            truth_fishing & typed_fishing       ~ "TP",
            truth_fishing & !typed_fishing      ~ "FN",
            !truth_fishing & typed_fishing      ~ "FP",
            TRUE                                ~ "TN")
}

# What happened to an error (or a correct label) between two versions, from
# the two hull_outcome() values:
#   corrected       wrong in old (FP/FN), right in new (TP/TN)
#   still wrong     the same error in both
#   new error       right in old, wrong in new
#   still correct   right in both
#   absent          not in the new version (or in neither)
#   new vessel      not in the old version
error_status <- function(old, new) {
  wrong <- \(x) x %in% c("FP", "FN")
  right <- \(x) x %in% c("TP", "TN")
  case_when(new == "absent"               ~ "absent",
            old == "absent"               ~ "new vessel",
            wrong(old) & right(new)       ~ "corrected",
            wrong(old) & wrong(new)       ~ "still wrong",
            right(old) & wrong(new)       ~ "new error",
            TRUE                          ~ "still correct")
}

# One row per MMSI with a reference gear class: accepted vessel_gear.csv rows
# (the analyst's class), plus rejected rows whose GFW gear then mapped to a
# specific class (the analyst let GFW's gear stand). Rejected rows whose GFW
# gear was unresolved carry no truth and are dropped. Every MMSI has at most
# one accepted gear row today; the stop guards that assumption.
gear_truth <- function(gear_inputs) {
  acc <- gear_inputs |> filter(decision == "accept")
  stopifnot("an MMSI has more than one accepted gear row" = !anyDuplicated(acc$MMSI))

  rej <- gear_inputs |>
    filter(decision == "reject", !MMSI %in% acc$MMSI) |>
    mutate(gear_class = gear_class_of(gfw_gear_type)) |>
    filter(gear_class != "UNRESOLVED") |>
    distinct(MMSI, .keep_all = TRUE)

  bind_rows(mutate(acc, truth_source = "accepted"),
            mutate(rej, truth_source = "confirmed")) |>
    select(MMSI, Vessel_Name, truth_gear = gear_class, truth_source, basis,
           evidence_ref, Notes)
}

# Gear outcome of one version's GFW gear code against the reference class:
#   correct     GFW's code maps to the reference class
#   unresolved  GFW gives no specific gear (generic FISHING, INCONCLUSIVE,
#               INSUFFICIENT_DATA, a non-fishing type's code, ...)
#   wrong       GFW's code maps to another specific class
#   absent      no records in that version
gear_outcome <- function(truth_gear, gfw_gear) {
  cls <- gear_class_of(gfw_gear)
  case_when(is.na(gfw_gear)             ~ "absent",
            cls == "UNRESOLVED"         ~ "unresolved",
            cls == truth_gear           ~ "correct",
            TRUE                        ~ "wrong")
}

# Ratios ---------------------------------------------------------------------

# new / old hours ratio and % change, NA where the old total is 0
pct_change <- function(old, new) if_else(old > 0, 100 * (new - old) / old, NA_real_)
