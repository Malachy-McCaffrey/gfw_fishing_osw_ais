# -*- coding: utf-8 -*-
"""Loaders for every input the analysis reads.

One place where files are opened, CRSs are reconciled, and structural
assumptions are asserted. Every loader validates what it returns, so a silently
wrong input fails here rather than surfacing as a puzzling hotspot map later.

Inputs are all committed to the repository:

* ``data/shp/aoi/Orsted_sqGrid_utm19n.shp``  -- 3,375 analysis cells, EPSG:32619
* ``data/shp/aoi/Orsted_AOI.shp``            -- study-area boundary, EPSG:4326
* ``data/shp/owf/{SFW,RWF,SRW}.shp``         -- wind projects, EPSG:3857
* ``data/interim/gfw/gfw_{vp,afe}{1,2,3}_*_sub.csv`` -- cleaned GFW records

**No arcpy.** Vector I/O goes through geopandas/pyogrio.

Note on the module name: ``io`` shadows the standard-library module only if this
directory is placed on ``sys.path`` directly. Imported normally as
``gfw_fishing_osw_ais.io`` it is harmless, but do not run this file as a script.
"""

from __future__ import annotations

import logging

import geopandas as gpd
import pandas as pd

from . import config as cfg

log = logging.getLogger(__name__)

__all__ = [
    "classify_gear",
    "load_aoi",
    "load_grid",
    "load_owf",
    "load_stage",
    "month_denominator",
    "to_points",
]


# ---------------------------------------------------------------------------
# Grid and boundary layers
# ---------------------------------------------------------------------------
def load_grid() -> gpd.GeoDataFrame:
    """Load the analysis grid, adding a stable zero-based ``cell_id``.

    ``cell_id`` is the positional index of the shapefile record and is the join
    key used everywhere downstream. It replaces the arcpy workflow's
    ``OBJECTID`` / ``TARGET_FID``.

    Returns a GeoDataFrame of 3,375 polygons in EPSG:32619 with the grid's
    original attributes (``Lon_C``, ``Lat_C``, ``Area_m2``, ``Area_km2``).
    """
    grid = gpd.read_file(cfg.GRID_PATH)

    if grid.crs is None:
        raise ValueError(f"{cfg.GRID_PATH.name} has no CRS")
    if grid.crs.to_epsg() != cfg.ANALYSIS_CRS:
        raise ValueError(
            f"{cfg.GRID_PATH.name} is EPSG:{grid.crs.to_epsg()}, "
            f"expected EPSG:{cfg.ANALYSIS_CRS}"
        )
    if len(grid) != cfg.N_GRID_CELLS:
        raise ValueError(
            f"{cfg.GRID_PATH.name} has {len(grid)} cells, expected {cfg.N_GRID_CELLS}"
        )

    missing = {"Lon_C", "Lat_C", "Area_km2"} - set(grid.columns)
    if missing:
        # weights.py derives lattice indices from Lon_C / Lat_C, so their
        # absence is fatal rather than cosmetic.
        raise ValueError(f"{cfg.GRID_PATH.name} missing columns: {sorted(missing)}")

    grid = grid.reset_index(names="cell_id")
    log.info("Loaded grid: %d cells, EPSG:%d", len(grid), grid.crs.to_epsg())
    return grid


def load_aoi() -> gpd.GeoDataFrame:
    """Load the study-area boundary, reprojected to the analysis CRS.

    This is the dissolved union of the SFW + RWF + SRW 10 km buffers
    (``gfw_aoi_creation.py:63-68``). Ships as EPSG:4326.
    """
    aoi = gpd.read_file(cfg.AOI_PATH).to_crs(cfg.ANALYSIS_CRS)
    log.info("Loaded AOI: %d feature(s), EPSG:%d", len(aoi), aoi.crs.to_epsg())
    return aoi


def load_owf() -> gpd.GeoDataFrame:
    """Load the three Orsted wind-project outlines, reprojected and labelled.

    Returns one GeoDataFrame with ``project`` (SFW / RWF / SRW) and
    ``project_name`` columns, in EPSG:32619.

    Deliberately excludes ``VW1``, ``VW1_Buffer``, ``SRW_Buffer`` and the
    unfiltered ``SNE_OWFs`` layer -- Vineyard Wind 1 is not an Orsted project
    and lies outside the AOI, and the ``*_Buffer`` layers are AOI-construction
    intermediates rather than map features. See ``cfg.OWF_LAYERS_EXCLUDED``.
    """
    frames = []
    for code, name in cfg.OWF_LAYERS.items():
        path = cfg.SHP_OWF_DIR / f"{code}.shp"
        if not path.exists():
            raise FileNotFoundError(f"OWF layer not found: {path}")
        layer = gpd.read_file(path).to_crs(cfg.ANALYSIS_CRS)
        layer["project"] = code
        layer["project_name"] = name
        frames.append(layer[["project", "project_name", "geometry"]])

    owf = gpd.GeoDataFrame(
        pd.concat(frames, ignore_index=True), crs=f"EPSG:{cfg.ANALYSIS_CRS}"
    )
    log.info(
        "Loaded OWF layers: %s (%d features, EPSG:%d)",
        ", ".join(cfg.OWF_LAYERS),
        len(owf),
        owf.crs.to_epsg(),
    )
    return owf


# ---------------------------------------------------------------------------
# GFW records
# ---------------------------------------------------------------------------
def classify_gear(gear_type: pd.Series) -> pd.Series:
    """Map GFW ``Gear Type`` values onto the four analysis classes.

    ``Gear Type`` is a fixed per-vessel registry attribute, so this is a lookup
    rather than an inference. Unmapped or missing labels fall back to
    ``UNRESOLVED`` and are logged, so a new GFW label cannot silently vanish.
    """
    normalised = gear_type.fillna("NA").astype(str).str.strip().str.upper()
    unknown = sorted(set(normalised) - set(cfg.GEAR_CLASS_MAP))
    if unknown:
        log.warning(
            "Unmapped Gear Type value(s) %s -> %s", unknown, cfg.GEAR_CLASS_FALLBACK
        )
    return normalised.map(cfg.GEAR_CLASS_MAP).fillna(cfg.GEAR_CLASS_FALLBACK)


def load_stage(dataset: str, stage: int) -> pd.DataFrame:
    """Load one dataset/stage CSV, typed and with ``gear_class`` attached.

    ``dataset`` is ``"vp"`` or ``"afe"``; ``stage`` is 1, 2 or 3. These are the
    cleaned interim files, i.e. after the R pipeline removed Orsted charter
    vessels (Stages 2-3 only), cargo vessels, and -- for AFE -- records at or
    below the 0.32 hour threshold (``Rmd:494-535``).

    Rows whose gear class is ``EXCLUDED`` (non-fishing vessels that survived
    into the AFE files) are dropped and the count logged.
    """
    spec = _dataset_spec(dataset)
    stage_spec = _stage_spec(stage)

    path = cfg.INTERIM_GFW_DIR / spec.stage_file.format(stage=stage)
    if not path.exists():
        raise FileNotFoundError(f"Interim file not found: {path}")

    df = pd.read_csv(
        path,
        parse_dates=["Year Month", "Time Range"],
        dtype={"MMSI": "string", "Vessel ID": "string"},
    )

    if spec.hours_column not in df.columns:
        raise ValueError(
            f"{path.name} missing '{spec.hours_column}'; found {list(df.columns)}"
        )

    labels = set(df["Development Stage"].unique())
    if labels != {stage_spec.label}:
        raise ValueError(
            f"{path.name} contains Development Stage {sorted(labels)}, "
            f"expected only '{stage_spec.label}'"
        )

    df["gear_class"] = classify_gear(df["Gear Type"])

    n_excluded = int((df["gear_class"] == cfg.EXCLUDED).sum())
    if n_excluded:
        # The AFE pull was never filtered to Vessel Type == "FISHING" unlike
        # the VP pull (Rmd:203-254), so a handful of non-fishing rows survive.
        log.info("%s stage %d: dropping %d non-fishing row(s)", dataset, stage, n_excluded)
        df = df[df["gear_class"] != cfg.EXCLUDED].copy()

    observed = df["Year Month"].nunique()
    if observed != stage_spec.n_months:
        # Not an error: a month with no records anywhere in the AOI is a real
        # zero, not a missing observation. Known case is afe stage 1 (41 of 44).
        log.info(
            "%s stage %d: %d of %d nominal months have records",
            dataset,
            stage,
            observed,
            stage_spec.n_months,
        )

    log.info(
        "Loaded %s stage %d: %d rows, %d vessels (MMSI), %.0f hours",
        dataset,
        stage,
        len(df),
        df[cfg.VESSEL_COUNT_COLUMN].nunique(),
        df[spec.hours_column].sum(),
    )
    return df


def to_points(df: pd.DataFrame) -> gpd.GeoDataFrame:
    """Convert GFW records to points in the analysis CRS.

    ``Lat`` / ``Lon`` are 0.01-degree cell centroids in WGS 84; the result is
    reprojected to EPSG:32619 ready for the spatial join onto the grid.
    """
    pts = gpd.GeoDataFrame(
        df.copy(),
        geometry=gpd.points_from_xy(df["Lon"], df["Lat"]),
        crs=f"EPSG:{cfg.GEOGRAPHIC_CRS}",
    )
    return pts.to_crs(cfg.ANALYSIS_CRS)


def month_denominator(dataset: str, stage: int, df: pd.DataFrame | None = None) -> int:
    """Months to divide by when computing per-cell monthly means.

    Controlled by ``cfg.MONTH_DENOMINATOR``:

    ``"nominal"``
        Stage length from ``cfg.STAGES`` (44 / 43 / 40). A month with no
        records anywhere in the AOI counts as an observed zero.
    ``"observed"``
        Distinct months present in the data, reproducing the archived arcpy
        behaviour (``gfw_vp_stage_grid_summary.py:181``). Requires ``df``.

    The two agree for every dataset/stage except AFE stage 1 (41 vs 44), where
    ``"observed"`` yields values 7.3% higher. Global Moran's I and Gi* are
    invariant to this uniform rescaling; only descriptive hour comparisons
    across stages are affected.
    """
    if cfg.MONTH_DENOMINATOR == "nominal":
        return _stage_spec(stage).n_months
    if cfg.MONTH_DENOMINATOR == "observed":
        if df is None:
            raise ValueError("month_denominator(observed) requires df")
        return int(df["Year Month"].nunique())
    raise ValueError(
        f"cfg.MONTH_DENOMINATOR must be 'nominal' or 'observed', "
        f"got {cfg.MONTH_DENOMINATOR!r}"
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _dataset_spec(dataset: str) -> cfg.DatasetSpec:
    try:
        return cfg.DATASETS[dataset]
    except KeyError:
        raise ValueError(
            f"Unknown dataset {dataset!r}; expected one of {cfg.DATASET_KEYS}"
        ) from None


def _stage_spec(stage: int) -> cfg.StageSpec:
    try:
        return cfg.STAGES[stage]
    except KeyError:
        raise ValueError(
            f"Unknown stage {stage!r}; expected one of {cfg.STAGE_NUMBERS}"
        ) from None
