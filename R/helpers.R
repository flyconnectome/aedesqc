# Shared helpers for the aedesqc metric scripts (QC + annotation).

# Return a column if present, else a vector of NA of the right length. QC infra
# should degrade gracefully on schema drift rather than crash, so we probe
# rather than assume every column exists.
col_or_na <- function(df, name) {
  if (name %in% names(df)) df[[name]] else rep(NA, nrow(df))
}

# TRUE where a value is effectively empty. Handles both dump columns (read as
# character, blank = "") and live aedes_meta() columns (e.g. `group` comes back
# numeric with ungrouped = NaN, which as.character() turns into "NaN"). "0" is
# treated as blank too, honouring the aedes convention that group = 0 means
# ungrouped (no 0 currently exists in the data, but the guard is harmless).
is_blank <- function(x) {
  x <- trimws(as.character(x))
  is.na(x) | x %in% c("", "0", "NA", "NaN")
}

# TRUE for each status value containing any of `drop` as a token. Handles
# multi-select (comma-separated) status columns and is case-insensitive, so
# aedes's lowercase "duplicate" and a capitalised variant both match. Mirrors
# fafbseg:::status_matches (not exported), kept local so the scripts don't reach
# into the package internals.
status_matches <- function(status, drop) {
  if (!length(drop)) return(logical(length(status)))
  drop <- tolower(trimws(drop))
  toks <- strsplit(tolower(as.character(status)), ",", fixed = TRUE)
  vapply(toks, function(t) any(trimws(t) %in% drop), logical(1))
}

utc_date <- function() format(Sys.time(), "%Y-%m-%d", tz = "UTC")

# Append `new` (one day's rows) to a committed history CSV, replacing any
# existing rows for the same date so a same-day re-run overwrites rather than
# duplicates.
append_dedup <- function(path, new) {
  # Force date to character so bind_rows() doesn't clash with readr's
  # auto-parsed Date column when re-reading an existing history file.
  old <- if (file.exists(path))
    readr::read_csv(path, show_col_types = FALSE,
                    col_types = readr::cols(date = readr::col_character()))
  else new[0, ]
  old <- old[!old$date %in% new$date, , drop = FALSE]
  out <- dplyr::bind_rows(old, new) |> dplyr::arrange(.data$date)
  readr::write_csv(out, path)
  out
}

# Build a day-on-day delta formatter closed over the current `row` and the
# previous run's `prev` row (or NULL). Returns "" when unchanged/unavailable.
make_delta <- function(row, prev) {
  function(field) {
    if (is.null(prev) || is.na(prev[[field]]) || is.na(row[[field]])) return("")
    d <- row[[field]] - prev[[field]]
    if (d == 0) return("")
    sprintf(" (%+d)", d)
  }
}

# Build a :warning: emoji flag for metrics that got worse since the last run.
make_warn <- function(row, prev) {
  function(field, worse_when_up = TRUE) {
    if (is.null(prev) || is.na(prev[[field]]) || is.na(row[[field]])) return("")
    d <- row[[field]] - prev[[field]]
    if ((worse_when_up && d > 0) || (!worse_when_up && d < 0)) " :warning:" else ""
  }
}
