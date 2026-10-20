# Data Dictionary

Every file the R workflow (`r/`) reads or writes, and the fields in each. GFW
data, GARFO permit lists and lookup caches are gitignored; see
[Provenance](#provenance). Fields used only by the archived Python analysis are
listed under [Archived Python outputs](#archived-python-outputs).

---

## Development stages and the analysis window

| Stage | Window | Months | Rationale |
|---|---|---|---|
| 1 | 2016-01-01 → 2020-09-30 | 57 | Pre-monitoring baseline |
| 2 | 2020-10-01 → 2023-03-31 | 30 | South Fork Wind fisheries monitoring began 10/2020 |
| 3 | 2023-04-01 → 2026-08-31 | 41 | Seabed prep for South Fork Wind began 04/2023; construction and operation across SFW, RWF and SRW |

The windows are defined once, in `dev_stages` in `r/gfw_helpers.R`; change
them there, not in individual scripts. A record's stage comes from its
`Year Month`.

The **analysis window** is the span of the stages, `analysis_start` to
`analysis_end` (2016-01-01 to 2026-08-31). The 2026-10-06 pull runs to
2026-09-30, but 02, 03 and 04 drop records after `analysis_end` when they read
the raw files (`in_analysis_window()`), and say how many they dropped.
2026-08-31 is the last day the Ørsted survey-date files cover (see
[Ørsted survey dates](#orsted-survey-dates)); after it, survey work by
chartered fishing vessels is undated and would count as fishing. The grid is
still built from the whole pull.

---

## Raw data

### `data/raw/gfw/gfw_{vp,afe}_id.csv`

Unfiltered 4Wings API output from `r/01_pull_gfw.qmd`, 16 columns. One row =
one Vessel ID × one 0.01° cell × one day.

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
| `MMSI` | string | Maritime Mobile Service Identity. **The counting unit and the join key for vessel decisions.** Always read as text. |
| `IMO` | string | Mostly null |
| `CallSign` | string | Self-reported |
| `First Transmission Date`, `Last Transmission Date` | datetime | AIS transmission history bounds |
| `Vessel Presence Hours` | int, 1–24 | *VP file only.* Count of hours with ≥1 AIS position. **Not** an integrated duration. |
| `Apparent Fishing Hours` | float | *AFE file only.* Hours classified as fishing by GFW's behavioural model. GFW computes it only for vessels it treats as fishing. |

### `data/raw/gfw/pull_info.csv`

Written by the pull alongside the raw files: `pull_date` (the day the pull
ran), `query_start` / `query_end` (the date range requested, end excluded) and
`vp_rows` / `afe_rows`. 03 and 04 read `pull_date` from it and record it in
the crosswalk; for pulls made before the file existed they fall back to the
raw VP file's modification date, with a warning.

### `data/raw/vessel_evidence/`

Read only by `03_review_vessels.qmd`.

| File | Contents |
|---|---|
| `registries/garfo_permits_YYYY.csv`, `registries/garfo_tuna_permits_2026.csv` | NOAA GARFO permit lists, one per permit year plus the HMS/tuna file. Only vessel fields are read; owner names, telephone numbers and addresses are never loaded. |
| `gfw_identity_queried.csv` | GFW identity API log: every Vessel ID queried, with the date, status and GFW dataset version, so each ID is requested once |
| `gfw_identity_registry.csv`, `gfw_identity_combined.csv` | Parsed registry and combined-source records from those queries |
| `psix_lookups.csv` | USCG CGMIX PSIX lookups by call sign and official number, with the date and status |

---

## Fields derived on read

`read_gfw()` in `r/gfw_helpers.R` reads every column as text, then adds:

| Field | Description |
|---|---|
| `hours` | The file's hours column (VP or AFE), numeric |
| `date` | From `Time Range` |
| `Year Month` | First day of the record's month |
| `Development Stage` | `Stage 1` / `Stage 2` / `Stage 3` from `Year Month`, recomputed even if the file has one |
| `ix`, `iy` | `round(Lon / 0.01)`, `round(Lat / 0.01)`: integer cell indices of the lower-left corner |
| `cell_id` | `"ix_iy"`. The join key between records and the grid throughout; records are joined to cells by this key, never by a spatial join. |

### Gear classes {#gear-classes}

`gear_class_map` in `r/gfw_helpers.R`. `Gear Type` is a fixed per-vessel
registry attribute, so this is a lookup, not an inference. Corrections from
`references/vessel_gear.csv` override it per vessel and window (04).

| Class | GFW `Gear Type` values |
|---|---|
| `MOBILE` | TRAWLERS, DREDGE_FISHING, OTHER_PURSE_SEINES, TUNA_PURSE_SEINES, PURSE_SEINES, TROLLERS, DRIFTING_LONGLINES |
| `FIXED` | SET_GILLNETS, POTS_AND_TRAPS, SET_LONGLINES, FIXED_GEAR |
| `POLE_AND_LINE` | POLE_AND_LINE — kept separate; indicates recreational and for-hire charter vessels, not a commercial SNE fishery |
| `UNRESOLVED` | Anything else (FISHING, INCONCLUSIVE, OTHER, NA, ...) — gear GFW did not determine |

---

## Spatial layers

| File | CRS | Description |
|---|---|---|
| `data/sf/aoi/Orsted_AOI.shp` | EPSG:4326 | Study boundary — dissolved union of the SFW + RWF + SRW 10 km buffers |
| `data/sf/owf/sfw/SFW.shp`, `rwf/RWF.shp`, `srw/SRW.shp` | EPSG:3857 | Ørsted lease areas. **Reproject before use.** A cell is `in_lease` (03) when its centroid falls inside one. |
| `data/sf/owf/vw1/{VW1,VW1_Buffer}.shp`, `srw/SRW_Buffer.shp`, `SNE_OWFs.shp` | EPSG:3857 | **Not used.** Vineyard Wind is not an Ørsted project and lies outside the AOI; `*_Buffer` are AOI-construction intermediates. |
| `data/sf/owf/{sfw,rwf,srw}/turbines/` | GeoJSON EPSG:4326 | Ørsted, as supplied (read only). Mariner layout GeoJSONs (positions, cable routes, lease; SRW preliminary), RWF and SRW foundation-installation CSVs (one row per installation day; encoding detected, Latin-1 or UTF-8), and the SFW PSO monitoring report (installation dates in Table 3). Built into `data/sf/infra/infrastructure.gpkg` by 05 |
| `data/sf/fishnet/gfw_grid_utm19n.gpkg` | EPSG:32619 | The analysis grid, written by `02_build_grid.qmd`. One polygon per 0.01° cell present in the raw VP pull (3,376 cells), built from the lower-left corner and reprojected, so each cell is a parallelogram of about 840 m E–W by 1,110 m N–S. |

Grid fields:

| Field | Description |
|---|---|
| `cell_id`, `ix`, `iy` | As [derived on read](#fields-derived-on-read) |
| `area_km2` | Cell area in UTM 19N; varies slightly by latitude, so normalise hours by it |
| `aoi_frac` | Share of the cell inside the AOI |
| `aoi_class` | `inside` (≥ 0.99), `edge`, or `outside` (0). Outside cells hold real records GFW returned for the AOI query; keep them, and drop them in a sensitivity check. |

Neighbours (built in 02, not saved) are queen contiguity on the UTM grid;
every cell has at least one.

---

## Vessel classification inputs (`references/`)

All tracked. The only files edited by hand are `vessel_decisions.csv`,
`vessel_gear.csv`, `orsted_survey_vessels.csv`, `vessel_removals.csv` and
`garfo_permit_codes.csv`. `r/tests/testthat/test-references.R` checks the
schema of each.

### `references/vessel_removals.csv`

Ørsted charter vessels and other known removals, keyed on **MMSI** because
name matching cannot reliably remove a vessel (one hull emits several name
strings, and one name can belong to several hulls).

| Column | Meaning |
|---|---|
| `Vessel_Name` | Reported name. For the log only — matching is on MMSI |
| `MMSI` | 9 digits, unique within the file |
| `Operation` | `Safety`, `Survey`, `Research` or `Cargo` |
| `Scope` | `stages_2_3` or `all_stages`, see below |
| `Identified_By` | Source of the identification, free text: e.g. `Anna Turano (Orsted) email`, `SFW PSO PAM Report 2024 Appendix A`, `orsted_fv_survey_dates_aug2026.csv`, `marinetraffic`, `known_research_vessel`, `manual identification` |
| `Confidence` | `confirmed`, `probable`, `possible`. Read only by the archived Python pipeline |
| `Decision` | `Y` when the MMSI also has rows in `vessel_decisions.csv`, which replace its removal-list row. A note only; no code reads it |
| `Notes` | Free text |

`Scope` carries the stage-conditional treatment:

- **`stages_2_3`** — chartered working fishing hulls. In the crosswalk they
  are fishing hulls with an activity exclusion from the start of Stage 2, so
  Stage 1 is kept as genuine fishing activity. Survey vessels' exclusions are
  replaced by their dated survey windows; see
  [Ørsted survey dates](#orsted-survey-dates).
- **`all_stages`** — not a fishing vessel under any circumstances, so there is
  no baseline worth keeping. Currently four vessels: NOAA Gloria Michelle, a
  NOAA Fisheries research vessel that GFW classes as FISHING/TRAWLERS; the
  cargo vessels Sunnanvik (GFW: FISHING/INCONCLUSIVE) and Cygnus (GFW: CARGO);
  and Celtic, an Ørsted safety-charter port tender (GFW: OTHER).

`SFW PSO PAM Report 2024.pdf`, cited in `Identified_By`, is not tracked
(`*.pdf` is gitignored); it is the South Fork Wind protected species observer
and passive acoustic monitoring report for 2024, from Ørsted.

### `references/vessel_decisions.csv`

Hull and activity decisions, edited by hand or collected from 03's review
sheet. The [crosswalk columns](#vessel_crosswalk) plus:

| Column | Meaning |
|---|---|
| `decision` | `accept` (the row enters the crosswalk) or `reject` (GFW's label stands; the vessel leaves the review sheet) |
| `decided_on` | ISO date |

A decision for a removal-list MMSI replaces that vessel's removal-list and
survey-date rows; a `reject` for one removes it from the crosswalk.

### `references/vessel_gear.csv`

Gear corrections, edited by hand or collected from 03's gear review sheet.
Independent of the crosswalk, so a charter vessel's gear can be fixed without
touching its exclusion.

| Column | Meaning |
|---|---|
| `decision`, `decided_on` | `accept` sets the gear; `reject` records that GFW's gear was checked and kept |
| `MMSI` | As in the pull |
| `valid_from`, `valid_to` | ISO dates; blank = open-ended. Windows for one MMSI must not overlap |
| `Vessel_Name` | For the log only |
| `gear_class` | `MOBILE` / `FIXED` / `POLE_AND_LINE` / `UNRESOLVED` |
| `basis`, `evidence_ref` | Where the gear came from, e.g. `analyst knowledge`, `GARFO permit`, `GFW registry`, with the hull or permit |
| `gfw_gear_type`, `pull_date` | GFW's gear when the decision was made |
| `Notes` | Free text |

### Ørsted survey dates {#orsted-survey-dates}

`references/orsted_fv_survey_dates_aug2026.csv`: one row per vessel per survey
trip, 595 trips from 2020-10-28 to 2026-08-11, as delivered by Ørsted. Every
file matching `orsted_fv_survey_dates_*.csv` is read.

| Column | Meaning |
|---|---|
| `Project` | Survey area: `SFW`, `REV`, `SRW`, `North Control Area`, `South Control Area`, `NEP` (all project areas), or a combination such as `REV / SRW` |
| `Departure Date`, `Return Date` | ISO dates of the trip, inclusive; one-day trips have equal dates |
| `Vessel` | Vessel name as written by Ørsted. Spellings vary (`F/V Heather Lynn`, `Cailyn and Maren`), and some cells list two vessels separated by a comma |
| `Note` | Free text (one row) |

The file also has blank spacer rows and two empty trailing columns, which are
ignored.

`references/orsted_survey_vessels.csv` maps each vessel name in the survey
files to an MMSI: `survey_name` (upper case, F/V prefix removed), `MMSI`,
`Vessel_Name`, `ais_name`, and the match evidence `survey_days` / `ais_days`
(survey days on which that MMSI has AIS records). Add a row when a new file
brings a new name; the run stops on any unmapped name.

How the crosswalk uses them (`build_crosswalk()` in `r/vessel_helpers.R`):

- A vessel's trips that overlap or fall on consecutive days are merged into one
  window (`hull_class = fishing`, `activity_excluded = TRUE`,
  `Operation = Survey`, `Identified_By = orsted_survey_dates`), with the
  projects listed in `Notes`. Dates are used as given, not shifted to UTC.
- For each survey vessel these windows replace its open-ended removal-list
  row, so its records before and between its listed trips count as fishing. A
  survey vessel need not be on the removal list (e.g. Cailyn & Maren II,
  338538875): its windows come from the file alone.
- **Survey work only.** The file does not date guard or scout work, so vessels
  listed as `Safety` in `vessel_removals.csv` keep their open-ended
  removal-list row.
- **Coverage.** `survey_dates_through` (`r/vessel_helpers.R`, 2026-08-31)
  marks the last day the files cover, and the build stops if a trip ends
  later. The analysis window ends on the same day. When a new file arrives,
  add it to `references/` with the same name pattern, map any new names, and
  move `survey_dates_through` (and `analysis_end`, if the window should grow).
- **Arch Angel** matches MMSI 368407550 (GFW type PASSENGER). The other
  removal-list Archangels (367478020, 368308710) have no AIS records on its
  survey days.

### `references/garfo_permit_codes.csv`

Meaning of each GARFO fishery permit code, one row per `fishery` and `code`:
`permit_type` (`commercial` / `for_hire` / `recreational` / `unknown`),
optional `gear_hint` (`FIXED` / `MOBILE`), `open_access` and `oa_directed`
(commercial permits anyone can obtain, and whether they are for a directed
fishery), a `description`, and the `basis` and `source` of each mapping (NOAA
Fisheries permit pages).

---

## Generated files

### `references/vessel_crosswalk.csv` {#vessel_crosswalk}

**Generated** by 03 from the removal list, the survey-date files and the
accepted decisions; do not edit. 04 rebuilds it and stops if the committed
file differs. Precedence: a decision replaces survey-date and removal-list
rows; survey-date rows replace removal-list rows.

One row per MMSI per validity window. A record is matched to the row whose
window contains its date; records with no row keep GFW's label. Inside the
window, `hull_class` overrides GFW's `Vessel Type` when deciding set
membership; the `Vessel Type` column itself is never rewritten.

| Column | Values |
|---|---|
| `MMSI` | 9 digits; any format for `gear_marker`; other malformed MMSIs exactly as in the GFW pull |
| `valid_from`, `valid_to` | ISO dates; blank = open-ended. Windows for one MMSI must not overlap |
| `Vessel_Name` | For the log only |
| `hull_class` | `fishing` (adds a vessel GFW does not type FISHING) / `non_fishing` / `gear_marker` (removes one it does) / `unknown` |
| `activity_excluded` | `TRUE` = records in the window are not fishing (charter or survey work) |
| `Operation` | `Safety`, `Survey`, ... for charter rows |
| `Identified_By`, `evidence_ref`, `Notes` | Where the decision came from |
| `gfw_vessel_type`, `gfw_gear_type`, `pull_date` | GFW's labels for the MMSI in the pull the row was built against |

### `references/vessel_permit_groups.csv`

**Generated** by 03; do not edit. The GARFO permit group of each MMSI with a
unique, year-overlapping GARFO name match that USCG PSIX does not contradict:
`MMSI`, `permit_group` (`commercial`, `for-hire`, `commercial + for-hire`,
`for-hire + open-access commercial`, `recreational only`, `unmapped codes
only`), `pull_date`. 04 reports the dual-permitted groups separately. Only
the group leaves 03; no GARFO hull, permit number or owner field does.

### `data/processed/vessel_review/{vessel,gear}_review.csv`

Generated by 03 every run; not tracked. The first columns are a suggestion in
the layout of `vessel_decisions.csv` / `vessel_gear.csv`; set `decision` to
`accept` or `reject` and the next run of 03 copies the row into the input
file. The rest of the columns are the evidence. If you open them in Excel,
import every column as Text and save as CSV UTF-8; otherwise Excel rewrites
dates and long IDs and validation stops the run.

### `data/processed/gfw/gfw_{vp,afe}_id_classified.csv`

Written by 04: every raw record inside the analysis window, with the
[fields derived on read](#fields-derived-on-read) and:

| Field | Description |
|---|---|
| `cw_hull`, `cw_excluded`, `cw_identified_by` | The matching crosswalk row's `hull_class`, `activity_excluded` and `Identified_By`; blank when there is none |
| `gfw_fishing` | GFW `Vessel Type == FISHING` |
| `is_marker`, `nonfish` | Crosswalk `gear_marker` / `non_fishing` hull |
| `added` | Crosswalk `fishing` hull that GFW does not type FISHING |
| `excluded` | Inside a charter or survey window |
| `in_strict` | **Strict set**: `gfw_fishing`. The unprocessed GFW data |
| `in_primary` | **Primary set**: (`gfw_fishing` or `added`) and not `is_marker`, `nonfish` or `excluded`. The headline analysis |
| `gear_class_gfw` | GFW's gear through the gear map (used for Strict) |
| `gear_class` | The accepted correction in `vessel_gear.csv` for the record's date, otherwise `gear_class_gfw` (used for Primary) |
| `gear_source` | `vessel_gear` or `gfw` |

### `data/interim/gfw/` cell tables

Fishing-vessel tables, written by 04. Zero-filled across every grid cell,
every stage or every month of the analysis window, both sets and, in the gear
tables, all four gear classes. These are the fishing-vessel inputs for the
analysis. Like everything in `data/interim/`, they are an intermediate stage:
they will get further treatment before processed versions feed the downstream
analysis.

| File (VP and AFE) | One row per |
|---|---|
| `gfw_{vp,afe}_cell_stage_sets.csv` | cell × stage × set |
| `gfw_{vp,afe}_cell_month_sets.csv` | cell × month × set |
| `gfw_{vp,afe}_cell_stage_gear_sets.csv` | cell × stage × set × gear class |
| `gfw_{vp,afe}_cell_month_gear_sets.csv` | cell × month × set × gear class |

| Field | Description |
|---|---|
| `cell_id` | Grid key |
| `Development Stage` or `Year Month` | Time step |
| `set` | `strict` or `primary` |
| `gear_class` | Gear tables only: `gear_class_gfw` for Strict, `gear_class` for Primary |
| `vp_hours` / `afe_hours` | Sum of hours |
| `n_mmsi` | Distinct MMSIs in the row. Does not sum across gear classes or months to a vessel total |

Hours are totals: divide by the stage's `months` for a rate, and by the
cell's `area_km2` for a density.

Raw-data tables, written by 02, all vessel types and no classification:
`gfw_{vp,afe}_id_cell_stage.csv` and `gfw_{vp,afe}_id_cell_month.csv`
(`cell_id`, time step, `vp_hours` / `afe_hours`, `n_mmsi`). They keep the raw
`_id` suffix so they are not mistaken for fishing-vessel totals. They stay
in `data/interim/` alongside the fishing-vessel tables.

### `data/processed/analysis/` analysis tables

Written by `r/05_prepare_analysis.qmd` (Phase 0 of
`planning/gfw_analysis_plan.qmd`) from the **Primary** gear tables. One table
per dataset × time step, zero-filled across every cell, stratum and the three
resolved gear classes (`UNRESOLVED` holds no Primary hours and is dropped).
The stage × season and season-year tables are sums of the monthly table, so
hours reconcile exactly with 04. Every file has a `<file>.json` provenance
sidecar (input SHA-256s, git commit, `renv.lock` hash, R version, seed,
`pull_date`).

| File (VP and AFE) | One row per |
|---|---|
| `{vp,afe}_stage_gear.csv` | cell × stage × gear |
| `{vp,afe}_stage_season_gear.csv` | cell × stage × season × gear |
| `{vp,afe}_season_year_gear.csv` | cell × season-year × gear |
| `{vp,afe}_month_gear.csv` | cell × month × gear |

| Field | Description |
|---|---|
| `cell_id`, `gear_class` | Grid key; `MOBILE`, `FIXED` or `POLE_AND_LINE` |
| `stage` | `Stage 1`–`Stage 3` (every table) |
| `season` | `AprSep` or `OctMar`. Both stage boundaries fall between seasons |
| `season_year` | Apr–Sep: its calendar year. Oct–Mar: the year it ends in (Oct 2020 – Mar 2021 is 2021). The first (2016 `OctMar`, 3 months) and last (2026 `AprSep`, 5 months) are partial |
| `year_month`, `moy`, `year`, `t_index` | Monthly table only: first of month, month of year, year, month index from 1 (2016-01) |
| `hours` | Sum of VP or AFE hours |
| `n_mmsi` | Distinct MMSIs in the cell and stratum. Does not sum across rows |
| `n_mmsi_fleet` | Distinct Primary MMSIs of the gear active anywhere in the AOI in the stratum. An AOI count, so it can itself respond to the projects |
| `months` | Months in the stratum (1 in the monthly table) |
| `rate` | `hours / months` |
| `rate_std` | Stage table only: season-standardised rate, the mean of the 12 month-of-year mean rates in the stage. Level comparisons only |
| `rate_fleet` | `hours / (months × n_mmsi_fleet)`, hours per vessel-month. Level comparisons only; blank when the gear has no vessels in the stratum |
| `density` | `hours / (months × area_km2)`, h km⁻² month⁻¹ |
| `log_expo` | `log(months × area_km2)`, the model offset |
| `y_vst` | Variance-stabilised density for the spatial statistics: √`density` (VP); `log(density + c)` (AFE), `c` = half the smallest positive density in the surface (dataset × gear × stratum). Blank on an all-zero surface |
| `domain` | Cell active for this dataset and gear in Stage 1 |
| `area_km2`, `aoi_class`, `x_km`, `y_km` | From the grid; centroid in EPSG:32619, km |
| `dist_lease_km`, `dist_band`, `nearest_project`, `depth_m`, `depth_sd_m`, `slope_deg`, `bpi_broad`, `d_found_final_km`, `d_cable_km` | Static cell covariates, copied from `cells.gpkg` (defined there) so each table stands alone |
| `d_found_km`, `n_found_2km`, `active_construction`, `cable_works`, `phase`, `months_since_first_found` | Monthly table only: infrastructure exposure, as in `infra_cell_month.csv` (below) |
| `d_found_km`, `n_found_2km`, `active_construction_share`, `cable_works_share`, `phase`, `months_since_first_found` | Season-year table only: as in `infra_cell_season_year.csv` (below) |

Rounded when written (decimals): `dist_lease_km`, `x_km`, `y_km`, `depth_m`,
`depth_sd_m`, `d_found_km`, `d_found_final_km`, `d_cable_km` 3; `area_km2` 6;
`slope_deg`, `bpi_broad` 4; `y_vst` 6; season-year means and shares 3. Every
derived field is computed before rounding; `cells.gpkg` keeps full precision.

### `data/processed/analysis/infra_cell_*.csv`

Infrastructure exposure per cell, without gear, written by 05 step 8 from
`data/sf/infra/infrastructure.gpkg`. Distances are from the cell centroid.

| File | One row per |
|---|---|
| `infra_cell_month.csv` | cell × month |
| `infra_cell_season_year.csv` | cell × season-year |
| `infra_cell_month_srw_planned.csv` | cell × month; sensitivity with SRW's 40 unrecorded positions installed in May 2026 |

| Field | Description |
|---|---|
| `d_found_km` | km to the nearest foundation (WTG or substation) whose last installation day is on or before the month's end. Blank before the first (June 2023). Season-year: mean over the months that have one |
| `n_found_2km` | Installed foundations within 2 km (season-year: mean) |
| `active_construction` | A foundation's installation days overlap the month within 5 km. Season-year: `active_construction_share`, the share of months |
| `cable_works` | A cable route whose works window overlaps the month lies within 2 km. Season-year: `cable_works_share` |
| `phase` | Nearest project's `pre`, `construction` or `post_construction` (after its last works day, only if every foundation is installed and every cable window closed). Season-year: the phase in most months, ties to the later |
| `months_since_first_found` | Months from the nearest project's first foundation (negative before). Season-year: mean |

The radii are 05 parameters (`r_count_km`, `r_active_km`, `r_cable_km`).

### `data/processed/analysis/cells.gpkg`

One row per grid cell, EPSG:32619, with the static covariates.

| Field | Description |
|---|---|
| `cell_id`, `ix`, `iy`, `area_km2`, `aoi_frac`, `aoi_class` | From the grid (02) |
| `x_km`, `y_km` | Centroid, km |
| `dist_lease_km` | Signed distance from the centroid to the nearest lease boundary; negative inside a lease |
| `dist_band` | `inside`, `0-2`, `2-4`, `4-8`, `8-15` km, each [lower, upper). `8-15` is the BAG reference |
| `nearest_project` | `SFW`, `RWF` or `SRW`: the lease containing the cell, or else the nearest |
| `domain_{vp,afe}_{mobile,fixed,pole_and_line}` | Cell active for that dataset and gear in Stage 1 |
| `depth_m`, `depth_sd_m` | Area-weighted mean and SD of depth (m, positive down), NCEI CRM Vol. 1 at 30 m |
| `slope_deg` | Area-weighted mean slope at 30 m |
| `bpi_broad` | Broad bathymetric position index: elevation minus its 1–3 km annulus mean, on a 150 m aggregate. Positive = ridges and banks |
| `d_found_final_km` | km to the nearest eventual foundation of any project, SRW's planned positions included |
| `d_cable_km` | km to the nearest cable route (inter-array or export) of any project, as drawn in the layout files |

### `data/sf/infra/infrastructure.gpkg`

Ørsted foundations and cable routes, EPSG:32619, written by 05 step 8 from
the files in `data/sf/owf/*/turbines/` and the two `references/` tables
below. Layer `foundations`, one row per foundation (166):

| Field | Description |
|---|---|
| `asset_id` | `<project>-<internal id>`, or `<project>-<grid position>` where there is no internal id (SFW turbines, SRW planned) |
| `project` | `SFW`, `RWF`, `SRW` |
| `asset_type` | `wtg` (turbine) or `oss` (substation: SFW Z01, RWF Z01a / Z01b / Z02, SRW OCS-DC) |
| `grid_pos` | Ørsted 1 × 1 nm grid position, e.g. `AM06`. RWF Z01a and Z01b share AL11 |
| `internal_id` | Ørsted id (RWF `B##`/`Z##`, SRW `C##`/`D25`/`OCS-DC`, SFW `Z01`) |
| `status` | `installed` or `planned` (SRW positions with no installation record) |
| `date_basis` | `exact` (foundation CSV or PSO report), `project_window` (SFW turbines: the 12 share 2023-07-02 to 2023-08-07, as their PSO ids do not map to positions), `planned` |
| `foundation_installed`, `foundation_end` | First and last installation day across the foundation's rows in the CSV |
| `n_date_rows` | CSV rows (one per installation day) for this foundation (SRW OCS-DC: its 8 pin piles) |
| `wtg_installed`, `first_power` | Not supplied; blank |
| `depth_m` | Water depth from the CSV (m) |
| `layout_offset_m` | Distance from the CSV (as-installed) position to the layout point; 0 where the layout point is used |
| `source`, `version_date` | Source file(s); the layout file's date |

Layer `cables`, one row per route (168):

| Field | Description |
|---|---|
| `asset_id` | `<project>-<asset_type>-<route_name>` |
| `asset_type` | `iac` (inter-array) or `export_cable` |
| `route_name` | Name in the layout file, e.g. `AM06 to AM05`, `EC1` |
| `lay_start`, `lay_end` | Project × cable-type works window from `references/infra_cable_windows.csv`; an open window ends at the end of the analysis window |
| `date_basis` | `project_window`, `open_window`, `complete_by` (end only), `unknown` |
| `burial_complete` | Not supplied; blank |
| `source`, `version_date` | Source of the window; the layout file's date |

### `references/sfw_foundation_dates.csv`, `references/infra_cable_windows.csv`

Hand-transcribed and tracked; schema checked in
`r/tests/testthat/test-references.R`. `sfw_foundation_dates.csv`: the SFW
PSO report's monopile installation dates (`pso_id`, `structure`,
`first_date`, `last_date`, `source`). `infra_cable_windows.csv`: one row per
project × cable type (`lay_start`, `lay_end`, `date_basis`, `source`), each
citing the public source of its dates.

### `data/processed/analysis/grid_queen.gal`, `grid_weights.rds`

Queen contiguity of the grid, checked identical between `poly2nb()` and the
integer lattice. The GAL file uses `cell_id` as the region id, for GeoDa and
PySAL. The RDS holds the `nb` object and the `listw` objects `lw_W`
(row-standardised: Moran's I, LISA) and `lw_B_self` (binary, self-included:
Gi\*).

### `data/sf/bathy/crm_vol1_2023_aoi.tif`

NOAA NCEI U.S. Coastal Relief Model Vol. 1 (2023, 1 arc-second, EGM2008
metres, positive up), subset to the grid's bounding box plus 5 km via THREDDS
WCS by 05. Public domain. The sidecar records the request URL, access date
and file hash; 05 fetches again only if the hash or request changes.

---

## Provenance

The raw extracts come from `r/01_pull_gfw.qmd` with a valid `GFW_TOKEN`, via
`gfwr` v3.0, one calendar-year request per dataset:

```r
gfw_ais_presence(spatial_resolution = "HIGH",     # 0.01 degree
                 temporal_resolution = "DAILY",
                 group_by = "VESSEL_ID",
                 start_date = ..., end_date = ..., # one calendar year per call
                 region_source = "USER_SHAPEFILE",
                 region = orsted_aoi)
```

`gfw_ais_fishing_hours()` takes identical arguments. No `filter_by` is applied,
so no server-side flag, gear or vessel-type filtering occurs.

GFW reprocesses its data and relabels vessels between pulls, so a new pull
does not reproduce an old one; every decision in `references/` was made
against the 2026-10-06 pull. Keep a copy of that pull to reproduce the
analysis.

Data © Global Fishing Watch, CC BY-SA 4.0. R environment pinned in
`renv.lock`.

---

## Archived Python outputs

Produced by the archived Python analysis (`archive/`), not by the R workflow;
kept for reading the archived reports. The archived pipeline used the
superseded centroid-based grid (`Orsted_sqGrid_utm19n.shp`, 3,375 cells) with
a zero-based positional cell index, and the earlier stage windows.

### `data/processed/gfw/gfw_{vp,afe}{1,2,3}_*_sub.csv`

Per-stage files from the earlier R pull (`gfw_vp_afe_dataPull_090126.Rmd`,
superseded by `r/03_review_vessels.qmd` and `r/04_classify_aggregate.qmd`).
Filtering applied: VP restricted to `Vessel Type == "FISHING"`; 34 named
Ørsted survey/safety vessels removed for Stages 2–3; two misclassified cargo
vessels removed; AFE records at or below 0.32 hours removed.

### Per-cell summary (`aggregate.summarize_stage`)

| Field | Description |
|---|---|
| `SumVesselHrs` / `SumFishingHrs` | Total hours in the cell for that stage and gear class |
| `SumVesselCount` | Distinct **MMSIs** |
| `SumVesselIdCount` | Distinct Vessel IDs — sensitivity column only |
| `TotalRecords` | Row count |
| `MonthMeanVesselHrs` / `MonthMeanFishingHrs` | Sum ÷ stage length in months. Not per-cell active months, so zeros are structural. |
| `MMVH_sqrt` / `MMFH_sqrt` | Square root of the above. The primary analysis surface. |

### Spatial statistics (`spatial_stats.run_stage`)

ArcGIS-compatible names.

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
