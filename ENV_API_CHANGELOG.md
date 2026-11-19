# Drona environment API changelog

`DRONA_ENV_API` (in `views/env_api.py`) is the version of what environments can rely on: map.json syntax,
schema elements and flags, `runtime_support` functions and form components, and driver variables. It is not
the app's release number.

- **Minor** bump: something new environments can use (a new element, schema flag, shared function, or form component).
- **Major** bump: something environments relied on was removed or changed incompatibly.

Bump it in the same change that adds the feature, and add a line here.

An environment declares what it needs with `requires_drona` in its `manifest.yml` and in its `metadata.json`
entry in the environment repo:

```yaml
requires_drona: ">=2.0"        # or ">=2.1,<3"; a bare "2.1" means ">=2.1"
```

Without `requires_drona` an environment is treated as compatible. Drona refuses to import an environment whose
requirement doesn't match, shows it disabled in the Import dialog, and shows a warning when an already
installed environment is opened.

## 2.1

Added:

- Pending job card: `forms/drona_info_pending.json` (`drona_pending_section`) with
  `schedulers/slurm/retrievers/drona_slurm_pending.sh` (why the job waits, estimated start, queue
  position, priority factors, overlapping maintenance reservations).
- Finished job card: `forms/drona_info_outcome.json` (`drona_outcome_section`) with
  `schedulers/slurm/retrievers/drona_slurm_outcome.sh` (how the job ended, exit code, failed steps,
  first error line, blocked workflow jobs).
- Both Slurm jobs cards (`drona_slurm_jobs_panel.json`, `drona_slurm_jobs_table.json`) show a one-line
  reason under pending and unsuccessful jobs and refresh every 60 s while the workflow isn't done.
- `drona_slurm_seff.sh` with `VIEW=compact`: a "Next run" line with smaller requests for successful jobs.

Removed:

- The pre-2.0 `runtime_support` paths (`form_components/`, `map_references/`, `retriever_scripts/`,
  `html_templates/`), `runtime_support/aliases.json`, the `driver_scripts/drona_wf_driver_sbatch`
  symlink and `legacy/` (`drona_info_nodeutil.json`, the utilization panels, `drona_select_wf`,
  `drona_slurm_nodeutil.sh`, `drona_slurm_cgroups.sh`). Use the 2.0 paths; drona-v2 environments
  already do. Environments still on the old paths need `requires_drona: "<2.1"`.

## 2.0

First versioned API (the `hprc-dev` line). Environments written for it need at least:

- `runtime_support`: `$DRONA_RUNTIME_DIR` / `$DRONA_ENV_DIR` in schema `$ref`s, shared form components
  (`forms/*.json`), map fragments (`maps/`), shared retriever scripts (`retrievers/`,
  `schedulers/slurm/retrievers/`), `drona_runtime_utils`, and the submit tool
  `schedulers/slurm/drona_wf_driver_sbatch` (with `#DRONA label:` stage labels). The pre-2.0 paths
  (`form_components/`, `map_references/`, `retriever_scripts/`, `html_templates/`,
  `driver_scripts/drona_wf_driver_sbatch`) still resolve through `runtime_support/aliases.json`
  (removed in 2.1). See `runtime_support/CATALOG.md`.
- map.json `$include` and order-independent `[KEY]` substitution
- built-in retrievers (`builtin:db_lookup`, `builtin:db_options`, `builtin:db_job_options`)
- elements: `dynamicTable`, `chart` (incl. `enableZoom`), collapsible card layout, layout frame and shared choice options
- retriever polling (`refreshInterval`), the retriever timeout, and paused retrievers in collapsed containers
- hidden additional files (`preview_order: -1`)
- shared workflow manage actions (rerun/recreate/cancel), job/node scope pickers, CPU/GPU monitoring
- runs on an existing workflow: reserved field `drona_target_wf` (schema flag `"workflowTarget": true`),
  no new record, script in `<wfdir>/.drona/runs/<timestamp>/`, run started in the workflow directory,
  `DRONA_WF_NAME` and `DRONA_RUN_DIR`, jobinfo append in `drona_wf_driver_sbatch`. Env code that deletes
  `$DRONA_WF_ID` as manage self-cleanup must skip it when `DRONA_RUN_DIR` is set.

Environments from before 2.0 (no `requires_drona`) keep working.
