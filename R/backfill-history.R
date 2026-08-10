#!/usr/bin/env Rscript

# One-off: reconstruct QC + annotation history from archived aedes_main FlyTable
# TSV dumps in data/ (named aedes_main_YYYY-MM-DDThh.tsv), so the dashboards show
# a trend going back before the live pipeline existed.
#
# Uses the same metric definitions as the live scripts (R/metrics-core.R), so
# backfilled dates and live dates form one continuous series. Dates already in a
# history file are left untouched — live rows (which carry a real n_stale from a
# chunkedgraph check) always win over a re-derived dump row.
#
# Local, offline, idempotent: no tokens, no network. Re-running only fills gaps.
#
#   Rscript R/backfill-history.R [dump_dir]   # default dump_dir = "data"

suppressPackageStartupMessages({
  library(dplyr)
})

source("R/helpers.R")
source("R/metrics-core.R")

dump_dir <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(dump_dir)) dump_dir <- "data"

dumps <- sort(Sys.glob(file.path(dump_dir, "aedes_main_*.tsv")))
if (!length(dumps)) stop("No aedes_main_*.tsv dumps found in ", dump_dir)
dates <- sub("^aedes_main_(\\d{4}-\\d{2}-\\d{2})T.*\\.tsv$", "\\1", basename(dumps))
message(sprintf("Found %d dumps: %s .. %s", length(dumps), dates[1], dates[length(dates)]))

# Read all columns as character: avoids readr type-guessing (some free-text
# columns trip the logical/number guesser) and matches how the metric helpers
# treat every field. root_duplicated "TRUE"/"FALSE" is parsed by qc_masks().
read_dump <- function(f)
  suppressWarnings(readr::read_tsv(f, col_types = readr::cols(.default = "c"),
                                   progress = FALSE))

existing_dates <- function(path) {
  if (!file.exists(path)) return(character(0))
  readr::read_csv(path, show_col_types = FALSE,
                  col_types = readr::cols(date = readr::col_character()))$date
}

paths <- list(
  qc   = "metrics/qc_history.csv",
  ann  = "metrics/annotation_history.csv",
  sc   = "metrics/by_superclass_history.csv",
  st   = "metrics/by_status_history.csv"
)
have <- lapply(paths, existing_dates)

acc <- list(qc = list(), ann = list(), sc = list(), st = list())
for (i in seq_along(dumps)) {
  d <- dates[i]
  # Nothing to do for this date if every history file already has it.
  if (all(vapply(have, function(h) d %in% h, logical(1)))) next
  meta <- read_dump(dumps[i])
  if (!(d %in% have$qc))  acc$qc[[d]]  <- qc_metrics_row(meta, d, n_stale = NA_integer_)
  if (!(d %in% have$ann)) acc$ann[[d]] <- annotation_metrics_row(meta, d)
  if (!(d %in% have$sc))  acc$sc[[d]]  <- by_superclass_counts(meta, d)
  if (!(d %in% have$st))  acc$st[[d]]  <- by_status_counts(meta, d)
  message(sprintf("  [%d/%d] %s: %d rows", i, length(dumps), d, nrow(meta)))
}

write_back <- function(key) {
  rows <- dplyr::bind_rows(acc[[key]])
  if (!nrow(rows)) { message("No new dates for ", paths[[key]]); return(invisible()) }
  out <- append_dedup(paths[[key]], rows)
  message(sprintf("%s: +%d dates -> %d rows total", paths[[key]], nrow(rows), nrow(out)))
}
invisible(lapply(names(paths), write_back))
message("Backfill done.")
