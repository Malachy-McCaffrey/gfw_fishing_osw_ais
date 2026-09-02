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
import pandas as pd

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

# ArcGIS-style hotspot palette, keyed by the -3..+3 Gi_Bin scale.
GI_BIN_COLORS = {
    -3: "#2166ac",
    -2: "#67a9cf",
    -1: "#d1e5f0",
    0: "#f7f7f7",
    1: "#fddbc7",
    2: "#ef8a62",
    3: "#b2182b",
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
AOI_EDGE = "#555555"


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
) -> plt.Axes:
    """Draw one stage's Gi* hotspot surface."""
    merged = grid.merge(cells[["cell_id", "Gi_Bin"]], on="cell_id")
    merged["color"] = merged["Gi_Bin"].map(GI_BIN_COLORS)
    merged.plot(ax=ax, color=merged["color"], linewidth=0)
    _overlay(ax, owf, aoi, label_projects)
    _finish(ax, title)
    return ax


def change_map(
    ax: plt.Axes,
    changes: pd.DataFrame,
    grid: gpd.GeoDataFrame,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None = None,
    title: str = "",
    label_projects: bool = True,
) -> plt.Axes:
    """Draw how hotspot status changed between two stages.

    ``changes`` is the ``classes`` frame from ``transitions.run_transitions``.
    """
    merged = grid.merge(changes[["cell_id", "change"]], on="cell_id")
    merged["color"] = merged["change"].map(tr.CHANGE_COLORS)
    merged.plot(ax=ax, color=merged["color"], linewidth=0)
    _overlay(ax, owf, aoi, label_projects)
    _finish(ax, title)
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
) -> plt.Figure:
    """The poster's lead panel: both stage transitions, side by side.

    Annotated with the area gained and lost, so the headline numbers are on the
    figure rather than only in a table the reader has to find.
    """
    spec = cfg.DATASETS[dataset]
    pairs = [p for p in cfg.STAGE_TRANSITIONS if (*p, gear_class) in transitions_out]
    fig, axes = plt.subplots(1, len(pairs), figsize=(7.0 * len(pairs), 7.4))
    axes = [axes] if len(pairs) == 1 else list(axes)

    for ax, (a, b) in zip(axes, pairs):
        result = transitions_out[(a, b, gear_class)]
        summary = result["summary"].set_index("change")
        gained = summary.loc["gained hot", "area_km2"]
        lost = summary.loc["lost hot", "area_km2"]
        change_map(
            ax, result["classes"], grid, owf, aoi,
            title=f"{cfg.STAGES[a].label} → {cfg.STAGES[b].label}",
        )
        ax.annotate(
            f"+{gained:,.0f} km² gained hot\n−{lost:,.0f} km² lost hot",
            xy=(0.03, 0.03), xycoords="axes fraction", fontsize=11,
            va="bottom", ha="left",
            bbox=dict(boxstyle="round,pad=0.45", fc="white", ec="#cccccc", alpha=0.92),
        )

    _legend(fig, tr.CHANGE_COLORS, ncol=5)
    fig.suptitle(
        f"{spec.label} — change in hotspot structure"
        + (f" ({gear_class.replace('_', ' ').lower()})" if gear_class else ""),
        fontsize=15, y=0.98,
    )
    fig.tight_layout(rect=(0, 0.08, 1, 0.96))
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
) -> plt.Figure:
    """One change map per gear class, for the transition that matters most.

    This is where the mobile-versus-fixed story lives. ``UNRESOLVED`` is shown
    alongside the interpretable classes rather than hidden, because its growth
    across stages is a finding in its own right -- it reflects GFW registry
    coverage rather than fleet behaviour.
    """
    spec = cfg.DATASETS[dataset]
    classes = [
        g for g in cfg.ANALYSIS_GEAR_CLASSES
        if (from_stage, to_stage, g) in transitions_out
    ]
    fig, axes = plt.subplots(1, len(classes), figsize=(4.2 * len(classes), 4.9))
    axes = [axes] if len(classes) == 1 else list(axes)

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
    fig.suptitle(
        f"{spec.label} — {cfg.STAGES[from_stage].label} → "
        f"{cfg.STAGES[to_stage].label} by gear class",
        fontsize=13, y=0.98,
    )
    fig.tight_layout(rect=(0, 0.14, 1, 0.94))
    return fig


def save(fig: plt.Figure, name: str, dpi: int = 300) -> str:
    """Write a figure to ``reports/figures`` at poster resolution."""
    cfg.FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    path = cfg.FIGURES_DIR / f"{name}.png"
    fig.savefig(path, dpi=dpi, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    log.info("Wrote %s", path)
    return str(path)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
def _overlay(
    ax: plt.Axes,
    owf: gpd.GeoDataFrame,
    aoi: gpd.GeoDataFrame | None,
    label_projects: bool,
) -> None:
    """Draw the AOI frame and the three lease areas over a filled surface."""
    if aoi is not None:
        aoi.boundary.plot(ax=ax, color=AOI_EDGE, linewidth=0.9, linestyle=(0, (4, 3)))

    owf.boundary.plot(ax=ax, color=OWF_EDGE, linewidth=1.7)

    if label_projects:
        for code, part in owf.groupby("project"):
            point = part.geometry.union_all().representative_point()
            ax.annotate(
                code, xy=(point.x, point.y), fontsize=10, fontweight="bold",
                ha="center", va="center", color=OWF_EDGE,
                bbox=dict(boxstyle="round,pad=0.22", fc="white", ec="none", alpha=0.78),
            )


def _finish(ax: plt.Axes, title: str) -> None:
    ax.set_title(title, fontsize=12)
    ax.set_aspect("equal")
    ax.set_axis_off()


def _legend(fig: plt.Figure, colors: dict, ncol: int) -> None:
    handles = [
        mpatches.Patch(facecolor=color, edgecolor="#999999", linewidth=0.4, label=label)
        for label, color in colors.items()
    ]
    fig.legend(
        handles=handles, loc="lower center", ncol=ncol, frameon=False,
        fontsize=9, bbox_to_anchor=(0.5, 0.01),
    )
