#!/bin/zsh
# Verifies the Vertex AI path for Gemini 4 Argon end to end.
#
# Vertex rather than AI Studio because only Vertex bills against the project,
# which is where Google Cloud trial credits live. An AI Studio key bills its
# own account and cannot draw on those credits no matter how it is configured.
#
# Checks, in order: a token can be minted, the endpoint and body shape are
# accepted, an inline image is accepted, and streaming works. The token is
# never printed.

PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null)}"
MODEL_ID="gemini-4-argon"
LOCATION="global"
BASE="https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${MODEL_ID}"

echo "project: ${PROJECT_ID}"
echo "model:   ${MODEL_ID}"
echo

echo "=== 1. mint an access token ==="
TOKEN=$(gcloud auth application-default print-access-token 2>&1)
if [ ${#TOKEN} -lt 50 ]; then
  echo "  FAILED: ${TOKEN}"
  echo
  echo "  Fix with:  gcloud auth application-default login"
  echo "  Then set the quota project:"
  echo "             gcloud auth application-default set-quota-project ${PROJECT_ID}"
  exit 1
fi
echo "  ok, token length ${#TOKEN}"
echo

echo "=== 1b. can we even reach the host? ==="
curl -sS -o /dev/null -w "  aiplatform.googleapis.com -> HTTP %{http_code} in %{time_total}s\n" \
  "https://aiplatform.googleapis.com/" 2>&1 | head -3
echo

echo "=== 2. text-only request (checks endpoint + body shape) ==="
HTTP=$(curl -sS --http1.1 -o /tmp/vertex_text.json -w "%{http_code}" --stderr /tmp/vertex_text.err \
  -X POST "${BASE}:generateContent" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{"role":"user","parts":[{"text":"In one sentence: who invented quicksort and in what year?"}]}],
    "systemInstruction": {"parts":[{"text":"Answer in one short sentence."}]},
    "generationConfig": {"maxOutputTokens": 200, "thinkingConfig": {"thinkingLevel": "LOW"}}
  }')
echo "  HTTP ${HTTP}"
[ -s /tmp/vertex_text.err ] && echo "  curl said: $(head -3 /tmp/vertex_text.err)"
if [ "$HTTP" = "200" ]; then
  python3 -c "
import json
d=json.load(open('/tmp/vertex_text.json'))
c=d.get('candidates',[{}])[0]
print('  answer:', ''.join(p.get('text','') for p in c.get('content',{}).get('parts',[]))[:220].strip())
print('  finishReason:', c.get('finishReason'))
print('  usage:', d.get('usageMetadata'))
print('  modelVersion:', d.get('modelVersion'))
" 2>/dev/null || head -c 400 /tmp/vertex_text.json
else
  head -c 500 /tmp/vertex_text.json
fi
echo; echo

echo "=== 3. inline image (the capability this whole app depends on) ==="
IMG="${STUDY_SCREEN:?set STUDY_SCREEN to a screenshot of study material}"
if [ -f "$IMG" ]; then
  B64=$(base64 -i "$IMG" | tr -d '\n')
  cat > /tmp/vertex_img_req.json <<EOF
{
  "contents": [{"role":"user","parts":[
    {"inlineData":{"mimeType":"image/png","data":"${B64}"}},
    {"text":"Name the five boxes in the diagram, in order. One line."}
  ]}],
  "generationConfig": {"maxOutputTokens": 200, "thinkingConfig": {"thinkingLevel": "LOW"}}
}
EOF
  HTTP=$(curl -sS --http1.1 -o /tmp/vertex_img.json -w "%{http_code}" --stderr /tmp/vertex_img.err \
    -X POST "${BASE}:generateContent" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @/tmp/vertex_img_req.json)
  echo "  HTTP ${HTTP}"
  [ -s /tmp/vertex_img.err ] && echo "  curl said: $(head -3 /tmp/vertex_img.err)"
  python3 -c "
import json
d=json.load(open('/tmp/vertex_img.json'))
c=d.get('candidates',[{}])[0]
print('  answer:', ''.join(p.get('text','') for p in c.get('content',{}).get('parts',[]))[:260].strip())
print('  usage:', d.get('usageMetadata'))
" 2>/dev/null || head -c 500 /tmp/vertex_img.json
else
  echo "  test image not found, skipped"
fi
echo; echo

echo "=== 4. streaming with alt=sse (undocumented for Vertex; needs proving) ==="
curl -sS --http1.1 -N --max-time 45 \
  -X POST "${BASE}:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{"role":"user","parts":[{"text":"Count from one to five, one number per sentence."}]}],
    "generationConfig": {"maxOutputTokens": 120, "thinkingConfig": {"thinkingLevel": "LOW"}}
  }' | head -c 700
echo
echo
echo "  ^ 'data: {...}' lines above mean SSE streaming works."
echo "  A bare JSON array means it streams, but not as SSE."
