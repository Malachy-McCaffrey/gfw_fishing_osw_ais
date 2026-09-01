#### GFW API ACCESS TOKEN #### 

library(usethis)


edit_r_environ(scope = "project")

Sys.getenv("GFW_TOKEN")

# Check/install remotes
#if (!require("remotes"))
#  install.packages("remotes")

#remotes::install_github("GlobalFishingWatch/gfwr",
#                        dependencies = TRUE)

install.packages("gfwr", 
                 repos = c("https://globalfishingwatch.r-universe.dev",
                           "https://cran.r-project.org"))

library(gfwr)
