#!__PYTHON__
import json, os, signal, sys, time
from pathlib import Path

THREAD='11111111-1111-4111-8111-111111111111'
OTHER='22222222-2222-4222-8222-222222222222'
RELATIVE='sessions/2026/08/03/rollout-2026-08-03T00-00-00-11111111-1111-4111-8111-111111111111.jsonl'
args=sys.argv[1:]
if args == ["--version"]:
 print("codex-cli __VERSION__")
 raise SystemExit(0)
if args == ["exec", "resume", "--help"]:
 print("SESSION_ID PROMPT --last --all")
 raise SystemExit(0)
if args == ["exec", "--help"]:
 print("--json --color --sandbox --config --skip-git-repo-check --ignore-user-config --ignore-rules")
 raise SystemExit(0)
prompt=args[-1]
if "--dangerously-bypass-approvals-and-sandbox" in args and args[-2] != "--":
 raise SystemExit(73)
resume="resume" in args
thread=args[args.index("resume")+1] if resume else THREAD
home=Path(os.environ["CODEX_HOME"])
auth=home / "auth.json"
auth.write_bytes(auth.read_bytes()+b"|refreshed")
auth.chmod(0o600)
if resume:
 matches=list(home.glob(f"sessions/**/*-{thread}.jsonl"))
 if len(matches)!=1: raise SystemExit(70)
 rollout=matches[0]
 prior=rollout.read_bytes()
else:
 rollout=home / RELATIVE
 rollout.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 prior=b""
if prompt == "oversize-rollout":
 rollout.write_bytes(b"x"*1000001)
else:
 rollout.write_bytes(prior+b"\n"+prompt.encode())
rollout.chmod(0o600)
if prompt in {"timeout", "cancel-me"}:
 time.sleep(5)
if prompt == "command-signal":
 os.kill(os.getpid(),signal.SIGTERM)
if prompt == "output-overflow":
 sys.stdout.write("x"*100000); sys.stdout.flush(); time.sleep(5)
if prompt == "malformed-jsonl":
 print("not-json")
 raise SystemExit(0)
emitted=OTHER if prompt == "foreign-thread" else thread
print(json.dumps({"type":"thread.started","thread_id":emitted}))
print(json.dumps({"type":"turn.started"}))
if prompt == "provider-failure":
 print(json.dumps({"type":"turn.failed","error":{"message":"provider canary not retained"}}))
 raise SystemExit(1)
text=("resumed:first:second" if resume and b"first" in prior and prompt=="second" else "answer:"+prompt)
print(json.dumps({"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":text}}))
print(json.dumps({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}))
