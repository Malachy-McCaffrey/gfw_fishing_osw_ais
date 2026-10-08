# Project paths, relative to the repo root. Every qmd sources this file, so
# moving or renaming a folder is a one-line change here.
#
# A qmd can override any entry through a Quarto parameter of the same name,
# e.g. `quarto render gfw_fishnet_grid.qmd -P interim:scratch/interim`, which
# lets a test run write somewhere other than the real data folders.

gfw_paths <- list(
  # GFW 4Wings pulls (gfw_vp_afe_datapull.qmd)
  raw_gfw       = "data/raw/gfw",
  raw_vp        = "data/raw/gfw/gfw_vp_id.csv",
  raw_afe       = "data/raw/gfw/gfw_afe_id.csv",
  pull_info     = "data/raw/gfw/pull_info.csv",     # when the raw files were pulled
  processed_gfw = "data/processed/gfw",
  interim_gfw   = "data/interim/gfw",

  # spatial layers
  aoi           = "data/sf/aoi/Orsted_AOI.shp",
  leases        = c("data/sf/owf/SFW.shp", "data/sf/owf/RWF.shp", "data/sf/owf/SRW.shp"),
  fishnet       = "data/sf/fishnet",
  grid          = "data/sf/fishnet/gfw_grid_utm19n.gpkg",

  # vessel classification (gfw_vessel_filtering.qmd)
  evidence      = "data/raw/vessel_evidence",            # GFW identity API cache
  registries    = "data/raw/vessel_evidence/registries", # GARFO permit lists, read only
  review        = "data/processed/vessel_review",        # generated review sheet
  removals      = "references/vessel_removals.csv",
  decisions     = "references/vessel_decisions.csv",
  crosswalk     = "references/vessel_crosswalk.csv",     # generated from the two above
  permit_codes  = "references/garfo_permit_codes.csv"
)

# gfw_paths with any non-empty Quarto parameter of the same name applied
gfw_paths_with <- function(params = list()) {
  over <- params[intersect(names(params), names(gfw_paths))]
  over <- over[!vapply(over, \(x) is.null(x) || identical(x, ""), logical(1))]
  utils::modifyList(gfw_paths, over)
}
