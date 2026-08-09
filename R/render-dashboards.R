#!/usr/bin/env Rscript

# Render both dashboards to public/ for GitHub Pages:
#   report/qc.Rmd         -> public/index.html        (QC landing page)
#   report/annotation.Rmd -> public/annotation.html
suppressPackageStartupMessages(library(rmarkdown))

dir.create("public", showWarnings = FALSE)

# Resolve the include to an absolute path *eagerly*: render() setwd()s into the
# Rmd's dir before forcing output_options (a promise), so a relative path would
# resolve against report/ and be lost. Absolute path is CWD-independent.
header <- normalizePath("report/header.html", mustWork = TRUE)

render_one <- function(rmd, out) {
  render(rmd, output_file = out, output_dir = "public",
         output_options = list(includes = includes(in_header = header)))
  # Fail loudly rather than silently deploy an indexable page.
  page <- file.path("public", out)
  if (!any(grepl("noindex", readLines(page), fixed = TRUE)))
    stop("noindex meta tag missing from ", page)
  message("Rendered ", page)
}

render_one("report/qc.Rmd", "index.html")
render_one("report/annotation.Rmd", "annotation.html")

# Ask crawlers not to index the site (belt-and-braces with the noindex meta tag
# in report/header.html).
writeLines(c("User-agent: *", "Disallow: /"), "public/robots.txt")
message("Wrote public/robots.txt")
