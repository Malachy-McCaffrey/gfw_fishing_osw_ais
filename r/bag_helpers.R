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
