"""Own Windows Job BEFORE child resume; retain process creation/root exit/active-zero receipts.
Runs real-parent harness inside owned tree. No global process control.
"""
import argparse,ctypes,json,os,pathlib,subprocess,time
from ctypes import wintypes as w
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--evidence',required=True);p.add_argument('--assign-failure',action='store_true');a=p.parse_args()
root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
if os.name!='nt':print('SKIP: owned Windows Job proof (1 skipped)');raise SystemExit(0)
k=ctypes.WinDLL('kernel32',use_last_error=True)
class STARTUP(ctypes.Structure):
 _fields_=[('cb',w.DWORD),('reserved',w.LPWSTR),('desktop',w.LPWSTR),('title',w.LPWSTR),('x',w.DWORD),('y',w.DWORD),('xs',w.DWORD),('ys',w.DWORD),('xc',w.DWORD),('yc',w.DWORD),('fill',w.DWORD),('flags',w.DWORD),('show',w.WORD),('reserved2size',w.WORD),('reserved2',ctypes.c_void_p),('stdin',w.HANDLE),('stdout',w.HANDLE),('stderr',w.HANDLE)]
class PROCESS(ctypes.Structure):_fields_=[('process',w.HANDLE),('thread',w.HANDLE),('pid',w.DWORD),('tid',w.DWORD)]
class ACCOUNT(ctypes.Structure):_fields_=[('user',ctypes.c_longlong),('kernel',ctypes.c_longlong),('pu',ctypes.c_longlong),('pk',ctypes.c_longlong),('faults',w.DWORD),('total',w.DWORD),('active',w.DWORD),('terminated',w.DWORD)]
k.CreateJobObjectW.argtypes=[ctypes.c_void_p,w.LPCWSTR];k.CreateJobObjectW.restype=w.HANDLE
k.CreateProcessW.argtypes=[w.LPCWSTR,w.LPWSTR,ctypes.c_void_p,ctypes.c_void_p,w.BOOL,w.DWORD,ctypes.c_void_p,w.LPCWSTR,ctypes.POINTER(STARTUP),ctypes.POINTER(PROCESS)];k.CreateProcessW.restype=w.BOOL
for name,args in [('AssignProcessToJobObject',[w.HANDLE,w.HANDLE]),('TerminateProcess',[w.HANDLE,w.UINT]),('TerminateJobObject',[w.HANDLE,w.UINT]),('WaitForSingleObject',[w.HANDLE,w.DWORD]),('ResumeThread',[w.HANDLE]),('CloseHandle',[w.HANDLE]),('GetExitCodeProcess',[w.HANDLE,ctypes.POINTER(w.DWORD)]),('QueryInformationJobObject',[w.HANDLE,ctypes.c_int,ctypes.c_void_p,w.DWORD,ctypes.c_void_p])]:getattr(k,name).argtypes=args
repo=pathlib.Path(a.repo).resolve();script=repo/'scripts/test-sentinel-real-parent.cjs'
node=subprocess.check_output(['where','node'],text=True).splitlines()[0]
command=subprocess.list2cmdline([node,str(script)])
startup=STARTUP();startup.cb=ctypes.sizeof(startup);process=PROCESS();job=k.CreateJobObjectW(None,None);assert job
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
  assert acc.total>=3,'real node and sentinel creation not observed'
  assert code.value==0,'real-parent child failed'
finally:
 (root/'job-receipt.json').write_text(json.dumps(facts,indent=2))
 k.CloseHandle(process.thread);k.CloseHandle(process.process);k.CloseHandle(job)
print('owned return Job ok (1 check, 0 skipped): '+json.dumps(facts))
