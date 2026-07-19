<#
.SYNOPSIS
    Atliso Drive Mapper - maps network drives on Intune-managed Windows devices.
    Replaces GPO drive map preferences. No Group Policy required.

.DESCRIPTION
    Edit the $DriveMappings block below - nothing else needs changing.
    - Auto-detects your AD DNS domain for FQDN share paths ({domain} token)
    - Optional per-drive AD group filtering (no LDAP queries - uses the user's token)
    - Idempotent: safe to re-run; fixes wrong mappings, skips correct ones
    - Retries mapping while the network/VPN comes up at logon
    - Logs to %LOCALAPPDATA%\Atliso\DriveMapper.log

.NOTES
    Deploy via Intune as a Platform script:
      Run using logged-on credentials : YES  (drives are per-user)
      Run in 64-bit PowerShell        : YES
      Assign to                       : user groups
    Author : Atliso (https://atliso.com) - free to use, MIT licence.
#>

# ══════════════ EDIT THIS BLOCK FOR YOUR ENVIRONMENT ══════════════
# {domain} expands to your AD DNS domain automatically (e.g. corp.contoso.com).
# GroupFilter is optional: leave out to map for everyone, or set one or more
# AD group names (comma-separated) - the drive only maps if the user is a member.

$DriveMappings = @(
    @{ Letter = "S"; Path = "\\fileserver.{domain}\shared";              Label = "Shared" }
    @{ Letter = "H"; Path = "\\fileserver.{domain}\home\$env:USERNAME";  Label = "Home" }
    @{ Letter = "F"; Path = "\\fileserver.{domain}\finance";             Label = "Finance"; GroupFilter = "Finance-Team" }
)

# Remove mapped drives that are NOT in the list above? ($true/$false)
$RemoveUnlistedDrives = $false
# ══════════════════════════════════════════════════════════════════

$LogDir  = Join-Path $env:LOCALAPPDATA "Atliso"
$LogFile = Join-Path $LogDir "DriveMapper.log"
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Add-Content -Path $LogFile
    Write-Output $Message
}

Write-Log "=== Atliso Drive Mapper started (user: $env:USERNAME) ==="

# ── Auto-detect the AD DNS domain for the {domain} token ──────────
$Domain = $env:USERDNSDOMAIN
if ([string]::IsNullOrEmpty($Domain)) {
    # Fallback for Entra-joined / off-network sessions
    try { $Domain = (Get-CimInstance Win32_ComputerSystem).Domain } catch { $Domain = $null }
}
if ([string]::IsNullOrEmpty($Domain) -or $Domain -eq "WORKGROUP") {
    Write-Log "WARNING: could not auto-detect a domain. '{domain}' paths will not resolve - use full server FQDNs in your config instead."
}
else {
    Write-Log "Detected domain: $Domain"
}

# ── Get the user's group memberships from their token (fast, no LDAP) ──
$UserGroups = @()
try {
    $UserGroups = (whoami /groups /fo csv | ConvertFrom-Csv).'Group Name' |
        ForEach-Object { ($_ -split '\\')[-1] }   # strip DOMAIN\ prefix
}
catch {
    Write-Log "WARNING: could not read group memberships - group-filtered drives will be skipped. $($_.Exception.Message)"
}

# ── Map each drive ────────────────────────────────────────────────
foreach ($Drive in $DriveMappings) {

    $Letter = $Drive.Letter.TrimEnd(':')
    $Path   = $Drive.Path
    if ($Domain) { $Path = $Path -replace '\{domain\}', $Domain }

    # Group filter: skip if the user isn't in any listed group
    if ($Drive.GroupFilter) {
        $Required = $Drive.GroupFilter -split ',' | ForEach-Object { $_.Trim() }
        $Match = $Required | Where-Object { $UserGroups -contains $_ }
        if (-not $Match) {
            Write-Log "$Letter`: skipped - user not in group(s): $($Required -join ', ')"
            continue
        }
    }

    # Already mapped correctly? Skip.
    $Existing = Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue
    if ($Existing -and $Existing.DisplayRoot -eq $Path) {
        Write-Log "$Letter`: already mapped correctly - skipping"
        continue
    }

    # ── SAFETY: verify the new target is reachable BEFORE touching anything.
    # An existing mapping is never removed in favour of a path that doesn't work.
    $Reachable = $false
    $MaxAttempts = 3
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        if (Test-Path -Path $Path -ErrorAction SilentlyContinue) { $Reachable = $true; break }
        Write-Log "$Letter`: target not reachable yet ($Path) - attempt $i"
        if ($i -lt $MaxAttempts) { Start-Sleep -Seconds (10 * $i) }
    }
    if (-not $Reachable) {
        if ($Existing) {
            Write-Log "$Letter`: target unreachable - KEEPING existing mapping -> $($Existing.DisplayRoot)"
        }
        else {
            Write-Log "$Letter`: target unreachable - skipping (check the path, permissions, and network)"
        }
        continue
    }

    # Target verified - now it's safe to replace a stale mapping
    if ($Existing) {
        Write-Log "$Letter`: removing stale mapping -> $($Existing.DisplayRoot)"
        net use "$Letter`:" /delete /y 2>$null | Out-Null
    }

    # Map with retry
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            New-PSDrive -Name $Letter -PSProvider FileSystem -Root $Path `
                -Description $Drive.Label -Persist -Scope Global -ErrorAction Stop | Out-Null

            # Set the friendly name shown in File Explorer
            try {
                (New-Object -ComObject Shell.Application).NameSpace("$Letter`:").Self.Name = $Drive.Label
            } catch { }

            Write-Log "$Letter`: mapped -> $Path (attempt $i)"
            break
        }
        catch {
            Write-Log "$Letter`: attempt $i failed - $($_.Exception.Message)"
            if ($i -lt $MaxAttempts) { Start-Sleep -Seconds (10 * $i) }
            else { Write-Log "$Letter`: GIVING UP after $MaxAttempts attempts" }
        }
    }
}

# ── Optionally remove drives not in the config ────────────────────
if ($RemoveUnlistedDrives) {
    $Wanted = $DriveMappings | ForEach-Object { $_.Letter.TrimEnd(':') }
    Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.DisplayRoot -like '\\*' -and $Wanted -notcontains $_.Name } |
        ForEach-Object {
            Write-Log "$($_.Name): not in config - removing"
            net use "$($_.Name):" /delete /y 2>$null | Out-Null
        }
}

# ── Persistence fix: make sure Windows reconnects these at logon ──
Get-ChildItem -Path HKCU:\Network -ErrorAction SilentlyContinue | ForEach-Object {
    New-ItemProperty -Path $_.PSPath -Name ConnectionType -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
}

Write-Log "=== Atliso Drive Mapper finished ==="
