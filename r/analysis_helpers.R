# Helpers shared by the analysis qmds (05 onward). Source after the tidyverse,
# r/paths.R and r/gfw_helpers.R:
#   source("r/paths.R"); source("r/gfw_helpers.R"); source("r/analysis_helpers.R")
#
# Everything here is a pure function of its arguments, apart from
# write_provenance(), so each one is unit-tested in
# r/tests/testthat/test-analysis_helpers.R.

# Analysis gear classes ----------------------------------------------------
# The three resolved classes. UNRESOLVED is a structural zero in Primary
# (planning/gfw_analysis_plan.qmd, "Composition of the Primary set"), so the
# analysis tables drop it after 05 checks that it holds no hours.

analysis_gears <- c("MOBILE", "FIXED", "POLE_AND_LINE")

# Seasons ------------------------------------------------------------------
# Apr–Sep and Oct–Mar. Both stage boundaries (2020-10-01, 2023-04-01) fall
# between these seasons, so no stage × season stratum or season-year spans two
# stages (plan, "Time steps").

# `month`: first-of-month Dates. Returns "AprSep" or "OctMar".
season_of <- function(month) {
  m <- as.integer(format(month, "%m"))
  ifelse(m %in% 4:9, "AprSep", "OctMar")
}

# The year a season belongs to. Apr–Sep takes its own calendar year; Oct–Mar
# takes the year it *ends* in, so Oct 2020 – Mar 2021 is 2021 and Jan–Mar 2016
# opens the series as a partial 2016 OctMar.
season_year_of <- function(month) {
  y <- as.integer(format(month, "%Y"))
  m <- as.integer(format(month, "%m"))
  y + (m >= 10L)
}

# Variance-stabilised density ---------------------------------------------
# Plan, "Variance-stabilising transforms": VP (Tweedie p ≈ 1.2) takes √density;
# AFE (p ≈ 1.7) takes log(density + c), with c half the smallest positive
# density *in that surface*. A surface is one dataset × gear × time-step value
# (one map), so call this inside group_by() on those keys.
#
# Returns NA for a surface with no positive value: c is undefined there, and
# every spatial statistic on an all-zero surface is undefined anyway.
vst_density <- function(density, dataset) {
  stopifnot("dataset must be vp or afe" = length(dataset) == 1 && dataset %in% c("vp", "afe"))
  if (dataset == "vp") return(sqrt(density))
  pos <- density[density > 0]
  if (length(pos) == 0) return(rep(NA_real_, length(density)))
  log(density + min(pos) / 2)
}

# Any of the three candidate scales for the transform check (Phase 1, step 3).
# "log" uses the same per-surface c as vst_density(), so "sqrt" and "log"
# reproduce y_vst for VP and AFE respectively.
transform_scale <- function(density, scale) {
  switch(scale,
         raw  = density,
         sqrt = sqrt(density),
         log  = vst_density(density, "afe"),
         stop("scale must be raw, sqrt or log"))
}

# Mean–variance slope -------------------------------------------------------
# Slope of log(variance) on log(mean) across units (cells), using only units
# with a positive mean and variance. On raw values it estimates the Tweedie
# power p (Var ∝ mean^p). With `var` taken on a transformed scale and `mean`
# on the raw scale, a slope near 0 means the transform stabilises the variance.
mv_slope <- function(mean, var) {
  keep <- is.finite(mean) & is.finite(var) & mean > 0 & var > 0
  if (sum(keep) < 3) return(NA_real_)
  unname(coef(stats::lm(log(var[keep]) ~ log(mean[keep])))[2])
}

# Vessel concentration ------------------------------------------------------
# Share of the total held by the k largest values (e.g. vessels' hours).
top_k_share <- function(x, k) {
  x <- sort(x, decreasing = TRUE)
  sum(x[seq_len(min(k, length(x)))]) / sum(x)
}

# Lorenz curve points: cumulative share of units (smallest first) against
# cumulative share of the total, starting at (0, 0).
lorenz_points <- function(x) {
  x <- sort(x)
  tibble::tibble(p_units = c(0, seq_along(x) / length(x)),
                 p_total = c(0, cumsum(x) / sum(x)))
}

# Season-standardised stage rate -------------------------------------------
# Caveat 8: a per-month stage rate is weighted by the stage's calendar mix.
# The standardised rate weights every month-of-year equally: the mean of the
# 12 month-of-year mean rates within the stage.
#
# `hours`, `moy`: one value per month of a single cell × gear × stage, from the
# zero-filled monthly table (so a month with no activity is a 0, not missing).
rate_std_of <- function(hours, moy) {
  stopifnot("rate_std needs all 12 months of the year" = setequal(moy, 1:12))
  mean(tapply(hours, moy, mean))
}

# Lease distance ------------------------------------------------------------
# Signed distance from each point to the nearest lease boundary, in km:
# negative inside a lease, positive outside. `nearest_project` is the lease
# containing the point, or else the nearest one.
#
# `pts`: sf POINT; `leases`: sf with one row per project and a `project`
# column. Both in the same projected CRS with metre units (EPSG:32619 here).
lease_distance <- function(pts, leases) {
  stopifnot("pts and leases must share a CRS" = sf::st_crs(pts) == sf::st_crs(leases))
  # distance to each lease *boundary*: inside a polygon, the distance to the
  # polygon itself is 0, which carries no gradient
  d_edge  <- units::drop_units(sf::st_distance(pts, sf::st_boundary(leases))) / 1000
  # 0/1 matrix, points × leases; numeric so max.col() can pick the column
  inside  <- sf::st_within(pts, leases, sparse = FALSE) * 1L
  stopifnot("a point lies inside more than one lease" = all(rowSums(inside) <= 1))

  in_any  <- rowSums(inside) == 1
  # inside: the containing lease; outside: the nearest edge
  nearest <- ifelse(in_any, max.col(inside), max.col(-d_edge, ties.method = "first"))
  d_near  <- d_edge[cbind(seq_along(nearest), nearest)]

  tibble::tibble(dist_lease_km   = ifelse(in_any, -d_near, d_near),
                 nearest_project = leases$project[nearest])
}

# BAG distance bands. `inside` is any negative signed distance; the outer ring
# (8–15 km) is the BAG reference level, so it is the first factor level.
dist_band_levels <- c("8-15", "inside", "0-2", "2-4", "4-8")

dist_band_of <- function(dist_km) {
  stopifnot("distance beyond the 15 km outer ring" = all(dist_km <= 15))
  band <- cut(dist_km, breaks = c(-Inf, 0, 2, 4, 8, 15),
              labels = c("inside", "0-2", "2-4", "4-8", "8-15"),
              # [lower, upper) bands, with the outer ring closed at 15 km
              right = FALSE, include.lowest = TRUE)
  factor(as.character(band), levels = dist_band_levels)
}

# Lattice queen neighbours --------------------------------------------------
# Queen contiguity from the integer cell indices alone. Cell i's neighbours
# are the up-to-8 cells whose (ix, iy) differ from its own by at most 1. Used
# to check poly2nb() on the cell polygons: if both agree, no floating-point
# sliver in the geometry has added or dropped a link (plan, Phase 0 step 7).
lattice_nb <- function(ix, iy, ids) {
  # "ix iy" -> row position, so each candidate resolves by name lookup
  key <- stats::setNames(seq_along(ix), paste(ix, iy))
  nb <- lapply(seq_along(ix), function(i) {
    # the 3 × 3 block centred on cell i, including i
    cand <- paste(ix[i] + rep(-1:1, 3), iy[i] + rep(-1:1, each = 3))
    j <- unname(key[cand])
    # drop positions outside the grid (NA) and the cell itself; spdep wants
    # sorted integer row positions
    sort(as.integer(j[!is.na(j) & j != i]))
  })
  # spdep marks an island with a single 0L, not an empty vector
  nb <- lapply(nb, \(x) if (length(x) == 0) 0L else x)
  structure(nb, class = "nb", region.id = ids, type = "queen", sym = TRUE)
}

# Model cache ---------------------------------------------------------------
# Plan, "Runtime and caching": the BAG and Phase 5–6 models can take minutes
# to hours, and R renders are not frozen. fit_cached() saves each fit under a
# hash of everything it depends on, and refits only when that hash changes.
# This stands in for `targets` (not a dependency).
#
# `key_inputs`: a named list of everything the fit depends on: the data it
#   is fitted to, the formula, the family, the mesh settings, any options.
#   Formulas are deparsed before hashing, so two identical formulas created
#   in different environments give the same key.
# `fit_fun`: a function of no arguments that fits and returns the model.
# `packages`: whose installed versions join the key, so upgrading a model
#   package (e.g. via renv) refits rather than reusing an old fit.
# `label`: a readable name, stored in the sidecar only (not part of the key).
#
# Writes <dir>/<hash>.rds and a <hash>.rds.json sidecar (label, the key's
# element names, package versions, R version, fit time in seconds).
# Returns the fit. Not a pure function: it reads and writes `dir`.
fit_cache_packages <- c("sdmTMB", "glmmTMB", "TMB", "fmesher", "mgcv")

# The cache file a fit_cached() call would use, without fitting. Lets a
# parallel launcher skip specifications that are already cached. Returns the
# path, with the full hash and package versions as attributes.
fit_cache_path <- function(key_inputs, dir = gfw_paths$models, packages = fit_cache_packages) {
  stopifnot("key_inputs must be a named list" = is.list(key_inputs) && !is.null(names(key_inputs)))
  # formula environments differ between calls; their text does not
  key <- lapply(key_inputs, \(x) if (inherits(x, "formula")) paste(deparse(x), collapse = " ") else x)
  versions <- vapply(packages, function(p) {
    if (requireNamespace(p, quietly = TRUE)) as.character(utils::packageVersion(p)) else NA_character_
  }, character(1))
  hash <- digest::digest(list(key = key, versions = versions, r = R.version.string), algo = "sha256")
  structure(file.path(dir, paste0(substr(hash, 1, 20), ".rds")), hash = hash, versions = versions)
}

fit_cached <- function(key_inputs, fit_fun, dir = gfw_paths$models, label = NULL,
                       packages = fit_cache_packages) {
  stopifnot("fit_fun must be a function" = is.function(fit_fun))
  f <- fit_cache_path(key_inputs, dir, packages)
  hash <- attr(f, "hash")
  versions <- attr(f, "versions")
  f <- as.character(f)
  if (file.exists(f)) return(readRDS(f))

  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  t0 <- Sys.time()
  fit <- fit_fun()
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  saveRDS(fit, f)
  jsonlite::write_json(list(
    label = if (is.null(label)) NA_character_ else label,
    hash = hash, written = format(Sys.time(), tz = "UTC", usetz = TRUE),
    fit_seconds = round(elapsed, 1), key_elements = names(key_inputs),
    packages = as.list(versions), r_version = R.version.string),
    paste0(f, ".json"), auto_unbox = TRUE, pretty = TRUE, digits = NA)
  fit
}

# Provenance sidecar --------------------------------------------------------
# Writes <out_path>.json next to an output (plan, "FAIR implementation"): the
# SHA-256 of every input, the git commit, the renv.lock hash, R version and
# seed, so anyone can tell whether a derived file still matches its inputs.
# Uncommitted edits are not captured by the commit, so render from a clean
# working tree for anything that is released.
#
# `inputs`: paths of every file read to make the output. `extra`: a named list
# of step-specific metadata (e.g. pull_date, row count).
file_sha256 <- function(path) digest::digest(file = path, algo = "sha256")

write_provenance <- function(out_path, inputs, extra = list()) {
  meta <- c(list(
    file = basename(out_path),
    written = format(Sys.time(), tz = "UTC", usetz = TRUE),
    output_sha256 = file_sha256(out_path),
    inputs = lapply(stats::setNames(as.list(inputs), inputs), file_sha256),
    git_commit = tryCatch(gert::git_info()$commit, error = \(e) NA_character_),
    git_clean = tryCatch(nrow(gert::git_status()) == 0, error = \(e) NA),
    renv_lock_sha256 = file_sha256("renv.lock"),
    r_version = R.version.string,
    seed = 42L), extra)
  # auto_unbox: length-1 values as JSON scalars; pretty: readable in a diff
  jsonlite::write_json(meta, paste0(out_path, ".json"),
                       auto_unbox = TRUE, pretty = TRUE, digits = NA)
  invisible(meta)
}
