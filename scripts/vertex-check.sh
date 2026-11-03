#!/bin/zsh
# Verifies the Vertex AI path for Gemini 4 Argon.
#
# --http1.1 because curl's HTTP/2 fails here with "stream 1 was not closed
# cleanly: PROTOCOL_ERROR". That is a curl problem, not a service one, so the
# Swift client using URLSession is unaffected. The token is never printed.

PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
MODEL_ID="gemini-4-argon"
LOCATION="global"
BASE="https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${MODEL_ID}"

show_error() {
  if head -c 20 "$1" 2>/dev/null | grep -qi "<!DOCTYPE\|<html"; then
    echo "    (HTML page, not a JSON API error: rejected before reaching the API)"
    sed -e 's/<[^>]*>//g' "$1" | tr -s ' \n' ' \n' | grep -viE '^[[:space:]]*$' | head -5 | sed 's/^/    /'
  else
    head -c 500 "$1" 2>/dev/null | sed 's/^/    /'
  fi
}

echo "project: ${PROJECT_ID}"; echo

echo "=== 1. token ==="
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "  FAILED: ${TOKEN}"; exit 1; }
echo "  ok, length ${#TOKEN}"
echo "$TOKEN" | grep -qE '^[A-Za-z0-9._~+/-]+=*$' && echo "  characters valid" || echo "  WARNING: odd characters, header may be illegal"
echo

echo "=== 3. text-only generateContent ==="
printf '%s' '{"contents":[{"role":"user","parts":[{"text":"In one sentence: who invented quicksort and in what year?"}]}],"generationConfig":{"maxOutputTokens":200,"thinkingConfig":{"thinkingLevel":"LOW"}}}' > /tmp/vx_req.json
H=$(curl -sS --http1.1 -o /tmp/vx_text.json -w "%{http_code}" -X POST "${BASE}:generateContent" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary @/tmp/vx_req.json)
echo "  HTTP ${H}"
if [ "$H" = "200" ]; then
  python3 -c "import json;d=json.load(open('/tmp/vx_text.json'));c=d.get('candidates',[{}])[0];print('    answer:',''.join(p.get('text','') for p in c.get('content',{}).get('parts',[]))[:200].strip());print('    usage :',d.get('usageMetadata'))"
else show_error /tmp/vx_text.json; fi
echo

echo "=== 4. inline image ==="
IMG=/private/tmp/claude-501/-Users-maverickrajeev-Documents-projects/119fa531-54fe-45f1-a621-6ef52815cceb/scratchpad/study_small.png
if [ -f "$IMG" ]; then
python3 - "$IMG" > /tmp/vx_img_req.json <<'PY'
import base64,json,sys
b64=base64.b64encode(open(sys.argv[1],'rb').read()).decode()
json.dump({"contents":[{"role":"user","parts":[{"inlineData":{"mimeType":"image/png","data":b64}},{"text":"Name the five boxes in the diagram, in order. One line."}]}],"generationConfig":{"maxOutputTokens":200,"thinkingConfig":{"thinkingLevel":"LOW"}}},sys.stdout)
PY
  H=$(curl -sS --http1.1 -o /tmp/vx_img.json -w "%{http_code}" -X POST "${BASE}:generateContent" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary @/tmp/vx_img_req.json)
  echo "  HTTP ${H}  (request $(wc -c < /tmp/vx_img_req.json | tr -d ' ') bytes)"
  if [ "$H" = "200" ]; then
    python3 -c "import json;d=json.load(open('/tmp/vx_img.json'));c=d.get('candidates',[{}])[0];print('    answer:',''.join(p.get('text','') for p in c.get('content',{}).get('parts',[]))[:240].strip());print('    usage :',d.get('usageMetadata'))"
  else show_error /tmp/vx_img.json; fi
else echo "  test image missing"; fi
echo

echo "=== 5. streaming alt=sse ==="
curl -sS --http1.1 -N --max-time 45 -o /tmp/vx_stream.txt -X POST "${BASE}:streamGenerateContent?alt=sse" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary '{"contents":[{"role":"user","parts":[{"text":"Count one to five, one number per sentence."}]}],"generationConfig":{"maxOutputTokens":120,"thinkingConfig":{"thinkingLevel":"LOW"}}}'
if grep -q "^data: " /tmp/vx_stream.txt 2>/dev/null; then
  echo "  SSE WORKS: $(grep -c '^data: ' /tmp/vx_stream.txt) frames"
  grep -m2 "^data: " /tmp/vx_stream.txt | cut -c1-150 | sed 's/^/    /'
else
  echo "  no SSE frames:"; head -c 250 /tmp/vx_stream.txt | sed 's/^/    /'
fi
