# Data Dictionary

Every field the analysis reads or produces. Source data is gitignored; see
[Provenance](#provenance) to regenerate it.

---

## Source data

### `data/external/gfw/gfw_{vp,afe}_id.csv`

Unfiltered API output, 18 columns. One row = one vessel × one 0.01° cell × one day.

| Column | Type | Description |
|---|---|---|
| `Lat`, `Lon` | float | 0.01° cell centroid, WGS 84 (EPSG:4326) |
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

### `data/processed/gfw/gfw_{vp,afe}{1,2,3}_*_sub.csv`

Cleaned per-stage files — what the analysis actually reads. Same schema minus
`Entry`/`Exit Timestamp`, `IMO`, `CallSign`, and the transmission dates (12 columns).

Filtering already applied by the R pipeline (`gfw_vp_afe_dataPull_090126.Rmd:494-535`):

- VP only: restricted to `Vessel Type == "FISHING"`
- Both: 34 named Ørsted survey/safety vessels removed for Stages 2–3 only
- Both: two misclassified cargo vessels removed, all stages
- AFE only: records at or below 0.32 hours removed

### Spatial layers

| File | CRS | Description |
|---|---|---|
| `data/shp/aoi/Orsted_sqGrid_utm19n.shp` | EPSG:32619 | 3,375 analysis cells. Carries `Lon_C`, `Lat_C` (0.01° centroids), `Area_m2`, `Area_km2`. |
| `data/shp/aoi/Orsted_AOI.shp` | EPSG:4326 | Study boundary — dissolved union of the SFW + RWF + SRW 10 km buffers |
| `data/shp/owf/{SFW,RWF,SRW}.shp` | EPSG:3857 | Ørsted lease areas. **Reproject before use.** |
| `data/shp/owf/{VW1,VW1_Buffer,SRW_Buffer}.shp`, `SNE_OWFs.shp` | EPSG:3857 | **Not used.** Vineyard Wind is not an Ørsted project and lies outside the AOI; `*_Buffer` are AOI-construction intermediates. |

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
| `cell_id` | Zero-based positional index into the grid; the join key throughout |
| `SumVesselHrs` / `SumFishingHrs` | Total hours in the cell for that stage and gear class |
| `SumVesselCount` | Distinct **MMSIs** |
| `SumVesselIdCount` | Distinct Vessel IDs — sensitivity column only |
| `TotalRecords` | Row count |
| `MonthMeanVesselHrs` / `MonthMeanFishingHrs` | Sum ÷ **stage length** (44 / 43 / 40). Not per-cell active months, so zeros are structural. |
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
| 1 | 2016-01-01 → 2019-08-01 | 44 | Pre-monitoring baseline |
| 2 | 2019-09-01 → 2023-03-01 | 43 | Protected-species surveys began 09/2019 |
| 3 | 2023-04-01 → 2026-07-01 | 40 | Seabed prep for South Fork Wind began 04/2023 |

Stage 3's final month is partial — data ends 2026-07-13.

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

`data/external/RmVessels_RunningList.csv` is the **superseded** predecessor of this list: the same 46
vessels, but untracked and without the `Scope`, `Identified_By`, `Confidence` and `Date_Added` columns.
Neither pipeline reads it any more. It is left in place rather than deleted because `data/` is not
modified by this project.

| Column | Meaning |
|---|---|
| `Vessel_Name` | Reported name. For the log only -- matching is on MMSI |
| `MMSI` | 9 digits, unique within the file |
| `Operation` | `Safety` or `Survey` -- the charter role |
| `Scope` | `stages_2_3` or `all_stages`, see below |
| `Identified_By` | `orsted_list`, `behavioural_screen`, `marinetraffic`, `name_variant`, `known_research_vessel` |
| `Confidence` | `confirmed`, `probable`, `possible` |
| `Date_Added` | ISO `yyyy-mm-dd`. Blank for the original Orsted list |
| `Notes` | Free text |

`Scope` carries the stage-conditional treatment:

- **`stages_2_3`** -- chartered working fishing hulls. Stages 2-3 are removed,
  Stage 1 is retained as genuine fishing activity.
- **`all_stages`** -- not a fishing vessel under any circumstances, so there is
  no baseline worth keeping. Currently only NOAA Gloria Michelle, a NOAA
  Fisheries research vessel that GFW classes as FISHING/TRAWLERS.

Both readers validate the file on load and fail loudly, listing every problem
found rather than stopping at the first: blank names, an MMSI that is not 9
digits, duplicate MMSI, unknown `Scope` or `Confidence` values, a `Date_Added`
that is not ISO. `load_removal_list()` logs the breakdown by scope and
confidence on every read; the list currently holds 46 vessels.

---

## Provenance

Source CSVs regenerate from `r/scripts/rmd/gfw_vp_afe_dataPull_090126.Rmd` with a
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
