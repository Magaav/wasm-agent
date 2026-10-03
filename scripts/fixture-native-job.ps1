# Windows-only fixture containment. Start suspended, assign an owned kill-on-close Job,
# then resume; a stop-file request terminates only that Job and proves descendant drain.
param([Parameter(Mandatory=$true)][string]$Spec)
$ErrorActionPreference='Stop'
$request=Get-Content -LiteralPath $Spec -Raw | ConvertFrom-Json
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FixtureJob {
 [StructLayout(LayoutKind.Sequential)] public struct Startup { public uint cb; public IntPtr reserved,desktop,title; public uint x,y,cx,cy,xchars,ychars,fill,flags; public ushort show,reserved2; public IntPtr reservedPtr,stdin,stdout,stderr; }
 [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
 [StructLayout(LayoutKind.Sequential)] public struct BasicLimits { public long user,job; public uint flags; public UIntPtr min,max; public uint active; public UIntPtr affinity; public uint priority,scheduling; }
 [StructLayout(LayoutKind.Sequential)] public struct Io { public ulong reads,writes,other,readBytes,writeBytes,otherBytes; }
 [StructLayout(LayoutKind.Sequential)] public struct Limits { public BasicLimits basic; public Io io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
 [StructLayout(LayoutKind.Sequential)] public struct Accounting { public long user,kernel,periodUser,periodKernel; public uint faults,total,active,terminated; }
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr attributes,string name);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr job,int kind,ref Limits info,uint size);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting info,uint size,IntPtr returned);
 [DllImport("kernel32.dll", EntryPoint="QueryInformationJobObject", SetLastError=true)] public static extern bool QueryLimits(IntPtr job,int kind,out Limits info,uint size,IntPtr returned);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateProcess(string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr env,string cwd,ref Startup startup,out ProcessInfo info);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool inJob);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateJobObject(IntPtr job,uint exit);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process,uint exit);
 [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle,uint ms);
 [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
 [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int kind);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
 public static string Quote(string arg) {
   var b=new StringBuilder("\"");int slash=0;
   foreach(char c in arg) { if(c=='\\'){slash++;continue;}if(c=='\"'){b.Append('\\',slash*2+1);b.Append(c);}else{b.Append('\\',slash);b.Append(c);}slash=0; }
   b.Append('\\',slash*2);b.Append('"');return b.ToString();
 }
 public static void Check(bool ok,string step) { if(!ok)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),step); }
 public static Limits KillOnClose() { var limits=new Limits(); limits.basic.flags=0x2000; return limits; }
}
'@
$job=[IntPtr]::Zero
$process=New-Object FixtureJob+ProcessInfo
$proof=@{schema=1;creation_proven=$false;assigned=$false;drained=$false;phase='starting';stop_requested=$false}
function Save-Proof { [IO.File]::WriteAllText($request.receipt,($proof | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false)) }
try {
 $job=[FixtureJob]::CreateJobObject([IntPtr]::Zero,$null)
 [FixtureJob]::Check(($job -ne [IntPtr]::Zero),'CreateJobObject')
 # PowerShell mutates a boxed copy for `limits.basic.flags`; initialise the nested struct in C#.
 $limits=[FixtureJob]::KillOnClose()
 [FixtureJob]::Check([FixtureJob]::SetInformationJobObject($job,9,[ref]$limits,[Runtime.InteropServices.Marshal]::SizeOf($limits)),'SetInformationJobObject')
 $actualLimits=New-Object FixtureJob+Limits
 [FixtureJob]::Check([FixtureJob]::QueryLimits($job,9,[ref]$actualLimits,[Runtime.InteropServices.Marshal]::SizeOf($actualLimits),[IntPtr]::Zero),'QueryInformationJobObject limits')
 $proof.limit_flags=$actualLimits.basic.flags;$proof.kill_on_close=($actualLimits.basic.flags -band 0x2000) -ne 0
 [FixtureJob]::Check($proof.kill_on_close,'owned Job must enforce kill-on-close')
 $proof.no_breakaway=($actualLimits.basic.flags -band 0x1800) -eq 0
 [FixtureJob]::Check($proof.no_breakaway,'owned Job must refuse breakaway flags')
 $startup=New-Object FixtureJob+Startup
 $startup.cb=[Runtime.InteropServices.Marshal]::SizeOf($startup)
 $startup.flags=0x100
 $startup.stdin=[FixtureJob]::GetStdHandle(-10);$startup.stdout=[FixtureJob]::GetStdHandle(-11);$startup.stderr=[FixtureJob]::GetStdHandle(-12)
 $quoted=@([FixtureJob]::Quote($request.program));foreach($argument in $request.args){$quoted += [FixtureJob]::Quote([string]$argument)}
 $command=[Text.StringBuilder]::new(($quoted -join ' '))
 [FixtureJob]::Check([FixtureJob]::CreateProcess($request.program,$command,[IntPtr]::Zero,[IntPtr]::Zero,$true,0x08000004,[IntPtr]::Zero,$request.cwd,[ref]$startup,[ref]$process),'CreateProcess suspended')
 $proof.creation_proven=$true;$proof.native_pid=$process.pid
 [FixtureJob]::Check([FixtureJob]::AssignProcessToJobObject($job,$process.process),'AssignProcessToJobObject')
 $proof.assigned=$true
 $inJob=$false;[FixtureJob]::Check([FixtureJob]::IsProcessInJob($process.process,$job,[ref]$inJob),'IsProcessInJob')
 [FixtureJob]::Check($inJob,'native process must belong to its owned Job');$proof.in_job=$inJob
 [FixtureJob]::Check(([FixtureJob]::ResumeThread($process.thread) -ne [uint32]::MaxValue),'ResumeThread')
 $proof.phase='running';Save-Proof
 while ([FixtureJob]::WaitForSingleObject($process.process,50) -eq 258) {
   if (Test-Path -LiteralPath $request.stop) {
     $proof.stop_requested=$true
     [FixtureJob]::Check([FixtureJob]::TerminateJobObject($job,0),'TerminateJobObject')
     break
   }
 }
 [FixtureJob]::Check(([FixtureJob]::WaitForSingleObject($process.process,10000) -eq 0),'wait native process')
 $accounting=New-Object FixtureJob+Accounting
 $deadline=[DateTime]::UtcNow.AddSeconds(10)
 do {
   [FixtureJob]::Check([FixtureJob]::QueryInformationJobObject($job,1,[ref]$accounting,[Runtime.InteropServices.Marshal]::SizeOf($accounting),[IntPtr]::Zero),'QueryInformationJobObject accounting')
   if($accounting.active -eq 0){break}
   if(-not $proof.stop_requested){[FixtureJob]::Check([FixtureJob]::TerminateJobObject($job,0),'drain remaining descendants');$proof.stop_requested=$true}
   Start-Sleep -Milliseconds 50
 }while([DateTime]::UtcNow -lt $deadline)
 $proof.accounting=@{active_processes=$accounting.active;total_processes=$accounting.total;terminated_processes=$accounting.terminated}
 $proof.drained=$accounting.active -eq 0
 $proof.phase='exited'
 $nativeExit=[uint32]0;[FixtureJob]::Check([FixtureJob]::GetExitCodeProcess($process.process,[ref]$nativeExit),'GetExitCodeProcess');$proof.native_exit=$nativeExit
 Save-Proof
 if(-not $proof.drained){throw 'fixture_job_descendant_drain_unverified'}
 if(-not $proof.stop_requested -and $nativeExit -ne 0){exit 1}
}catch {
 $proof.error=$_.Exception.Message;$proof.phase='failed';Save-Proof
 Write-Error $_ -ErrorAction Continue
 exit 1
}finally {
 # Even assignment failure cannot leave a suspended process outside our Job.
 if($process.process -ne [IntPtr]::Zero -and -not $proof.assigned){[void][FixtureJob]::TerminateProcess($process.process,1);[void][FixtureJob]::WaitForSingleObject($process.process,10000)}
 if($process.thread -ne [IntPtr]::Zero){[void][FixtureJob]::CloseHandle($process.thread)}
 if($process.process -ne [IntPtr]::Zero){[void][FixtureJob]::CloseHandle($process.process)}
 if($job -ne [IntPtr]::Zero){[void][FixtureJob]::CloseHandle($job)}
}
