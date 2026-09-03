# -*- coding: utf-8 -*-
"""The removal list and its validator.

This list decides which vessels leave the analysis, so the validator in
``io.load_removal_list`` is the guard on the most consequential judgement in the
project. These tests exist because a validator nothing exercises is a validator
that may already be broken.
"""

from __future__ import annotations

import pandas as pd
import pytest

from gfw_fishing_osw_ais import config as cfg, io


@pytest.fixture
def removals_at(tmp_path, monkeypatch):
    """Point the loader at a CSV built for one test, then restore."""

    def _write(frame: pd.DataFrame):
        path = tmp_path / "removals.csv"
        frame.to_csv(path, index=False)
        monkeypatch.setattr(cfg, "VESSEL_REMOVALS_PATH", path)
        io.load_removal_list.cache_clear()
        return path

    yield _write
    io.load_removal_list.cache_clear()


@pytest.fixture
def valid_frame() -> pd.DataFrame:
    return pd.DataFrame(
        [
            {"Vessel_Name": "Alpha", "MMSI": "367000001", "Operation": "Safety",
             "Scope": "stages_2_3", "Identified_By": "orsted_list",
             "Confidence": "confirmed", "Date_Added": "", "Notes": ""},
            {"Vessel_Name": "Beta", "MMSI": "338000002", "Operation": "Survey",
             "Scope": "all_stages", "Identified_By": "known_research_vessel",
             "Confidence": "probable", "Date_Added": "2026-01-31", "Notes": "x"},
        ]
    )


# --- the list that ships -----------------------------------------------------

def test_shipped_list_loads_and_holds_its_invariants():
    removals = io.load_removal_list()
    assert len(removals) > 0
    assert set(cfg.REMOVAL_REQUIRED_COLUMNS) <= set(removals.columns)
    assert removals["MMSI"].str.fullmatch(r"\d{9}").all()
    assert not removals["MMSI"].duplicated().any()
    assert set(removals["Scope"]) <= set(cfg.REMOVAL_SCOPES)
    assert set(removals["Confidence"]) <= set(cfg.CONFIDENCE_LEVELS)


def test_every_scope_in_the_shipped_list_is_actually_handled():
    """A scope the code does not branch on would silently remove nothing."""
    scopes = set(io.load_removal_list()["Scope"])
    assert scopes <= {"stages_2_3", "all_stages"}


# --- the validator -----------------------------------------------------------

def test_accepts_a_well_formed_list(removals_at, valid_frame):
    removals_at(valid_frame)
    assert len(io.load_removal_list()) == 2


def test_missing_file_is_reported_as_such(removals_at, valid_frame, tmp_path, monkeypatch):
    monkeypatch.setattr(cfg, "VESSEL_REMOVALS_PATH", tmp_path / "absent.csv")
    io.load_removal_list.cache_clear()
    with pytest.raises(FileNotFoundError):
        io.load_removal_list()


def test_missing_column_is_named(removals_at, valid_frame):
    removals_at(valid_frame.drop(columns=["Confidence"]))
    with pytest.raises(ValueError, match="Confidence"):
        io.load_removal_list()


@pytest.mark.parametrize(
    "column, bad_value, expected",
    [
        ("MMSI", "12345", "9 digits"),
        ("MMSI", "36700000x", "9 digits"),
        ("Scope", "stage_2", "unknown Scope"),
        ("Confidence", "likely", "unknown Confidence"),
        ("Vessel_Name", "", "blank Vessel_Name"),
        ("Date_Added", "31/01/2026", "Date_Added"),
    ],
)
def test_each_malformed_field_is_rejected(removals_at, valid_frame, column, bad_value, expected):
    frame = valid_frame.copy()
    frame.loc[0, column] = bad_value
    removals_at(frame)
    with pytest.raises(ValueError, match=expected):
        io.load_removal_list()


def test_duplicate_mmsi_is_rejected(removals_at, valid_frame):
    frame = valid_frame.copy()
    frame.loc[1, "MMSI"] = frame.loc[0, "MMSI"]
    removals_at(frame)
    with pytest.raises(ValueError, match="duplicate MMSI"):
        io.load_removal_list()


def test_all_problems_are_reported_together(removals_at, valid_frame):
    """The loader collects every fault rather than stopping at the first.

    One round trip per fault is the difference between fixing the list once and
    fixing it six times.
    """
    frame = valid_frame.copy()
    frame.loc[0, "MMSI"] = "123"
    frame.loc[0, "Scope"] = "stage_2"
    frame.loc[1, "Confidence"] = "likely"
    frame.loc[1, "Vessel_Name"] = ""
    removals_at(frame)
    with pytest.raises(ValueError) as excinfo:
        io.load_removal_list()
    message = str(excinfo.value)
    for expected in ("9 digits", "unknown Scope", "unknown Confidence", "blank Vessel_Name"):
        assert expected in message
