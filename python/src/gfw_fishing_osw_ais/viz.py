# -*- coding: utf-8 -*-
"""Maps and figure assembly for the poster.

Figure strategy, in one line: **the change maps are the hero, the per-stage
maps are context.** Three Gi* maps side by side ask the reader to hold one in
working memory while scanning the next and infer the difference, which at a
poster session mostly does not happen. A change map does that differencing for
them and states the finding directly.

Every map carries the three Orsted lease outlines, which is what lets a viewer
read hotspot movement *relative to the projects* rather than in empty sea.
``io.load_owf`` returns only SFW, RWF and SRW: Vineyard Wind 1 is not an
Orsted project and lies outside the study area, and the ``*_Buffer`` layers are
AOI-construction intermediates rather than map features.

No basemap tiles are fetched, so figures render identically offline and in CI.
"""

from __future__ import annotations

import logging

import geopandas as gpd
import matplotlib as mpl
import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import rasterio
from functools import lru_cache

from . import config as cfg
from . import transitions as tr

log = logging.getLogger(__name__)

__all__ = [
    "change_map",
    "gear_small_multiples",
    "gi_map",
    "hero_figure",
    "reference_strip",
    "save",
]

# Hotspot palette, sampled from the ASLO 2026 poster so the two read as one
# body of work. The warm ramp is that poster's exact 90/95/99% confidence
# colours; the cold ramp mirrors it in blue, and "not significant" is the same
# near-white, which sits quietly against the ocean basemap.
GI_BIN_COLORS = {
    -3: "#2f6fb0",
    -2: "#7fa9d4",
    -1: "#c5d9ec",
    0: "#f7f7f2",
    1: "#fab984",
    2: "#ed7551",
    3: "#d62f27",
}
GI_BIN_LABELS = {
    -3: "Cold 99%",
    -2: "Cold 95%",
    -1: "Cold 90%",
    0: "Not significant",
    1: "Hot 90%",
    2: "Hot 95%",
    3: "Hot 99%",
}

OWF_EDGE = "#111111"

# Width / height of the cached AOI basemap. Panels are framed on that raster,
# so a panel drawn at any other aspect pads itself with empty margin -- which
# is where this figure's whitespace came from.
PANEL_ASPECT = 0.86


# ---------------------------------------------------------------------------
# Cartographic furniture
# ---------------------------------------------------------------------------
@lru_cache(maxsize=4)
def _read_basemap(path: str):
    """Read a cached basemap GeoTIFF as an RGB array plus its extent."""
    with rasterio.open(path) as src:
        arr = src.read([1, 2, 3])
        b = src.bounds
    return np.transpose(arr, (1, 2, 0)), (b.left, b.right, b.bottom, b.top)


def _basemap(ax: plt.Axes, path=None):
    """Draw the cached ocean basemap beneath everything else.

    Returns the extent so the panel can be framed on the basemap rather than
    on the data, which is what puts ocean around the study area. Returns None
    if the cache is absent, so a figure still draws without it.
    """
    path = path or cfg.BASEMAP_AOI_PATH
    if not path.exists():
        log.warning("Basemap cache missing: %s -- run scripts/fetch_basemap.py", path)
        return None
    img, extent = _read_basemap(str(path))
    ax.imshow(img, extent=extent, origin="upper", zorder=0,
              interpolation="bilinear")
    return extent


def _north_arrow(ax: plt.Axes, x: float = 0.052, y: float = 0.775,
                 h: float = 0.032) -> None:
    """The ASLO poster's north arrow: a slim solid dart under a small "N".

    Drawn as one polygon in axes coordinates -- tip, both barbs, and a notched
    base -- rather than an annotate() arrow, which cannot make the concave
    base that gives this mark its shape.

    Sits low enough on the left edge to stay over water: the basemap carries
    the Rhode Island and Long Island coastline across the top of every panel,
    and a mark laid over land is hard to read and looks like an accident.
    """
    w = h * 0.30
    dart = [(x, y + h), (x + w, y - h * 0.55), (x, y - h * 0.18),
            (x - w, y - h * 0.55)]
    ax.add_patch(mpatches.Polygon(
        dart, closed=True, transform=ax.transAxes, facecolor="#1a1a1a",
        edgecolor="none", zorder=6, clip_on=False))
    ax.text(x, y + h * 1.35, "N", transform=ax.transAxes, ha="center",
            va="bottom", fontsize=5.5, color="#1a1a1a", zorder=6)


def _scale_bar(ax: plt.Axes, y: float = 0.045) -> None:
    """Two-segment metric scale bar, sized to a round number of kilometres.

    The axes are UTM metres, so bar length is exact rather than nominal.
    """
    x0, x1 = ax.get_xlim()
    target = (x1 - x0) * 0.17
    nice = [1, 2, 5, 10, 20, 25, 50, 100]
    km = min(nice, key=lambda k: abs(k * 1000 - target))
    span = km * 1000
    # right-aligned: the hero panels carry their gained/lost annotation box in
    # the bottom-left corner.
    left = x1 - (x1 - x0) * 0.10 - span
    y0, y1 = ax.get_ylim()
    yb = y0 + (y1 - y0) * y
    h = (y1 - y0) * 0.008

    # A plain rule with end and midpoint ticks, as on the poster -- not an
    # alternating black/white bar, which reads as heavier than it needs to.
    ax.plot([left, left + span], [yb, yb], color="#1a1a1a", linewidth=0.8,
            solid_capstyle="butt", zorder=6)
    for frac in (0.0, 0.5, 1.0):
        xt = left + span * frac
        ax.plot([xt, xt], [yb, yb + h], color="#1a1a1a", linewidth=0.8,
                solid_capstyle="butt", zorder=6)
    for frac, lab in ((0, "0"), (0.5, f"{km // 2}"), (1, f"{km} km")):
        ax.text(left + span * frac, yb + h * 2.0, lab, ha="center", va="bottom",
                fontsize=5.5, color="#1a1a1a", zorder=6)


def _locator_inset(ax: plt.Axes, aoi: gpd.GeoDataFrame) -> None:
    """Regional inset placing the study area in Southern New England.

    A reader who does not know Rhode Island Sound cannot tell where these
    hotspots are; the hero panels carry this so they can.
    """
    if not cfg.BASEMAP_REGION_PATH.exists():
        return
    img, extent = _read_basemap(str(cfg.BASEMAP_REGION_PATH))
    inset = ax.inset_axes([0.735, 0.725, 0.25, 0.25], zorder=7)
    inset.imshow(img, extent=extent, origin="upper", interpolation="bilinear")
    w, s, e, n = aoi.total_bounds
    inset.add_patch(mpatches.Rectangle(
        (w, s), e - w, n - s, facecolor="none", edgecolor="#1a1a1a",
        linewidth=1.2, zorder=3))
    inset.set_xlim(extent[0], extent[1])
    inset.set_ylim(extent[2], extent[3])
    inset.set_xticks([]); inset.set_yticks([])
    inset.set_aspect("equal")
    for side in inset.spines.values():
        side.set_edgecolor("#1a1a1a")
        side.set_linewidth(0.9)


# ---------------------------------------------------------------------------
# Single panels
# ---------------------------------------------------------------------------
def gi_map(
    ax: plt.Axes,
    cells: pd.DataFrame,
    grid: gpd.GeoDataFrame,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None = None,
    title: str = "",
    label_projects: bool = True,
    locator: bool = False,
) -> plt.Axes:
    """Draw one stage's Gi* hotspot surface over the ocean basemap."""
    extent = _basemap(ax)
    merged = grid.merge(cells[["cell_id", "Gi_Bin"]], on="cell_id")
    merged["color"] = merged["Gi_Bin"].map(GI_BIN_COLORS)
    merged.plot(ax=ax, color=merged["color"], linewidth=0, zorder=1)
    _overlay(ax, owf, aoi, label_projects)
    _finish(ax, title, extent)
    if locator and aoi is not None:
        _locator_inset(ax, aoi)
    return ax


def change_map(
    ax: plt.Axes,
    changes: pd.DataFrame,
    grid: gpd.GeoDataFrame,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None = None,
    title: str = "",
    label_projects: bool = True,
    locator: bool = False,
) -> plt.Axes:
    """Draw how hotspot status changed between two stages.

    ``changes`` is the ``classes`` frame from ``transitions.run_transitions``.
    """
    extent = _basemap(ax)
    merged = grid.merge(changes[["cell_id", "change"]], on="cell_id")
    merged["color"] = merged["change"].map(tr.CHANGE_COLORS)
    merged.plot(ax=ax, color=merged["color"], linewidth=0, zorder=1)
    _overlay(ax, owf, aoi, label_projects)
    _finish(ax, title, extent)
    if locator and aoi is not None:
        _locator_inset(ax, aoi)
    return ax


# ---------------------------------------------------------------------------
# Assembled figures
# ---------------------------------------------------------------------------
def hero_figure(
    dataset: str,
    transitions_out: dict,
    grid: gpd.GeoDataFrame,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None = None,
    gear_class: str | None = None,
    panel_height: float = 6.4,
) -> plt.Figure:
    """The poster's lead panel: both stage transitions, side by side.

    Annotated with the area gained and lost, so the headline numbers are on the
    figure rather than only in a table the reader has to find.

    ``panel_height`` sets the figure height in inches and so its aspect ratio.
    The default is tuned for a portrait A0 poster, where the panel spans the
    full column width and every centimetre of height is contested: at 6.0 the
    rendered figure is roughly 2:1, against 1.6:1 at the old 7.4. The maps
    themselves are unchanged -- what is reclaimed is vertical whitespace.
    """
    spec = cfg.DATASETS[dataset]
    pairs = [p for p in cfg.STAGE_TRANSITIONS if (*p, gear_class) in transitions_out]
    fig, axes = plt.subplots(
        1, len(pairs),
        figsize=(panel_height * PANEL_ASPECT * len(pairs), panel_height))
    axes = [axes] if len(pairs) == 1 else list(axes)

    for ax, (a, b) in zip(axes, pairs):
        result = transitions_out[(a, b, gear_class)]
        summary = result["summary"].set_index("change")
        gained = summary.loc["gained hot", "area_km2"]
        lost = summary.loc["lost hot", "area_km2"]
        change_map(
            ax, result["classes"], grid, owf, aoi,
            title=f"{cfg.STAGES[a].label} → {cfg.STAGES[b].label}",
            locator=True,
        )
        ax.annotate(
            f"+{gained:,.0f} km² gained hot\n−{lost:,.0f} km² lost hot",
            xy=(0.025, 0.025), xycoords="axes fraction", fontsize=6.5,
            va="bottom", ha="left", zorder=6,
            bbox=dict(boxstyle="round,pad=0.28", fc="white", ec="#cccccc",
                      alpha=0.92, linewidth=0.5),
        )

    _legend(fig, tr.CHANGE_COLORS, ncol=5)
    _attribution(fig)
    fig.suptitle(
        f"{spec.label}: where hotspots were gained and lost "
        f"across offshore wind development stages"
        + (f" — {gear_class.replace('_', ' ').lower()} gear" if gear_class else ""),
        fontsize=11.5, y=0.985,
    )
    fig.tight_layout(rect=(0, 0.065, 1, 0.945), w_pad=0.4)
    return fig


def reference_strip(
    dataset: str,
    cells_by_key: dict,
    grid: gpd.GeoDataFrame,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None = None,
    gear_class: str | None = None,
) -> plt.Figure:
    """The three per-stage Gi* surfaces, small, as context for the hero panel.

    A change map alone is unreadable without the baseline: "gained hot" means
    nothing if the reader cannot see there was no hotspot there before.
    """
    spec = cfg.DATASETS[dataset]
    stages = [s for s in cfg.STAGE_NUMBERS if (s, gear_class) in cells_by_key]
    fig, axes = plt.subplots(1, len(stages), figsize=(4.2 * len(stages), 4.6))
    axes = [axes] if len(stages) == 1 else list(axes)

    for ax, stage in zip(axes, stages):
        gi_map(
            ax, cells_by_key[(stage, gear_class)], grid, owf, aoi,
            title=cfg.STAGES[stage].label, label_projects=False,
        )

    _legend(fig, {GI_BIN_LABELS[k]: v for k, v in GI_BIN_COLORS.items()}, ncol=7)
    _attribution(fig)
    fig.suptitle(f"{spec.label} — Gi* hotspots by stage", fontsize=13, y=0.98)
    fig.tight_layout(rect=(0, 0.12, 1, 0.94))
    return fig


def gear_small_multiples(
    dataset: str,
    transitions_out: dict,
    grid: gpd.GeoDataFrame,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None = None,
    from_stage: int = 2,
    to_stage: int = 3,
    ncols: int | None = None,
) -> plt.Figure:
    """One change map per gear class, for the transition that matters most.

    This is where the mobile-versus-fixed story lives. ``UNRESOLVED`` is shown
    alongside the interpretable classes rather than hidden, because its growth
    across stages is a finding in its own right -- it reflects GFW registry
    coverage rather than fleet behaviour.

    ``ncols`` defaults to one wide row, which is right on a landscape screen.
    On a portrait poster it is not: vessel presence has four gear classes, and
    a 1x4 row is 3.2:1, so spanning a narrow column leaves each map too small
    to read. Passing ``ncols=2`` stacks them 2x2 at roughly 1.6:1 instead.
    """
    spec = cfg.DATASETS[dataset]
    classes = [
        g for g in cfg.ANALYSIS_GEAR_CLASSES
        if (from_stage, to_stage, g) in transitions_out
    ]
    ncols = ncols or len(classes)
    nrows = -(-len(classes) // ncols)          # ceiling division
    fig, axes = plt.subplots(
        nrows, ncols, figsize=(4.2 * ncols, 4.9 * nrows)
    )
    axes = list(fig.axes)                      # row-major, works for any shape
    for spare in axes[len(classes):]:          # a 2x2 holding 3 maps
        spare.set_axis_off()

    for ax, gear_class in zip(axes, classes):
        result = transitions_out[(from_stage, to_stage, gear_class)]
        summary = result["summary"].set_index("change")
        change_map(
            ax, result["classes"], grid, owf, aoi,
            title=gear_class.replace("_", " ").title(), label_projects=False,
        )
        ax.annotate(
            f"+{summary.loc['gained hot', 'area_km2']:,.0f} / "
            f"−{summary.loc['lost hot', 'area_km2']:,.0f} km²",
            xy=(0.5, -0.04), xycoords="axes fraction",
            fontsize=9, ha="center", va="top", color="#444444",
        )

    _legend(fig, tr.CHANGE_COLORS, ncol=5)
    _attribution(fig)
    fig.suptitle(
        f"{spec.label} — {cfg.STAGES[from_stage].label} → "
        f"{cfg.STAGES[to_stage].label} by gear class",
        fontsize=13, y=0.98,
    )
    # The legend band is a fixed height, so it needs a smaller share of a
    # taller multi-row figure.
    fig.tight_layout(rect=(0, 0.14 if nrows == 1 else 0.08, 1, 0.94))
    return fig


def save(
    fig: plt.Figure,
    name: str,
    dpi: int = 300,
    formats: tuple[str, ...] = ("png", "pdf", "svg"),
) -> list[str]:
    """Write a figure to ``reports/figures`` as PNG, PDF and SVG.

    All three are rendered from the same figure rather than converted from one
    another: tracing a raster map back into vectors would turn crisp cell edges
    into approximated outlines, and the text into paths.

    * **SVG** is the poster master. Its ground is transparent, so it sits on the
      poster's panel colour like ``methods_flowchart.svg``, and its text stays
      live and editable in Illustrator.
    * **PDF** is the print master for anything that wants a self-contained
      vector file.
    * **PNG** is kept because the Quarto reports embed it and browsers render it
      without a plugin. It keeps a white ground, since the reports composite it
      onto a white page.

    Vector matters here: these are polygon maps with text, so a raster carries
    every cell edge as pixels. Spanning the 76 cm live width of a portrait A0 at
    300 dpi would need roughly 9,000 px, and the PNGs land at about 115 dpi at
    that size.
    """
    cfg.FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    written = []
    for fmt in formats:
        path = cfg.FIGURES_DIR / f"{name}.{fmt}"
        transparent = fmt == "svg"
        # svg.fonttype "none" keeps labels as <text> instead of converting them
        # to outlines, which is what makes the SVG editable in Illustrator. The
        # cost is that the viewing machine must have the font; matplotlib's
        # default here is "path", which bakes the glyphs in and cannot be typed
        # over.
        with mpl.rc_context({"svg.fonttype": "none"}):
            fig.savefig(
                path, dpi=dpi, bbox_inches="tight",
                facecolor="none" if transparent else "white",
                transparent=transparent,
            )
        written.append(str(path))
    plt.close(fig)
    log.info("Wrote %s", ", ".join(written))
    return written


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _overlay(
    ax: plt.Axes,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None,
    label_projects: bool,
) -> None:
    """Draw the three lease areas over the filled surface.

    The AOI is deliberately not outlined: the grid cells stop at its boundary,
    so they describe it already, and a dashed ring on top only adds ink.
    """
    owf.boundary.plot(ax=ax, color=OWF_EDGE, linewidth=1.0, zorder=3)

    if label_projects:
        for code, part in owf.groupby("project"):
            point = part.geometry.union_all().representative_point()
            ax.annotate(
                code, xy=(point.x, point.y), fontsize=10, fontweight="bold",
                ha="center", va="center", color=OWF_EDGE, zorder=4,
            )


def _finish(ax: plt.Axes, title: str, extent=None) -> None:
    """Frame the panel and add the north arrow and scale bar.

    Framing on the basemap extent rather than the data is what leaves ocean
    around the study area instead of cropping tight to the grid.
    """
    if extent is not None:
        ax.set_xlim(extent[0], extent[1])
        ax.set_ylim(extent[2], extent[3])
    ax.set_title(title, fontsize=12)
    ax.set_aspect("equal")
    _north_arrow(ax)
    _scale_bar(ax)
    ax.set_axis_off()


def _attribution(fig: plt.Figure) -> None:
    """Esri's terms require the basemap credit wherever the tiles are drawn."""
    if not cfg.BASEMAP_AOI_PATH.exists():
        return
    fig.text(0.995, 0.004, cfg.BASEMAP_ATTRIBUTION, ha="right", va="bottom",
             fontsize=5.5, color="#666666")


def _legend(fig: plt.Figure, colors: dict, ncol: int) -> None:
    handles = [
        mpatches.Patch(facecolor=color, edgecolor="#999999", linewidth=0.4, label=label)
        for label, color in colors.items()
    ]
    fig.legend(
        handles=handles, loc="lower center", ncol=ncol, frameon=False,
        fontsize=9, bbox_to_anchor=(0.5, 0.01),
    )
