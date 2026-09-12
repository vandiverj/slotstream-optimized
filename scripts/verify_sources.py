#!/usr/bin/env python3
"""Verify that both engine trees still match the saved source snapshots."""
import hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
for name, directory in [('78gb', root), ('30gb', root / 'engines/30gb')]:
    expected = json.loads((root / 'provenance' / (name + '.json')).read_text())['source_files']
    files = [p for p in (directory / 'Sources').rglob('*') if p.is_file()]
    files += [directory / 'Package.swift', directory / 'Package.resolved']
    actual = {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    if actual != expected: raise SystemExit(name + ': source identity mismatch')
    print(name + ': exact source snapshot verified')
