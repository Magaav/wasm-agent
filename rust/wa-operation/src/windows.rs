use super::*;
use std::{ffi::OsStr, os::windows::ffi::OsStrExt, ptr::{null, null_mut}};
use windows_sys::Win32::{Foundation::*, Security::SECURITY_ATTRIBUTES, Storage::FileSystem::*, System::{Threading::*, Pipes::*, JobObjects::*}};

struct Handle(HANDLE);
unsafe impl Send for Handle {}
impl Drop for Handle { fn drop(&mut self) { if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {unsafe {CloseHandle(self.0);}} } }
fn wide(s: &str) -> Vec<u16> { OsStr::new(s).encode_wide().chain(Some(0)).collect() }
fn check(ok: i32) -> io::Result<()> { if ok==0 {Err(io::Error::last_os_error())} else {Ok(())} }
fn quote(arg: &str) -> String {
    let mut out=String::from("\""); let mut slashes=0;
    for c in arg.chars() {
        if c=='\\' {slashes+=1;continue}
        if c=='"' {out.push_str(&"\\".repeat(slashes*2+1));out.push(c)}
        else {out.push_str(&"\\".repeat(slashes));out.push(c)}
        slashes=0;
    }
    out.push_str(&"\\".repeat(slashes*2));out.push('"');out
}
fn pipe() -> io::Result<(Handle,Handle)> {
    let mut r=null_mut();let mut w=null_mut();
    let sa=SECURITY_ATTRIBUTES{nLength:std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,lpSecurityDescriptor:null_mut(),bInheritHandle:1};
    check(unsafe {CreatePipe(&mut r,&mut w,&sa,0)})?;
    let pair=(Handle(r),Handle(w));
    check(unsafe {SetHandleInformation(pair.0.0,HANDLE_FLAG_INHERIT,0)})?;
    Ok(pair)
}
pub struct Process { process: Handle, job: Handle, stdout: Handle, stderr: Handle }
impl Process {
    pub fn spawn(spec: &Spec) -> io::Result<Self> {
        if spec.program.contains('\0') || spec.args.iter().any(|a|a.contains('\0')) || spec.cwd.contains('\0') {
            return Err(io::Error::new(io::ErrorKind::InvalidInput,"NUL in process argument"));
        }
        let job=Handle(unsafe {CreateJobObjectW(null(),null())});
        if job.0.is_null() {return Err(io::Error::last_os_error())}
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION=unsafe {std::mem::zeroed()};
        limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        limits.BasicLimitInformation.ActiveProcessLimit=64;
        check(unsafe {SetInformationJobObject(job.0,JobObjectExtendedLimitInformation,&limits as *const _ as _,std::mem::size_of_val(&limits) as u32)})?;
        let (out_read,out_write)=pipe()?;let (err_read,err_write)=pipe()?;
        let sa=SECURITY_ATTRIBUTES{nLength:std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,lpSecurityDescriptor:null_mut(),bInheritHandle:1};
        let input=Handle(unsafe {CreateFileW(wide("NUL").as_ptr(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,null_mut())});
        if input.0==INVALID_HANDLE_VALUE {return Err(io::Error::last_os_error())}
        // Restrict inheritance to this operation's stdio. Parallel launches must not retain each other's pipes.
        let mut size=0;
        unsafe {InitializeProcThreadAttributeList(null_mut(),1,0,&mut size);}
        let mut storage=vec![0usize;(size+std::mem::size_of::<usize>()-1)/std::mem::size_of::<usize>()];
        let attrs=storage.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
        check(unsafe {InitializeProcThreadAttributeList(attrs,1,0,&mut size)})?;
        struct Attrs(LPPROC_THREAD_ATTRIBUTE_LIST);
        impl Drop for Attrs {fn drop(&mut self){unsafe{DeleteProcThreadAttributeList(self.0)}}}
        let _attrs=Attrs(attrs);
        let handles=[input.0,out_write.0,err_write.0];
        check(unsafe {UpdateProcThreadAttribute(attrs,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,handles.as_ptr() as _,std::mem::size_of_val(&handles),null_mut(),null())})?;
        let mut startup:STARTUPINFOEXW=unsafe {std::mem::zeroed()};
        startup.StartupInfo.cb=std::mem::size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput=input.0;startup.StartupInfo.hStdOutput=out_write.0;startup.StartupInfo.hStdError=err_write.0;
        startup.lpAttributeList=attrs;
        let application=wide(&spec.program);
        let mut command=wide(&std::iter::once(spec.program.as_str()).chain(spec.args.iter().map(String::as_str)).map(quote).collect::<Vec<_>>().join(" "));
        let cwd=wide(&spec.cwd);
        let mut env:std::collections::BTreeMap<String,(String,String)>=std::env::vars().map(|(k,v)|(k.to_uppercase(),(k,v))).collect();
        for (k,v) in &spec.env {env.insert(k.to_uppercase(),(k.clone(),v.clone()));}
        let mut env_wide:Vec<u16>=env.values().flat_map(|(k,v)|wide(&format!("{k}={v}"))).collect();env_wide.push(0);
        let mut info:PROCESS_INFORMATION=unsafe {std::mem::zeroed()};
        check(unsafe {CreateProcessW(application.as_ptr(),command.as_mut_ptr(),null(),null(),1,CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT|EXTENDED_STARTUPINFO_PRESENT,env_wide.as_ptr() as _,if spec.cwd.is_empty(){null()}else{cwd.as_ptr()},&startup.StartupInfo,&mut info)})?;
        let process=Handle(info.hProcess);let thread=Handle(info.hThread);
        // The child cannot spawn anything before containment is installed. Failure never resumes it.
        if let Err(e)=check(unsafe {AssignProcessToJobObject(job.0,process.0)}) {
            unsafe {TerminateProcess(process.0,1);}
            return Err(e)
        }
        let result=Self {process,job,stdout:out_read,stderr:err_read};
        if unsafe {ResumeThread(thread.0)}==u32::MAX {return Err(io::Error::last_os_error())}
        Ok(result)
    }
    pub fn code(&mut self)->io::Result<Option<i32>> {
        match unsafe {WaitForSingleObject(self.process.0,0)} {
            WAIT_TIMEOUT=>Ok(None),
            WAIT_OBJECT_0=>{let mut code=0;check(unsafe {GetExitCodeProcess(self.process.0,&mut code)})?;Ok(Some(code as i32))},
            _=>Err(io::Error::last_os_error()),
        }
    }
    pub fn terminate(&mut self)->io::Result<()> {check(unsafe {TerminateJobObject(self.job.0,1)})}
    pub fn descendants(&self)->io::Result<bool> {
        // Accounting can briefly include an already-signalled root; do not misreport that as an orphan.
        let mut storage=[0usize;66];
        check(unsafe {QueryInformationJobObject(self.job.0,JobObjectBasicProcessIdList,storage.as_mut_ptr() as _,std::mem::size_of_val(&storage) as u32,null_mut())})?;
        let list=unsafe {&*(storage.as_ptr() as *const JOBOBJECT_BASIC_PROCESS_ID_LIST)};
        let ids=unsafe {std::slice::from_raw_parts(list.ProcessIdList.as_ptr(),list.NumberOfProcessIdsInList as usize)};
        let root=unsafe {GetProcessId(self.process.0)};
        for &id in ids {
            if id as u32==root {continue}
            let handle=Handle(unsafe {OpenProcess(SYNCHRONIZE,0,id as u32)});
            if !handle.0.is_null() && unsafe {WaitForSingleObject(handle.0,0)}==WAIT_TIMEOUT {return Ok(true)}
        }
        Ok(false)
    }
    pub fn containment()-> &'static str {"windows_job_object"}
    pub fn read(&mut self, stderr:bool, buffer:&mut [u8])->io::Result<Option<usize>> {
        let pipe=if stderr {self.stderr.0}else{self.stdout.0};let mut available=0;
        if unsafe {PeekNamedPipe(pipe,null_mut(),0,null_mut(),&mut available,null_mut())}==0 {
            let error=io::Error::last_os_error();
            if error.raw_os_error()==Some(ERROR_BROKEN_PIPE as i32) {return Ok(Some(0))}
            return Err(error)
        }
        if available==0 {return Ok(None)}
        let mut read=0;
        check(unsafe {ReadFile(pipe,buffer.as_mut_ptr(),available.min(buffer.len() as u32),&mut read,null_mut())})?;
        Ok(Some(read as usize))
    }
}
impl Drop for Process {fn drop(&mut self){let _=self.terminate();}}
