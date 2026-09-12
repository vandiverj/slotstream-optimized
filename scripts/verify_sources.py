#!/usr/bin/env python3
"""Verify the single ACD source snapshot and the two supported profiles."""
import hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
expected = json.loads((root / 'provenance/acd.json').read_text())['source_files']
files = [p for p in (root / 'Sources').rglob('*') if p.is_file()]
files += [root / 'Package.swift', root / 'Package.resolved']
actual = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
if actual != expected: raise SystemExit('ACD source identity mismatch')
common = {'SLOTSTREAM_ADAPTIVE_DRAFT':'1','SLOTSTREAM_ATTN_BLOCK':'256',
          'SLOTSTREAM_GDN_PREPARE':'gates','SLOTSTREAM_COMPILE_EXPERTS':'0',
          'SLOTSTREAM_DRAFT_DEPTH':'1','SLOTSTREAM_PREFILL_CHUNK':'2048',
          'SLOTSTREAM_PREFIX_CACHE':'0','SLOTSTREAM_EXPERT_LOAD_BATCH':'32',
          'SLOTSTREAM_IO_QUEUE_DEPTH':'12','SLOTSTREAM_POOL_QUEUE_DEPTH':'32'}
for name, experts, resident in [('30gb',152,'off'),('78gb',512,'both')]:
    cfg = json.loads((root / 'profiles' / (name+'.json')).read_text())
    if not (cfg['engine']=='.' and cfg['baseline']=='ACD' and cfg['experts']==experts
            and cfg['mtp']=='on' and cfg['max_context']==32768 and cfg['prefix_cache'] is False
            and cfg['environment']==dict(common,SLOTSTREAM_FULL_RESIDENT_MODE=resident)):
        raise SystemExit(name+': ACD profile mismatch')
    print(name+': ACD profile verified')
print('Single ACD source snapshot verified')
