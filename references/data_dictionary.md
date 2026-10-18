# Data Dictionary

Every field the analysis reads or produces. Source data is gitignored; see
[Provenance](#provenance) to regenerate it.

---

## Source data

### `data/raw/gfw/gfw_{vp,afe}_id.csv`

Unfiltered API output, 18 columns. One row = one vessel × one 0.01° cell × one day.

| Column | Type | Description |
|---|---|---|
| `Lat`, `Lon` | float | Lower-left corner of the 0.01° cell, WGS 84 (EPSG:4326). The cell spans `Lon`–`Lon + 0.01`, `Lat`–`Lat + 0.01`. Values carry float32 noise (e.g. `-71.209999`); snap with `round(x / 0.01)`, never `floor()`. |
| `Time Range` | date | The day the record covers |
| `Vessel ID` | string | GFW identity **segment** UUID. Not a stable hull identifier — one MMSI can carry up to five. Do not use for vessel counts. |
| `Flag` | string | ISO3 registration |
| `Vessel Name` | string | Self-reported; varies for the same hull. Not reliable for filtering. |
| `Entry Timestamp`, `Exit Timestamp` | datetime (UTC) | Bounds of the identity segment |
| `Gear Type` | string | GFW gear label. Fixed per vessel; see [Gear classes](#gear-classes). |
| `Vessel Type` | string | FISHING, PASSENGER, CARGO, SEISMIC_VESSEL, CARRIER, BUNKER, GEAR, OTHER |
| `MMSI` | string | Maritime Mobile Service Identity. **The counting unit.** |
| `IMO` | string | Mostly null |
| `CallSign` | string | Self-reported |
| `First/Last Transmission Date` | datetime | AIS transmission history bounds |
| `Vessel Presence Hours` | int, 1–24 | *VP file only.* Count of hours with ≥1 AIS position. **Not** an integrated duration. |
| `Apparent Fishing Hours` | float, 0–25.3 | *AFE file only.* Hours classified as fishing by GFW's behavioural model. |
| `Development Stage` | string | `Stage 1` / `Stage 2` / `Stage 3`, derived in the R pull |
| `Year Month` | date | First of month, derived |

### `data/raw/gfw/pull_info.csv`

Written by the pull alongside the raw files: `pull_date` (the day the pull
ran), `query_start` / `query_end` (the date range requested) and `vp_rows` /
`afe_rows`. `03_classify_vessels.qmd` reads `pull_date` from it; for pulls
made before the file existed it falls back to the raw VP file's modification
date, with a warning.

### `data/processed/gfw/gfw_{vp,afe}{1,2,3}_*_sub.csv`

Cleaned per-stage files — what the analysis actually reads. Same schema minus
`Entry`/`Exit Timestamp`, `IMO`, `CallSign`, and the transmission dates (12 columns).

Filtering applied by the earlier R pull (`gfw_vp_afe_dataPull_090126.Rmd`, since superseded by `r/03_classify_vessels.qmd`):

- VP only: restricted to `Vessel Type == "FISHING"`
- Both: 34 named Ørsted survey/safety vessels removed for Stages 2–3 only
- Both: two misclassified cargo vessels removed, all stages
- AFE only: records at or below 0.32 hours removed

### Spatial layers

| File | CRS | Description |
|---|---|---|
| `data/sf/aoi/Orsted_AOI.shp` | EPSG:4326 | Study boundary — dissolved union of the SFW + RWF + SRW 10 km buffers |
| `data/sf/owf/{SFW,RWF,SRW}.shp` | EPSG:3857 | Ørsted lease areas. **Reproject before use.** |
| `data/sf/owf/{VW1,VW1_Buffer,SRW_Buffer}.shp`, `SNE_OWFs.shp` | EPSG:3857 | **Not used.** Vineyard Wind is not an Ørsted project and lies outside the AOI; `*_Buffer` are AOI-construction intermediates. |

---

## Derived fields

### Gear classes {#gear-classes}

Assigned by `config.GEAR_CLASS_MAP`. `Gear Type` is a fixed per-vessel registry
attribute, so this is a lookup, not an inference.

| Class | GFW `Gear Type` values |
|---|---|
| `MOBILE` | TRAWLERS, DREDGE_FISHING, OTHER_PURSE_SEINES, TUNA_PURSE_SEINES, PURSE_SEINES, TROLLERS, DRIFTING_LONGLINES |
| `FIXED` | SET_GILLNETS, POTS_AND_TRAPS, SET_LONGLINES, FIXED_GEAR |
| `POLE_AND_LINE` | POLE_AND_LINE — kept separate; indicates recreational and for-hire charter vessels, not a commercial SNE fishery |
| `UNRESOLVED` | FISHING, INCONCLUSIVE, NA — fishing vessels whose gear GFW did not determine |
| `EXCLUDED` | PASSENGER, OTHER, CARGO, SEISMIC_VESSEL, CARRIER, BUNKER, GEAR — dropped on load |

### Per-cell summary (`aggregate.summarize_stage`)

| Field | Description |
|---|---|
| `cell_id` | `"ix_iy"`, where `ix = round(Lon / 0.01)` and `iy = round(Lat / 0.01)` from GFW's lower-left coordinates (`02_build_grid.qmd`); the join key throughout. The archived Python pipeline used a zero-based positional index into the old centroid-based grid instead. |
| `SumVesselHrs` / `SumFishingHrs` | Total hours in the cell for that stage and gear class |
| `SumVesselCount` | Distinct **MMSIs** |
| `SumVesselIdCount` | Distinct Vessel IDs — sensitivity column only |
| `TotalRecords` | Row count |
| `MonthMeanVesselHrs` / `MonthMeanFishingHrs` | Sum ÷ **stage length** (57 / 30 / 42). Not per-cell active months, so zeros are structural. |
| `MMVH_sqrt` / `MMFH_sqrt` | Square root of the above. The primary analysis surface. |

### Spatial statistics (`spatial_stats.run_stage`)

ArcGIS-compatible names, so downstream comparison code still applies.

| Field | Description |
|---|---|
| `GiZScore` | Getis-Ord Gi\* z-score, **binary weights** |
| `GiPValue` | Two-tailed (esda reports one-tailed; doubled) |
| `Gi_Bin` | −3…+3. Sign = direction, magnitude = confidence (99/95/90%) after BH-FDR |
| `LMiIndex`, `LMiZScore`, `LMiPValue` | Local Moran's I, 999 seeded permutations |
| `COType` | HH / HL / LH / LL after BH-FDR; empty if not significant |

### Change classes (`transitions.change_classes`)

Mutually exclusive, so counts sum to the grid size: `stable hot`, `gained hot`,
`lost hot`, `hot to cold`, `cold to hot`, `stable cold`, `gained cold`,
`lost cold`, `no change`.

---

## Development stages

| Stage | Window | Months | Rationale |
|---|---|---|---|
| 1 | 2016-01-01 → 2020-09-30 | 57 | Pre-monitoring baseline |
| 2 | 2020-10-01 → 2023-03-31 | 30 | South Fork Wind fisheries monitoring began 10/2020 |
| 3 | 2023-04-01 → 2026-09-30 | 42 | Seabed prep for South Fork Wind began 04/2023 |

Stage 3 runs through the end of the current pull — data ends 2026-09-30.

The R code takes these windows from one place, `dev_stages` in
`r/gfw_helpers.R`; a record's stage comes from its `Year Month`. Change
them there, not in individual scripts.

---

## Supplementary vessel removals

Applied in Python on top of the R pipeline's filter, keyed on **MMSI** because
name matching cannot reliably remove a vessel (one hull emits several name
strings). See `00b-plan-revisions.qmd`.

The list lives in `references/vessel_removals.csv` -- tracked, unlike `data/`,
so the filter ships with the repository. Both languages read that one file:
Python via `io.load_removal_list()`, R via the validation block in the pull
script. Adding a vessel, or changing how one is treated, is a one-row edit to
the CSV; nothing vessel-specific is hard-coded in either language.

| Column | Meaning |
|---|---|
| `Vessel_Name` | Reported name. For the log only -- matching is on MMSI |
| `MMSI` | 9 digits, unique within the file |
| `Operation` | `Safety` or `Survey` -- the charter role |
| `Scope` | `stages_2_3` or `all_stages`, see below |
| `Identified_By` | Source of the identification, free text: e.g. `Anna Turano (Orsted) email`, `SFW PSO PAM Report 2024 Appendix A`, `orsted_fv_survey_dates_aug2026.csv`, `marinetraffic`, `known_research_vessel`, `manual identification` |
| `Confidence` | `confirmed`, `probable`, `possible`. Read only by the archived Python pipeline |
| `Decision` | `Y` when the MMSI also has rows in `vessel_decisions.csv`, which replace its removal-list row. A note only; no code reads it |
| `Notes` | Free text |

`Scope` carries the stage-conditional treatment:

- **`stages_2_3`** -- chartered working fishing hulls. Stages 2-3 are removed,
  Stage 1 is retained as genuine fishing activity.
- **`all_stages`** -- not a fishing vessel under any circumstances, so there is
  no baseline worth keeping. Currently four vessels: NOAA Gloria Michelle, a
  NOAA Fisheries research vessel that GFW classes as FISHING/TRAWLERS; the
  cargo vessels Sunnanvik (GFW: FISHING/INCONCLUSIVE) and Cygnus (GFW: CARGO);
  and Celtic, an Ørsted safety-charter port tender (GFW: OTHER).

Both readers validate the file on load and fail loudly, listing every problem
found rather than stopping at the first: blank names, an MMSI that is not 9
digits, duplicate MMSI, unknown `Scope` or `Confidence` values, a `Date_Added`
that is not ISO. `load_removal_list()` logs the breakdown by scope and
confidence on every read; the list currently holds 45 vessels.

In `03_classify_vessels.qmd`, a `stages_2_3` vessel's open-ended exclusion
is replaced by its actual survey windows when it appears in the Ørsted
survey-date files; see [Ørsted survey dates](#orsted-survey-dates).

---

## Vessel classification files

Used by `r/03_classify_vessels.qmd`.

| File | Tracked | Role |
|---|---|---|
| `references/vessel_decisions.csv` | yes | Hull and activity decisions, edited by hand. Crosswalk columns plus `decision` (`accept` / `reject`) and `decided_on`. A decision for a removal-list MMSI replaces that vessel's removal-list row. |
| `references/vessel_gear.csv` | yes | Gear corrections, edited by hand: `MMSI`, optional `valid_from`/`valid_to`, `gear_class` (`MOBILE` / `FIXED` / `POLE_AND_LINE` / `UNRESOLVED`), `basis`, `evidence_ref`, `decision`, `decided_on`. An accepted row overrides GFW's gear for that vessel's records in the window; independent of the crosswalk, so a charter vessel's gear can be fixed without touching its exclusion. |
| `references/orsted_fv_survey_dates_*.csv` | yes | Ørsted's lists of survey trips by chartered fishing vessel, kept as delivered; every file matching the pattern is read. See [Ørsted survey dates](#orsted-survey-dates). |
| `references/orsted_survey_vessels.csv` | yes | Maps each vessel name in the survey files to an MMSI: `survey_name` (upper case, F/V prefix removed), `MMSI`, `Vessel_Name`, `ais_name`, and the match evidence `survey_days` / `ais_days` (survey days on which that MMSI has AIS records). Add a row when a new file brings a new name; the run stops on any unmapped name. |
| `references/vessel_crosswalk.csv` | yes | **Generated** every run from `vessel_removals.csv`, the survey-date files and the accepted decisions (a decision replaces survey-date and removal-list rows; survey-date rows replace removal-list rows). One row per MMSI per validity window (`valid_from`–`valid_to`), with `hull_class` and `activity_excluded`, and GFW's labels in the current pull. Inside the window, `hull_class` overrides GFW's `Vessel Type` when deciding set membership (`fishing` adds a vessel GFW does not type FISHING; `non_fishing` / `gear_marker` removes one it does); the `Vessel Type` column itself is never rewritten. Do not edit. |
| `references/garfo_permit_codes.csv` | yes | Meaning of each GARFO fishery permit code: permit type, gear hint, open access, NOAA source |
| `data/processed/vessel_review/vessel_review.csv` | no | **Generated** hull/activity review sheet: candidates, evidence and a suggested decision per vessel. Rows marked `accept` / `reject` are copied into `vessel_decisions.csv` on the next run. |
| `data/processed/vessel_review/gear_review.csv` | no | **Generated** gear review sheet: every removal-list fishing vessel, plus fishing vessels with unresolved GFW gear or GARFO permits that disagree, with a suggested gear class. Marked rows are copied into `vessel_gear.csv` on the next run. |
| `data/raw/vessel_evidence/` | no | GFW identity API cache (queried IDs with date, status and dataset version) and the GARFO permit lists in `registries/` |

### Ørsted survey dates {#orsted-survey-dates}

`references/orsted_fv_survey_dates_aug2026.csv`: one row per vessel per survey
trip, 595 trips from 2020-10-28 to 2026-08-11.

| Column | Meaning |
|---|---|
| `Project` | Survey area: `SFW`, `REV`, `SRW`, `North Control Area`, `South Control Area`, `NEP` (all project areas), or a combination such as `REV / SRW` |
| `Departure Date`, `Return Date` | ISO dates of the trip, inclusive; one-day trips have equal dates |
| `Vessel` | Vessel name as written by Ørsted. Spellings vary (`F/V Heather Lynn`, `Cailyn and Maren`), and some cells list two vessels separated by a comma |
| `Note` | Free text (one row) |

The file also has blank spacer rows and two empty trailing columns, which are
ignored.

How `03_classify_vessels.qmd` uses it:

- Each trip becomes part of a crosswalk window for its MMSI (`hull_class =
  fishing`, `activity_excluded = TRUE`, `Operation = Survey`, `Identified_By =
  orsted_survey_dates`, `Confidence = confirmed`). A vessel's trips that
  overlap or fall on consecutive days are merged into one window, and the
  projects are listed in `Notes`. Dates are used as given: they are not
  shifted to UTC.
- For each survey vessel these windows replace its open-ended removal-list
  row, so its records before, between and after its listed trips count as
  fishing. A survey vessel need not be on the removal list (e.g. Cailyn &
  Maren II, 338538875): its windows come from the file alone.
- **Survey work only.** The file does not date guard or scout work, so
  vessels listed as `Safety` in `vessel_removals.csv` keep their open-ended
  removal-list row.
- **Incomplete.** The file runs through August 2026; dates for September and
  October 2026 are still to come. `survey_dates_through` (Parameters chunk,
  currently 2026-08-31) marks the last day covered, and the run stops if a
  trip ends later. Records after it are not excluded, so any surveys there
  count as fishing until their dates arrive. When a new file arrives, add it
  to `references/` with the same name pattern, map any new names, and move
  `survey_dates_through`.
- **Arch Angel** matches MMSI 368407550 (GFW type PASSENGER). The other
  removal-list Archangels (367478020, 368308710) have no AIS records on its
  survey days.

---

## Provenance

Source CSVs regenerate from `r/01_pull_gfw.qmd` with a
valid `GFW_TOKEN`, via `gfwr` v3.0:

```r
gfw_ais_presence(spatial_resolution = "HIGH",     # 0.01 degree
                 temporal_resolution = "DAILY",
                 group_by = "VESSEL_ID",
                 start_date = ..., end_date = ..., # 11 calendar-year calls
                 region_source = "USER_SHAPEFILE",
                 region = orsted_aoi)
```

`gfw_ais_fishing_hours()` takes identical arguments. No `filter_by` is applied,
so no server-side flag, gear or confidence filtering occurs.

**Two known issues when regenerating:**

1. The script writes to `data/interim/gfw`; the analysis reads `data/processed/gfw`.
2. `rmOrsted` matches on `Vessel Name` and leaks. Rebuild it on MMSI.

Data © Global Fishing Watch, CC BY-SA 4.0. Analysis environment pinned in `uv.lock`.
