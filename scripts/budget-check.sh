#!/bin/zsh
# Does the graded budget actually change the shape of the answer?
PROJECT=medi-agent-490106
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null | tr -d '\r\n')
[ ${#TOKEN} -lt 50 ] && { echo "no token"; exit 1; }
URL="https://aiplatform.googleapis.com/v1/projects/${PROJECT}/locations/global/publishers/google/models/gemini-4-argon:streamGenerateContent?alt=sse"

ask() {
  local Q="$1" TOK="$2" SHAPE="$3"
  python3 - "$Q" "$TOK" "$SHAPE" > /tmp/bq.json <<'PY'
import json,sys
idx='''t43: Compute owns its disk
t46: Scaling compute means moving data
t49: Storage and compute pulled apart
t50: Data lives once, in cheap cloud object storage
t52: Scaling compute is starting a process, not moving bytes
t53: Losing a node loses a cache, not data
t54: Decide: A design that welds a node local disk to its identity contradicts the product.'''
p = open('/tmp/tutor_prompt.txt').read().replace('\\(screenIndexListing)', idx) + "\n\n" + sys.argv[3]
json.dump({"contents":[{"role":"user","parts":[{"text":sys.argv[1]}]}],
 "systemInstruction":{"parts":[{"text":p}]},
 "generationConfig":{"maxOutputTokens":int(sys.argv[2]),"thinkingConfig":{"thinkingLevel":"LOW"}}}, sys.stdout)
PY
  T=$(curl -sS --http1.1 -N --max-time 90 -w "%{time_starttransfer}" -o /tmp/bo.txt \
    -X POST "$URL" -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" --data-binary @/tmp/bq.json)
  python3 -c "
import json,re,sys
txt=open('/tmp/bo.txt').read(); out=[]
for line in txt.splitlines():
    if line.startswith('data: '):
        try:
            d=json.loads(line[6:])
            for c in d.get('candidates',[]):
                for p in c.get('content',{}).get('parts',[]): out.append(p.get('text',''))
        except Exception: pass
a=''.join(out); tags=re.findall(r'\[([A-Z]+)(?::[^\]]*)?\]',a)
spoken=re.sub(r'\[[^\]]*\]','',a).strip()
sents=[s for s in re.split(r'[.!?]',spoken) if s.strip()]
print(f'   ttfb ${T}s  words {len(spoken.split())}  sentences {len(sents)}  board {\"YES\" if \"BOARD\" in tags else \"no\"}  marks {len([t for t in tags if t not in (\"CLEAR\",\"BOARD\",\"COL\",\"BASE\",\"CAPTION\",\"CELLS\",\"PTR\")])}')
print('   ' + spoken[:170].replace(chr(10),' '))
"
}

echo "=== SHORT tier: 90 tokens ==="
ask "what does line three do" 90 "LENGTH: ONE sentence. they asked something specific and small. answer it and stop. no board."
echo
echo "=== NORMAL tier: 190 tokens ==="
ask "why is separating storage from compute the thing to lead with" 190 "LENGTH: THREE sentences carrying one idea. they are waiting in silence while you write, so every extra sentence is a longer wait. draw a board only if the idea genuinely has stages or data to step through."
echo
echo "=== DEEP tier: 520 tokens ==="
ask "walk me through how separating storage from compute actually works" 520 "LENGTH: they asked to be taught this properly. take the room: up to eight sentences, and draw a board if the idea has structure. still no preamble and no reading the screen back."
