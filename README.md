# Trump Sentiment Analysis

Compare Trump speech transcripts (Senate Democrats newsroom) with NYT Article Search coverage.

## Data

| Folder | Contents | Date range |
|--------|----------|------------|
| `data/speeches/` | `corpus.txt`, `metadata.csv`, `transcripts/` | Jun 2025 – May 2026 |
| `data/nyt/` | `nyt_cache/`, `nyt_fetch.log` | Jul 7 – Sep 28, 2025 (partial) |

NYT collection stopped at 6 of 23 planned windows due to HTTP 429 rate limiting.

**Note:** `data/` is not in this repo (too large). Keep your local copy of `data/speeches/` and `data/nyt/nyt_cache/`, or re-run the scripts below to rebuild.

## Main analysis

Knit `trump_project_analysis.Rmd` from this folder:

```r
setwd("path/to/Trump_sentiment_analysis")
rmarkdown::render("trump_project_analysis.Rmd")
```

## Scripts

- `scripts/senate_dem_retrieval.py` — scrape transcripts
- `scripts/run_nyt_retrieval.R` — NYT API fetch (2-week windows)
- `scripts/run_nyt.sh` — run fetch in tmux
