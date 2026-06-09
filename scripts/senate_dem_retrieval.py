"""
Scraper for Trump Transcripts on Senate Democrats website.
https://www.democrats.senate.gov/newsroom/trump-transcripts

Run from your local machine:
    pip install requests beautifulsoup4
    python scrape_transcripts.py

Outputs:
  - transcripts/    Individual .txt files per transcript
  - corpus.txt      All transcripts concatenated (for analysis)
  - metadata.csv    Title, date, URL for every transcript
"""

import re
import csv
import time
import os
from pathlib import Path

try:
    import requests
    from bs4 import BeautifulSoup
except ImportError:
    raise SystemExit(
        "Missing dependencies. Install with:\n"
        "    pip install requests beautifulsoup4"
    )

BASE_URL = "https://www.democrats.senate.gov"
LIST_URL = BASE_URL + "/newsroom/trump-transcripts"
TOTAL_PAGES = 21          # update if more pages are added later
DELAY = 1.5               # seconds between requests — be polite
OUTPUT_DIR = Path("data/speeches/transcripts")
CORPUS_FILE = Path("data/speeches/corpus.txt")
METADATA_FILE = Path("data/speeches/metadata.csv")

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": BASE_URL,
})


# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

def fetch(url: str, retries: int = 3) -> str:
    for attempt in range(retries):
        try:
            r = SESSION.get(url, timeout=20)
            r.raise_for_status()
            return r.text
        except requests.RequestException as e:
            print(f"  Attempt {attempt + 1} failed: {e}")
            time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"Failed to fetch {url} after {retries} attempts")


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def get_transcript_links(page: int) -> list[str]:
    url = LIST_URL if page == 1 else f"{LIST_URL}?pagenum_rs={page}"
    soup = BeautifulSoup(fetch(url), "html.parser")
    links = []
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if "/newsroom/trump-transcripts/" in href and href != "/newsroom/trump-transcripts":
            full = href if href.startswith("http") else BASE_URL + href
            if full not in links:
                links.append(full)
    return links


def parse_transcript(html: str) -> tuple[str, str, str]:
    """Return (title, date, body_text)."""
    soup = BeautifulSoup(html, "html.parser")

    # Date — appears as "Published: MM.DD.YYYY"
    date = "unknown"
    date_match = re.search(r"Published:\s*([\d.]+)", html)
    if date_match:
        date = date_match.group(1)

    # Title
    h1 = soup.find("h1")
    title = h1.get_text(strip=True) if h1 else "untitled"

    # Body: everything between <h1> and the page footer / social share block.
    # The transcript text lives in the main content area after the breadcrumb.
    # We grab all paragraphs / bold lines that follow the h1.
    body_parts = []

    # Find the content container — it follows the breadcrumb nav
    # Strategy: get all siblings/descendants after h1 until we hit footer nav
    if h1:
        for el in h1.find_all_next():
            tag = el.name
            if tag in ("script", "style"):
                continue
            # Stop at footer / nav / social links area
            classes = " ".join(el.get("class", []))
            if any(c in classes for c in ("site-footer", "l-footer", "social", "sidebar")):
                break
            # Stop when we hit the print/email/share links
            if tag == "ul" and el.find("a", string=re.compile(r"Print|Email|Share", re.I)):
                break
            if tag in ("p", "div", "h2", "h3", "h4", "blockquote"):
                text = el.get_text(separator=" ", strip=True)
                if text and len(text) > 10:
                    body_parts.append(text)

    # Deduplicate while preserving order (BeautifulSoup traverses into children)
    seen_parts: set[str] = set()
    deduped = []
    for part in body_parts:
        if part not in seen_parts:
            seen_parts.add(part)
            deduped.append(part)

    # Filter out nav/footer fragments that might have leaked through
    SKIP_FRAGMENTS = (
        "Skip to", "Senate Democrats", "About Senate Dems",
        "En Español", "Site Search", "Jobs", "Diversity Initiative",
    )
    cleaned = [p for p in deduped if not any(p.startswith(s) for s in SKIP_FRAGMENTS)]

    return title, date, "\n\n".join(cleaned)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def slugify(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text[:80].strip("-")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    OUTPUT_DIR.mkdir(exist_ok=True)

    # ── Phase 1: collect all transcript URLs ──────────────────────────────
    all_links: list[str] = []
    print(f"Collecting transcript links from {TOTAL_PAGES} listing pages…")
    for page in range(1, TOTAL_PAGES + 1):
        links = get_transcript_links(page)
        print(f"  Page {page:2d}: {len(links)} links found")
        all_links.extend(links)
        time.sleep(DELAY)

    # Deduplicate while preserving order
    seen: set[str] = set()
    unique_links = [l for l in all_links if not (l in seen or seen.add(l))]
    print(f"\nTotal unique transcripts to scrape: {len(unique_links)}\n")

    # ── Phase 2: scrape each transcript ───────────────────────────────────
    metadata_rows: list[dict] = []
    corpus_parts: list[str] = []
    errors: list[str] = []

    for i, url in enumerate(unique_links, 1):
        print(f"[{i:3d}/{len(unique_links)}] {url}")
        try:
            html = fetch(url)
            title, date, body = parse_transcript(html)

            if not body:
                print("  ⚠  Empty body — skipping")
                errors.append(url)
                continue

            # Save individual file
            slug = slugify(f"{date}-{title}") or f"transcript-{i}"
            filepath = OUTPUT_DIR / f"{slug}.txt"
            filepath.write_text(
                f"TITLE: {title}\nDATE:  {date}\nURL:   {url}\n\n{body}\n",
                encoding="utf-8",
            )

            metadata_rows.append({"title": title, "date": date, "url": url})
            corpus_parts.append(f"=== {title} | {date} ===\n{url}\n\n{body}")

        except Exception as e:
            print(f"  ✗ Error: {e}")
            errors.append(url)

        time.sleep(DELAY)

    # ── Phase 3: write outputs ─────────────────────────────────────────────
    separator = "\n\n" + "─" * 80 + "\n\n"
    CORPUS_FILE.write_text(
        separator.join(corpus_parts) + "\n",
        encoding="utf-8",
    )
    print(f"\n✓ corpus.txt  — {CORPUS_FILE.stat().st_size:,} bytes, {len(corpus_parts)} transcripts")

    with METADATA_FILE.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["title", "date", "url"])
        writer.writeheader()
        writer.writerows(metadata_rows)
    print(f"✓ metadata.csv — {len(metadata_rows)} rows")
    print(f"✓ transcripts/ — {len(list(OUTPUT_DIR.iterdir()))} files")

    if errors:
        print(f"\n⚠  {len(errors)} URLs failed:")
        for e in errors:
            print(f"   {e}")


if __name__ == "__main__":
    main()
