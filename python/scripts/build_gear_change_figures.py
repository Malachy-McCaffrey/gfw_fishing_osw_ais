# -*- coding: utf-8 -*-
"""Rebuild the Stage 2 -> Stage 3 gear-change poster figures.

Run this to (re)write ``reports/figures/{afe,vp}_gear_change_s2s3.{png,pdf,svg}``::

    uv run python python/scripts/build_gear_change_figures.py

Both figures include a ``POLE_AND_LINE`` panel. For vessel presence that class
is already in ``cfg.DATASETS["vp"].gi_star_gear_classes``, so it comes free
from the normal ``spatial_stats.run_all`` default. For apparent fishing effort
it is not -- ``cfg.DATASETS["afe"].gi_star_gear_classes`` omits it because it
occupies only 2.4-6.2 percent of grid cells, too sparse for a stable Gi*
surface -- so this script asks ``run_all`` for it explicitly rather than
changing that default, which would also affect every other AFE result that
reads the dataset spec. ``viz.gear_small_multiples`` marks that one panel with
an asterisk and a caveat rather than presenting it as a confirmed hotspot.

These figures are tracked as deliverables (see the .gitignore comment on
``reports/figures/``), so re-run this after any change to the removal list or
the underlying extracts and commit the result -- same reasoning as the
basemap cache in ``fetch_basemap.py``.
"""

from __future__ import annotations

from gfw_fishing_osw_ais import config as cfg, io
from gfw_fishing_osw_ais import spatial_stats as ss
from gfw_fishing_osw_ais import transitions as tr
from gfw_fishing_osw_ais import viz

# All four analysis classes, for both datasets -- the override that puts
# POLE_AND_LINE into the AFE run despite cfg.DATASETS["afe"].gi_star_gear_classes.
ALL_CLASSES = (cfg.MOBILE, cfg.FIXED, cfg.POLE_AND_LINE, cfg.UNRESOLVED)


def main() -> None:
    grid = io.load_grid()
    owf = io.load_owf()
    aoi = io.load_aoi()

    for dataset in cfg.DATASET_KEYS:
        cells, _ = ss.run_all(dataset, gear_classes=ALL_CLASSES)
        trans = tr.run_transitions(dataset, cells, grid)
        fig = viz.gear_small_multiples(dataset, trans, grid, owf, aoi)
        viz.save(fig, f"{dataset}_gear_change_s2s3")


if __name__ == "__main__":
    main()
