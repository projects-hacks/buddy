#!/bin/zsh
# Time to first byte across models, with a screenshot attached.
#
# TTFB is the number that decides the voice loop: it is the silence after the
# user stops speaking and before the tutor starts. Argon measured 8.45s on a
# trivial text prompt, which is worse than the local 4B, so the trade between
# a smarter model and a faster one needs measuring rather than assuming.

PROJECT="${1:-${VERTEX_PROJECT:?set VERTEX_PROJECT to your Google Cloud project}}"
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "no token"; exit 1; }

IMG=/private/tmp/claude-501/-Users-maverickrajeev-Documents-projects/119fa531-54fe-45f1-a621-6ef52815cceb/scratchpad/study_small.png
python3 - "$IMG" > /tmp/lat_req.json <<'PY'
import base64,json,sys
b64=base64.b64encode(open(sys.argv[1],'rb').read()).decode()
json.dump({"contents":[{"role":"user","parts":[
  {"inlineData":{"mimeType":"image/png","data":b64}},
  {"text":"There is a bug in the code on screen. Which line is wrong and why? Two sentences."}]}],
  "generationConfig":{"maxOutputTokens":200,"thinkingConfig":{"thinkingLevel":"LOW"}}},sys.stdout)
PY

printf "%-26s %8s %8s  %s\n" "model" "ttfb" "total" "answer"
for M in gemini-4-argon gemini-3.5-flash gemini-3.8-flash; do
  URL="https://aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/global/publishers/google/models/${M}:streamGenerateContent?alt=sse"
  rm -f /tmp/lat_out.txt
  T=$(curl -sS --http1.1 -N --max-time 60 \
      -w "%{time_starttransfer} %{time_total} %{http_code}" -o /tmp/lat_out.txt \
      -X POST "$URL" -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" --data-binary @/tmp/lat_req.json 2>/dev/null)
  TTFB=$(echo $T | cut -d' ' -f1); TOTAL=$(echo $T | cut -d' ' -f2); CODE=$(echo $T | cut -d' ' -f3)
  if [ "$CODE" = "200" ]; then
    ANS=$(python3 -c "
import re,sys,json
txt=open('/tmp/lat_out.txt').read()
out=[]
for line in txt.splitlines():
    if line.startswith('data: '):
        try:
            d=json.loads(line[6:])
            for c in d.get('candidates',[]):
                for p in c.get('content',{}).get('parts',[]):
                    out.append(p.get('text',''))
        except Exception: pass
print(''.join(out).replace(chr(10),' ')[:95])
" 2>/dev/null)
  else
    ANS="HTTP ${CODE}: $(head -c 80 /tmp/lat_out.txt | tr -d '\n')"
  fi
  printf "%-26s %7.2fs %7.2fs  %s\n" "$M" "$TTFB" "$TOTAL" "$ANS"
done
