#!/usr/bin/env bash
# Run NYT retrieval in the background via tmux:
#   bash run_nyt.sh
#
# Reattach later:
#   tmux attach -t nyt-fetch
#
# Check progress:
#   tail -f nyt_fetch.log

set -euo pipefail
cd "$(dirname "$0")/.."
SESSION="nyt-fetch"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Session '$SESSION' already running. Attach with:"
  echo "  tmux attach -t $SESSION"
  exit 1
fi

tmux new-session -d -s "$SESSION" \
  "Rscript scripts/run_nyt_retrieval.R 2>&1 | tee -a data/nyt/nyt_fetch.log; echo; echo 'Finished at' \$(date) | tee -a data/nyt/nyt_fetch.log; bash"

echo "Started in tmux session: $SESSION"
echo "  tmux attach -t $SESSION    # watch live"
echo "  tail -f data/nyt/nyt_fetch.log      # follow log"
echo "  Ctrl-b then d              # detach"
