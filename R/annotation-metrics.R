#!/usr/bin/env Rscript

# Daily annotation-coverage metrics for the Aedes (aedes_main) FlyTable.
#
# Companion to R/qc-metrics.R. Where the QC script counts data-integrity
# problems, this one tracks how much of the table has been *annotated*: coverage
# of each descriptive field, a per-superclass breakdown, and per-annotator
# contribution counts. Appends to metrics/annotation_history.csv and
# metrics/by_superclass_history.csv and writes a Slack payload.
#
# Requires FLYTABLE_TOKEN (aedes_meta). No CAVE token needed — annotation
# coverage never touches the chunkedgraph.

suppressPackageStartupMessages({
  library(aedes)
  library(dplyr)
})

source("R/helpers.R")
source("R/metrics-core.R")

# --- pull ------------------------------------------------------------------

# drop_status = NULL to describe the whole table. refresh = FALSE: qc-metrics.R
# runs first in the workflow and has already refreshed the row-wise flytable
# cache this run, so this is a fast local read. Metric definitions live in
# metrics-core.R, shared with the historical TSV backfill.
message("Pulling aedes_main ...")
meta <- aedes_meta(drop_status = NULL, refresh = FALSE)
message(sprintf("  %d rows, %d columns", nrow(meta), ncol(meta)))

today <- utc_date()
row <- annotation_metrics_row(meta, today)

print(as.data.frame(row))

# --- persist history -------------------------------------------------------

history <- append_dedup("metrics/annotation_history.csv", row)
append_dedup("metrics/by_superclass_history.csv", by_superclass_counts(meta, today))
append_dedup("metrics/by_status_history.csv", by_status_counts(meta, today))

# Per-annotator row counts (contribution, not problems).
annotator <- as.character(col_or_na(meta, "annotator"))
ann_tbl <- tibble(annotator = ifelse(is_blank(annotator), "<unknown>", annotator)) |>
  count(annotator, name = "n") |>
  arrange(desc(.data$n))

# --- Slack payload ---------------------------------------------------------

prev <- history[history$date != today, , drop = FALSE]
prev <- if (nrow(prev)) prev[nrow(prev), ] else NULL

delta <- make_delta(row, prev)

pct <- function(field) sprintf("%.0f%%", 100 * row[[field]] / row$n_rows)
line <- function(label, field)
  sprintf("• %s: *%s* (%s)%s", label, row[[field]], pct(field), delta(field))

ann_txt <- if (nrow(ann_tbl)) {
  top <- head(ann_tbl, 10)
  paste0("\n\n*Rows by annotator (top 10):*\n",
         paste(sprintf("• %s: %d", top$annotator, top$n), collapse = "\n"))
} else ""

text <- paste0(
  "*Aedes annotation — ", today, "*  _(", row$n_rows, " rows)_\n",
  line("side", "n_side"), "\n",
  line("superclass", "n_superclass"), "\n",
  line("class", "n_class"), "\n",
  line("type", "n_type"), "\n",
  line("hemilineage", "n_hemilineage"), "\n",
  line("proofreader", "n_proofreader"), "\n",
  line("annotator", "n_annotator"),
  ann_txt,
  "\n\n<https://flyconnectome.github.io/aedesqc/annotation.html|Annotation dashboard> · ",
  "<https://flyconnectome.github.io/aedesqc/|QC dashboard>"
)

dir.create("report", showWarnings = FALSE)
jsonlite::write_json(list(text = text), "report/annotation_slack_payload.json",
                     auto_unbox = TRUE, pretty = TRUE)
message("Wrote report/annotation_slack_payload.json")
message("Done.")
