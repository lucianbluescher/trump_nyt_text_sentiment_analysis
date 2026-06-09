# NYT article retrieval — run interactively or in the background:
#   Rscript run_nyt_retrieval.R
#   bash run_nyt.sh
#
# From EDS-231-text-sentiment project in R:
#   source("../Trump_sentiment_analysis/run_nyt_retrieval.R", chdir = TRUE)
# Or setwd first:
#   setwd("~/Desktop/MEDS/EDS-231/Trump_sentiment_analysis")
#   source("run_nyt_retrieval.R")

suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(httr))
suppressPackageStartupMessages(library(tidyverse))

# Find this script's folder no matter where you source from
find_trump_dir <- function() {
  candidates <- c(
    getwd(),
    file.path(getwd(), "Trump_sentiment_analysis"),
    file.path(getwd(), "..", "Trump_sentiment_analysis"),
    file.path(getwd(), "..", "..", "Trump_sentiment_analysis")
  )
  for (d in unique(normalizePath(candidates, winslash = "/", mustWork = FALSE))) {
    if (file.exists(file.path(d, "data/speeches/corpus.txt"))) return(d)
  }
  stop("Cannot find Trump_sentiment_analysis project root.")
}
setwd(find_trump_dir())

LOG_FILE <- "data/nyt/nyt_fetch.log"
CACHE_DIR <- "data/nyt/nyt_cache"
OUT_CSV <- "data/nyt/nyt_articles.csv"

log_msg <- function(...) {
  line <- paste0(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " ", ..., "\n")
  cat(line)
  cat(line, file = LOG_FILE, append = TRUE)
}

API_KEY <- Sys.getenv("NYT_API_KEY")
if (API_KEY == "") API_KEY <- Sys.getenv("NYT_KEY")
if (API_KEY == "" || API_KEY == "your_api_key_here") {
  stop("Set NYT_API_KEY (or NYT_KEY) in .Renviron, restart R, then re-run.")
}

BEGIN_DATE <- as.Date("2025-07-07")
END_DATE   <- as.Date("2026-05-20")
TERM       <- "trump"
WINDOW_DAYS <- 14L
RATE_LIMIT_SECS <- 20L

empty_df <- data.frame(
  id = numeric(),
  created_time = character(),
  snippet = character(),
  headline = character(),
  web_url = character(),
  stringsAsFactors = FALSE
)

fromJSON_retry <- function(url, max_tries = 10L) {
  for (attempt in seq_len(max_tries)) {
    resp <- tryCatch(GET(url), error = function(e) NULL)

    if (is.null(resp)) {
      wait <- 30L * attempt
      log_msg("Connection error. Sleeping ", wait, "s (attempt ", attempt, ")...")
      Sys.sleep(wait)
      next
    }

    status <- status_code(resp)
    if (status %in% c(429L, 503L)) {
      wait <- 90L * attempt
      log_msg("HTTP ", status, ". Sleeping ", wait, "s (attempt ", attempt, ")...")
      Sys.sleep(wait)
      next
    }

    if (status != 200L) {
      stop(
        "HTTP ", status, ": ",
        rawToChar(content(resp, as = "raw", encoding = "UTF-8"))
      )
    }

    return(fromJSON(content(resp, as = "text", encoding = "UTF-8"), flatten = TRUE))
  }

  stop("Max retries exceeded after ", max_tries, " attempts.")
}

docs_to_df <- function(docs) {
  if (is.null(docs)) return(empty_df)

  if (is.data.frame(docs)) {
    if (nrow(docs) == 0) return(empty_df)
    n <- nrow(docs)
    pub_date <- docs$pub_date
    snippet <- docs$snippet
    headline <- docs$headline.main
    web_url <- docs$web_url
  } else if (is.list(docs) && !is.null(docs$pub_date)) {
    n <- 1L
    pub_date <- docs$pub_date
    snippet <- docs$snippet %||% NA_character_
    headline <- if (is.list(docs$headline)) docs$headline$main else docs$headline.main
    headline <- headline %||% NA_character_
    web_url <- docs$web_url %||% NA_character_
  } else {
    return(empty_df)
  }

  data.frame(
    id = seq_len(n),
    created_time = pub_date,
    snippet = snippet,
    headline = headline,
    web_url = web_url,
    stringsAsFactors = FALSE
  )
}

nytAPI <- function(term1, begin_date, end_date, api, page_cache_dir = NULL) {
  searchQ <- URLencode(term1)
  url <- paste0(
    "https://api.nytimes.com/svc/search/v2/articlesearch.json?q=", searchQ,
    "&begin_date=", begin_date, "&end_date=", end_date, "&api-key=", api
  )

  initialsearch <- fromJSON_retry(url)
  hits <- initialsearch$response$meta$hits %||% 0L
  log_msg("'", term1, "' ", begin_date, "-", end_date, ": ", hits, " hits")

  if (hits == 0) return(empty_df)
  if (hits >= 1000) {
    log_msg("WARNING: ", hits, " hits — capped at 1000. Use shorter windows.")
  }

  df <- empty_df

  if (!is.null(page_cache_dir)) {
    dir.create(page_cache_dir, showWarnings = FALSE, recursive = TRUE)
  }

  for (i in 0:99) {
    page_file <- if (!is.null(page_cache_dir)) {
      file.path(page_cache_dir, paste0("page_", i, ".rds"))
    } else {
      NA_character_
    }

    if (!is.na(page_file) && file.exists(page_file)) {
      temp <- readRDS(page_file)
      log_msg("  page cache hit: ", basename(page_file))
    } else {
      nytSearch <- fromJSON_retry(paste0(url, "&page=", i))
      temp <- docs_to_df(nytSearch$response$docs)
      if (!is.na(page_file)) saveRDS(temp, page_file)
    }

    if (nrow(temp) == 0) {
      log_msg("  page ", i, " empty — done with window")
      break
    }

    df <- rbind(df, temp)
    if (nrow(temp) < 10) break
    if (i > 0 && i %% 10 == 0) {
      log_msg("  pause after 10 pages...")
      Sys.sleep(120)
    }
    Sys.sleep(RATE_LIMIT_SECS)
  }

  df
}

dir.create(CACHE_DIR, showWarnings = FALSE, recursive = TRUE)
if (!file.exists(LOG_FILE)) cat("", file = LOG_FILE)

window_starts <- seq(BEGIN_DATE, END_DATE, by = paste(WINDOW_DAYS, "days"))
log_msg("Starting retrieval: ", length(window_starts), " windows")

all_results <- empty_df

for (i in seq_along(window_starts)) {
  w_start <- window_starts[i]
  w_end <- min(w_start + WINDOW_DAYS - 1L, END_DATE)
  begin_str <- format(w_start, "%Y%m%d")
  end_str <- format(w_end, "%Y%m%d")
  cache_file <- file.path(CACHE_DIR, paste0("trump_", begin_str, "_", end_str, ".rds"))
  page_cache_dir <- file.path(CACHE_DIR, paste0("trump_", begin_str, "_", end_str))

  if (file.exists(cache_file)) {
    chunk <- readRDS(cache_file)
    log_msg("Window cache hit: ", basename(cache_file), " (", nrow(chunk), " rows)")
  } else {
    log_msg("Fetching window ", i, "/", length(window_starts), ": ", begin_str, "-", end_str)
    chunk <- nytAPI(TERM, begin_str, end_str, API_KEY, page_cache_dir)
    saveRDS(chunk, cache_file)
    if (i < length(window_starts)) Sys.sleep(RATE_LIMIT_SECS)
  }

  all_results <- bind_rows(all_results, chunk)
}

results <- all_results |>
  filter(!is.na(web_url), web_url != "") |>
  distinct(web_url, .keep_all = TRUE) |>
  arrange(desc(created_time))

write.csv(results, OUT_CSV, row.names = FALSE)
log_msg("Done. Saved ", nrow(results), " unique articles to ", OUT_CSV)

nytDat <- results
