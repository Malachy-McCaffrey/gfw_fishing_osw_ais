# Spatiotemporal Responses of AIS-Broadcasting Fishing Vessels to Offshore Wind Development in Southern New England

Geospatial analysis and statistical modeling workflows to quantify AIS vessel presence and apparent fishing effort proximal to three Orsted offshore wind projects in Southern New England. Pre-processed AIS vessel presence and apparent fishing effort data accessed from Global Fishing Watch 4Wings API via gfwr package. This research is in fulfillment of my master's thesis.

**Status:** the analysis was developed in Python through the thesis write-up and poster. Active development has since moved to an R-only workflow in `r/`. The R workflow runs from the data pull through vessel classification, the analysis tables, exploratory analysis and the global and local spatial statistics (analysis Phases 0–3); the before–after–gradient (BAG) models (Phase 4) are in progress, and the statistical models, sensitivity and synthesis (Phases 5–8) are not yet written. The phase-by-phase status is the *Status* table at the top of [`planning/gfw_analysis_plan.qmd`](planning/gfw_analysis_plan.qmd). The completed Python analysis is archived, not deleted — still reproducible, see `archive/README.md`.

---

## The R workflow

Files in `r/` are numbered in run order. `r/_quarto.yml` lists the render order, so `quarto render r/` runs 02 → 02a → 03 → 04 → 05 → 05a → 06 → 07 → 08 → 10. Steps 00–04 prepare and classify the data; 05 onward are the analysis phases of [`planning/gfw_analysis_plan.qmd`](planning/gfw_analysis_plan.qmd), where each phase's method and gate are written down.

| Step | File | What it does | Needs |
|---|---|---|---|
| 00 | `00_setup.R` | Restores the R environment and stores the GFW token. Run once per machine. | — |
| 01 | `01_pull_gfw.qmd` | Pulls daily 0.01° vessel presence (VP) and apparent fishing effort (AFE) for the AOI from the GFW 4Wings API, one calendar year per request, at a named dataset version (`gfw_4wings_pinned()`; gfwr itself always requests `:latest`), and writes the raw extracts and `pull_info.csv` to `data/raw/gfw/{pipeline}/`. Refuses to overwrite an existing pull. Not in the default render. | GFW token |
| 02 | `02_build_grid.qmd` | Rebuilds GFW's 0.01° grid from the lower-left cell corners, reprojects it to UTM 19N, flags cells against the AOI, builds queen-contiguity neighbours, and writes raw-data (all vessel types) cell tables. | Raw pull |
| 02a | `02a_infrastructure.qmd` | Builds the Ørsted foundation and cable layers (`data/sf/infra/infrastructure.gpkg`) and their per-cell distance, construction, safety-zone and timing covariates (`infra_cell_*.csv`), with its own gate. Needs only the grid, so it runs straight after 02. | Grid, Ørsted files |
| 03 | `03_review_vessels.qmd` | The analyst's vessel review. Screens for misclassified vessels, gathers evidence (GARFO permits, GFW identity API, USCG PSIX), writes review sheets, and turns decisions into `references/vessel_crosswalk_{pipeline}.csv` and `references/vessel_permit_groups_{pipeline}.csv`. The only step that writes to `references/`. | Raw pull, GARFO permit lists, API caches |
| 04 | `04_classify_aggregate.qmd` | Applies the crosswalk and gear corrections to every record, builds the **Strict** (GFW's `FISHING` label) and **Primary** (verified) analysis sets, and writes the classified records and zero-filled cell × stage / cell × month tables, with and without gear class. Stops if the crosswalk is out of date. | Raw pull, grid, `references/` |
| 05 | `05_prepare_analysis.qmd` | **Phase 0.** Builds the analysis tables, bathymetry covariates (NCEI CRM, fetched here), exposure weights and spatial weights, and joins 02a's infrastructure covariates. Ends with a gate that stops the render if a check fails. | 04, 02a |
| 05a | `05a_export_rasters.qmd` | Writes the Primary set's VP and AFE hours, vessel counts and static cell covariates as GeoTIFF and NetCDF on GFW's 0.01° grid (EPSG:4326), for overlay with other gridded fisheries data (D-067). An output only: nothing downstream reads it. Ends with a read-back gate. | 04, 05 |
| 06 | `06_explore.qmd` | **Phase 1.** Exploratory analysis: data structure, zeros, transforms, parallel-trends tests and the gate decisions for the models. | 05 |
| 07 | `07_spatial_global.qmd` | **Phase 2.** Global Moran's I, General G and correlograms; writes the practical range (*ρ*₀) used for later weights and priors. | 05 |
| 08 | `08_spatial_local.qmd` | **Phase 3.** Local Moran's I vs Getis-Ord Gi\*: change maps, comparison criteria and the power simulation. | 05, 07 |
| 10 | `10_bag.qmd` | **Phase 4, in progress.** Before–after–gradient models on interim specifications; fits are cached in `data/processed/models/{pipeline}/`. | 05 |
| 11–14 | not yet written | **Phases 5–8:** frequentist models, INLA-SPDE, sensitivity, synthesis. | |

There is no 09. A planned `01a_compare_pipelines.qmd` will compare GFW pipeline versions ([`planning/gfw_pipeline_v5_plan.qmd`](planning/gfw_pipeline_v5_plan.qmd)).

Shared code, sourced by the qmds: `paths.R` (every path; each can be overridden with a Quarto parameter), `gfw_helpers.R` (development stages, analysis window, `read_gfw()`, gear classes), `vessel_helpers.R` (crosswalk build and validation, `classify()`, the fishing roster), `review_helpers.R` (03's screen, GARFO matching, and GFW identity and PSIX evidence), `analysis_helpers.R` (seasons, transforms, lease distances, lattice neighbours, `fit_cached()`, provenance sidecars), `infra_helpers.R` (reading Ørsted foundation files and building exposure covariates), `spatial_helpers.R` (global and local statistics) and `bag_helpers.R` (BAG models).

**Analysis window:** 2016-01-01 to 2026-08-31, in three development stages (`dev_stages` in `r/gfw_helpers.R`):

| Stage | Window | Months | |
|---|---|---|---|
| 1 | 2016-01-01 → 2020-09-30 | 57 | Pre-monitoring baseline |
| 2 | 2020-10-01 → 2023-03-31 | 30 | South Fork Wind fisheries monitoring began 10/2020 |
| 3 | 2023-04-01 → 2026-08-31 | 41 | SFW seabed preparation began 04/2023; construction and operation across SFW, RWF and SRW |

The pull runs to 2026-09-30, but the window ends on 2026-08-31, the last day Ørsted's survey-trip records cover. After that date, survey work by chartered fishing vessels would be counted as fishing.

## Repository map

### Where to look

| To find out… | Read |
|---|---|
| what is done and what comes next | the *Status* table at the top of [`planning/gfw_analysis_plan.qmd`](planning/gfw_analysis_plan.qmd) |
| how an analysis phase works, and its gate | that phase's section of the same plan |
| why something was decided, and when | [`planning/decisions.md`](planning/decisions.md), by decision ID (D-001…); notes in the plan and the qmds cite these IDs |
| what a file or column means | [`references/data_dictionary.md`](references/data_dictionary.md) |
| how vessels are screened and corrected | [`planning/vessel_filtering_plan.qmd`](planning/vessel_filtering_plan.qmd) |
| how a vessel decision reaches the analysis sets | [`planning/vessel_decision_flow.qmd`](planning/vessel_decision_flow.qmd) |
| how a new GFW pipeline version is handled | [`planning/gfw_pipeline_v5_plan.qmd`](planning/gfw_pipeline_v5_plan.qmd), and *GFW pipeline versions* in the data dictionary |
| where any file is read or written | [`r/paths.R`](r/paths.R): every path, in one list |
| the archived Python analysis | [`archive/README.md`](archive/README.md) |

### Layout

```
r/                          workflow qmds in run order (00–10, with 02a and 05a), shared *_helpers.R, paths.R
  tests/testthat/           tests for the shared code; schema checks on references/
references/                 tracked: hand-made decision files, Ørsted dates, GARFO codes,
                            generated *_{pipeline}.csv crosswalk, permit groups and roster,
                            data dictionary, basemap
planning/                   the analysis plan, the decisions log, the vessel and v5 plans
data/sf/                    tracked spatial layers: AOI, leases and turbine files (owf/),
                            grid (fishnet/{pipeline}/), bathymetry, Ørsted infrastructure
data/raw/                   gitignored: GFW pulls (gfw/{pipeline}/) and vessel evidence
data/interim/, processed/   gitignored: everything the qmds derive, by pipeline version
reports/                    gitignored: figures and tables from 06 onward, by pipeline version
archive/                    frozen Python implementation and its written output
```

Data flows one way: the pull (01) → grid (02) → infrastructure covariates (02a) → vessel review (03, writes `references/`) → classification (04) → analysis tables (05) → rasters for other GIS work (05a, an output only) → the analysis phases (06–10) → `reports/`. Everything made from a pull is filed under its GFW pipeline version (`v4` today).

`planning/post_filter_review.qmd`, `planning/work-plan-appendices.md` and `planning/gridcell_decision.R` are earlier working notes, kept for the record.

## What ships with the clone, and what does not

**Committed:** the spatial layers under `data/sf/` (AOI, lease areas and the 3,376-cell analysis grid in EPSG:32619), everything in `references/`, and the archived Python analysis with its poster figures.

**Not committed** (`data/raw/`, `data/processed/`, `data/interim/` are gitignored):

- the GFW extracts (`data/raw/gfw/`), which need a GFW API token to pull;
- the GARFO permit lists and the GFW identity / USCG PSIX lookup caches (`data/raw/vessel_evidence/`), which only 03 reads;
- everything the qmds generate from them;
- rendered qmd output: the HTML, its `*_files/` folders (figures and page libraries) and Quarto's intermediate files. Render the qmds to see them.

GFW reprocesses its data and relabels vessels between pulls, so a new pull will not reproduce the 2026-10-06 pull the decisions in `references/` were made against. That pull is GFW pipeline **v4**. Everything made from a pull is filed under its pipeline version (`data/raw/gfw/v4/`, `references/vessel_crosswalk_v4.csv`, and so on), and every qmd takes `-P pipeline:<version>` (default `v4`, set in `r/paths.R`); see *GFW pipeline versions* in `references/data_dictionary.md`. To reproduce the analysis tables exactly, use a copy of that pull: put it in `data/raw/gfw/v4/`, then render 02 and 04. That needs neither the GARFO files nor a token.

## Requirements

- **R 4.5.2**, the version `renv.lock` was made with (CI uses the same). Another 4.5.x release should work; R 4.6 or later is untested, so if you have several versions installed, open the project with 4.5.2.
- **[renv](https://rstudio.github.io/renv/)**. `renv.lock` pins every package, including `gfwr` 3.0 from the Global Fishing Watch r-universe and `testthat`. Each qmd ends with a *Session info* section (`sessionInfo()` and `renv::diagnostics()`), so every render records the R and package versions it ran with.
- **Quarto** (developed against 1.10).
- **A Global Fishing Watch API token**, only for a new pull (01) or new identity lookups (03). Request one at <https://globalfishingwatch.org/our-apis>.
- **Python 3.12** and [uv](https://docs.astral.sh/uv/), only to reproduce the archived analysis under `archive/`.

## Running it

From the repository root:

1. **Set up R 4.5.2** by running `r/00_setup.R` line by line. It runs `renv::restore()`, then opens the project `.Renviron` (gitignored) for the token:

   ```
   GFW_TOKEN=your_token_here
   ```

   `renv` activates itself through the committed `.Rprofile`, so opening the project in R, RStudio or Positron picks it up.

2. **Get the raw pull.** Either copy the 2026-10-06 extracts into `data/raw/gfw/v4/`, or make a new pull, naming its folder and GFW dataset version: `quarto render r/01_pull_gfw.qmd -P pipeline:v5 -P dataset_version:v5.0`.

3. **Render the workflow.** `quarto render r/` runs 02 to 10 in order. Without the GARFO files and caches, skip 03; 04 uses the crosswalk committed in `references/`:

   ```sh
   quarto render r/02_build_grid.qmd
   quarto render r/02a_infrastructure.qmd
   quarto render r/04_classify_aggregate.qmd
   ```

   then render 05 onward one at a time in the same way. 08's permutation tests take about 3 h on a first run and 10's model fits can take minutes each; both are cached, so later renders are fast.

   Every path is repo-relative and each qmd finds the repo root itself, so the qmds also run chunk by chunk in an IDE.

4. **To change a vessel decision**, edit `references/vessel_decisions.csv` or `vessel_gear.csv` (or mark rows in 03's review sheets), re-render 03 to regenerate the crosswalk, then render 04. How a decision travels to the analysis sets is in `planning/vessel_decision_flow.qmd`.

### The archived Python analysis

```sh
uv sync --locked
cd archive/reports
uv run quarto render
```

Run Quarto through `uv run` so it resolves the project interpreter rather than a system Python. The renders are frozen and the cache is committed, so this rebuilds the reports from a bare clone without a token or the extracts.

## Tests

```r
testthat::test_dir("r/tests/testthat")
```

```sh
uv run python -m pytest
```

The R tests cover the stage boundaries, the analysis window, `read_gfw()` coordinate snapping, the gear map, crosswalk and gear validation and `classify()`. They also check the schema of every tracked file in `references/`, and that the committed crosswalk matches its inputs. The Python tests validate the archived package. Both run on a bare clone, and CI (`.github/workflows/tests.yml`) runs both on every push to `main` and on pull requests.

## Notes on reproducibility

- **Paths resolve from the repository root.** There are no absolute paths in `r/`, `archive/python/src` or `archive/reports`; every R path lives in `r/paths.R`.
- **Vessel classification is data, not code.** Every vessel decision is a row in a tracked CSV in `references/`, schema-checked by the tests and validated again on every run. Records are matched on MMSI, never on vessel name, because one hull broadcasts several names and one name can belong to several hulls.
- **The crosswalk cannot go stale silently.** 04 rebuilds it from its inputs and stops if it differs from the committed file.
- **Line endings are fixed** by `.gitattributes`, so files edited on Windows and elsewhere diff cleanly.
- **Both environments are locked**, `renv.lock` for R and `uv.lock` for the archived Python analysis.
- **R renders are not frozen or committed**, because they read data that Quarto does not track and are rebuilt from the qmds. The archived Python reports are frozen (`freeze: auto`) and their cache under `archive/reports/_freeze/` is committed.
- **Permutation-based statistics in the archived analysis are seeded** (`config.RANDOM_SEED`). The archived arcpy workflow set no seed and could not be reproduced.

## Citation

See `CITATION.cff`. Global Fishing Watch data are licensed CC BY-SA 4.0 and must be attributed separately.

## License

MIT — see `LICENSE`.
