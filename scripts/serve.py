#!/usr/bin/env python3
"""Launch one exact saved profile after a local memory preflight."""
import argparse, json, os, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def configuration(profile, model, port):
    cfg = json.loads((ROOT / 'profiles' / (profile + '.json')).read_text())
    binary = ROOT / cfg['engine'] / '.build/release/slotstream'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SLOTSTREAM_', 'MLX_', 'SS_DEBUG_'))}
    env.update(cfg['environment'])
    common = ['--model', str(Path(model).expanduser().resolve()), '--experts-per-layer', str(cfg['experts']),
              '--mtp', cfg['mtp'], '--max-context', str(cfg['max_context'])]
    argv = [str(binary), 'serve', '--port', str(port), '--no-prefix-cache'] + common
    return cfg, binary, env, common, argv

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['78gb', '30gb'], default='78gb')
    parser.add_argument('--model', default='~/.slotstream/models/qwen38-flash-next-mlx-4bit')
    parser.add_argument('--port', type=int, default=11434)
    parser.add_argument('--dry-run', action='store_true', help='Show exact arguments and profile environment without loading the model')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535: parser.error('port must be between 1 and 65535')
    cfg, binary, env, common, argv = configuration(args.profile, args.model, args.port)
    if args.dry_run:
        print(json.dumps({'argv': argv, 'environment': cfg['environment'], 'clear_inherited_prefixes': ['SLOTSTREAM_', 'MLX_', 'SS_DEBUG_']}, indent=2))
        return
    if not binary.is_file(): parser.error('Build this profile first with scripts/build.sh ' + args.profile)
    if not Path(args.model).expanduser().is_dir(): parser.error('Model directory missing; download with slotstream pull or pass --model PATH')
    processes = subprocess.run(['pgrep', '-x', 'slotstream'], capture_output=True, text=True)
    if processes.returncode != 1: parser.error('A slotstream process is running, or the process check failed. Run only one model at a time.')
    check = subprocess.run([str(binary), 'doctor'] + common, env=env, capture_output=True, text=True)
    print(check.stdout, end='', flush=True)
    if check.returncode: parser.error(check.stderr or 'Model preflight failed')
    available = re.search(r'([\d.]+) GB reclaimable now', check.stdout)
    peak = re.search(r'expect:\s*~([\d.]+) GB peak', check.stdout)
    chunk = re.search(r'prefill:\s*(\d+) tokens per pass', check.stdout)
    if not (available and peak and chunk): parser.error('Cannot verify memory headroom from doctor output')
    # Account for an explicitly selected prefill chunk exceeding the planner's estimate.
    selected_chunk = int(cfg['environment']['SLOTSTREAM_PREFILL_CHUNK'])
    estimated = float(peak[1]) + max(0, selected_chunk - int(chunk[1])) * .0013
    floor = 82 if args.profile == '78gb' else 31
    required = max(floor, estimated) + cfg['reclaimable_reserve_gb']
    if float(available[1]) < required:
        parser.error('Need %.1f GB reclaimable including reserve; doctor reports %s GB. Free memory before launching.' % (required, available[1]))
    os.execve(str(binary), argv, env)

if __name__ == '__main__': main()
