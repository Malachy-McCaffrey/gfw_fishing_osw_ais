# Helpers for the BAG models (Phase 4, 10_bag.qmd). Source after the
# tidyverse, r/paths.R, r/gfw_helpers.R and r/analysis_helpers.R:
#   source("r/analysis_helpers.R"); source("r/bag_helpers.R")
#
# Pure functions of their arguments (the simulation and bootstrap ones take
# an explicit seed), unit-tested in r/tests/testthat/test-bag_helpers.R.
# The model fits themselves live in 10_bag.qmd, cached with fit_cached().

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

# Whether each term meets the minimum support set in 10's parameters
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
# The plan's reading rules (@sec-bag-reading) as functions, so 10's verdict
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
