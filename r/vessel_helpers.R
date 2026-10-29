# Vessel classification helpers shared by 03_review_vessels.qmd and
# 04_classify_aggregate.qmd. Source after the tidyverse, r/paths.R and
# r/gfw_helpers.R:
#   source("r/paths.R"); source("r/gfw_helpers.R"); source("r/vessel_helpers.R")
#
# 03 builds the crosswalk and writes it to references/; 04 rebuilds it from the
# same tracked inputs and stops if the two differ, so the analysis tables can
# never be made from a stale crosswalk.

# Last day the Ørsted survey-date files cover; the build stops if a trip ends
# later. Move it when a new file arrives. It should not fall before
# analysis_end (r/gfw_helpers.R): survey trips after it are undated, so those
# records would count as fishing.
survey_dates_through <- as.Date("2026-08-31")

# File layouts --------------------------------------------------------------

# gfw_vessel_type, gfw_gear_type, pull_date and gfw_pipeline record the pull a
# row was made against: GFW's labels then, the pull date, and the GFW pipeline
# version (e.g. v4). A decision about a hull stays valid across versions; the
# version says which labels it was checked against.
cw_cols <- c("MMSI", "valid_from", "valid_to", "Vessel_Name", "hull_class",
             "activity_excluded", "Operation", "Identified_By",
             "evidence_ref", "gfw_vessel_type", "gfw_gear_type",
             "pull_date", "gfw_pipeline", "Notes")
decision_cols <- c("decision", "decided_on", cw_cols)

gear_cols <- c("decision", "decided_on", "MMSI", "valid_from", "valid_to",
               "Vessel_Name", "gear_class", "basis", "evidence_ref",
               "gfw_gear_type", "pull_date", "gfw_pipeline", "Notes")

hull_classes   <- c("fishing", "non_fishing", "gear_marker", "unknown")
gear_classes   <- c("MOBILE", "FIXED", "POLE_AND_LINE", "UNRESOLVED")
removal_scopes <- c("stages_2_3", "all_stages")

lo_date <- as.Date("1900-01-01") # stand-ins for open-ended windows
hi_date <- as.Date("2100-12-31")

read_chr <- function(path) {
  read_csv(path, col_types = cols(.default = col_character()), na = c("", "NA"))
}

empty_tbl <- function(cols) as_tibble(set_names(rep(list(character()), length(cols)), cols))

# Raw pull --------------------------------------------------------------------

# Date of the raw pull, recorded by 01_pull_gfw.qmd in pull_info.csv. Pulls
# made before that file existed fall back to the raw VP file's modification
# date, with a warning.
read_pull_date <- function(paths) {
  if (file.exists(paths$pull_info)) {
    as.Date(read_chr(paths$pull_info)$pull_date[1])
  } else {
    warning(paths$pull_info, " not found; using the modification date of ", paths$raw_vp,
            " as the pull date", call. = FALSE)
    # local date; as.Date() on a time would use UTC and can shift the day
    as.Date(format(file.mtime(paths$raw_vp), "%Y-%m-%d"))
  }
}

# GFW labels per MMSI as of this pull (most frequent, in case of a split)
gfw_labels_of <- function(vp, afe) {
  bind_rows(vp, afe) |>
    filter(!is.na(MMSI)) |>
    count(MMSI, `Vessel Type`, `Gear Type`) |>
    group_by(MMSI) |>
    slice_max(n, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(MMSI, gfw_vessel_type = `Vessel Type`, gfw_gear_type = `Gear Type`)
}

# Validation ------------------------------------------------------------------

# MMSIs with overlapping validity windows; f and t are Dates (NA = open-ended)
overlapping_mmsi <- function(mmsi, f, t) {
  tibble(MMSI = mmsi, f = coalesce(f, lo_date), t = coalesce(t, hi_date)) |>
    arrange(MMSI, f) |>
    group_by(MMSI) |>
    filter(lead(f) <= t | lag(t) >= f) |>
    pull(MMSI) |>
    unique()
}

# Stops with every problem found. `cw` has Date windows and a logical
# activity_excluded. With gfw_labels (the current pull) given, an MMSI that is
# not 9 digits must appear exactly as in the pull, which still catches MMSIs
# Excel damaged (scientific notation, dropped leading zeros); without it, as in
# the reference-file tests, that check is skipped.
validate_crosswalk <- function(cw, gfw_labels = NULL, source = "the crosswalk inputs") {
  overlaps <- overlapping_mmsi(cw$MMSI, cw$valid_from, cw$valid_to)

  bad_mmsi <- if (is.null(gfw_labels)) character() else {
    cw |>
      filter(hull_class != "gear_marker", !grepl("^[0-9]{9}$", MMSI),
             !MMSI %in% gfw_labels$MMSI) |>
      pull(MMSI) |>
      unique()
  }

  problems <- c(
    if (any(!cw$hull_class %in% hull_classes))
      "unknown hull_class",
    # checked when the column is there (it always is in the tracked files;
    # minimal test crosswalks leave it out)
    if ("gfw_pipeline" %in% names(cw) && anyNA(cw$gfw_pipeline))
      "gfw_pipeline is blank (the GFW pipeline version the row was made against)",
    if (anyNA(cw$activity_excluded))
      "activity_excluded must be TRUE or FALSE",
    if (length(bad_mmsi) > 0)
      paste0("MMSI is not 9 digits and not in the GFW pull: ",
             paste(bad_mmsi, collapse = ", ")),
    if (any(cw$valid_from > cw$valid_to, na.rm = TRUE))
      "valid_from after valid_to",
    if (length(overlaps) > 0)
      paste0("overlapping windows for MMSI: ", paste(overlaps, collapse = ", "))
  )

  if (length(problems) > 0) {
    stop("Invalid crosswalk (check ", source, "):\n  - ",
         paste(problems, collapse = "\n  - "), call. = FALSE)
  }
  invisible(cw)
}

# Types a crosswalk read as character (vessel_crosswalk_{pipeline}.csv, or build_crosswalk()
# output) and validates it
type_crosswalk <- function(cw_chr, gfw_labels = NULL, source = "the crosswalk inputs") {
  cw_chr |>
    mutate(valid_from = as.Date(valid_from),
           valid_to   = as.Date(valid_to),
           activity_excluded = as.logical(activity_excluded)) |>
    validate_crosswalk(gfw_labels, source)
}

# Accepted gear corrections with Date windows, after checking every row
validate_gear <- function(gear_inputs, source = "the gear file") {
  gear <- gear_inputs |>
    filter(decision == "accept") |>
    mutate(valid_from = as.Date(valid_from), valid_to = as.Date(valid_to))

  overlaps <- overlapping_mmsi(gear$MMSI, gear$valid_from, gear$valid_to)

  problems <- c(
    if (!all(gear_inputs$decision %in% c("accept", "reject")))
      "decision must be accept or reject",
    if (any(!gear$gear_class %in% gear_classes))
      "gear_class must be MOBILE, FIXED, POLE_AND_LINE or UNRESOLVED",
    if ("gfw_pipeline" %in% names(gear_inputs) && anyNA(gear_inputs$gfw_pipeline))
      "gfw_pipeline is blank (the GFW pipeline version the row was made against)",
    if (any(gear$valid_from > gear$valid_to, na.rm = TRUE))
      "valid_from after valid_to",
    if (length(overlaps) > 0)
      paste0("overlapping windows for MMSI: ", paste(overlaps, collapse = ", "))
  )
  if (length(problems) > 0) {
    stop("Invalid ", source, ":\n  - ", paste(problems, collapse = "\n  - "),
         call. = FALSE)
  }
  gear
}

# Building the crosswalk --------------------------------------------------------

# Ørsted survey-file names vary across rows ("F/V Heather Lynn", "Cailyn and
# Maren"), so they are upper-cased and stripped of an F/V prefix before being
# matched to orsted_survey_vessels.csv
norm_survey_name <- function(x) str_squish(str_remove(toupper(x), "^F/?V\\s+"))

# The crosswalk, as character columns in cw_cols order, from the removal list,
# the Ørsted survey-date files and the accepted decisions. Precedence: a
# decision replaces survey-date and removal-list rows; survey-date rows replace
# removal-list rows. Safety vessels keep their removal-list row, since the
# survey files do not date guard and scout work.
build_crosswalk <- function(paths, decisions, gfw_labels, pull_date) {
  stage2_start <- as.character(dev_stages$start[dev_stages$stage == "Stage 2"])

  removal_list <- read_chr(paths$removals)
  survey_names <- read_chr(paths$survey_vessels)
  survey_files <- Sys.glob(paths$survey_dates)

  survey_trips <- survey_files |>
    map(\(p) read_csv(p, col_types = cols(.default = col_character()),
                      col_select = c(Project, `Departure Date`, `Return Date`, Vessel),
                      name_repair = "unique_quiet") |>
          mutate(source_file = basename(p))) |>
    list_rbind() |>
    filter(!is.na(Vessel)) |>              # the files carry blank spacer rows
    mutate(Vessel = str_split(Vessel, ",\\s*")) |> # some rows list two vessels
    unnest(Vessel) |>
    mutate(survey_name = norm_survey_name(Vessel),
           dep = as.Date(`Departure Date`, optional = TRUE),
           ret = as.Date(`Return Date`, optional = TRUE)) |>
    left_join(select(survey_names, survey_name, MMSI, Vessel_Name), by = "survey_name")

  survey_problems <- c(
    if (anyNA(survey_trips$MMSI))
      paste0("vessel names not in ", paths$survey_vessels, ": ",
             paste(unique(survey_trips$Vessel[is.na(survey_trips$MMSI)]), collapse = ", ")),
    if (anyNA(survey_trips$dep) || anyNA(survey_trips$ret))
      "a Departure or Return Date is not an ISO date (YYYY-MM-DD)",
    if (any(survey_trips$ret < survey_trips$dep, na.rm = TRUE))
      "a Return Date is before its Departure Date",
    if (any(survey_trips$ret > survey_dates_through, na.rm = TRUE))
      paste0("trips end after survey_dates_through (", survey_dates_through,
             "); move it in r/vessel_helpers.R")
  )
  if (length(survey_problems) > 0) {
    stop("Invalid survey dates:\n  - ", paste(survey_problems, collapse = "\n  - "), call. = FALSE)
  }
  if (survey_dates_through < analysis_end) {
    warning("survey_dates_through (", survey_dates_through, ") is before analysis_end (",
            analysis_end, "): survey vessels' records in between count as fishing",
            call. = FALSE)
  }

  # survey vessels whose removal-list row is replaced: not Safety vessels (their
  # guard/scout dates are not in the files) and not vessels with a decision
  safety_mmsi <- removal_list$MMSI[removal_list$Operation %in% "Safety"]
  survey_mmsi <- setdiff(unique(survey_trips$MMSI), c(decisions$MMSI, safety_mmsi))

  kept_open <- intersect(unique(survey_trips$MMSI), safety_mmsi)
  if (length(kept_open) > 0) {
    message("Survey dates not applied to Safety vessels (removal-list row kept): ",
            paste(kept_open, collapse = ", "))
  }

  # one window per run of overlapping or touching trips
  survey_windows <- survey_trips |>
    filter(MMSI %in% survey_mmsi) |>
    arrange(MMSI, dep) |>
    group_by(MMSI, Vessel_Name) |>
    mutate(window = cumsum(as.numeric(dep) >
                             lag(cummax(as.numeric(ret)), default = -Inf) + 1)) |>
    group_by(MMSI, Vessel_Name, window) |>
    summarise(valid_from = min(dep), valid_to = max(ret), trips = n(),
              projects = paste(sort(unique(na.omit(Project))), collapse = "; "),
              evidence_ref = paste(sort(unique(source_file)), collapse = "; "),
              .groups = "drop") |>
    transmute(MMSI, Vessel_Name,
              valid_from = as.character(valid_from), valid_to = as.character(valid_to),
              evidence_ref,
              Notes = paste0(trips, if_else(trips == 1, " survey trip", " survey trips"),
                             if_else(projects == "", "", paste0(": ", projects))))

  survey_rows <- survey_windows |>
    mutate(hull_class = "fishing", activity_excluded = "TRUE", Operation = "Survey",
           Identified_By = "orsted_survey_dates",
           pull_date = as.character(.env$pull_date),
           gfw_pipeline = paths$pipeline) |>
    left_join(gfw_labels, by = "MMSI")

  removal_rows <- removal_list |>
    filter(!MMSI %in% decisions$MMSI, !MMSI %in% survey_mmsi) |>
    transmute(MMSI, Vessel_Name,
              valid_from = if_else(Scope == "stages_2_3", stage2_start, NA_character_),
              valid_to   = NA_character_,
              hull_class = if_else(Scope == "stages_2_3", "fishing", "non_fishing"),
              activity_excluded = if_else(Scope == "stages_2_3", "TRUE", "FALSE"),
              Operation, Identified_By,
              evidence_ref = NA_character_,
              # the pull the crosswalk was built against (pull_info.csv) and
              # its GFW pipeline version
              pull_date = as.character(.env$pull_date),
              gfw_pipeline = paths$pipeline,
              Notes) |>
    # GFW's labels for these vessels in that pull
    left_join(gfw_labels, by = "MMSI")

  bind_rows(removal_rows, survey_rows,
            decisions |> filter(decision == "accept") |> select(all_of(cw_cols))) |>
    select(all_of(cw_cols)) |>
    arrange(MMSI, valid_from)
}

# Classification ----------------------------------------------------------------

# Matches each record to at most one crosswalk row and one gear row by MMSI and
# date, then sets the Strict and Primary flags and the record's gear class
classify <- function(df, cw, gear) {
  cw_join <- cw |>
    transmute(MMSI,
              cw_from = coalesce(valid_from, lo_date),
              cw_to   = coalesce(valid_to, hi_date),
              cw_hull = hull_class,
              cw_excluded = activity_excluded,
              cw_identified_by = Identified_By)

  gear_join <- gear |>
    transmute(MMSI,
              g_from = coalesce(valid_from, lo_date),
              g_to   = coalesce(valid_to, hi_date),
              gear_override = gear_class)

  out <- df |>
    left_join(cw_join, by = join_by(MMSI, between(date, cw_from, cw_to))) |>
    left_join(gear_join, by = join_by(MMSI, between(date, g_from, g_to)))

  stopifnot("a record matched more than one crosswalk or gear row" = nrow(out) == nrow(df))

  out |>
    mutate(
      gfw_fishing = `Vessel Type` %in% "FISHING",
      is_marker   = cw_hull %in% "gear_marker",
      nonfish     = cw_hull %in% "non_fishing",
      added       = cw_hull %in% "fishing" & !gfw_fishing,
      excluded    = cw_excluded %in% TRUE,
      in_strict   = gfw_fishing,
      in_primary  = (gfw_fishing | added) & !is_marker & !nonfish & !excluded,
      # gear_class_gfw is GFW's gear only, for the Strict set
      gear_class_gfw = gear_class_of(`Gear Type`),
      gear_class  = coalesce(gear_override, gear_class_gfw),
      gear_source = if_else(is.na(gear_override), "gfw", "vessel_gear")) |>
    select(-cw_from, -cw_to, -g_from, -g_to, -gear_override)
}

# Fishing roster ----------------------------------------------------------------
# A write-once snapshot of every MMSI that counted as fishing in one GFW
# pipeline version (planning/gfw_pipeline_v5_plan.qmd, Section 2.7). When GFW
# reprocesses its data and relabels vessels, the next version's run of 03
# compares the new labels with this snapshot, so a known fishing vessel whose
# vessel or gear type changed is sent to review instead of silently leaving the
# Strict and Primary sets. 03 writes it once per version, with
# write_roster_once(); it is never regenerated.

roster_cols <- c(
  "MMSI", "pipeline", "pull_date", "source_commit", "Vessel_Name",
  # GFW's labels for the MMSI in this pull (gfw_labels_of(): most frequent)
  "gfw_vessel_type", "gfw_gear_type",
  # the analysis gear class the records actually got (correction or GFW gear),
  # hours-weighted most frequent, and where it came from
  "gear_class", "gear_source",
  # why the MMSI is on the roster; at least one is TRUE
  "src_gfw_fishing", "src_cw_fishing", "src_gear_correction", "src_garfo_permit",
  "permit_group",
  # whether any of its records is in the Primary set
  "in_primary",
  "vp_hours_s1", "vp_hours_s2", "vp_hours_s3",
  "afe_hours_s1", "afe_hours_s2", "afe_hours_s3",
  "vessel_ids", "first", "last")

# GARFO permit groups that mark a vessel as fishing for the roster. The other
# groups 03 can write ("recreational only", "unmapped codes only") do not.
roster_permit_groups <- c("commercial", "for-hire", "commercial + for-hire",
                          "for-hire + open-access commercial")

# One row per MMSI with records in this pull that counted as fishing by any
# source, in roster_cols order:
#   src_gfw_fishing      any of its records is typed FISHING by GFW
#   src_cw_fishing       the crosswalk has a fishing-hull row for it
#   src_gear_correction  vessel_gear.csv has an accepted correction for it
#   src_garfo_permit     a unique GARFO match puts it in a fishing permit group
# vp and afe are read_gfw() records (already trimmed to the analysis window),
# cw a typed crosswalk (type_crosswalk()), gear the accepted gear rows
# (validate_gear()), permit_groups the vessel_permit_groups_{pipeline}.csv table, and
# gfw_labels the gfw_labels_of() table for the same pull.
build_fishing_roster <- function(vp, afe, cw, gear, permit_groups, gfw_labels,
                                 pull_date, pipeline, source_commit = NA_character_) {
  # classify every record as 04 does, so in_primary and gear_class are the
  # values the analysis used
  recs <- bind_rows(VP  = classify(vp, cw, gear),
                    AFE = classify(afe, cw, gear), .id = "dataset") |>
    filter(!is.na(MMSI))

  fishing_permits <- permit_groups |> filter(permit_group %in% roster_permit_groups)

  # the four sources, per MMSI
  sources <- tibble(MMSI = unique(recs$MMSI)) |>
    mutate(src_gfw_fishing     = MMSI %in% recs$MMSI[recs$`Vessel Type` %in% "FISHING"],
           src_cw_fishing      = MMSI %in% cw$MMSI[cw$hull_class == "fishing"],
           src_gear_correction = MMSI %in% gear$MMSI,
           src_garfo_permit    = MMSI %in% fishing_permits$MMSI) |>
    filter(src_gfw_fishing | src_cw_fishing | src_gear_correction | src_garfo_permit)

  # MMSIs named by the crosswalk, gear or permit files but with no records in
  # this pull's analysis window cannot be compared with a later pull, so they
  # are left off; say how many
  named <- unique(c(cw$MMSI[cw$hull_class == "fishing"], gear$MMSI, fishing_permits$MMSI))
  no_records <- setdiff(named, recs$MMSI)
  if (length(no_records) > 0) {
    message(length(no_records), " fishing MMSIs in references/ have no records in this ",
            "pull's analysis window and are not on the roster")
  }

  recs <- recs |> filter(MMSI %in% sources$MMSI)

  # VP and AFE hours per stage, one column per dataset x stage, 0 where none
  hour_cols <- paste0(rep(c("vp", "afe"), each = 3), "_hours_s", 1:3)
  hours <- recs |>
    mutate(col = paste0(tolower(dataset), "_hours_s",
                        str_extract(`Development Stage`, "\\d"))) |>
    count(MMSI, col, wt = hours) |>
    pivot_wider(names_from = col, values_from = n, values_fill = 0)
  for (col in setdiff(hour_cols, names(hours))) hours[[col]] <- 0

  # the gear class the records got, weighted by hours (ties: the first)
  gear_now <- recs |>
    count(MMSI, gear_class, gear_source, wt = hours) |>
    group_by(MMSI) |>
    slice_max(n, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(MMSI, gear_class, gear_source)

  # most frequent AIS name, Primary membership, Vessel IDs and the date span
  per_mmsi <- recs |>
    group_by(MMSI) |>
    summarise(Vessel_Name = names(which.max(table(`Vessel Name`)))[1] %||% NA_character_,
              in_primary  = any(in_primary),
              vessel_ids  = paste(sort(unique(na.omit(`Vessel ID`))), collapse = "|"),
              first       = as.character(min(date)),
              last        = as.character(max(date)),
              .groups = "drop")

  sources |>
    left_join(per_mmsi, by = "MMSI") |>
    left_join(select(gfw_labels, MMSI, gfw_vessel_type, gfw_gear_type), by = "MMSI") |>
    left_join(gear_now, by = "MMSI") |>
    left_join(select(permit_groups, MMSI, permit_group), by = "MMSI") |>
    left_join(hours, by = "MMSI") |>
    mutate(pipeline = pipeline,
           pull_date = as.character(pull_date),
           source_commit = source_commit,
           across(all_of(hour_cols), \(x) round(x, 3))) |>
    select(all_of(roster_cols)) |>
    arrange(MMSI)
}

# Writes a roster to path only if no file is there yet: a roster is the record
# of one pipeline version as it was analysed, so it is never replaced. To
# rebuild one deliberately, delete the file (and say why in the commit).
write_roster_once <- function(roster, path) {
  if (file.exists(path)) {
    stop(path, " already exists. A fishing roster is written once per pipeline ",
         "version and never replaced; delete it first only if it must be rebuilt.",
         call. = FALSE)
  }
  stopifnot("roster columns do not match roster_cols" = identical(names(roster), roster_cols),
            "roster has a repeated MMSI" = !anyDuplicated(roster$MMSI),
            "roster has more than one pipeline" = n_distinct(roster$pipeline) == 1)
  write_csv(roster, path, na = "")
  message("Wrote ", nrow(roster), " MMSIs to ", path)
  invisible(path)
}

# Roster check ------------------------------------------------------------------
# On a later pipeline version's run, 03 compares the previous version's roster
# with the current pull (planning/gfw_pipeline_v5_plan.qmd, Section 3.6, Part B)
# and 04 checks that every roster vessel is accounted for (Part C).

# The roster a run compares against: the newest roster written for a pipeline
# version other than `pipeline` (v4 on a v5 run), or NULL if there is none (a
# v4 run). Versions are ordered by their number, so v10 comes after v9.
# `template` is paths$roster, e.g. "references/fishing_roster_%s.csv".
previous_roster_path <- function(template, pipeline) {
  files <- Sys.glob(sprintf(template, "*"))
  # the version each file names: what sits where the template has %s
  ends     <- strsplit(basename(template), "%s", fixed = TRUE)[[1]]
  versions <- substring(basename(files), nchar(ends[1]) + 1,
                        nchar(basename(files)) - nchar(ends[2]))
  keep <- versions != pipeline
  if (!any(keep)) return(NULL)
  files <- files[keep]; versions <- versions[keep]
  # numeric part of the version (v4 -> 4, v4.1 -> 4.1), then the name itself
  num <- suppressWarnings(as.numeric(sub("^v", "", versions)))
  files[order(num, versions)][length(files)]
}

# One row per change in the current pull for a roster MMSI:
#   type        GFW's vessel type differs from the roster's
#   gear_class  the analysis gear class the records now get differs from the
#               roster's (a type change usually brings one too; both are listed)
#   missing     the MMSI has no records in the current pull's analysis window
# roster is a fishing_roster_*.csv read with read_chr(); gfw_labels the
# gfw_labels_of() table of the current pull; gear_now one row per MMSI with
# the gear class its current records get (classify(), hours-weighted, as in
# build_fishing_roster()); cw the current typed crosswalk; gear the accepted
# gear rows. A change is `protected` when an analyst's decision already
# settles it whatever GFW now says: a type change when the MMSI has a
# crosswalk row (its hull class is decided), a gear-class change when it has
# a gear correction. Protected changes are kept for the record.
roster_changes <- function(roster, gfw_labels, gear_now, cw, gear) {
  base <- roster |>
    transmute(MMSI, Vessel_Name, in_primary = as.logical(in_primary),
              type_old = gfw_vessel_type, gear_old = gfw_gear_type,
              class_old = gear_class,
              vp_hours_old  = as.numeric(vp_hours_s1) + as.numeric(vp_hours_s2) + as.numeric(vp_hours_s3),
              afe_hours_old = as.numeric(afe_hours_s1) + as.numeric(afe_hours_s2) + as.numeric(afe_hours_s3)) |>
    left_join(transmute(gfw_labels, MMSI, type_new = gfw_vessel_type, gear_new = gfw_gear_type),
              by = "MMSI") |>
    left_join(transmute(gear_now, MMSI, class_new = gear_class), by = "MMSI") |>
    mutate(present = MMSI %in% gfw_labels$MMSI)

  # NA-safe "differs": a label that appears or disappears counts as a change
  differs <- \(a, b) coalesce(a != b, !(is.na(a) & is.na(b)))

  bind_rows(
    base |> filter(!present) |> mutate(change = "missing", protected = FALSE),
    base |> filter(present, differs(type_old, type_new)) |>
      mutate(change = "type", protected = MMSI %in% cw$MMSI),
    base |> filter(present, differs(class_old, class_new)) |>
      mutate(change = "gear_class", protected = MMSI %in% gear$MMSI)) |>
    select(MMSI, Vessel_Name, change, protected, in_primary, type_old, type_new,
           gear_old, gear_new, class_old, class_new, vp_hours_old, afe_hours_old) |>
    arrange(match(change, c("type", "gear_class", "missing")), desc(afe_hours_old), MMSI)
}
