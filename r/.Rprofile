# Quarto (render and preview) starts R in the qmd's own folder, r/, where the
# repo-root .Rprofile is not read, so renv never activated and packages came
# from the user library instead of renv.lock (e.g. "no package called
# 'spdep'"). Point renv at the repo root and activate it from here too.
Sys.setenv(RENV_PROJECT = normalizePath("..", winslash = "/"))
source("../renv/activate.R")
