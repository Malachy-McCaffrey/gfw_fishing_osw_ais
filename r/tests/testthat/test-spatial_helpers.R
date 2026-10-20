# Tests for r/spatial_helpers.R (Phase 2 onward)

suppressPackageStartupMessages(library(spdep))

# A small regular lattice to test on: nx × ny unit cells, queen contiguity
# from the same lattice_nb() 05 checks the real grid with. Centroids are 1 km
# apart, so distances in "km" are cell steps.
test_lattice <- function(nx = 12, ny = 12) {
  g <- expand_grid(iy = seq_len(ny), ix = seq_len(nx))
  nb <- lattice_nb(g$ix, g$iy, as.character(seq_len(nrow(g))))
  list(g = g, nb = nb,
       lw_W = nb2listw(nb, style = "W"),
       lw_B = nb2listw(nb, style = "B"))
}

test_that("g_scale() is √ for VP and y_vst shifted to 0 at zero cells for AFE", {
  d <- c(0, 0.04, 1)
  expect_equal(g_scale(d, "vp"), sqrt(d))
  # c = 0.02, so log(1 + d / c) = log(d + c) - log(c)
  expect_equal(g_scale(d, "afe"), vst_density(d, "afe") - log(0.02))
  expect_equal(g_scale(d, "afe")[1], 0)
  expect_true(all(g_scale(d, "afe") >= 0))
  expect_true(all(is.na(g_scale(c(0, 0), "afe"))))
  expect_error(g_scale(d, "AFE"), "vp or afe")
})

test_that("Moran's I is the same on y_vst and on the G scale for AFE", {
  L <- test_lattice()
  set.seed(1)
  d <- rexp(nrow(L$g)) * rbinom(nrow(L$g), 1, 0.4)
  a <- global_stats(vst_density(d, "afe"), L$lw_W, L$lw_B, y_G = g_scale(d, "afe"))
  b <- global_stats(g_scale(d, "afe"), L$lw_W, L$lw_B)
  # a constant shift leaves I, and the permutation draws under one seed, unchanged
  expect_equal(a$I, b$I)
  expect_equal(a$I_p, b$I_p)
  expect_equal(a$G, b$G)
})

test_that("global_stats() finds clustering in a smooth surface and none in noise", {
  L <- test_lattice()
  # a gradient across the lattice clusters strongly
  smooth <- L$g$ix + L$g$iy
  s <- global_stats(smooth, L$lw_W, L$lw_B)
  expect_gt(s$I, 0.8)
  expect_lt(s$I_p, 0.01)
  expect_gt(s$I, s$I_null_hi)
  expect_gt(s$G_z, 0)
  # every column a plain numeric vector, so the table can be written to CSV
  expect_true(all(map_lgl(s, \(x) is.double(x) && is.null(dim(x)))))
  # independent noise sits inside the permutation band
  set.seed(2)
  noise <- runif(nrow(L$g))
  n <- global_stats(noise, L$lw_W, L$lw_B)
  expect_gt(n$I_p, 0.01)
  expect_true(n$I_null_lo < 0 && n$I_null_hi > 0)
})

test_that("global_stats() is reproducible from its seed, and NA on a degenerate surface", {
  L <- test_lattice()
  set.seed(3)
  y <- runif(nrow(L$g))
  expect_identical(global_stats(y, L$lw_W, L$lw_B), global_stats(y, L$lw_W, L$lw_B))
  expect_true(is.na(global_stats(rep(1, nrow(L$g)), L$lw_W, L$lw_B)$I))
  expect_true(is.na(global_stats(rep(NA_real_, nrow(L$g)), L$lw_W, L$lw_B)$I))
  # General G refuses negative values (AFE y_vst must go through g_scale())
  expect_error(global_stats(y - 0.5, L$lw_W, L$lw_B), "non-negative")
})

test_that("lag and band weights reproduce the queen neighbours at the first lag", {
  L <- test_lattice()
  lag1 <- lag_weights(L$nb, 2)[[1]]
  expect_equal(lapply(lag1$neighbours, as.integer), lapply(L$nb, as.integer))
  # on a unit lattice, the queen neighbours are exactly those within √2
  band1 <- band_weights(cbind(L$g$ix, L$g$iy), c(0, 1.5, 3))[[1]]
  expect_equal(lapply(band1$neighbours, as.integer), lapply(L$nb, as.integer))
})

test_that("correlogram() decays with lag on a smooth surface", {
  L <- test_lattice(15, 15)
  y <- sin(L$g$ix / 3) + cos(L$g$iy / 3)
  cg <- correlogram(y, lag_weights(L$nb, 4))
  expect_equal(nrow(cg), 4)
  expect_true(all(diff(cg$I) < 0))
})

test_that("practical_range() interpolates the first crossing and flags censoring", {
  # crosses 0.1 halfway between 3 and 5 km
  r <- practical_range(c(1, 3, 5, 7), c(0.6, 0.2, 0.0, -0.1))
  expect_equal(r$range_km, 4)
  expect_false(r$censored)
  # never below: censored at the last distance
  r <- practical_range(c(1, 3, 5), c(0.6, 0.4, 0.3))
  expect_equal(r$range_km, 5)
  expect_true(r$censored)
  # below at the first lag: that lag's distance
  expect_equal(practical_range(c(1, 3), c(0.05, 0))$range_km, 1)
  expect_error(practical_range(c(3, 1), c(0.5, 0)), "increase")
})

test_that("local_stats() finds a planted hot block with both statistics", {
  L <- test_lattice(15, 15)
  lw_G <- nb2listw(include.self(L$nb), style = "B")
  # a sparse surface: zeros except a 3 × 3 block of effort and a few strays
  d <- numeric(nrow(L$g))
  d[L$g$ix %in% 6:8 & L$g$iy %in% 6:8] <- 5
  d[c(3, 40, 200)] <- 0.5
  s <- local_stats(vst_density(d, "afe"), g_scale(d, "afe"), L$lw_W, lw_G, nsim = 999)
  expect_equal(nrow(s), nrow(L$g))
  centre <- which(L$g$ix == 7 & L$g$iy == 7)
  expect_gt(s$gi_z[centre], 0)
  expect_equal(s$quadrant[centre], "High-High")
  expect_lt(s$gi_p[centre], 0.01)
  expect_lt(s$lisa_p[centre], 0.01)
  # same seed, same result
  expect_identical(s, local_stats(vst_density(d, "afe"), g_scale(d, "afe"), L$lw_W, lw_G, nsim = 999))
  # an empty neighbourhood far from the block is low, never a hotspot, and
  # not significant (regression test: spdep 1.4.2's folded Gi* p flagged
  # every empty neighbourhood)
  empty <- which(L$g$ix == 14 & L$g$iy == 14)
  expect_lt(s$gi_z[empty], 0)
  expect_gt(s$gi_p[empty], 0.05)
  expect_gt(s$lisa_p[empty], 0.05)
  # the z is (Gi − E.Gi) / √Var.Gi: the hot centre and the empty corner sit on
  # opposite sides of zero
  expect_gt(s$gi_z[centre], 2)
  # degenerate surface: NA rows, not an error
  expect_true(all(is.na(local_stats(rep(0, nrow(L$g)), rep(0, nrow(L$g)), L$lw_W, lw_G)$gi_z)))
  expect_error(local_stats(d - 1, d - 1, L$lw_W, lw_G, nsim = 99), "non-negative")
})

test_that("gi_bins() takes the strictest FDR level and the sign of z", {
  z <- c(4, -4, 2, 0.5, NA)
  # BH over the 4 non-missing p: adjusted 0.002, 0.002, 0.04, 0.9
  p <- c(0.001, 0.001, 0.03, 0.9, NA)
  b <- gi_bins(z, p)
  expect_equal(b[1:2], c(3L, -3L))
  expect_equal(b[3], 2L)            # 0.04 clears 5% but not 1%
  expect_equal(b[4:5], c(0L, 0L))
  expect_equal(gi_status(c(3L, -1L, 0L)), c("hot", "cold", "ns"))
})

test_that("lisa_class() maps quadrants and drops non-significant cells", {
  q <- c("High-High", "Low-Low", "High-Low", "Low-High", "High-High")
  p <- c(0.0001, 0.0001, 0.0001, 0.0001, 0.9)
  expect_equal(lisa_class(q, p), c("HH", "LL", "HL", "LH", "ns"))
  expect_equal(lisa_status(c("HH", "LL", "HL", "ns")), c("hot", "cold", "ns", "ns"))
})

test_that("change_class() follows the archive's mutually exclusive scheme", {
  from <- c("hot", "ns", "hot", "hot", "cold", "cold", "ns", "cold", "ns")
  to   <- c("hot", "hot", "ns", "cold", "hot", "cold", "cold", "ns", "ns")
  expect_equal(as.character(change_class(from, to)), change_levels)
})

test_that("cohen_kappa() is 1 for agreement, 0 for chance and NA when undefined", {
  a <- c(TRUE, TRUE, FALSE, FALSE)
  expect_equal(cohen_kappa(a, a), 1)
  expect_equal(cohen_kappa(c(TRUE, FALSE, TRUE, FALSE), c(TRUE, TRUE, FALSE, FALSE)), 0)
  expect_true(is.na(cohen_kappa(rep(FALSE, 4), rep(FALSE, 4))))
})

test_that("all_zero_neighbourhood() needs the cell and every neighbour at 0", {
  L <- test_lattice(5, 5)
  d <- numeric(25)
  d[13] <- 1                       # the centre cell of the 5 × 5 lattice
  z <- all_zero_neighbourhood(d, L$nb)
  expect_false(z[13])
  expect_false(z[7])               # a neighbour of the centre
  expect_true(z[1])                # a corner two steps away
})

test_that("class_stability() scores kept classes and overlap", {
  base <- c("hot", "hot", "ns", "cold")
  alt  <- c("hot", "ns", "hot", "cold")
  s <- class_stability(base, alt)
  expect_equal(s$keep_share, 2 / 3)
  expect_equal(s$jaccard, 2 / 4)
  expect_true(is.na(class_stability(rep("ns", 3), rep("ns", 3))$keep_share))
})

test_that("null_surface() keeps the observed values and is spatially smooth", {
  L <- test_lattice(15, 15)
  R <- grf_chol(cbind(L$g$ix, L$g$iy), range_km = 6)
  vals <- c(rep(0, 150), rexp(75))
  n1 <- null_surface(R, vals, seed = 1)
  expect_equal(sort(n1), sort(vals))
  expect_identical(n1, null_surface(R, vals, seed = 1))
  expect_false(identical(n1, null_surface(R, vals, seed = 2)))
  # the field's structure survives the rank mapping
  expect_gt(moran(n1, L$lw_W, length(n1), Szero(L$lw_W))$I, 0.3)
})

test_that("power_summary() counts paired replicates with at least the minimum excess", {
  null <- c(0.10, 0.20, 0.30, 0.40)
  sig  <- c(0.25, 0.25, 0.30, 0.55)        # paired excess 0.15, 0.05, 0, 0.15
  s <- power_summary(null, sig)
  expect_equal(s$power, 0.5)               # two replicates reach 10 pp
  expect_equal(s$any_excess, 0.75)
  expect_equal(s$mean_excess, mean(sig - null))
  expect_equal(s$fp, mean(null))
  expect_equal(s$replicates, 4)
  expect_equal(power_summary(null, sig, min_excess = 0.05)$power, 0.75)
  expect_error(power_summary(null, sig[-1]), "pair up")
})

test_that("cached() computes once and then reads the cache", {
  dir <- file.path(tempdir(), "cache_test")
  unlink(dir, recursive = TRUE)
  calls <- 0
  f <- function() { calls <<- calls + 1; 42 }
  expect_equal(cached(dir, "x", list(a = 1), f), 42)
  expect_equal(cached(dir, "x", list(a = 1), f), 42)
  expect_equal(calls, 1)
  # a different key recomputes
  cached(dir, "x", list(a = 2), f)
  expect_equal(calls, 2)
})

test_that("block_bootstrap_I() brackets I and is reproducible", {
  L <- test_lattice(20, 20)
  set.seed(4)
  # smooth signal plus noise, so I is clearly positive but below 1
  y <- sin(L$g$ix / 4) + cos(L$g$iy / 4) + rnorm(nrow(L$g), sd = 0.5)
  I_full <- moran(y, L$lw_W, length(y), Szero(L$lw_W))$I
  # centroids at 0.5, 1.5, ... 19.5, so 5-km blocks tile the 20 × 20 lattice 4 × 4
  cx <- L$g$ix - 0.5
  cy <- L$g$iy - 0.5
  bb <- block_bootstrap_I(y, L$nb, cx, cy, block_km = 5, B = 199)
  expect_equal(bb$n_blocks, 16)
  # dropping the links between blocks moves I only a little
  expect_lt(abs(bb$I_within - I_full), 0.1)
  expect_true(bb$I_lo < I_full && bb$I_hi > I_full)
  expect_gt(bb$I_boot_se, 0)
  expect_identical(bb, block_bootstrap_I(y, L$nb, cx, cy, block_km = 5, B = 199))
})
