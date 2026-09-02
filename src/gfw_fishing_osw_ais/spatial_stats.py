# -*- coding: utf-8 -*-
"""Global and local spatial statistics.

Open-source replacement for the ``arcpy.stats`` chain in
``python/scripts/arcpy/gfw_vp_fv_spatial_stats_workflow.py`` and its AFE twin:

=========================================  =========================================
arcpy tool                                 Replacement
=========================================  =========================================
``SpatialAutocorrelation``                 ``esda.Moran``
``HighLowClustering``                      ``esda.G``
``HotSpots`` (Gi*, ``APPLY_FDR``)          ``esda.G_Local`` + Benjamini-Hochberg
``ClustersOutliers`` (``APPLY_FDR``, 499)  ``esda.Moran_Local`` + Benjamini-Hochberg
=========================================  =========================================

Output field names mirror the ArcGIS ones (``Gi_Bin``, ``COType``,
``GiZScore``, ``LMiZScore``) so the pandas comparison code at
``gfw_vp_fv_spatial_stats_workflow.py:427-527`` still applies.

Two things the archived workflow left loose are fixed here:

* **Seeded permutations.** The arcpy run set no seed, so its Local Moran's
  results were not reproducible. Everything here uses ``cfg.RANDOM_SEED``.
* **Explicit Gi\\* self-weight.** Weights come from ``weights.gi_star_weights``,
  which puts the focal cell in its own neighbourhood before row
  standardisation, rather than relying on esda's fallback guess that the
  self-weight equals the row maximum.

Gi\\* significance is analytic, matching ``HotSpots``, which has no permutation
parameter. Local Moran's uses conditional randomisation, matching
``ClustersOutliers``; permutations are raised from the arcpy default of 499 to
``cfg.N_PERMUTATIONS`` (999) since the run is cheap.
"""

from __future__ import annotations

import logging

import esda
import geopandas as gpd
import numpy as np
import pandas as pd
from statsmodels.stats.multitest import multipletests

from . import aggregate
from . import config as cfg
from . import io
from . import weights as wts

log = logging.getLogger(__name__)

__all__ = ["run_all", "run_stage"]

# esda Moran_Local quadrant codes -> the ArcGIS COType labels.
QUADRANT_LABELS = {1: "HH", 2: "LH", 3: "LL", 4: "HL"}

# Confidence levels behind the ArcGIS -3..+3 Gi_Bin scale. Ordered strictest
# first so a cell takes the highest level it qualifies for.
BIN_ALPHAS = ((3, 0.01), (2, 0.05), (1, 0.10))


def run_stage(
    dataset: str,
    stage: int,
    gear_class: str | None = None,
    value: str = "sqrt",
    grid: gpd.GeoDataFrame | None = None,
    w=None,
    w_star=None,
    df: pd.DataFrame | None = None,
) -> tuple[pd.DataFrame, dict]:
    """Run the full statistic set for one dataset/stage/gear class.

    Parameters
    ----------
    value
        ``"sqrt"`` (default, the primary surface) or ``"raw"``. The archived
        workflow ran both and compared them; ``"raw"`` is the sensitivity check.

    Returns
    -------
    ``(cells, globals_)`` where ``cells`` is one row per grid cell carrying the
    ArcGIS-compatible output fields, and ``globals_`` is a dict of the
    whole-surface statistics.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid() if grid is None else grid
    if w is None:
        w = wts.lattice_queen(grid)
    if w_star is None:
        w_star = wts.gi_star_weights(grid)
    wts.validate_weights(w)

    summary = aggregate.summarize_stage(
        dataset, stage, gear_class=gear_class, grid=grid, df=df
    )
    field = spec.sqrt_field if value == "sqrt" else spec.month_mean_field
    if value not in ("sqrt", "raw"):
        raise ValueError(f"value must be 'sqrt' or 'raw', got {value!r}")

    y = summary[field].to_numpy(dtype=float)
    label = f"{dataset} stage {stage} gear={gear_class or 'ALL'} [{value}]"

    cells = summary[["cell_id", spec.month_mean_field, spec.sqrt_field]].copy()
    globals_ = {
        "dataset": dataset,
        "stage": stage,
        "gear_class": gear_class or "ALL",
        "value": value,
        "field": field,
        "n_cells": len(y),
        "n_active": int((y > 0).sum()),
    }

    # A constant surface has no spatial structure to find, and every statistic
    # below would divide by zero. Happens only for an empty gear class.
    if np.ptp(y) == 0:
        log.warning("%s: constant surface, statistics skipped", label)
        cells["GiZScore"] = np.nan
        cells["GiPValue"] = np.nan
        cells["Gi_Bin"] = 0
        cells["LMiIndex"] = np.nan
        cells["LMiZScore"] = np.nan
        cells["LMiPValue"] = np.nan
        cells["COType"] = ""
        globals_.update(
            morans_i=np.nan, morans_z=np.nan, morans_p=np.nan,
            general_g=np.nan, general_g_z=np.nan, general_g_p=np.nan,
            n_hot=0, n_cold=0, n_cluster=0, n_outlier=0,
        )
        return cells, globals_

    # --- Global: Moran's I (SpatialAutocorrelation) ------------------------
    moran = esda.Moran(y, w)
    globals_.update(
        morans_i=float(moran.I),
        morans_z=float(moran.z_norm),
        morans_p=float(moran.p_norm),
    )

    # --- Global: Getis-Ord General G (HighLowClustering) -------------------
    # Undefined if any value is negative; sqrt of a non-negative mean is safe.
    general_g = esda.G(y, w)
    globals_.update(
        general_g=float(general_g.G),
        general_g_z=float(general_g.z_norm),
        general_g_p=float(general_g.p_norm),
    )

    # --- Local: Getis-Ord Gi* (HotSpots) -----------------------------------
    # Analytic p-values, matching HotSpots, which takes no permutation count.
    #
    # transform="B" is load-bearing. Gi*'s variance depends on the weight sum
    # W_i, so row standardisation (esda's default "R") forces W_i = 1 and
    # compresses every z-score: max |z| drops from 10.78 to 3.96 and FDR then
    # finds no significant cells at all. Binary weights are required.
    gi = esda.G_Local(y, w_star, star=None, transform="B", permutations=0)
    gi_z = np.asarray(gi.Zs, dtype=float)
    # esda reports a one-tailed p_norm; ArcGIS GiPValue is two-tailed.
    gi_p = np.clip(np.asarray(gi.p_norm, dtype=float) * 2, 0.0, 1.0)
    cells["GiZScore"] = gi_z
    cells["GiPValue"] = gi_p
    cells["Gi_Bin"] = _fdr_bins(gi_z, gi_p)

    # --- Local: Anselin Local Moran's I (ClustersOutliers) -----------------
    lmi = esda.Moran_Local(
        y, w, permutations=cfg.N_PERMUTATIONS, seed=cfg.RANDOM_SEED
    )
    lmi_p = np.asarray(lmi.p_sim, dtype=float)
    significant = _fdr_reject(lmi_p, cfg.FDR_ALPHA)
    cells["LMiIndex"] = np.asarray(lmi.Is, dtype=float)
    cells["LMiZScore"] = np.asarray(lmi.z_sim, dtype=float)
    cells["LMiPValue"] = lmi_p
    cells["COType"] = np.where(
        significant, pd.Series(lmi.q).map(QUADRANT_LABELS).to_numpy(), ""
    )

    globals_.update(
        n_hot=int((cells["Gi_Bin"] > 0).sum()),
        n_cold=int((cells["Gi_Bin"] < 0).sum()),
        n_cluster=int(cells["COType"].isin(["HH", "LL"]).sum()),
        n_outlier=int(cells["COType"].isin(["HL", "LH"]).sum()),
    )

    log.info(
        "%s: Moran I=%.4f (z=%.1f), Gi* hot=%d cold=%d, LMi cluster=%d outlier=%d",
        label, globals_["morans_i"], globals_["morans_z"],
        globals_["n_hot"], globals_["n_cold"],
        globals_["n_cluster"], globals_["n_outlier"],
    )
    return cells, globals_


def run_all(
    dataset: str, value: str = "sqrt", gear_classes: tuple | None = None
) -> tuple[dict, pd.DataFrame]:
    """Run every stage and gear class for one dataset.

    ``gear_classes`` defaults to the dataset's ``gi_star_gear_classes``, which
    omits POLE_AND_LINE for apparent fishing effort: that class occupies only
    2.4-6.2 percent of grid cells there, so a hotspot surface would be unstable.
    The all-gear surface (``None``) is always included.

    Returns ``({(stage, gear_class): cells_df}, globals_df)``.
    """
    spec = cfg.DATASETS[dataset]
    grid = io.load_grid()
    w = wts.lattice_queen(grid)
    w_star = wts.gi_star_weights(grid)
    wts.validate_weights(w)

    classes = (None,) + tuple(
        gear_classes if gear_classes is not None else spec.gi_star_gear_classes
    )

    cells_by_key: dict = {}
    global_rows = []
    for stage in cfg.STAGE_NUMBERS:
        df = io.load_stage(dataset, stage)
        for gear_class in classes:
            cells, globals_ = run_stage(
                dataset, stage, gear_class=gear_class, value=value,
                grid=grid, w=w, w_star=w_star, df=df,
            )
            cells_by_key[(stage, gear_class)] = cells
            global_rows.append(globals_)

    return cells_by_key, pd.DataFrame(global_rows)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _fdr_reject(p: np.ndarray, alpha: float) -> np.ndarray:
    """Benjamini-Hochberg rejection mask, tolerating NaN p-values.

    ArcGIS's ``APPLY_FDR`` is a BH correction on the local p-values; this is
    the direct equivalent. NaN p-values (from cells the statistic could not be
    computed for) are treated as non-significant rather than propagating.
    """
    finite = np.isfinite(p)
    reject = np.zeros(len(p), dtype=bool)
    if finite.any():
        reject[finite] = multipletests(p[finite], alpha=alpha, method="fdr_bh")[0]
    return reject


def _fdr_bins(z: np.ndarray, p: np.ndarray) -> np.ndarray:
    """ArcGIS-style -3..+3 confidence bins from FDR-corrected p-values.

    A cell takes the sign of its z-score and the highest confidence level whose
    BH-corrected threshold it clears: +/-3 at 99 percent, +/-2 at 95 percent,
    +/-1 at 90 percent, 0 if not significant at any level.
    """
    bins = np.zeros(len(z), dtype=int)
    sign = np.sign(np.nan_to_num(z)).astype(int)
    for level, alpha in BIN_ALPHAS:
        newly = (bins == 0) & _fdr_reject(p, alpha)
        bins = np.where(newly, sign * level, bins)
    return bins
