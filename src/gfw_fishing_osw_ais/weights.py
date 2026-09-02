# -*- coding: utf-8 -*-
"""Spatial weights for the analysis grid.

**Do not use ``libpysal.weights.Queen.from_dataframe`` on this grid.** It
silently produces a nearly useless weights matrix, and every Gi* and Local
Moran's result computed from it would be meaningless.

Why it fails
------------
``gfw_orsted_sqGrid.ipynb`` built the grid by drawing an independent
0.01-degree square around each unique GFW point (``half = 0.005``) rather than
generating one tessellated fishnet. Every polygon therefore carries its own
four corner coordinates, computed separately. Reprojecting WGS84 to UTM 19N
with ``PRESERVE_SHAPE`` then moves each polygon's vertices independently, so
cells that ought to share an edge end up with corner coordinates differing in
the last few decimal places. Geometric contiguity tests for *shared vertices*,
finds none, and concludes the cells are not neighbours:

===========================  ===============  ==========  =======
Method                       Mean neighbours  Components  Islands
===========================  ===============  ==========  =======
``Queen.from_dataframe``                1.96          74        0
``KNN(k=8)``                            8.00           1        0
Lattice-derived Queen (used)            7.80           1        0
===========================  ===============  ==========  =======

The fix
-------
The cells sit on an exact 0.01-degree lattice, so contiguity is recoverable
analytically from the ``Lon_C`` / ``Lat_C`` centroid attributes the shapefile
already carries. Two cells are Queen neighbours iff their integer lattice
indices differ by at most one on each axis. No geometry predicate, no distance
tolerance to tune, no floating-point comparison.

``KNN(k=8)`` was rejected despite also being connected: it forces exactly eight
neighbours everywhere, inventing them across the grid's outer edge and around
interior gaps where no cell exists.
"""

from __future__ import annotations

import logging

import geopandas as gpd
import numpy as np
import pandas as pd
from libpysal import weights

from . import config as cfg

log = logging.getLogger(__name__)

__all__ = [
    "gi_star_weights",
    "lattice_indices",
    "lattice_queen",
    "neighbor_summary",
    "validate_weights",
]

# A Queen lattice gives 8 neighbours in the interior and 3-5 at edges and
# corners. Anything below this mean means contiguity has broken down -- the
# polygon-based construction scores 1.96.
MIN_MEAN_NEIGHBORS = 7.0


def lattice_indices(grid: gpd.GeoDataFrame) -> pd.DataFrame:
    """Recover integer lattice row/column indices from cell centroids.

    ``Lat_C`` / ``Lon_C`` are the 0.01-degree cell-centre coordinates GFW
    returned, carried through the grid build unchanged. Dividing by the cell
    size and rounding gives an exact integer lattice.

    Raises if two cells collapse onto the same index, which would mean the
    centroids are not on the lattice the grid claims.
    """
    missing = {"Lat_C", "Lon_C"} - set(grid.columns)
    if missing:
        raise ValueError(f"Grid missing lattice columns: {sorted(missing)}")

    scaled_lat = grid["Lat_C"].to_numpy(dtype=float) / cfg.CELL_SIZE_DEG
    scaled_lon = grid["Lon_C"].to_numpy(dtype=float) / cfg.CELL_SIZE_DEG

    # Centroids should land on integers once scaled. Tolerate float noise from
    # the shapefile round-trip, but not a genuinely off-lattice cell.
    drift = np.max(np.abs(np.r_[scaled_lat, scaled_lon] - np.round(np.r_[scaled_lat, scaled_lon])))
    if drift > 0.1:
        raise ValueError(
            f"Cell centroids are not on a {cfg.CELL_SIZE_DEG} degree lattice "
            f"(max drift {drift:.3f} cells)"
        )

    idx = pd.DataFrame(
        {
            "cell_id": grid["cell_id"].to_numpy(),
            "row": np.round(scaled_lat).astype(int),
            "col": np.round(scaled_lon).astype(int),
        }
    )

    n_duplicate = len(idx) - len(idx.drop_duplicates(["row", "col"]))
    if n_duplicate:
        raise ValueError(
            f"{n_duplicate} cell(s) share a lattice index; centroids are not unique"
        )

    log.info(
        "Lattice: %d cells spanning %d rows x %d cols (max drift %.2e cells)",
        len(idx),
        idx["row"].nunique(),
        idx["col"].nunique(),
        drift,
    )
    return idx


def lattice_queen(
    grid: gpd.GeoDataFrame,
    row_standardize: bool = True,
    include_self: bool = False,
) -> weights.W:
    """Build Queen contiguity from lattice indices rather than geometry.

    Parameters
    ----------
    grid
        Output of ``io.load_grid()``; needs ``cell_id``, ``Lat_C``, ``Lon_C``.
    row_standardize
        Apply ``w.transform = "r"``. The archived arcpy workflow built the
        ``.swm`` row-standardised and then passed ``Standardization="NONE"`` to
        every downstream tool so it was not applied twice; here the equivalent
        is to standardise once and reuse the same ``W``.
    include_self
        Add each cell to its own neighbour set with weight 1 before
        standardising. Required for Gi* -- use ``gi_star_weights`` rather than
        setting this by hand.

    Returns
    -------
    ``libpysal.weights.W`` whose ids are ``cell_id`` values, in grid order, so
    a value array taken from ``aggregate.summarize_stage`` aligns positionally.
    """
    idx = lattice_indices(grid)
    lookup = {(r, c): int(cid) for cid, r, c in idx.itertuples(index=False)}

    offsets = [
        (dr, dc)
        for dr in (-1, 0, 1)
        for dc in (-1, 0, 1)
        if (dr, dc) != (0, 0)
    ]

    neighbors: dict[int, list[int]] = {}
    for cell_id, row, col in idx.itertuples(index=False):
        found = [
            lookup[(row + dr, col + dc)]
            for dr, dc in offsets
            if (row + dr, col + dc) in lookup
        ]
        if include_self:
            found.append(int(cell_id))
        neighbors[int(cell_id)] = found

    w = weights.W(neighbors, id_order=idx["cell_id"].astype(int).tolist(), silence_warnings=True)

    if row_standardize:
        w.transform = "r"

    log.info(
        "Built lattice Queen: n=%d, mean neighbours=%.2f, components=%d, islands=%d%s",
        w.n,
        w.mean_neighbors,
        w.n_components,
        len(w.islands),
        " (self-inclusive)" if include_self else "",
    )
    return w


def gi_star_weights(grid: gpd.GeoDataFrame) -> weights.W:
    """Queen weights including each cell's own value, for Getis-Ord Gi*.

    Gi* differs from Gi by including the focal cell in its own neighbourhood.
    Setting the self-weight explicitly avoids ``esda``'s fallback, which warns
    and assumes the self-weight equals the row maximum -- a guess that depends
    on whether the matrix has already been standardised.

    Self-weights are added *before* row standardisation so every cell carries
    equal weight across itself and its neighbours.
    """
    return lattice_queen(grid, row_standardize=True, include_self=True)


def validate_weights(
    w: weights.W,
    min_mean_neighbors: float = MIN_MEAN_NEIGHBORS,
    expect_components: int = 1,
) -> None:
    """Fail loudly if the weights matrix has degraded.

    This is the guard against silently regressing to geometric contiguity,
    which yields 1.96 mean neighbours across 74 disconnected components on this
    grid. Call it before running any spatial statistic.
    """
    problems = []
    if w.mean_neighbors < min_mean_neighbors:
        problems.append(
            f"mean neighbours {w.mean_neighbors:.2f} < {min_mean_neighbors} "
            f"(geometric contiguity on this grid gives 1.96)"
        )
    if w.n_components != expect_components:
        problems.append(f"{w.n_components} components, expected {expect_components}")
    if w.islands:
        problems.append(f"{len(w.islands)} island(s): {w.islands[:5]}")
    if w.n != cfg.N_GRID_CELLS:
        problems.append(f"n={w.n}, expected {cfg.N_GRID_CELLS}")

    if problems:
        raise ValueError("Weights matrix failed validation: " + "; ".join(problems))

    log.info(
        "Weights validated: n=%d, mean neighbours=%.2f, 1 component, no islands",
        w.n,
        w.mean_neighbors,
    )


def neighbor_summary(w: weights.W) -> pd.DataFrame:
    """Neighbour-count distribution, for the methods write-up.

    On a healthy lattice the interior cells carry the full 8 and the remainder
    sit at the grid's outer edge or around interior gaps.
    """
    counts = pd.Series({cell: len(nb) for cell, nb in w.neighbors.items()})
    out = (
        counts.value_counts()
        .sort_index()
        .rename_axis("n_neighbors")
        .reset_index(name="n_cells")
    )
    out["pct_cells"] = (100 * out["n_cells"] / out["n_cells"].sum()).round(1)
    return out
