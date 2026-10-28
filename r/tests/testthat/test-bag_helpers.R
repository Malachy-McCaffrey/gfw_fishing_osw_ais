# Tests for r/bag_helpers.R (Phase 4)

test_that("bag_prepare() sets the BAG reference levels and z-scores terrain", {
  d <- tibble(stage = c("Stage 2", "Stage 1", "Stage 3", "Stage 1"),
              dist_band = c("inside", "8-15", "0-2", "4-8"),
              season = c("AprSep", "OctMar", "AprSep", "OctMar"),
              slope_deg = c(1, 2, 3, 4), bpi_broad = c(0, 0, 1, 1))
  p <- bag_prepare(d)
  expect_equal(levels(p$stage)[1], "Stage 1")
  expect_equal(levels(p$dist_band)[1], "8-15")
  expect_equal(mean(p$slope_z), 0)
  expect_equal(sd(p$slope_z), 1)
})

test_that("rate_ratios() exponentiates with a Wald interval", {
  tab <- tibble(term = c("a", "b"), estimate = c(log(0.5), 0), std.error = c(0.1, 0.2))
  rr <- rate_ratios(tab, "a")
  expect_equal(rr$rr, 0.5)
  expect_equal(rr$rr_lo, exp(log(0.5) - qnorm(0.975) * 0.1))
  expect_error(rate_ratios(tab, "zzz"), "not in the model")
})

test_that("inject_effect() thins counts and scales continuous values", {
  set.seed(1)
  y <- rpois(20000, 5)
  thinned <- inject_effect(y, 0.7, "count", seed = 2)
  expect_true(all(thinned <= y) && all(thinned == round(thinned)))
  expect_equal(mean(thinned) / mean(y), 0.7, tolerance = 0.02)
  # factor 1 leaves values unchanged; zeros stay zero
  expect_identical(inject_effect(y, 1, "count"), as.integer(y))
  z <- c(0, 1.5, 3)
  expect_equal(inject_effect(z, c(1, 0.5, 0.5), "continuous"), c(0, 0.75, 1.5))
  expect_error(inject_effect(z, 1.2, "continuous"), "\\[0, 1\\]")
})

test_that("power_from_refits() scores power, bias and coverage", {
  truth <- log(0.8)
  est <- c(truth, truth, truth, NA)
  se <- c(0.05, 0.05, 0.5, 0.1)   # two tight CIs exclude 0, one wide does not
  p <- power_from_refits(est, se, 0.2)
  expect_equal(p$replicates, 3)
  expect_equal(p$failed, 1)
  expect_equal(p$power, 2 / 3)
  expect_equal(p$bias, 0)
  expect_equal(p$coverage, 1)
})

test_that("mde_of() returns the smallest effect reaching the target", {
  expect_equal(mde_of(c(0, 0.1, 0.2, 0.3, 0.5), c(0.05, 0.3, 0.7, 0.85, 1)), 0.3)
  expect_true(is.na(mde_of(c(0, 0.2, 0.5), c(0.05, 0.4, 0.6))))
})

test_that("pretrend_margin() follows the plan's formula and placeholder", {
  expect_equal(pretrend_margin(0.3, 6), 0.5 * abs(log(0.7)) / 6)
  expect_equal(pretrend_margin(NA, 6), log(1.03))
})

test_that("tost_band() sorts parallel, non-parallel and inconclusive", {
  d <- 0.03
  expect_equal(tost_band(0.001, 0.005, d)$outcome, "parallel")
  expect_equal(tost_band(0.10, 0.01, d)$outcome, "non-parallel")
  expect_equal(tost_band(0.01, 0.03, d)$outcome, "inconclusive")
  expect_equal(pretrend_verdict(c("parallel", "parallel")), "parallel")
  expect_equal(pretrend_verdict(c("parallel", "inconclusive")), "inconclusive")
  expect_equal(pretrend_verdict(c("inconclusive", "non-parallel")), "non-parallel")
})

test_that("boot_band_rate() gives the pooled rate with an interval around it", {
  set.seed(3)
  d <- tibble(dist_band = rep(c("inside", "8-15"), each = 200),
              hours = rpois(400, rep(c(2, 6), each = 200)), expo = 10)
  b <- boot_band_rate(d, B = 199)
  inside <- b[b$dist_band == "inside", ]
  expect_equal(inside$rate, sum(d$hours[1:200]) / 2000)
  expect_true(inside$lo < inside$rate && inside$hi > inside$rate)
  expect_identical(b, boot_band_rate(d, B = 199))
})
