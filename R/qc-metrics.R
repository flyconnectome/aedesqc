#!/usr/bin/env Rscript

# Daily QC metrics for the Aedes (aedes_main) FlyTable.
#
# Pulls the full aedes_main table once via aedes_meta(drop_status = NULL) so
# every row (including `duplicate` / `bad_nucleus` rows) is retained and can be
# counted, computes a row of scalar QC metrics, checks root-id currency via the
# chunkedgraph, and appends the result to the committed history file. Also
# writes a Slack payload summarising the run (with day-on-day deltas).
#
# Annotation-coverage metrics live in R/annotation-metrics.R — this script is
# QC (data-integrity) only.
#
# Requires two secrets, supplied as environment variables by the workflow:
#   FLYTABLE_TOKEN  - FlyTable/seatable API token (aedes_meta)
#   the CAVE token  - written to ~/.cloudvolume/secrets by the workflow so
#                     flywire_islatest() can authenticate to the chunkedgraph.

suppressPackageStartupMessages({
  library(aedes)
  library(dplyr)
})

source("R/helpers.R")
source("R/metrics-core.R")

# --- pull ------------------------------------------------------------------

# drop_status = NULL so `duplicate` / `bad_nucleus` rows are retained and can be
# counted (aedes_meta passes drop_status through to fafbseg::cam_meta()).
message("Pulling aedes_main ...")
meta <- aedes_meta(drop_status = NULL, refresh = TRUE)
message(sprintf("  %d rows, %d columns", nrow(meta), ncol(meta)))

# Metric definitions live in metrics-core.R so this live pull and the historical
# TSV backfill (R/backfill-history.R) stay in lock-step.
masks     <- qc_masks(meta)
root_id   <- masks$root_id
annotator <- as.character(col_or_na(meta, "annotator"))

# --- stale root ids (chunkedgraph) -----------------------------------------

# The FlyTable job refreshes root_ids every 30 min, so this should be ~0 — it is
# a canary for that job stalling rather than a routine backlog. Historical dumps
# cannot be checked this way, so backfilled rows carry NA here.
n_stale <- NA_integer_
is_stale <- rep(FALSE, nrow(meta))
uroot <- unique(root_id[!is_blank(root_id)])
message(sprintf("Checking currency of %d unique root ids ...", length(uroot)))
latest <- tryCatch(
  aedes::with_aedes(fafbseg::flywire_islatest(uroot)),
  error = function(e) { message("  flywire_islatest failed: ", conditionMessage(e)); NULL }
)
if (!is.null(latest) && length(latest) == length(uroot)) {
  stale_ids <- uroot[!is.na(latest) & !latest]
  n_stale   <- length(stale_ids)
  is_stale  <- root_id %in% stale_ids
}

# --- assemble metrics row --------------------------------------------------

today <- utc_date()
row <- qc_metrics_row(meta, today, n_stale = n_stale, masks = masks)

print(as.data.frame(row))

# --- persist history -------------------------------------------------------

history <- append_dedup("metrics/qc_history.csv", row)

# --- Slack payload ---------------------------------------------------------

prev <- history[history$date != today, , drop = FALSE]
prev <- if (nrow(prev)) prev[nrow(prev), ] else NULL

delta <- make_delta(row, prev)
warn  <- make_warn(row, prev)

# FlyTable QC views: link a metric label to the view listing its rows. Only some
# views exist yet; pass vid = NULL to leave the label unlinked.
flytable_base <- "https://flytable.mrc-lmb.cam.ac.uk/workspace/148/dtable/aedes/?tid=0000&vid="
line <- function(label, field, vid = NULL, worse_when_up = TRUE) {
  lab <- if (is.null(vid)) label else sprintf("<%s%s|%s>", flytable_base, vid, label)
  sprintf("• %s: *%s*%s%s", lab, row[[field]], delta(field), warn(field, worse_when_up))
}

# Per-annotator problem counts (any actionable QC issue), latest run.
problem <- masks$missing_rootid | masks$missing_pos | masks$bad_position |
  masks$dup_rootid | is_stale
ann_tbl <- tibble(annotator = ifelse(is_blank(annotator), "<unknown>", annotator),
                  problem = problem) |>
  filter(.data$problem) |>
  count(annotator, name = "n") |>
  arrange(desc(.data$n))
ann_txt <- if (nrow(ann_tbl)) {
  paste0("\n\n*Problem rows by annotator:*\n",
         paste(sprintf("• %s: %d", ann_tbl$annotator, ann_tbl$n), collapse = "\n"))
} else ""

text <- paste0(
  "*Aedes QC — ", today, "*\n",
  line("Duplicate root_ids to check", "n_dup_rootids", vid = "8yT4"),
  sprintf(" over %d root_ids", row$n_dup_rootid_groups), "\n",
  line("Missing root_id", "n_missing_rootid"), "\n",
  line("Missing position", "n_missing_position"), "\n",
  line("Bad position", "n_bad_position"), "\n",
  line("Type but no group", "n_type_no_group"), "\n",
  line("Bad nucleus", "n_bad_nucleus"), "\n",
  line("Stale root_ids", "n_stale_rootids"),
  ann_txt,
  "\n\n_", row$n_rows, " rows, ", row$n_root_ids, " distinct root_ids. ",
  row$n_duplicate_status, " tagged status=duplicate (keep-anyway)._",
  "\n\n<https://flyconnectome.github.io/aedesqc/|QC dashboard> · ",
  "<https://flyconnectome.github.io/aedesqc/annotation.html|Annotation dashboard>"
)

dir.create("report", showWarnings = FALSE)
jsonlite::write_json(list(text = text), "report/qc_slack_payload.json",
                     auto_unbox = TRUE, pretty = TRUE)
message("Wrote report/qc_slack_payload.json")
message("Done.")
