#!/usr/bin/env python3
"""Check a running Slotstream server with a small real completion."""
import argparse, json, urllib.request
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base-url', default='http://127.0.0.1:11434')
a = p.parse_args()
body = dict(model='qwen3.8-flash-next:4bit', messages=[dict(role='user',content='Reply with READY.')],
            stream=False,max_tokens=32,temperature=0,top_p=1,top_k=0,presence_penalty=0,seed=42,reasoning_effort='none')
request = urllib.request.Request(a.base_url.rstrip('/')+'/v1/chat/completions',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
with urllib.request.urlopen(request, timeout=180) as response:
    result = json.load(response)
choice = result['choices'][0]
answer = choice['message'].get('content','')
if choice.get('finish_reason')!='stop' or not isinstance(answer,str) or not answer.strip() or choice['message'].get('tool_calls'):
    raise SystemExit('API check failed: completion was empty, incomplete, or an unexpected tool call')
print('API check passed:', answer.strip())
