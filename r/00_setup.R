#### PROJECT SETUP ####
# Run once per machine, line by line, from the repo root (the folder holding
# renv.lock). renv activates itself through .Rprofile when R starts there.

# 1. Install every package at the version in renv.lock, including gfwr from
#    the Global Fishing Watch r-universe. Use R 4.5.x, the version the lockfile
#    was made with. Do not install.packages() into this project: anything
#    installed outside renv.lock is not reproducible.
renv::restore()

# 2. Store the GFW API token. Opens the project-level .Renviron (gitignored);
#    add a line GFW_TOKEN=your_token_here, save, and restart R. Request a
#    token at https://globalfishingwatch.org/our-apis. Only 01_pull_gfw.qmd
#    and 03_review_vessels.qmd with run_gfw_api: true need it.
usethis::edit_r_environ(scope = "project")

# 3. After restarting R, check the token is visible (should be TRUE)
nzchar(Sys.getenv("GFW_TOKEN"))

# 4. Check the R tests pass
testthat::test_dir("r/tests/testthat")
