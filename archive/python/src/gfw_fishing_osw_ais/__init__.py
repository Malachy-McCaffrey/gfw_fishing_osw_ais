# -*- coding: utf-8 -*-
"""Analysis package for the GFW / offshore-wind fishing effort study.

The modules are imported directly rather than re-exported here, so that
``config`` can be pulled in on its own without loading geopandas::

    from gfw_fishing_osw_ais import config as cfg, io, aggregate

* ``config``        -- paths, stages, gear classes, constants
* ``io``            -- loaders, each validating what it returns
* ``aggregate``     -- per-cell, per-stage roll-ups on the analysis grid
* ``weights``       -- lattice-recovered Queen contiguity and Gi* weights
* ``spatial_stats`` -- Moran's I, General G, Gi*, Local Moran's I
* ``transitions``   -- stage-to-stage hotspot change
* ``explore``       -- distribution diagnostics and documented limitations
* ``viz``           -- figures

There is no command-line entry point: the analysis runs from the Quarto
reports under ``reports/``. See the README to reproduce it.
"""

__version__ = "0.1.0"
