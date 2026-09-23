---
name: windows-test-vm
description: Use when bootstrapping, starting, repairing, accessing by SSH, or testing wasm-agent in a disposable Windows Hyper-V VM on the operator's PC.
---

# Windows release test VM

Use the existing scratch VM when it is healthy. Keep the operator's desktop free: use host Hyper-V PowerShell only for VM lifecycle and guest SSH for installation, tests, and cleanup. A VMConnect console is a one-time fallback for first boot or SSH repair, not the normal control channel.

## Identify the VM before acting

The VM created for the September 2026 release test is `wa-av-test-20260923`, Hyper-V ID `17a4bed1-0384-405a-98e3-ddd176e18aa0`, with disk `C:\Users\Victor\AppData\Local\Temp\wa-av-test-20260923\clean.vhdx`. It is a clean Windows 11 Home 23H2 guest with local administrator `wa-test`, 4 GB RAM, 2 CPUs, a dynamic 64 GB VHDX, and the Hyper-V Default Switch. The other VM, `w11`, belongs to the operator: leave its state and disks alone.

In elevated **host** PowerShell, verify name, ID, disk, state and adapter before starting, stopping, mounting or replacing anything:

```powershell
$vm = Get-VM -Name 'wa-av-test-20260923' -ErrorAction Stop
$disk = Get-VMHardDiskDrive -VMName $vm.Name
$nic = Get-VMNetworkAdapter -VMName $vm.Name
$vm | Select-Object Name,Id,State,MemoryAssigned
$disk | Select-Object Path
$nic | Select-Object SwitchName,IPAddresses
```

The guest IP previously was `172.23.132.56`, and the host Default Switch address was `172.23.128.1`; both can change. Obtain the current IP from Hyper-V and verify SSH connectivity instead of trusting a cached address. `Get-VMNetworkAdapter` can temporarily show a stale address during boot. The host firewall should allow SSH only from the host's current switch address. Preserve this VM's disk at the end of a test; stop only this VM so its 4 GB RAM is released.

## If there is no suitable scratch VM

Check available C: space, RAM, Hyper-V availability, Windows ISO, and existing VM names first. A clean Windows install consumed roughly 17 GB of host disk here even though the VHDX's maximum is 64 GB; about 22 GB free on C: was tight. Do not reclaim unrelated files or Docker data without a separate reason. Create a distinct scratch VM and record its name, ID, disk and ISO. Example host commands, with new paths chosen for that run:

```powershell
$name = 'wa-av-test-YYYYMMDD'
$root = Join-Path $env:LOCALAPPDATA "Temp\$name"
$iso = 'C:\Users\Victor\Downloads\Win11_23H2_English_x64v2.iso'
New-Item -ItemType Directory -Path $root -Force | Out-Null
New-VHD -Path (Join-Path $root 'clean.vhdx') -Dynamic -SizeBytes 64GB
New-VM -Name $name -Generation 2 -MemoryStartupBytes 4GB -VHDPath (Join-Path $root 'clean.vhdx') -Path $root -SwitchName 'Default Switch'
Set-VMProcessor -VMName $name -Count 2
Add-VMDvdDrive -VMName $name -Path $iso
Set-VMFirmware -VMName $name -FirstBootDevice (Get-VMDvdDrive -VMName $name)
```

An older 23H2 ISO failed Secure Boot in this scratch VM; `Set-VMFirmware -VMName $name -EnableSecureBoot Off` let it boot. Apply that only to the scratch VM when this specific boot failure occurs. Windows Setup still needs its first interactive console session. Complete OOBE with a **new local account** under your control; do not depend on the operator's Microsoft account, password, recovery email or phone. Use a known password for a new VM, stored locally and never pasted into chat. The existing `wa-test` account has a blank password; that worked for SSH key authentication but **PowerShell Direct rejected it** with `The credential is invalid.` Do not assume PowerShell Direct can repair this VM after SSH is down. Record the new VM's local credentials and SSH host fingerprint securely, outside the repo.

## Prepare guest SSH once

Inside the guest's elevated PowerShell during initial setup, install OpenSSH Server if needed, configure key auth, and make `sshd` automatic **before the first reboot**:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic
Start-Service sshd
Get-Service sshd | Select-Object Status,StartType
```

The test guest's `wa-test` is an administrator, so its public key belongs in `C:\ProgramData\ssh\administrators_authorized_keys`, with inheritance removed and access for Administrators and SYSTEM only. The host private key stays on the host. This session's key is `C:\Users\Victor\AppData\Local\Temp\wa-av-test-20260923\vm_ssh`; its pinned host key is in the neighboring `known_hosts`. Create a fresh Ed25519 pair for a replacement VM, install **only its public key** in the guest, verify the server fingerprint before pinning it, and keep `StrictHostKeyChecking=yes` thereafter. The tested guest configuration was:

```powershell
$keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
Set-Content -LiteralPath $keyFile -Value '<host vm_ssh.pub contents>' -Encoding ascii
icacls.exe $keyFile /inheritance:r
icacls.exe $keyFile /grant:r '*S-1-5-32-544:(F)' '*S-1-5-18:(F)'
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
New-NetFirewallRule -Name 'WA-AV-Test-SSH' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -RemoteAddress '<host Default Switch IPv4>' -Profile Any
```

Check the Windows OpenSSH administrator-key rule if changing `sshd_config`, and recheck the firewall source address if the Default Switch changes. `sc.exe qc sshd` must show `AUTO_START`; merely starting `sshd` leaves it unavailable on the next boot if its startup type remains Manual. Verify with an actual reboot and SSH login.

## Start and use it without touching the desktop

Run `Start-VM -Name 'wa-av-test-20260923'` in elevated host PowerShell after verifying its identity. Windows may show a UAC prompt; ask the human to approve a specific prompt if required. Do not try to create permanent UAC access or disable Defender. Poll for the current guest IPv4 address and test port 22. With the current scratch VM and IP, these commands worked from the host:

```powershell
$root = 'C:\Users\Victor\AppData\Local\Temp\wa-av-test-20260923'
$ip = '172.23.132.56' # replace with current Hyper-V guest IPv4
ssh -i "$root\vm_ssh" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$root\known_hosts" "wa-test@$ip" whoami
scp -i "$root\vm_ssh" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$root\known_hosts" "$root\github-install-test.ps1" "wa-test@${ip}:C:/Users/wa-test/github-install-test.ps1"
ssh -i "$root\vm_ssh" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$root\known_hosts" "wa-test@$ip" powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:/Users/wa-test/github-install-test.ps1
```

For complex guest PowerShell, copy a `.ps1` and run `-File` as above. Inline quoting through PowerShell, `ssh.exe`, Windows `cmd.exe` and guest PowerShell broke a pipeline here (`Select-Object` was interpreted by `cmd.exe`). Use a native `C:/...` guest path, never a POSIX `/c/...` path. Do not put secrets in command arguments or in the repo. The existing scratch key and scripts are temporary files, so recreate them if missing rather than guessing a host key or weakening SSH checks.

If SSH is down, first determine whether the VM is booting, the IP changed, port 22 is firewalled, or `sshd` stopped. Try Hyper-V PowerShell Direct only if a valid guest credential is available. On this VM the blank-password credential failed. With authorization for a brief console recovery, use VMConnect once, open Windows **Services**, select `OpenSSH SSH Server`, and start it. In this session, VMConnect's **Clipboard > Type clipboard text** could type `services` into Windows Search and could select `OpenSSH SSH Server` in the Services list, but did not type into an elevated PowerShell console. The console is elevated on the host, so ordinary synthetic input may not reach it. Once SSH connects, run `ssh ... sc.exe config sshd start= auto`, verify `sc.exe qc sshd` reports `AUTO_START`, and return to SSH. Avoid further console input.

## Release and antivirus check

The public GitHub prerelease `v0.1.0-alpha.11` has `install.ps1`, `windows-service.json`, a Windows ZIP and its SHA256 file. The GitHub installer defaults to the rendezvous descriptor, which was still alpha.10 during this test. Pass the matching GitHub manifest explicitly:

```powershell
$base = 'https://github.com/Magaav/wasm-agent/releases/download/v0.1.0-alpha.11'
& ([scriptblock]::Create((Invoke-RestMethod "$base/install.ps1"))) -ReleaseManifestUri "$base/windows-service.json"
```

For an unattended VM test, add `-Name`, separate `-InstallDir` and `-NodeHome`, `-Hours 1 -AcceptAccess -NoRegisterCommand`; use explicit consent on a client's PC. The bootstrap checks HTTPS, manifest schema/availability, pinned operators, ZIP SHA256 and package content before connecting. Alpha.11 used a statically linked CRT because the original alpha.10 executable failed on a clean Windows guest with missing `VCRUNTIME140.dll` (`0xC0000135`). Do not install a VC runtime merely to mask a packaging failure.

Check `Get-MpComputerStatus` for enabled service, antivirus and real-time protection, then `Get-MpThreatDetection` after installing and running. Defender was enabled with signature `1.459.360.0`; alpha.11 installed and attached with zero detections. Its `wa.exe` is unsigned (`Get-AuthenticodeSignature` reports `NotSigned`), so this is **not** proof that SmartScreen will show no warning on a client's interactive download. Do not disable host or guest antivirus to obtain a passing result. A repeat release test should record exact manifest version, archive SHA256, guest OS, Defender signatures, enrollment/access status and any warnings.

The bootstrap starts a local server that may exit when the SSH command session ends. To keep a test server alive, create a guest Scheduled Task scoped to this test, with `New-ScheduledTaskAction` running a guest script that sets `WASM_AGENT_HOME`, changes to the guest workspace and invokes installed `wa.exe serve --port <enrollment port> --client-port <port+1> --ui <install>\ui`. Use `New-ScheduledTaskPrincipal -UserId 'wa-test' -LogonType Interactive -RunLevel Limited`, then `Register-ScheduledTask` and `Start-ScheduledTask`. Alpha.11 used task `WA-AV-Github-Serve`, port `56631`, client port `56632`; subsequent SSH probes showed `/health` OK, access `active`, `registered`, `attached`, and one `wa` process. Do not infer an ongoing relay from an installer message alone; check it after the SSH session ends.

## Finish

Revoke the guest enrollment with the installed `scripts\first-run.ps1 disconnect` under its `WASM_AGENT_HOME`, verify `wa.exe access` is inactive, stop and unregister only the task created for this test, then shut down this scratch guest over SSH (`shutdown.exe /s /t 0`). Confirm Hyper-V reports it `Off`. Preserve the VHDX for reuse. Keep the original `w11` VM and the host's Defender settings untouched. The VM disk is large; do not delete or move it via an unverified computed path. If a cleanup operation is rejected by automatic approval review, report the refusal and do not retry by another route.
