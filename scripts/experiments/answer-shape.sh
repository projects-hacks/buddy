#!/bin/zsh
# Measures the shape of a real answer: time to first byte, how long it is, and
# how many marks it carries. Those three are the whole complaint: silence
# before the answer, too much to follow, and marks dribbling out for a minute.
PROJECT="${VERTEX_PROJECT:?set VERTEX_PROJECT to your Google Cloud project}"
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "no token"; exit 1; }

INDEX='t43: Compute owns its disk
t45: A node identity includes the data it holds
t46: Scaling compute means moving data
t48: Losing a node loses data until it is re-replicated
t49: Storage and compute pulled apart
t50: Data lives once, in cheap cloud object storage
t51: Any number of clusters read it and own none of it
t52: Scaling compute is starting a process, not moving bytes
t53: Losing a node loses a cache, not data
t54: Decide: A design that welds a node local disk to its identity quietly contradicts the product.
t64: storage handle the data load while compute handle the processing load'

python3 - "$INDEX" > /tmp/shape_req.json <<'PY'
import json,sys
prompt = open('/tmp/tutor_prompt.txt').read().replace('\\(screenIndexListing)', sys.argv[1])
json.dump({
 "contents":[{"role":"user","parts":[{"text":"why is separating storage from compute the thing to lead with"}]}],
 "systemInstruction":{"parts":[{"text":prompt}]},
 "generationConfig":{"maxOutputTokens":150,"thinkingConfig":{"thinkingLevel":"LOW"}}}, sys.stdout)
PY

URL="https://aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/global/publishers/google/models/gemini-4-argon:streamGenerateContent?alt=sse"
T=$(curl -sS --http1.1 -N --max-time 90 -w "%{time_starttransfer} %{time_total}" -o /tmp/shape_out.txt \
  -X POST "$URL" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  --data-binary @/tmp/shape_req.json)
echo "ttfb $(echo $T | cut -d' ' -f1)s   total $(echo $T | cut -d' ' -f2)s"
python3 -c "
import json,re
txt=open('/tmp/shape_out.txt').read()
out=[]
for line in txt.splitlines():
    if line.startswith('data: '):
        try:
            d=json.loads(line[6:])
            for c in d.get('candidates',[]):
                for p in c.get('content',{}).get('parts',[]):
                    out.append(p.get('text',''))
        except Exception: pass
a=''.join(out)
tags=re.findall(r'\[([A-Z]+)(?::[^\]]*)?\]', a)
spoken=re.sub(r'\[[^\]]*\]','',a).strip()
print(f'words spoken : {len(spoken.split())}')
print(f'sentences    : {len([s for s in re.split(r\"[.!?]\", spoken) if s.strip()])}')
print(f'marks        : {len(tags)}  {tags}')
print('---')
print(a.strip()[:700])
"
