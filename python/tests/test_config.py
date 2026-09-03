# -*- coding: utf-8 -*-
"""The constants other modules trust without re-checking."""

from __future__ import annotations

import pandas as pd
import pytest

from gfw_fishing_osw_ais import config as cfg


def test_repo_root_is_the_directory_holding_pyproject():
    assert (cfg.REPO_ROOT / "pyproject.toml").is_file()


def test_stages_are_contiguous_and_non_overlapping():
    """Stage windows must tile the study period with no gap and no overlap.

    A gap would silently drop months from the denominators; an overlap would
    double-count them.
    """
    spans = [cfg.STAGES[n] for n in sorted(cfg.STAGE_NUMBERS)]
    for earlier, later in zip(spans, spans[1:]):
        expected = pd.Timestamp(earlier.end) + pd.offsets.MonthBegin(1)
        assert pd.Timestamp(later.start) == expected, (
            f"{earlier.label} ends {earlier.end}, so {later.label} must start "
            f"{expected.date()}, not {later.start}"
        )


def test_declared_month_counts_match_the_declared_windows():
    """n_months is used as a divisor, so it must match the window it describes."""
    for spec in cfg.STAGES.values():
        months = len(
            pd.date_range(spec.start, spec.end, freq="MS")
        )
        assert months == spec.n_months, f"{spec.label}: {months} months, declared {spec.n_months}"


def test_gear_map_only_produces_known_classes():
    known = set(cfg.ANALYSIS_GEAR_CLASSES) | {cfg.EXCLUDED}
    assert set(cfg.GEAR_CLASS_MAP.values()) <= known
    assert cfg.GEAR_CLASS_FALLBACK in cfg.ANALYSIS_GEAR_CLASSES


def test_excluded_is_not_carried_into_the_analysis():
    assert cfg.EXCLUDED not in cfg.ANALYSIS_GEAR_CLASSES


@pytest.mark.parametrize("spec", list(cfg.DATASETS.values()), ids=list(cfg.DATASETS))
def test_gi_star_gear_classes_are_a_subset_of_the_analysis_classes(spec):
    assert set(spec.gi_star_gear_classes) <= set(cfg.ANALYSIS_GEAR_CLASSES)
