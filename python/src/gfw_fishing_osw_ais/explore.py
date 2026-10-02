# -*- coding: utf-8 -*-
"""Distribution diagnostics and dataset limitations.

Phase 1 of the analysis: understand the response variables before running any
spatial statistic on them. Two questions drive this module.

1. *What shape are the data?* The per-cell monthly means are heavily
   right-skewed and structurally zero-inflated, which is why the spatial
   statistics run on a sqrt transform with the raw field kept as a sensitivity
   check. ``distribution_diagnostics`` quantifies that rather than assuming it.

2. *What can these data not tell us?* ``limitations`` computes the numbers
   behind each documented caveat, so the Quarto write-up states measured values
   rather than adjectives.

The statistical tests are ported from
``python/scripts/arcpy/gfw_vp_monthmeanhrs_distribution_diagnostics.py:75-114``,
which was already pure scipy/matplotlib. Only the input changed: it read
ArcGIS feature classes, this reads the aggregation in ``aggregate.py``.
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd
from scipy import stats

from . import aggregate
from . import config as cfg
from . import io

log = logging.getLogger(__name__)

__all__ = [
    "behavioural_screen",
    "distribution_diagnostics",
    "gear_composition",
    "limitations",
    "transform_comparison",
    "vessel_identity_inflation",
]

# scipy.stats.shapiro is unreliable above this n and warns; the grid is 3,375
# cells so this only bites if the grid grows.
_SHAPIRO_MAX_N = 5000


# ---------------------------------------------------------------------------
# Distribution shape
# ---------------------------------------------------------------------------
def distribution_diagnostics(
    dataset: str, gear_classes: tuple | None = None
) -> pd.DataFrame:
    """Per-cell distribution summary for every stage and gear class.

    Reports n, percent zero, mean, median, sd, skewness, excess kurtosis, and
    two normality tests (Shapiro-Wilk, D'Agostino K^2) on the dataset's
    ``MonthMean*`` field.

    A high ``pct_zero`` is expected and structural, not a data error: the
    monthly mean divides by the whole stage length, so any cell inactive for
    the entire stage is an exact zero.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid()
    classes = (None,) + tuple(
        gear_classes if gear_classes is not None else cfg.ANALYSIS_GEAR_CLASSES
    )

    rows = []
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        for gear_class in classes:
            summary = aggregate.summarize_stage(
                dataset, stage, gear_class=gear_class, grid=grid, df=df
            )
            rows.append(
                _describe(
                    summary[spec.month_mean_field].to_numpy(dtype=float),
                    dataset=dataset,
                    stage=stage,
                    gear_class=gear_class or "ALL",
                )
            )

    return pd.DataFrame(rows)


def transform_comparison(
    dataset: str, gear_classes: tuple | None = None
) -> pd.DataFrame:
    """Compare raw, sqrt and log1p skewness for every stage and gear class.

    Neither transform fully normalises a zero-inflated variable -- the spike at
    exactly zero does not move under a monotonic transform -- but this shows
    which gets furthest. The archived workflow chose sqrt on this basis and
    carried the raw field alongside as a sensitivity check; this module exists
    to confirm that choice still holds for the gear-stratified surfaces.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid()
    classes = (None,) + tuple(
        gear_classes if gear_classes is not None else cfg.ANALYSIS_GEAR_CLASSES
    )

    rows = []
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        for gear_class in classes:
            summary = aggregate.summarize_stage(
                dataset, stage, gear_class=gear_class, grid=grid, df=df
            )
            x = summary[spec.month_mean_field].to_numpy(dtype=float)
            rows.append(
                {
                    "dataset": dataset,
                    "stage": stage,
                    "gear_class": gear_class or "ALL",
                    "raw_skew": _round(stats.skew(x), 3),
                    "sqrt_skew": _round(stats.skew(np.sqrt(x)), 3),
                    "log1p_skew": _round(stats.skew(np.log1p(x)), 3),
                }
            )

    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Charter-vessel behavioural screen
# ---------------------------------------------------------------------------
def behavioural_screen(
    dataset: str = "afe", stage: int = 3, min_hours: float = 20.0
) -> pd.DataFrame:
    """Score every vessel active in ``stage`` on the charter-vessel signature.

    This reproduces, as a function, the investigation that found the eleven
    offshore-wind charter and research vessels the original name-based R
    filter missed (``00b-plan-revisions.qmd``, "Scope added: charter-vessel
    contamination"). Three signals, read together:

    * ``pct_hours_inside_lease`` -- share of this stage's hours worked inside
      an Orsted lease footprint, against ``fleet_pct_inside_lease`` (the
      clean fleet, i.e. vessels not on the removal list).
    * ``prior_hours`` -- hours in the stages before ``stage``. Zero means no
      activity before construction began.
    * ``hours_per_active_day`` -- hours worked per distinct day with any
      record, against the same figure for the clean fleet.

    Runs on ``io.load_raw``, not ``io.load_stage``: the cleaned per-stage CSVs
    already have every removal-list vessel filtered out, so scoring them would
    always come back empty. ``already_removed`` marks rows also present in
    ``references/vessel_removals.csv``, so a result can be read against the
    current list rather than only used to grow it.

    This is a screen, not a verdict -- it ranks candidates for investigation,
    it does not confirm them. It also has a structural blind spot: it detects
    vessels whose behaviour *changed*, so an established fishing vessel that
    took a charter (the Virginia Wave case) will not score high on
    ``prior_hours`` and can escape it for exactly that reason.
    """
    spec = cfg.DATASETS[dataset]
    stage_spec = cfg.STAGES[stage]
    mmsi_col = cfg.VESSEL_COUNT_COLUMN
    hours_col = spec.hours_column
    owf = io.load_owf()
    leases = owf.geometry.union_all()

    raw = io.load_raw(dataset)

    target = raw.loc[raw["Development Stage"] == stage_spec.label].copy()
    target["gear_class"] = io.classify_gear(target["Gear Type"])
    target = target[target["gear_class"] != cfg.EXCLUDED]

    pts = io.to_points(target)
    pts["in_lease"] = pts.geometry.within(leases)

    prior_hours = pd.Series(dtype=float)
    for earlier in cfg.STAGE_NUMBERS:
        if earlier >= stage:
            continue
        prior = raw.loc[raw["Development Stage"] == cfg.STAGES[earlier].label]
        prior_hours = prior_hours.add(
            prior.groupby(mmsi_col)[hours_col].sum(), fill_value=0.0
        )

    clean_pts = io.to_points(io.load_stage(dataset, stage))
    clean_pts["in_lease"] = clean_pts.geometry.within(leases)
    fleet_total = float(clean_pts[hours_col].sum())
    fleet_inside = float(clean_pts.loc[clean_pts["in_lease"], hours_col].sum())
    fleet_pct_inside_lease = round(100 * fleet_inside / fleet_total, 1) if fleet_total else np.nan
    fleet_active_days = clean_pts.groupby(mmsi_col, observed=True)["Time Range"].nunique()
    fleet_hpad = (clean_pts.groupby(mmsi_col, observed=True)[hours_col].sum() / fleet_active_days)
    fleet_hours_per_active_day = round(float(fleet_hpad.median()), 1) if len(fleet_hpad) else np.nan

    removed = set(io.load_removal_list()["MMSI"])
    names = target.drop_duplicates(mmsi_col).set_index(mmsi_col)["Vessel Name"]

    rows = []
    for mmsi, sub in pts.groupby(mmsi_col, observed=True):
        hours = float(sub[hours_col].sum())
        if hours < min_hours:
            continue
        inside = float(sub.loc[sub["in_lease"], hours_col].sum())
        active_days = int(sub["Time Range"].nunique())
        rows.append(
            {
                "dataset": dataset,
                "stage": stage,
                "MMSI": mmsi,
                "Vessel_Name": names.get(mmsi, "?"),
                "hours": round(hours, 1),
                "pct_hours_inside_lease": round(100 * inside / hours, 1),
                "fleet_pct_inside_lease": fleet_pct_inside_lease,
                "prior_hours": round(float(prior_hours.get(mmsi, 0.0)), 1),
                "active_days": active_days,
                "hours_per_active_day": round(hours / active_days, 1) if active_days else np.nan,
                "fleet_hours_per_active_day": fleet_hours_per_active_day,
                "already_removed": mmsi in removed,
            }
        )

    screen = pd.DataFrame(rows)
    if screen.empty:
        return screen
    return screen.sort_values("pct_hours_inside_lease", ascending=False).reset_index(drop=True)


# ---------------------------------------------------------------------------
# Composition and limitations
# ---------------------------------------------------------------------------
def gear_composition(dataset: str) -> pd.DataFrame:
    """Hours, records, vessels and cells occupied per stage and gear class.

    This is the table behind the gear-degradation finding: the share of hours
    carried by ``UNRESOLVED`` rises sharply across stages, which is a change in
    GFW registry coverage rather than in fleet behaviour. Reporting it as a
    first-class result is the reason ``UNRESOLVED`` is carried as its own class
    instead of being dropped.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid()

    rows = []
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        stage_hours = df[spec.hours_column].sum()
        for gear_class in cfg.ANALYSIS_GEAR_CLASSES:
            sub = df[df["gear_class"] == gear_class]
            summary = aggregate.summarize_stage(
                dataset, stage, gear_class=gear_class, grid=grid, df=df
            )
            n_cells = int((summary[spec.sum_field] > 0).sum())
            hours = float(sub[spec.hours_column].sum())
            rows.append(
                {
                    "dataset": dataset,
                    "stage": stage,
                    "gear_class": gear_class,
                    "records": len(sub),
                    "hours": _round(hours, 1),
                    "pct_stage_hours": _round(
                        100 * hours / stage_hours if stage_hours else 0.0, 1
                    ),
                    "vessels_mmsi": sub[cfg.VESSEL_COUNT_COLUMN].nunique(),
                    "cells_occupied": n_cells,
                    "pct_grid_occupied": _round(100 * n_cells / len(grid), 1),
                }
            )

    return pd.DataFrame(rows)


def vessel_identity_inflation(dataset: str) -> pd.DataFrame:
    """Vessel ID vs MMSI counts per stage, and the inflation ratio.

    ``group_by="VESSEL_ID"`` in the GFW pull returns identity *segments*, not
    resolved hulls, so one vessel can appear under several Vessel IDs when its
    self-reported name or call sign varies. The inflation is stage-dependent,
    which would manufacture a spurious trend in vessel counts -- hence MMSI is
    the counting unit. See the note in ``config.py``.
    """
    rows = []
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        n_vid = df[cfg.VESSEL_COUNT_SENSITIVITY_COLUMN].nunique()
        n_mmsi = df[cfg.VESSEL_COUNT_COLUMN].nunique()
        rows.append(
            {
                "dataset": dataset,
                "stage": stage,
                "vessel_id_count": n_vid,
                "mmsi_count": n_mmsi,
                "inflation_ratio": _round(n_vid / n_mmsi if n_mmsi else np.nan, 3),
            }
        )
    return pd.DataFrame(rows)


def limitations(dataset: str) -> pd.DataFrame:
    """Measured values behind each documented dataset limitation.

    Returns one row per limitation with a quantity, so the write-up can state
    numbers instead of adjectives. Every entry corresponds to a caveat in the
    work plan.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid()
    rows = []

    for stage in cfg.STAGE_NUMBERS:
        stage_spec = cfg.STAGES[stage]
        df = io.load_stage(dataset, stage)
        summary = aggregate.summarize_stage(dataset, stage, grid=grid, df=df)

        observed_months = int(df["Year Month"].nunique())
        hours = df[spec.hours_column]

        rows.extend(
            [
                _limitation(
                    dataset, stage, "structural_zero_cells",
                    int((summary[spec.sum_field] == 0).sum()),
                    "Grid cells with no activity all stage. MonthMean divides by "
                    "stage length, so these are exact zeros by construction.",
                ),
                _limitation(
                    dataset, stage, "months_observed_of_nominal",
                    observed_months,
                    f"Months with any record, of {stage_spec.n_months} nominal. "
                    "A month with none is a real zero, not a gap.",
                ),
                _limitation(
                    dataset, stage, "vessels_mmsi",
                    df[cfg.VESSEL_COUNT_COLUMN].nunique(),
                    "Distinct MMSIs. Compare against hours: effort rising faster "
                    "than vessel count indicates AIS coverage growth, the "
                    "dominant confound for a before/after reading.",
                ),
                _limitation(
                    dataset, stage, "total_hours",
                    _round(float(hours.sum()), 1),
                    "Total hours in stage.",
                ),
                _limitation(
                    dataset, stage, "pct_hours_gear_unresolved",
                    _round(
                        100
                        * df.loc[df["gear_class"] == cfg.UNRESOLVED, spec.hours_column].sum()
                        / hours.sum()
                        if hours.sum()
                        else 0.0,
                        1,
                    ),
                    "Share of hours whose gear GFW did not resolve. Rises sharply "
                    "across stages, so gear-stratified comparisons partly track "
                    "registry coverage rather than behaviour.",
                ),
                _limitation(
                    dataset, stage, "pct_records_at_hour_mode",
                    _round(100 * (hours == hours.mode().iloc[0]).mean(), 1),
                    "Share of records at the modal hour value. Vessel presence is "
                    "an integer count of hours with at least one AIS position, so "
                    "it is one-inflated rather than continuous.",
                ),
            ]
        )

    return pd.DataFrame(rows)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _describe(x: np.ndarray, dataset: str, stage: int, gear_class: str) -> dict:
    """Distribution summary for one vector, mirroring the arcpy diagnostics."""
    n = len(x)
    row = {
        "dataset": dataset,
        "stage": stage,
        "gear_class": gear_class,
        "n": n,
        "pct_zero": _round(100 * float((x == 0).sum()) / n if n else np.nan, 2),
        "mean": _round(float(np.mean(x)), 4),
        "median": _round(float(np.median(x)), 4),
        "std": _round(float(np.std(x)), 4),
        "skewness": _round(float(stats.skew(x)), 3),
        "excess_kurtosis": _round(float(stats.kurtosis(x)), 3),
        "shapiro_p": np.nan,
        "dagostino_p": np.nan,
    }

    # Both tests need variation; an all-zero surface has none.
    if n > 2 and np.ptp(x) > 0:
        if n <= _SHAPIRO_MAX_N:
            row["shapiro_p"] = float(stats.shapiro(x).pvalue)
        row["dagostino_p"] = float(stats.normaltest(x).pvalue)
    else:
        log.info(
            "%s stage %d gear=%s: constant surface, normality tests skipped",
            dataset, stage, gear_class,
        )

    return row


def _limitation(dataset: str, stage: int, name: str, value, note: str) -> dict:
    return {
        "dataset": dataset,
        "stage": stage,
        "limitation": name,
        "value": value,
        "note": note,
    }


def _round(value, digits: int):
    """Round, passing NaN and non-finite values through untouched."""
    return value if value is None or not np.isfinite(value) else round(value, digits)
