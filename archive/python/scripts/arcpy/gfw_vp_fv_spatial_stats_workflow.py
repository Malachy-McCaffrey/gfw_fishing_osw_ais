# -*- coding: utf-8 -*-
# %% [markdown]
# # gfw_spatial_stats_workflow
#
# Full spatial-statistics workflow for the three development-stage grid
# summary feature classes produced by `gfw_stage_grid_summary.py`. Runs, in
# order, for each stage:
#
# 1. Add a sqrt-transformed `MonthMeanVesselHrs` field (see distribution
#    diagnostics -- the raw field is heavily right-skewed/zero-inflated).
# 2. **Incremental Spatial Autocorrelation** -- finds a genuine peak (a
#    distance where the z-score curve actually turns over: rises, then
#    falls) to use as a Fixed Distance Band. Z-scores can keep climbing
#    across an entire tested range even as Moran's I itself declines, so
#    the largest z-score in the table is NOT automatically a real peak --
#    see `find_isa_peak()` below. If no genuine peak is found within the
#    tested range, that stage skips the FIXED_DISTANCE_BAND comparison and
#    defaults to CONTIGUITY_EDGES_CORNERS, with a warning logged telling
#    you to widen the distance range and re-run.
# 3. **Global Moran's I**, run twice for comparison: once with
#    `CONTIGUITY_EDGES_CORNERS`, once with `FIXED_DISTANCE_BAND` at the
#    peak distance from step 2. The stronger (higher z-score, significant)
#    result decides which conceptualization feeds the rest of the workflow.
# 4. **Generate Spatial Weights Matrix** (.swm) using the winning
#    conceptualization -- built once, reused by every tool below so all
#    local/global statistics operate on an identical neighbor structure.
# 5. **High/Low Clustering (Getis-Ord General G)** -- global precondition
#    check, the global counterpart to Gi*.
# 6. **Cluster and Outlier Analysis (Anselin Local Moran's I)** and
#    **Hot Spot Analysis (Getis-Ord Gi*)**, both with FDR correction, each
#    run on BOTH the sqrt-transformed field (primary analysis) and the raw
#    field (sensitivity check) -- using the SAME weights matrix for both,
#    so the only thing that varies between the two runs is the transform.
#
# Step 8 below (a separate, arcpy-free pandas section) then answers the
# three follow-up questions that motivated running both versions:
# - Does the raw-vs-transformed choice actually change which cells are
#   flagged as hot/cold spots?
# - How many cells fall into each Local Moran's I category (HH/LL/HL/LH),
#   and does that shift between raw and transformed?
# - Do the same cells show up as both a Gi* hot/cold spot AND a Local
#   Moran's spatial outlier -- i.e. where do the two local statistics
#   agree or disagree?
#
# It's kept as a separate step deliberately: Steps 1-7 are pure
# geoprocessing (each stage's tools depend on that stage's own prior
# outputs), so they stay one per-stage arcpy loop. The pandas comparisons
# only need the *finished* attribute tables and don't affect what gets
# built, so they run once, afterward, over all three stages together --
# no reason to interleave DataFrame work into the geoprocessing loop.
#
# **On "ArcPy and geopandas"**: the actual spatial-statistics tools (weights
# matrices, Moran's I, Local Moran's I, Gi*, Incremental Spatial
# Autocorrelation) only exist in arcpy's Spatial Statistics toolbox --
# geopandas has no equivalent built in (that would require adding `esda` /
# `libpysal`, a separate ecosystem, out of scope here). So this workflow
# runs entirely on arcpy, with pandas used for the Step 8 comparisons
# (it ships with arcgispro-py3, no extra install needed). geopandas shows
# up only in the very last, optional cell, for an independent read/plot of
# the final Gi* output outside of ArcGIS Pro's own rendering.
#
# **Requirements**: arcpy (ArcGIS Pro Python env or a clone of it).
# geopandas is optional, only needed for the last cell
# (`pip install geopandas` into your clone if you want it).

# %%
import os
import sys
import logging

try:
    import arcpy
except ImportError:
    print(
        "ERROR: Could not import arcpy. Select your ArcGIS Pro / cloned "
        "arcpy environment as the kernel for this notebook.",
        file=sys.stderr,
    )
    raise

import pandas as pd  # ships with arcgispro-py3

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

# %% [markdown]
# ## 1. Configuration

# %%
PROJECT_GDB = os.environ.get("GFW_GDB_PATH", r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb")  # <-- EDIT or set env var

# The three grid summary feature classes produced by the earlier pipeline
STAGE_FCS = {
    "Stage 1": "gfw_vp1_fv_sub_utm19n_summaryGrid",
    "Stage 2": "gfw_vp2_fv_sub_utm19n_summaryGrid",
    "Stage 3": "gfw_vp3_fv_sub_utm19n_summaryGrid",
}

UNIQUE_ID_FIELD = "OBJECTID"          # <-- EDIT if different
RAW_FIELD = "MonthMeanVesselHrs"      # <-- EDIT if your field name differs
SQRT_FIELD = "MMVH_sqrt"              # new field this script creates

# Output naming
OUTPUT_DIR = os.environ.get("GFW_OUTPUT_DIR", r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\fixedDistComparisonOutputs")  # <-- EDIT: .swm goes here
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Incremental Spatial Autocorrelation settings
# ISA needs a wide enough range for the z-score-by-distance curve to
# actually turn over (rise then fall) -- if every distance band comes back
# significant with a still-rising z-score, the range wasn't wide enough
# and ISA (via find_isa_peak, below) will skip the fixed-distance comparison
# for that stage rather than use a meaningless edge-of-range value.
# Leaving Beginning_Distance/Distance_Increment as "" lets ISA choose them
# automatically from the data's average nearest-neighbor distance -- if
# that auto-chosen range turns out too narrow (as it did for Stage 1: 10
# bands from ~845 m to ~8,406 m, still climbing at the far end), re-run
# with explicit wider values here, e.g. ISA_BEGINNING_DISTANCE = 1000 and
# ISA_DISTANCE_INCREMENT = 3000 to sweep out to ~30 km.
ISA_NUM_DISTANCE_BANDS = 30        # <-- EDIT if you want a finer/coarser sweep
ISA_BEGINNING_DISTANCE = "1000"        # <-- EDIT: "" = auto; or set a distance in meters
ISA_DISTANCE_INCREMENT = "1000"        # <-- EDIT: "" = auto; or set a distance in meters

arcpy.env.workspace = PROJECT_GDB
arcpy.env.overwriteOutput = True

log.info("Using geodatabase: %s", PROJECT_GDB)
log.info("Using output folder for .swm/.pdf/.dbf files: %s", OUTPUT_DIR)

# %% [markdown]
# ## 2. Helper functions -- geoprocessing

# %%
def add_sqrt_field(fc_path, raw_field, sqrt_field):
    """Add a sqrt-transformed copy of raw_field to fc_path, named sqrt_field."""
    existing = [f.name for f in arcpy.ListFields(fc_path)]
    if sqrt_field not in existing:
        arcpy.management.AddField(fc_path, sqrt_field, "DOUBLE")

    with arcpy.da.UpdateCursor(fc_path, [raw_field, sqrt_field]) as cursor:
        for row in cursor:
            raw_val = row[0] if row[0] is not None else 0.0
            row[1] = raw_val ** 0.5
            cursor.updateRow(row)


def _find_field(field_names, *keywords):
    """Return the first field name containing all given keywords (case-insensitive)."""
    for name in field_names:
        upper = name.upper()
        if all(k.upper() in upper for k in keywords):
            return name
    return None


def run_incremental_spatial_autocorrelation(
    fc_path, field, num_bands, out_table, out_report,
    beginning_distance="", distance_increment="",
):
    """
    Run Incremental Spatial Autocorrelation. Returns isa_df with standardized
    columns [Distance, ZScore, PValue] for every distance band tested.
    Peak selection is handled separately by find_isa_peak() below -- keeping
    them apart means the full curve is always available for inspection
    (Step 5), regardless of whether a peak was found.
    """
    arcpy.stats.IncrementalSpatialAutocorrelation(
        fc_path, field, str(num_bands),
        str(beginning_distance) if beginning_distance != "" else "",
        str(distance_increment) if distance_increment != "" else "",
        "EUCLIDEAN", "ROW_STANDARDIZATION",
        out_table, out_report,
    )

    field_names = [f.name for f in arcpy.ListFields(out_table)]
    dist_field = _find_field(field_names, "DIST")
    z_field = _find_field(field_names, "Z", "SCORE") or _find_field(field_names, "Z_S")
    p_field = _find_field(field_names, "P", "VAL")

    if not (dist_field and z_field and p_field):
        raise RuntimeError(
            f"Could not identify DISTANCE/Z_SCORE/P_VALUE fields in {out_table}. "
            f"Fields found: {field_names}"
        )

    with arcpy.da.SearchCursor(out_table, [dist_field, z_field, p_field]) as cursor:
        rows = list(cursor)
    return pd.DataFrame(rows, columns=["Distance", "ZScore", "PValue"])


def find_isa_peak(isa_df):
    """
    Identify a genuine peak in the z-score-by-distance curve: a distance
    band where the z-score rises then falls (a true local maximum), per
    Incremental Spatial Autocorrelation methodology -- NOT simply the
    largest z-score in the table. Moran's I z-scores climb as more distant
    neighbor pairs get folded in even as clustering intensity (Moran's I
    itself) is declining, so the largest z-score in a table is very often
    just the edge of whatever range happened to be tested, not a meaningful
    "optimal scale."

    Returns a dict: {"found": bool, "distance": float or None,
    "z_score": float or None, "p_value": float or None, "note": str}.
    "found" is False when the curve is still rising at the last tested
    band -- the caller should widen the tested distance range rather than
    use that edge value as a Fixed Distance Band.
    """
    z = isa_df["ZScore"].values
    d = isa_df["Distance"].values
    p = isa_df["PValue"].values
    n = len(z)

    sig = p < 0.05

    interior_peaks = [
        i for i in range(1, n - 1)
        if sig[i] and z[i] > z[i - 1] and z[i] > z[i + 1]
    ]
    if interior_peaks:
        i = max(interior_peaks, key=lambda idx: z[idx])
        return {
            "found": True, "distance": float(d[i]), "z_score": float(z[i]),
            "p_value": float(p[i]), "note": "interior_peak",
        }

    # Still climbing at the far end of the tested range -- NOT a valid peak.
    if z[-1] >= z[-2]:
        return {
            "found": False, "distance": None, "z_score": None, "p_value": None,
            "note": (
                f"z-score still increasing at the largest distance tested "
                f"({d[-1]:.1f} m) -- the true peak lies beyond this range. "
                f"Widen it (increase Beginning_Distance / Distance_Increment "
                f"/ number of distance bands) and re-run ISA."
            ),
        }

    # Already declining from the very first band tested -- usable, but the
    # true peak may lie below the smallest distance tested.
    return {
        "found": True, "distance": float(d[0]), "z_score": float(z[0]),
        "p_value": float(p[0]), "note": (
            f"z-score already declining from the first distance band tested "
            f"({d[0]:.1f} m) -- true peak may lie below this range."
        ),
    }


def compare_conceptualizations(fc_path, field, fixed_distance):
    """
    Run Global Moran's I under CONTIGUITY_EDGES_CORNERS and FIXED_DISTANCE_BAND
    (at fixed_distance), and return a dict comparing both, plus the winner
    ("CONTIGUITY_EDGES_CORNERS" or "FIXED_DISTANCE_BAND") based on whichever
    has the higher z-score.
    """
    results = {}

    contiguity_result = arcpy.stats.SpatialAutocorrelation(
        fc_path, field, "NO_REPORT", "CONTIGUITY_EDGES_CORNERS",
        "EUCLIDEAN_DISTANCE", "ROW", "#",
    )
    results["CONTIGUITY_EDGES_CORNERS"] = {
        "morans_i": float(contiguity_result.getOutput(0)),
        "z_score": float(contiguity_result.getOutput(1)),
        "p_value": float(contiguity_result.getOutput(2)),
    }

    fixed_distance_result = arcpy.stats.SpatialAutocorrelation(
        fc_path, field, "NO_REPORT", "FIXED_DISTANCE_BAND",
        "EUCLIDEAN_DISTANCE", "ROW", str(fixed_distance),
    )
    results["FIXED_DISTANCE_BAND"] = {
        "morans_i": float(fixed_distance_result.getOutput(0)),
        "z_score": float(fixed_distance_result.getOutput(1)),
        "p_value": float(fixed_distance_result.getOutput(2)),
    }

    winner = max(results, key=lambda k: results[k]["z_score"])
    return results, winner


# %% [markdown]
# ## 3. Run the workflow, one stage at a time
# For each stage, Local Moran's I and Gi* each run TWICE -- once on the
# sqrt-transformed field (primary analysis) and once on the raw field
# (sensitivity check) -- both using the identical spatial weights matrix,
# so Step 8 can isolate the effect of the transform alone.

# %%
results_by_stage = {}

for stage_name, fc_name in STAGE_FCS.items():
    log.info("=" * 70)
    log.info("Processing %s (%s)", stage_name, fc_name)
    fc_path = os.path.join(PROJECT_GDB, fc_name)

    # --- Step 1: sqrt-transformed field -----------------------------------
    add_sqrt_field(fc_path, RAW_FIELD, SQRT_FIELD)
    log.info("  Added/updated %s field.", SQRT_FIELD)

    # --- Step 2: Incremental Spatial Autocorrelation -----------------------
    isa_table = os.path.join(OUTPUT_DIR, f"{fc_name}_ISA.dbf")
    isa_report = os.path.join(OUTPUT_DIR, f"{fc_name}_ISA_report.pdf")
    isa_df = run_incremental_spatial_autocorrelation(
        fc_path, SQRT_FIELD, ISA_NUM_DISTANCE_BANDS, isa_table, isa_report
    )
    peak = find_isa_peak(isa_df)

    # --- Step 3: compare CONTIGUITY_EDGES_CORNERS vs FIXED_DISTANCE_BAND ---
    # Only meaningful if ISA actually found a peak -- if the z-score curve
    # is still climbing at the edge of the tested range, any "peak" distance
    # would just be an artifact of the range tested, not a real spatial
    # scale, so FIXED_DISTANCE_BAND is skipped for this stage rather than
    # built on a distance that doesn't mean anything yet.
    if peak["found"]:
        log.info(
            "  ISA peak: %.2f m (z=%.3f, p=%.4f) -- %s",
            peak["distance"], peak["z_score"], peak["p_value"], peak["note"],
        )
        peak_distance = peak["distance"]
        comparison, winner = compare_conceptualizations(fc_path, SQRT_FIELD, peak_distance)
        for concept, stats_ in comparison.items():
            log.info(
                "  %-24s Moran's I=%.4f  z=%.3f  p=%.4f",
                concept, stats_["morans_i"], stats_["z_score"], stats_["p_value"],
            )
        log.info("  -> Winning conceptualization: %s", winner)
    else:
        log.warning("  ISA: no valid peak found -- %s", peak["note"])
        log.warning(
            "  Skipping FIXED_DISTANCE_BAND comparison for this stage; "
            "defaulting to CONTIGUITY_EDGES_CORNERS. Re-run ISA with a wider "
            "distance range and re-process this stage once a peak is found."
        )
        peak_distance = None
        contiguity_only = arcpy.stats.SpatialAutocorrelation(
            fc_path, SQRT_FIELD, "NO_REPORT", "CONTIGUITY_EDGES_CORNERS",
            "EUCLIDEAN_DISTANCE", "ROW", "#",
        )
        comparison = {
            "CONTIGUITY_EDGES_CORNERS": {
                "morans_i": float(contiguity_only.getOutput(0)),
                "z_score": float(contiguity_only.getOutput(1)),
                "p_value": float(contiguity_only.getOutput(2)),
            }
        }
        winner = "CONTIGUITY_EDGES_CORNERS"

    # --- Step 4: build the final spatial weights matrix (.swm) ------------
    swm_path = os.path.join(OUTPUT_DIR, f"{fc_name}_{winner}.swm")
    if winner == "CONTIGUITY_EDGES_CORNERS":
        arcpy.stats.GenerateSpatialWeightsMatrix(
            fc_path, UNIQUE_ID_FIELD, swm_path, "CONTIGUITY_EDGES_CORNERS",
            "#", "#", "#", "#", "ROW_STANDARDIZATION",
        )
    else:
        arcpy.stats.GenerateSpatialWeightsMatrix(
            fc_path, UNIQUE_ID_FIELD, swm_path, "FIXED_DISTANCE_BAND",
            "EUCLIDEAN", "#", str(peak_distance), "#", "ROW_STANDARDIZATION",
        )
    log.info("  Built spatial weights matrix: %s", swm_path)

    # --- Step 5: High/Low Clustering (Getis-Ord General G) -- global check
    ghg_result = arcpy.stats.HighLowClustering(
        fc_path, SQRT_FIELD, "false", "GET_SPATIAL_WEIGHTS_FROM_FILE",
        "EUCLIDEAN_DISTANCE", "NONE", "#", swm_path,
    )
    general_g = {
        "observed_g": float(ghg_result.getOutput(0)),
        "z_score": float(ghg_result.getOutput(1)),
        "p_value": float(ghg_result.getOutput(2)),
    }
    log.info(
        "  General G: G=%.6f  z=%.3f  p=%.4f",
        general_g["observed_g"], general_g["z_score"], general_g["p_value"],
    )

    # --- Step 6/7: Local Moran's I and Gi*, sqrt (primary) + raw (check) --
    local_moran_fc = os.path.join(PROJECT_GDB, f"{fc_name}_LocalMoran")
    arcpy.stats.ClustersOutliers(
        fc_path, SQRT_FIELD, local_moran_fc, "GET_SPATIAL_WEIGHTS_FROM_FILE",
        "EUCLIDEAN_DISTANCE", "NONE", "#", swm_path, "APPLY_FDR", 499,
    )
    log.info("  Created Local Moran's I output (sqrt): %s", local_moran_fc)

    local_moran_fc_raw = os.path.join(PROJECT_GDB, f"{fc_name}_LocalMoran_raw")
    arcpy.stats.ClustersOutliers(
        fc_path, RAW_FIELD, local_moran_fc_raw, "GET_SPATIAL_WEIGHTS_FROM_FILE",
        "EUCLIDEAN_DISTANCE", "NONE", "#", swm_path, "APPLY_FDR", 499,
    )
    log.info("  Created Local Moran's I output (raw, sensitivity check): %s", local_moran_fc_raw)

    hotspot_fc = os.path.join(PROJECT_GDB, f"{fc_name}_HotSpots")
    arcpy.stats.HotSpots(
        fc_path, SQRT_FIELD, hotspot_fc, "GET_SPATIAL_WEIGHTS_FROM_FILE",
        "EUCLIDEAN_DISTANCE", "NONE", "#", "#", swm_path, "APPLY_FDR",
    )
    log.info("  Created Hot Spot Analysis output (sqrt): %s", hotspot_fc)

    hotspot_fc_raw = os.path.join(PROJECT_GDB, f"{fc_name}_HotSpots_raw")
    arcpy.stats.HotSpots(
        fc_path, RAW_FIELD, hotspot_fc_raw, "GET_SPATIAL_WEIGHTS_FROM_FILE",
        "EUCLIDEAN_DISTANCE", "NONE", "#", "#", swm_path, "APPLY_FDR",
    )
    log.info("  Created Hot Spot Analysis output (raw, sensitivity check): %s", hotspot_fc_raw)

    results_by_stage[stage_name] = {
        "isa_df": isa_df,
        "isa_peak": peak,
        "peak_distance": peak_distance,
        "comparison": comparison,
        "winner": winner,
        "swm_path": swm_path,
        "general_g": general_g,
        "local_moran_fc": local_moran_fc,
        "local_moran_fc_raw": local_moran_fc_raw,
        "hotspot_fc": hotspot_fc,
        "hotspot_fc_raw": hotspot_fc_raw,
    }

log.info("=" * 70)
log.info("Geoprocessing complete for all stages.")

# %% [markdown]
# ## 4. Global-statistics summary table

# %%
summary_rows = []
for stage, r in results_by_stage.items():
    fdb = r["comparison"].get("FIXED_DISTANCE_BAND")
    summary_rows.append({
        "Stage": stage,
        "ISA peak found": r["isa_peak"]["found"],
        "Peak distance": round(r["peak_distance"], 1) if r["peak_distance"] is not None else None,
        "Contiguity z": round(r["comparison"]["CONTIGUITY_EDGES_CORNERS"]["z_score"], 3),
        "Fixed-distance z": round(fdb["z_score"], 3) if fdb is not None else None,
        "Winner": r["winner"],
        "General G z": round(r["general_g"]["z_score"], 3),
        "General G p": round(r["general_g"]["p_value"], 4),
    })

print(pd.DataFrame(summary_rows).to_string(index=False))
print(
    "\nNote: rows with 'ISA peak found' = False used CONTIGUITY_EDGES_CORNERS "
    "by default -- re-run ISA for those stages with a wider distance range "
    "and re-process to get a real FIXED_DISTANCE_BAND comparison."
)

# %% [markdown]
# ## 5. ISA distance-vs-z-score curves, all stages together
# Concatenates each stage's full Incremental Spatial Autocorrelation sweep
# (not just the selected peak) so the three curves can be compared side by
# side -- useful for judging whether the stages cluster at similar spatial
# scales or genuinely different ones.

# %%
isa_all = pd.concat(
    [df.assign(Stage=stage) for stage, r in results_by_stage.items() for df in [r["isa_df"]]],
    ignore_index=True,
)
print(isa_all.pivot(index="Distance", columns="Stage", values="ZScore").to_string())

# %% [markdown]
# ## 6. Local Moran's I classification tallies (sqrt vs raw)
# How many cells fall into each HH/LL/HL/LH category (blank = not
# significant), and whether that changes between the transformed and raw
# fields.

# %%
def read_fc_fields_as_df(fc_path, id_field, fields):
    """Read id_field + given fields from a feature class/table into a DataFrame."""
    all_fields = [id_field] + list(fields)
    with arcpy.da.SearchCursor(fc_path, all_fields) as cursor:
        rows = list(cursor)
    return pd.DataFrame(rows, columns=all_fields)


for stage, r in results_by_stage.items():
    sqrt_types = read_fc_fields_as_df(r["local_moran_fc"], UNIQUE_ID_FIELD, ["COType"])
    raw_types = read_fc_fields_as_df(r["local_moran_fc_raw"], UNIQUE_ID_FIELD, ["COType"])

    tally = pd.DataFrame({
        "sqrt (primary)": sqrt_types["COType"].value_counts(dropna=False),
        "raw (sensitivity)": raw_types["COType"].value_counts(dropna=False),
    }).fillna(0).astype(int)

    print(f"\n{stage} -- Local Moran's I COType counts (blank = not significant):")
    print(tally.to_string())

# %% [markdown]
# ## 7. Gi* hot/cold spot agreement: sqrt vs raw
# For each stage: what fraction of cells get the SAME Gi_Bin classification
# whether you feed in the raw or the sqrt-transformed variable, and where
# specifically do they disagree. A high agreement rate means the hot spot
# pattern is robust to the transform choice; a low one means the transform
# is doing real work and the choice should be reported explicitly.

# %%
for stage, r in results_by_stage.items():
    sqrt_gi = read_fc_fields_as_df(r["hotspot_fc"], UNIQUE_ID_FIELD, ["Gi_Bin"])
    raw_gi = read_fc_fields_as_df(r["hotspot_fc_raw"], UNIQUE_ID_FIELD, ["Gi_Bin"])

    merged = sqrt_gi.merge(raw_gi, on=UNIQUE_ID_FIELD, suffixes=("_sqrt", "_raw"))
    agreement_pct = (merged["Gi_Bin_sqrt"] == merged["Gi_Bin_raw"]).mean() * 100

    print(f"\n{stage} -- Gi_Bin agreement between sqrt and raw: {agreement_pct:.1f}%")
    print(pd.crosstab(merged["Gi_Bin_sqrt"], merged["Gi_Bin_raw"],
                       rownames=["sqrt Gi_Bin"], colnames=["raw Gi_Bin"]).to_string())

# %% [markdown]
# ## 8. Overlap between Gi* hot/cold spots and Local Moran's I outliers
# (sqrt/primary results only.) These two local statistics answer different
# questions -- Gi* flags clusters of similarly high/low values, Local
# Moran's I additionally flags spatial outliers (a high cell surrounded by
# low ones, or vice versa). This crosstab shows where a cell was flagged by
# both, either, or neither -- e.g. cells that are both a Gi* hot spot AND a
# Local Moran's HL/LH outlier are worth a closer look, since that combination
# is unusual (a strong local cluster that's also flagged as anomalous
# relative to its immediate neighbors).

# %%
for stage, r in results_by_stage.items():
    gi = read_fc_fields_as_df(r["hotspot_fc"], UNIQUE_ID_FIELD, ["Gi_Bin"])
    co = read_fc_fields_as_df(r["local_moran_fc"], UNIQUE_ID_FIELD, ["COType"])

    merged = gi.merge(co, on=UNIQUE_ID_FIELD)
    print(f"\n{stage} -- Gi* Gi_Bin vs Local Moran's I COType (sqrt/primary):")
    print(pd.crosstab(merged["Gi_Bin"], merged["COType"]).to_string())

# %% [markdown]
# ## 9. (Optional) Independent visual QA with geopandas
# geopandas doesn't compute any of the statistics above -- it's just used
# here to read arcpy's Gi* output and produce a quick independent plot,
# outside of ArcGIS Pro's own rendering, as a sanity check.
# Requires `pip install geopandas` in your cloned environment.

# %%
# import geopandas as gpd
# import matplotlib.pyplot as plt
#
# stage_to_check = "Stage 1"
# hotspot_fc = results_by_stage[stage_to_check]["hotspot_fc"]
#
# gdf = gpd.read_file(GDB_PATH, layer=os.path.basename(hotspot_fc))
# gi_field = [c for c in gdf.columns if "GiZScore" in c or c.upper().startswith("GI")][0]
#
# fig, ax = plt.subplots(figsize=(8, 8))
# gdf.plot(column=gi_field, cmap="RdBu_r", legend=True, ax=ax)
# ax.set_title(f"{stage_to_check}: Getis-Ord Gi* z-scores")
# plt.show()
