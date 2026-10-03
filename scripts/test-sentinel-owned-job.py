"""Own Windows Job BEFORE child resume; retain process creation/root exit/active-zero receipts.
Runs real-parent harness inside owned tree. No global process control.
"""
import argparse,ctypes,json,os,pathlib,subprocess,time
from ctypes import wintypes as w
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--evidence',required=True);p.add_argument('--assign-failure',action='store_true');p.add_argument('--escape-attempt',action='store_true');a=p.parse_args()
root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
if os.name!='nt':print('SKIP: owned Windows Job proof (1 skipped)');raise SystemExit(0)
k=ctypes.WinDLL('kernel32',use_last_error=True)
class STARTUP(ctypes.Structure):
 _fields_=[('cb',w.DWORD),('reserved',w.LPWSTR),('desktop',w.LPWSTR),('title',w.LPWSTR),('x',w.DWORD),('y',w.DWORD),('xs',w.DWORD),('ys',w.DWORD),('xc',w.DWORD),('yc',w.DWORD),('fill',w.DWORD),('flags',w.DWORD),('show',w.WORD),('reserved2size',w.WORD),('reserved2',ctypes.c_void_p),('stdin',w.HANDLE),('stdout',w.HANDLE),('stderr',w.HANDLE)]
class PROCESS(ctypes.Structure):_fields_=[('process',w.HANDLE),('thread',w.HANDLE),('pid',w.DWORD),('tid',w.DWORD)]
class BASICLIMIT(ctypes.Structure):
 _fields_=[('perprocess',ctypes.c_longlong),('perjob',ctypes.c_longlong),('flags',w.DWORD),('minimum',ctypes.c_size_t),('maximum',ctypes.c_size_t),('active_limit',w.DWORD),('affinity',ctypes.c_size_t),('priority',w.DWORD),('scheduling',w.DWORD)]
class IO(ctypes.Structure):_fields_=[(name,ctypes.c_ulonglong) for name in ['readops','writeops','otherops','readbytes','writebytes','otherbytes']]
class EXTENDED(ctypes.Structure):_fields_=[('basic',BASICLIMIT),('io',IO),('processmem',ctypes.c_size_t),('jobmem',ctypes.c_size_t),('peakprocess',ctypes.c_size_t),('peakjob',ctypes.c_size_t)]
class ACCOUNT(ctypes.Structure):_fields_=[('user',ctypes.c_longlong),('kernel',ctypes.c_longlong),('pu',ctypes.c_longlong),('pk',ctypes.c_longlong),('faults',w.DWORD),('total',w.DWORD),('active',w.DWORD),('terminated',w.DWORD)]
k.CreateJobObjectW.argtypes=[ctypes.c_void_p,w.LPCWSTR];k.CreateJobObjectW.restype=w.HANDLE
k.CreateProcessW.argtypes=[w.LPCWSTR,w.LPWSTR,ctypes.c_void_p,ctypes.c_void_p,w.BOOL,w.DWORD,ctypes.c_void_p,w.LPCWSTR,ctypes.POINTER(STARTUP),ctypes.POINTER(PROCESS)];k.CreateProcessW.restype=w.BOOL
for name,args in [('AssignProcessToJobObject',[w.HANDLE,w.HANDLE]),('TerminateProcess',[w.HANDLE,w.UINT]),('TerminateJobObject',[w.HANDLE,w.UINT]),('WaitForSingleObject',[w.HANDLE,w.DWORD]),('ResumeThread',[w.HANDLE]),('CloseHandle',[w.HANDLE]),('GetExitCodeProcess',[w.HANDLE,ctypes.POINTER(w.DWORD)]),('QueryInformationJobObject',[w.HANDLE,ctypes.c_int,ctypes.c_void_p,w.DWORD,ctypes.c_void_p])]:getattr(k,name).argtypes=args
repo=pathlib.Path(a.repo).resolve();script=repo/'scripts/test-sentinel-real-parent.cjs'
node=subprocess.check_output(['where','node'],text=True).splitlines()[0]
if a.escape_attempt:
 probe=root/'escape.cjs'
 childinfo=root/'attempt-child.json'
 py="import subprocess,sys,json,time; f=sys.argv[1];\ntry:\n p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(10)'],creationflags=0x01000000);open(f,'w').write(json.dumps({'pid':p.pid,'created':True}));p.wait()\nexcept OSError as e:\n open(f,'w').write(json.dumps({'created':False,'error':str(e)}))"
 probe.write_text("const {spawnSync}=require('child_process');const r=spawnSync('python',['-c',"+json.dumps(py)+","+json.dumps(str(childinfo))+"]);process.exit(r.status||0);")
 script=probe
command=subprocess.list2cmdline([node,str(script)])
startup=STARTUP();startup.cb=ctypes.sizeof(startup);process=PROCESS();job=k.CreateJobObjectW(None,None);assert job
k.SetInformationJobObject.argtypes=[w.HANDLE,ctypes.c_int,ctypes.c_void_p,w.DWORD];k.SetInformationJobObject.restype=w.BOOL
k.IsProcessInJob.argtypes=[w.HANDLE,w.HANDLE,ctypes.POINTER(w.BOOL)];k.IsProcessInJob.restype=w.BOOL
limits=EXTENDED();limits.basic.flags=0x2000 # KILL_ON_JOB_CLOSE, neither breakaway flag
assert k.SetInformationJobObject(job,9,ctypes.byref(limits),ctypes.sizeof(limits)),ctypes.get_last_error()
applied=EXTENDED();assert k.QueryInformationJobObject(job,9,ctypes.byref(applied),ctypes.sizeof(applied),None)
assert applied.basic.flags==0x2000,'owned limits not applied'
# inherited environment is consumed only by harness's explicit private environment allowlist.
assert k.CreateProcessW(node,ctypes.create_unicode_buffer(command),None,None,False,4,None,str(repo),ctypes.byref(startup),ctypes.byref(process)),ctypes.get_last_error()
facts={'pid':process.pid,'created_suspended':True,'resumed':False,'assignment_injected_failure':a.assign_failure}
try:
 assigned=False if a.assign_failure else bool(k.AssignProcessToJobObject(job,process.process))
 if not assigned:
  assert k.TerminateProcess(process.process,91);assert k.WaitForSingleObject(process.process,10000)==0
  code=w.DWORD();assert k.GetExitCodeProcess(process.process,ctypes.byref(code));facts.update(exit=code.value,active=0,negative=True)
  assert code.value==91,'suspended assignment failure cleanup wrong exit'
 else:
  assert k.ResumeThread(process.thread)!=0xffffffff;facts['resumed']=True
  if a.escape_attempt:
   deadline=time.monotonic()+8
   while not childinfo.exists() and time.monotonic()<deadline:time.sleep(.01)
   assert childinfo.exists(),'attempt child receipt missing'
   info=json.loads(childinfo.read_text());facts['breakaway_attempt']=info
   if info['created']:
    k.OpenProcess.argtypes=[w.DWORD,w.BOOL,w.DWORD];k.OpenProcess.restype=w.HANDLE
    childhandle=k.OpenProcess(0x1000|0x100000|1,False,info['pid']);assert childhandle,ctypes.get_last_error()
    member=w.BOOL();assert k.IsProcessInJob(childhandle,job,ctypes.byref(member)),ctypes.get_last_error()
    facts['attempted_child_in_exact_job']=bool(member.value)
    if not member.value:
     assert k.TerminateProcess(childhandle,94);assert k.WaitForSingleObject(childhandle,10000)==0
     facts['escaped_child_killed_waited']=True
     k.CloseHandle(childhandle)
     k.TerminateJobObject(job,95);k.WaitForSingleObject(process.process,10000)
     raise AssertionError('attempted child escaped exact owned Job')
    k.CloseHandle(childhandle)
  wait=k.WaitForSingleObject(process.process,100000)
  if wait!=0:
   k.TerminateJobObject(job,92);k.WaitForSingleObject(process.process,10000);raise AssertionError('private harness deadline; tree terminated')
  code=w.DWORD();assert k.GetExitCodeProcess(process.process,ctypes.byref(code));facts['exit']=code.value
  deadline=time.monotonic()+15
  while True:
   acc=ACCOUNT();assert k.QueryInformationJobObject(job,1,ctypes.byref(acc),ctypes.sizeof(acc),None),ctypes.get_last_error()
   if acc.active==0:break
   if time.monotonic()>deadline:k.TerminateJobObject(job,93);raise AssertionError('owned descendants remain after root exit')
   time.sleep(.05)
  facts.update(active=acc.active,total_created=acc.total,terminated=acc.terminated)
  assert acc.total>=(2 if a.escape_attempt else 3),'owned process creation not observed'
  assert code.value==0,'real-parent child failed'
finally:
 code=w.DWORD();k.GetExitCodeProcess(process.process,ctypes.byref(code))
 if code.value==259:
  k.TerminateJobObject(job,96);k.TerminateProcess(process.process,96);assert k.WaitForSingleObject(process.process,10000)==0
 acc=ACCOUNT();assert k.QueryInformationJobObject(job,1,ctypes.byref(acc),ctypes.sizeof(acc),None)
 deadline=time.monotonic()+10
 while acc.active and time.monotonic()<deadline:
  time.sleep(.02);assert k.QueryInformationJobObject(job,1,ctypes.byref(acc),ctypes.sizeof(acc),None)
 facts['final_active']=acc.active;assert acc.active==0,'cleanup active processes unknown'
 (root/'job-receipt.json').write_text(json.dumps(facts,indent=2))
 k.CloseHandle(process.thread);k.CloseHandle(process.process);k.CloseHandle(job)
print('owned return Job ok (1 check, 0 skipped): '+json.dumps(facts))
