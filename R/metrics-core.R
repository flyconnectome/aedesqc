# Core metric definitions shared by the live pipeline (qc-metrics.R,
# annotation-metrics.R) and the historical backfill (backfill-history.R). Every
# date in the committed history is therefore computed identically whether it
# came from a live aedes_meta() pull or an aedes_main FlyTable TSV dump — no
# discontinuity where the two series meet.
#
# Requires helpers.R (col_or_na, is_blank, status_matches) sourced first.

# QC issue masks (one logical per row of `meta`). Duplicate detection reads the
# server-maintained `root_duplicated` checkbox rather than recomputing it; NA
# (unchecked) cells count as FALSE.
qc_masks <- function(meta) {
  root_id  <- as.character(col_or_na(meta, "root_id"))
  svid     <- as.character(col_or_na(meta, "supervoxel_id"))
  position <- as.character(col_or_na(meta, "point_xyz"))
  type     <- as.character(col_or_na(meta, "type"))
  group    <- as.character(col_or_na(meta, "group"))
  rd <- as.logical(col_or_na(meta, "root_duplicated"))
  rd[is.na(rd)] <- FALSE
  list(
    root_id        = root_id,
    dup_rootid     = rd,
    missing_rootid = is_blank(root_id),
    missing_pos    = is_blank(position),
    bad_position   = !is_blank(position) & is_blank(svid),
    type_no_group  = !is_blank(type) & is_blank(group)
  )
}

# One row of scalar QC metrics. `n_stale` is supplied by the caller (a live
# chunkedgraph check for today's pull; NA for historical dumps, which cannot be
# checked against the current segmentation).
qc_metrics_row <- function(meta, date, n_stale = NA_integer_, masks = qc_masks(meta)) {
  status  <- as.character(col_or_na(meta, "status"))
  root_id <- masks$root_id
  uroot   <- unique(root_id[!is_blank(root_id)])
  dup_ids <- unique(root_id[masks$dup_rootid & !is_blank(root_id)])
  tibble::tibble(
    date                = date,
    n_rows              = nrow(meta),
    n_root_ids          = length(uroot),
    n_dup_rootids       = sum(masks$dup_rootid),
    n_dup_rootid_groups = length(dup_ids),
    n_duplicate_status  = sum(status_matches(status, "duplicate")),
    n_bad_nucleus       = sum(status_matches(status, "bad_nucleus")),
    n_missing_rootid    = sum(masks$missing_rootid),
    n_missing_position  = sum(masks$missing_pos),
    n_bad_position      = sum(masks$bad_position),
    n_type_no_group     = sum(masks$type_no_group),
    n_stale_rootids     = n_stale
  )
}

# Annotation coverage fields -> history column names, in report order. Add or
# remove here as the schema evolves; col_or_na() tolerates ones a given dump
# does not (yet) have.
annotation_fields <- c(
  side          = "n_side",
  superclass    = "n_superclass",
  class         = "n_class",
  subclass      = "n_subclass",
  subsubclass   = "n_subsubclass",
  type          = "n_type",
  group         = "n_group",
  hemilineage   = "n_hemilineage",
  nerve         = "n_nerve",
  neurotransmitter_verified = "n_nt_verified",
  proofreader   = "n_proofreader",
  annotator     = "n_annotator"
)

# One row of annotation-coverage counts (rows with a non-empty value per field).
annotation_metrics_row <- function(meta, date) {
  row <- tibble::tibble(date = date, n_rows = nrow(meta))
  for (f in names(annotation_fields))
    row[[annotation_fields[[f]]]] <- sum(!is_blank(col_or_na(meta, f)))
  row
}

# Long-format per-superclass counts for one day (blank -> "<none>").
by_superclass_counts <- function(meta, date) {
  superclass <- as.character(col_or_na(meta, "superclass"))
  tibble::tibble(superclass = ifelse(is_blank(superclass), "<none>", superclass)) |>
    dplyr::count(superclass, name = "n") |>
    dplyr::mutate(date = date, .before = 1)
}

# Long-format per-status counts for one day (proofreading-workflow field).
by_status_counts <- function(meta, date) {
  status <- as.character(col_or_na(meta, "status"))
  tibble::tibble(status = ifelse(is_blank(status), "<none>", status)) |>
    dplyr::count(status, name = "n") |>
    dplyr::mutate(date = date, .before = 1)
}
