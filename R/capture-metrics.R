#!/usr/bin/env Rscript

# Fetch the synapse capture results that the aedes snapshot server publishes
# (see aedes/inst/scripts/synsnap-capture.R) for report/capture.Rmd, and check
# that the snapshot and capture results are up to date.
#
# Reads the snapshot server's status.json (latest snapshot; ok is FALSE if the
# newest snapshot is too old or the last run failed) and downloads into
# capture/ (not committed):
#   index.json         capture results status (latest tag, ok)
#   history.csv        capture at the end of each tier etc. for every snapshot
#   latest.parquet     full capture curves for the latest snapshot
# and writes report/capture_status.json, which qc-metrics.R uses to flag stale
# data in the QC Slack summary. Failing to fetch is reported there rather than
# failing the workflow, so the other dashboards still update.
#
# Needs the CAVE token (written by the workflow) to work out the publish address
# unless the aedes.snapshot_url option is set.

suppressPackageStartupMessages(library(aedes))

# The server itself flags old snapshots; this only checks that the server and
# the capture step (run hourly by cron) are still running.
MAX_AGE_HOURS <- 6

dir.create("capture", showWarnings = FALSE)
dir.create("report", showWarnings = FALSE)
now <- Sys.time()
problems <- character()
problem <- function(...) problems <<- c(problems, paste0(...))

# the publish address is deliberately unguessable, so keep it out of messages
oops <- function(what, url) function(e) {
  problem("could not ", what, " ", basename(url), ": ",
          gsub(dirname(url), "<url>", conditionMessage(e), fixed = TRUE))
  NULL
}
fetch <- function(url, file) {
  tryCatch({
    utils::download.file(url, file.path("capture", file), mode = "wb", quiet = TRUE)
    file.path("capture", file)
  }, error = oops("download", url))
}
read_json <- function(url) tryCatch(
  jsonlite::fromJSON(paste(readLines(url, warn = FALSE), collapse = "\n")),
  error = oops("read", url))
age_hours <- function(ts)
  as.numeric(difftime(now, as.POSIXct(ts, tz = "UTC"), units = "hours"))
check_age <- function(what, ts) {
  if (is.null(ts) || is.na(ts)) return(problem(what, ": no timestamp"))
  h <- age_hours(ts)
  if (h > MAX_AGE_HOURS)
    problem(sprintf("%s is %.0f hours old (%s)", what, h, ts))
}

base <- tryCatch(aedes_snapshot_url(), error = function(e) {
  problem("could not work out the snapshot address: ", conditionMessage(e))
  NULL
})

status <- index <- NULL
if (!is.null(base)) {
  status <- read_json(file.path(base, "status.json"))
  if (!is.null(status)) {
    if (!isTRUE(status$ok))
      problem("snapshot server reported errors: ",
              paste(unlist(status$errors), collapse = "; "))
    check_age("last snapshot server run", status$time)
  }
  index_file <- fetch(file.path(base, "capture", "index.json"), "index.json")
  if (!is.null(index_file)) {
    index <- jsonlite::fromJSON(index_file)
    if (!isTRUE(index$ok))
      problem("capture failed for ", paste(names(index$errors), collapse = ", "))
    check_age("last capture run", index$created)
    if (!is.null(status) && !identical(index$latest, status$latest))
      problem("capture results (", index$latest, ") lag the latest snapshot (",
              status$latest, ")")
    if (!is.null(index$latest)) {
      fetch(file.path(base, "capture", "history.csv"), "history.csv")
      fetch(file.path(base, "capture", paste0(index$latest, ".parquet")),
            "latest.parquet")
    }
  }
}

res <- list(
  checked = format(now, tz = "UTC", usetz = TRUE),
  stale = length(problems) > 0,
  problems = as.list(problems),
  snapshot = status$latest,
  snapshot_timestamp = status$latest_timestamp,
  capture = index$latest,
  capture_timestamp = index$latest_timestamp
)
jsonlite::write_json(res, "report/capture_status.json", auto_unbox = TRUE,
                     pretty = TRUE, null = "null")
if (length(problems)) message("Capture data problems:\n  ",
                              paste(problems, collapse = "\n  "))
message("Wrote report/capture_status.json")
