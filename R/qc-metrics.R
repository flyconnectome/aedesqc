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

# --- pull ------------------------------------------------------------------

# drop_status = NULL so `duplicate` / `bad_nucleus` rows are retained and can be
# counted (aedes_meta passes drop_status through to fafbseg::cam_meta()).
message("Pulling aedes_main ...")
meta <- aedes_meta(drop_status = NULL, refresh = TRUE)
message(sprintf("  %d rows, %d columns", nrow(meta), ncol(meta)))

root_id  <- as.character(col_or_na(meta, "root_id"))
svid     <- as.character(col_or_na(meta, "supervoxel_id"))
position <- as.character(col_or_na(meta, "point_xyz"))
status   <- as.character(col_or_na(meta, "status"))
annotator <- as.character(col_or_na(meta, "annotator"))

# aedes status tokens are lowercase (cf. CRANT's uppercase DUPLICATED). These
# are manual flags: `duplicate` = "known duplicate, keep anyway"; `bad_nucleus`
# = flagged nucleus. Token-wise match handles multi-select comma-joined values.
is_dup_status   <- status_matches(status, "duplicate")
is_bad_nucleus  <- status_matches(status, "bad_nucleus")

# `root_duplicated` is a server-maintained checkbox column, set every 30 min by
# aedes:::aedes_flytable_update(): TRUE for root_ids with 2+ rows AFTER setting
# aside rows with status == "duplicate". So, unlike CRANT, we do NOT recompute
# duplicate clashes here — we just read the column. Unchecked cells come back
# as NA; treat as FALSE.
is_dup_rootid <- as.logical(col_or_na(meta, "root_duplicated"))
is_dup_rootid[is.na(is_dup_rootid)] <- FALSE
dup_ids <- unique(root_id[is_dup_rootid & !is_blank(root_id)])

# QC issue masks:
missing_rootid <- is_blank(root_id)                    # no root_id
missing_pos    <- is_blank(position)                   # no point_xyz
bad_position   <- !is_blank(position) & is_blank(svid) # point present, no supervoxel

# --- stale root ids (chunkedgraph) -----------------------------------------

# The FlyTable job refreshes root_ids every 30 min, so this should be ~0 — it is
# a canary for that job stalling rather than a routine backlog.
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
row <- tibble(
  date                = today,
  n_rows              = nrow(meta),
  n_root_ids          = length(uroot),
  # actionable QC issues
  n_dup_rootids       = sum(is_dup_rootid),   # rows the server flagged root_duplicated
  n_dup_rootid_groups = length(dup_ids),      # distinct root_ids affected
  n_duplicate_status  = sum(is_dup_status),   # manually flagged "keep anyway"
  n_bad_nucleus       = sum(is_bad_nucleus),
  n_missing_rootid    = sum(missing_rootid),
  n_missing_position  = sum(missing_pos),
  n_bad_position      = sum(bad_position),
  n_stale_rootids     = n_stale
)

print(as.data.frame(row))

# --- persist history -------------------------------------------------------

history <- append_dedup("metrics/qc_history.csv", row)

# --- Slack payload ---------------------------------------------------------

prev <- history[history$date != today, , drop = FALSE]
prev <- if (nrow(prev)) prev[nrow(prev), ] else NULL

delta <- make_delta(row, prev)
warn  <- make_warn(row, prev)

line <- function(label, field, worse_when_up = TRUE) {
  sprintf("• %s: *%s*%s%s", label, row[[field]], delta(field), warn(field, worse_when_up))
}

# Per-annotator problem counts (any actionable QC issue), latest run.
problem <- missing_rootid | missing_pos | bad_position | is_dup_rootid | is_stale
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
  line("Duplicate root_ids to check", "n_dup_rootids"),
  sprintf(" over %d root_ids", row$n_dup_rootid_groups), "\n",
  line("Missing root_id", "n_missing_rootid"), "\n",
  line("Missing position", "n_missing_position"), "\n",
  line("Bad position", "n_bad_position"), "\n",
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
