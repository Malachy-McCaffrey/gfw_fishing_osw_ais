# Decisions log

Every analysis and workflow decision, with what it changed. It was extracted
from `planning/gfw_analysis_plan.qmd` on 2026-10-28 (D-001 to D-052 keep their
text from the plan's former "Decisions log" table) and is now the only place
decisions are recorded. Vessel-by-vessel hull and gear decisions are data, not
log entries: they live in `references/vessel_decisions.csv` and
`references/vessel_gear.csv`. Only decisions about how vessels are screened or
treated as a group belong here.

**How to use it**

- **Find a decision by its ID.** Notes in the plan and in the qmds cite it,
  e.g. "(decision 2026-10-20, D-047)". Search for the ID here.
- **Add a decision** as a new row at the top, under a dated heading, with the
  next free ID. IDs follow the order decisions were made; the log is shown
  newest first.
- **Never edit or delete an old row.** If a decision changes, add a new row
  and mark the old one `Superseded by D-xxx` in its Status column. The record
  of what was believed when is part of the provenance.
- **Cite the ID** wherever the decision shows up in code or prose, so it can
  be traced both ways.

Links of the form *plan: …* point to sections of
`planning/gfw_analysis_plan.qmd`.

**Phase numbers.** Rows before D-059 use the original numbering, in which
Phase 4 was AKDE. From D-059 on, Phases 5–9 are renumbered 4–8: BAG is now
Phase 4, frequentist models 5, INLA-SPDE 6, sensitivity 7 and synthesis 8.

---

### 2026-10-29, raster export

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-067 | Raster export | **A new output step, `r/05a_export_rasters.qmd`, writes the Primary set's per-cell effort and the static cell covariates as GeoTIFF and NetCDF** in `data/processed/rasters/{pipeline}/`, so they can be overlaid with other gridded fisheries data (NOAA fishing footprints, VMS and VTR products). **Primary only** (the user, 2026-10-29); Strict is not exported. **Grid:** GFW's own 0.01° lattice in EPSG:4326, so each cell is one pixel and nothing is resampled. A UTM raster was rejected because the cells are not square in UTM (about 0.84 × 1.11 km), so it would need resampling. **Extent:** the AOI's bounding box snapped outward to the lattice and padded by one cell (`lattice_template()`), not each version's grid, so v4 and v5 rasters line up pixel for pixel; pixels off the grid are NA, grid cells with no effort 0. **Gears:** `all` plus the three analysis gears; Primary `UNRESOLVED` is checked to be 0 h and not written. **Vessel counts are distinct counts and do not add** across cells, gears or time, so the `all` layers come from 04's all-gear tables, never from summing the gear layers, and every count file is marked non-additive. **New dependency:** ncdf4 1.24, added to `renv.lock` for terra's `writeCDF()` and the NetCDF attributes | Output only: nothing in 06 onward reads it, and no analysis table changes. Gate: every pixel read back from disk equals its table value exactly; off-grid pixels are NA; each NetCDF matches its GeoTIFF; gear hours sum to `all`. Checked on v4 in a sandbox render: the gate passed, and the AFE stage totals match `afe_stage_gear.csv`. The v5 rasters wait for 02 → 05 on v5 (v5 plan, step 8): the v5 raw pull has 4 cells that v4 lacks and lacks 4 of v4's (union 3,380), and both fit the AOI extent | |

### 2026-10-29, infrastructure exposure radii

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-066 | Sensitivity-radius tables | **02a writes `n_found` and `active_construction` at the sensitivity radii in the same render**, as two extra tables: `infra_cell_month_radii.csv` and `infra_cell_season_year_radii.csv`. Each has one column per radius (`n_found_1km` / `_2km` / `_4km`, `active_construction_2km` / `_5km` / `_10km`; season-year: means and `_share`). The radius sets are 02a parameters (`r_count_sens_km`, `r_active_sens_km`). Rejected: re-rendering 02a with a changed radius. The output names don't depend on the radius, so a re-render would overwrite the primary tables that 05 and 10 read | The primary tables, 05 and the analysis tables are unchanged; a Phase 4 or Phase 7 model joins the column it needs. Recorded installation dates only (no SRW-planned variant) and no `cable_works` radii, which no planned run varies. Three new gate checks: the primary-radius columns equal the main tables exactly, exposure never shrinks as the radius grows, and there are no gaps | |
| D-065 | Exposure radii | **The radii stay at 2 km (`n_found`), 5 km (`active_construction`) and 2 km (`cable_works`), and the reasons are recorded here after the fact.** They were set on 2026-10-19 with D-022 to D-026 but never logged, so the reasons below are reconstructed. They are all measured from the cell centroid; cells are about 0.84 × 1.11 km. **Count (2 km):** the layouts are on a 1 nm grid. Median nearest-neighbour foundation spacing is 1.84 km (RWF), 1.78 km (SFW) and 1.84 km (SRW), measured from `infrastructure.gpkg` on 2026-10-29. So 2 km reaches the nearest ring of foundations without spanning the array, and it matches the 0–2 km BAG band. **Active construction (5 km): a judgement, not a measured scale.** Construction could lower effort in three ways. (1) Mandated exclusion inside the 500 m USCG zones; this is `sz_share`'s job, not this covariate's (D-034). (2) Fishers choosing to stay away beyond the zones: the construction fleet gets in the way, fixed gear set nearby is at risk, and notices to mariners ask vessels to keep clear. (3) Target species moving away from piling noise. `active_construction` (λ) is meant to capture (2) and (3). No published distance for (2) was found, and it is probably the larger effect on vessels. For (3), NMFS's modelled Level B harassment ranges give a rough scale for how far piling noise carries: 4,684 m for SFW's 11-m monopiles (IHA, 87 FR 806, 2022-01-06; sound field verification later measured 1.84–3.25 km on all but the first pile), and for RWF 3,833 / 4,271 m (WTG monopiles) and 4,100 / 4,698 m (OSS monopiles), summer / winter (final rule, 88 FR 72562, 2023-10-20). These are marine-mammal thresholds (160 dB rms, 10 dB attenuation assumed). They show the noise footprint is of the order of 5 km, but they say nothing about fish or vessel responses. Piling is also intermittent (hours on some days), while the covariate is on for the whole month. So the radius is not a noise threshold, and the sensitivity runs carry the weight. **Cable works (2 km):** the lay footprint is narrow and the windows are coarse and set per project (D-025). A tight radius limits months of false exposure, and it matches the count radius. **Choosing the radius from the data is exploratory until it is shown to work.** Phase 3's hotspot maps could not detect a planted 2 km halo. That test used per-cell flags, so it does not by itself rule out estimating λ in a model, but finding where an effect ends needs more power than detecting it. A radius chosen by best fit is also noisy when power is low, and it inflates λ | No output changes. The half / double sensitivity runs (`n_found` at 1 / 2 / 4 km, `active_construction` at 2 / 5 / 10 km; plan, Phase 7) test the choice. A **radius-recovery case** is added to the Phase 4 power simulations ([plan: BAG power analysis](gfw_analysis_plan.qmd#sec-bag-power)): plant λ at 5 km, refit at 2 / 5 / 10 km, and check how often 5 km fits best. A gear × dataset may compare radii to choose one only where recovery is ≥ 0.8 at an effect λ is powered (≥ 0.8) to detect; elsewhere the radius runs are a sensitivity check only | |

### 2026-10-29, GFW pipeline v5

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-064 | Roster check (v5 plan, Section 3.6, Part B) | **On a run against a new pipeline version, 03 compares the previous version's fishing roster with the pull** (`roster_changes()`, `previous_roster_path()` in `r/vessel_helpers.R`). Type changes of previous-Primary vessels with no crosswalk row and no decision made against this version go on a new hull-sheet list, `5_roster_label_change` (every row reviewed, suggested `fishing`, ordered by previous-version AFE); unprotected gear-class changes get a gear-sheet reason; missing vessels and roster-wide drift are reported in Phase 6. Departures from the plan: the list is named for the roster, not for v4; retyped vessels are not added to the gear sheet until a decision makes them fishing hulls (as for list 1). Also: list 3's foreign-flag rule uses the `UNRESOLVED` gear class instead of `INCONCLUSIVE` (gone in v5); 03 refuses identity lookups from another pipeline version; a `grid` path parameter | Sandbox renders (nothing in `data/` or `references/` written): on v4, every output is byte-identical except three new list-3 rows (Canadian boats, generic FISHING gear, 1–2 VP h). On v5: crosswalk unchanged (640 rows); list 5 has **379 vessels** (349 now PASSENGER, 21 OTHER_NON_FISHING, 5 GEAR, 4 INSUFFICIENT_DATA; 68% MID 338; v4 7,440 VP h, 1,818 AFE h), far above the plan's "few dozen"; the gear sheet has 75 rows, 68 with a roster reason (12 specific-to-specific, e.g. KAREN ANN FIXED → MOBILE, 734 AFE h). v5 renamed OTHER to OTHER_NON_FISHING and puts a non-fishing vessel's type in Gear Type; no new fishing gear codes | |

### 2026-10-28, workflow structure

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-063 | v4 data source | **The v4 data are a snapshot of `:latest` pulled on 2026-10-06, and `:v4.0` is not re-pulled** (v5 plan, Section 3.3 dropped). v4 was still updating daily until its 2026-10-21 freeze, so the snapshot cannot be requested from GFW again. It is reproduced by archiving the raw v4 pull in a repository with a DOI, not by re-pulling. `data/raw/gfw/v4/pull_info.csv` records it as `:latest (resolved to v4)` | No `data/raw/gfw/v4_repull/`. The only check against frozen `:v4.0` is the live check of the pinned wrapper (D-062) on June 2024: vessel presence and fishing effort matched record for record and hour for hour (7,452 and 1,191 records). Six MMSIs had different labels in `:v4.0`, four of them on the roster. EAGLE-EYE (368055000) went from SET_LONGLINES to DRIFTING_LONGLINES (FIXED to MOBILE), the FRANCES boats (367155670, 366940990) from POLE_AND_LINE to INCONCLUSIVE, and SUSAN L (366211560) from INCONCLUSIVE to TRAWLERS (already covered by a MOBILE gear correction). The analysis keeps the 2026-10-06 labels. Methods should cite the snapshot date and the DOI | |
| D-062 | Pinned pulls | **New pulls request an explicit GFW dataset version**, never `:latest`: `gfw_4wings_pinned()` in `r/gfw_helpers.R` sends gfwr's 4Wings request with the dataset ID named, and `01` requires `-P dataset_version:vN.N`. `pull_info.csv` records `vp_dataset`, `afe_dataset`, `gfwr_version` and `api_base`. Raw columns are kept as text | A pull's version is now a fact of the request, not only of its folder name, and `:v4.0` can be re-pulled for the reproducibility check (v5 plan, Section 3.3) while it is served. Offline tests tie the request to gfwr 3.0's | |
| D-061 | Vessel review code | **03's functions moved to `r/review_helpers.R`** (27 functions and constants), unchanged except that the screening thresholds they read from 03's `screen` list are now arguments. 03 keeps the thresholds and the review's narrative; its split into 03a–d is deferred | 03 went from 1,704 to about 1,250 lines; the functions gained tests (`test-review_helpers.R`). Rendered on v4 with outputs redirected, 03 reproduced the crosswalk, permit groups, decision files and both review sheets byte for byte | |
| D-060 | Infrastructure step | **Ørsted infrastructure moved out of `05` (step 8) into `r/02a_infrastructure.qmd`**, which runs after 02 and writes `infrastructure.gpkg`, `infra_cell_static.csv` and the `infra_cell_*.csv` tables. 05 reads and joins them in step 9, unchanged; its exposure parameters moved to 02a. Reverses D-021 | 02a needs only the grid, leases and Ørsted files, so an infrastructure update re-renders 02a and 05 without the vessel workflow. 05's analysis tables are unchanged (see the verification in the commit) | |

### 2026-10-28, decision log and planning documents

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-059 | Analysis phases | **AKDE removed from the plan** (its section, status and timeline rows, the synthesis "why AKDE was dropped" item and the Fleming et al. 2015 citation). **Phases 5–9 renumbered 4–8** in the plan, `r/05`–`r/10`, the helper files and tests. D-003 and the quoted original request at the top of the plan are kept as history | Old rows of this log keep the old numbers (see "Phase numbers" above). Exceedance-probability maps stay in the INLA phase as a model-based hotspot surface. Notebook file names (`10_bag.qmd` to `14_synthesis.qmd`) are unchanged | |
| D-058 | Planning documents | **Decisions log extracted** from `planning/gfw_analysis_plan.qmd` into this file, with IDs added to every dated decision note in the plan and in `r/05`–`r/10`. **The split of the plan into plan and methods is deferred** until after the v5 adoption decision and Phase 6 | The plan gains a phase status table and points here. Methods are written once, from the settled analysis and final numbers, rather than moved from the plan now and rewritten later | |

### 2026-10-28, GFW pipeline versions

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-057 | New pulls | **`r/01_pull_gfw.qmd` requires `-P pipeline:<version>`** and **refuses to overwrite** a pull already filed under that version. `pull_info.csv` records the version | gfwr requests `:latest`, so the served version cannot be read from the request; naming it is the analyst's job | |
| D-056 | Decision files | **`gfw_pipeline` column added** to `vessel_decisions.csv`, `vessel_gear.csv` and the crosswalk, **backfilled as `v4`** for every existing row (checked: all other values unchanged). Validated as never blank; written to both review sheets | Each decision records which version's GFW labels it was checked against, so the v5 review can tell old decisions from new | |
| D-055 | Repo layout | **Everything made from a pull is filed under its pipeline version**: raw pull, interim, processed and analysis tables, review sheets, GFW identity cache, grid, model cache, reports, and the generated `vessel_crosswalk_{pipeline}.csv` and `vessel_permit_groups_{pipeline}.csv`. Shared across versions: hand-made decision files, removals, survey dates, GARFO lists, the PSIX cache, bathymetry, infrastructure. Default version **`v4`** (`gfw_pipeline_default` in `r/paths.R`); every qmd takes `-P pipeline:` | The v4 data was moved into `v4/` folders (1,616 files, checksums verified) and `04` reproduced its ten outputs byte for byte. Model-cache keys hash data, not paths, so no refits | |
| D-054 | v4 fishing roster | **`references/fishing_roster_v4.csv` written once** (1,554 MMSIs; source commit `69d3e22`), on the pre-versioning layout. Every MMSI that counted as fishing in the v4 pull by any source (GFW type, crosswalk fishing hull, gear correction, fishing GARFO permit group). Written by `write_roster_once()`, which refuses to replace it | A later version's run of 03 compares its labels with the roster and sends type or gear changes to review (`planning/gfw_pipeline_v5_plan.qmd`, Section 2.7, Parts B and C) | |

### 2026-10-27, GFW pipeline v5

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-053 | New GFW data | **Compare the next pull with the 2026-10-06 pull before using it**: vessel presence, apparent fishing hours, and false positives and negatives. That pull is pipeline v4; GFW released v5 on 2026-10-21 | `planning/gfw_pipeline_v5_plan.qmd`. Which version becomes primary is decided after the comparison | |

### 2026-10-20, Phase 5 setup

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-047 | Phase 5 before Phase 6 | **Option (a): run Phase 5 now on an interim model**, the form Phase 6 recommends (`sdmTMB` with an SPDE spatial field; stage × season: a shared field plus an iid field per stage; timing models: a shared field plus an AR1 field over years; NB2 for VP, Tweedie for AFE, with delta-Gamma alongside for the AFE stage × season models). Refit when Phase 6 settles the base model | Every fit is cached under its full specification (`fit_cached()`), so Phase 6 changes only the specification. The power analysis and Phase 3 criterion 5 are re-run on Phase 6's base model |  |
| D-048 | Mesh | **2 km cutoff** (783 vertices for VP mobile) | Same headline estimate as a 1 km cutoff (rate ratio 1.01 vs 0.98, SE 0.15 both) at half the fitting time (168 vs 348 s) |  |
| D-049 | Power simulations | **100 per effect size** (not 200), effects 0, 20, 30 and 50%, run as parallel worker processes (`callr`) | About 2,000 refits; 200 would double a multi-hour run. Raise for any gear whose curve crosses 0.8 between two tested effects |  |
| D-050 | Convergence rule | A fit counts as converged when `sanity()` reports a positive-definite Hessian, positive eigenvalues, optimiser convergence and small gradients. `se_magnitude_ok` is not required | When depth acts linearly, the depth smooth's wiggliness parameter collapses to zero and its SE is uninformative; this is harmless |  |
| D-051 | Dependencies | **Installed** 2026-10-20: `glmmTMB` 1.1.15.2, `DHARMa` 0.5.0, `marginaleffects` 1.0.0 (with `sandwich`); already present: `sdmTMB` 1.1.0, `fmesher` 0.8.0, `TMB`, `mgcv` 1.9-3. Recorded with `renv::snapshot()` once `10_bag.qmd` uses them | `mgcv` was **not** in `renv.lock` despite the 2026-10-18 entry below; the snapshot restores it |  |
| D-052 | Model cache | **`fit_cached()` built** (`r/analysis_helpers.R`, with `fit_cache_path()`): fits in `data/processed/models/<hash>.rds` with a JSON sidecar (fit time, package versions); `reports/` added to `.renvignore` | — |  |

### 2026-10-20, pre-Phase 5 charter screen

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-043 | Systematic charter-like vessel screen | **Run before Phase 5** (`r/scratchpad/charter_screen.R`, results in `charter_screen_2026-10-20.csv`). Every Primary vessel × dataset × gear in Stages 2–3, flagged if its lease share was > 2× its fleet's on ≥ 20 h (A) **and** it ran ≥ 12 h per active day (B) or had no Stage 1 history (C). 36 vessels flagged | The BAG headline is the inside-the-leases contrast that charter vessels distort. Flagged vessels held 32–56% of fixed and a third of mobile Stage 2–3 inside-lease AFE hours |  |
| D-044 | ARGO (338350046), TRADITION (368361590), GULF STREAM (368128790) | **Excluded as safety charters from 2021-05-01**, as for AMELIA JOYCE and the others: same review status (safety suggested, kept 2026-10-15) plus the full pattern (A + B + C: 12.5–18.9 h per active day, 54–73% inside) | Consistency with the 2026-10-20 exclusions |  |
| D-045 | SANDRA JANE (367327960) | **Excluded as a safety charter from 2021-05-01** (new row). Never reviewed before; survey period 19.6 h per active day, 47% inside the leases, first fishing record 2021-05-03 (the safety contract's start), 23% of mobile AFE inside-lease hours in Stage 2. Its 134 h of earlier fishing are kept | — |  |
| D-046 | BUCKEYE (368175660) and the A + C-only vessels | **Kept.** BUCKEYE's long days appear only in AFE (VP 7.9 h/day). The A + C vessels fish normal-length days and are most likely new AIS carriers fishing in or near the leases, the behaviour Phase 5 measures | Their influence is reported through the Phase 5 leave-one-vessel-out runs, not removed |  |

### 2026-10-20, safety-charter exclusions

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-042 | AMELIA JOYCE (368080240), LILY M (368231710), JACK M (368250590) | **Excluded as safety charters from 2021-05-01, open-ended** (`references/vessel_decisions.csv`: `accept`, Operation `safety`, Identified_By `behavioural_screen`). This reverses the 2026-10-15 decision to keep them. 2021-05-01 is the start of the Ørsted–SSNA safety-vessel contract, the window already used for Beth Anne and Pamela Ann | Found while preparing the ROSA webinar: together they held 55% of Stage 3 mobile AFE hours inside the leases, with 34–57% of their own hours there (AMELIA JOYCE 16.6 h per active day), the PROVIDER pattern (caveat 11). Their hours from May 2021 leave Primary; 03–08 re-run, and the plan's typed figures predate this change |  |

### 2026-10-20, Phase 3

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-036 | Local p-values | **z-moment permutation p** (`Pr(z != E(Ii))`, `Pr(z != E(Gi))`), 999 conditional permutations, for both statistics and every run | No p-value floor, so BH-FDR can reject on sparse surfaces. The rank p (floor 2/1,000) rejected nothing on the fixed and pole-and-line AFE surfaces. The folded p, chosen first, was **withdrawn**: spdep 1.4.2's `localG_perm()` returns 0.001 for empty neighbourhoods where a hand-coded permutation gives about 0.4, so it flagged every empty neighbourhood. The normal approximation is checked by the criterion-5 null runs |  |
| D-037 | Gi\* scale | **The non-negative G scale** (`g_scale()`), as for General G | `localG_perm()` divides by the surface total; on AFE's log `y_vst` that total is negative and every z changes sign |  |
| D-038 | Criterion 5 nulls | **Interim:** Gaussian random field at each gear's *ρ*₀ (clamped 3–10 km), rank-mapped onto the observed Stage 1 values, 40 replicates | Re-run with Phase 6 simulations when they exist |  |
| D-039 | Criterion 5 detection | **Paired:** each replicate's signal run against its own null (same field, same seed); detected if the signal raises the zone's flagged share by **≥ 10 percentage points**. Power = share of replicates detecting. Mean excess and any-excess share reported alongside | An unpaired rule (beating the spread of all null replicates) mostly measures where random clusters fall. The gate (halo power < 0.5 for both → maps descriptive) uses this power |  |
| D-040 | Criterion 6 | **Deferred** until Phase 5 | The primary method chosen in Phase 3 stays provisional |  |
| D-041 | Emerging hot spot analysis | **Skipped for now** (would add `sfdep`) | Optional extension left open |  |

### 2026-10-20, SFW crosswalk

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-032 | SFW foundation source | **Ørsted's `sfw_monopile_install_orsted.csv` is primary**: PSO id (A01–A15, Z01) × layout position (`USCG_ID`) × installation day, with as-built DMS coordinates. **PSO Table 3 (`references/sfw_foundation_dates.csv`) is kept as an independent check**, and `05` asserts the two agree | Every SFW foundation has exact dates (`date_basis = "exact"`); the shared turbine window and its sensitivity run are retired. Verified 2026-10-20: 13 foundations (A10 and Z01 over two days each), dates identical to Table 3, every position within 0.3 m of the as-built layout (mariner notice, 2025-07-25), Z01 on AP06 as inferred |  |
| D-033 | A01's truncated id | The CSV's `USCG_ID` for A01 read **"AM0"**; its coordinates fall on **AM05** (0 m). **Corrected to AM05 in the file by the user, 2026-10-20** | `05` still matches SFW positions by distance and asserts every `USCG_ID` names its match; a reference test now requires every id to be a complete grid name |  |
| D-034 | USCG safety zones | **500 m around every foundation, from its installation to its project's rule end** (`references/infra_safety_zones.csv`): SFW enforced 2023-05-01 to 2024-05-31 (user; 88 FR, 2 May 2023, extended by 88 FR 87716); RWF rule to 2027-05-31; SRW rule to 2028-05-31, so RWF and SRW zones stay on to the end of the window | New covariate `sz_share(t)` (area share of the cell inside an active zone) in the month and season-year tables and the timing model (caveat 17). Inside a zone, lost effort is mandated, not avoidance |  |
| D-035 | Zone enforcement | The RWF and SRW rules enforce zones **only during active construction** (about 48 h to 1 week per location). **Sensitivity**, not the main definition: `sz_share_install` counts each zone on its installation days only | One Phase 8 run; the main covariate follows the installation-to-rule-end timing |  |

### 2026-10-20, Phase 2

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-027 | General G scale for AFE | **log(1 + density / *c*)**, i.e. `y_vst` − log(*c*), with the same per-surface *c*. VP keeps √density | General G needs non-negative values, and AFE's `y_vst` is negative at every zero cell. Moran's I is unchanged by the shift, so I and G read the same surface (`g_scale()` in `r/spatial_helpers.R`; [plan: Phase 2](gfw_analysis_plan.qmd#sec-global)) |  |
| D-028 | Correlogram range of 3–5 km | **Borderline: queen stays primary, and a distance-band run is added to Phase 3** at the range rounded up to a whole km | The plan's gate covered < 3 km and > 5 km only. A censored range (I ≥ 0.1 at 20 km) counts as > 5 km. Every band run is capped at 10 km, censored or not (VP fixed's uncensored ~18 km range would otherwise give a 19 km band) |  |
| D-029 | *ρ*₀ | **Median of the three stage ranges** per dataset × gear, from the distance correlogram of `y_vst` (2-km annuli to 20 km, threshold I = 0.1) | One prior per dataset × gear model in Phases 6–7, written to `global_rho0.csv` and its sidecar |  |
| D-030 | VP mobile range prior | Its correlogram is **censored** (I ≥ 0.1 at 19 km in every stage), so the Phase 2 *ρ*₀ is a lower bound only. **Phase 7 takes its range prior from the Matérn range of the Phase 6 `sdmTMB` fit** | Phase 6 meshes and CV blocks for VP mobile use the 10 km cap. The other five dataset × gear priors use the Phase 2 *ρ*₀ ([plan: Phase 6 models](gfw_analysis_plan.qmd#sec-models)) |  |
| D-031 | Interval for I | **Cell-block bootstrap**, blocks of side *ρ*₀ clamped to 3–10 km, shifted to centre on the full-grid I | Moran's I is reported with an interval as well as the permutation null band |  |

### 2026-10-19, Ørsted infrastructure

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-021 | Where it is built | **In `05` (Phase 0, step 8)**, not a separate `09`. Layers in `data/sf/infra/infrastructure.gpkg` (writing to `data/sf/infra/` approved) | The exposure covariates sit in the month and season-year analysis tables from the start, so Phases 1 and 5 read one table ([plan: Ørsted infrastructure](gfw_analysis_plan.qmd#sec-infra)) | Superseded by D-060 |
| D-022 | Multi-day installations | The foundation CSVs (which replaced the Excel files) give **one row per installation day**: first day = `foundation_installed`, last = `foundation_end`; repeated rows must agree on position, structure and depth | Multi-day installs (e.g. RWF Z01a, 17 days) count as under construction for every day they span |  |
| D-023 | SFW turbine ids | *Superseded 2026-10-20 (see "SFW crosswalk" above).* The PSO report's A01–A15 had no published crosswalk to the layout positions; Z01 was placed on AP06 and the 12 turbines shared the turbine window, 2023-07-02 to 2023-08-07 | — | Superseded by D-032 |
| D-024 | SRW's 40 unrecorded positions | **Planned, not installed.** Sensitivity: installed from May 2026 | The primary covariates count 45 SRW foundations at the end of the window. A second table (`infra_cell_month_srw_planned.csv`) gives the upper-bound exposure |  |
| D-025 | Cable timing | **Static routes + coarse project windows.** Cable-lay dates per route are not published | `d_cable_km` is static. `cable_works(t)` is on only where a window is known (SFW 2023-03 to 2023-09; RWF inter-array from 2025-11) |  |
| D-026 | Substations | **Counted with turbines** in the foundation covariates | A jacket or monopile is the same seabed obstruction to gear; the covariates are renamed `d_found_km`, `n_found_2km` |  |

### 2026-10-19, BAG power

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-019 | Simulation power analysis | **Added to Phase 5** (step 3): minimum detectable BAG effect per gear × dataset, from the Phase 6 base model with injected effects | Every BAG estimate is reported against its MDE. A gear with MDE > 50% is reported descriptively ([plan: BAG power analysis](gfw_analysis_plan.qmd#sec-bag-power)). |  |
| D-020 | Pre-trend equivalence test | **Added to Phase 5** (step 4): TOST on band-specific pre-construction trends at cell level, margin tied to the MDE | Parallel trends must be shown, not just not rejected ([plan: pre-trend test](gfw_analysis_plan.qmd#sec-bag-pretrend)) |  |

### 2026-10-19, Phase 1 gate

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-016 | Transforms | **Kept**: √ for VP, log(density + *c*) for AFE. No dataset × gear met the step 3 switch rule | `y_vst` in `05` unchanged |  |
| D-017 | Pre-window screen | Cailyn & Maren (338389953) was flagged on 5 VP h (2 in the leases): **no action**. A hull now needs **≥ 20 pre-window hours** to be flagged | No hull goes back to `03`; the Stage 1 baseline stands |  |
| D-018 | Pre-construction trends | No band × year test rejected parallel trends, but power is low, and the raw all-vessel series is dominated by project survey traffic inside the leases (2018–2020). **Proceed with the within-AOI BAG**, and add a **band × year pre-trend term for every gear as a Phase 8 sensitivity run** | The raw all-vessel series is not used as an uptake measure |  |

### 2026-10-18, third follow-up

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-013 | Descriptive time steps | **The same for every gear and dataset:** stage (default), stage × season (Apr–Sep / Oct–Mar) and season-year (22 steps) | Moran's I, General G, LISA, Gi\* and the maps are comparable across gears, because none of them changes with the time step. The seasons are Apr–Sep and Oct–Mar because both stage boundaries fall between them ([plan: time steps](gfw_analysis_plan.qmd#sec-time-steps)). |  |
| D-014 | Model time steps | **A shared stage × season BAG model** for every modelled gear. **Timing models:** monthly for VP and mobile AFE, season-year for fixed AFE | The BAG effects are comparable across gears. Monthly resolution is kept only where the data support it ([plan: time steps](gfw_analysis_plan.qmd#sec-time-steps)). |  |
| D-015 | Season standardisation | **Level comparisons only** (stage rate tables, density-difference maps, descriptive BAG). Raw rates for the spatial statistics. **Never in the models**, which carry a season term instead | The standardisation costs at most 4% of effective sample size, so its noise is negligible. The spatial statistics are unaffected by multiplying a surface by a constant, so they gain little from it. Rescaled hours are no longer counts, which would break NB2 (caveat 8). |  |

### 2026-10-18, second follow-up

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-011 | PROVIDER (367717050) | Charter window moved back to **2020-06-18** (`references/vessel_decisions.csv`; reasoning in its `Notes`) | Its June–September 2020 hours leave Primary Stage 1. 03 and 04 re-run, and every number in this plan re-measured afterwards. |  |
| D-012 | `.renvignore` | Added: `planning/`, plus the gitignored `r/scratchpad/` and `.venv/` | renv's dependency scan no longer counts the plan's example chunks as used packages. When `.renvignore` exists, renv reads it instead of `.gitignore`, so the gitignored code folders are listed too. |  |

### 2026-10-18, follow-up

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-005 | Dependencies | **Approved, phase by phase** | Each package in [plan: workflow overview](gfw_analysis_plan.qmd#sec-workflow) is installed and snapshotted when its phase starts. |  |
| D-006 | `mgcv` | **Pinned** in `renv.lock`: 1.9-3, with `Matrix` 1.7-4 and `nlme` 3.1-168 | Available to Phases 5–6 with a recorded version |  |
| D-007 | PROVIDER (367717050) | Charter window changed to **2020-10-01 onward**; 03 and 04 re-run | Its Stage 2–3 hours are out of Primary. Stage 1 2020 is still open (caveat 11 in [plan: caveats](gfw_analysis_plan.qmd#sec-caveats)). Numbers in this plan were re-measured after the change. | Superseded by D-011 |
| D-008 | Land | **The AOI does not touch land** | No barrier model. The SPDE field is stationary over open water ([plan: Phase 6 models](gfw_analysis_plan.qmd#sec-models)). |  |
| D-009 | Bathymetry | **Added as a model covariate** | NCEI CRM Vol. 1 (2023, 1 arc-second), with derived terrain covariates ([plan: environmental covariates](gfw_analysis_plan.qmd#sec-env)) |  |
| D-010 | Benthic habitat | **Pending from Ørsted** | Specification and coverage rules in [plan: environmental covariates](gfw_analysis_plan.qmd#sec-env). Models are built so the habitat terms can be added when the data arrive. |  |

### 2026-10-18, interview

| ID | Topic | Decision | Consequence | Status |
|---|---|---|---|---|
| D-001 | Stage 3 | **Keep the three stages** in `dev_stages` | Stage tables stay as built. Project timing enters only through the time-varying infrastructure covariates in the monthly BAG models ([plan: Phase 5 BAG](gfw_analysis_plan.qmd#sec-bag)). |  |
| D-002 | Control area | **Within-AOI gradient only** | BAG uses the 8–15 km ring as the reference. Inference is limited to redistribution, stated in every write-up ([plan: limits of the within-AOI BAG](gfw_analysis_plan.qmd#sec-bag-limits)). |  |
| D-003 | AKDE | **Assess, then drop** | [plan: Phase 4 AKDE](gfw_analysis_plan.qmd#sec-akde) records why AKDE does not fit these data, and what replaces it for visualisation. | Plan section removed (D-059) |
| D-004 | Timeline | **Thesis, about 3–6 months** | Full scope. INLA-SPDE is the confirmatory and extension model; the frequentist models are primary ([plan: Phase 6 models](gfw_analysis_plan.qmd#sec-models)). |  |
