# -*- coding: utf-8 -*-
# %% [markdown]
# # monthmeanhrs_distribution_diagnostics
#
# Checks the distribution of `MonthMeanVesselHrs` (skewness, kurtosis,
# normality) in each of the three development-stage grid summary
# feature classes, before deciding how to feed the variable into
# Moran's I / Local Moran's I / Getis-Ord Gi*.
#
# **Note on reading the data**: in your own ArcGIS Pro / cloned-arcpy
# environment, read each feature class straight out of the geodatabase
# with arcpy (see `read_fc_with_arcpy` below) -- this is the simplest,
# most direct route and is what you should actually use. I've also left
# in `read_shp_with_geopandas` as a fallback for reading standalone
# shapefiles outside of ArcGIS Pro's Python environment (e.g. if you
# ever need to check this on a machine without arcpy) -- it requires
# `pip install geopandas` in that environment.

# %%

import os
import numpy as np
import pandas as pd
from scipy import stats
import matplotlib.pyplot as plt

# %% [markdown]
# ## 1. Read the data
# Pick ONE of the two functions below depending on your environment.

# %%
def read_fc_with_arcpy(gdb_path, fc_name, field):
    """Read one field from a geodatabase feature class using arcpy."""
    import arcpy
    fc_path = f"{gdb_path}\\{fc_name}"
    values = [row[0] for row in arcpy.da.SearchCursor(fc_path, [field])]
    return np.array(values, dtype=float)


def read_shp_with_geopandas(shp_path, field):
    """Read one field from a standalone .shp (+ .dbf/.shx/.prj) using geopandas."""
    import geopandas as gpd
    gdf = gpd.read_file(shp_path)
    return gdf[field].astype(float).values


# %%
PROJECT_GDB = os.environ.get("GFW_GDB_PATH", r"C:\\Users\\mmccaffrey17\\ArcGIS\\Projects\\GFW_VesselHotspots_SNE\\GFW_VesselHotspots_SNE.gdb")

STAGE_OUTPUT_FCS = {
    "Stage 1": "gfw_vp1_fv_sub_utm19n_gridSummary",
    "Stage 2": "gfw_vp2_fv_sub_utm19n_gridSummary",
    "Stage 3": "gfw_vp3_fv_sub_utm19n_gridSummary",
}
FIELD_NAME = "MonthMeanVesselHrs"

# %%
# Choose your source: swap this line to read_shp_with_geopandas(...) if
# you're working from standalone shapefiles instead of the geodatabase.
data = {
    stage: read_fc_with_arcpy(PROJECT_GDB, fc, FIELD_NAME)
    for stage, fc in STAGE_OUTPUT_FCS.items()
}
# data = {
#     stage: read_shp_with_geopandas(shp, SHP_FIELD_NAME)
#     for stage, shp in STAGE_SHAPEFILES.items()
# }

# %% [markdown]
# ## 2. Distribution diagnostics
# Skewness, kurtosis, and two normality tests (Shapiro-Wilk and
# D'Agostino K^2) for each stage.

# %%
summary_rows = []
for stage, x in data.items():
    n = len(x)
    n_zero = int((x == 0).sum())
    sh_stat, sh_p = stats.shapiro(x)
    dag_stat, dag_p = stats.normaltest(x)
    summary_rows.append({
        "Stage": stage,
        "n": n,
        "pct_zero": round(100 * n_zero / n, 2),
        "mean": round(np.mean(x), 4),
        "median": round(np.median(x), 4),
        "std": round(np.std(x), 4),
        "skewness": round(stats.skew(x), 3),
        "excess_kurtosis": round(stats.kurtosis(x), 3),
        "shapiro_p": sh_p,
        "dagostino_p": dag_p,
    })

diagnostics_df = pd.DataFrame(summary_rows)
print(diagnostics_df.to_string(index=False))

# %% [markdown]
# ## 3. Check whether a transform reduces skew
# Compares raw, sqrt, and log1p skewness side by side. Neither transform
# will fully normalize a zero-inflated variable (the exact-zero spike
# doesn't move under a monotonic transform), but this shows which
# transform gets furthest and is a reasonable candidate to carry into
# the spatial statistics tools.

# %%
transform_rows = []
for stage, x in data.items():
    transform_rows.append({
        "Stage": stage,
        "raw_skew": round(stats.skew(x), 3),
        "sqrt_skew": round(stats.skew(np.sqrt(x)), 3),
        "log1p_skew": round(stats.skew(np.log1p(x)), 3),
    })
print(pd.DataFrame(transform_rows).to_string(index=False))

# %% [markdown]
# ## 4. Histogram + Q-Q plot per stage

# %%
fig, axes = plt.subplots(2, len(data), figsize=(5 * len(data), 8))
for i, (stage, x) in enumerate(data.items()):
    axes[0, i].hist(x, bins=40, color="#3b6ea5", edgecolor="white")
    axes[0, i].set_title(f"{stage}: {FIELD_NAME}\nskew={stats.skew(x):.2f}")
    axes[0, i].set_xlabel(FIELD_NAME)
    axes[0, i].set_ylabel("Grid cell count")

    stats.probplot(x, dist="norm", plot=axes[1, i])
    axes[1, i].set_title(f"{stage}: Q-Q plot vs Normal")

plt.tight_layout()
plt.savefig("monthmean_distribution_diagnostics.png", dpi=130)
plt.show()
