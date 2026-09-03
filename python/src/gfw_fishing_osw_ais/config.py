# -*- coding: utf-8 -*-
"""Project-wide configuration: paths, stage definitions, gear classes, constants.

Single source of truth for every value the analysis modules share. Nothing here
reads data or has side effects, so it is safe to import from anywhere.

All paths derive from the repository root rather than being hard-coded, so the
workflow runs on any machine without editing -- unlike the archived arcpy
scripts under ``python/scripts/arcpy/``, which embed absolute geodatabase paths.

**No arcpy.** This package deliberately uses only open-source geospatial tools
so the analysis is reproducible without an ArcGIS Pro licence.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
def _find_repo_root(start: Path) -> Path:
    """Walk up from this file until the directory holding pyproject.toml.

    Deliberately not a fixed ``parents[n]`` index. The package has already been
    relocated once -- from ``src/gfw_fishing_osw_ais`` to
    ``python/src/gfw_fishing_osw_ais`` -- which silently changed its depth and
    made every data path resolve one directory too shallow. Anchoring on a
    marker file survives the next move.
    """
    for candidate in (start, *start.parents):
        if (candidate / "pyproject.toml").is_file():
            return candidate
    raise RuntimeError(
        f"Could not locate pyproject.toml above {start}; "
        "REPO_ROOT is undeterminable"
    )


REPO_ROOT = _find_repo_root(Path(__file__).resolve().parent)

DATA_DIR = REPO_ROOT / "data"
EXTERNAL_GFW_DIR = DATA_DIR / "external" / "gfw"
PROCESSED_DIR = DATA_DIR / "processed"

# The cleaned per-stage CSVs the analysis reads. These were written to
# data/interim/gfw by the R pipeline and later moved to data/processed/gfw;
# the R script (Rmd:645-665) still writes to the old location, so a re-pull
# will need either that path updated or the files moved again.
INTERIM_GFW_DIR = PROCESSED_DIR / "gfw"
SHP_AOI_DIR = DATA_DIR / "shp" / "aoi"
SHP_OWF_DIR = DATA_DIR / "shp" / "owf"

REPORTS_DIR = REPO_ROOT / "reports"
FIGURES_DIR = REPORTS_DIR / "figures"
REFERENCES_DIR = REPO_ROOT / "references"

GRID_PATH = SHP_AOI_DIR / "Orsted_sqGrid_utm19n.shp"
AOI_PATH = SHP_AOI_DIR / "Orsted_AOI.shp"

# ---------------------------------------------------------------------------
# Coordinate reference systems
# ---------------------------------------------------------------------------
# GFW returns 0.01-degree cell centroids in WGS 84; all analysis runs in
# UTM 19N so distances and areas are metric.
GEOGRAPHIC_CRS = 4326      # EPSG:4326  WGS 84
ANALYSIS_CRS = 32619       # EPSG:32619 WGS 84 / UTM zone 19N
OWF_SOURCE_CRS = 3857      # EPSG:3857  the OWF shapefiles ship in Web Mercator

# GFW 4Wings "HIGH" spatial resolution. Used to recover lattice indices from
# the grid Lon_C / Lat_C centroid attributes -- see weights.py.
CELL_SIZE_DEG = 0.01

# Expected cell count in Orsted_sqGrid_utm19n.shp; asserted on load.
N_GRID_CELLS = 3375

# ---------------------------------------------------------------------------
# Reproducibility
# ---------------------------------------------------------------------------
# The archived arcpy workflow set no seed, so its Local Moran results were not
# reproducible. Everything here is seeded.
RANDOM_SEED = 42
N_PERMUTATIONS = 999
FDR_ALPHA = 0.05

# ---------------------------------------------------------------------------
# Development stages
# ---------------------------------------------------------------------------
# Windows are inherited from the R data pull, which already wrote a
# "Development Stage" column into every interim CSV:
#   r/scripts/rmd/gfw_vp_afe_dataPull_090126.Rmd:396-411
#
# NOTE: that file carries two contradictory sets of month-count comments. The
# 44 / 43 / 40 set (lines 401/405/409) is correct; the 31 / 42 / 37 set is
# stale. n_months below is authoritative and is verified against the data by
# io.load_stage.


@dataclass(frozen=True)
class StageSpec:
    """One offshore-wind development stage."""

    number: int
    label: str        # matches the "Development Stage" column verbatim
    start: str        # first Year Month, inclusive
    end: str          # last Year Month, inclusive
    n_months: int
    description: str


STAGES = {
    1: StageSpec(
        number=1,
        label="Stage 1",
        start="2016-01-01",
        end="2019-08-01",
        n_months=44,
        description="Pre-monitoring baseline",
    ),
    2: StageSpec(
        number=2,
        label="Stage 2",
        start="2019-09-01",
        end="2023-03-01",
        n_months=43,
        description="Pre-construction monitoring; protected-species surveys began 09/2019",
    ),
    3: StageSpec(
        number=3,
        label="Stage 3",
        start="2023-04-01",
        end="2026-07-01",
        n_months=40,
        description="Construction and operation; seabed prep for SFW began 04/2023",
    ),
}

STAGE_NUMBERS = tuple(STAGES)

# Consecutive stage pairs for the change analysis (transitions.py).
STAGE_TRANSITIONS = ((1, 2), (2, 3))

# Denominator for per-cell monthly means.
#   "nominal"  -- stage length above (44 / 43 / 40). A month with no records
#                 anywhere in the AOI is treated as an observed zero.
#   "observed" -- distinct months present in the data, reproducing the archived
#                 arcpy behaviour (gfw_vp_stage_grid_summary.py:181).
# The two agree everywhere except AFE stage 1 (41 observed of 44 nominal),
# where "observed" gives values 7.3% higher. Moran's I and Gi* are invariant to
# this uniform rescaling; only descriptive cross-stage hour comparisons change.
MONTH_DENOMINATOR = "nominal"

# ---------------------------------------------------------------------------
# Gear classification
# ---------------------------------------------------------------------------
# "Gear Type" is a fixed per-vessel registry attribute -- 0 of 14,903 vessels
# carry more than one label -- so this is a straight lookup, not an inference.
#
# POLE_AND_LINE is kept as its own class rather than folded into MOBILE.
# Commercial pole-and-line is not a Southern New England fishery, and the
# vessel names in this class (MISTE ROSE, FISHIN ADDICTION 17, TUF GUY,
# TRANQUILITY, WATERPROOF, MACKEREL SKY, PREVAIL, BLUE ANGEL) indicate
# recreational and for-hire charter vessels carrying AIS -- consistent with the
# charter and yacht vessels deliberately retained during MarineTraffic
# adjudication at Rmd:481-486.

MOBILE = "MOBILE"
FIXED = "FIXED"
POLE_AND_LINE = "POLE_AND_LINE"
UNRESOLVED = "UNRESOLVED"
EXCLUDED = "EXCLUDED"

GEAR_CLASS_MAP = {
    # Gear is towed, dragged, or drifts with the vessel
    "TRAWLERS": MOBILE,
    "DREDGE_FISHING": MOBILE,
    "OTHER_PURSE_SEINES": MOBILE,
    "TUNA_PURSE_SEINES": MOBILE,
    "PURSE_SEINES": MOBILE,
    "TROLLERS": MOBILE,
    "DRIFTING_LONGLINES": MOBILE,
    # Gear is anchored or deployed and returned to
    "SET_GILLNETS": FIXED,
    "POTS_AND_TRAPS": FIXED,
    "SET_LONGLINES": FIXED,
    "FIXED_GEAR": FIXED,
    # Likely recreational / for-hire -- see note above
    "POLE_AND_LINE": POLE_AND_LINE,
    # Fishing vessel, gear not determined by GFW
    "FISHING": UNRESOLVED,
    "INCONCLUSIVE": UNRESOLVED,
    "NA": UNRESOLVED,
    # Non-fishing. The AFE pull was never filtered to Vessel Type == "FISHING"
    # unlike the VP pull (Rmd:203-254), so these survive into gfw_afe_id_sub.
    "PASSENGER": EXCLUDED,
    "OTHER": EXCLUDED,
    "CARGO": EXCLUDED,
    "SEISMIC_VESSEL": EXCLUDED,
    "CARRIER": EXCLUDED,
    "BUNKER": EXCLUDED,
    "GEAR": EXCLUDED,
}

# Unmapped or missing "Gear Type" values land here rather than raising, so a
# new GFW label cannot silently drop records. io.classify_gear logs any it hits.
GEAR_CLASS_FALLBACK = UNRESOLVED

# Classes carried into the analysis, in display order. EXCLUDED is dropped.
ANALYSIS_GEAR_CLASSES = (MOBILE, FIXED, POLE_AND_LINE, UNRESOLVED)

# ---------------------------------------------------------------------------
# Datasets
# ---------------------------------------------------------------------------
# Output field names mirror the archived arcpy workflow so the pandas
# comparison code at gfw_vp_fv_spatial_stats_workflow.py:427-527 still applies.


@dataclass(frozen=True)
class DatasetSpec:
    """One of the two GFW response variables."""

    key: str
    label: str
    hours_column: str      # column name in the interim CSVs
    stage_file: str        # format template, {stage} -> 1/2/3
    sum_field: str
    month_mean_field: str
    sqrt_field: str
    gi_star_gear_classes: tuple


DATASETS = {
    "vp": DatasetSpec(
        key="vp",
        label="Vessel presence",
        hours_column="Vessel Presence Hours",
        stage_file="gfw_vp{stage}_fv_sub.csv",
        sum_field="SumVesselHrs",
        month_mean_field="MonthMeanVesselHrs",
        sqrt_field="MMVH_sqrt",
        # Pole-and-line occupies 1,030-1,439 of 3,375 cells (30-43%), ample
        # support for a hotspot surface.
        gi_star_gear_classes=(MOBILE, FIXED, POLE_AND_LINE, UNRESOLVED),
    ),
    "afe": DatasetSpec(
        key="afe",
        label="Apparent fishing effort",
        hours_column="Apparent Fishing Hours",
        stage_file="gfw_afe{stage}_id_sub.csv",
        sum_field="SumFishingHrs",
        month_mean_field="MonthMeanFishingHrs",
        sqrt_field="MMFH_sqrt",
        # Pole-and-line occupies only 81-209 of 3,375 cells (2.4-6.2%), i.e.
        # ~97.6% structural zeros in Stage 1. A Gi* surface there would be
        # unstable, so this class is reported descriptively only.
        gi_star_gear_classes=(MOBILE, FIXED, UNRESOLVED),
    ),
}

DATASET_KEYS = tuple(DATASETS)

# Columns present in every data/interim/gfw/*_sub.csv -- 12 of the external
# files' 18 (Rmd:543-545 drops timestamps, IMO, CallSign, transmission dates).
# The dataset-specific hours column sits between "MMSI" and "Development Stage".
INTERIM_COLUMNS = (
    "Lat",
    "Lon",
    "Time Range",
    "Vessel ID",
    "Flag",
    "Vessel Name",
    "Gear Type",
    "Vessel Type",
    "MMSI",
    "Development Stage",
    "Year Month",
)

# ---------------------------------------------------------------------------
# Vessel identity
# ---------------------------------------------------------------------------
# MMSI, not Vessel ID, is the counting unit. In this extract 0 Vessel IDs span
# more than one MMSI while 1,258 MMSIs span more than one Vessel ID (max 5),
# because group_by="VESSEL_ID" returns identity *segments*, not resolved hulls.
# The inflation is stage-dependent (ratio 1.129 / 1.064 / 1.047), so counting
# Vessel IDs would manufacture a spurious decline across exactly the comparison
# this analysis makes. Vessel ID counts are kept as a sensitivity column.
#
# Limitation: MMSI can be reassigned or misreported, so it is not a perfect
# hull identifier either. Resolving hull identity properly needs the GFW
# vessel-identity endpoint, deferred to the thesis.
VESSEL_COUNT_COLUMN = "MMSI"
VESSEL_COUNT_SENSITIVITY_COLUMN = "Vessel ID"

# ---------------------------------------------------------------------------
# Supplementary vessel removals
# ---------------------------------------------------------------------------
# The R pipeline removed 34 named Orsted survey and safety vessels for Stages
# 2-3 (Rmd:494-516). That filter matched on `Vessel Name` and leaked: several
# charter vessels active during Revolution Wind construction were not on the
# list. The removals below are applied on top of the interim CSVs.
#
# **Keyed by MMSI, not name.** Name matching is what let these through in the
# first place, and it is genuinely unsafe here: "TRADITION" alone spans six
# MMSIs across two vessel types, only one of which is a charter.
#
# Identified by a behavioural screen -- appearing in Stage 3 with little or no
# prior history, working 35-60% of their hours inside the lease areas against
# a fleet baseline of 18.9%, in a 5-7 month burst beginning October 2024, the
# month after Revolution Wind's first turbine was installed.
#
# VIRGINIA WAVE is the anchor case: it is a confirmed Orsted charter, having
# grounded off Beavertail State Park while working for Revolution Wind, yet it
# carries 1,029 hours of "apparent fishing effort" in Stage 3.
# The list itself lives in references/vessel_removals.csv -- tracked, unlike
# data/, so the filter ships with the repository and a collaborator can
# reproduce it. Load it with io.load_removal_list(), which validates the schema.
VESSEL_REMOVALS_PATH = REFERENCES_DIR / "vessel_removals.csv"

# Closed vocabularies, enforced on read.
#   stages_2_3 -- chartered working fishing hulls; stage 1 records are genuine
#                 fishing and are retained.
#   all_stages -- not a fishing vessel at all, so there is no baseline to keep.
REMOVAL_SCOPES = ("stages_2_3", "all_stages")

# How the vessel was identified, and how much weight that carries.
#   confirmed -- external evidence (Orsted list, press report, known vessel)
#   probable  -- convergent behavioural evidence
#   possible  -- behavioural signature on small volume
CONFIDENCE_LEVELS = ("confirmed", "probable", "possible")

# Date_Added is validated for format whenever it is non-blank, so the column
# has to be present for that check to run at all. Requiring it here turns a
# missing column into the collected "missing columns" error rather than a
# KeyError raised mid-validation.
REMOVAL_REQUIRED_COLUMNS = (
    "Vessel_Name", "MMSI", "Scope", "Identified_By", "Confidence", "Date_Added",
)

# Stages from which a "stages_2_3" vessel is removed.
RM_CHARTER_STAGES = (2, 3)

# ---------------------------------------------------------------------------
# Offshore wind project layers
# ---------------------------------------------------------------------------
# The three Orsted projects, drawn on every map.
OWF_LAYERS = {
    "SFW": "South Fork Wind",
    "RWF": "Revolution Wind",
    "SRW": "Sunrise Wind",
}

# Present in data/shp/owf/ but deliberately NOT plotted. Vineyard Wind 1 is not
# an Orsted project and lies outside the study AOI, which is the dissolved
# union of the SFW + RWF + SRW 10 km buffers only (gfw_aoi_creation.py:63-68).
# The *_Buffer layers are AOI-construction intermediates, not map features.
OWF_LAYERS_EXCLUDED = ("VW1", "VW1_Buffer", "SRW_Buffer", "SNE_OWFs")
