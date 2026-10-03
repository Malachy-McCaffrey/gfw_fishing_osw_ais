# -*- coding: utf-8 -*-
"""Loaders for the committed spatial layers, and the gear lookup.

Everything here runs on a bare clone: these inputs are tracked.
"""

from __future__ import annotations

import pandas as pd
import pytest

from gfw_fishing_osw_ais import config as cfg, io


def test_grid_has_the_expected_cell_count_and_crs(grid):
    assert len(grid) == cfg.N_GRID_CELLS
    assert grid.crs.to_epsg() == cfg.ANALYSIS_CRS


def test_grid_cell_ids_are_unique(grid):
    assert grid["cell_id"].is_unique


def test_grid_carries_the_centroid_columns_weights_depend_on(grid):
    """weights.lattice_indices recovers row/column from these, not geometry."""
    assert {"Lat_C", "Lon_C"} <= set(grid.columns)
    assert grid[["Lat_C", "Lon_C"]].notna().all().all()


def test_aoi_and_owf_are_reprojected_to_the_analysis_crs():
    assert io.load_aoi().crs.to_epsg() == cfg.ANALYSIS_CRS
    assert io.load_owf().crs.to_epsg() == cfg.ANALYSIS_CRS


def test_owf_excludes_the_buffer_layers():
    """Vineyard Wind and the *_Buffer layers are deliberately out of scope."""
    names = " ".join(io.load_owf().astype(str).to_numpy().ravel()).lower()
    assert "buffer" not in names


# --- gear classification -----------------------------------------------------

def test_known_gear_labels_map_to_their_class():
    known = list(cfg.GEAR_CLASS_MAP)[:5]
    out = io.classify_gear(pd.Series(known))
    assert list(out) == [cfg.GEAR_CLASS_MAP[k] for k in known]


def test_gear_matching_is_insensitive_to_case_and_padding():
    label = next(iter(cfg.GEAR_CLASS_MAP))
    messy = pd.Series([f"  {label.lower()}  "])
    assert io.classify_gear(messy).iloc[0] == cfg.GEAR_CLASS_MAP[label]


def test_unmapped_and_missing_labels_fall_back_rather_than_vanish():
    out = io.classify_gear(pd.Series(["NOT_A_REAL_GEAR", None]))
    assert list(out) == [cfg.GEAR_CLASS_FALLBACK, cfg.GEAR_CLASS_FALLBACK]


def test_classify_gear_never_returns_null():
    out = io.classify_gear(pd.Series([None, "", "ZZZ", next(iter(cfg.GEAR_CLASS_MAP))]))
    assert out.notna().all()
