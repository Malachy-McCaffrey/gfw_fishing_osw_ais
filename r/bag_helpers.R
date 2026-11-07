# Helpers for the BAG models (Phase 4, 09_bag.qmd). Source after the
# tidyverse, r/paths.R, r/gfw_helpers.R and r/analysis_helpers.R:
#   source("r/analysis_helpers.R"); source("r/bag_helpers.R")
#
# Pure functions of their arguments (the simulation and bootstrap ones take
# an explicit seed), unit-tested in r/tests/testthat/test-bag_helpers.R.
# The model fits themselves live in 09_bag.qmd, cached with fit_cached().

# Factor levels used by every BAG model --------------------------------------
# The 8–15 km ring is the BAG reference (plan, "BAG design"), and Stage 1 the
# reference period, so each stage × band coefficient is the change in that
# band's rate, relative to the outer ring, since Stage 1.
bag_stage_levels <- c("Stage 1", "Stage 2", "Stage 3")
bag_band_levels  <- c("8-15", "inside", "0-2", "2-4", "4-8")
bag_phase_levels <- c("pre", "construction", "post_construction")

# Set the reference levels and z-score the terrain covariates. `d`: a model
# table with stage (if present), dist_band, phase (if present), slope_deg and
# bpi_broad. The z-scores use the table's own mean and SD, so each model's
# covariates are centred on its own domain.
bag_prepare <- function(d) {
  z <- \(x) (x - mean(x)) / stats::sd(x)
  d |>
    dplyr::mutate(
      dist_band = factor(as.character(dist_band), levels = bag_band_levels),
      dplyr::across(dplyr::any_of("stage"), \(x) factor(x, levels = bag_stage_levels)),
      dplyr::across(dplyr::any_of("phase"), \(x) factor(x, levels = bag_phase_levels)),
      dplyr::across(dplyr::any_of("season"), \(x) factor(x, levels = c("AprSep", "OctMar"))),
      slope_z = z(slope_deg), bpi_z = z(bpi_broad))
}

# Rate ratios from fixed-effect estimates --------------------------------------
# `tab`: a tibble with term, estimate and std.error (log scale), e.g. from
# sdmTMB::tidy() or broom-style output. Returns the requested terms with the
# rate ratio exp(estimate) and its Wald confidence interval at `level`.
rate_ratios <- function(tab, terms, level = 0.95) {
  z <- stats::qnorm(1 - (1 - level) / 2)
  out <- dplyr::filter(tab, term %in% terms)
  stopifnot("a requested term is not in the model" = all(terms %in% out$term))
  out |>
    dplyr::transmute(term, estimate, std.error,
                     rr = exp(estimate), rr_lo = exp(estimate - z * std.error),
                     rr_hi = exp(estimate + z * std.error),
                     p = 2 * stats::pnorm(-abs(estimate / std.error)))
}

# Injecting a known effect into simulated data (power analysis) ---------------
# Multiplies the expected response by `factor` (1 − e) row by row, without
# refitting the generating model:
# - counts (VP, NB2): binomial thinning, each of the y events kept with
#   probability `factor`, so the mean becomes factor × μ exactly, and the
#   result stays an integer count;
# - continuous (AFE, Tweedie): y × factor, which scales the mean and keeps
#   the zeros (a Tweedie variable stays Tweedie under scaling, with the same
#   power p).
# `factor`: one value per row (1 where nothing is injected). `seed` makes the
# thinning reproducible.
inject_effect <- function(y, factor, type = c("count", "continuous"), seed = 1) {
  type <- match.arg(type)
  stopifnot(length(factor) == length(y) || length(factor) == 1,
            "factors must lie in [0, 1]" = all(factor >= 0 & factor <= 1))
  factor <- rep_len(factor, length(y))
  if (type == "continuous") return(y * factor)
  set.seed(seed)
  stats::rbinom(length(y), size = round(y), prob = factor)
}

# Power, bias and coverage for one effect size ----------------------------------
# `est`, `se`: the headline log rate ratio and its SE from each refit;
# `true_e`: the injected effect (0.2 = −20%). A replicate detects the effect
# when its 95% CI excludes 0 (rate ratio 1), as in the plan. Failed refits
# (NA) are counted separately and left out of the rates.
power_from_refits <- function(est, se, true_e, level = 0.95) {
  z <- stats::qnorm(1 - (1 - level) / 2)
  ok <- !is.na(est) & !is.na(se) & is.finite(se)
  lo <- est[ok] - z * se[ok]
  hi <- est[ok] + z * se[ok]
  truth <- log(1 - true_e)
  tibble::tibble(effect = true_e, replicates = sum(ok), failed = sum(!ok),
                 power = mean(lo > 0 | hi < 0),
                 bias = mean(est[ok]) - truth,
                 coverage = mean(lo <= truth & hi >= truth))
}

# Power scenarios (D-091; plan, "Simulation power analysis") ---------------------
# The multiplier for each row's simulated mean, by the shape of the planted
# effect. `stage`: each row's stage; `band`: each row's own FULL distance
# band (inside, 0-2, 2-4, 4-8, 8-15), even when the model pools the bands,
# so a pooled gear's cells get the same effect as a full-band gear's;
# `scenario`:
# - "inside": 1 − e in the inside band only. The matching scenario for a
#   gear fitted with the four bands: its MDE is that of the Stage 3 × inside
#   headline;
# - "near": 1 − e in inside and 0–2 km, the cells of the pooled near band.
#   The matching scenario for a gear whose bands are pooled (D-076);
# - "fading": 1 − e inside, 1 − e/2 at 0–2 km and 1 − e/4 at 2–4 km, a
#   displacement that weakens with distance. For the gradient test's power
#   only (the shape the test exists to detect), not for the MDE.
# Only Stage 3 rows are touched; Stages 1 and 2 keep a multiplier of 1.
power_effect_factor <- function(stage, band, scenario = c("inside", "near", "fading"), e) {
  scenario <- match.arg(scenario)
  ifelse(as.character(stage) == "Stage 3", 1 - e * band_share(band, scenario, e), 1)
}

# The share of e each row's band receives under a scenario (see
# power_effect_factor()); 0 for bands outside the scenario. Shared by the
# stage × season and timing plants so both use one definition of the shapes.
band_share <- function(band, scenario, e) {
  stopifnot("e must be a single proportion in [0, 1)" = length(e) == 1 && e >= 0 && e < 1)
  share <- switch(scenario,
                  inside = c(inside = 1),
                  near   = c(inside = 1, "0-2" = 1),
                  fading = c(inside = 1, "0-2" = 0.5, "2-4" = 0.25))
  s <- unname(share[as.character(band)])
  s[is.na(s)] <- 0
  s
}

# The timing models' planted effect (D-094; plan, "Simulation power
# analysis", step 2): as power_effect_factor(), but on the rows in each
# cell's own construction phase (`construction` = 1) instead of Stage 3, so
# it is the effect the construction × inside (or near) term estimates.
# `band`: each row's own FULL band; `scenario`: "inside" (four bands) or
# "near" (pooled bands), the matching scenario of the timing model.
timing_effect_factor <- function(construction, band, scenario = c("inside", "near"), e) {
  scenario <- match.arg(scenario)
  ifelse(construction == 1, 1 - e * band_share(band, scenario, e), 1)
}

# The effect sizes that get 400 more simulations, to 500 (D-094): after the
# 100-simulation pass, the smallest e > 0 with power >= target, and the
# tested size just below it when that is above 0. Empty when no size
# reaches the target (no second pass: the gear's MDE is above the largest
# tested size either way). `effect`, `power`: one value per tested size.
bracket_effects <- function(effect, power, target = 0.8) {
  o <- order(effect); effect <- effect[o]; power <- power[o]
  i <- which(effect > 0 & !is.na(power) & power >= target)
  if (length(i) == 0) return(numeric())
  i <- min(i)
  below <- if (i > 1 && effect[i - 1] > 0) effect[i - 1]
  c(below, effect[i])
}

# Radius recovery for one effect size (D-065, D-094; plan, "Radius
# recovery"). `tab`: one row per simulation × radius refit, with columns
# sim, radius (km), aic, estimate and std.error of λ (NA when the refit
# failed); `true_e`: the planted effect, so the true λ is log(1 − e);
# `primary`: the radius the effect was planted at. Only simulations whose
# refits converged at every radius are scored, so the AIC comparison is
# always among the same radii. Returns:
# - power: λ's 95% CI excludes 0 at the primary radius;
# - recovery: the primary radius has the lowest AIC;
# - false_select: another radius beats the primary by more than `delta` AIC
#   units (at e = 0, the selection noise);
# - bias_primary, bias_winner: mean λ minus the truth at the primary radius
#   and at whichever radius has the lowest AIC (the winner's curse).
radius_summary <- function(tab, true_e, primary = 5, delta = 2, level = 0.95) {
  z <- stats::qnorm(1 - (1 - level) / 2)
  truth <- log(1 - true_e)
  n_radii <- dplyr::n_distinct(tab$radius)
  ok <- tab |>
    dplyr::group_by(sim) |>
    dplyr::filter(sum(!is.na(aic) & !is.na(estimate)) == n_radii) |>
    dplyr::ungroup()
  per_sim <- ok |>
    dplyr::group_by(sim) |>
    dplyr::summarise(
      aic_primary = aic[radius == primary],
      est_primary = estimate[radius == primary],
      se_primary = std.error[radius == primary],
      best = radius[which.min(aic)],
      est_winner = estimate[which.min(aic)],
      beaten = any(aic[radius != primary] < aic[radius == primary] - delta),
      .groups = "drop")
  tibble::tibble(
    effect = true_e,
    n_sims = dplyr::n_distinct(tab$sim),
    n_complete = nrow(per_sim),
    power = mean(abs(per_sim$est_primary) > z * per_sim$se_primary),
    recovery = mean(per_sim$best == primary),
    false_select = mean(per_sim$beaten),
    bias_primary = mean(per_sim$est_primary) - truth,
    bias_winner = mean(per_sim$est_winner) - truth)
}

# The gradient test's rejection rate across refits (D-091): the share of
# converged refits whose Wald test of all Stage 3 × band terms rejects at
# `alpha`. At e = 0 this is the test's false-positive rate (should be close
# to alpha). Failed refits (NA p) are counted, not scored.
wald_power <- function(p, alpha = 0.05) {
  ok <- !is.na(p)
  tibble::tibble(n_ok = sum(ok), n_failed = sum(!ok),
                 power = if (any(ok)) mean(p[ok] < alpha) else NA_real_)
}

# Minimum detectable effect: the smallest tested effect with power >= target,
# or NA if none reaches it (then the gear is reported descriptively, with
# "MDE > largest tested effect").
mde_of <- function(effect, power, target = 0.8) {
  hit <- effect[effect > 0 & power >= target]
  if (length(hit) == 0) NA_real_ else min(hit)
}

# Pre-trend equivalence test (plan, "Pre-trend equivalence test") -------------
# Margin: a pre-trend matters if, extrapolated over `dt_years` (the gap
# between the Stage 1 and Stage 3 midpoints), it would bias the BAG effect by
# half the smallest effect worth detecting (`mde`, as a proportion). Until
# the power analysis has run, the plan's placeholder is log(1.03) a year.
pretrend_margin <- function(mde, dt_years) {
  if (is.na(mde)) return(log(1.03))
  0.5 * abs(log(1 - mde)) / dt_years
}

# TOST for one band's trend `est` (log scale per year, relative to the 8–15
# km ring) with standard error `se` and margin `delta`. Equivalent if the
# 90% CI lies inside (−delta, delta). Returns the plan's three outcomes:
#   "parallel"      90% CI inside the margin;
#   "non-parallel"  95% CI excludes 0 and the estimate is outside the margin;
#   "inconclusive"  anything else.
tost_band <- function(est, se, delta) {
  lo90 <- est - stats::qnorm(0.95) * se
  hi90 <- est + stats::qnorm(0.95) * se
  lo95 <- est - stats::qnorm(0.975) * se
  hi95 <- est + stats::qnorm(0.975) * se
  outcome <- dplyr::case_when(
    lo90 > -delta & hi90 < delta ~ "parallel",
    (lo95 > 0 | hi95 < 0) & abs(est) > delta ~ "non-parallel",
    TRUE ~ "inconclusive")
  tibble::tibble(est, se, lo90, hi90, lo95, hi95, delta, outcome)
}

# The gear's overall pre-trend verdict from its band outcomes: parallel only
# if every band is (an intersection–union test, so no multiplicity
# correction); non-parallel if any band is; otherwise inconclusive.
pretrend_verdict <- function(outcomes) {
  if (any(outcomes == "non-parallel")) "non-parallel"
  else if (all(outcomes == "parallel")) "parallel"
  else "inconclusive"
}

# Where a pre-trend comes from (D-075): compares the full pre-period verdict
# (the gate) with the Stage 1-only and 2016–2019 diagnostic fits. Stage 2
# holds site surveys and boulder clearance, and 2020 holds COVID, so a
# departure seen over the full pre-period but not in Stage 1 points to Stage
# 2 (anticipation or site work) rather than a long-run trend. `full`,
# `stage1`, `pre_covid`: verdicts from pretrend_verdict(). Returns one
# sentence for the reading table.
pretrend_reading <- function(full, stage1, pre_covid) {
  dplyr::case_when(
    full == "parallel" & stage1 == "parallel" ~ "parallel in both: no sign of a problem",
    full != "parallel" & stage1 == "parallel" ~
      "departure arises in Stage 2 (anticipation or site work): read the development terms, not a straight-line trend",
    full == "non-parallel" & stage1 == "non-parallel" ~ "long-run trend: the band × year term is the right fix",
    full == "parallel" ~ paste0("Stage 1 noise or COVID: the 2016–2019 fit is ", pre_covid),
    full == "non-parallel" ~ "departure over the full pre-period; Stage 1 alone is too short to place it",
    stage1 == "non-parallel" ~ paste0("Stage 1 trend not resolved over the full pre-period: the 2016–2019 fit is ", pre_covid),
    TRUE ~ "inconclusive in both: too little information to place a departure")
}

# Stage 2 terms for the timing model (D-075) -----------------------------------
# Months from each pre-construction time step to the cell's first
# construction step, so pre-period steps can be binned by how close the
# works were (event-time leads). `cell_id`; `step`: an integer index of the
# time step (t_index for months; 2 × season_year + OctMar for season-years);
# `phase`: the nearest project's phase; `step_months`: months per step (1 or
# 6). NA for steps not in "pre", and for cells never under construction in
# the window. Relies on phase only moving forward (pre, then construction).
months_to_works <- function(cell_id, step, phase, step_months = 1) {
  pre <- as.character(phase) == "pre"
  first_works <- stats::ave(ifelse(pre, NA_real_, step), cell_id,
                            FUN = function(x) if (all(is.na(x))) rep(NA_real_, length(x)) else rep(min(x, na.rm = TRUE), length(x)))
  ifelse(pre, (first_works - step) * step_months, NA_real_)
}

# The pre-construction bin of each time step (D-075): "baseline" (Stage 1),
# "dev_early" (development, more than 24 months before the works, or no
# works in the window), "lead_24_13" and "lead_12_1"; NA outside "pre".
# `development`: logical, the step is pre-construction and in Stage 2 or
# later. Leads count only inside development, so Stage 1 stays the baseline.
pre_period_bin <- function(phase, development, lead_months) {
  dplyr::case_when(
    as.character(phase) != "pre" ~ NA_character_,
    !development ~ "baseline",
    !is.na(lead_months) & lead_months <= 12 ~ "lead_12_1",
    !is.na(lead_months) & lead_months <= 24 ~ "lead_24_13",
    TRUE ~ "dev_early")
}

# Distance-band schemes (D-076) ------------------------------------------------
# The non-reference bands of each scheme, named as they appear in column
# names (`<prefix>_<name>`) with their dist_band labels as values. "full" is
# the plan's four bands; "merged" pools them into near (inside + 0–2 km) and
# mid (2–8 km), for gears too sparse to support four band terms. The 8–15 km
# ring stays the reference in both.
band_schemes <- list(
  full   = c(inside = "inside", "0_2" = "0-2", "2_4" = "2-4", "4_8" = "4-8"),
  merged = c(near = "near", mid = "mid"))

# Recode dist_band to the merged scheme: inside and 0–2 km become "near",
# 2–4 and 4–8 km "mid"; the 8–15 km ring is unchanged and stays the
# reference level.
merge_bands <- function(dist_band) {
  x <- as.character(dist_band)
  x[x %in% c("inside", "0-2")] <- "near"
  x[x %in% c("2-4", "4-8")] <- "mid"
  factor(x, levels = c("8-15", "near", "mid"))
}

# Indicator × distance-band columns, named `<prefix>_<band>` for the
# non-reference bands of `bands` (default: the full scheme's inside, 0_2,
# 2_4, 4_8, as the timing model's cx_* terms are). `d`: a model table with
# dist_band; `ind`: the name of a 0/1 column in it.
band_interactions <- function(d, ind, prefix, bands = band_schemes$full) {
  for (nm in names(bands))
    d[[paste0(prefix, "_", nm)]] <- d[[ind]] * (as.character(d$dist_band) == bands[[nm]])
  d
}

# Distance to the nearest installed foundation as bands, for the timing
# model's h(·) (D-076). `cuts`: upper edges in km, e.g. c(2, 5, 10) for
# 0–2 / 2–5 / 5–10 km, or a coarser c(5, 10) or 10 when the finer bands lack
# support. Cells with no foundation within the last cut are "none", the
# reference level.
found_band_of <- function(d_found_km, cuts = c(2, 5, 10)) {
  labs <- paste0(c(0, utils::head(cuts, -1)), "-", cuts)
  x <- cut(d_found_km, c(0, cuts), labels = labs, include.lowest = TRUE)
  x <- as.character(x)
  x[is.na(x)] <- "none"
  factor(x, levels = c("none", labs))
}

# Last day of the model time step holding `month` (a first-of-month Date),
# so vessel records can be matched to the timing tables' rows. "month": the
# month's last day. "season_year": the project's convention
# (season_year_of(), r/analysis_helpers.R): AprSep Y ends 30 September Y;
# OctMar Y runs October Y − 1 to March Y and ends 31 March Y.
step_end_of <- function(month, step) {
  if (step == "month") return(as.Date(format(month + 31, "%Y-%m-01")) - 1)
  mo <- as.integer(format(month, "%m")); yr <- as.integer(format(month, "%Y"))
  as.Date(dplyr::case_when(
    mo >= 4 & mo <= 9 ~ sprintf("%d-09-30", yr),
    mo >= 10 ~ sprintf("%d-03-31", yr + 1L),
    TRUE ~ sprintf("%d-03-31", yr)))
}

# Last day of a season-year time step, from the table's season and
# season_year columns (the same convention as step_end_of()).
season_year_end <- function(season, season_year) {
  as.Date(ifelse(season == "AprSep", sprintf("%d-09-30", as.integer(season_year)),
                 sprintf("%d-03-31", as.integer(season_year))))
}

# An integer index that orders season-year steps in time: within season_year
# Y, OctMar (October Y − 1 to March Y) comes before AprSep Y.
season_year_index <- function(season, season_year) {
  2L * as.integer(season_year) + as.integer(season == "AprSep")
}

# Term support (D-076) ---------------------------------------------------------
# The fixed-effect part of a model formula: every term except the s()
# smooths, which have no indicator columns to count.
fixed_formula <- function(f) {
  lab <- attr(stats::terms(f), "term.labels")
  stats::as.formula(paste(deparse(f[[2]]), "~", paste(lab[!startsWith(lab, "s(")], collapse = " + ")))
}

# How much data backs each 0/1 column of a model's fixed-effect design:
# rows with it on, positive rows (hours > 0) among them, distinct cells with
# a positive row and, if `vessels` is given, distinct vessels with positive
# hours in those rows. Continuous columns (the intercept, terrain, shares,
# trends) are skipped. `formula`, `d`: the model formula and data.
# `vessels`: one row per key × MMSI with positive hours, keyed by `keys`
# (columns of `d`, e.g. cell_id, stage, season).
term_support <- function(formula, d, vessels = NULL, keys = NULL) {
  X <- stats::model.matrix(fixed_formula(formula), d)
  ind <- colnames(X)[apply(X, 2, function(x) all(x %in% c(0, 1)))]
  ind <- setdiff(ind, "(Intercept)")
  pos <- d$hours > 0
  if (!is.null(vessels)) {
    # character keys on both sides, so factors and dates join alike
    kd <- dplyr::mutate(dplyr::select(d, dplyr::all_of(keys)), dplyr::across(dplyr::everything(), as.character))
    kv <- dplyr::mutate(vessels, dplyr::across(dplyr::all_of(keys), as.character))
  }
  purrr::map_dfr(ind, function(t) {
    on <- X[, t] == 1
    nv <- if (is.null(vessels)) NA_integer_ else
      dplyr::n_distinct(dplyr::semi_join(kv, dplyr::distinct(kd[on & pos, , drop = FALSE]), by = keys)$MMSI)
    tibble::tibble(term = t, rows = sum(on), positive = sum(on & pos),
                   cells = dplyr::n_distinct(d$cell_id[on & pos]), vessels = nv)
  })
}

# Whether each term meets the minimum support set in 09's parameters
# (D-076): at least `min_positive` positive rows, from at least `min_cells`
# cells and `min_vessels` vessels. A vessel count of NA (no vessel table)
# skips that criterion.
support_ok <- function(sup, min_positive, min_cells, min_vessels) {
  sup$positive >= min_positive & sup$cells >= min_cells &
    (is.na(sup$vessels) | sup$vessels >= min_vessels)
}

# Spatial-block folds (D-077) -----------------------------------------------------
# Cross-validation folds for the random-field check. The study area is cut
# into square blocks `size_km` on a side (anchored at the lowest x and y),
# and whole blocks are dealt to `k` folds, so every row of a cell (all its
# stages and seasons) lands in the same fold. Blocks at least the
# autocorrelation range ρ0 wide keep most of a held-out block beyond the
# range of the training data, which is what makes the score honest about
# spatial prediction (random row folds would leak through the field).
#
# The deal is deterministic and does not touch the session's random seed:
# blocks are ordered by a hash of (seed, block label) and assigned 1, 2, …,
# k, 1, 2, … in that order, so each fold gets the same number of blocks
# (± 1). Returns an integer fold per row.
spatial_block_folds <- function(x_km, y_km, size_km, k = 5, seed = 42) {
  stopifnot("size_km must be positive" = size_km > 0,
            "x_km and y_km must have the same length" = length(x_km) == length(y_km))
  block <- paste(floor((x_km - min(x_km)) / size_km), floor((y_km - min(y_km)) / size_km))
  blocks <- sort(unique(block))
  if (length(blocks) < k) stop("only ", length(blocks), " blocks of ", size_km, " km for ", k, " folds")
  # the hash order stands in for a shuffle: stable across sessions and platforms
  h <- vapply(blocks, \(b) digest::digest(paste(seed, b), algo = "md5"), character(1))
  fold_of_block <- integer(length(blocks))
  fold_of_block[order(h)] <- rep_len(seq_len(k), length(blocks))
  fold_of_block[match(block, blocks)]
}

# Reading the results (D-078) ----------------------------------------------------
# The plan's reading rules (@sec-bag-reading) as functions, so 09's verdict
# table applies them mechanically and the rules cannot drift after the
# estimates are seen. Estimates are on the log scale (log rate ratio), and
# `mde` is the gear's minimum detectable effect as a proportional decrease
# (0.3 = a 30% drop), so the equivalence margin is ±|log(1 − mde)| on the
# log scale: a 30% drop or the matching 43% rise.

# The verdict on one estimate:
# - "decrease" / "increase": the 95% CI excludes no change;
# - "no change ≥ MDE": the 90% CI lies inside ±MDE (the TOST reading used by
#   the pre-trend test), so any change as large as the MDE is ruled out;
# - "inconclusive": neither (the CI covers no change and an MDE-sized one).
# A missing MDE leaves only the first two readings. NA estimates give NA.
bag_verdict <- function(estimate, se, mde) {
  m <- -log(1 - mde)
  lo95 <- estimate - stats::qnorm(0.975) * se; hi95 <- estimate + stats::qnorm(0.975) * se
  lo90 <- estimate - stats::qnorm(0.95) * se;  hi90 <- estimate + stats::qnorm(0.95) * se
  dplyr::case_when(
    is.na(estimate) | is.na(se) ~ NA_character_,
    hi95 < 0 ~ "decrease",
    lo95 > 0 ~ "increase",
    !is.na(m) & lo90 > -m & hi90 < m ~ "no change ≥ MDE",
    TRUE ~ "inconclusive")
}

# What a sensitivity variant does to the headline's conclusion. A variant on
# a narrower sample (fixed cohort, no safety-zone cells) widens the CI, which
# can turn "decrease" into "inconclusive" with the same point estimate: that
# is lost precision, not a different answer. So the outcome separates the
# two:
# - "shifted": the estimate moves from the headline's by more than the MDE
#   (log scale), or the verdict changes in substance: to the opposite
#   direction, or between a detected change and "no change ≥ MDE". Only
#   this makes a headline "not robust";
# - "weaker" / "stronger": the verdict differs only because the CI is wider
#   (now inconclusive) or narrower (was inconclusive), with the estimate
#   within the MDE of the headline's. Reported, not counted;
# - "same": same verdict, estimate within the MDE.
# NA when the variant failed to fit.
check_outcome <- function(estimate, se, est_head, verdict_head, mde) {
  v <- bag_verdict(estimate, se, mde)
  moved <- !is.na(mde) & abs(estimate - est_head) > -log(1 - mde)
  change <- c("decrease", "increase")
  substantive <- (v %in% change & verdict_head %in% change & v != verdict_head) |
    (v %in% change & verdict_head == "no change ≥ MDE") |
    (v == "no change ≥ MDE" & verdict_head %in% change)
  dplyr::case_when(
    is.na(v) ~ NA_character_,
    moved | substantive ~ "shifted",
    v == verdict_head ~ "same",
    v == "inconclusive" ~ "weaker",
    TRUE ~ "stronger")
}

# Question 1 of the reading order: can the headline be read? Returns one row
# per model with `gate` and the reasons behind it, worst first:
# - "fail": the headline fit did not converge, or the gear is descriptive
#   only (MDE above 50% or never reached; plan, "Simulation power analysis");
# - "hold": the pre-trend is non-parallel, so the headline must come from a
#   model with the band × year trend term (Phase 7), not this one;
# - "caution": the pre-trend is inconclusive (the trend-term model becomes
#   co-primary), or the random-field check prefers another structure (D-077);
# - "pass": none of these.
# `field_other` may be NA (the check was skipped), which is not a caution.
bag_gate <- function(converged, descriptive_only, pretrend, field_other) {
  n <- length(converged)
  out <- lapply(seq_len(n), function(i) {
    fail <- c(if (!isTRUE(converged[i])) "headline fit did not converge",
              if (isTRUE(descriptive_only[i])) "MDE above 50% or not reached")
    hold <- if (identical(pretrend[i], "non-parallel")) "non-parallel pre-trend: needs the band × year term (Phase 7)"
    caution <- c(if (identical(pretrend[i], "inconclusive")) "inconclusive pre-trend: trend-term model co-primary (Phase 7)",
                 if (isTRUE(field_other[i])) "random-field check prefers another structure (D-077)")
    gate <- if (length(fail)) "fail" else if (length(hold)) "hold" else if (length(caution)) "caution" else "pass"
    c(gate, paste(c(fail, hold, caution), collapse = "; "))
  })
  tibble::tibble(gate = vapply(out, `[`, character(1), 1), gate_reasons = vapply(out, `[`, character(1), 2))
}

# The gear's one-line verdict, from the gate, the headline verdict and how
# many of the counted robustness checks shifted it (plan, @sec-bag-reading).
# A "caution" gate keeps the verdict but marks it provisional. `bound`: the
# exclusion upper bound's check_outcome() (Phase 7; NA until it runs). It is
# not a counted check, because restoring guard-vessel hours biases the
# estimate away from a decrease by construction; a shifted bound adds
# "classification-sensitive" instead.
bag_final_verdict <- function(gate, verdict, checks_shifted, mde, bound = NA) {
  robust <- ifelse(checks_shifted == 0, "robust", "not robust")
  v <- dplyr::case_when(
    gate == "fail" ~ "not interpretable (descriptive only)",
    gate == "hold" ~ "withheld until the trend-adjusted fit",
    is.na(verdict) ~ "not interpretable (no estimate)",
    verdict == "inconclusive" ~ "inconclusive",
    verdict %in% c("decrease", "increase") ~ paste0(verdict, " detected, ", robust),
    verdict == "no change ≥ MDE" ~ paste0("no change larger than ", round(100 * mde), "%, ", robust))
  # the bound only qualifies a readable verdict
  v <- ifelse(gate %in% c("pass", "caution") & bound %in% "shifted", paste0(v, "; classification-sensitive"), v)
  ifelse(gate == "caution", paste(v, "(provisional)"), v)
}

# The gradient test (D-091) ------------------------------------------------------
# Beside each headline verdict, the plan (@sec-bag-prereg) asks whether the
# gradient changed shape anywhere: are all Stage 3 × band terms zero at once?
# One band's term cannot answer that, and testing the bands one by one would
# give four chances to be fooled. A Wald test asks it once.
#
# Wald χ² test that the coefficients `estimate` (a named numeric vector, log
# scale) are all zero, given their covariance matrix `V` (from the fit's
# fixed-effect covariance, with the same names on rows and columns). The
# statistic is b' V⁻¹ b, χ² with one degree of freedom per coefficient under
# the null. With one coefficient it is the square of the z-test that
# rate_ratios() reports, so the two agree.
#
# Returns a one-row tibble: chi2, df and p. NA (with df still the number of
# terms) when any estimate or covariance is missing, the names do not match,
# or V is not positive definite (a fit at a boundary): the test cannot be
# read, which is not the same as "no gradient change".
wald_joint <- function(estimate, V) {
  b  <- unname(estimate)
  df <- length(b)
  na <- tibble::tibble(chi2 = NA_real_, df = df, p = NA_real_)
  if (df == 0 || anyNA(b) || anyNA(V)) return(na)
  V <- as.matrix(V)
  # the covariance must describe exactly these coefficients, in this order
  if (is.null(names(estimate)) || !identical(rownames(V), names(estimate)) ||
      !identical(colnames(V), names(estimate))) return(na)
  # positive definite, judged by the eigenvalues relative to the largest:
  # chol() alone is not enough, because rounding can leave an exactly
  # singular matrix with a tiny positive pivot, and the test would then
  # divide by noise. 1e-10 is far below any real variance ratio between
  # coefficients on the log scale
  ev <- eigen(V, symmetric = TRUE, only.values = TRUE)$values
  if (min(ev) <= 1e-10 * max(abs(ev))) return(na)
  # Cholesky gives a stable solve
  R <- tryCatch(chol(V), error = function(e) NULL)
  if (is.null(R)) return(na)
  # b' V⁻¹ b = ||R'⁻¹ b||², with V = R'R
  z <- backsolve(R, b, transpose = TRUE)
  chi2 <- sum(z^2)
  tibble::tibble(chi2 = chi2, df = df, p = stats::pchisq(chi2, df, lower.tail = FALSE))
}

# The linear fixed effects of an sdmTMB fit and their covariance, labelled
# by term, for wald_joint() (D-091). sdmTMB's vcov() cannot be used for this:
# it labels the covariance with tidy()'s terms only when the two have the
# same length, and with a smooth in the formula (every BAG model has
# s(depth_m)) tidy() adds the smooth's coefficient, which is not among the
# linear effects b_j, so vcov() returns unlabelled rows. The labels are the
# column names of the fit's own fixed-effect design matrix (X_ij), which
# are the b_j in order, so estimates and covariance come from the same
# sd_report and cannot be mispaired.
#
# `parts`: 1 for a single-family fit or the first part of a delta model, 2
# for the second, c(1, 2) for both together (named "1:<term>" and
# "2:<term>", with their cross-part covariance). Returns list(estimate, V),
# or NULL if a part's estimates do not match its design matrix (e.g. a
# coefficient mapped off), so the caller reports the test as not readable.
# Takes a fitted model, unlike the pure functions above, and is checked by
# a dry run on synthetic fits rather than in the unit tests.
fixed_effects_cov <- function(fit, parts = 1) {
  pf <- fit$sd_report$par.fixed
  cf <- fit$sd_report$cov.fixed
  par_name <- c("b_j", "b_j2")
  idx <- integer(); nm <- character()
  for (m in parts) {
    i <- which(names(pf) == par_name[m])
    X <- fit$tmb_data$X_ij[[m]]
    if (is.null(X) || length(i) != ncol(X)) return(NULL)
    idx <- c(idx, i)
    nm <- c(nm, if (length(parts) > 1) paste0(m, ":", colnames(X)) else colnames(X))
  }
  V <- cf[idx, idx, drop = FALSE]
  dimnames(V) <- list(nm, nm)
  list(estimate = stats::setNames(unname(pf[idx]), nm), V = V)
}

# The Wald test of `terms` in a fit (D-091), from fixed_effects_cov(). For
# both parts of a delta model, give `parts = c(1, 2)` and the terms
# unprefixed: each is tested in both parts. NA (df still the number of
# tested coefficients) when the terms cannot be matched.
fit_wald <- function(fit, terms, parts = 1) {
  tm <- if (length(parts) > 1) as.vector(outer(paste0(parts, ":"), terms, paste0)) else terms
  fc <- fixed_effects_cov(fit, parts)
  if (is.null(fc) || !all(tm %in% names(fc$estimate)))
    return(tibble::tibble(chi2 = NA_real_, df = length(tm), p = NA_real_))
  wald_joint(fc$estimate[tm], fc$V[tm, tm, drop = FALSE])
}

# Warm starts (D-097) ------------------------------------------------------------
# A variant of a fitted model (the timing model with lead bins, the fleet
# term, or without its AR1 year field) on the same rows, and so the same
# mesh and time steps, starts its optimiser from the parent's estimates
# instead of from zero. The maximum is the same; only the path to it is
# shorter.
#
# Builds sdmTMBcontrol(start = ...) for the variant from parameter lists:
# `parent_pars`, the parent's full parameter list at its optimum (fixed and
# random, as from parList()); `parent_cols`, the column names of its
# fixed-effect design matrix; `template_pars`, `template_cols` and
# `template_map`, the same for the variant, from sdmTMB(..., do_fit = FALSE).
#   - b_j (the linear fixed effects) is matched by column name: shared terms
#     take the parent's value, new terms (log_fleet, the lead bins) start at
#     0, and terms the variant drops are left out.
#   - every other parameter is copied when the parent has it with the same
#     dimensions, except one the variant holds fixed: any NA in its map. A
#     variant without the AR1 field keeps epsilon_st and ar1_phi at full size
#     but mapped off, and copying them would fix the field at the parent's
#     values rather than switch it off.
#   - zero-length parameters, and b_j2 (delta models, not warm-started), are
#     left at their defaults.
# Returns a named list for sdmTMBcontrol(start = ...).
warm_start <- function(parent_pars, parent_cols, template_pars, template_cols, template_map) {
  stopifnot(length(parent_pars$b_j) == length(parent_cols),
            length(template_pars$b_j) == length(template_cols))
  # linear fixed effects by name; new terms at 0
  b <- stats::setNames(rep(0, length(template_cols)), template_cols)
  shared <- intersect(template_cols, parent_cols)
  b[shared] <- as.vector(parent_pars$b_j)[match(shared, parent_cols)]
  b_j <- template_pars$b_j
  b_j[] <- unname(b)
  # every other parameter: same name, same shape, free in the variant
  same_shape <- function(a, t) identical(dim(a), dim(t)) && length(a) == length(t)
  held_fixed <- function(nm) !is.null(template_map[[nm]]) && anyNA(template_map[[nm]])
  rest <- setdiff(names(template_pars), c("b_j", "b_j2"))
  keep <- rest[vapply(rest, function(nm) {
    nm %in% names(parent_pars) && length(template_pars[[nm]]) > 0 &&
      same_shape(parent_pars[[nm]], template_pars[[nm]]) && !held_fixed(nm)
  }, logical(1))]
  c(list(b_j = b_j), parent_pars[keep])
}

# The start list for a variant from its parent's cached fit (D-097), by
# warm_start(). `parent_file`: the parent's fit_cached() file; `template`:
# the variant built with sdmTMB(..., do_fit = FALSE). The parameters are read
# at the parent's best evaluation (last.par.best), random effects included.
# Takes fitted models, unlike the pure function above, so it is checked by
# the warm-against-cold comparison rather than in the unit tests.
warm_start_of <- function(parent_file, template) {
  parent <- readRDS(parent_file)
  e <- parent$tmb_obj$env
  warm_start(e$parList(par = e$last.par.best), colnames(parent$tmb_data$X_ij[[1]]),
             template$tmb_params, colnames(template$tmb_data$X_ij[[1]]), template$tmb_map)
}

# The reading of the gradient test (D-091). It is a significance test, so a
# non-rejection is "no evidence of a gradient change", never "no change":
# only the headline verdict's "no change ≥ MDE" can rule a change out. It
# sits beside the verdict and never alters it. NA p (the test could not be
# computed) gives NA.
gradient_verdict <- function(p, alpha = 0.05) {
  dplyr::case_when(is.na(p) ~ NA_character_,
                   p < alpha ~ "gradient change detected",
                   TRUE ~ "no evidence of a gradient change")
}

# Cell bootstrap of band rates (descriptive BAG) ---------------------------------
# Resamples cells with replacement within each distance band, B times, and
# returns the rate (hours per km² per month, summed hours over summed
# exposure) with a percentile interval. `d`: one row per cell for one
# dataset × gear × stratum, with dist_band, hours and expo (months × km²).
boot_band_rate <- function(d, B = 999, seed = 42, probs = c(0.025, 0.975)) {
  set.seed(seed)
  d |>
    dplyr::group_by(dist_band) |>
    dplyr::group_modify(function(g, k) {
      n <- nrow(g)
      reps <- vapply(seq_len(B), function(b) {
        i <- sample.int(n, n, replace = TRUE)
        sum(g$hours[i]) / sum(g$expo[i])
      }, numeric(1))
      tibble::tibble(rate = sum(g$hours) / sum(g$expo), cells = n,
                     lo = stats::quantile(reps, probs[1], names = FALSE),
                     hi = stats::quantile(reps, probs[2], names = FALSE))
    }) |>
    dplyr::ungroup()
}
