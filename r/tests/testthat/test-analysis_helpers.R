# Tests for r/analysis_helpers.R (Phase 0 onward)

test_that("season_of() splits Apr–Sep from Oct–Mar", {
  m <- as.Date(sprintf("2020-%02d-01", 1:12))
  expect_equal(season_of(m), rep(c("OctMar", "AprSep", "OctMar"), c(3, 6, 3)))
})

test_that("season_year_of() labels Oct–Mar by the year it ends in", {
  m <- as.Date(c("2016-01-01", "2016-04-01", "2016-09-01", "2020-10-01",
                 "2021-03-01", "2026-08-01"))
  expect_equal(season_year_of(m), c(2016L, 2016L, 2016L, 2021L, 2021L, 2026L))
})

test_that("the analysis window holds 22 season-years, none spanning two stages", {
  months <- seq(analysis_start, analysis_end, by = "month")
  sy <- tibble(month = months, stage = stage_of(months),
               season = season_of(months), season_year = season_year_of(months))
  per_sy <- distinct(sy, season, season_year, stage)
  expect_equal(nrow(distinct(per_sy, season, season_year)), 22)
  # one stage per season-year: no stratum straddles a stage boundary
  expect_equal(nrow(per_sy), 22)
})

test_that("vst_density() is √ for VP and log(x + c) for AFE", {
  d <- c(0, 0.04, 1)
  expect_equal(vst_density(d, "vp"), sqrt(d))
  # c is half the smallest positive density in the surface
  expect_equal(vst_density(d, "afe"), log(d + 0.02))
  expect_true(all(is.na(vst_density(c(0, 0), "afe"))))
  expect_error(vst_density(d, "VP"), "vp or afe")
})

test_that("rate_std_of() weights every month-of-year equally", {
  # Jan appears twice with 0 h, every other month once with 6 h: the raw
  # mean counts Jan twice (66 / 13), the standardised mean once (66 / 12)
  moy   <- c(1, 1, 2:12)
  hours <- c(0, 0, rep(6, 11))
  expect_equal(rate_std_of(hours, moy), 66 / 12)
  expect_equal(mean(hours), 66 / 13)
  expect_error(rate_std_of(1:11, 1:11), "all 12 months")
})

test_that("lease_distance() is negative inside and picks the nearest lease", {
  sq <- function(x0, y0, s) sf::st_polygon(list(cbind(x0 + c(0, s, s, 0, 0), y0 + c(0, 0, s, s, 0))))
  leases <- sf::st_sf(project = c("A", "B"),
                      geometry = sf::st_sfc(sq(0, 0, 4000), sq(10000, 0, 4000), crs = 32619))
  pts <- sf::st_sf(geometry = sf::st_sfc(
    sf::st_point(c(1000, 2000)),   # inside A, 1 km from its west edge
    sf::st_point(c(6000, 2000)),   # 2 km east of A, 4 km west of B
    sf::st_point(c(9000, 2000)),   # 1 km west of B
    crs = 32619))
  out <- lease_distance(pts, leases)
  expect_equal(out$dist_lease_km, c(-1, 2, 1))
  expect_equal(out$nearest_project, c("A", "A", "B"))
})

test_that("dist_band_of() bins [lower, upper) with 8-15 as the reference", {
  d <- c(-0.5, 0, 1.99, 2, 7.9, 8, 15)
  band <- dist_band_of(d)
  expect_equal(as.character(band), c("inside", "0-2", "0-2", "2-4", "4-8", "8-15", "8-15"))
  expect_equal(levels(band)[1], "8-15")
  expect_error(dist_band_of(15.1), "15 km")
})

test_that("lattice_nb() gives queen neighbours on a 3 × 3 block with a hole", {
  # 3 × 3 block missing its centre: corners have 2 neighbours, edges 4
  cells <- expand_grid(ix = 0:2, iy = 0:2) |> filter(!(ix == 1 & iy == 1))
  nb <- lattice_nb(cells$ix, cells$iy, paste(cells$ix, cells$iy))
  expect_s3_class(nb, "nb")
  card <- lengths(nb)
  edge <- (cells$ix == 1) | (cells$iy == 1)
  # edge midpoints: two corners plus the two diagonal edge midpoints
  expect_equal(card[edge], rep(4L, 4))
  # corners: the two edge midpoints beside them (the diagonal is the hole)
  expect_equal(card[!edge], rep(2L, 4))
  # symmetric: j in nb[[i]] implies i in nb[[j]]
  expect_true(spdep::is.symmetric.nb(nb, verbose = FALSE, force = TRUE))
})

test_that("lattice_nb() matches poly2nb() on unit squares", {
  cells <- expand_grid(ix = 0:3, iy = 0:2)
  polys <- sf::st_sfc(purrr::map2(cells$ix, cells$iy, \(x, y)
    sf::st_polygon(list(cbind(x + c(0, 1, 1, 0, 0), y + c(0, 0, 1, 1, 0))))))
  expect_true(isTRUE(all.equal(
    spdep::poly2nb(sf::st_sf(geometry = polys), queen = TRUE, snap = 0),
    lattice_nb(cells$ix, cells$iy, seq_len(nrow(cells))),
    check.attributes = FALSE)))
})

test_that("transform_scale() reproduces y_vst and rejects unknown scales", {
  d <- c(0, 0.04, 1)
  expect_equal(transform_scale(d, "raw"), d)
  expect_equal(transform_scale(d, "sqrt"), vst_density(d, "vp"))
  expect_equal(transform_scale(d, "log"), vst_density(d, "afe"))
  expect_error(transform_scale(d, "log1p"), "raw, sqrt or log")
})

test_that("mv_slope() recovers the power of a known mean–variance law", {
  m <- c(0.5, 1, 2, 4, 8)
  expect_equal(mv_slope(m, 3 * m^1.7), 1.7)
  # zero means and variances are dropped, not logged
  expect_equal(mv_slope(c(0, m), c(0, 3 * m^1.7)), 1.7)
  expect_true(is.na(mv_slope(c(1, 2), c(1, 4))))
})

test_that("top_k_share() and lorenz_points() describe concentration", {
  x <- c(50, 30, 10, 5, 5)
  expect_equal(top_k_share(x, 1), 0.5)
  expect_equal(top_k_share(x, 2), 0.8)
  expect_equal(top_k_share(x, 10), 1)
  lz <- lorenz_points(x)
  expect_equal(nrow(lz), 6)
  expect_equal(lz$p_total[c(1, 6)], c(0, 1))
  expect_equal(lz$p_total[2], 0.05)
})

test_that("fit_cached() fits once, reuses the cache, and refits when the key changes", {
  dir <- file.path(tempdir(), "fit_cache_test")
  unlink(dir, recursive = TRUE)
  calls <- 0
  fit <- function() { calls <<- calls + 1; list(value = 42) }
  d <- data.frame(y = 1:3)
  # a formula built in another environment hashes the same
  key <- function(f) list(data = d, formula = f, family = "nbinom2")
  f1 <- local(y ~ x)
  f2 <- local({ a <- 1; y ~ x })

  expect_equal(fit_cached(key(f1), fit, dir = dir, packages = "stats")$value, 42)
  expect_equal(fit_cached(key(f2), fit, dir = dir, packages = "stats")$value, 42)
  expect_equal(calls, 1)
  # one fit file and its JSON sidecar, which names the key's elements
  rds <- list.files(dir, pattern = "\\.rds$")
  expect_length(rds, 1)
  meta <- jsonlite::read_json(file.path(dir, paste0(rds, ".json")))
  expect_equal(unlist(meta$key_elements), c("data", "formula", "family"))

  # new data, or a different package set (e.g. an upgrade), refits
  fit_cached(list(data = data.frame(y = 1:4), formula = f1, family = "nbinom2"), fit,
             dir = dir, packages = "stats")
  expect_equal(calls, 2)
  fit_cached(key(f1), fit, dir = dir, packages = c("stats", "utils"))
  expect_equal(calls, 3)
  expect_error(fit_cached(list(1), fit, dir = dir), "named list")
})
