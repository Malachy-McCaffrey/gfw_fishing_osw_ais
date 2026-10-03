# -*- coding: utf-8 -*-
"""Stage loading and the vessel removals applied on top of it.

These need the GFW extracts, which are not committed, so they skip on a clone
that has not run the R pull.
"""

from __future__ import annotations

import pytest

from gfw_fishing_osw_ais import config as cfg, io

from conftest import needs_gfw_data

pytestmark = needs_gfw_data

CASES = [(d, s) for d in cfg.DATASET_KEYS for s in cfg.STAGE_NUMBERS]
IDS = [f"{d}{s}" for d, s in CASES]


@pytest.mark.parametrize("dataset, stage", CASES, ids=IDS)
def test_each_stage_file_loads_with_its_hours_column(dataset, stage):
    df = io.load_stage(dataset, stage)
    assert len(df) > 0
    assert cfg.DATASETS[dataset].hours_column in df.columns
    assert "gear_class" in df.columns


@pytest.mark.parametrize("dataset, stage", CASES, ids=IDS)
def test_a_stage_file_contains_only_its_own_stage(dataset, stage):
    """Mislabelled rows would leak effort across the before/after comparison."""
    df = io.load_stage(dataset, stage)
    assert set(df["Development Stage"]) == {cfg.STAGES[stage].label}


@pytest.mark.parametrize("dataset, stage", CASES, ids=IDS)
def test_excluded_gear_never_survives_into_the_analysis(dataset, stage):
    assert cfg.EXCLUDED not in set(io.load_stage(dataset, stage)["gear_class"])


@pytest.mark.parametrize("dataset, stage", CASES, ids=IDS)
def test_observed_months_never_exceed_the_stage_length(dataset, stage):
    """More months than the window holds means the window or the data is wrong."""
    df = io.load_stage(dataset, stage)
    assert df["Year Month"].nunique() <= cfg.STAGES[stage].n_months


# --- the removals actually happen -------------------------------------------

@pytest.mark.parametrize("dataset", cfg.DATASET_KEYS)
def test_all_stages_removals_are_gone_from_every_stage(dataset):
    mmsi = set(
        io.load_removal_list()
        .query("Scope == 'all_stages'")["MMSI"]
    )
    for stage in cfg.STAGE_NUMBERS:
        present = set(io.load_stage(dataset, stage)[cfg.VESSEL_COUNT_COLUMN].astype(str))
        assert not (mmsi & present), f"{dataset} stage {stage} retains {mmsi & present}"


@pytest.mark.parametrize("dataset", cfg.DATASET_KEYS)
def test_charter_removals_are_gone_from_stages_2_and_3(dataset):
    mmsi = set(
        io.load_removal_list()
        .query("Scope == 'stages_2_3'")["MMSI"]
    )
    for stage in cfg.RM_CHARTER_STAGES:
        present = set(io.load_stage(dataset, stage)[cfg.VESSEL_COUNT_COLUMN].astype(str))
        assert not (mmsi & present), f"{dataset} stage {stage} retains {mmsi & present}"


@pytest.mark.parametrize("dataset", cfg.DATASET_KEYS)
def test_stage_1_keeps_the_charter_vessels_pre_construction_records(dataset):
    """Charter hulls are real fishing vessels; their baseline is real fishing.

    Removing them from Stage 1 too would erase genuine activity and bias the
    before/after comparison in the opposite direction.
    """
    charter = set(io.load_removal_list().query("Scope == 'stages_2_3'")["MMSI"])
    present = set(io.load_stage(dataset, 1)[cfg.VESSEL_COUNT_COLUMN].astype(str))
    assert charter & present, "no charter vessel survives in Stage 1 -- scope is being ignored"
