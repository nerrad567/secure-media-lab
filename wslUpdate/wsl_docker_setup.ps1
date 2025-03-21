# Toggle to also output logs to the console (set to $true to enable)
$LogToConsole = $false

# Set log level (1 = Errors only, 2 = Errors+Warnings, 3 = All messages)
$LogLevel = 2  # Default to all messages

# Define the log file with a descriptive name
$logFile = "C:\Scripts\wsl_docker_setup.log"

# Ensure log directory exists
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Global variable to track if Ubuntu-24.04 was last seen online
$script:WasUbuntuOnline = $false

function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "CRITICAL")]
        [string]$Level = "INFO"
    )
    try {
        $shouldLog = switch ($Level) {
            "CRITICAL" { $true }  # Always log critical errors
            "ERROR"    { $LogLevel -ge 1 }
            "WARNING"  { $LogLevel -ge 2 }
            "INFO"     { $LogLevel -ge 3 }
        }

        if ($shouldLog) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $fullMessage = "[$timestamp] [$Level] $Message"
            $encoding = New-Object System.Text.UTF8Encoding($false)  # UTF8 without BOM
            [System.IO.File]::AppendAllText($logFile, "$fullMessage`n", $encoding)
            if ($LogToConsole) {
                Write-Output $fullMessage
            }
        }
    }
    catch {
        Write-Error "Failed to write to log file: $_"
    }
}

# Function: Get and clean WSL distributions
function Get-WSLDistributions {
    try {
        $line = wsl --list --verbose
        if ($LASTEXITCODE -ne 0) {
            throw "WSL list command failed with exit code: $LASTEXITCODE"
        }
        
        $lineList = [System.Collections.ArrayList]$line
        $i = 0
        while ($i -lt $lineList.Count) {
            $currentElement = $lineList[$i]
            if (-not $currentElement -or $currentElement.Trim() -eq "" -or 
                $currentElement.Trim() -eq "NAME            STATE           VERSION") {
                $lineList.RemoveAt($i)
            } else {
                $i++
            }
        }

        for ($i = 0; $i -lt $lineList.Count; $i++) {
            $element = $lineList[$i] -replace '\s+', '' -replace '^\0+', '' -replace '^\*', '' -replace '[\d\0]+$', ''
            $lineList[$i] = $element
        }
        
        return $lineList
    }
    catch {
        Write-Log -Message "Failed to get WSL distributions: $_" -Level "ERROR"
        return @()
    }
}

# Function: Check and add port mapping if needed
function Set-PortMapping {
    try {
        $existingMappings = netsh interface portproxy show all
        if ($existingMappings -match "192.168.0.51\s+8096") {
            Write-Log -Message "Port mapping for 192.168.0.51:8096 already exists" -Level "INFO"
            return
        }
        
        $result = netsh interface portproxy add v4tov4 listenport=8096 listenaddress=192.168.0.51 `
            connectport=8096 connectaddress=127.0.0.1 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log -Message "Port mapping set successfully" -Level "INFO"
        } else {
            throw "Port mapping failed with exit code: $LASTEXITCODE. Result: $result"
        }
    }
    catch {
        Write-Log -Message "Error setting port mapping: $_" -Level "ERROR"
    }
}

# Function: Mount a drive if not already mounted
function Mount-DriveIfMissing {
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$DriveInfo
    )
    try {
        $mountedDrives = (wsl -e ls /mnt/wsl 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {  # 2 is acceptable (empty dir)
            throw "Failed to check mounted drives: Exit code $LASTEXITCODE"
        }

        if ($mountedDrives -notmatch $DriveInfo.Name) {
            Write-Log -Message "Mounting drive $($DriveInfo.Name)" -Level "INFO"
            $mountOutput = wsl --mount $DriveInfo.Drive --partition $DriveInfo.Partition --type ext4 --name $DriveInfo.Name 2>&1
            if ($LASTEXITCODE -ne 0) {
                if ($mountOutput -match "WSL_E_DISK_ALREADY_MOUNTED") {
                    Write-Log -Message "Drive $($DriveInfo.Name) already mounted in WSL2, forcing dismount" -Level "WARNING"
                    Dismount-Drive -DriveInfo $DriveInfo
                    # Retry mounting after forced dismount
                    Write-Log -Message "Retrying mount for $($DriveInfo.Name) after forced dismount" -Level "INFO"
                    wsl --mount $DriveInfo.Drive --partition $DriveInfo.Partition --type ext4 --name $DriveInfo.Name 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Mount retry failed with exit code: $LASTEXITCODE. Error: $mountOutput"
                    }
                    Write-Log -Message "Successfully mounted $($DriveInfo.Name) after forced dismount" -Level "INFO"
                } else {
                    throw "Mount failed with exit code: $LASTEXITCODE. Error: $mountOutput"
                }
            } else {
                Write-Log -Message "Successfully mounted $($DriveInfo.Name)" -Level "INFO"
            }
        } else {
            Write-Log -Message "Drive $($DriveInfo.Name) already mounted" -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Failed to mount $($DriveInfo.Name): $_" -Level "ERROR"
    }
}

# Function: Dismount a drive with retries and sanity check
function Dismount-Drive {
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$DriveInfo,
        [int]$MaxRetries = 5,
        [int]$DelaySeconds = 2
    )
    try {
        # Sanity check: Try mounting to see if it’s already mounted (will fail with WSL_E_DISK_ALREADY_MOUNTED if it is)
        $mountCheck = wsl --mount $DriveInfo.Drive --partition $DriveInfo.Partition --type ext4 --name $DriveInfo.Name 2>&1
        $isMounted = $LASTEXITCODE -ne 0 -and $mountCheck -match "WSL_E_DISK_ALREADY_MOUNTED"

        if ($isMounted) {
            Write-Log -Message "Sanity check confirmed $($DriveInfo.Name) is mounted, proceeding with dismount" -Level "INFO"
        } else {
            $mountedDrives = (wsl -e ls /mnt/wsl 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $mountedDrives -match $DriveInfo.Name) {
                Write-Log -Message "Fallback check confirmed $($DriveInfo.Name) is mounted, proceeding with dismount" -Level "INFO"
                $isMounted = $true
            }
        }

        if ($isMounted) {
            Write-Log -Message "Dismounting drive $($DriveInfo.Name)" -Level "INFO"
            $attempt = 1
            while ($attempt -le $MaxRetries) {
                wsl --unmount $DriveInfo.Drive 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    # Verify dismount worked
                    $mountCheck = wsl --mount $DriveInfo.Drive --partition $DriveInfo.Partition --type ext4 --name $DriveInfo.Name 2>&1
                    if ($LASTEXITCODE -ne 0 -and $mountCheck -match "WSL_E_DISK_ALREADY_MOUNTED") {
                        Write-Log -Message "Dismount attempt $attempt for $($DriveInfo.Name) appeared successful but drive still mounted" -Level "WARNING"
                    } else {
                        Write-Log -Message "Successfully dismounted $($DriveInfo.Name) on attempt $attempt" -Level "INFO"
                        return
                    }
                } else {
                    Write-Log -Message "Dismount attempt $attempt for $($DriveInfo.Name) failed with exit code: $LASTEXITCODE" -Level "WARNING"
                }
                Start-Sleep -Seconds $DelaySeconds
                $attempt++
            }
            Write-Log -Message "Failed to dismount $($DriveInfo.Name) after $MaxRetries attempts" -Level "CRITICAL"
            exit 1  # Exit script with failure code
        } else {
            Write-Log -Message "Drive $($DriveInfo.Name) not mounted, skipping dismount" -Level "INFO"
        }
    }
    catch {
        Write-Log -Message "Failed to dismount $($DriveInfo.Name): $_" -Level "CRITICAL"
        exit 1  # Exit script with failure code
    }
}

# Function: Mount all ext4 drives if they are missing
function Mount-MissingDrives {
    $drives = @(
        @{Drive="\\.\PHYSICALDRIVE0"; Partition=1; Name="MediaSSD"},
        @{Drive="\\.\PHYSICALDRIVE1"; Partition=1; Name="StagingSSD"}
    )
    
    Write-Log -Message "Checking drive mounts" -Level "INFO"
    foreach ($drive in $drives) {
        Mount-DriveIfMissing -DriveInfo $drive
    }
}

# Function: Dismount all drives
function Dismount-AllDrives {
    $drives = @(
        @{Drive="\\.\PHYSICALDRIVE0"; Partition=1; Name="MediaSSD"},
        @{Drive="\\.\PHYSICALDRIVE1"; Partition=1; Name="StagingSSD"}
    )
    
    Write-Log -Message "Dismounting all drives" -Level "INFO"
    foreach ($drive in $drives) {
        Dismount-Drive -DriveInfo $drive
    }
}

# Function: Launch WSL Ubuntu-24.04
function Start-WSLInstance {
    try {
        $distros = Get-WSLDistributions
        if ($distros -contains "Ubuntu-24.04Running") {
            Write-Log -Message "Ubuntu-24.04 already running" -Level "INFO"
            return
        }

        Write-Log -Message "Launching Ubuntu-24.04" -Level "INFO"
        Start-Process -FilePath "wsl.exe" -ArgumentList "-d Ubuntu-24.04 bash -c 'tail -f /dev/null'" `
            -RedirectStandardOutput "NUL" -WindowStyle Hidden -ErrorAction Stop
        
        Start-Sleep -Seconds 10
        $distros = Get-WSLDistributions
        if ($distros -contains "Ubuntu-24.04Running") {
            Write-Log -Message "Successfully launched Ubuntu-24.04" -Level "INFO"
        } else {
            throw "Failed to verify Ubuntu-24.04 launch"
        }
    }
    catch {
        Write-Log -Message "Error launching WSL instance: $_" -Level "ERROR"
    }
}

# Function: Initialize WSL setup
function Initialize-WSLSetup {
    Write-Log -Message "Initializing WSL setup" -Level "INFO"
    try {
        $distros = Get-WSLDistributions
        if ($distros -contains "Ubuntu-24.04Running") {
            Write-Log -Message "Ubuntu-24.04 is already running, ensuring drives are mounted" -Level "INFO"
            Mount-MissingDrives
            $script:WasUbuntuOnline = $true
        } else {
            Write-Log -Message "Ubuntu-24.04 not running, performing full initialization" -Level "INFO"
            Dismount-AllDrives  # Dismount first
            Mount-MissingDrives # Then mount
            Start-WSLInstance   # Then start the OS
            $script:WasUbuntuOnline = $true  # Assume it’s online after successful start
        }
    }
    catch {
        Write-Log -Message "Error during initialization: $_" -Level "CRITICAL"
        exit 1  # Exit script with failure code
    }
}

# Initial Setup
Write-Log -Message "Starting WSL Docker setup script" -Level "INFO"
Set-PortMapping
Initialize-WSLSetup

# Main Monitoring Loop
Write-Log -Message "Starting continuous monitoring" -Level "INFO"
while ($true) {
    try {
        $distros = Get-WSLDistributions
        $isUbuntuOnline = $distros -contains "Ubuntu-24.04Running"

        if ($isUbuntuOnline) {
            Mount-MissingDrives
            if (-not $script:WasUbuntuOnline) {
                Write-Log -Message "Ubuntu-24.04 is back online" -Level "INFO"
            }
            $script:WasUbuntuOnline = $true
        } else {
            if ($script:WasUbuntuOnline) {
                Write-Log -Message "Ubuntu-24.04 went offline, dismounting and remounting drives" -Level "WARNING"
                Dismount-AllDrives
                Mount-MissingDrives
                $script:WasUbuntuOnline = $false
            } else {
                Write-Log -Message "Ubuntu-24.04 still offline, no action taken" -Level "INFO"
            }
        }
        Start-Sleep -Seconds 10
    }
    catch {
        Write-Log -Message "Error in monitoring loop: $_" -Level "ERROR"
        Start-Sleep -Seconds 10  # Prevent tight error loop
    }
}