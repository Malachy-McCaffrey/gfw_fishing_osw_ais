# Everything the BAG notebooks build before fitting (Phase 4; D-101): the
# Phase 0 tables, the vessel records, every model specification and the
# support rule behind it, and the two parallel runners. Sourced by
#   09a_bag_fit.qmd    fits every main, field-check and leave-one-vessel-out model
#   09b_bag_power.qmd  Step 3 simulation power (after Phase 5, D-096)
#   09_bag.qmd         the report, which only reads what 09a and 09b cached
# so all three build the same specifications and so compute the same cache
# keys. The code was moved here from 10_bag.qmd unchanged (D-101), apart
# from: get_fit() never fits; run_refit_jobs() can refuse to fit
# (read_only); the leave-one-vessel-out refits are a function,
# lovo_refits(); the power base fits are listed apart (power_specs).
#
# Builds objects only. It writes no table or figure, so sourcing it twice,
# or from any of the three, has no side effects beyond creating the refit
# cache folder.
#
# Needs, before sourcing: the tidyverse, sf and sdmTMB attached; r/paths.R,
# r/gfw_helpers.R, r/analysis_helpers.R and r/bag_helpers.R sourced;
# `root` (the repo root) and `doc_params` (the document's params: pipeline,
# path overrides, bag_params, and its own run settings).

# --- parameters (D-101) --------------------------------------------------------
# The model-defining parameters live in one file, r/bag_params.yml, so the
# three notebooks cannot drift apart; `-P bag_params:<file>` points all of a
# render at another set (e.g. a Phase 5 mesh check). The document's own
# params (pipeline, paths, workers) are added on top.
bag_params_file <- if (nzchar(doc_params$bag_params %||% "")) doc_params$bag_params else
  file.path(root, "r", "bag_params.yml")
qparams <- modifyList(yaml::read_yaml(bag_params_file), doc_params)
paths <- gfw_paths_with(qparams)
set.seed(42)
datasets <- c("vp", "afe")
# result files of the refit workers (leave-one-vessel-out, power), one
# folder per refit specification
job_dir <- file.path(paths$bag, "cache")
dir.create(job_dir, recursive = TRUE, showWarnings = FALSE)

# --- Phase 0 tables ----------------------------------------------------------
tpath <- \(ds, ts) file.path(paths$analysis, sprintf("%s_%s_gear.csv", ds, ts))
read_tab <- \(ds, ts) read_csv(tpath(ds, ts), show_col_types = FALSE,
                               col_types = cols(cell_id = "c", gear_class = "c", stage = "c",
                                                season = "c", phase = "c", dist_band = "c",
                                                nearest_project = "c", domain = "l", .default = "?"))
ss    <- map(set_names(datasets), \(ds) read_tab(ds, "stage_season"))
st    <- map(set_names(datasets), \(ds) read_tab(ds, "stage"))
month <- map(set_names(datasets), \(ds) read_tab(ds, "month"))
sy_afe <- read_tab("afe", "season_year")
# VP season-year: its fleet counts (the fleet-size sensitivity for fixed AFE,
# whose timing model runs at season-year), and the VP timing models' season-
# year power proxy and radius recovery (Step 3, D-094)
sy_vp <- read_tab("vp", "season_year")
sy <- list(afe = sy_afe, vp = sy_vp)
# active construction at the sensitivity radii per cell × season-year (02a,
# D-066), for VP mobile's radius recovery (D-065, D-094): columns
# active_construction_<r>km_share for each radius in qparams$radius_km
radii_path <- file.path(paths$analysis, "infra_cell_season_year_radii.csv")
sy_radii <- read_csv(radii_path, col_types = cols(cell_id = "c", season = "c", .default = "d"))

input_files <- c(map(datasets, \(ds) tpath(ds, c("stage", "stage_season", "month"))) |> unlist(),
                 tpath(c("afe", "vp"), "season_year"), radii_path)

# the modelled dataset × gear combinations (plan, "Scope per gear")
ss_models <- tribble(~dataset, ~gear,
                     "vp", "MOBILE", "vp", "FIXED", "vp", "POLE_AND_LINE",
                     "afe", "MOBILE", "afe", "FIXED") |>
  mutate(id = paste(dataset, gear, sep = "_"),
         family = if_else(dataset == "vp", "nbinom2", "tweedie"))

# --- vessel records ----------------------------------------------------------
records_path <- \(ds) file.path(paths$processed_gfw, sprintf("gfw_%s_id_classified.csv", ds))
vessel_month <- map_dfr(set_names(datasets), \(ds)
  read_csv(records_path(ds), col_types = cols(.default = "c"),
           col_select = c(MMSI, `Vessel Name`, cell_id, gear_class, in_primary, hours, date)) |>
    filter(in_primary == "TRUE") |>
    mutate(hours = as.numeric(hours), m = floor_date(as.Date(date), "month")) |>
    group_by(MMSI, vessel = `Vessel Name`, cell_id, gear_class, m) |>
    summarise(hours = sum(hours), .groups = "drop"), .id = "dataset")
input_files <- c(input_files, records_path(datasets))

# per cell × stage × season (stage × season models and leave-one-vessel-out)
vessel_hours <- vessel_month |>
  mutate(stage = stage_of(m), season = season_of(m)) |>
  group_by(dataset, MMSI, vessel, cell_id, gear_class, stage, season) |>
  summarise(hours = sum(hours), .groups = "drop")
vessel_ss <- vessel_hours |> filter(hours > 0) |> distinct(dataset, gear_class, cell_id, stage, season, MMSI)
# per cell × time step, keyed by the step's last day (timing models)
vessel_step <- map(c(month = "month", season_year = "season_year"), \(step)
  vessel_month |> filter(hours > 0) |> mutate(step_end = step_end_of(m, step)) |>
    distinct(dataset, gear_class, cell_id, step_end, MMSI))

# --- model specifications ----------------------------------------------------
# as.numeric (D-098): YAML gives `mesh_cutoff_km: 2` as the integer 2L, and
# fmesher 0.8.0 ignores an integer cutoff, so the mesh had a vertex at every
# data location instead of none closer than 2 km
cutoff <- as.numeric(qparams$mesh_cutoff_km)
stopifnot("mesh cutoff must be one positive number" = length(cutoff) == 1 && cutoff > 0)

# a fit specification: the cache key and a fit function that runs anywhere.
# `start_from`: another spec on the same rows (so the same mesh and time
# steps) whose cached fit this one starts its optimiser from (D-097): the
# timing variants start from the main timing fit. Its cache hash joins the
# key, so a changed parent refits its variants; specs without one keep their
# key. `after` names the parent's cache file, which run_specs() waits for.
make_spec <- function(id, d, formula, family, spatiotemporal = "off", time = NULL, knots = NULL,
                      start_from = NULL) {
  force(d); force(formula); force(family); force(spatiotemporal); force(time); force(knots)
  cut <- cutoff
  key <- list(data = d, formula = formula, family = family, cutoff = cut, spatial = "on",
              spatiotemporal = spatiotemporal, time = time, knots = knots)
  parent_file <- NULL
  if (!is.null(start_from)) {
    stopifnot("a warm start needs the parent's rows" = nrow(start_from$key$data) == nrow(d))
    pf <- fit_cache_path(start_from$key, paths$models)
    key$start_from <- attr(pf, "hash")
    parent_file <- as.character(pf)
  }
  fun <- function() {
    fam <- switch(family, nbinom2 = sdmTMB::nbinom2(), tweedie = sdmTMB::tweedie(),
                  delta_gamma = sdmTMB::delta_gamma())
    mesh <- sdmTMB::make_mesh(d, c("x_km", "y_km"), cutoff = cut)
    if (is.null(parent_file))
      return(sdmTMB::sdmTMB(formula, data = d, mesh = mesh, family = fam, offset = d$log_expo,
                            spatial = "on", spatiotemporal = spatiotemporal, time = time, knots = knots,
                            silent = TRUE))
    # warm start (D-097): build the variant unfitted for its parameter
    # layout and map, take the parent's estimates into it (warm_start_of(),
    # bag_helpers.R), then fit. multiphase off: sdmTMB applies `start` after
    # its first, non-spatial phase, so that phase would be discarded anyway
    # silent = TRUE (D-102): with do_fit = FALSE sdmTMB still builds the TMB
    # object, and without it that build traces to the console; in a worker
    # whose output went to an unread pipe that trace stalled both v5 warm
    # starts on 2026-11-06
    template <- sdmTMB::sdmTMB(formula, data = d, mesh = mesh, family = fam, offset = d$log_expo,
                               spatial = "on", spatiotemporal = spatiotemporal, time = time, knots = knots,
                               do_fit = FALSE, silent = TRUE)
    start <- warm_start_of(parent_file, template)
    sdmTMB::sdmTMB(formula, data = d, mesh = mesh, family = fam, offset = d$log_expo,
                   spatial = "on", spatiotemporal = spatiotemporal, time = time, knots = knots,
                   control = sdmTMB::sdmTMBcontrol(start = start, multiphase = FALSE), silent = TRUE)
  }
  list(id = id, key = key, fun = fun, after = parent_file)
}
# Reads a spec's cached fit; never fits (D-101). Fitting is run_specs()'s
# job, in 09a (main fits) or 09b (power bases), so a render of the report can
# never start an hours-long fit in its own process. A fit that is missing
# stops with the notebook that makes it
get_fit <- \(spec) fit_cache_read(spec$key, paths$models, label = spec$id,
                                  hint = "Render r/09a_bag_fit.qmd (r/09b_bag_power.qmd for a power base) for this pipeline first")
fit_ok <- \(f) { s <- sanity(f, silent = TRUE); isTRUE(s$hessian_ok && s$eigen_values_ok && s$nlminb_ok && s$gradients_ok) }

# --- stage × season (steps 3, 5) --------------------------------------------
ss_cols <- c("cell_id", "stage", "stage_num", "season", "dist_band", "hours", "log_expo",
             "depth_m", "slope_z", "bpi_z", "x_km", "y_km")
# `bands`: the distance-band scheme (D-076), "full" (inside, 0–2, 2–4, 4–8
# km) or "merged" (near = inside + 0–2, mid = 2–8 km); 8–15 km is the
# reference in both
ss_data <- function(ds, g, bands = "full") {
  d <- ss[[ds]] |> filter(gear_class == g, domain) |> bag_prepare() |>
    mutate(stage_num = as.integer(stage)) |> select(all_of(ss_cols))
  if (bands == "merged") d <- mutate(d, dist_band = merge_bands(dist_band))
  d
}
ss_formula <- hours ~ stage * dist_band + season + s(depth_m, k = 4) + slope_z + bpi_z
ss_base_formula <- hours ~ stage + dist_band + season + s(depth_m, k = 4) + slope_z + bpi_z
# the BAG terms and the headline term of a band scheme: the Stage 2 and
# Stage 3 × near-band interactions (inside and 0–2 km, or near when merged)
near_bands <- \(bands) if (bands == "full") c("inside", "0-2") else "near"
bag_terms_of <- \(bands) paste0("stageStage ", rep(2:3, length(near_bands(bands))), ":dist_band",
                                rep(near_bands(bands), each = 2))
headline_of <- \(bands) paste0("stageStage 3:dist_band", near_bands(bands)[1])
all_bag_terms <- unique(c(bag_terms_of("full"), bag_terms_of("merged")))
# every stage × band term of a scheme, for the full grid and the gradient
# test (D-091): Stages 2 and 3 × all four bands (full), or × near and mid
# (merged). Kept apart from bag_terms_of(), which the power, leave-one-
# vessel-out and robustness refits use, so their results and caches do not
# change
grid_terms_of <- \(bands, stages = 2:3) {
  b <- unname(band_schemes[[bands]])
  paste0("stageStage ", rep(stages, each = length(b)), ":dist_band", rep(b, length(stages)))
}
# the headline row of each model in a results table with id and term
headline_rows <- \(tab) semi_join(tab, transmute(ss_sets, id, term = headline), by = c("id", "term"))
# a spatial field shared by all stages plus an iid field per stage (plan, Phase 5 sketch)
ss_spec <- \(id, d, formula, family) make_spec(id, d, formula, family, "iid", "stage_num")

# cells with any area in an active safety zone in any month (caveat 17)
zone_cells <- month$vp |> filter(sz_share > 0) |> distinct(cell_id) |> pull()

# --- term support (D-076) and the stage x season sets ------------------------
sup_ok <- \(sup) support_ok(sup, qparams$support_min_positive, qparams$support_min_cells,
                            qparams$support_min_vessels)
# the support of a stage × season model's terms; vessels matched by cell,
# stage and season
ss_support <- function(ds, g, d)
  term_support(ss_formula, d, filter(vessel_ss, dataset == ds, gear_class == g), c("cell_id", "stage", "season"))
# the finest band scheme whose BAG terms are all supported, or "none"
choose_ss <- function(ds, g) {
  sup_all <- NULL
  for (b in names(band_schemes)) {
    sup <- ss_support(ds, g, ss_data(ds, g, b)) |> mutate(bands = b)
    sup_all <- bind_rows(sup_all, sup)
    if (all(sup_ok(filter(sup, term %in% bag_terms_of(b))))) return(list(bands = b, support = sup_all))
  }
  list(bands = "none", support = sup_all)
}

ss_choice <- ss_models |> mutate(choice = map2(dataset, gear, choose_ss), bands = map_chr(choice, "bands"))
# a gear whose pooled BAG terms still lack support is reported descriptively
# only (step 1) and has no stage × season model
ss_sets <- ss_choice |> filter(bands != "none") |>
  mutate(data = pmap(list(dataset, gear, bands), ss_data),
         terms = map(bands, bag_terms_of), headline = map_chr(bands, headline_of),
         spec = pmap(list(id, data, family), \(id, d, fam) ss_spec(id, d, ss_formula, fam)),
         spec_base = pmap(list(id, data, family), \(id, d, fam) ss_spec(paste(id, "base"), d, ss_base_formula, fam)),
         spec_nozone = pmap(list(id, data, family), \(id, d, fam)
           ss_spec(paste(id, "no zone cells"), filter(d, !cell_id %in% zone_cells), ss_formula, fam)),
         # AFE: the delta-Gamma hurdle alongside Tweedie (plan, "Response families")
         spec_dg = pmap(list(id, data, dataset), \(id, d, ds)
           if (ds == "afe") ss_spec(paste(id, "delta_gamma"), d, ss_formula, "delta_gamma") else NULL))

# --- timing and pre-trend (steps 4, 6) ----------------------------------------
timing_models <- tribble(~dataset, ~gear, ~step,
                         "vp", "MOBILE", "month", "vp", "FIXED", "month", "vp", "POLE_AND_LINE", "month",
                         "afe", "MOBILE", "month", "afe", "FIXED", "season_year") |>
  mutate(id = paste(dataset, gear, sep = "_"),
         family = if_else(dataset == "vp", "nbinom2", "tweedie"))

# `bands`: the distance-band scheme (D-076); `cuts`: the foundation-distance
# band edges for h(·), coarsened when the finer bands lack support
timing_data <- function(ds, g, step, bands = "full", cuts = c(2, 5, 10)) {
  # season-year for both datasets: fixed AFE's timing model, and every
  # model's season-year power proxy (D-094)
  base <- if (step == "month") month[[ds]] else sy[[ds]]
  d <- base |> filter(gear_class == g, domain) |> bag_prepare()
  if (bands == "merged") d <- mutate(d, dist_band = merge_bands(dist_band))
  bx <- band_schemes[[bands]]
  d |>
    mutate(year_c = if (step == "month") (t_index - 1) / 12 - 5 else season_year - 2021,
           season = factor(season, c("AprSep", "OctMar")),
           construction = as.numeric(phase == "construction"),
           post = as.numeric(phase == "post_construction"),
           found_band = found_band_of(d_found_km, cuts),
           active = if (step == "month") as.numeric(active_construction) else active_construction_share,
           year_num = if (step == "month") as.numeric(year) else as.numeric(season_year),
           time_year = as.integer(year_num),
           # Stage 2 as its own phase (D-075): pre-construction steps from
           # Stage 2 on (site surveys, boulder clearance) are "development",
           # so "pre" in the construction terms means Stage 1 only, and the
           # dx_* terms estimate any anticipation instead of assuming none.
           # For RWF- and SRW-nearest cells development runs into Stage 3,
           # up to their own project's first works.
           development = as.numeric(phase == "pre" & stage != "Stage 1"),
           # last day of the time step, for the 2016–2019 pre-trend fit and
           # the vessel match; season-year OctMar Y runs October Y − 1 to
           # March Y (season_year_of(), r/analysis_helpers.R)
           step_end = if (step == "month") ceiling_date(as.Date(year_month), "month") - 1
                      else season_year_end(season, season_year),
           # event-time leads (D-075): months to the cell's first
           # construction step, binned inside development
           step_idx = if (step == "month") t_index else season_year_index(season, season_year),
           lead_months = months_to_works(cell_id, step_idx, phase, if (step == "month") 1 else 6),
           pre_bin = pre_period_bin(phase, development == 1, lead_months),
           dev_early = as.numeric(pre_bin %in% "dev_early"),
           lead_24_13 = as.numeric(pre_bin %in% "lead_24_13"),
           lead_12_1 = as.numeric(pre_bin %in% "lead_12_1"),
           # the pooled lead bin, when the three bins lack support (D-076)
           lead_24_1 = lead_24_13 + lead_12_1) |>
    band_interactions("construction", "cx", bx) |>
    band_interactions("post", "post", bx) |>
    band_interactions("development", "dx", bx) |>
    band_interactions("dev_early", "de", bx) |>
    band_interactions("lead_24_13", "l24", bx) |>
    band_interactions("lead_12_1", "l12", bx) |>
    band_interactions("lead_24_1", "l241", bx)
}
# the indicator × band columns of a scheme, e.g. band_cols("cx", "full") gives
# cx_inside, cx_0_2, cx_2_4, cx_4_8
band_cols <- \(prefix, bands = "full") paste0(prefix, "_", names(band_schemes[[bands]]))
timing_core <- c("cell_id", "hours", "log_expo", "dist_band", "phase", "stage", "step_end", "year_c", "construction",
                 "found_band", "development", "pre_bin", "dev_early", "lead_24_13", "lead_12_1", "lead_24_1",
                 "active", "sz_share", "depth_m", "slope_z", "bpi_z", "year_num", "time_year", "x_km", "y_km")
timing_select <- \(d) select(d, all_of(timing_core), matches("^(cx|post|dx|de|l24|l12|l241)_"),
                             any_of(c("moy", "season")))
pretrend_formula <- function(step) {
  if (step == "month") hours ~ dist_band * year_c + s(moy, bs = "cc", k = 8) + s(depth_m, k = 4) + slope_z + bpi_z
  else hours ~ dist_band * year_c + season + s(depth_m, k = 4) + slope_z + bpi_z
}
# How the pre-construction period is split (D-075): the main timing model
# gives development one set of band terms; the leads model splits it by
# months to the works, in three bins or, when those lack support, one.
dev_terms_of   <- \(b) c("development", band_cols("dx", b))
lead3_terms_of <- \(b) c("dev_early", "lead_24_13", "lead_12_1", band_cols("de", b), band_cols("l24", b), band_cols("l12", b))
lead1_terms_of <- \(b) c("dev_early", "lead_24_1", band_cols("de", b), band_cols("l241", b))
# `terms`: the fixed effects other than the terrain covariates and smooths,
# in the order construction, construction × band, post × band, the pre-period
# split, found_band, active, sz_share, dist_band
timing_formula <- function(step, terms) {
  common <- paste(c(terms, "s(depth_m, k = 4)", "slope_z", "bpi_z"), collapse = " + ")
  as.formula(if (step == "month") paste("hours ~", common, "+ s(moy, bs = 'cc', k = 8) + s(year_num, k = 5)")
             else paste("hours ~", common, "+ season + s(year_num, k = 5)"))
}
month_knots <- \(step) if (step == "month") list(moy = c(0.5, 12.5)) else NULL
timing_terms_of <- \(b, pre, post_keep, found = TRUE, active = TRUE)
  c("construction", band_cols("cx", b), post_keep, pre, if (found) "found_band", if (active) "active", "sz_share", "dist_band")

# The support rule for one timing model (D-076), in a fixed order: band
# scheme from the construction and development × band terms; then the
# foundation-distance bands; then the optional post-construction and active
# terms; then the lead bins. Returns the scheme, the data, the main and leads
# fixed terms (NULL when unsupported), the support counts and a log.
plan_timing <- function(ds, g, step) {
  vess <- filter(vessel_step[[step]], dataset == ds, gear_class == g)
  supp <- \(d, terms) term_support(timing_formula(step, terms), d, vess, c("cell_id", "step_end"))
  ok_of <- \(sup) set_names(sup_ok(sup), sup$term)
  log <- character()
  tried <- NULL   # support of each band scheme tried, kept when none passes
  # 1. band scheme
  for (b in names(band_schemes)) {
    d <- timing_data(ds, g, step, b)
    terms <- timing_terms_of(b, dev_terms_of(b), band_cols("post", b))
    sup_b <- supp(d, terms)
    tried <- bind_rows(tried, mutate(sup_b, model = "timing", bands = b))
    ok <- ok_of(sup_b)
    if (all(ok[c(band_cols("cx", b), band_cols("dx", b))] %in% TRUE)) break
    log <- c(log, paste(b, "bands: a construction or development × band term lacks support"))
    if (b == "merged") return(list(bands = "none", log = log, support = tried))
  }
  # 2. foundation-distance bands, finest supported cut
  found <- FALSE
  for (cuts in list(c(2, 5, 10), c(5, 10), 10)) {
    d <- timing_data(ds, g, step, b, cuts)
    ok <- ok_of(supp(d, terms))
    lv <- paste0("found_band", levels(d$found_band)[-1])
    if (all(ok[lv] %in% TRUE)) { found <- TRUE; break }
    log <- c(log, paste0("found_band cuts ", paste(cuts, collapse = "/"), " km: a band lacks support"))
  }
  if (!found) { cuts <- c(2, 5, 10); d <- timing_data(ds, g, step, b, cuts); log <- c(log, "found_band dropped") }
  # 3. optional terms: post × band and (monthly) active construction
  post_keep <- band_cols("post", b)[ok[band_cols("post", b)] %in% TRUE]
  if (length(setdiff(band_cols("post", b), post_keep)))
    log <- c(log, paste("dropped:", paste(setdiff(band_cols("post", b), post_keep), collapse = ", ")))
  active <- !("active" %in% names(ok)) || isTRUE(ok[["active"]])
  if (!active) log <- c(log, "dropped: active")
  terms <- timing_terms_of(b, dev_terms_of(b), post_keep, found, active)
  sup <- supp(d, terms) |> mutate(model = "timing")
  # 4. lead bins: three, else one, else none
  lead_terms <- NULL
  for (lt in list(lead3_terms_of(b), lead1_terms_of(b))) {
    terms_l <- timing_terms_of(b, lt, post_keep, found, active)
    sup_l <- supp(d, terms_l) |> mutate(model = "leads")
    if (all(ok_of(sup_l)[setdiff(lt, "dev_early")] %in% TRUE)) { lead_terms <- terms_l; break }
    log <- c(log, paste0("leads (", if (identical(lt, lead3_terms_of(b))) "three bins" else "one bin",
                         "): a lead term lacks support"))
  }
  if (is.null(lead_terms)) log <- c(log, "no leads model")
  list(bands = b, cuts = cuts, data = timing_select(d), terms = terms, lead_terms = lead_terms,
       support = bind_rows(mutate(sup, bands = b), if (!is.null(lead_terms)) mutate(sup_l, bands = b)), log = log)
}

# A spec, or NULL when the support rule left no model to fit
spec_or_null <- \(ok, ...) if (ok) make_spec(...) else NULL
timing_sets <- timing_models |>
  left_join(select(ss_choice, id, pre_bands = bands), by = "id") |>
  mutate(plan = pmap(list(dataset, gear, step), plan_timing),
         bands = map_chr(plan, "bands"),
         # pre-trend data use the stage × season model's band scheme, so the
         # gate tests the bands that model estimates
         pre_data = pmap(list(dataset, gear, step, pre_bands), \(ds, g, step, b)
           if (b == "none") NULL else timing_select(timing_data(ds, g, step, b))),
         # pre-trend: pre-construction months, persistent field only
         spec_pre = pmap(list(id, pre_data, step, family), \(id, d, step, fam)
           spec_or_null(!is.null(d), paste(id, "pretrend"), filter(d, phase == "pre"), pretrend_formula(step), fam,
                        knots = month_knots(step))),
         # diagnostic pre-trend fits (D-075): Stage 1 only, without the
         # Stage 2 site work; and 2016–2019, without COVID as well
         spec_pre_s1 = pmap(list(id, pre_data, step, family), \(id, d, step, fam)
           spec_or_null(!is.null(d), paste(id, "pretrend stage 1"), filter(d, phase == "pre", stage == "Stage 1"),
                        pretrend_formula(step), fam, knots = month_knots(step))),
         spec_pre_1619 = pmap(list(id, pre_data, step, family), \(id, d, step, fam)
           spec_or_null(!is.null(d), paste(id, "pretrend 2016-2019"),
                        filter(d, phase == "pre", step_end <= as.Date("2019-12-31")),
                        pretrend_formula(step), fam, knots = month_knots(step))),
         # timing BAG: persistent field plus an AR1 field over years
         spec_timing = pmap(list(id, plan, step, family), \(id, pl, step, fam)
           spec_or_null(pl$bands != "none", paste(id, "timing"), pl$data, timing_formula(step, pl$terms), fam,
                        "ar1", "time_year", knots = month_knots(step))),
         # the same with development split into event-time leads (D-075),
         # started from the main timing fit (D-097) when there is one
         spec_timing_leads = pmap(list(id, plan, step, family, spec_timing), \(id, pl, step, fam, parent)
           spec_or_null(!is.null(pl$lead_terms), paste(id, "timing leads"), pl$data,
                        timing_formula(step, pl$lead_terms), fam, "ar1", "time_year", knots = month_knots(step),
                        start_from = parent)))

# --- timing power at a season-year proxy (Step 3; D-094) ----------------------
# A monthly timing refit takes hours, so every timing model's power is
# simulated at season-year. The proxy is the timing model rebuilt at
# season-year by the same support rule (D-076): its band scheme, foundation
# cut and optional terms are chosen afresh, since season-year cells pool six
# months and may support terms the monthly model drops (or the reverse). For
# fixed AFE the timing model already runs at season-year, so its own plan is
# reused and its power is its actual power, not a proxy.
# The headline of a timing model: construction × inside, or construction ×
# near when its bands are pooled (D-076), mirroring headline_of()
timing_headline_of <- \(bands) if (bands == "full") "cx_inside" else "cx_near"
tpower_sets <- timing_models |>
  mutate(proxy = step == "month",
         plan = pmap(list(id, dataset, gear, step), \(id, ds, g, step)
           if (step == "season_year") timing_sets$plan[[match(id, timing_sets$id)]]
           else plan_timing(ds, g, "season_year")),
         bands = map_chr(plan, "bands"),
         headline = map_chr(bands, \(b) if (b == "none") NA_character_ else timing_headline_of(b)),
         # base model: the season-year timing model without the construction
         # × band terms (the BAG terms of this model), as the stage × season
         # base drops stage × band but keeps stage; construction stays
         spec_base = pmap(list(id, plan, family), \(id, pl, fam)
           spec_or_null(pl$bands != "none", paste(id, "timing power base (season-year)"), pl$data,
                        timing_formula("season_year", setdiff(pl$terms, band_cols("cx", pl$bands))), fam,
                        "ar1", "time_year")))

# --- radius recovery: VP mobile at season-year (Step 3; D-065, D-094) ---------
# The VP mobile season-year model's data with `active` taken at radius `r`
# km: the share of the season-year with active construction within r km of
# the cell (02a's sensitivity radii, D-066), joined by cell and the
# season-year's last day. At 5 km it must reproduce the primary share; the
# tables are rounded to 1/1000, so equality is checked to that.
radius_data <- function(d, r) {
  col <- sprintf("active_construction_%gkm_share", r)
  rad <- sy_radii |>
    transmute(cell_id, step_end = season_year_end(season, season_year), active_r = .data[[col]])
  out <- left_join(d, rad, by = c("cell_id", "step_end"), relationship = "one-to-one")
  stopifnot("a cell × season-year has no radius exposure" = !anyNA(out$active_r))
  if (r == 5) stopifnot("the 5 km radius share does not reproduce active_construction_share" =
                          max(abs(out$active_r - out$active)) <= 1e-3)
  mutate(out, active = active_r) |> select(-active_r)
}
radius_plan <- tpower_sets |> filter(id == "vp_MOBILE") |> pull(plan) |> pluck(1)
# runnable only when the season-year support rule kept a model and its λ
radius_ok <- radius_plan$bands != "none" && "active" %in% radius_plan$terms
radius_spec_base <- if (radius_ok)
  make_spec("vp_MOBILE radius base (season-year)", radius_plan$data,
            timing_formula("season_year", setdiff(radius_plan$terms, "active")), "nbinom2", "ar1", "time_year")


# the support rule's decisions and every count behind them (D-076)
support_rules <- bind_rows(
  ss_choice |> transmute(id, model = "stage × season", decision = paste("bands:", bands)),
  timing_sets |> transmute(id, model = "timing",
                           decision = map_chr(plan, \(pl) paste(c(paste("bands:", pl$bands),
                             if (!is.null(pl$cuts) && pl$bands != "none") paste0("found_band cuts: ", paste(pl$cuts, collapse = "/")),
                             pl$log), collapse = "; "))),
  # the season-year power proxies (D-094); fixed AFE's is its timing model
  tpower_sets |> filter(proxy) |>
    transmute(id, model = "timing power proxy (season-year)",
              decision = map_chr(plan, \(pl) paste(c(paste("bands:", pl$bands),
                if (!is.null(pl$cuts) && pl$bands != "none") paste0("found_band cuts: ", paste(pl$cuts, collapse = "/")),
                pl$log), collapse = "; "))))
term_support_tab <- bind_rows(
  ss_choice |> transmute(id, s = map(choice, "support")) |> unnest(s) |> mutate(model = "stage × season"),
  timing_sets |> transmute(id, s = map(plan, "support")) |> unnest(s)) |>
  mutate(supported = sup_ok(pick(everything())))

# --- fleet-size sensitivity (step 8; plan caveat 5) ---------------------------
# AOI-wide fleet size per gear and time step: distinct Primary MMSIs of that
# gear transmitting anywhere in the AOI (`n_mmsi_fleet`, built in 05). It is a
# proxy for AIS uptake, which grew over the series.
# The VP count is used for both datasets. The AFE count is the number of
# vessels with apparent fishing that period, which is partly the outcome
# itself: a month with no fishing vessels has zero hours by construction.
# The VP count measures who carried AIS in the AOI, fishing or not.
# Each lookup is keyed by the columns the model data already carry, so it
# joins without adding columns to the base data. That keeps the base models'
# cache keys unchanged:
#   stage × season: stage, season
#   monthly timing: year_num (calendar year) and moy, which identify the month
#   season-year timing (fixed AFE): season and year_num (= season_year)
fleet_vp <- list(
  stage_season = ss$vp |> distinct(gear_class, stage, season, fleet = n_mmsi_fleet),
  month = month$vp |> distinct(gear_class, year_num = as.numeric(year), moy, fleet = n_mmsi_fleet),
  season_year = sy_vp |> distinct(gear_class, season, year_num = as.numeric(season_year), fleet = n_mmsi_fleet))
# one fleet count per gear × time step, or the join would duplicate rows
walk(fleet_vp, \(f) stopifnot("fleet lookup not unique per gear × time step" =
                                !anyDuplicated(select(f, -fleet))))

# Adds `log_fleet` to model data `d` (gear `g`, time step `step`): log(fleet + 1),
# centred on the model data's mean. Uses + 1 because VP pole-and-line has one
# month with no vessels. Centring keeps the intercept at the average fleet.
# Its coefficient is an elasticity: the % change in expected hours per 1%
# change in fleet size. A value near 1 means hours scale with the number of
# vessels carrying AIS.
add_log_fleet <- function(d, g, step) {
  f <- fleet_vp[[step]] |> filter(gear_class == g) |> select(-gear_class)
  keys <- setdiff(names(f), "fleet")
  # the model data hold stage and season as factors, the lookup as characters
  k <- d |> select(all_of(keys)) |> mutate(across(where(is.factor), as.character))
  fl <- left_join(k, f, by = keys)$fleet
  stopifnot("fleet lookup changed the row count" = length(fl) == nrow(d),
            "a model row has no fleet count" = !anyNA(fl))
  lf <- log1p(fl)
  d |> mutate(log_fleet = lf - mean(lf))
}

# the stage × season BAG with the fleet term added; the BAG terms are unchanged
ss_fleet_formula <- update(ss_formula, . ~ . + log_fleet)

ss_sets <- ss_sets |>
  mutate(spec_fleet = pmap(list(id, gear, data, family), \(id, g, d, fam)
    ss_spec(paste(id, "fleet"), add_log_fleet(d, g, "stage_season"), ss_fleet_formula, fam)))
timing_sets <- timing_sets |>
  # started from the main timing fit (D-097): the same rows with one more term
  mutate(spec_timing_fleet = pmap(list(id, gear, plan, step, family, spec_timing), \(id, g, pl, step, fam, parent)
    spec_or_null(pl$bands != "none", paste(id, "timing fleet"), add_log_fleet(pl$data, g, step),
                 timing_formula(step, c(pl$terms, "log_fleet")), fam, "ar1", "time_year",
                 knots = month_knots(step), start_from = parent)))

# --- mobile vs fixed (step 7) --------------------------------------------------
gc_formula <- hours ~ gear * stage * dist_band + gear * season + s(depth_m, k = 4) + slope_z + bpi_z
# the joint model uses the coarser of the two gears' band schemes (D-076),
# and is not fitted if either gear has no stage × season model
gc_bands <- map_chr(set_names(datasets), function(ds) {
  b <- ss_choice$bands[ss_choice$id %in% paste(ds, c("MOBILE", "FIXED"), sep = "_")]
  if (any(b == "none")) "none" else if (any(b == "merged")) "merged" else "full"
})
gc_specs <- map(set_names(datasets[gc_bands[datasets] != "none"]), function(ds) {
  d <- bind_rows(ss_data(ds, "MOBILE", gc_bands[[ds]]) |> mutate(gear = "MOBILE"),
                 ss_data(ds, "FIXED", gc_bands[[ds]]) |> mutate(gear = "FIXED")) |>
    mutate(gear = factor(gear, c("MOBILE", "FIXED")),
           # each gear × stage gets its own iid field
           gear_stage = as.integer(interaction(gear, stage, drop = TRUE)))
  make_spec(paste(ds, "gear contrast"), d, gc_formula, if (ds == "vp") "nbinom2" else "tweedie",
            "iid", "gear_stage")
})

# --- every main fit (09a) ----------------------------------------------------
# compact(): the support rule (D-076) leaves some timing specs NULL
all_specs <- c(ss_sets$spec, ss_sets$spec_base, ss_sets$spec_nozone, compact(ss_sets$spec_dg),
               compact(timing_sets$spec_pre), compact(timing_sets$spec_timing), gc_specs,
               # Stage 2 diagnostics (D-075)
               compact(timing_sets$spec_pre_s1), compact(timing_sets$spec_pre_1619),
               compact(timing_sets$spec_timing_leads),
               # fleet-size sensitivity (step 8): new fits; the ones above stay cached
               ss_sets$spec_fleet, compact(timing_sets$spec_timing_fleet))
# the power bases (Step 3, D-094): the timing models' season-year proxies and
# VP mobile's radius recovery, fitted by 09b, only when Step 3 runs (D-096).
# Fixed AFE's proxy base is a new fit too: its timing model has the cx terms.
# The stage × season power simulates from ss_sets$spec_base, a main fit above
power_specs <- c(compact(tpower_sets$spec_base), compact(list(radius_spec_base)))

# Step 3's results, as 09b saves them for the report (D-101), and their
# fingerprint: the cache hash of every base model the power simulates from
# and every power parameter. The report uses a saved result only when its
# fingerprint matches the current one, so a power run on older models or
# settings is never read as current (it falls back to D-096's NA path)
power_results_path <- file.path(paths$bag, "power_results.rds")
power_fingerprint <- function() digest::digest(list(
  bases = map_chr(c(ss_sets$spec_base, power_specs), \(s) attr(fit_cache_path(s$key, paths$models), "hash")),
  params = qparams[c("power_nsim", "power_effects", "power_nsim_bracket", "power_fade_effect",
                     "timing_power_effects", "radius_effects", "radius_km")]), algo = "sha256")

# Worker output (D-102). callr::r_bg() sends a worker's stdout and stderr to
# pipes by default, and neither runner reads them while it waits: once a
# worker printed more than a pipe holds, its next write blocked forever (two
# v5 warm starts sat at zero CPU for two hours on 2026-11-06). Each worker
# instead writes both streams to its own file in worker_logs/ of the report
# folder, named after its fit or refit set and overwritten by the next
# attempt, so output can never block and every fit leaves a log to read.
worker_log <- function(name) {
  d <- file.path(paths$bag, "worker_logs")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  file.path(d, paste0(gsub("[^A-Za-z0-9_.-]+", "_", name), ".log"))
}
# A finished worker's error, or NULL when it succeeded. A worker whose R
# code errors still exits with status 0 (callr records the error in its
# result file instead; checked 2026-11-06), so the exit status alone never
# caught a failed fit: the result is checked too. The message is callr's
# record of the error (independent of the output streams) and the last
# lines of the worker's log
worker_error <- function(p, log_file) {
  err <- tryCatch({ p$get_result(); NULL }, error = conditionMessage)
  if (is.null(err) && p$get_exit_status() == 0) return(NULL)
  if (is.null(err)) err <- paste("exit status", p$get_exit_status())
  tail_lines <- if (file.exists(log_file)) tail(readLines(log_file, warn = FALSE), 20) else character()
  paste0(err, "\n--- last lines of ", log_file, " ---\n", paste(tail_lines, collapse = "\n"))
}

# Fits every spec not yet cached, `workers` at a time, each in its own R
# process (callr). Scheduling (D-097):
#   - at most `heavy_workers` fits over `heavy_rows` rows run at once; the
#     other slots take smaller fits, so the large monthly models cannot all
#     run together and exhaust memory;
#   - a warm-started variant (spec$after, its parent's cache file) waits
#     until that file exists;
#   - parents before variants, then largest first, so the long fits start
#     early and their variants can follow.
# Polls every 5 s, and records each fit's peak resident memory from those
# polls (a fit shorter than one poll may show NA). Returns a tibble of
# model and peak_gb for the fits it ran.
# Progress (D-099): quarto holds back R's messages until a chunk ends, so
# each fit's start and end, and every `status_min` minutes a line per
# running fit (minutes, CPU minutes, memory), are appended to
# fit_progress.log in the report folder, where a long run can be watched.
run_specs <- function(specs, workers, heavy_workers = qparams$heavy_workers,
                      heavy_rows = qparams$heavy_rows, status_min = 30) {
  progress_file <- file.path(paths$bag, "fit_progress.log")
  dir.create(paths$bag, recursive = TRUE, showWarnings = FALSE)
  progress <- function(...) cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), ..., "\n",
                                file = progress_file, append = TRUE)
  todo <- keep(specs, \(s) !file.exists(fit_cache_path(s$key, paths$models)))
  message(length(todo), " of ", length(specs), " fits to run")
  progress("run_specs:", length(todo), "of", length(specs), "fits to run;", workers, "workers")
  last_status <- Sys.time()
  rows_of <- \(s) nrow(s$key$data)
  is_heavy <- \(s) rows_of(s) > heavy_rows
  # a variant is ready once its parent's fit is cached
  ready <- \(s) is.null(s$after) || file.exists(s$after)
  todo <- todo[order(!map_lgl(todo, \(s) is.null(s$after)), -map_int(todo, rows_of))]
  running <- list()
  peaks <- tibble(model = character(), peak_gb = numeric())
  while (length(todo) > 0 || length(running) > 0) {
    # fill free slots with the first ready spec that the heavy cap allows
    repeat {
      if (length(running) >= workers || length(todo) == 0) break
      n_heavy <- sum(map_lgl(running, "heavy"))
      i <- detect_index(todo, \(s) ready(s) && (!is_heavy(s) || n_heavy < heavy_workers))
      if (i == 0) break
      s <- todo[[i]]; todo <- todo[-i]
      # user_profile = FALSE (D-099): the worker skips the project's
      # .Rprofile, so renv is not activated in it (renv's activation takes
      # one shared lock, and a worker that never released it stalled every
      # later worker on 2026-11-06); libpath gives it this session's
      # library, the renv project library, instead. Output goes to the
      # fit's own log file, never to a pipe (D-102)
      log_file <- worker_log(s$id)
      p <- callr::r_bg(function(root, spec, dir) {
        setwd(root)
        suppressPackageStartupMessages(library(tidyverse))
        # bag_helpers.R for warm_start_of() (D-097); it only defines
        # functions and constants
        source("r/paths.R"); source("r/gfw_helpers.R"); source("r/analysis_helpers.R")
        source("r/bag_helpers.R")
        fit_cached(spec$key, spec$fun, dir = dir, label = spec$id)
        TRUE
      }, args = list(root = root, spec = s, dir = paths$models), supervise = TRUE,
      user_profile = FALSE, libpath = .libPaths(), stdout = log_file, stderr = "2>&1")
      running[[s$id]] <- list(p = p, heavy = is_heavy(s), peak = NA_real_, start = Sys.time(),
                              log = log_file)
      progress("start:", s$id, "| rows", rows_of(s), if (is_heavy(s)) "| heavy" else "",
               if (!is.null(s$after)) "| warm" else "")
    }
    # nothing running and nothing can start: a variant's parent is neither
    # cached nor queued, so waiting would never end
    if (length(running) == 0 && length(todo) > 0)
      stop("fits waiting on a parent that is not scheduled: ", paste(map_chr(todo, "id"), collapse = ", "))
    Sys.sleep(5)
    for (nm in names(running)) {
      r <- running[[nm]]
      if (r$p$is_alive()) {
        rss <- tryCatch(r$p$get_memory_info()[["rss"]], error = \(e) NA_real_)
        if (!is.na(rss)) running[[nm]]$peak <- max(r$peak, rss, na.rm = TRUE)
      } else {
        mins <- round(as.numeric(difftime(Sys.time(), r$start, units = "mins")), 1)
        err <- worker_error(r$p, r$log)
        if (!is.null(err)) {
          progress("FAILED:", nm, "after", mins, "min | log", r$log)
          stop("fit failed: ", nm, "\n", err)
        }
        progress("done:", nm, "|", mins, "min | peak", round(r$peak / 1e9, 2), "GB")
        peaks <- add_row(peaks, model = nm, peak_gb = round(r$peak / 1e9, 2))
        running[[nm]] <- NULL
      }
    }
    # every status_min minutes, one line per running fit: wall minutes, CPU
    # minutes (a fit whose CPU stops rising is stuck; one whose CPU tracks
    # its wall time is working) and current memory
    if (difftime(Sys.time(), last_status, units = "mins") >= status_min) {
      last_status <- Sys.time()
      iwalk(running, function(r, nm) {
        cpu <- tryCatch(sum(r$p$get_cpu_times()[c("user", "system")]), error = \(e) NA_real_)
        rss <- tryCatch(r$p$get_memory_info()[["rss"]], error = \(e) NA_real_)
        progress("running:", nm, "|", round(as.numeric(difftime(Sys.time(), r$start, units = "mins"))), "min |",
                 round(cpu / 60), "CPU min |", round(rss / 1e9, 2), "GB")
      })
      progress("queued:", length(todo))
    }
  }
  progress("run_specs: finished")
  peaks
}

# --- refit workers (leave-one-vessel-out in 09a, power in 09b) ---------------
# a job: one response vector to refit with the full stage × season model.
# Shared by the power analysis and the leave-one-vessel-out refits (step 8)
# `term`, `terms`: the model's headline and BAG terms, which depend on its
# band scheme (D-076). `wald_terms`: if given, the terms of the gradient test
# (D-091), whose Wald statistic each worker also computes from the refit's
# fixed-effect covariance and stores as wald_chi2, wald_df and wald_p. The
# power analysis passes them; leave-one-vessel-out does not need them.
# `formula`, `spatiotemporal`, `time`: the model refitted, by default the
# stage × season model (iid field by stage); the timing power and radius
# recovery (D-094) pass the season-year timing formula with an AR1 field
# over time_year. Every refit also records its AIC, for the radius recovery
# `read_only` (D-101): the report reads the results 09a or 09b wrote and
# stops, rather than refitting, if any is missing
run_refit_jobs <- function(spec_id, d, family, jobs, term, terms, wald_terms = NULL,
                           formula = ss_formula, spatiotemporal = "iid", time = "stage_num",
                           workers = qparams$workers, read_only = FALSE) {
  # spec on disk, read by every worker; its hash names the result folder, so
  # a changed specification never reuses old results. wald_terms and a
  # non-default field join the spec only when given, so a stage × season
  # caller keeps its existing key
  # `cutoff`: the numeric mesh cutoff (D-098), as for the main fits
  spec <- list(data = d, formula = formula, family = family, cutoff = cutoff,
               term = term, terms = terms)
  if (!is.null(wald_terms)) spec$wald_terms <- wald_terms
  if (spatiotemporal != "iid" || time != "stage_num") {
    spec$spatiotemporal <- spatiotemporal; spec$time <- time
  }
  key <- substr(digest::digest(list(spec, as.character(packageVersion("sdmTMB"))), algo = "sha256"), 1, 10)
  out_dir <- file.path(job_dir, paste(spec_id, key, sep = "_"))
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  spec_file <- file.path(out_dir, "spec.rds")
  if (!file.exists(spec_file)) saveRDS(spec, spec_file)
  # each result file is named by its tag and a hash of its response vector,
  # so a refit is reused only for exactly the same simulated data
  jobs <- jobs |> mutate(tag0 = tag, tag = paste0(tag, "_", map_chr(y, \(v) substr(digest::digest(v), 1, 8))))
  todo <- jobs |> mutate(file = file.path(out_dir, paste0(tag, ".rds"))) |> filter(!file.exists(file))
  if (read_only && nrow(todo) > 0)
    stop(nrow(todo), " of ", nrow(jobs), " refits of ", spec_id, " not run. Render r/09a_bag_fit.qmd ",
         "(leave-one-vessel-out) or r/09b_bag_power.qmd (power) for this pipeline first", call. = FALSE)
  if (nrow(todo) > 0) {
    chunks <- split(todo, rep_len(seq_len(min(workers, nrow(todo))), nrow(todo)))
    # one log per worker, named by the refit set and the worker's number;
    # output goes there, never to a pipe (D-102)
    logs <- map_chr(seq_along(chunks), \(i) worker_log(paste0(basename(out_dir), "_w", i)))
    procs <- map2(chunks, logs, function(ch, log_file) {
      jf <- tempfile(fileext = ".rds"); saveRDS(ch, jf)
      callr::r_bg(function(root, spec_file, jobs_file) {
        setwd(root)
        suppressPackageStartupMessages({ library(sdmTMB); library(dplyr) })
        # fit_wald() and wald_joint(), for the gradient test (D-091); the
        # helpers file only defines functions and constants, so sourcing it
        # has no side effects in the worker
        source("r/bag_helpers.R")
        spec <- readRDS(spec_file); jobs <- readRDS(jobs_file)
        wt <- spec$wald_terms
        # the gradient test of one refit, by fit_wald() (labels from the
        # design matrix, as in Step 5); NA when the refit failed or its terms
        # cannot be matched to the covariance
        wald_of <- function(fit) {
          if (is.null(fit)) return(data.frame(wald_chi2 = NA_real_, wald_df = length(wt), wald_p = NA_real_))
          w <- fit_wald(fit, wt)
          data.frame(wald_chi2 = w$chi2, wald_df = w$df, wald_p = w$p)
        }
        fam <- switch(spec$family, nbinom2 = nbinom2(), tweedie = tweedie())
        mesh <- make_mesh(spec$data, c("x_km", "y_km"), cutoff = spec$cutoff)
        # the field over time: the stage × season default unless the spec
        # names another (the timing refits' AR1 over years, D-094)
        st <- if (is.null(spec$spatiotemporal)) "iid" else spec$spatiotemporal
        tm <- if (is.null(spec$time)) "stage_num" else spec$time
        for (j in seq_len(nrow(jobs))) {
          d <- spec$data; d$hours <- jobs$y[[j]]
          fit <- try(sdmTMB(spec$formula, data = d, mesh = mesh, family = fam, offset = d$log_expo,
                            spatial = "on", spatiotemporal = st, time = tm, silent = TRUE),
                     silent = TRUE)
          # the same convergence rule as fit_ok() in the main session
          ok <- !inherits(fit, "try-error") &&
            isTRUE(all(unlist(sanity(fit, silent = TRUE))[c("hessian_ok", "eigen_values_ok", "nlminb_ok", "gradients_ok")]))
          res <- if (ok) {
            t <- tidy(fit)
            r <- t[t$term %in% spec$terms, c("term", "estimate", "std.error")]
            # one gradient test per refit, repeated on each of its term rows
            if (!is.null(wt)) r <- cbind(r, wald_of(fit))
            # the refit's AIC, for comparing radii (D-094)
            r$aic <- AIC(fit)
            r
          } else {
            r <- data.frame(term = spec$term, estimate = NA_real_, std.error = NA_real_)
            if (!is.null(wt)) r <- cbind(r, wald_of(NULL))
            r$aic <- NA_real_
            r
          }
          saveRDS(cbind(res, tag = jobs$tag[j]), file.path(dirname(spec_file), paste0(jobs$tag[j], ".rds")))
        }
        TRUE
      # user_profile = FALSE and this session's library: no renv
      # activation, so no shared lock to wait on (D-099)
      }, args = list(root = root, spec_file = spec_file, jobs_file = jf), supervise = TRUE,
      user_profile = FALSE, libpath = .libPaths(), stdout = log_file, stderr = "2>&1")
    })
    walk(procs, \(p) p$wait())
    errs <- map2(procs, logs, worker_error)
    failed <- which(!map_lgl(errs, is.null))
    if (length(failed) > 0)
      stop(length(failed), " refit workers failed: ", errs[[failed[1]]])
  }
  # results carry the caller's original tag
  map_dfr(seq_len(nrow(jobs)), \(j) readRDS(file.path(out_dir, paste0(jobs$tag[j], ".rds"))) |>
            mutate(tag = jobs$tag0[j]))
}

# --- random-field check specs (D-077) ----------------------------------------
# Built whatever `field_check` says, so 09a and the report agree on them;
# 09a fits them, and the report reads them, only when it is true.
# Phase 3's practical range per dataset × gear (07 writes it); the block
# size for each stage × season model's folds
rho0_path <- file.path(paths$spatial, "tables", "global_rho0.csv")
input_files <- c(input_files, rho0_path)
rho0 <- read_csv(rho0_path, show_col_types = FALSE) |>
  transmute(id = paste(dataset, gear_class, sep = "_"), rho0_km, rho0_censored)

# a cross-validation specification: the same cache as make_spec(), but the
# fit function runs sdmTMB_cv and keeps only the scores (no models, no
# coefficients), so nothing here can be read as a BAG effect
make_cv_spec <- function(id, d, formula, family, spatiotemporal, time, folds) {
  force(d); force(formula); force(family); force(spatiotemporal); force(time); force(folds)
  cut <- cutoff
  key <- list(type = "spatial-block cv", data = d, formula = formula, family = family, cutoff = cut,
              spatial = "on", spatiotemporal = spatiotemporal, time = time, folds = folds)
  fun <- function() {
    fam <- switch(family, nbinom2 = sdmTMB::nbinom2(), tweedie = sdmTMB::tweedie())
    # one mesh from all the data, shared by every fold
    mesh <- sdmTMB::make_mesh(d, c("x_km", "y_km"), cutoff = cut)
    # sequential folds: each spec already runs in its own process, and the
    # future packages are not direct dependencies; the offset must be given
    # by column name for sdmTMB_cv
    cv <- sdmTMB::sdmTMB_cv(formula, data = d, mesh = mesh, family = fam, offset = "log_expo",
                            spatial = "on", spatiotemporal = spatiotemporal, time = time,
                            fold_ids = folds, k_folds = max(folds), parallel = FALSE,
                            save_models = FALSE, silent = TRUE)
    list(sum_loglik = cv$sum_loglik, fold_loglik = cv$fold_loglik, pdHess = cv$pdHess,
         max_gradients = cv$max_gradients, fold_rows = as.vector(table(folds)))
  }
  list(id = id, key = key, fun = fun)
}

# the three field structures for the stage × season models
cv_structures <- tribble(~structure, ~spatiotemporal, ~time,
                         "shared", "off", NA,
                         "iid per stage", "iid", "stage_num",
                         "AR1 per stage", "ar1", "stage_num")
cv_sets <- ss_sets |>
  select(id, family, data) |>
  left_join(rho0, by = "id") |>
  # blocks at least ρ0 wide, rounded up to the next km
  mutate(block_km = ceiling(rho0_km),
         folds = map2(data, block_km, \(d, b) spatial_block_folds(d$x_km, d$y_km, b, qparams$cv_folds)),
         blocks = map2_int(data, block_km, \(d, b) n_distinct(floor((d$x_km - min(d$x_km)) / b),
                                                            floor((d$y_km - min(d$y_km)) / b)))) |>
  cross_join(cv_structures) |>
  mutate(spec = pmap(list(id, data, family, spatiotemporal, time, folds, structure),
                     \(id, d, fam, st, tm, fo, s) make_cv_spec(paste(id, "cv", s), d, ss_formula, fam, st,
                                                               if (is.na(tm)) NULL else tm, fo)))

# the timing models without the AR1 year field, for the AIC comparison
field_timing <- timing_sets |> filter(!map_lgl(spec_timing, is.null)) |>
  # started from the timing fit (D-097); its AR1 field is left out of the start
  mutate(spec_nofield = pmap(list(id, plan, step, family, spec_timing), \(id, pl, step, fam, parent)
    make_spec(paste(id, "timing no year field"), pl$data, timing_formula(step, pl$terms), fam,
              knots = month_knots(step), start_from = parent)))

field_specs <- c(cv_sets$spec, field_timing$spec_nofield)

# --- leave-one-vessel-out (step 8) -------------------------------------------
# vessel_hours: read in "Vessel records" above
lovo_vessels <- vessel_hours |>
  group_by(dataset, gear_class, MMSI) |>
  summarise(vessel = first(vessel), hours = sum(hours), .groups = "drop") |>
  group_by(dataset, gear_class) |>
  mutate(rank = rank(-hours, ties.method = "first")) |>
  filter(rank <= qparams$lovo_top_k | MMSI %in% as.character(unlist(qparams$lovo_extra))) |>
  ungroup()

# The headline refitted without each of those vessels, one refit set per
# stage × season model. 09a runs it; the report calls it with read_only =
# TRUE, which reads the same result files and refits nothing (D-101)
lovo_refits <- function(read_only = FALSE) ss_sets |>
  mutate(res = pmap(list(id, dataset, gear, data, family, headline, terms), function(id, ds, g, d, fam, hl, tm) {
    vs <- filter(lovo_vessels, dataset == ds, gear_class == g)
    if (nrow(vs) == 0) return(NULL)
    jobs <- tibble(MMSI = vs$MMSI) |>
      mutate(tag = paste0("lovo_", MMSI),
             y = map(MMSI, function(v) {
               h <- vessel_hours |> filter(dataset == ds, gear_class == g, MMSI == v) |>
                 select(cell_id, stage, season, h_v = hours)
               dd <- left_join(select(d, cell_id, stage, season, hours) |> mutate(stage = as.character(stage),
                                                                                  season = as.character(season)),
                               h, by = c("cell_id", "stage", "season"))
               y <- dd$hours - coalesce(dd$h_v, 0)
               y <- pmax(0, y)
               if (fam == "nbinom2") round(y) else y
             }))
    # vessel names are attached by the report, from the tag
    run_refit_jobs(id, d, fam, jobs, hl, tm, read_only = read_only) |> filter(term == hl)
  })) |>
  select(id, res) |> unnest(res)
