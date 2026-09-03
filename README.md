# Spatiotemporal Responses of AIS-Broadcasting Fishing Vessels to Offshore Wind Development in Southern New England

Geospatial analysis and statistical modeling workflows to quantify AIS vessel presence and apparent fishing effort proximal to three Orsted offshore wind projects in Southern New England. Pre-processed AIS vessel presence and apparent fishing effort data accessed from Global Fishing Watch 4Wings API via gfwr package. This research is in fulfillment of my master's thesis.

---

## What is here

| Path | Role |
|---|---|
| `r/scripts/rmd/gfw_vp_afe_dataPull_090126.Rmd` | The data pull. Queries the GFW 4Wings API, filters, assigns development stages, writes the analysis CSVs. |
| `python/src/gfw_fishing_osw_ais/` | The analysis package: loaders, aggregation, spatial weights, spatial statistics, plots. |
| `reports/*.qmd` | The written analysis. Renders to self-contained HTML. |
| `references/` | Data dictionary and the vessel removal list. |
| `data/shp/` | Committed spatial inputs — analysis grid, AOI, wind-project footprints. |
| `python/notebooks/`, `python/scripts/arcpy/` | **Archived, not part of the reproducible path.** Exploratory notebooks and the original ArcGIS chain, superseded by `python/src/`. The arcpy scripts embed absolute geodatabase paths and require an ArcGIS Pro licence. |

## What ships with the clone, and what does not

**Committed:** the spatial layers under `data/shp/` (analysis grid of 3,375 cells at 0.01° in EPSG:32619, the study-area boundary, five offshore-wind layers), the vessel removal list, and the poster figures under `reports/figures/`.

**Not committed:** the Global Fishing Watch extracts under `data/external/gfw/` and `data/processed/gfw/`. These are the files the analysis actually reads, and regenerating them requires a GFW API token and a run of the R pull. Rendered Quarto HTML is also untracked — it is reproducible from the `.qmd` sources.

## Requirements

- **Python 3.12** and [uv](https://docs.astral.sh/uv/). The lockfile pins every version.
- **R**, with `gfwr`, `tidyverse`, `sf` and `lubridate`. The pull was run against gfwr v3.0.
- **Quarto** (developed against 1.10) to render the reports.
- **A Global Fishing Watch API token.** Request one from the GFW API portal at <https://globalfishingwatch.org/our-apis>.

## Reproducing the analysis

**1. Store your GFW API token.** It is read from the environment as `GFW_TOKEN`. Put it in a project-level `.Renviron`, which is gitignored:

```
GFW_TOKEN=your_token_here
```

`r/scripts/gfw_api_access_token.R` opens that file for editing and installs `gfwr` if needed.

**2. Run the data pull.** Knit `r/scripts/rmd/gfw_vp_afe_dataPull_090126.Rmd` **with the repository root as the working directory** — every path in it is repo-relative. It queries the API in eleven calendar-year calls per dataset, creates its own output directories, and writes the analysis CSVs into `data/processed/gfw/`.

**3. Install the Python environment.**

```sh
uv sync --locked
```

**4. Render the reports.**

```sh
cd reports
uv run quarto render
```

Run Quarto through `uv run` so it resolves the project interpreter rather than a system Python.

## Notes on reproducibility

- **Paths resolve from the repository root**, located by walking up to `pyproject.toml`. Nothing needs editing to run on another machine, and there are no absolute paths in `python/src`, `r/scripts` or `reports`.
- **Permutation-based statistics are seeded** (`config.RANDOM_SEED`), so Local Moran's I results are stable across runs. Gi\* uses analytic p-values and is deterministic by construction. The archived arcpy workflow set no seed and could not be reproduced.
- **The vessel removal list is a single tracked file**, `references/vessel_removals.csv`, read by both the R pull and Python and schema-validated on load in each. Adding or reclassifying a vessel is a one-row edit; nothing vessel-specific is hard-coded in either language.
- **No arcpy.** The analysis runs entirely on open-source geospatial tooling, so it reproduces without an ArcGIS licence.

## Citation

See `CITATION.cff`. Global Fishing Watch data are licensed CC BY-SA 4.0 and must be attributed separately.

## License

MIT — see `LICENSE`.
