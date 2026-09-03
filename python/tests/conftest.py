# -*- coding: utf-8 -*-
"""Shared fixtures.

The spatial inputs under ``data/shp/`` are committed, so those tests run on any
clone, CI included. The GFW extracts are not committed -- they are regenerated
by the R pull -- so tests that need them are skipped rather than failed when
they are absent, so a clone without the extracts still gets a green run
over everything that does not depend on them.
"""

from __future__ import annotations

import pytest

from gfw_fishing_osw_ais import config as cfg


def _extracts_present() -> bool:
    return all(
        (cfg.PROCESSED_GFW_DIR / spec.stage_file.format(stage=stage)).exists()
        for spec in cfg.DATASETS.values()
        for stage in cfg.STAGE_NUMBERS
    )


needs_gfw_data = pytest.mark.skipif(
    not _extracts_present(),
    reason=f"GFW extracts absent from {cfg.PROCESSED_GFW_DIR}; run the R pull",
)


@pytest.fixture(scope="session")
def grid():
    from gfw_fishing_osw_ais import io

    return io.load_grid()
