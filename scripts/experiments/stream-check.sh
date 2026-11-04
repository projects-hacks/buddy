#!/bin/zsh
# Does Vertex stream, and in what framing?
#
# Progressive speech depends on this: without streaming, nothing can be spoken
# until the whole answer is generated, which undoes the fluency work. Google's
# docs do not state whether alt=sse is supported on Vertex, so it is measured.
#
# Stale files are removed first: a previous run left a 401 body behind that
# curl never overwrote, because it received nothing, and that old error read
# like a fresh failure.

PROJECT_ID="${1:-${VERTEX_PROJECT:?set VERTEX_PROJECT to your Google Cloud project}}"
BASE="https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/publishers/google/models/gemini-4-argon"
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "no token"; exit 1; }

BODY='{"contents":[{"role":"user","parts":[{"text":"Count one to five. One short sentence each."}]}],"generationConfig":{"maxOutputTokens":150,"thinkingConfig":{"thinkingLevel":"LOW"}}}'

for VARIANT in "alt=sse" "no-alt"; do
  rm -f /tmp/vx_s.txt
  if [ "$VARIANT" = "alt=sse" ]; then
    URL="${BASE}:streamGenerateContent?alt=sse"
  else
    URL="${BASE}:streamGenerateContent"
  fi

  echo "=== ${VARIANT} ==="
  # -N disables buffering; time_starttransfer is the number that matters,
  # because that is when the first token could begin being spoken.
  curl -sS --http1.1 -N --max-time 40 \
    -w "  ttfb %{time_starttransfer}s  total %{time_total}s  HTTP %{http_code}  %{size_download} bytes\n" \
    -o /tmp/vx_s.txt \
    -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY"

  if [ -s /tmp/vx_s.txt ]; then
    if grep -q "^data: " /tmp/vx_s.txt; then
      echo "  framing: SSE ($(grep -c '^data: ' /tmp/vx_s.txt) data frames)"
      grep -m1 "^data: " /tmp/vx_s.txt | cut -c1-140 | sed 's/^/    /'
    elif head -c 1 /tmp/vx_s.txt | grep -q '\['; then
      echo "  framing: JSON array (streams, but not SSE)"
      head -c 180 /tmp/vx_s.txt | sed 's/^/    /'
    else
      echo "  framing: unknown"
      head -c 220 /tmp/vx_s.txt | sed 's/^/    /'
    fi
  else
    echo "  nothing received"
  fi
  echo
done
