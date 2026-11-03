#!/bin/zsh
# Shows why ADC cannot mint a token. Prints only the error, never a token.
echo "=== stdout (would be the token) ==="
OUT=$(gcloud auth application-default print-access-token 2>/dev/null)
echo "  length: ${#OUT}"
echo
echo "=== stderr (the reason) ==="
gcloud auth application-default print-access-token 2>&1 >/dev/null | head -12 | sed 's/^/  /'
echo
echo "=== accounts gcloud knows ==="
gcloud auth list --format="value(account,status)" 2>/dev/null | sed 's/^/  /'
echo
echo "=== ADC file ==="
ADC="$HOME/.config/gcloud/application_default_credentials.json"
if [ -f "$ADC" ]; then
  python3 -c "
import json,sys
d=json.load(open('$ADC'))
print('  keys present:', sorted(d.keys()))
print('  type:', d.get('type','(none)'))
print('  quota_project_id:', d.get('quota_project_id','(NOT SET)'))
"
else
  echo "  no ADC file"
fi
