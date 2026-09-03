# -*- coding: utf-8 -*-
"""Spatial weights.

The Gi* weights carry a documented trap: row standardisation collapses the
variance term and destroys the hotspot surface. That property is asserted here
so a future "tidy-up" cannot quietly reintroduce it.
"""

from __future__ import annotations

import numpy as np

from gfw_fishing_osw_ais import weights as wts


def test_lattice_indices_cover_every_cell(grid):
    idx = wts.lattice_indices(grid)
    assert len(idx) == len(grid)
    assert idx["cell_id"].is_unique


def test_queen_contiguity_gives_at_most_eight_neighbours(grid):
    w = wts.lattice_queen(grid)
    counts = np.array([len(v) for v in w.neighbors.values()])
    assert counts.max() <= 8
    assert counts.min() >= 0


def test_queen_contiguity_is_symmetric(grid):
    w = wts.lattice_queen(grid)
    for cell, neighbours in list(w.neighbors.items())[:200]:
        for other in neighbours:
            assert cell in w.neighbors[other], f"{cell}->{other} not reciprocated"


def test_a_cell_is_never_its_own_queen_neighbour(grid):
    w = wts.lattice_queen(grid)
    assert all(cell not in nbrs for cell, nbrs in w.neighbors.items())


def test_gi_star_weights_put_the_focal_cell_in_its_own_neighbourhood(grid):
    """Gi* is Gi plus the focal value; esda will not add it for us."""
    w = wts.gi_star_weights(grid)
    assert all(cell in nbrs for cell, nbrs in w.neighbors.items())


def test_gi_star_weights_stay_binary(grid):
    """Row standardisation forces W_i = 1 and compresses every z-score.

    See the docstring on ``gi_star_weights``: it is the difference between 832
    FDR-significant cells and none at all.
    """
    w = wts.gi_star_weights(grid)
    values = {v for row in w.weights.values() for v in row}
    assert values == {1.0}


def test_gi_star_neighbourhood_is_the_queen_set_plus_self(grid):
    queen = wts.lattice_queen(grid, row_standardize=False)
    star = wts.gi_star_weights(grid)
    for cell in list(queen.neighbors)[:200]:
        assert set(star.neighbors[cell]) == set(queen.neighbors[cell]) | {cell}
