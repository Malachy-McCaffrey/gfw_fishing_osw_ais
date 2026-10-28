# gfw_fishing_osw_ais

R via renv. Active development lives in r/.

Orientation: start with the "Repository map" in README.md. Phase status is the
Status table at the top of planning/gfw_analysis_plan.qmd; decisions are logged,
by ID, in planning/decisions.md (add new ones there, newest first, and cite the
ID where the decision shows up). Every path lives in r/paths.R.

Python is archived at archive/python/ — frozen, not actively developed, but still
runnable via uv (`uv run`, `uv add` — never bare pip or python) from the repo root;
pyproject.toml stays at the root and points into archive/python/. Treat it as
reference material: don't extend it with new features, but it's fair game to run,
read, or fix for reproducibility.

Never modify anything in data/
Ask before installing new dependencies.
Propose a plan before multi-file changes.