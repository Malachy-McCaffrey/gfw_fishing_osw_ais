# Spatiotemporal Responses of AIS-Broadcasting Fishing Vessels to Offshore Wind Development in Southern New England

Geospatial analysis and statistical modeling workflows to quantify AIS vessel presence and apparent fishing effort proximal to three Orsted offshore wind projects in Southern New England. Pre-processed AIS vessel presence and apparent fishing effort data accessed from Global Fishing Watch 4Wings API via gfwr package. This research is in fulfillment of my master's thesis.

**Status:** the analysis was developed in Python through the thesis write-up and poster. Active development has since moved to an R-only workflow in `r/`. The R workflow currently runs from the data pull through vessel classification to the cell tables the spatial analysis will read; the downstream analysis is not yet written. The completed Python analysis is archived, not deleted — still reproducible, see `archive/README.md`.

---

## The R workflow

Files in `r/` are numbered in run order. `r/_quarto.yml` lists the render order, so `quarto render r/` runs 02 → 03 → 04.

| Step | File | What it does | Needs |
|---|---|---|---|
| 00 | `00_setup.R` | Restores the R environment and stores the GFW token. Run once per machine. | — |
| 01 | `01_pull_gfw.qmd` | Pulls daily 0.01° vessel presence (VP) and apparent fishing effort (AFE) for the AOI from the GFW 4Wings API, one calendar year per request, and writes the raw extracts and `pull_info.csv`. Not in the default render: it overwrites the raw data. | GFW token |
| 02 | `02_build_grid.qmd` | Rebuilds GFW's 0.01° grid from the lower-left cell corners, reprojects it to UTM 19N, flags cells against the AOI, builds queen-contiguity neighbours, and writes raw-data (all vessel types) cell tables. | Raw pull |
| 03 | `03_review_vessels.qmd` | The analyst's vessel review. Screens for misclassified vessels, gathers evidence (GARFO permits, GFW identity API, USCG PSIX), writes review sheets, and turns decisions into `references/vessel_crosswalk.csv` and `references/vessel_permit_groups.csv`. The only step that writes to `references/`. | Raw pull, GARFO permit lists, API caches |
| 04 | `04_classify_aggregate.qmd` | Applies the crosswalk and gear corrections to every record, builds the **Strict** (GFW's `FISHING` label) and **Primary** (verified) analysis sets, and writes the classified records and zero-filled cell × stage / cell × month tables, with and without gear class. Stops if the crosswalk is out of date. | Raw pull, grid, `references/` |

Shared code, sourced by every qmd: `paths.R` (every path; each can be overridden with a Quarto parameter), `gfw_helpers.R` (development stages, analysis window, `read_gfw()`, gear classes) and `vessel_helpers.R` (crosswalk build and validation, `classify()`).

**Analysis window:** 2016-01-01 to 2026-08-31, in three development stages (`dev_stages` in `r/gfw_helpers.R`):

| Stage | Window | Months | |
|---|---|---|---|
| 1 | 2016-01-01 → 2020-09-30 | 57 | Pre-monitoring baseline |
| 2 | 2020-10-01 → 2023-03-31 | 30 | South Fork Wind fisheries monitoring began 10/2020 |
| 3 | 2023-04-01 → 2026-08-31 | 41 | SFW seabed preparation began 04/2023; construction and operation across SFW, RWF and SRW |

The pull runs to 2026-09-30, but the window ends on 2026-08-31, the last day Ørsted's survey-trip records cover. After that date, survey work by chartered fishing vessels would be counted as fishing.

## What else is here

| Path | Role |
|---|---|
| `references/` | Tracked inputs to the vessel classification (removal list, Ørsted survey dates, hand-made vessel and gear decisions, GARFO permit codes), the generated crosswalk and permit groups, and the [data dictionary](references/data_dictionary.md). |
| `data/sf/` | Committed spatial layers: the AOI, the Ørsted lease areas, and the analysis grid (`fishnet/gfw_grid_utm19n.gpkg`, written by 02). |
| `planning/` | Design record: the vessel-classification plan and decision flow, the grid-cell diagnostics, and the archived work-plan appendices. |
| `r/tests/` | `testthat` tests for the shared R code and schema checks on every tracked file in `references/`. |
| `archive/` | **The complete, frozen Python implementation and its written output.** Superseded, not deleted; see `archive/README.md`. |

## What ships with the clone, and what does not

**Committed:** the spatial layers under `data/sf/` (AOI, lease areas and the 3,376-cell analysis grid in EPSG:32619), everything in `references/`, and the archived Python analysis with its poster figures.

**Not committed** (`data/raw/`, `data/processed/`, `data/interim/` are gitignored):

- the GFW extracts (`data/raw/gfw/`), which need a GFW API token to pull;
- the GARFO permit lists and the GFW identity / USCG PSIX lookup caches (`data/raw/vessel_evidence/`), which only 03 reads;
- everything the qmds generate from them.

GFW reprocesses its data and relabels vessels between pulls, so a new pull will not reproduce the 2026-10-06 pull the decisions in `references/` were made against. To reproduce the analysis tables exactly, use a copy of that pull: put it in `data/raw/gfw/`, then render 02 and 04. That needs neither the GARFO files nor a token.

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

2. **Get the raw pull.** Either copy the 2026-10-06 extracts into `data/raw/gfw/`, or make a new pull with `quarto render r/01_pull_gfw.qmd`.

3. **Render the workflow.** `quarto render r/` runs 02, 03 and 04 in order. Without the GARFO files and caches, skip 03; 04 uses the crosswalk committed in `references/`:

   ```sh
   quarto render r/02_build_grid.qmd
   quarto render r/04_classify_aggregate.qmd
   ```

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
- **R renders are not frozen**, because they read data that Quarto does not track. The archived Python reports are frozen (`freeze: auto`) and their cache under `archive/reports/_freeze/` is committed.
- **Permutation-based statistics in the archived analysis are seeded** (`config.RANDOM_SEED`). The archived arcpy workflow set no seed and could not be reproduced.

## Citation

See `CITATION.cff`. Global Fishing Watch data are licensed CC BY-SA 4.0 and must be attributed separately.

## License

MIT — see `LICENSE`.
