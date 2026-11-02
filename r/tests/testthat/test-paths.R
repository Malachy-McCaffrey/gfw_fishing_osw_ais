# r/paths.R: one set of paths per GFW pipeline version

# entries that hold a version's own outputs (planning/gfw_pipeline_v5_plan.qmd, 3.1)
versioned <- c("raw_gfw", "raw_vp", "raw_afe", "pull_info", "processed_gfw",
               "interim_gfw", "fishnet", "grid", "evidence", "review",
               "crosswalk", "permit_groups", "analysis", "rasters", "models",
               "explore", "spatial", "bag", "garfo_match", "port_visits",
               "port_visits_queried", "port_year", "port_stage1")

test_that("make_gfw_paths() puts each version's outputs in its own place", {
  p4 <- make_gfw_paths("v4")
  p5 <- make_gfw_paths("v5")

  expect_equal(p5$pipeline, "v5")
  expect_equal(p5$raw_vp, "data/raw/gfw/v5/gfw_vp_id.csv")
  expect_equal(p5$grid, "data/sf/fishnet/v5/gfw_grid_utm19n.gpkg")
  expect_equal(p5$crosswalk, "references/vessel_crosswalk_v5.csv")
  # no versioned path is shared between two versions
  expect_length(intersect(unlist(p4[versioned]), unlist(p5[versioned])), 0)
  # every other entry is the same for both
  shared <- setdiff(names(p4), c(versioned, "pipeline"))
  expect_equal(p4[shared], p5[shared])
  # hand-made inputs and non-GFW caches are among the shared ones
  expect_true(all(c("decisions", "gear", "removals", "psix", "registries",
                    "roster", "bathy", "infra", "port_communities",
                    "port_anchorages") %in% shared))
  # port visits sit with the identity cache, port tables with the review sheets
  expect_equal(p5$port_visits, "data/raw/vessel_evidence/v5/gfw_port_visits.csv")
  expect_equal(p5$port_stage1, "data/processed/vessel_review/v5/vessel_port_stage1.csv")
})

test_that("make_gfw_paths() rejects a version that is not a folder name", {
  expect_error(make_gfw_paths(""), "pipeline must be")
  expect_error(make_gfw_paths("v5/../v4"), "pipeline must be")
  expect_error(make_gfw_paths(c("v4", "v5")), "pipeline must be")
})

test_that("gfw_paths_with() takes the version from `pipeline`, then single overrides", {
  expect_equal(gfw_paths_with(list()), make_gfw_paths(gfw_pipeline_default))
  expect_equal(gfw_paths_with(list(pipeline = "")), make_gfw_paths(gfw_pipeline_default))
  expect_equal(gfw_paths_with(list(pipeline = "v5"))$analysis, "data/processed/analysis/v5")

  # a single-entry override applies on top of the chosen version
  p <- gfw_paths_with(list(pipeline = "v5", interim_gfw = "scratch/interim", gear = ""))
  expect_equal(p$interim_gfw, "scratch/interim")
  expect_equal(p$raw_vp, "data/raw/gfw/v5/gfw_vp_id.csv")
  expect_equal(p$gear, gfw_paths$gear)   # blank parameter: no override
  expect_equal(p$pipeline, "v5")
})
