# -*- coding: utf-8 -*-
"""Stage-to-stage change in hotspot structure.

The poster asks what *changed* across the three development stages, not what
each stage looked like in isolation. Three independent Gi* maps make a reader
hold one in working memory while scanning the next and infer the difference;
this module does that differencing explicitly.

Outputs, per consecutive stage pair and per gear class:

* ``change_classes`` -- a per-cell label (gained hot, stable hot, lost hot,
  and so on), which is what the hero map is coloured by.
* ``change_summary`` -- cell counts and area in km2 for each of those labels.
* ``transition_matrix`` -- the full 7x7 Gi_Bin crosstab for the record, and a
  condensed 3x3 hot / not-significant / cold version for display.
* ``cotype_transitions`` -- the same for Local Moran's cluster and outlier
  types.
* ``stage_rates`` -- hours and per-vessel rates normalised by stage length, so
  the AIS-coverage confound stays visible rather than being absorbed into an
  apparent activity increase.

There is no statistical test of the difference between two Gi* surfaces here.
Each surface is FDR-corrected within its own stage, and the transition tables
describe how those classifications moved. Read them as description, not as a
significance test of change.
"""

from __future__ import annotations

import logging

import geopandas as gpd
import numpy as np
import pandas as pd

from . import aggregate
from . import config as cfg
from . import io

log = logging.getLogger(__name__)

__all__ = [
    "lease_share",
    "change_classes",
    "change_summary",
    "cotype_transitions",
    "hot_status",
    "stage_rates",
    "transition_matrix",
]

# Condensed Gi_Bin status. The -3..+3 scale carries confidence level; for
# change detection only the direction matters.
HOT, COLD, NS = "hot", "cold", "ns"

# Per-cell change labels, in the order they should appear in a legend.
CHANGE_ORDER = (
    "stable hot",
    "gained hot",
    "lost hot",
    "hot to cold",
    "cold to hot",
    "stable cold",
    "gained cold",
    "lost cold",
    "no change",
)

# Colours for the change map. Reds for hot-side, blues for cold-side, muted
# grey for cells that never reached significance in either stage.
# Keyed to the same warm ramp as the ASLO 2026 poster's Gi* confidence
# classes, so the two posters read as one body of work: the strongest change
# takes the 99% red, the weakest the 90% orange. "No change" is the poster's
# near-white, which sits quietly over the ocean basemap.
CHANGE_COLORS = {
    "stable hot": "#d62f27",
    "gained hot": "#ed7551",
    "lost hot": "#fab984",
    "hot to cold": "#7b3294",
    "cold to hot": "#c2a5cf",
    "stable cold": "#2f6fb0",
    "gained cold": "#7fa9d4",
    "lost cold": "#c5d9ec",
    "no change": "#f7f7f2",
}


def hot_status(gi_bin: pd.Series) -> pd.Series:
    """Collapse the -3..+3 ``Gi_Bin`` scale to hot / cold / not-significant."""
    return pd.Series(
        np.where(gi_bin > 0, HOT, np.where(gi_bin < 0, COLD, NS)),
        index=gi_bin.index,
        name="status",
    )


def change_classes(cells_from: pd.DataFrame, cells_to: pd.DataFrame) -> pd.DataFrame:
    """Label each cell by how its hotspot status changed between two stages.

    Labels are mutually exclusive, so the counts sum to the grid size. Direct
    reversals (``hot to cold``, ``cold to hot``) are kept separate rather than
    folded into gained/lost, since a reversal is a substantively different
    event from a cell simply dropping out of significance.
    """
    merged = cells_from[["cell_id", "Gi_Bin"]].merge(
        cells_to[["cell_id", "Gi_Bin"]], on="cell_id", suffixes=("_from", "_to")
    )
    if len(merged) != len(cells_from):
        raise ValueError(
            f"cell_id mismatch: {len(cells_from)} and {len(cells_to)} rows "
            f"joined to {len(merged)}"
        )

    a = hot_status(merged["Gi_Bin_from"])
    b = hot_status(merged["Gi_Bin_to"])

    conditions = [
        (a == HOT) & (b == HOT),
        (a == NS) & (b == HOT),
        (a == HOT) & (b == NS),
        (a == HOT) & (b == COLD),
        (a == COLD) & (b == HOT),
        (a == COLD) & (b == COLD),
        (a == NS) & (b == COLD),
        (a == COLD) & (b == NS),
    ]
    merged["change"] = np.select(conditions, CHANGE_ORDER[:8], default="no change")
    merged["status_from"] = a
    merged["status_to"] = b
    return merged


def change_summary(
    cells_from: pd.DataFrame,
    cells_to: pd.DataFrame,
    grid: gpd.GeoDataFrame,
) -> pd.DataFrame:
    """Cell counts and area in km2 for each change label.

    Area comes from the grid's ``Area_km2``, which varies slightly by latitude
    (mean 0.933 km2), so an area total is not simply the cell count times a
    constant.
    """
    changes = change_classes(cells_from, cells_to)
    merged = changes.merge(grid[["cell_id", "Area_km2"]], on="cell_id")

    out = (
        merged.groupby("change")
        .agg(n_cells=("cell_id", "size"), area_km2=("Area_km2", "sum"))
        .reindex(CHANGE_ORDER)
        .fillna(0)
        .astype({"n_cells": int})
    )
    out["area_km2"] = out["area_km2"].round(1)
    out["pct_grid"] = (100 * out["n_cells"] / len(grid)).round(1)
    return out.reset_index()


def transition_matrix(
    cells_from: pd.DataFrame, cells_to: pd.DataFrame, condensed: bool = True
) -> pd.DataFrame:
    """Crosstab of hotspot classification between two stages.

    ``condensed=True`` gives the 3x3 hot / ns / cold table that fits a slide or
    a report; ``False`` gives the full 7x7 ``Gi_Bin`` crosstab, which retains
    the confidence levels and is the version to keep for the record.
    """
    merged = cells_from[["cell_id", "Gi_Bin"]].merge(
        cells_to[["cell_id", "Gi_Bin"]], on="cell_id", suffixes=("_from", "_to")
    )

    if condensed:
        order = [HOT, NS, COLD]
        rows = hot_status(merged["Gi_Bin_from"])
        cols = hot_status(merged["Gi_Bin_to"])
    else:
        order = list(range(-3, 4))
        rows = merged["Gi_Bin_from"]
        cols = merged["Gi_Bin_to"]

    return (
        pd.crosstab(rows, cols)
        .reindex(index=order, columns=order)
        .fillna(0)
        .astype(int)
        .rename_axis(index="from", columns="to")
    )


def cotype_transitions(
    cells_from: pd.DataFrame, cells_to: pd.DataFrame
) -> pd.DataFrame:
    """Crosstab of Local Moran's ``COType`` between two stages.

    Blank means not significant. Note that for sparse gear classes the ``LL``
    category is dominated by the structural zero field rather than by
    meaningful low-activity clusters, so read LL transitions with care -- Gi*
    is the more trustworthy statistic on those surfaces.
    """
    merged = cells_from[["cell_id", "COType"]].merge(
        cells_to[["cell_id", "COType"]], on="cell_id", suffixes=("_from", "_to")
    )
    order = ["HH", "HL", "LH", "LL", ""]
    return (
        pd.crosstab(merged["COType_from"], merged["COType_to"])
        .reindex(index=order, columns=order)
        .fillna(0)
        .astype(int)
        .rename_axis(index="from", columns="to")
    )


def stage_rates(dataset: str) -> pd.DataFrame:
    """Hours and per-vessel rates by stage and gear class, length-normalised.

    Absolute hours are not comparable across stages on their own: the stages
    differ in length (44 / 43 / 40 months) and, more importantly, AIS coverage
    grows over the study period. Reporting hours per month alongside hours per
    vessel per month keeps that confound visible -- if hours per month rises
    while hours per vessel per month is flat, the increase is fleet coverage
    rather than intensified activity.
    """
    spec = cfg.DATASETS[dataset]
    rows = []
    for stage in cfg.STAGE_NUMBERS:
        stage_spec = cfg.STAGES[stage]
        df = io.load_stage(dataset, stage)
        n_months = io.month_denominator(dataset, stage, df)

        for gear_class in (None,) + cfg.ANALYSIS_GEAR_CLASSES:
            sub = df if gear_class is None else df[df["gear_class"] == gear_class]
            hours = float(sub[spec.hours_column].sum())
            n_vessels = int(sub[cfg.VESSEL_COUNT_COLUMN].nunique())
            rows.append(
                {
                    "dataset": dataset,
                    "stage": stage,
                    "stage_label": stage_spec.label,
                    "gear_class": gear_class or "ALL",
                    "months": n_months,
                    "hours": round(hours, 1),
                    "vessels_mmsi": n_vessels,
                    "hours_per_month": round(hours / n_months, 2),
                    "hours_per_vessel_month": round(
                        hours / n_months / n_vessels if n_vessels else np.nan, 4
                    ),
                }
            )
    return pd.DataFrame(rows)


def lease_share(dataset: str) -> pd.DataFrame:
    """Activity inside the wind-lease polygons versus elsewhere in the AOI.

    The hotspot maps show where activity concentrates; this answers the blunter
    question of whether it happens inside the lease footprints at all. Both are
    normalised by stage length so the three stages are comparable.

    Read the absolute and share columns together. A falling ``pct_in_lease``
    with a flat ``in_lease_hours_per_month`` means the fishery grew *around*
    the leases rather than withdrawing from them -- a different claim from an
    absolute decline, and the one these data actually support.
    """
    spec = cfg.DATASETS[dataset]
    owf = io.load_owf()
    leases = owf.geometry.union_all()

    rows = []
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        pts = io.to_points(df)
        pts["in_lease"] = pts.geometry.within(leases)
        n_months = io.month_denominator(dataset, stage, df)

        for gear_class in (None,) + cfg.ANALYSIS_GEAR_CLASSES:
            sub = pts if gear_class is None else pts[pts["gear_class"] == gear_class]
            total = float(sub[spec.hours_column].sum())
            inside = float(sub.loc[sub["in_lease"], spec.hours_column].sum())
            rows.append(
                {
                    "dataset": dataset,
                    "stage": stage,
                    "stage_label": cfg.STAGES[stage].label,
                    "gear_class": gear_class or "ALL",
                    "in_lease_hours_per_month": round(inside / n_months, 1),
                    "outside_hours_per_month": round((total - inside) / n_months, 1),
                    "pct_in_lease": round(100 * inside / total, 1) if total else np.nan,
                }
            )
    return pd.DataFrame(rows)


def run_transitions(dataset: str, cells_by_key: dict, grid: gpd.GeoDataFrame) -> dict:
    """Build every transition product for one dataset.

    ``cells_by_key`` is the output of ``spatial_stats.run_all``. Returns a dict
    keyed by ``(from_stage, to_stage, gear_class)``.
    """
    out = {}
    gear_classes = sorted(
        {gear for (_, gear) in cells_by_key}, key=lambda g: (g is not None, g)
    )

    for from_stage, to_stage in cfg.STAGE_TRANSITIONS:
        for gear_class in gear_classes:
            key_from = (from_stage, gear_class)
            key_to = (to_stage, gear_class)
            if key_from not in cells_by_key or key_to not in cells_by_key:
                continue

            a, b = cells_by_key[key_from], cells_by_key[key_to]
            out[(from_stage, to_stage, gear_class)] = {
                "classes": change_classes(a, b),
                "summary": change_summary(a, b, grid),
                "matrix_condensed": transition_matrix(a, b, condensed=True),
                "matrix_full": transition_matrix(a, b, condensed=False),
                "cotype": cotype_transitions(a, b),
            }
            log.info(
                "%s stage %d->%d gear=%s: transitions computed",
                dataset, from_stage, to_stage, gear_class or "ALL",
            )
    return out
