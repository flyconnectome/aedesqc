# aedesqc

Daily quality-control **and** annotation-coverage metrics for the Aedes
(`aedes_main`) FlyTable, accessed through the
[aedes](https://github.com/flyconnectome/aedes) package. A scheduled GitHub
Action pulls `aedes_meta(drop_status = NULL)` once a day, computes two sets of
metrics, appends them to committed history files, renders two dashboards to
GitHub Pages, and (optionally) posts summaries to Slack.

The design mirrors [flyconnectome/crantqc](https://github.com/flyconnectome/crantqc);
see [Differences from crantqc](#differences-from-crantqc) for what changed.

## Reports

Two dashboards, one Pages site (<https://flyconnectome.github.io/aedesqc/>):

| page | script | what |
| --- | --- | --- |
| `index.html` (QC) | [`R/qc-metrics.R`](R/qc-metrics.R) → [`report/qc.Rmd`](report/qc.Rmd) | data-integrity: duplicates, missing/bad positions, stale ids |
| `annotation.html` | [`R/annotation-metrics.R`](R/annotation-metrics.R) → [`report/annotation.Rmd`](report/annotation.Rmd) | how much of the table is annotated, by field / superclass / annotator |

## Metrics

**QC** — one row per run in [`metrics/qc_history.csv`](metrics/qc_history.csv):

| column | meaning |
| --- | --- |
| `n_rows` | total rows in `aedes_main` |
| `n_root_ids` | distinct non-empty `root_id`s |
| `n_dup_rootids` | rows with `root_duplicated` ticked (server-maintained) |
| `n_dup_rootid_groups` | distinct root_ids those rows span |
| `n_duplicate_status` | rows manually tagged `status = duplicate` (keep-anyway) |
| `n_bad_nucleus` | rows tagged `status = bad_nucleus` |
| `n_missing_rootid` | rows with empty `root_id` |
| `n_missing_position` | rows with empty `point_xyz` |
| `n_bad_position` | `point_xyz` present but no `supervoxel_id` |
| `n_stale_rootids` | `root_id`s no longer current per the chunkedgraph (should be ~0) |

**Annotation** — [`metrics/annotation_history.csv`](metrics/annotation_history.csv)
(coverage counts per field) plus a per-superclass breakdown in
[`metrics/by_superclass_history.csv`](metrics/by_superclass_history.csv).

### History reconstruction

The history before the live pipeline started was reconstructed from archived
`aedes_main` FlyTable TSV dumps with [`R/backfill-history.R`](R/backfill-history.R)
(run locally over dumps in `data/`, which is git-ignored). It reuses the same
metric code as the live scripts ([`R/metrics-core.R`](R/metrics-core.R)) so
backfilled and live dates form one continuous series, and it never overwrites an
existing date — live rows always win. Two caveats on the reconstructed range
(2026-05-13 →):

- `n_stale_rootids` is **NA** for backfilled dates — currency can only be checked
  against the *current* segmentation, not a historical dump.
- The daily dumps were not refreshed at weekends, so ~3-day stretches carry the
  previous Friday's values forward (visible as small stair-steps in the trends).

## Differences from crantqc

| | crantqc | aedesqc |
| --- | --- | --- |
| Metadata source | `crant_meta()` (CRANTb seatable) | `aedes_meta()` (`aedes_main` FlyTable via `fafbseg::cam_meta()`) |
| Table token | `CRANTTABLE_TOKEN` | **`FLYTABLE_TOKEN`** |
| CAVE host | `proofreading.zetta.ai` | **`global.daf-apis.com`** (flywire middleauth), datastack `wclee_aedes_brain` |
| Dataset scoping | crantr is dataset-specific | flywire calls wrapped in `aedes::with_aedes()` |
| `status` meaning | QC flags (`DUPLICATED`, …) | **proofreading workflow** (`adequate`, `to_review`, `needs_extending`, …); `duplicate` is one QC-relevant token |
| Duplicate `status` token | uppercase, multi-select `DUPLICATED` | lowercase `duplicate` |
| Duplicate detection | recomputed in the QC script | read from the server-maintained **`root_duplicated`** column (set every 30 min by the FlyTable job) |
| Position column | `position` | **`point_xyz`** |
| Annotation columns | `super_class`, `cell_class`, `cell_type` | `superclass`, `class`, `subclass`, `subsubclass`, `type`, `hemilineage`, … |
| Stale-id check | `crant_islatest()` | `with_aedes(fafbseg::flywire_islatest())` |

Both stacks reach seatable through the same Python `seatable_api` package
(reticulate), so the CI Python setup is unchanged.

## Setup

Repository secrets (**Settings → Secrets and variables → Actions**):

| secret | what |
| --- | --- |
| `FLYTABLE_TOKEN` | FlyTable/seatable API token (as used by `aedes_meta()`) |
| `FLYWIRE_CAVE_TOKEN` | flywire/CAVE token (32-char), for the stale-id check |
| `QC_SLACK_WEBHOOK_URL` | *optional* — Slack [Incoming Webhook](https://api.slack.com/messaging/webhooks) for the QC summary |
| `ANNOTATION_SLACK_WEBHOOK_URL` | *optional* — Slack webhook for the annotation summary |

Enable **Settings → Pages → Source: Deploy from a branch → `gh-pages`** after
the first successful run. Trigger a manual run from the **Actions** tab
(`aedes-qc` → *Run workflow*).

## Notes / roadmap

- **FlyTable QC-view deep links** — the *Duplicate root_ids to check* metric
  links to its FlyTable view (`vid=8yT4`) in both the dashboard and Slack. Add
  more by supplying the `vid` for each remaining QC view (missing/bad position,
  etc.) in `report/qc.Rmd` and `R/qc-metrics.R`.
- **Phase 2**: fill in [`annotators.csv`](annotators.csv) to @-mention the
  responsible person in Slack instead of listing plain annotator names.
