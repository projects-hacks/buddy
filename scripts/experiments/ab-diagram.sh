#!/bin/zsh
# Same question, same budget. Only difference: whether the prompt offers the
# positioned grid. Isolates what the richer diagram actually costs.
PROJECT="${VERTEX_PROJECT:?set VERTEX_PROJECT to your Google Cloud project}"
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "no token"; exit 1; }
URL="https://aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/global/publishers/google/models/gemini-4-argon:streamGenerateContent?alt=sse"
Q="walk me through how separating storage from compute actually works"

run() {
  local VARIANT="$1"
  rm -f /tmp/ab_out.txt
  python3 - "$VARIANT" "$Q" > /tmp/ab_req.json <<'PY'
import json,sys,re
idx='''t43: Compute owns its disk
t49: Storage and compute pulled apart
t50: Data lives once, in cheap cloud object storage
t52: Scaling compute is starting a process, not moving bytes'''
p = open('/tmp/tutor_prompt.txt').read().replace('\\(screenIndexListing)', idx)
if sys.argv[1] == 'without':
    # Strip the positioned-diagram section, leaving columns only.
    start = p.find('POSITIONED DIAGRAMS')
    end = p.find('example, binary search:')
    if start != -1 and end != -1:
        p = p[:start] + p[end:]
    p = re.sub(r'\[NODE:[^\n]*\n', '', p)
    p = re.sub(r'\[EDGE:[^\n]*\n', '', p)
p += "\n\nLENGTH: they asked to be taught this properly. take the room: up to eight sentences, and draw a board if the idea has structure."
json.dump({"contents":[{"role":"user","parts":[{"text":sys.argv[2]}]}],
 "systemInstruction":{"parts":[{"text":p}]},
 "generationConfig":{"maxOutputTokens":520,"thinkingConfig":{"thinkingLevel":"LOW"}}}, sys.stdout)
PY
  T=$(curl -sS --http1.1 -N --max-time 120 -w "%{time_starttransfer} %{http_code}" -o /tmp/ab_out.txt \
    -X POST "$URL" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary @/tmp/ab_req.json)
  python3 -c "
import json,re
txt=open('/tmp/ab_out.txt').read(); out=[]
for line in txt.splitlines():
    if line.startswith('data: '):
        try:
            d=json.loads(line[6:])
            for c in d.get('candidates',[]):
                for p in c.get('content',{}).get('parts',[]): out.append(p.get('text',''))
        except Exception: pass
a=''.join(out)
print(f'  $VARIANT grid: ttfb $(echo $T | cut -d\" \" -f1)s  nodes {len(re.findall(chr(91)+\"NODE:\",a))}  cols {len(re.findall(chr(91)+\"COL:\",a))}  words {len(re.sub(chr(91)+chr(94)+chr(93)+\"*\"+chr(93),chr(32),a).split())}')
" 2>/dev/null || echo "  $VARIANT: parse issue, raw size $(wc -c < /tmp/ab_out.txt)"
}

echo "prompt lines: $(wc -l < /tmp/tutor_prompt.txt)"
run without
run with
