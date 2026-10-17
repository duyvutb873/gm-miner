#!/usr/bin/env bash
# DeepInfra effective prices (list x (1-discount)) for GLM routes vs gm retail.
d=$(mktemp -d); curl -sS -m 30 https://api.deepinfra.com/models/list -o "$d/l.json" || { echo "DI: fetch lỗi"; exit 1; }
python3 -I - "$d/l.json" <<'P'
import json,sys
retail={'zai-org/GLM-5.3-Flash':(0.15,0.50),'zai-org/GLM-5.2':(1.40,4.40),'zai-org/GLM-5.3':(1.40,4.40)}
rows={m.get('model_name'):m.get('pricing') or {} for m in json.load(open(sys.argv[1]))}
for n,(ri,ro) in retail.items():
  p=rows.get(n)
  if not p: print(f"DI {n}: KHÔNG THẤY"); continue
  disc=p.get('discount') or 0; f=1-disc
  i=p['cents_per_input_token']*1e4*f; o=p['cents_per_output_token']*1e4*f
  ratio=(3*i+o)/(3*ri+ro)
  print(f"DI {n}: giảm {disc*100:.1f}% ends={p.get('discount_ends_at')} -> ${i:.4f}/${o:.4f} | chi phí/retail {ratio*100:.0f}% | hòa vốn ở giảm {max(0,(1-ratio/0.97))*100:.0f}%")
P
rm -rf "$d"
