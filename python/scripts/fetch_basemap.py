# -*- coding: utf-8 -*-
"""Fetch the Esri Ocean Basemap once and cache it as GeoTIFF.

Run this only to (re)create the cache::

    uv run python python/scripts/fetch_basemap.py

The figures read the committed rasters, never the network. That keeps figure
regeneration offline, deterministic, and reproducible after the tile service
has moved on -- the same reason the vessel removal list is tracked rather than
fetched. Two extents are written, both warped to the analysis CRS:

* ``aoi_ocean_utm19n.tif``    -- the study area, for the map panels
* ``region_gray_utm19n.tif``  -- Southern New England, for the locator inset

Esri's terms require attribution wherever these are drawn; see
``config.BASEMAP_ATTRIBUTION``.
"""

from __future__ import annotations

import sys

import contextily as cx
import rasterio
from rasterio.transform import from_bounds

from gfw_fishing_osw_ais import config as cfg, io

SOURCE = cx.providers.Esri.OceanBasemap
# The locator inset is greyscale, matching the ASLO poster: a muted canvas
# reads as context rather than competing with the panel it sits on.
REGION_SOURCE = cx.providers.Esri.WorldGrayCanvas

# Southern New England, in EPSG:4326: Long Island Sound to Cape Cod. Chosen so
# a reader can place the AOI against Rhode Island and Massachusetts.
REGION_LL = (-72.35, 40.30, -69.75, 42.20)

AOI_MARGIN = 0.12      # fraction of extent, so ocean surrounds the study area
AOI_ZOOM = 12
# Zoom 10, not 9: the inset prints at roughly 10 cm on an A0 poster, and the
# canvas place labels (Providence, New Bedford) have to survive that.
REGION_ZOOM = 10

# Warping Web Mercator tiles into UTM rotates the image slightly, leaving black
# nodata wedges in the corners. Trimming a margin off every edge removes them;
# AOI_MARGIN is sized so there is still ocean around the study area afterwards.
EDGE_TRIM = 0.055


def _trim(img, extent, frac=EDGE_TRIM):
    """Crop the nodata wedges the reprojection leaves at the edges."""
    h, w = img.shape[0], img.shape[1]
    dy, dx = int(h * frac), int(w * frac)
    left, right, bottom, top = extent
    sx, sy = (right - left) / w, (top - bottom) / h
    return (img[dy:h - dy, dx:w - dx],
            (left + dx * sx, right - dx * sx, bottom + dy * sy, top - dy * sy))


def _write(img, extent, path, crs):
    """Write a contextily image array to a GeoTIFF."""
    left, right, bottom, top = extent
    height, width = img.shape[0], img.shape[1]
    bands = min(img.shape[2], 3)          # drop alpha; the basemap is opaque
    path.parent.mkdir(parents=True, exist_ok=True)
    with rasterio.open(
        path, "w", driver="GTiff", height=height, width=width, count=bands,
        dtype=img.dtype, crs=crs,
        transform=from_bounds(left, bottom, right, top, width, height),
        compress="deflate", predictor=2, tiled=True,
    ) as dst:
        for b in range(bands):
            dst.write(img[:, :, b], b + 1)
    mb = path.stat().st_size / 1e6
    print(f"  wrote {path.name}  {width}x{height}  {mb:.1f} MB")


def main() -> int:
    aoi = io.load_aoi()

    print("AOI extent:")
    w, s, e, n = aoi.to_crs(cfg.GEOGRAPHIC_CRS).total_bounds
    dx, dy = (e - w) * AOI_MARGIN, (n - s) * AOI_MARGIN
    img, ext = cx.bounds2img(w - dx, s - dy, e + dx, n + dy,
                             zoom=AOI_ZOOM, source=SOURCE, ll=True)
    img, ext = cx.warp_tiles(img, ext, t_crs=f"EPSG:{cfg.ANALYSIS_CRS}")
    img, ext = _trim(img, ext)
    _write(img, ext, cfg.BASEMAP_AOI_PATH, f"EPSG:{cfg.ANALYSIS_CRS}")

    print("Regional extent (locator inset):")
    img, ext = cx.bounds2img(*REGION_LL, zoom=REGION_ZOOM, source=REGION_SOURCE,
                             ll=True)
    img, ext = cx.warp_tiles(img, ext, t_crs=f"EPSG:{cfg.ANALYSIS_CRS}")
    img, ext = _trim(img, ext)
    _write(img, ext, cfg.BASEMAP_REGION_PATH, f"EPSG:{cfg.ANALYSIS_CRS}")

    print("\n" + cfg.BASEMAP_ATTRIBUTION)
    return 0


if __name__ == "__main__":
    sys.exit(main())
