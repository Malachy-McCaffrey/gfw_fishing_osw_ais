# -*- coding: utf-8 -*-
# %% [markdown]
# # gfw_stage_grid_summary
#
# For three development-stage vessel-presence spatial join tables (outputs of
# Spatial Join operations against a common fishnet grid target feature class),
# aggregate each table by TARGET_FID, compute four summary statistics, fill
# unmatched grid cells (null join results) with zero, and join the results
# back onto copies of the fishnet grid to produce three standalone polygon
# feature classes -- one per development stage. These outputs are intended as
# inputs for Moran's I, Local Outlier Analysis, and Getis-Ord Gi* hot spot
# analysis.
#
# **Summary statistics per TARGET_FID, per development stage**
# - `SumFishingHrs`: sum of `Apprent_Fishing_Hours`
# - `MonthMeanFishingHrs`: `SumFishingHrs` / (count of distinct `YearMonth`
#   values present anywhere in that stage's dataset)
# - `SumVesselCount`: count of distinct `Vessel_ID` values
# - `TotalRecords`: count of join records (rows)
#
# Grid cells that received no spatial join match (`Join_Count == 0`, i.e. the
# "null" rows created by a one-to-many/keep-all spatial join) are assigned 0
# for all four statistics rather than being dropped, so every `TARGET_FID` in
# the fishnet is represented in the output.
#
# **Requirements**: arcpy (ArcGIS Pro Python environment or a clone of it).
# pandas/numpy ship with arcgispro-py3 already.
#
# **Configuration**: this notebook reads `GDB_PATH` from the `GFW_GDB_PATH`
# environment variable if it's set, otherwise falls back to the placeholder
# below. This keeps your actual local geodatabase path (which may reveal
# folder structure or a username) out of version control -- see the
# accompanying note on environment variables / `.env` files if you commit
# this repo to GitHub.

# %%
import os
import sys
import logging

import arcpy

import numpy as np
import pandas as pd

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

# %% [markdown]
# ## 1. Configuration
# Edit the values below for your project, or set the `GFW_GDB_PATH`
# environment variable and leave `GDB_PATH` as-is.

# %%
PROJECT_GDB = os.environ.get("GFW_GDB_PATH", r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb") # <-- EDIT or set env var

FISHNET_FC = r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb\\Orsted_sqGrid_utm19n"
FISHNET_ID_FIELD = "OBJECTID"

arcpy.env.workspace = PROJECT_GDB
arcpy.env.overwriteOutput = True

log.info("Using geodatabase: %s", PROJECT_GDB)

# %% [markdown]
# ## 2. Spatial join GFW points to fishnet grid

# %%
# Create function to execute spatial join for all projected point feature classes that will be used for hotspot analysis
def spatial_join_pts_to_polygons(polygon_fc, point_fc, output_fc):

    arcpy.analysis.SpatialJoin(
    target_features=polygon_fc,
    join_features=point_fc,
    out_feature_class=output_fc,
    join_operation="JOIN_ONE_TO_MANY",
    join_type="KEEP_ALL",
    match_option="CONTAINS"
)
    
    print(f"Spatial join complete: {output_fc}")

# List GFW point feature classes for spatial join

point_fcs = [
    r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb\\gfw_afe1_id_sub_utm19n",
    r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb\\gfw_afe2_id_sub_utm19n",
    r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb\\gfw_afe3_id_sub_utm19n"
]

# Iteratively execute spatial join function

for point_fc in point_fcs:
    point_name = os.path.basename(point_fc)
    output_fc = os.path.join(PROJECT_GDB, f"{point_fc}_SJ")

    # call spatial join for each feature class (inside the loop)
    spatial_join_pts_to_polygons(
        polygon_fc=FISHNET_FC,
        point_fc=point_fc,
        output_fc=output_fc
    )

# Spatial Join output feature classes, one per development stage
STAGE_INPUT_FCS = {
    "Stage 1": "gfw_afe1_id_sub_utm19n_SJ",
    "Stage 2": "gfw_afe2_id_sub_utm19n_SJ",
    "Stage 3": "gfw_afe3_id_sub_utm19n_SJ",
}

# Output polygon feature classes to be created in GDB_PATH
STAGE_OUTPUT_FCS = {
    "Stage 1": "gfw_afe1_id_sub_utm19n_summaryGrid",
    "Stage 2": "gfw_afe2_id_sub_utm19n_summaryGrid",
    "Stage 3": "gfw_afe3_id_sub_utm19n_summaryGrid",
}

# Fields pulled from each Spatial Join output table for aggregation
SJ_FIELDS = [
    "TARGET_FID",
    "Join_Count",
    "Vessel_ID",
    "Apparent_Fishing_Hours",
    "YearMonth",
]

# The four summary fields that will be added to each output feature class
SUMMARY_FIELDS = [
    ("SumFishingHrs", "DOUBLE"),
    ("MonthMeanFishingHrs", "DOUBLE"),
    ("SumVesselCount", "LONG"),
    ("TotalRecords", "LONG"),
]

# %% [markdown]
# ## 3. Helper functions

# %%
def spatial_join_fc_to_df(fc_name, fields):
    """
    Read the required fields from a Spatial Join output feature class into
    a pandas DataFrame using an arcpy SearchCursor (safe for mixed
    numeric/text fields and NULLs, unlike FeatureClassToNumPyArray which
    struggles with string-null handling in some ArcGIS Pro versions).
    """
    fc_path = os.path.join(PROJECT_GDB, fc_name)
    rows = []
    with arcpy.da.SearchCursor(fc_path, fields, null_value=None) as cursor:
        for row in cursor:
            rows.append(row)
    df = pd.DataFrame(rows, columns=fields)
    return df


# %%
def get_all_target_fids(fc_name, id_field):
    """
    Return a sorted list of every ID value present in the target fishnet
    grid feature class -- this defines the full set of TARGET_FID values
    that must appear in the final summary, including cells that had zero
    spatial join matches.
    """
    fc_path = os.path.join(PROJECT_GDB, fc_name)
    ids = []
    with arcpy.da.SearchCursor(fc_path, [id_field]) as cursor:
        for row in cursor:
            ids.append(row[0])
    return sorted(set(ids))


# %%
def summarize_stage(df, all_target_fids):
    """
    Aggregate one development stage's Spatial Join table by TARGET_FID.

    - Rows where Join_Count == 0 represent fishnet cells with no matching
      vessel-presence points (the "null" join rows) and are excluded from
      the aggregation math, then explicitly zero-filled afterward so every
      TARGET_FID is represented.
    - MonthMeanFishingHrs uses a single denominator per stage: the count of
      distinct YearMonth values found anywhere in that stage's matched
      records (i.e., the number of months spanned by that development
      stage's monitoring window), not a per-cell month count.
    """
    matched = df[df["Join_Count"] > 0].copy()

    n_months = matched["YearMonth"].nunique()
    if n_months == 0:
        n_months = 1  # guard against divide-by-zero if a stage has no data at all

    grouped = matched.groupby("TARGET_FID").agg(
        SumFishingHrs=("Apparent_Fishing_Hours", "sum"),
        SumVesselCount=("Vessel_ID", "nunique"),
        TotalRecords=("Apparent_Fishing_Hours", "size"),
    ).reset_index()

    grouped["MonthMeanFishingHrs"] = grouped["SumFishingHrs"] / n_months

    full_ids = pd.DataFrame({"TARGET_FID": all_target_fids})
    summary = full_ids.merge(grouped, on="TARGET_FID", how="left")

    fill_cols = ["SumFishingHrs", "MonthMeanFishingHrs", "SumVesselCount", "TotalRecords"]
    summary[fill_cols] = summary[fill_cols].fillna(0)

    # keep counts as integers where appropriate
    summary["SumVesselCount"] = summary["SumVesselCount"].astype(int)
    summary["TotalRecords"] = summary["TotalRecords"].astype(int)

    return summary


# %%
def build_output_fc(summary_df, id_field, out_fc_name):
    """
    Copy the fishnet grid to a new output feature class, add the four
    summary fields, and populate them from summary_df (indexed by
    TARGET_FID / id_field) via an UpdateCursor.
    """
    out_path = os.path.join(PROJECT_GDB, out_fc_name)

    # 1) Copy the fishnet grid geometry/attributes to the new output FC
    arcpy.management.CopyFeatures(FISHNET_FC, out_path)

    # 2) Add the four summary fields
    field_specs = [[name, ftype] for name, ftype in SUMMARY_FIELDS]
    arcpy.management.AddFields(out_path, field_specs)

    # 3) Build a lookup dict: {TARGET_FID: (SumFishingHrs, MonthMeanFishingHrs,
    #    SumVesselCount, TotalRecords)}
    lookup = summary_df.set_index("TARGET_FID")[
        ["SumFishingHrs", "MonthMeanFishingHrs", "SumVesselCount", "TotalRecords"]
    ].to_dict(orient="index")

    update_fields = [id_field] + [name for name, _ in SUMMARY_FIELDS]
    with arcpy.da.UpdateCursor(out_path, update_fields) as cursor:
        for row in cursor:
            fid_value = row[0]
            stats = lookup.get(fid_value)
            if stats is None:
                # Should not normally happen if FISHNET_ID_FIELD truly
                # matches TARGET_FID, but zero-fill defensively.
                row[1:] = [0, 0, 0, 0]
            else:
                row[1] = stats["SumFishingHrs"]
                row[2] = stats["MonthMeanFishingHrs"]
                row[3] = stats["SumVesselCount"]
                row[4] = stats["TotalRecords"]
            cursor.updateRow(row)

    return out_path


# %% [markdown]
# ## 4. Run the pipeline
# Each stage runs in sequence: read the Spatial Join table, aggregate by
# TARGET_FID with zero-fill, then build the joined output feature class.
# `summary_df` is left in scope after the loop reflects the *last* stage
# processed, so you can inspect it below if useful (e.g. `summary_df.head()`
# or `summary_df.describe()`).

# %%
all_target_fids = get_all_target_fids(FISHNET_FC, FISHNET_ID_FIELD)
log.info("Fishnet grid contains %d target cells.", len(all_target_fids))

results = {}  # stage_name -> (summary_df, out_path), kept for inspection

for stage_name, sj_fc in STAGE_INPUT_FCS.items():
    log.info("Processing %s (%s)...", stage_name, sj_fc)

    # Read the Spatial Join output table into a DataFrame
    df = spatial_join_fc_to_df(sj_fc, SJ_FIELDS)

    # Aggregate by TARGET_FID, zero-filling unmatched cells
    summary_df = summarize_stage(df, all_target_fids)

    # Build the output polygon feature class with joined summary stats
    out_fc_name = STAGE_OUTPUT_FCS[stage_name]
    out_path = build_output_fc(summary_df, FISHNET_ID_FIELD, out_fc_name)

    results[stage_name] = (summary_df, out_path)

    log.info(
        "  -> Created %s | cells with matches: %d | zero-filled cells: %d",
        out_path,
        int((summary_df["TotalRecords"] > 0).sum()),
        int((summary_df["TotalRecords"] == 0).sum()),
    )

log.info(
    "Done. Three grid summary feature classes are ready for Spatial "
    "Autocorrelation (Moran's I), Cluster and Outlier Analysis (Anselin "
    "Local Moran's I), and Hot Spot Analysis (Getis-Ord Gi*)."
)

# %% [markdown]
# ## 5. (Optional) Inspect results
# Run this cell to spot-check one stage's summary table before moving on
# to the spatial statistics tools.

# %%

stage_to_check = "Stage 1"

results[stage_to_check][0].describe()