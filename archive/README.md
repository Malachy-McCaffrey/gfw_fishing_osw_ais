# Archived: the Python implementation

This is the frozen Python analysis — package, scripts, notebooks, tests, and the
Quarto reports built on it. It was the active workflow through the thesis analysis
and poster figures; development has since moved to a simpler, R-only workflow in
[`r/`](../r/).

Nothing here is deleted or disabled. It moved one level deeper, from `python/` and
`reports/` at the repository root to `archive/python/` and `archive/reports/`, and
remains fully reproducible — `pyproject.toml`, `uv.lock`, and `.python-version`
stay at the true repository root for exactly that reason, so `uv` and Quarto both
find the project root the same way they always did. See the root `README.md` for
the commands.

## What is here

| Path | Role |
|---|---|
| `python/src/gfw_fishing_osw_ais/` | The analysis package: loaders, aggregation, spatial weights, spatial statistics, plots. |
| `python/tests/` | Its test suite. Still runs via `uv run python -m pytest`. |
| `python/scripts/` | `fetch_basemap.py` (basemap cache) and `build_gear_change_figures.py` (poster figures), plus `scripts/arcpy/` and `notebooks/`, both already archived before this move — the original ArcGIS chain and exploratory notebooks, superseded by `python/src/` in turn. |
| `reports/*.qmd` | The written analysis. Renders to the committed, self-contained HTML. |
| `reports/figures/` | The poster figures (PNG/PDF/SVG), tracked as deliverables. |
| `reports/_freeze/` | The Quarto freeze cache, committed so the reports rebuild from a bare clone without a GFW token or the extracts. |

## Why it moved, not just stopped

Keeping this runnable rather than deleting it means the thesis figures and the
statistical decisions behind them (the Gi\* weighting fix, the FDR behaviour, the
vessel-removal screen) stay checkable against the code that produced them, even
after active development moves elsewhere. If the R workflow in `r/` ever needs to
reproduce a specific number from here, this is still the place to run it.
