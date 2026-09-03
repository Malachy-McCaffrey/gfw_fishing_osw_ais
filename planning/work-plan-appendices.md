# Work plan — appendices (private)

Implementation bookkeeping split out of `reports/00-work-plan.qmd` on 2026-09-02.
**This file is gitignored** (`planning/` rule in `.gitignore`). It is working reference,
not part of the published record.

Companion documents:
- `reports/00-work-plan.qmd` — the substantive plan (context, findings, decisions, phases)
- `C:\Users\mmccaffrey17\.claude\plans\fancy-brewing-seahorse.md` — the original approved plan

---

## Appendix A — Files touched

**New**

- `python/src/gfw_fishing_osw_ais/config.py` — paths, stage windows, gear map, CRS, `RANDOM_SEED = 42`
- `python/src/gfw_fishing_osw_ais/io.py` — `load_grid()`, `load_stage()`, `load_owf()`, `load_aoi()`
- `python/src/gfw_fishing_osw_ais/explore.py` — Phase 1 distribution diagnostics
- `python/src/gfw_fishing_osw_ais/aggregate.py` — spatial join + per-cell rollup
- `python/src/gfw_fishing_osw_ais/weights.py` — lattice-derived Queen contiguity
- `python/src/gfw_fishing_osw_ais/spatial_stats.py` — Moran / Gi\* / Local Moran's
- `python/src/gfw_fishing_osw_ais/transitions.py` — stage-change analysis
- `python/src/gfw_fishing_osw_ais/viz.py` — maps and figure assembly
- `reports/_quarto.yml`
- `reports/01-data-exploration.qmd`
- `reports/02-spatial-analysis.qmd`
- `references/data_dictionary.md`

**Modified**

- `pyproject.toml` — add `scipy`, `statsmodels` (`scipy` is currently only a transitive
  dependency of `scikit-learn`)

**Read-only inputs**

- `data/shp/aoi/Orsted_sqGrid_utm19n.shp` — 3,375 cells, EPSG:32619
- `data/shp/aoi/Orsted_AOI.shp` — EPSG:4326, single polygon, ~3,024.7 km²
- `data/shp/owf/{SFW,RWF,SRW,SNE_OWFs}.shp` — EPSG:3857, reproject before use
- `data/interim/gfw/gfw_{vp1,vp2,vp3}_fv_sub.csv` — 23,078 / 28,116 / 34,906 rows
- `data/interim/gfw/gfw_{afe1,afe2,afe3}_id_sub.csv` — 3,264 / 4,617 / 9,430 rows

**Untouched** — everything under `python/scripts/arcpy/` and `r/` stays as archived
ArcGIS/R provenance. Do not refactor or "fix" those; they document how the committed
data was produced.

---

## Appendix B — Verification checklist

1. **Regression against arcpy.** Stage 1 `MonthMeanVesselHrs` must give mean **0.1624**,
   median **0.0909** — confirmed, reproduces arcpy to 4 decimals.

   Matched-cell counts are **3,163 / 3,218 / 3,268** for VP Stages 1/2/3, against
   the arcpy figures of 3,164 / 3,218 / 3,269. Both deltas are explained, and
   these are the current targets — a drift away from them means the spatial join
   or the month denominator has changed.

   | | arcpy (2026-07-21) | current | Reason for difference |
   |---|---:|---:|---|
   | Stage 1 | 3,164 | 3,163 | 8 rows labelled `GEAR` (AIS-transmitting fishing gear/buoys, not vessels) uniquely occupied one cell. Classified `EXCLUDED` and dropped — correct, since a gear buoy is not a fishing vessel. Worth 8 hours of 24,119. |
   | Stage 2 | 3,218 | 3,218 | Exact match. Closed window, unaffected by the re-pull. |
   | Stage 3 | 3,269 | 3,268 | The arcpy run predates the 2026-09-01 R re-pull. Stage 3 is the open-ended window and its data now extends to 2026-07-13, six weeks past the arcpy run. Verified not a join artifact: `within` and `intersects` agree exactly, zero unmatched points, no duplicate matches. |

   Re-verify against arcpy only for Stages 1 and 2; Stage 3 will keep drifting with
   every re-pull and should not be pinned to a historical figure.

2. **Weights guard.** Assert all three:
   ```python
   assert w.n_components == 1
   assert w.mean_neighbors > 7      # expect 7.80
   assert len(w.islands) == 0
   ```
   Catches any regression to polygon-based contiguity, which yields mean 1.96
   neighbours across 74 components. This is the single most important guard in the
   codebase — a silent regression here invalidates every hotspot result.

3. **No arcpy.** `grep -rn "import arcpy" src/ reports/` must return nothing.

4. **Determinism.** Run `spatial_stats.py` twice; `Moran_Local` p-values must be
   byte-identical. Requires `seed=42` on every `Moran_Local` call.

5. **Sanity.** Global Moran's I strongly positive (~0.7) for VP. Gear-class hour totals
   must sum to the dataset total per stage (mobile + fixed + pole_and_line +
   unresolved + excluded == total).

6. **CRS alignment.** Assert every layer is EPSG:32619 at plot time. The OWF shapefiles
   arrive as EPSG:3857; a missed reprojection places lease areas roughly 4,500 km
   off-map, which is obvious — but a *partial* miss (some layers reprojected, some not)
   is not, so assert per layer rather than eyeballing the result.

7. **End to end.** `quarto render reports/` produces all HTML documents with figures.

---

## Appendix C — Explicitly out of scope

Deferred deliberately. Each has a stated reason so the decision is not relitigated
under time pressure.

| Item | Reason | Estimated cost |
|---|---|---|
| MMSI→gear crosswalk + resolved-only sensitivity | Needs an external registry (GARFO / USCG PSIX) and manual adjudication. Deferred to thesis. | 13–20 h |
| ISA distance-band peak search (`find_isa_peak`, `gfw_vp_fv_spatial_stats_workflow.py:190-245`) | Queen contiguity is justified because the grid cells *are* the analysis units. | 2–4 h |
| Space-time cube / emerging hotspots / Mann-Kendall | Temporal completeness is 0.157 — "weak" by the project's own threshold in `gfw_vp_fv_stcDiagnostics.ipynb`. 84% of bins would be estimated. | 6–10 h |
| Fixing `YearMonth` vs `Year Month` bug (`Rmd:416-424`) | The R pull is not being re-run. Will error on a fresh knit — fix before any re-pull. | 15 min |

---

## Appendix D — Effort estimate for the deferred gear crosswalk

Kept for thesis planning. Join path is
`MMSI → Vessel Name / CallSign` (both already in the CSVs) → NOAA GARFO permit records
or USCG PSIX → gear category. GARFO keys on USCG documentation number rather than MMSI,
so name/callsign matching with manual QA is the irreducible step.

| Task | Estimate |
|---|---|
| Crosswalk table scaffold + join + provenance columns | 3–4 h |
| Acquire and reconcile GARFO / PSIX source | 2–3 h |
| Adjudicate top 33 AFE MMSIs (→ 90% of the AFE gap) | 2–3 h |
| Extend to all 111 AFE + 158 VP MMSIs | +4–6 h |
| Sensitivity re-run (cheap once pipeline is parameterised) | 1–2 h |
| FAIR provenance documentation | 1–2 h |
| **Full scope** | **13–20 h (~2–3 working days)** |

**Scale of the problem, measured on the cleaned analysis inputs:**

- AFE (`gfw_afe_id_sub.csv`, 17,311 rows / 29,157 h): unresolved is 26.1% of hours,
  from 111 MMSIs. **33 MMSIs cover 90% of unresolved hours.**
- VP (`gfw_vp_fv_sub.csv`): 32.1% unresolved across 404 MMSIs; 158 for 90% coverage.

**Targeted middle path** (if the full crosswalk is too much for the thesis timeline):
crosswalk only the 33 AFE MMSIs and keep three-class for VP. ~4–6 h, closes 90% of the
gap where the headline claim lives.

---

## Appendix E — Reference numbers from exploration

Kept so these do not need recomputing.

**Stage definitions** (`gfw_vp_afe_dataPull_090126.Rmd:396-411`). The 44/43/40 month
comments are correct; the 31/42/37 set elsewhere in the file is stale.

| Stage | Window | Months |
|---|---|---|
| 1 | 2016-01-01 → 2019-08-01 | 44 |
| 2 | 2019-09-01 → 2023-03-01 | 43 |
| 3 | 2023-04-01 → 2026-07-01 | 40 |

**Raw external files** (unfiltered — `data/external/gfw/`)

| | VP | AFE |
|---|---|---|
| rows | 416,533 | 61,637 |
| unique Vessel ID | 14,903 | 521 |
| unique MMSI | 13,366 | — |
| months | 127 (2016-01 → 2026-07) | 124 |
| unique 0.01° cells | 3,375 | 3,200 |
| hours: median / mean / max | 1 / 1.615 / 24 | 1.01 / 1.481 / 25.28 |

**R filtering pipeline** (`Rmd:494-535`)

- AFE: 61,637 → 18,932 (Ørsted vessels, Stages 2–3 only) → 18,906 (cargo) → **17,311** (>0.32 h threshold)
- VP fishing: 137,539 → 86,153 (Ørsted) → **86,100** (cargo)

**Gear class × stage, cleaned inputs (hours)**

AFE:

| | Stage 1 | Stage 2 | Stage 3 |
|---|---|---|---|
| Mobile | 4,866 (74.0%) | 6,180 (75.3%) | 5,844 (40.7%) |
| Fixed | 454 (6.9%) | 666 (8.1%) | 2,179 (15.2%) |
| Unresolved | 822 (12.5%) | 808 (9.8%) | 5,982 (41.6%) |
| Other/inconclusive | 437 (6.6%) | 557 (6.8%) | 363 (2.5%) |

VP:

| | Stage 1 | Stage 2 | Stage 3 |
|---|---|---|---|
| Mobile | 14,335 (59.4%) | 16,425 (56.4%) | 16,372 (43.2%) |
| Fixed | 1,617 (6.7%) | 2,659 (9.1%) | 6,211 (16.4%) |
| Unresolved | 6,868 (28.5%) | 8,544 (29.3%) | 13,860 (36.6%) |
| Other/inconclusive | 1,299 (5.4%) | 1,496 (5.1%) | 1,473 (3.9%) |

**Weights comparison** on `Orsted_sqGrid_utm19n.shp`

| Method | Mean neighbours | Components | Islands |
|---|---|---|---|
| `Queen.from_dataframe` | 1.96 | 74 | 0 |
| `KNN(k=8)` | 8.00 | 1 | 0 |
| Lattice-derived Queen | 7.80 | 1 | 0 |

Lattice Queen neighbour distribution: 3,107 cells with 8; 62 with 7; 35 with 6;
128 with 5; 43 with 4.

**Grid properties**: 3,375 cells, EPSG:32619, bounds
`[297498.0, 4515619.0, 356962.3, 4585215.8]` (~59.5 × 69.6 km). Mean cell area
933,160 m². Mean width 866.5 m, mean height 1130.3 m — cells are *not* square in metres.

**Vessel identity**: 0 Vessel IDs span >1 MMSI; 1,258 MMSIs span >1 Vessel ID (max 5).
Vessel ID / MMSI ratio by stage: 1.129 / 1.064 / 1.047.

**Pole-and-line occupancy**

| | Stage 1 | Stage 2 | Stage 3 |
|---|---|---|---|
| VP cells | 1,030 (30.5%) | 1,249 (37.0%) | 1,439 (42.6%) |
| VP vessels | 66 | 90 | 130 |
| AFE cells | 81 (2.4%) | 149 (4.4%) | 209 (6.2%) |
| AFE vessels / hours | 13 / 144 | 18 / 264 | 31 / 397 |

---

## Appendix F — Known bugs in the archived ArcGIS/R code

Not being fixed (those files are frozen provenance), but recorded so they are not
mistaken for correct patterns during the port.

1. `gfw_vp_stage_grid_summary.py:98` — `os.path.join(PROJECT_GDB, ...)` with an already
   absolute `point_fc`, so `PROJECT_GDB` is silently discarded.
2. Feature-class name mismatch: `_gridSummary`
   (`gfw_vp_monthmeanhrs_distribution_diagnostics.py:51-53`) vs `_summaryGrid`
   (`gfw_vp_stage_grid_summary.py:116-118`). The diagnostics script cannot run as written.
3. `gfw_vp_fv_spatial_stats_workflow.py:543` — undefined `GDB_PATH` in the commented
   geopandas cell.
4. `find_isa_peak` indexes `z[-2]` (`:226`) — crashes if ISA returns fewer than 2 bands.
5. Conceptualization winner selected by z-score alone (`:277`) with no significance
   guard, despite the docstring claiming otherwise (`:22-23`).
6. `YearMonth` vs `Year Month` inconsistency in the Rmd (`:416-424`, `:594`, `:599`,
   `:620`) — committed code does not match the code that produced the CSVs.
7. No random seed anywhere in the arcpy workflow, so its Local Moran's results are not
   reproducible.
8. `key <- Sys.getenv("GFW_TOKEN")` (`Rmd:29`) is dead code; auth flows through
   `gfw_auth()`.
