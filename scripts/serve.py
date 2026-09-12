#!/usr/bin/env python3
"""Launch one exact saved profile after a local memory preflight."""
import argparse, json, math, os, re, subprocess
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

def preflight(binary, env, common, cfg, profile):
    def fail(message):
        raise RuntimeError(message)
    processes = subprocess.run(['pgrep', '-x', 'slotstream'], capture_output=True, text=True, timeout=5)
    if processes.returncode != 1: fail('A slotstream process is running, or the process check failed. Run only one model at a time.')
    check = subprocess.run([str(binary), 'doctor'] + common, env=env, capture_output=True, text=True, timeout=30)
    print(check.stdout, end='', flush=True)
    if check.returncode: fail(check.stderr or 'Model preflight failed')
    available = re.search(r'([\d.]+) GB reclaimable now', check.stdout)
    peak = re.search(r'expect:\s*~([\d.]+) GB peak', check.stdout)
    chunk = re.search(r'prefill:\s*(\d+) tokens per pass', check.stdout)
    if not (available and peak and chunk): fail('Cannot verify memory headroom from doctor output')
    # Account for an explicitly selected prefill chunk exceeding the planner's estimate.
    selected_chunk = int(cfg['environment']['SLOTSTREAM_PREFILL_CHUNK'])
    estimated = float(peak[1]) + max(0, selected_chunk - int(chunk[1])) * .0013
    floor = 82 if profile == '78gb' else 31
    required = max(floor, estimated) + cfg['reclaimable_reserve_gb']
    if float(available[1]) < required:
        fail('Need %.1f GB reclaimable including reserve; doctor reports %s GB. Free memory before launching.' % (required, available[1]))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['78gb', '30gb'], default='78gb')
    parser.add_argument('--model', default='~/.slotstream/models/qwen38-flash-next-mlx-4bit')
    parser.add_argument('--port', type=int, default=11434)
    parser.add_argument('--stall-timeout-seconds', type=float, default=0, help='Optional inference-progress watchdog; exits 75 on a stall (0 disables it)')
    parser.add_argument('--supervise', action='store_true', help='Restart failed processes at most three times with fresh preflight; never replay requests')
    parser.add_argument('--dry-run', action='store_true', help='Show exact arguments and profile environment without loading the model')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535: parser.error('port must be between 1 and 65535')
    if not math.isfinite(args.stall_timeout_seconds) or args.stall_timeout_seconds < 0:
        parser.error('stall timeout must be finite and nonnegative')
    cfg, binary, env, common, argv = configuration(args.profile, args.model, args.port)
    if args.stall_timeout_seconds:
        argv += ['--stall-timeout-seconds', str(args.stall_timeout_seconds)]
    if args.dry_run:
        print(json.dumps({'argv': argv, 'environment': cfg['environment'], 'clear_inherited_prefixes': ['SLOTSTREAM_', 'MLX_', 'SS_DEBUG_']}, indent=2))
        return
    if not binary.is_file(): parser.error('Build this profile first with scripts/build.sh ' + args.profile)
    if not Path(args.model).expanduser().is_dir(): parser.error('Model directory missing; download with slotstream pull or pass --model PATH')
    try:
        if args.supervise:
            from supervisor import supervise
            raise SystemExit(supervise(argv, env, lambda: preflight(binary, env, common, cfg, args.profile)))
        preflight(binary, env, common, cfg, args.profile)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.error(str(error))
    os.execve(str(binary), argv, env)

if __name__ == '__main__': main()
