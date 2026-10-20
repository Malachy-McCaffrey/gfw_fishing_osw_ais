# Helpers shared by the spatial-statistics qmds (07 onward). Source after the
# tidyverse, spdep, r/paths.R, r/gfw_helpers.R and r/analysis_helpers.R:
#   source("r/analysis_helpers.R"); source("r/spatial_helpers.R")
#
# Every function is a pure function of its arguments (the permutation and
# bootstrap ones take an explicit seed), so each one is unit-tested in
# r/tests/testthat/test-spatial_helpers.R.

# General G scale -----------------------------------------------------------
# General G and Gi* need non-negative values: G is a ratio of weighted sums of
# products of the values, which only reads as "share of the total held by
# neighbouring pairs" when every value is >= 0.
#
# VP's y_vst (√density) is already non-negative, so it is used as is. AFE's
# y_vst, log(density + c), is negative wherever density < c, including every
# zero cell. Decision (2026-10-20): General G for AFE uses
#   log(1 + density / c) = y_vst - log(c),
# with the same per-surface c (half the smallest positive density). This is
# y_vst shifted so that a zero cell maps to exactly 0. Moran's I does not
# change when a constant is added, so I and G are computed on matching scales.
#
# `density`: one surface (one dataset × gear × time-step value). Returns NA for
# an all-zero surface, where c, and every statistic, is undefined.
g_scale <- function(density, dataset) {
  stopifnot("dataset must be vp or afe" = length(dataset) == 1 && dataset %in% c("vp", "afe"))
  if (dataset == "vp") return(sqrt(density))
  pos <- density[density > 0]
  if (length(pos) == 0) return(rep(NA_real_, length(density)))
  log1p(density / (min(pos) / 2))
}

# Global statistics for one surface ------------------------------------------
# Plan, Phase 2 step 1: Moran's I by permutation and Getis-Ord General G.
#
# - Moran's I (`lw_W`, row-standardised): do similar values, high or low, sit
#   together? Permutation (`moran.mc`): the values are shuffled across cells
#   `nsim` times with the weights fixed, which is safer than the normal
#   approximation on skewed, zero-heavy surfaces. Reported with the null
#   mean and its 2.5–97.5% band (where I falls with no spatial structure; a
#   reference band, not an interval for I) and a z taken against the
#   permutation null, comparable across surfaces.
# - General G (`lw_B`, binary without self): are *high* values concentrated
#   together? spdep has no permutation version, so its z is analytic. Read
#   with I: a high I and an unremarkable G mean low values drive the
#   clustering.
#
# `y_I`: values for Moran's I; `y_G`: non-negative values for General G
# (defaults to `y_I`). Both in the weights' cell order. `seed` is reset for
# every surface, so a surface's p-value does not depend on what ran before it.
# Returns a one-row tibble; all NA for a surface that is constant or missing.
global_stats <- function(y_I, lw_W, lw_B, y_G = y_I, nsim = 999, seed = 42) {
  stopifnot("values and weights differ in length" =
              length(y_I) == length(lw_W$neighbours) && length(y_G) == length(y_I))
  out <- tibble::tibble(I = NA_real_, I_null_mean = NA_real_, I_null_lo = NA_real_,
                        I_null_hi = NA_real_, I_z = NA_real_, I_p = NA_real_,
                        G = NA_real_, G_expected = NA_real_, G_z = NA_real_, G_p = NA_real_)
  # an all-zero AFE surface has y_vst NA; a constant surface has no variance,
  # and I is 0/0 on it
  if (anyNA(y_I) || stats::var(y_I) == 0) return(out)

  set.seed(seed)
  mi <- spdep::moran.mc(y_I, lw_W, nsim = nsim, alternative = "greater")
  # mi$res holds the nsim permuted statistics followed by the observed one
  null_I <- utils::head(mi$res, -1)
  out$I           <- unname(mi$statistic)
  out$I_null_mean <- mean(null_I)
  out$I_null_lo   <- unname(stats::quantile(null_I, 0.025))
  out$I_null_hi   <- unname(stats::quantile(null_I, 0.975))
  out$I_z         <- (out$I - mean(null_I)) / stats::sd(null_I)
  out$I_p         <- mi$p.value

  stopifnot("General G needs non-negative values (see g_scale())" = all(y_G >= 0))
  gg <- spdep::globalG.test(y_G, lw_B, alternative = "greater")
  # as.numeric(): globalG.test() returns its statistic and p-value as 1 × 1
  # matrices, which would become matrix columns that write_csv() rejects
  out$G          <- as.numeric(gg$estimate[1])   # observed G
  out$G_expected <- as.numeric(gg$estimate[2])   # E[G] with no clustering
  out$G_z        <- as.numeric(gg$statistic)     # standard deviate
  out$G_p        <- as.numeric(gg$p.value)
  out
}

# Correlogram weights ---------------------------------------------------------
# Plan, Phase 2 step 3. The weights for each lag are built once and reused for
# every surface, because building them (especially the wide distance annuli)
# costs far more than computing I on them.

# Row-standardised weights for contiguity orders 1..max_order: order k links
# cells exactly k queen steps apart (`nblag`), not those within k steps.
# zero.policy: at high orders some edge cells have no neighbour at exactly that
# order; they are kept, with an empty row, rather than stopping.
lag_weights <- function(nb, max_order) {
  lags <- spdep::nblag(nb, max_order)
  lapply(lags, \(x) spdep::nb2listw(x, style = "W", zero.policy = TRUE))
}

# Row-standardised weights for distance annuli between consecutive `breaks`
# (km), from cell centroids `coords_km` (an n × 2 matrix in km). Each annulus
# is (lower, upper]: "GT" keeps a pair on a shared break in one band only, and
# with lower = 0 it also drops the cell itself.
band_weights <- function(coords_km, breaks) {
  lapply(seq_len(length(breaks) - 1), function(k) {
    nb <- spdep::dnearneigh(coords_km, breaks[k], breaks[k + 1], bounds = c("GT", "LE"))
    spdep::nb2listw(nb, style = "W", zero.policy = TRUE)
  })
}

# Moran's I of `y` at each lag in `lw_list`, with the analytic randomisation
# test (`moran.test`). The analytic test is used here, not permutation: it is
# the correlogram's *shape* that matters (where I falls to ~0.1), and 999
# permutations at each of 20 lags × 18 surfaces would add time but not
# information. Returns one row per lag, in list order.
correlogram <- function(y, lw_list) {
  purrr::map_dfr(lw_list, function(lw) {
    mt <- spdep::moran.test(y, lw, randomisation = TRUE, zero.policy = TRUE,
                            alternative = "greater")
    tibble::tibble(I = unname(mt$estimate[1]), I_expected = unname(mt$estimate[2]),
                   I_sd = sqrt(unname(mt$estimate[3])),
                   I_z = unname(mt$statistic), I_p = mt$p.value)
  })
}

# Practical range ---------------------------------------------------------------
# Plan, Phase 2 step 3: the distance at which a correlogram first drops below
# `threshold` (0.1). It sets the Phase 3 weight sensitivity and the empirical
# Matérn range rho0 for Phases 6–7.
#
# `dist_km`: each lag's representative distance (band midpoints), increasing;
# `I`: Moran's I at each lag. The crossing is interpolated linearly between
# the last lag above the threshold and the first below it. If the first lag
# is already below, the range is set to that lag's distance (an upper bound).
# If I never drops below, the range is right-censored at the last distance:
# `censored = TRUE` and `range_km` is that distance (a lower bound).
practical_range <- function(dist_km, I, threshold = 0.1) {
  stopifnot("dist_km and I differ in length" = length(dist_km) == length(I),
            "dist_km must increase" = !is.unsorted(dist_km, strictly = TRUE))
  below <- which(I < threshold)
  if (length(below) == 0)
    return(tibble::tibble(range_km = max(dist_km), censored = TRUE))
  k <- below[1]
  if (k == 1) return(tibble::tibble(range_km = dist_km[1], censored = FALSE))
  # straight line between (d[k-1], I[k-1]) and (d[k], I[k]), solved for I = threshold
  frac <- (I[k - 1] - threshold) / (I[k - 1] - I[k])
  tibble::tibble(range_km = dist_km[k - 1] + frac * (dist_km[k] - dist_km[k - 1]),
                 censored = FALSE)
}

# Cell-block bootstrap interval for Moran's I ---------------------------------
# The permutation band says where I would fall with no structure; it is not an
# interval for I itself. This gives one: the grid is cut into square blocks
# of side `block_km`, blocks are resampled with replacement (as many as there
# are), and I is recomputed on each resampled grid. Blocks at least as wide as
# the correlation range keep most of the spatial dependence inside a block,
# which is what makes resampling them valid.
#
# A resampled grid has no geometry linking one block copy to the next, so
# only links *within* a block are kept. That moves I a little (either way:
# block-edge cells lose neighbours, and the remaining ones weigh more) against
# the full grid. The interval is therefore centred on the full-grid I by shifting
# the bootstrap quantiles by (I_full - I_within), where I_within is I on the
# original grid with the same within-block links only (a "basic shift" of
# the percentile interval).
#
# `y`: values in the grid's order; `nb`: the queen nb; `x_km`, `y_km`: cell
# centroids. Returns a one-row tibble with the bootstrap SE and interval.
block_bootstrap_I <- function(y, nb, x_km, y_km, block_km, B = 999, seed = 42,
                              probs = c(0.025, 0.975)) {
  na_out <- tibble::tibble(block_km = block_km, n_blocks = NA_integer_, I_within = NA_real_,
                           I_boot_se = NA_real_, I_lo = NA_real_, I_hi = NA_real_)
  if (anyNA(y) || stats::var(y) == 0) return(na_out)

  # block of each cell, from its centroid
  block <- paste(floor(x_km / block_km), floor(y_km / block_km))
  # directed edge list of the queen graph (each pair appears twice, i->j and
  # j->i), kept only where both cells share a block
  ei <- rep(seq_along(nb), spdep::card(nb))
  ej <- unlist(nb)
  keep <- ej > 0 & block[ei] == block[ej]
  ei <- ei[keep]; ej <- ej[keep]

  # per block: its cells, and its edges as positions within that cell vector,
  # so a copy of the block can be placed anywhere in a resampled grid
  blocks <- split(seq_along(y), block)
  pos_in_block <- integer(length(y))
  for (b in blocks) pos_in_block[b] <- seq_along(b)
  edge_block <- block[ei]
  b_ei <- split(pos_in_block[ei], factor(edge_block, levels = names(blocks)))
  b_ej <- split(pos_in_block[ej], factor(edge_block, levels = names(blocks)))
  b_n  <- lengths(blocks)
  b_ne <- lengths(b_ei)

  # Moran's I with row-standardised within-block weights, for a value vector
  # `v` and directed edges (i, j). Each cell with at least one neighbour has a
  # row summing to 1, so S0 is the count of such cells; cells with none add
  # to n and the denominator only (spdep's zero.policy convention).
  moran_edges <- function(v, i, j) {
    z <- v - mean(v)
    deg <- tabulate(i, nbins = length(v))
    w <- 1 / deg[i]
    (length(v) / sum(deg > 0)) * sum(w * z[i] * z[j]) / sum(z^2)
  }

  I_within <- moran_edges(y, ei, ej)

  set.seed(seed)
  n_blocks <- length(blocks)
  boot <- vapply(seq_len(B), function(r) {
    s <- sample.int(n_blocks, n_blocks, replace = TRUE)
    # start position of each sampled block copy in the resampled vector
    offset <- c(0L, cumsum(b_n[s]))[seq_along(s)]
    v  <- y[unlist(blocks[s], use.names = FALSE)]
    i  <- unlist(b_ei[s], use.names = FALSE) + rep(offset, b_ne[s])
    j  <- unlist(b_ej[s], use.names = FALSE) + rep(offset, b_ne[s])
    # a resample made only of constant blocks has no variance; skip it
    if (stats::var(v) == 0) return(NA_real_)
    moran_edges(v, i, j)
  }, numeric(1))

  q <- stats::quantile(boot, probs, na.rm = TRUE, names = FALSE)
  # full-grid I, with every queen link, for the shift
  lw_full <- spdep::nb2listw(nb, style = "W")
  I_full <- spdep::moran(y, lw_full, length(y), spdep::Szero(lw_full))$I
  tibble::tibble(block_km = block_km, n_blocks = n_blocks, I_within = I_within,
                 I_boot_se = stats::sd(boot, na.rm = TRUE),
                 I_lo = q[1] + (I_full - I_within), I_hi = q[2] + (I_full - I_within))
}
