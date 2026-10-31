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

test_that("pretrend_reading() places a departure in Stage 1 or Stage 2 (D-075)", {
  expect_match(pretrend_reading("parallel", "parallel", "parallel"), "no sign")
  expect_match(pretrend_reading("non-parallel", "parallel", "parallel"), "Stage 2")
  expect_match(pretrend_reading("inconclusive", "parallel", "parallel"), "Stage 2")
  expect_match(pretrend_reading("non-parallel", "non-parallel", "parallel"), "long-run")
  expect_match(pretrend_reading("parallel", "inconclusive", "parallel"), "2016–2019 fit is parallel")
  expect_match(pretrend_reading("non-parallel", "inconclusive", "parallel"), "too short")
  expect_match(pretrend_reading("inconclusive", "non-parallel", "inconclusive"), "not resolved")
  expect_match(pretrend_reading("inconclusive", "inconclusive", "parallel"), "inconclusive in both")
  # vectorised over gears
  expect_length(pretrend_reading(c("parallel", "non-parallel"), c("parallel", "parallel"), c("parallel", "parallel")), 2)
})

test_that("months_to_works() counts down to each cell's first construction step", {
  d <- tibble(cell_id = c(rep("a", 4), rep("b", 3)), step = c(1:4, 1:3),
              phase = c("pre", "pre", "construction", "construction", "pre", "pre", "pre"))
  expect_equal(months_to_works(d$cell_id, d$step, d$phase), c(2, 1, NA, NA, NA, NA, NA))
  # season-year steps are 6 months
  expect_equal(months_to_works(d$cell_id, d$step, d$phase, 6)[1:2], c(12, 6))
})

test_that("pre_period_bin() keeps Stage 1 as baseline and bins development by lead", {
  ph <- c("pre", "pre", "pre", "pre", "pre", "construction")
  dev <- c(FALSE, TRUE, TRUE, TRUE, TRUE, FALSE)
  lead <- c(40, 30, 24, 12, NA, NA)
  expect_equal(pre_period_bin(ph, dev, lead),
               c("baseline", "dev_early", "lead_24_13", "lead_12_1", "dev_early", NA))
})

test_that("band_interactions() adds one indicator × band column per non-reference band", {
  d <- tibble(dist_band = factor(c("inside", "0-2", "8-15", "4-8")), x = c(1, 1, 1, 0))
  out <- band_interactions(d, "x", "dx")
  expect_equal(out$dx_inside, c(1, 0, 0, 0))
  expect_equal(out$dx_0_2, c(0, 1, 0, 0))
  expect_equal(out$dx_2_4, c(0, 0, 0, 0))
  expect_equal(out$dx_4_8, c(0, 0, 0, 0))
  # merged scheme (D-076)
  m <- band_interactions(mutate(d, dist_band = merge_bands(dist_band)), "x", "cx", band_schemes$merged)
  expect_equal(m$cx_near, c(1, 1, 0, 0))
  expect_equal(m$cx_mid, c(0, 0, 0, 0))
})

test_that("merge_bands() pools near and mid bands and keeps the ring as reference", {
  m <- merge_bands(c("inside", "0-2", "2-4", "4-8", "8-15"))
  expect_equal(as.character(m), c("near", "near", "mid", "mid", "8-15"))
  expect_equal(levels(m)[1], "8-15")
})

test_that("found_band_of() bands foundation distance at fine and coarse cuts", {
  d <- c(NA, 0.5, 2, 3, 7, 12)
  expect_equal(as.character(found_band_of(d)), c("none", "0-2", "0-2", "2-5", "5-10", "none"))
  expect_equal(as.character(found_band_of(d, c(5, 10))), c("none", "0-5", "0-5", "0-5", "5-10", "none"))
  expect_equal(as.character(found_band_of(d, 10)), c("none", "0-10", "0-10", "0-10", "0-10", "none"))
  expect_equal(levels(found_band_of(d))[1], "none")
})

test_that("step_end_of() matches months to the timing tables' step ends", {
  m <- as.Date(c("2019-02-01", "2019-04-01", "2019-09-01", "2019-10-01", "2020-03-01"))
  expect_equal(step_end_of(m, "month"), as.Date(c("2019-02-28", "2019-04-30", "2019-09-30", "2019-10-31", "2020-03-31")))
  expect_equal(step_end_of(m, "season_year"),
               as.Date(c("2019-03-31", "2019-09-30", "2019-09-30", "2020-03-31", "2020-03-31")))
  # the table side agrees: OctMar 2020 is October 2019 – March 2020
  expect_equal(season_year_end(c("OctMar", "AprSep", "OctMar"), c(2019, 2019, 2020)),
               as.Date(c("2019-03-31", "2019-09-30", "2020-03-31")))
  expect_equal(step_end_of(as.Date("2019-11-01"), "season_year"), season_year_end("OctMar", 2020))
})

test_that("season_year_index() puts OctMar Y before AprSep Y", {
  i <- season_year_index(c("OctMar", "AprSep", "OctMar", "AprSep"), c(2019, 2019, 2020, 2020))
  expect_equal(order(i), 1:4)
  expect_equal(diff(i), c(1, 1, 1))
})

test_that("term_support() counts rows, positive rows, cells and vessels per indicator", {
  d <- tibble(hours = c(0, 2, 1, 0, 3, 4), cell_id = c("a", "a", "b", "b", "c", "c"),
              stage = factor(c("Stage 1", "Stage 3", "Stage 3", "Stage 1", "Stage 3", "Stage 1"),
                             c("Stage 1", "Stage 3")),
              x_cont = c(0.2, 0.5, 1, 2, 3, 4))
  v <- tibble(cell_id = c("a", "b", "c", "c"), stage = c("Stage 3", "Stage 3", "Stage 3", "Stage 3"),
              MMSI = c("1", "1", "2", "3"))
  s <- term_support(hours ~ stage + x_cont + s(x_cont), d, v, c("cell_id", "stage"))
  expect_equal(s$term, "stageStage 3")   # continuous columns and smooths skipped
  expect_equal(s$rows, 3)
  expect_equal(s$positive, 3)
  expect_equal(s$cells, 3)
  expect_equal(s$vessels, 3)
  expect_true(is.na(term_support(hours ~ stage, d)$vessels))
  expect_equal(support_ok(s, 3, 3, 3), TRUE)
  expect_equal(support_ok(s, 3, 3, 4), FALSE)
  expect_equal(support_ok(mutate(s, vessels = NA), 3, 3, 4), TRUE)
})

test_that("spatial_block_folds() keeps blocks whole and deals them evenly (D-077)", {
  # a 20 × 20 km grid of 1 km cells, each with two rows (two stages)
  g <- expand.grid(x = 0:19 + 0.5, y = 0:19 + 0.5)
  x <- rep(g$x, 2); y <- rep(g$y, 2)
  f <- spatial_block_folds(x, y, 5, k = 4)
  expect_type(f, "integer")
  expect_setequal(unique(f), 1:4)
  # every 5 km block sits in one fold, and both rows of a cell agree
  blk <- paste(floor(x / 5), floor(y / 5))
  expect_true(all(tapply(f, blk, \(v) length(unique(v))) == 1))
  expect_equal(f[seq_len(nrow(g))], f[nrow(g) + seq_len(nrow(g))])
  # 16 blocks over 4 folds: 4 blocks each
  expect_equal(as.vector(table(tapply(f, blk, unique))), rep(4, 4))
  # deterministic, and the session seed is left alone
  set.seed(1); r0 <- runif(1); set.seed(1)
  expect_identical(spatial_block_folds(x, y, 5, k = 4), f)
  expect_equal(runif(1), r0)
  expect_false(identical(spatial_block_folds(x, y, 5, k = 4, seed = 7), f))
  expect_error(spatial_block_folds(x, y, 15, k = 5), "only 4 blocks")
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
