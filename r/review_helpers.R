# Vessel review helpers for 03_review_vessels.qmd: collecting marked review
# rows, the per-MMSI screen, GARFO permit matching, the GFW identity and USCG
# PSIX evidence, and the gear evidence. Source after the tidyverse,
# r/paths.R, r/gfw_helpers.R and r/vessel_helpers.R:
#   source("r/paths.R"); source("r/gfw_helpers.R"); source("r/vessel_helpers.R")
#   source("r/review_helpers.R")
#
# Moved out of 03 unchanged (2026-10-28), except that the screening thresholds
# the functions used from 03's global `screen` list are now arguments, so each
# function depends only on what it is given. The thresholds themselves stay in
# 03's Parameters chunk, where any change is recorded.

# Phase 1: decisions --------------------------------------------------------

# Copies rows marked accept/reject in a generated review sheet into its input
# file, skipping MMSIs the input file already has, and returns the input file.
# A sheet written before the gfw_pipeline column existed was generated from
# this version's pull (the sheets live in a version folder), so its rows get
# `pipeline`.
collect_marked <- function(sheet, input, cols, pipeline) {
  current <- if (file.exists(input)) read_chr(input) else empty_tbl(cols)
  stopifnot("input file is missing columns" = all(cols %in% names(current)))

  marked <- if (file.exists(sheet)) {
    s <- read_chr(sheet)
    if (!"gfw_pipeline" %in% names(s)) s$gfw_pipeline <- pipeline
    s |>
      filter(decision %in% c("accept", "reject")) |>
      mutate(decided_on = coalesce(decided_on, as.character(Sys.Date()))) |>
      select(all_of(cols))
  } else {
    current[0, ]
  }

  skipped <- semi_join(marked, current, by = "MMSI")
  if (nrow(skipped) > 0) {
    warning(nrow(skipped), " rows in ", sheet, " were skipped because their MMSI ",
            "is already in ", input, "; edit that file to change them", call. = FALSE)
  }

  new_rows <- anti_join(marked, current, by = "MMSI")
  if (nrow(new_rows) > 0) {
    current <- bind_rows(current, new_rows) |> select(all_of(cols))
    write_csv(current, input, na = "")
    message("Added ", nrow(new_rows), " rows to ", input)
  }

  stopifnot("decision must be accept or reject" =
              all(current$decision %in% c("accept", "reject")))
  current
}

# Phase 2: per-MMSI profile -------------------------------------------------

# One row per MMSI: names, flag and call sign, VP hours in total and by stage,
# active days, hours per day, the share of hours inside the leases overall
# and by stage (for the charter screen), the first and last Stage 3 day in a
# lease, AFE hours, and GFW's labels (`gfw_labels`, from gfw_labels_of()).
# `cell_lease` flags each grid cell whose centre is inside SFW, RWF or SRW.
profile_mmsi <- function(vp, afe, cell_lease, gfw_labels) {
  v <- vp |> filter(!is.na(MMSI)) |> left_join(cell_lease, by = "cell_id")
  a <- afe |> filter(!is.na(MMSI))

  stage_hours <- function(h, stage, s) sum(h[stage == s])

  pv <- v |>
    group_by(MMSI) |>
    summarise(
      names     = paste(sort(unique(na.omit(`Vessel Name`))), collapse = " / "),
      flag      = first(na.omit(Flag)),
      call_sign = first(na.omit(CallSign)),
      vp_hours  = sum(hours),
      s1 = stage_hours(hours, `Development Stage`, "Stage 1"),
      s2 = stage_hours(hours, `Development Stage`, "Stage 2"),
      s3 = stage_hours(hours, `Development Stage`, "Stage 3"),
      days  = n_distinct(date),
      h_day = vp_hours / days,
      lease_share     = sum(hours[in_lease]) / vp_hours,
      lease_share_s12 = if (s1 + s2 > 0)
        sum(hours[in_lease & `Development Stage` != "Stage 3"]) / (s1 + s2) else NA_real_,
      lease_share_s3  = if (s3 > 0)
        sum(hours[in_lease & `Development Stage` == "Stage 3"]) / s3 else NA_real_,
      s3_lease_first = suppressWarnings(min(date[in_lease & `Development Stage` == "Stage 3"])),
      s3_lease_last  = suppressWarnings(max(date[in_lease & `Development Stage` == "Stage 3"])),
      first = min(date),
      last  = max(date),
      .groups = "drop") |>
    mutate(across(c(s3_lease_first, s3_lease_last), \(x) if_else(is.finite(x), x, NA)))

  pa <- a |>
    group_by(MMSI) |>
    summarise(afe_hours = sum(hours),
              afe_s3 = sum(hours[`Development Stage` == "Stage 3"]),
              .groups = "drop")

  pv |>
    left_join(pa, by = "MMSI") |>
    left_join(gfw_labels, by = "MMSI") |>
    mutate(afe_hours = coalesce(afe_hours, 0),
           afe_s3    = coalesce(afe_s3, 0),
           mmsi_valid = grepl("^[0-9]{9}$", MMSI),
           battery_call_sign = str_detect(coalesce(call_sign, ""), "%"))
}

# Phase 2: GARFO permit matches ---------------------------------------------

# Only vessel fields are read from the GARFO permit lists; owner names,
# telephone numbers and addresses are never loaded.
garfo_personal <- c("OWNER NAME", "TELEPHONE", "ADDRESS LINE 1", "ADDRESS LINE 2",
                    "CITY", "STATE", "ZIP CODE", "HOME PORT CITY",
                    "PRINCIPAL PORT CITY")

# vessel fields; every other column of an annual file is a fishery holding
# that permit-year's codes
garfo_vessel_cols <- c("PERMIT", "HMS PERMIT", "PERMIT YEAR", "VESSEL NAME",
                       "HULL ID", "HOME PORT STATE", "PRINCIPAL PORT STATE",
                       "LENGTH", "GROSS TONS", "HORSEPOWER", "MAX TRAP LIMIT",
                       "CATEGORY", "CML CHB ENDORSEMENT", "ISSUEDDATE")

# GARFO vessel names too generic to link a hull to an MMSI
placeholder_names <- c("UNNAMED", "NONAME", "NONE", "NA", "SKIFF", "UNKNOWN")

# vessel name as a match key: upper case, "&" as AND, no F/V prefix, letters
# and digits only
norm_name <- function(x) {
  x |>
    toupper() |>
    str_replace_all("&", " AND ") |>
    str_remove("^[[:space:]]*(F[[:space:]]*/[[:space:]]*V|F[.]V[.]|FV)[[:space:]]+") |>
    str_remove_all("[^A-Z0-9]")
}

# a column of `d`, or NA for every row when the file does not have it (the
# annual and HMS files have different columns)
col_or_na <- function(d, col) if (col %in% names(d)) d[[col]] else rep(NA_character_, nrow(d))

# One GARFO permit file -> list(permits = one row per permit-year, codes = one
# row per permit-year x fishery x code).
read_garfo <- function(f) {
  d <- read_csv(f, col_types = cols(.default = col_character()),
                col_select = !any_of(garfo_personal),
                na = c("", " ", "NA", "None"), show_col_types = FALSE)
  names(d) <- str_remove(names(d), paste0("^", intToUtf8(0xFEFF))) # byte-order mark

  hms <- "HMS PERMIT" %in% names(d)

  permits <- tibble(
    file        = basename(f),
    source      = if (hms) "garfo_hms" else "garfo_permits",
    permit      = coalesce(col_or_na(d, "PERMIT"), col_or_na(d, "HMS PERMIT")),
    permit_year = suppressWarnings(as.integer(col_or_na(d, "PERMIT YEAR"))),
    vessel_name = col_or_na(d, "VESSEL NAME"),
    hull_id     = col_or_na(d, "HULL ID"),
    home_port_state = col_or_na(d, "HOME PORT STATE"),
    length_ft   = suppressWarnings(as.numeric(col_or_na(d, "LENGTH"))),
    trap_limit  = suppressWarnings(as.numeric(col_or_na(d, "MAX TRAP LIMIT"))))

  # one row per permit-year x fishery x code. Annual files hold one column
  # per fishery with comma-separated codes; the HMS file has a CATEGORY.
  fishery <- setdiff(names(d), garfo_vessel_cols)
  codes <- if (hms) {
    # a charter/headboat permit endorsed for commercial sale is a second,
    # commercial code for the same permit
    bind_rows(
      tibble(permit = permits$permit, permit_year = permits$permit_year,
             fishery = "HMS", code = col_or_na(d, "CATEGORY")),
      tibble(permit = permits$permit, permit_year = permits$permit_year,
             fishery = "HMS",
             code = if_else(col_or_na(d, "CML CHB ENDORSEMENT") %in% "Y",
                            "CHB COMMERCIAL SALE ENDORSEMENT", NA_character_)))
  } else {
    bind_cols(select(permits, permit, permit_year), d[fishery]) |>
      pivot_longer(all_of(fishery), names_to = "fishery", values_to = "code",
                   values_drop_na = TRUE) |>
      separate_longer_delim(code, ",")
  }
  codes <- codes |>
    mutate(file = basename(f), code = str_trim(code)) |>
    filter(!is.na(code), code != "")

  list(permits = permits, codes = codes)
}

# Summarise grouped matches: per MMSI (garfo_by_mmsi), and per MMSI and GARFO
# hull (garfo_by_hull), which Phase 4 uses when a registry length singles out
# one hull of an ambiguous name. `oa_bundle_min` is the number of open-access
# commercial permits that marks a party-boat bundle (03's
# screen$oa_bundle_min).
summarise_garfo <- function(m, oa_bundle_min) {
  m |>
    summarise(
      garfo_hulls = n_distinct(hull_id),
      garfo_max_hulls_with_name = max(hulls_with_name),
      garfo_max_mmsi_with_name  = max(mmsi_with_name),
      garfo_mmsi_overlap  = any(mmsi_with_name > 1 & mmsi_overlap),
      garfo_mmsi_sequence = any(mmsi_with_name > 1 & !mmsi_overlap),
      year_overlap     = any(permit_year >= year(first) & permit_year <= year(last)),
      garfo_years      = paste(sort(unique(permit_year)), collapse = ","),
      garfo_hull_id    = paste(sort(unique(hull_id)), collapse = "|"),
      hull_is_uscg     = all(hull_is_uscg),
      garfo_permits    = paste(sort(unique(permit)), collapse = "|"),
      garfo_sources    = paste(sort(unique(source)), collapse = "|"),
      garfo_length_ft  = median(length_ft, na.rm = TRUE),
      garfo_home_port  = paste(sort(unique(na.omit(home_port_state))), collapse = "|"),
      garfo_categories = str_trunc(paste(unique(na.omit(categories)), collapse = " / "), 300),
      any_commercial_la = any(commercial_la),
      any_commercial_oa = any(commercial_oa),
      any_for_hire      = any(for_hire),
      any_recreational  = any(recreational),
      any_fixed         = any(fixed_hint),
      any_mobile        = any(mobile_hint),
      garfo_oa_permits  = paste(sort(unique(unlist(str_split(oa_permits, fixed("|"))))) |>
                                 setdiff(""), collapse = "|"),
      garfo_oa_directed = paste(sort(unique(unlist(str_split(oa_directed_permits, fixed("|"))))) |>
                                 setdiff(""), collapse = "|"),
      .groups = "drop") |>
    mutate(garfo_length_ft = if_else(is.nan(garfo_length_ft), NA_real_, garfo_length_ft),
           garfo_match = case_when(
             garfo_hulls > 1 | garfo_mmsi_overlap ~ "ambiguous",
             !year_overlap                        ~ "unique_no_year_overlap",
             TRUE                                 ~ "unique_years"),
           garfo_n_oa = if_else(garfo_oa_permits == "", 0L,
                                str_count(garfo_oa_permits, fixed("|")) + 1L),
           # Open-access commercial permits are easy to obtain, so for-hire
           # vessels often hold them without fishing commercially. Keep that
           # combination as its own type rather than folding it into either
           # "for-hire" or "commercial + for-hire".
           garfo_permit_type = case_when(
             any_commercial_la & any_for_hire ~ "commercial + for-hire",
             any_commercial_oa & any_for_hire ~ "for-hire + open-access commercial",
             any_for_hire                     ~ "for-hire",
             any_commercial_la | any_commercial_oa ~ "commercial",
             any_recreational                 ~ "recreational only",
             TRUE                             ~ "unmapped codes only"),
           garfo_oa_bundle = garfo_permit_type == "for-hire + open-access commercial" &
                             garfo_n_oa >= oa_bundle_min,
           # gear hint only when it is unambiguous; a for-hire vessel with a
           # small set of open-access commercial permits may fish commercially
           garfo_gear_hint = case_when(
             garfo_permit_type == "for-hire"           ~ "POLE_AND_LINE",
             garfo_oa_bundle                           ~ "POLE_AND_LINE",
             any_for_hire                              ~ NA_character_,
             any_fixed & !any_mobile                   ~ "FIXED",
             any_mobile & !any_fixed                   ~ "MOBILE",
             TRUE                                      ~ NA_character_)) |>
    select(-starts_with("any_"))
}

# Phase 2: candidate lists --------------------------------------------------

# Charter screen on the per-MMSI profile: a lease-concentrated Stage 3 with
# either no Stage 1-2 history (a burst) or a lease share that rose from
# Stages 1-2 to Stage 3. `screen` is 03's list of thresholds (min_s3_hours,
# min_lease_share, max_prior_hours, min_lease_shift).
charter_screen <- function(p, screen) {
  p |>
    mutate(burst = s1 + s2 <= screen$max_prior_hours &
                   lease_share >= screen$min_lease_share,
           shift = !is.na(lease_share_s12) & !is.na(lease_share_s3) &
                   lease_share_s3 - lease_share_s12 >= screen$min_lease_shift,
           charter_flag = s3 >= screen$min_s3_hours & (burst | shift))
}

# Speed check for the charter screen (decision 2026-10-30, D-072). Safety
# and guard vessels standing by a construction site log AFE while holding
# station or drifting, so their AFE days are slow; a fishing vessel that
# simply works the lease areas tows at fishing speed. Only pulls from GFW
# pipeline v5 on have the presence `Speed` field (the mean speed, in knots,
# of a vessel-cell-day), so on a v4 pull this returns NULL and the check is
# skipped.
#
# One row per MMSI with AFE in `stage`:
#   afe_speed_h    AFE hours on days that have a speed (VP records that day)
#   afe_lt2        share of those hours on days with a mean speed < 2 kn
#   afe_lt4        share on days < 4 kn
#   afe_median_kn  median day speed over its AFE days
# A day's speed is the VP-hours-weighted mean of its records' `Speed`, the
# same measure as the pipeline comparison report's speed table.
afe_speed_profile <- function(vp, afe, stage = "Stage 3") {
  if (!"Speed" %in% names(vp)) return(NULL)

  day_speed <- vp |>
    filter(!is.na(MMSI), hours > 0) |>
    mutate(speed = suppressWarnings(as.numeric(Speed))) |>
    filter(!is.na(speed)) |>
    group_by(MMSI, date) |>
    summarise(speed = weighted.mean(speed, hours), .groups = "drop")

  afe |>
    filter(!is.na(MMSI), `Development Stage` %in% stage) |>
    group_by(MMSI, date) |>
    summarise(afe = sum(hours), .groups = "drop") |>
    inner_join(day_speed, by = c("MMSI", "date")) |>
    group_by(MMSI) |>
    summarise(afe_speed_h   = sum(afe),
              afe_lt2       = sum(afe[speed < 2]) / afe_speed_h,
              afe_lt4       = sum(afe[speed < 4]) / afe_speed_h,
              afe_median_kn = median(speed),
              .groups = "drop")
}

# The speed check's verdict for each vessel, from afe_speed_profile()'s
# columns and 03's thresholds (screen$speed_min_afe_h, screen$standby_min_lt4,
# screen$underway_max_lt4):
#   standby-like   most AFE on slow days, as for the listed safety vessels
#   underway       most AFE at fishing or transit speed: check the vessel's
#                  GARFO permits before accepting a charter exclusion
#   mixed          in between
#   too few hours  too little AFE with a speed to judge
#   NA             no speed in the pull (v4), so no check
# The thresholds were set on the v5 pull: every Ørsted-listed safety vessel
# with at least 20 Stage 3 AFE h in its window had >= 77% of it on days
# below 4 kn, against 59% for ordinary mobile-gear AFE.
speed_class <- function(afe_speed_h, afe_lt4, screen) {
  case_when(is.na(afe_speed_h)                      ~ NA_character_,
            afe_speed_h < screen$speed_min_afe_h     ~ "too few hours",
            afe_lt4 >= screen$standby_min_lt4        ~ "standby-like",
            afe_lt4 <  screen$underway_max_lt4       ~ "underway",
            TRUE                                     ~ "mixed")
}

# Phase 3: evidence caches --------------------------------------------------

# Append rows to a cache CSV, creating it (with a header) on first write.
append_csv <- function(df, path) {
  if (nrow(df) > 0) write_csv(df, path, append = file.exists(path), na = "")
}

# Read a cache CSV as character columns, or an empty table with `cols` when
# the cache does not exist yet (a bare clone, or no lookups made).
read_ev <- function(path, cols) {
  if (file.exists(path)) {
    read_chr(path)
  } else {
    empty_tbl(cols)
  }
}

# character column from an API data frame; list columns collapsed with "|"
col_chr <- function(df, col) {
  if (!col %in% names(df)) return(rep(NA_character_, nrow(df)))
  x <- df[[col]]
  if (is.list(x)) map_chr(x, \(v) paste(unique(unlist(v)), collapse = "|"))
  else as.character(x)
}

# Phase 3: GFW vessel-identity API ------------------------------------------

# columns of the three identity caches: what was queried, the registry
# records, and GFW's combined gear and ship types
queried_cols  <- c("vessel_id", "queried_on", "status", "dataset")
registry_cols <- c("MMSI", "source", "reg_mmsi", "reg_shipname", "reg_callsign",
                   "reg_gear", "reg_length_m", "reg_from", "reg_to", "reg_extra")
combined_cols <- c("MMSI", "vessel_id", "gear", "ship", "year_from", "year_to")

# Each API entry has an index; selfReportedInfo maps it to the MMSI(s) queried.
parse_identity <- function(r) {
  sr  <- r$selfReportedInfo
  idx <- tibble(index = as.numeric(sr$index), MMSI = col_chr(sr, "ssvid")) |>
    distinct()

  reg <- r$registryInfo
  registry <- if (is.data.frame(reg) && nrow(reg) > 0) {
    tibble(index        = as.numeric(reg$index),
           source       = col_chr(reg, "sourceCode"),
           reg_mmsi     = col_chr(reg, "ssvid"),
           reg_shipname = col_chr(reg, "shipname"),
           reg_callsign = col_chr(reg, "callsign"),
           reg_gear     = col_chr(reg, "geartypes"),
           reg_length_m = col_chr(reg, "lengthM"),
           reg_from     = col_chr(reg, "transmissionDateFrom"),
           reg_to       = col_chr(reg, "transmissionDateTo"),
           reg_extra    = col_chr(reg, "extraFields")) |>
      inner_join(idx, by = "index", relationship = "many-to-many") |>
      select(all_of(registry_cols)) |>
      distinct()
  } else {
    read_ev("", registry_cols)
  }

  cmb <- r$combinedSourcesInfo
  combined <- if (is.data.frame(cmb) && nrow(cmb) > 0) {
    tibble(index     = as.numeric(cmb$index),
           vessel_id = col_chr(cmb, "vesselId"),
           gear      = col_chr(cmb, "geartypes_name"),
           ship      = col_chr(cmb, "shiptypes_name"),
           year_from = col_chr(cmb, "shiptypes_yearFrom"),
           year_to   = col_chr(cmb, "shiptypes_yearTo")) |>
      inner_join(idx, by = "index", relationship = "many-to-many") |>
      select(all_of(combined_cols)) |>
      distinct()
  } else {
    read_ev("", combined_cols)
  }

  list(registry = registry, combined = combined,
       dataset = paste(unique(col_chr(r$dataset, "dataset")), collapse = "|"))
}

# any "|"-separated gear code a fishing gear (fishing_gear_codes,
# r/gfw_helpers.R)
has_fishing_gear <- function(g) {
  map_lgl(str_split(coalesce(g, ""), fixed("|")), \(x) any(x %in% fishing_gear_codes))
}

# Regional fisheries management organisation (RFMO) vessel lists. A listing
# (e.g. ICCAT, for tunas and other highly migratory species) means the vessel
# is authorised to fish, whatever gear or ship type the record carries: US
# sport fishing boats of 20 m or more are listed by ICCAT but typed PASSENGER.
rfmo_sources <- c("ICCAT", "IATTC", "WCPFC", "IOTC", "CCSBT", "NAFO", "NEAFC",
                  "SPRFMO", "CCAMLR", "SIOFA", "GFCM", "NPFC")

# any "|"-separated registry source an RFMO list
has_rfmo_source <- function(s) {
  map_lgl(str_split(coalesce(s, ""), fixed("|")), \(x) any(x %in% rfmo_sources))
}

# Phase 4: the review sheet -------------------------------------------------

# GARFO length (ft) agrees with the GFW registry length (m), within
# `tolerance` as a share of the registry length (03's screen$length_tolerance)
length_agrees <- function(garfo_ft, reg_m, tolerance) {
  !is.na(garfo_ft) & !is.na(reg_m) &
    abs(garfo_ft * 0.3048 - reg_m) <= tolerance * reg_m
}

# Phase 4: USCG PSIX checks -------------------------------------------------

# columns of the PSIX cache (paths$psix, shared by every pipeline version:
# PSIX is USCG, not GFW)
psix_cols <- c("key_type", "key", "queried_on", "status", "psix_official_no",
               "psix_name", "psix_call_sign", "psix_service", "psix_status")

# One PSIX vessel-summary query by call sign or official number (the service's
# VIN field). Returns NULL when PSIX has no match.
psix_query <- function(call_sign = "", official_no = "") {
  body <- paste0(
    '<?xml version="1.0" encoding="utf-8"?>',
    '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>',
    '<getVesselSummaryXMLString xmlns="https://cgmix.uscg.mil">',
    '<VesselID></VesselID><VesselName></VesselName>',
    '<CallSign>', call_sign, '</CallSign><VIN>', official_no, '</VIN>',
    '<HIN></HIN><Flag></Flag><Service></Service><BuildYear></BuildYear>',
    '</getVesselSummaryXMLString></soap:Body></soap:Envelope>')

  resp <- httr2::request("https://cgmix.uscg.mil/xml/PSIXData.asmx") |>
    httr2::req_headers(SOAPAction = '"https://cgmix.uscg.mil/getVesselSummaryXMLString"') |>
    httr2::req_body_raw(body, type = "text/xml; charset=utf-8") |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform()

  # the result is an XML document escaped inside the SOAP response
  inner <- xml2::xml_text(xml2::xml_find_first(
    xml2::read_xml(httr2::resp_body_string(resp)),
    "//*[local-name()='getVesselSummaryXMLStringResult']"))
  if (is.na(inner) || inner == "") return(NULL)
  v <- xml2::xml_find_all(xml2::read_xml(inner), "//VesselSummary")
  if (length(v) == 0) return(NULL)

  field <- \(f) xml2::xml_text(xml2::xml_find_first(v, f))
  tibble(psix_official_no = field("Identification"),
         psix_name        = field("VesselName"),
         psix_call_sign   = field("VesselCallSign"),
         psix_service     = field("ServiceType"),
         psix_status      = field("StatusLookupName"))
}

# AIS call signs in US format (K, N, W or AA-AL prefix); others are not looked up
us_call_sign <- function(cs) {
  x <- str_remove_all(toupper(coalesce(cs, "")), "\\s")
  if_else(str_detect(x, "^(K|N|W|A[A-L])[A-Z0-9]{2,6}$"), x, NA_character_)
}

# what to look up per MMSI: the AIS call sign, and a single GARFO hull ID that
# is a USCG official number
psix_keys <- function(df) {
  df |>
    transmute(MMSI,
              ais_cs = if_else(flag %in% "USA", us_call_sign(call_sign), NA_character_),
              hull   = if_else(garfo_match %in% c("unique_years", "ambiguous_length_resolved") &
                                 str_detect(coalesce(garfo_hull_id, ""), "^[0-9]+$"),
                               garfo_hull_id, NA_character_))
}

# Compares the cached PSIX records with each MMSI's call sign and GARFO hull
# (from psix_keys); also used, cache only, for the gear review sheet
psix_evaluate <- function(targets, psix) {
  psix_done <- psix |> filter(status %in% c("ok", "not_found")) |> distinct(key_type, key)

  # PSIX returns partial matches too; keep exact ones. "N/A" = no call sign
  psix_ok <- psix |>
    filter(status == "ok") |>
    mutate(psix_call_sign = na_if(psix_call_sign, "N/A"),
           desc = paste0("official no. ", psix_official_no, " ", psix_name,
                         ", call sign ", coalesce(psix_call_sign, "none"),
                         ", ", psix_service))

  collapse <- \(x) na_if(paste(sort(unique(na.omit(x))), collapse = "|"), "")

  by_hull <- psix_ok |>
    filter(key_type == "official_no", psix_official_no == key) |>
    group_by(hull = key) |>
    summarise(hull_cs = collapse(psix_call_sign), hull_service = collapse(psix_service),
              psix_hull = paste(unique(desc), collapse = "; "), .groups = "drop")

  by_cs <- psix_ok |>
    filter(key_type == "call_sign", psix_call_sign == key) |>
    group_by(ais_cs = key) |>
    summarise(cs_official_no = collapse(psix_official_no),
              psix_ais_call_sign = paste(unique(desc), collapse = "; "), .groups = "drop")

  in_list <- \(x, s) map2_lgl(x, s, \(a, b) !is.na(a) && a %in% str_split_1(coalesce(b, ""), fixed("|")))
  not_fishing_service <- \(s) !is.na(s) & !str_detect(s, regex("fish|passenger|recreational", ignore_case = TRUE))

  targets |>
    left_join(by_hull, by = "hull") |>
    left_join(by_cs, by = "ais_cs") |>
    mutate(
      hull_done = is.na(hull) | hull %in% psix_done$key[psix_done$key_type == "official_no"],
      cs_done   = is.na(ais_cs) | ais_cs %in% psix_done$key[psix_done$key_type == "call_sign"],
      cs_match  = in_list(ais_cs, hull_cs) | in_list(hull, cs_official_no),
      psix_link = case_when(
        is.na(hull)                         ~ NA_character_,
        !hull_done | !cs_done               ~ "not_queried",
        cs_match                            ~ "match",
        !is.na(cs_official_no)              ~ "ais_is_other_hull",
        !is.na(ais_cs) & !is.na(hull_cs)    ~ "call_sign_differs",
        is.na(ais_cs) & !is.na(hull_cs)     ~ "hull_has_cs_ais_none",
        is.na(psix_hull)                    ~ "hull_not_found",
        TRUE                                ~ "no_link"),
      # a call sign can change when a licence is reissued, so a differing one
      # is only noted
      psix_contradicts = psix_link %in% "ais_is_other_hull" |
        (psix_link %in% "match" & not_fishing_service(hull_service)),
      psix_ais_call_sign = case_when(
        !is.na(psix_ais_call_sign) ~ psix_ais_call_sign,
        !is.na(ais_cs) & cs_done   ~ "not in PSIX",
        TRUE                       ~ NA_character_),
      psix_note = case_when(
        psix_link %in% "not_queried" ~
          "PSIX not yet looked up (run with run_psix_api: true)",
        psix_contradicts & psix_link %in% "match" ~ paste0(
          "PSIX: AIS call sign matches GARFO hull ", hull, " (", psix_hull,
          "), but its service type is not fishing; GARFO match not used"),
        psix_link %in% "match" ~ paste0(
          "PSIX: AIS call sign matches GARFO hull ", hull, " (", psix_hull, ")"),
        psix_link %in% "ais_is_other_hull" ~ paste0(
          "PSIX: AIS call sign ", ais_cs, " is ", psix_ais_call_sign, ", not GARFO hull ",
          hull, " (", coalesce(psix_hull, "not in PSIX"), "); GARFO match not used"),
        psix_link %in% "call_sign_differs" ~ paste0(
          "PSIX: GARFO hull ", hull, " has call sign ", hull_cs, ", AIS broadcasts ",
          ais_cs, "; check that this MMSI is that hull (the call sign may have changed)"),
        psix_link %in% "hull_has_cs_ais_none" ~ paste0(
          "PSIX: GARFO hull ", hull, " (", psix_hull, ") has a call sign but AIS ",
          "broadcasts none; check that this MMSI is that hull"),
        psix_link %in% "hull_not_found" ~ paste0("PSIX: GARFO hull ", hull, " not found"),
        psix_link %in% "no_link" ~ paste0(
          "PSIX: GARFO hull ", hull, " (", psix_hull, ") has no call sign to compare"),
        !is.na(psix_ais_call_sign) ~ paste0("PSIX: AIS call sign ", ais_cs, " is ",
                                            psix_ais_call_sign),
        TRUE ~ NA_character_))
}

# Phase 4: gear review ------------------------------------------------------

# a single analysis gear class from the GFW registry gear codes, if they agree
reg_gear_class <- function(g) {
  map_chr(str_split(coalesce(g, ""), fixed("|")), \(x) {
    cls <- setdiff(unique(gear_class_of(x[x != ""])), "UNRESOLVED")
    if (length(cls) == 1) cls else NA_character_
  })
}
