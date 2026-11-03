#!/bin/zsh
# Does the model actually use the grid, and are the positions sane?
PROJECT=medi-agent-490106
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "no token"; exit 1; }
URL="https://aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/global/publishers/google/models/gemini-4-argon:streamGenerateContent?alt=sse"

ask() {
  python3 - "$1" > /tmp/dq.json <<'PY'
import json,sys
idx='''t43: Compute owns its disk
t49: Storage and compute pulled apart
t50: Data lives once, in cheap cloud object storage
t52: Scaling compute is starting a process, not moving bytes'''
p = open('/tmp/tutor_prompt.txt').read().replace('\\(screenIndexListing)', idx)
p += "\n\nLENGTH: they asked to be taught this properly. take the room: up to eight sentences, and draw a board if the idea has structure."
json.dump({"contents":[{"role":"user","parts":[{"text":sys.argv[1]}]}],
 "systemInstruction":{"parts":[{"text":p}]},
 "generationConfig":{"maxOutputTokens":520,"thinkingConfig":{"thinkingLevel":"LOW"}}}, sys.stdout)
PY
  T=$(curl -sS --http1.1 -N --max-time 90 -w "%{time_starttransfer}" -o /tmp/do.txt \
    -X POST "$URL" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary @/tmp/dq.json)
  echo "  ttfb ${T}s"
  python3 -c "
import json,re
txt=open('/tmp/do.txt').read(); out=[]
for line in txt.splitlines():
    if line.startswith('data: '):
        try:
            d=json.loads(line[6:])
            for c in d.get('candidates',[]):
                for p in c.get('content',{}).get('parts',[]): out.append(p.get('text',''))
        except Exception: pass
a=''.join(out)
nodes=re.findall(r'\[NODE:([^\]]+)\]',a)
edges=re.findall(r'\[EDGE:([^\]]+)\]',a)
print(f'  nodes {len(nodes)}  edges {len(edges)}')
ids=set()
for n in nodes:
    f=n.split(':')
    if len(f)>=4:
        pos=f[1].split(',')
        ids.add(f[0].strip())
        print(f'    {f[0].strip():6s} col {pos[0]:>2s} row {pos[1]:>2s} w {f[2]:>2s}  {f[3][:26]}')
bad=[e for e in edges if not all(x.strip() in ids for x in e.split(':')[0].split('->'))]
print(f'  dangling edges: {bad if bad else \"none\"}')
spoken=re.sub(r'\[[^\]]*\]','',a).strip()
print(f'  words {len(spoken.split())}')
"
}
echo "=== walk me through separating storage from compute ==="
ask "walk me through how separating storage from compute actually works"
