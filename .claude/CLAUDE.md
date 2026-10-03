# gfw_fishing_osw_ais

R via renv. Active development lives in r/.

Python is archived at archive/python/ — frozen, not actively developed, but still
runnable via uv (`uv run`, `uv add` — never bare pip or python) from the repo root;
pyproject.toml stays at the root and points into archive/python/. Treat it as
reference material: don't extend it with new features, but it's fair game to run,
read, or fix for reproducibility.

Never modify anything in data/
Ask before installing new dependencies.
Propose a plan before multi-file changes.