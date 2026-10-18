# Grid-cell decision diagnostics behind the grid-cell decisions in
# r/02_build_grid.qmd. Run from the repo root.
# Q1: how much data sits in the 52 gfw_vp_id cells that fall outside the AOI
#     under the lower-left anchor?
# Q2: did the 51 AOI-touching cells with no records have data under the
#     centroid anchor, by cell key and by physical overlap?

suppressMessages({library(tidyverse); library(sf)})
res <- 0.01; crs <- 32619
rd <- function(p) read_csv(p, show_col_types = FALSE, col_types = cols(MMSI = col_character(), IMO = col_character())) |>
  mutate(ix = as.integer(round(Lon/res)), iy = as.integer(round(Lat/res)), cell_id = sprintf("%d_%d", ix, iy))
vp <- rd("data/raw/gfw/gfw_vp_id.csv"); afe <- rd("data/raw/gfw/gfw_afe_id.csv")
poly <- function(ix, iy, off) st_polygon(list(cbind((ix + c(0,1,1,0,0))/100 - off, (iy + c(0,0,1,1,0))/100 - off)))
mk <- function(d, off) st_sf(d, geometry = st_sfc(map2(d$ix, d$iy, poly, off = off), crs = 4326)) |> st_transform(crs)
aoi <- st_read("data/sf/aoi/Orsted_AOI.shp", quiet = TRUE) |> st_union() |> st_transform(crs)
cells <- distinct(vp, cell_id, ix, iy)
lat <- expand_grid(ix = seq(min(cells$ix)-2L, max(cells$ix)+2L), iy = seq(min(cells$iy)-2L, max(cells$iy)+2L)) |>
  mutate(cell_id = sprintf("%d_%d", ix, iy), has_data = cell_id %in% cells$cell_id)
L  <- mk(lat, 0);     L$touch_ll  <- lengths(st_intersects(L, aoi)) > 0
C  <- mk(lat, 0.005); C$touch_ctr <- lengths(st_intersects(C, aoi)) > 0
lat$touch_ll <- L$touch_ll; lat$touch_ctr <- C$touch_ctr
outside <- lat |> filter(has_data, !touch_ll)
empty   <- lat |> filter(!has_data, touch_ll)
cat("Q1: outside cells", nrow(outside), "\n")
summ <- function(d, v, ids) d |> filter(cell_id %in% ids) |> summarise(rows = n(), hours = sum(.data[[v]]), cells = n_distinct(cell_id),
  mmsi = n_distinct(MMSI), fishing_rows = sum(`Vessel Type` == "FISHING", na.rm = TRUE), fishing_mmsi = n_distinct(MMSI[`Vessel Type` %in% "FISHING"]))
print(bind_rows(VP = summ(vp, "Vessel Presence Hours", outside$cell_id), AFE = summ(afe, "Apparent Fishing Hours", outside$cell_id), .id = "file"))
cat("share of all VP rows:", round(100*mean(vp$cell_id %in% outside$cell_id),2), "%; of VP hours:",
    round(100*sum(vp$`Vessel Presence Hours`[vp$cell_id %in% outside$cell_id])/sum(vp$`Vessel Presence Hours`),2), "%\n")
cat("outside cells touch AOI under centroid anchor:", sum(outside$touch_ctr), "of", nrow(outside), "\n")
# rows per cell: outside vs inside
pc <- vp |> count(cell_id) |> mutate(grp = if_else(cell_id %in% outside$cell_id, "outside", "other"))
print(pc |> group_by(grp) |> summarise(median_rows_per_cell = median(n), mean = round(mean(n),1)))
cat("\nQ2: empty cells", nrow(empty), "; records under their keys:", sum(vp$cell_id %in% empty$cell_id), "\n")
cat("empty cells touch AOI under centroid anchor:", sum(empty$touch_ctr), "of", nrow(empty), "\n")
ctr_empty <- lat |> filter(!has_data, touch_ctr)
cat("centroid-anchor AOI cells with no data:", nrow(ctr_empty), "; of these also in the 51:", sum(ctr_empty$cell_id %in% empty$cell_id), "\n")
# physical area of the 51 ll cells: overlapped by which centroid-grid cells with data?
Le <- L[L$cell_id %in% empty$cell_id, ]
Cd <- C[C$has_data, ]
ov <- st_intersection(select(Le, e_id = cell_id), select(Cd, c_id = cell_id)) |> mutate(a = as.numeric(st_area(geometry)))
ov <- ov |> filter(a > 1)
cov <- ov |> st_drop_geometry() |> group_by(e_id) |> summarise(frac_covered = sum(a)/as.numeric(st_area(Le[1,])), n_ctr_cells = n())
cat("of the 51, area overlapped by centroid-grid cells with data: ", nrow(cov), "cells overlapped; frac covered summary:\n"); print(summary(cov$frac_covered))
cat("VP rows in centroid-grid cells overlapping the 51:", sum(vp$cell_id %in% unique(ov$c_id)), "\n")
