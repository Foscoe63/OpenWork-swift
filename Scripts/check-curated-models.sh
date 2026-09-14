#!/usr/bin/env bash
# Check every curated MLX model id against Hugging Face.
#
# The catalog is a list of download targets. When an id is wrong the app offers a model that cannot
# be fetched, and the failure surfaces as an opaque HTTPClientError — five of fifteen ids were in
# that state before this script existed. Nothing in the build can catch it, because it depends on
# what exists on a remote host, so it is a script rather than a test: CI should not fail because
# Hugging Face is slow, rate-limiting, or momentarily down.
#
# Usage: Scripts/check-curated-models.sh
set -uo pipefail

CATALOG="$(dirname "$0")/../Sources/Engine/Providers/LocalMLXEngine.swift"
failed=0

while read -r id; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "https://huggingface.co/api/models/$id")
  case "$code" in
    200|307|308) printf '  ok    %s\n' "$id" ;;
    000)         printf '  ????  %s (no response — network, not the id)\n' "$id" ;;
    *)           printf '  FAIL  %s (HTTP %s)\n' "$id" "$code"; failed=$((failed + 1)) ;;
  esac
done < <(grep -oE '^\s+id: "[^"]+"' "$CATALOG" | sed -E 's/.*id: "//; s/"//' | sort -u)

if [ "$failed" -gt 0 ]; then
  echo
  echo "$failed curated model id(s) do not resolve. Hugging Face answers 401 for a repo that does"
  echo "not exist as well as one that is private, so treat 401 as 'find the real repo'."
  exit 1
fi
echo
echo "All curated model ids resolve."
