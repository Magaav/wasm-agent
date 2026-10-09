#[cfg(windows)]
use super::*;
#[cfg(windows)]
#[test]
fn captured_command_has_no_console_and_native_probes_use_no_children(){
 use std::os::windows::process::CommandExt;
 let system=std::env::var("SystemRoot").unwrap();
 let expression="$x=Add-Type -PassThru -Name QuietProbe -Namespace Wa -MemberDefinition '[System.Runtime.InteropServices.DllImport(\"kernel32.dll\")] public static extern System.IntPtr GetConsoleWindow();'; if($x::GetConsoleWindow() -ne [IntPtr]::Zero){exit 7}; Write-Output quiet";
 let output=quiet_command(std::path::PathBuf::from(system).join("System32/WindowsPowerShell/v1.0/powershell.exe"))
  .args(["-NoProfile","-NonInteractive","-Command",expression]).output().unwrap();
 assert!(output.status.success(),"{}",String::from_utf8_lossy(&output.stderr));
 assert!(String::from_utf8_lossy(&output.stdout).contains("quiet"));
 // A deliberate mutation creating a console must fail the same predicate.
 let control=quiet_command("powershell.exe").creation_flags(windows_sys::Win32::System::Threading::CREATE_NEW_CONSOLE)
  .args(["-NoProfile","-NonInteractive","-Command",expression]).output().unwrap();
 assert!(!control.status.success(),"console predicate did not discriminate");
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
 assert_eq!(winproc::listener_pid(port),Some(std::process::id()));
 assert!(winproc::pid_alive(std::process::id()));assert!(!winproc::pid_alive(0));
 drop(listener);assert_eq!(winproc::listener_pid(port),None);
 let ipv6=std::net::TcpListener::bind("[::1]:0").unwrap();let v6port=ipv6.local_addr().unwrap().port();
 assert_eq!(winproc::listener_pid(v6port),Some(std::process::id()));drop(ipv6);
 assert_eq!(winproc::listener_pid(v6port),None);
 assert_eq!(crate::shell_for(std::path::Path::new("C:/fixture.sh")).0,"C:\\Program Files\\Git\\usr\\bin\\bash.exe");
}
