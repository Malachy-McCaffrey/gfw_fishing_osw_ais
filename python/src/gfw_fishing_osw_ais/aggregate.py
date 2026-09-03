# -*- coding: utf-8 -*-
"""Aggregate GFW point records onto the analysis grid.

Open-source replacement for the arcpy spatial-join + pandas rollup in
``python/scripts/arcpy/gfw_vp_stage_grid_summary.py`` and its AFE twin. The
rollup logic there was already plain pandas; only the join needed replacing,
``arcpy.analysis.SpatialJoin`` becoming ``geopandas.sjoin``.

Output matches the arcpy field names so the downstream comparison code at
``gfw_vp_fv_spatial_stats_workflow.py:427-527`` still applies.

**Semantics worth knowing.** ``MonthMean*`` divides by the number of months in
the *stage*, not the number of months that individual cell was active
(``gfw_vp_stage_grid_summary.py:180-186``). Zero-inflation is therefore
structural: a cell with a single busy month across a 44-month stage gets a
small mean rather than a large one. Every grid cell is present in the output,
zero-filled if it saw no activity.
"""

from __future__ import annotations

import logging

import geopandas as gpd
import numpy as np
import pandas as pd

from . import config as cfg
from . import io

log = logging.getLogger(__name__)

__all__ = ["summarize_stage", "summarize_all"]

# Vessel-count fields. SumVesselCount is MMSI-based and is the one carried into
# the analysis; SumVesselIdCount is the Vessel ID sensitivity column -- see the
# vessel-identity note in config.py.
VESSEL_COUNT_FIELD = "SumVesselCount"
VESSEL_ID_COUNT_FIELD = "SumVesselIdCount"
RECORD_COUNT_FIELD = "TotalRecords"


def summarize_stage(
    dataset: str,
    stage: int,
    gear_class: str | None = None,
    grid: gpd.GeoDataFrame | None = None,
    df: pd.DataFrame | None = None,
) -> pd.DataFrame:
    """Roll one dataset/stage up to per-cell statistics.

    Parameters
    ----------
    dataset
        ``"vp"`` or ``"afe"``.
    stage
        1, 2 or 3.
    gear_class
        Restrict to one of ``cfg.ANALYSIS_GEAR_CLASSES``. ``None`` keeps every
        class, which is the all-gear surface.
    grid, df
        Pre-loaded grid and records, to avoid re-reading in a loop.

    Returns
    -------
    DataFrame with one row per grid cell (all ``cfg.N_GRID_CELLS`` of them,
    zero-filled where there was no activity), indexed positionally and carrying
    ``cell_id`` plus the dataset's sum, count, monthly-mean and sqrt fields.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid() if grid is None else grid
    df = io.load_stage(dataset, stage) if df is None else df

    # The month denominator is a property of the stage, so it is taken before
    # any gear filter. Dividing a gear class by only the months in which that
    # class happened to appear would make sparse classes look busier than they
    # are -- exactly the wrong bias for the pole-and-line comparison.
    n_months = io.month_denominator(dataset, stage, df)

    if gear_class is not None:
        if gear_class not in cfg.ANALYSIS_GEAR_CLASSES:
            raise ValueError(
                f"Unknown gear_class {gear_class!r}; "
                f"expected one of {cfg.ANALYSIS_GEAR_CLASSES}"
            )
        df = df[df["gear_class"] == gear_class].copy()

    summary = _empty_summary(grid, spec)

    if df.empty:
        log.warning(
            "%s stage %d gear=%s: no records, returning all-zero surface",
            dataset, stage, gear_class,
        )
        return summary

    joined = _join_to_grid(df, grid)

    grouped = joined.groupby("cell_id").agg(
        **{
            spec.sum_field: (spec.hours_column, "sum"),
            VESSEL_COUNT_FIELD: (cfg.VESSEL_COUNT_COLUMN, "nunique"),
            VESSEL_ID_COUNT_FIELD: (cfg.VESSEL_COUNT_SENSITIVITY_COLUMN, "nunique"),
            RECORD_COUNT_FIELD: (spec.hours_column, "size"),
        }
    )

    summary = summary.drop(columns=grouped.columns).join(grouped, on="cell_id")
    summary[grouped.columns] = summary[grouped.columns].fillna(0)

    summary[spec.month_mean_field] = summary[spec.sum_field] / n_months
    summary[spec.sqrt_field] = np.sqrt(summary[spec.month_mean_field])

    n_active = int((summary[spec.sum_field] > 0).sum())
    log.info(
        "%s stage %d gear=%s: %d of %d cells active, %.0f hours over %d months",
        dataset, stage, gear_class or "ALL",
        n_active, len(summary), summary[spec.sum_field].sum(), n_months,
    )
    return summary


def summarize_all(
    dataset: str,
    gear_classes: tuple | None = None,
    grid: gpd.GeoDataFrame | None = None,
) -> dict:
    """Summarize every stage and gear class for one dataset.

    ``gear_classes`` defaults to the dataset's ``gi_star_gear_classes`` plus the
    all-gear surface (``None``). Returns ``{(stage, gear_class): DataFrame}``.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid() if grid is None else grid
    classes = (None,) + tuple(
        gear_classes if gear_classes is not None else spec.gi_star_gear_classes
    )

    out = {}
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        for gear_class in classes:
            out[(stage, gear_class)] = summarize_stage(
                dataset, stage, gear_class=gear_class, grid=grid, df=df
            )
    return out


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _join_to_grid(df: pd.DataFrame, grid: gpd.GeoDataFrame) -> pd.DataFrame:
    """Spatial-join records onto grid cells, warning on any that fall outside.

    Replaces ``arcpy.analysis.SpatialJoin(..., JOIN_ONE_TO_MANY, KEEP_ALL,
    CONTAINS)``. Unmatched grid cells are handled by the caller's reindex rather
    than by ``KEEP_ALL``, so this is an inner-style join on the point side.
    """
    pts = io.to_points(df)
    joined = gpd.sjoin(
        pts, grid[["cell_id", "geometry"]], how="left", predicate="within"
    )

    n_unmatched = int(joined["cell_id"].isna().sum())
    if n_unmatched:
        # GFW cell centroids are what the grid was built from, so any miss
        # means the grid and the records have diverged.
        log.warning(
            "%d record(s) fell outside the grid and were dropped", n_unmatched
        )
        joined = joined[joined["cell_id"].notna()]

    return joined


def _empty_summary(grid: gpd.GeoDataFrame, spec: cfg.DatasetSpec) -> pd.DataFrame:
    """All-cells, all-zero frame carrying the grid attributes maps need."""
    summary = grid[["cell_id", "Lon_C", "Lat_C", "Area_km2"]].copy()
    for field in (
        spec.sum_field,
        VESSEL_COUNT_FIELD,
        VESSEL_ID_COUNT_FIELD,
        RECORD_COUNT_FIELD,
        spec.month_mean_field,
        spec.sqrt_field,
    ):
        summary[field] = 0.0
    return summary
