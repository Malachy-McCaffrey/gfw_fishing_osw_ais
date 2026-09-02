# GFW FIXED INFRASTRUCTURE DATA AS OF 11/25 # 

library(tidyverse)
library(sf)

fixed <- read_csv("sar_fixed_infrastructure_202511.csv")

wind <- fixed |> 
  filter(label == "wind")

write_csv(wind, "gfw_wind_infra.csv")

# convert wind csv into shp, set lat long to correct col names

wind_pts <- st_as_sf(wind, coords = c("lat", "lon"))

# set crs of wind_pts to same as aoi

aoi <- st_read("shapefiles/aoi.shp") |> 
  select(geometry)

wind_pts <- st_set_crs(wind_pts, st_crs(aoi))

# export sf

st_write(wind_pts, "shapefiles/gfw_wind_pts.shp") # only includes BIWF turbines, one rev wind turbine, and three VW1 turbines

# what if we include noise?

wind_noise <- fixed |> 
  filter(label == c("wind", "noise"))

wind_noise |> 
  group_by(label) |> 
  summarise(n())

wind_noise_pts <- st_as_sf(wind_noise, coords = c("lon", "lat"))

wind_noise_pts <- st_set_crs(wind_noise_pts, st_crs(aoi))

st_write(wind_noise_pts, "shapefiles/gfw_wind_noise_pts.shp")


