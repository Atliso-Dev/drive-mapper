# Pester 5+. Drives, shares and group membership are mocked, so nothing is mapped on the test machine:
#   Invoke-Pester ./tests

BeforeAll {
  $script:Source = Get-Content (Join-Path $PSScriptRoot '..\Atliso-DriveMapper.ps1') -Raw

  # A copy of the script with its own $DriveMappings block, the way an admin edits it.
  function script:New-Copy([string]$Mappings, [bool]$RemoveUnlisted = $false) {
    $text = [regex]::Replace($script:Source, '(?s)\$DriveMappings = @\(.*?\r?\n\)', "`$DriveMappings = @(`n$Mappings`n)", 1)
    $text = $text -replace '(?m)^\$RemoveUnlistedDrives = \$(true|false)', "`$RemoveUnlistedDrives = `$$($RemoveUnlisted.ToString().ToLower())"
    $path = Join-Path $TestDrive 'mapper.ps1'
    Set-Content -Path $path -Value $text
    $path
  }

  # Stand-ins: functions named whoami and net shadow the real exes, so the mocks catch every call.
  function global:whoami { }
  function global:net { }

  function script:Invoke-Mapper([string]$Mappings, [string[]]$Groups = @(), [hashtable]$Existing = @{}, [string[]]$Reachable = @('*'), [int]$ReachableOnAttempt = 1) {
    $global:AtlisoGroups = $Groups
    $global:AtlisoExisting = $Existing
    $global:AtlisoReachable = $Reachable
    $global:AtlisoAttempt = 0
    $global:AtlisoReachableOn = $ReachableOnAttempt
    Mock whoami { '"Group Name","Type","SID","Attributes"'; foreach ($g in $global:AtlisoGroups) { "`"CONTOSO\$g`",`"Group`",`"S-1-5-21`",`"Enabled`"" } }
    Mock net { }
    Mock Start-Sleep { }
    Mock Get-PSDrive { if ($global:AtlisoExisting.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name; DisplayRoot = $global:AtlisoExisting[$Name] } } }
    Mock Test-Path {
      $global:AtlisoAttempt++
      $global:AtlisoAttempt -ge $global:AtlisoReachableOn -and [bool]($global:AtlisoReachable | Where-Object { "$Path" -like $_ })
    } -ParameterFilter { "$Path" -like '\\*' }
    Mock New-PSDrive { }
    Mock Get-ChildItem { } -ParameterFilter { "$Path" -like 'HKCU:*' }
    $out = & (New-Copy $Mappings) | Out-String
    [pscustomobject]@{ Output = $out }
  }
}

Describe 'Atliso-DriveMapper' {

  BeforeEach {
    $env:LOCALAPPDATA = Join-Path $TestDrive 'appdata'
    $env:USERDNSDOMAIN = 'corp.contoso.com'
  }

  It 'expands {domain} and maps a reachable share' {
    Invoke-Mapper '@{ Letter = "S"; Path = "\\fileserver.{domain}\shared"; Label = "Shared" }' | Out-Null
    Should -Invoke New-PSDrive -Times 1 -Exactly -ParameterFilter { $Name -eq 'S' -and $Root -eq '\\fileserver.corp.contoso.com\shared' -and $Persist }
  }

  It 'skips a drive already mapped to the right path' {
    $r = Invoke-Mapper '@{ Letter = "S"; Path = "\\fs.{domain}\shared"; Label = "Shared" }' -Existing @{ S = '\\fs.corp.contoso.com\shared' }
    $r.Output | Should -Match 'already mapped correctly'
    Should -Invoke New-PSDrive -Times 0
  }

  It 'group filter: maps only for members' {
    $map = '@{ Letter = "F"; Path = "\\fs.{domain}\finance"; Label = "Finance"; GroupFilter = "Finance-Team, Directors" }'
    (Invoke-Mapper $map -Groups @('Everyone')).Output | Should -Match 'skipped - user not in group'
    Should -Invoke New-PSDrive -Times 0
    Invoke-Mapper $map -Groups @('Directors') | Out-Null
    Should -Invoke New-PSDrive -Times 1 -Exactly
  }

  It 'never removes a working mapping for an unreachable target' {
    $r = Invoke-Mapper '@{ Letter = "S"; Path = "\\new-fs.{domain}\shared"; Label = "Shared" }' -Existing @{ S = '\\old-fs\shared' } -Reachable @()
    $r.Output | Should -Match 'KEEPING existing mapping'
    Should -Invoke net -Times 0
    Should -Invoke New-PSDrive -Times 0
  }

  It 'replaces a stale mapping once the new target is reachable' {
    Invoke-Mapper '@{ Letter = "S"; Path = "\\new-fs.{domain}\shared"; Label = "Shared" }' -Existing @{ S = '\\old-fs\shared' } | Out-Null
    Should -Invoke net -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'use' -and $args[1] -eq 'S:' -and $args -contains '/delete' }
    Should -Invoke New-PSDrive -Times 1 -Exactly
  }

  It 'retries a share that is slow to come up (VPN at logon), then maps it' {
    $r = Invoke-Mapper '@{ Letter = "S"; Path = "\\fs.{domain}\shared"; Label = "Shared" }' -ReachableOnAttempt 2
    $r.Output | Should -Match 'target not reachable yet .* attempt 1'
    Should -Invoke Start-Sleep -Times 1 -Exactly
    Should -Invoke New-PSDrive -Times 1 -Exactly
  }

  It 'gives up after three attempts without mapping' {
    $r = Invoke-Mapper '@{ Letter = "S"; Path = "\\fs.{domain}\shared"; Label = "Shared" }' -Reachable @()
    $r.Output | Should -Match 'target unreachable - skipping'
    Should -Invoke Test-Path -Times 3 -Exactly -ParameterFilter { "$Path" -like '\\*' }
    Should -Invoke New-PSDrive -Times 0
  }
}
