
import json, os, re, stat, sys
MAX=1000000
PAT=re.compile(r"sessions/(?P<y>[0-9]{4})/(?P<m>0[1-9]|1[0-2])/(?P<d>0[1-9]|[12][0-9]|3[01])/rollout-[A-Za-z0-9_.-]+-(?P<t>[0-9a-f-]{36})\.jsonl")
HOME=os.environ["CODEX_HOME"]
TRANSFER=os.environ["PETRUS_CODEX_ROLLOUT_ROOT"]
LEAF=os.path.join(TRANSFER,"rollout.jsonl")

def fail():
 raise RuntimeError()

def directory(path):
 value=os.lstat(path)
 if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode) or stat.S_IMODE(value.st_mode)!=0o700 or value.st_uid!=os.geteuid(): fail()

def opened(path, flags, strict=True):
 fd=os.open(path,flags|os.O_NOFOLLOW)
 value=os.fstat(fd)
 if not stat.S_ISREG(value.st_mode) or value.st_uid!=os.geteuid() or value.st_nlink!=1 or (strict and stat.S_IMODE(value.st_mode)!=0o600):
  os.close(fd); fail()
 return fd,value

def read(path, nonempty=True, strict=True, normalize=False):
 fd,before=opened(path,os.O_RDONLY,strict)
 try:
  if normalize:
   os.fchmod(fd,0o600); before=os.fstat(fd)
  chunks=[]; retained=0
  while retained<=MAX:
   chunk=os.read(fd,min(65536,MAX+1-retained))
   if not chunk: break
   chunks.append(chunk); retained+=len(chunk)
  after=os.fstat(fd)
 finally: os.close(fd)
 data=b"".join(chunks)
 stable=(before.st_dev,before.st_ino,before.st_mode,before.st_uid,before.st_nlink,before.st_size,before.st_mtime_ns,before.st_ctime_ns)==(after.st_dev,after.st_ino,after.st_mode,after.st_uid,after.st_nlink,after.st_size,after.st_mtime_ns,after.st_ctime_ns)
 if not stable or len(data)!=after.st_size or len(data)>MAX or (nonempty and not data): fail()
 return data

def write_all(fd,data):
 pending=memoryview(data)
 while pending:
  count=os.write(fd,pending)
  if count<=0: fail()
  pending=pending[count:]

def replace(path,data):
 fd,_=opened(path,os.O_WRONLY)
 try:
  os.ftruncate(fd,0); os.fchmod(fd,0o600); write_all(fd,data); os.fsync(fd)
 finally: os.close(fd)
 read(path)

def create(path,data):
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try:
  os.fchmod(fd,0o600); write_all(fd,data); os.fsync(fd)
 finally: os.close(fd)
 read(path)

def safe_dirs(parts):
 path=HOME
 for part in parts:
  path=os.path.join(path,part)
  try: os.mkdir(path,0o700)
  except FileExistsError: pass
  directory(path)
 return path

def provider_directory(path):
 value=os.lstat(path)
 if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode) or value.st_uid!=os.geteuid(): fail()

def scrub():
 violation=False
 for root,dirs,files in os.walk(HOME,topdown=False,followlinks=False):
  for name in files:
   path=os.path.join(root,name)
   if path==os.path.join(HOME,"auth.json"): continue
   value=os.lstat(path)
   violation=violation or stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode) or value.st_uid!=os.geteuid() or (stat.S_ISREG(value.st_mode) and value.st_nlink!=1)
   os.unlink(path)
  for name in dirs:
   path=os.path.join(root,name); value=os.lstat(path)
   if stat.S_ISLNK(value.st_mode):
    violation=True; os.unlink(path)
   else:
    if not stat.S_ISDIR(value.st_mode) or value.st_uid!=os.geteuid(): violation=True
    os.rmdir(path)
 read(os.path.join(HOME,"auth.json"))
 if os.listdir(HOME)!=["auth.json"]: fail()
 return violation

def main():
 directory(HOME); directory(TRANSFER)
 read(os.path.join(HOME,"auth.json"))
 mode=sys.argv[1]
 if mode=="stage":
  thread,relative=sys.argv[2:4]; match=PAT.fullmatch(relative)
  if not match or match.group("t")!=thread: fail()
  data=read(LEAF); parent=safe_dirs(relative.split("/")[:-1]); target=os.path.join(parent,relative.split("/")[-1])
  if os.path.lexists(target): fail()
  create(target,data); print('{"ok":true}')
 elif mode=="collect":
  thread=sys.argv[2]; found=[]
  for root,dirs,files in os.walk(HOME,topdown=True,followlinks=False):
   for name in dirs:
    provider_directory(os.path.join(root,name))
   for name in files:
    path=os.path.join(root,name); relative=os.path.relpath(path,HOME).replace(os.sep,"/")
    match=PAT.fullmatch(relative)
    if match: found.append((path,relative,match.group("t")))
  if len(found)!=1 or found[0][2]!=thread: fail()
  source,relative,_=found[0]; data=read(source,strict=False,normalize=True); replace(LEAF,data)
  if scrub(): fail()
  print(json.dumps({"ok":True,"rollout_path":relative},separators=(",",":")))
 elif mode=="scrub":
  if scrub(): fail()
  print('{"ok":true}')
 else: fail()

try: main()
except Exception: raise SystemExit(64)
