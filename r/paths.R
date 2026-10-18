# Project paths, relative to the repo root. Every qmd sources this file, so
# moving or renaming a folder is a one-line change here.
#
# A qmd can override any entry through a Quarto parameter of the same name,
# e.g. `quarto render 02_build_grid.qmd -P interim:scratch/interim`, which
# lets a test run write somewhere other than the real data folders.

gfw_paths <- list(
  # GFW 4Wings pulls (01_pull_gfw.qmd)
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

  # vessel classification (03_classify_vessels.qmd)
  evidence      = "data/raw/vessel_evidence",            # GFW identity API cache
  registries    = "data/raw/vessel_evidence/registries", # GARFO permit lists, read only
  review        = "data/processed/vessel_review",        # generated review sheet
  removals      = "references/vessel_removals.csv",
  survey_dates  = "references/orsted_fv_survey_dates_*.csv", # Ørsted survey trips; every match is read
  survey_vessels = "references/orsted_survey_vessels.csv",  # survey-file vessel names -> MMSI
  decisions     = "references/vessel_decisions.csv",
  gear          = "references/vessel_gear.csv",          # gear corrections
  crosswalk     = "references/vessel_crosswalk.csv",     # generated from the two above
  permit_codes  = "references/garfo_permit_codes.csv"
)

# gfw_paths with any non-empty Quarto parameter of the same name applied
gfw_paths_with <- function(params = list()) {
  over <- params[intersect(names(params), names(gfw_paths))]
  over <- over[!vapply(over, \(x) is.null(x) || identical(x, ""), logical(1))]
  utils::modifyList(gfw_paths, over)
}
