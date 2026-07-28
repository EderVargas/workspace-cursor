#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$script:StageTimes = [ordered]@{
    "Cursor Rules" = 0.0
    "GitIgnore"    = 0.0
    "Graph"        = 0.0
    "Cluster"      = 0.0
}

$script:GraphStageLabel = "Graph Update"

function Write-Status {
    param(
        [ValidateSet("OK", "INFO", "ERROR")]
        [string]$Level,
        [string]$Message
    )

    $color = switch ($Level) {
        "OK"    { "Green" }
        "INFO"  { "Yellow" }
        "ERROR" { "Red" }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-Banner {
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "Workspace Initializer"
    Write-Host "======================================================"
    Write-Host ""
}

function Measure-Stage {
    param(
        [string]$StageName,
        [scriptblock]$Action
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    & $Action
    $stopwatch.Stop()

    $seconds = $stopwatch.Elapsed.TotalSeconds
    $script:StageTimes[$StageName] = $seconds
    return $seconds
}

function Invoke-Graphify {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $commandLine = "graphify $($Arguments -join ' ')"
    & graphify @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "$commandLine failed with exit code $LASTEXITCODE"
    }
}

function Test-GraphifyInstalled {
    $graphify = Get-Command graphify -ErrorAction SilentlyContinue
    if (-not $graphify) {
        Write-Status -Level "ERROR" -Message "Graphify is not installed or not in PATH."
        exit 1
    }

    Write-Status -Level "OK" -Message "Graphify installed"
}

function Test-GitRepository {
    if (-not (Test-Path -LiteralPath ".git")) {
        Write-Status -Level "ERROR" -Message "Not a Git repository (.git not found)."
        exit 1
    }

    Write-Status -Level "OK" -Message "Git repository detected"
}

function Ensure-CursorRules {
    $cursorRulePath = Join-Path ".cursor" "rules\graphify.mdc"

    Measure-Stage -StageName "Cursor Rules" -Action {
        if (Test-Path -LiteralPath $cursorRulePath) {
            Write-Status -Level "OK" -Message "Cursor rules already installed"
            return
        }

        Write-Status -Level "INFO" -Message "Installing Cursor rules..."
        Invoke-Graphify -Arguments @("cursor", "install")
        Write-Status -Level "OK" -Message "Cursor rules installed"
    } | Out-Null
}

function Ensure-GitIgnore {
    $requiredEntries = @(
        ".cursor/",
        "graphify-out/"
    )

    Measure-Stage -StageName "GitIgnore" -Action {
        $gitIgnorePath = ".gitignore"
        $existingLines = @()

        if (Test-Path -LiteralPath $gitIgnorePath) {
            $existingLines = Get-Content -LiteralPath $gitIgnorePath
        }

        $knownEntries = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($line in $existingLines) {
            $trimmed = $line.Trim()
            if ($trimmed.Length -gt 0) {
                [void]$knownEntries.Add($trimmed)
            }
        }

        $missingEntries = @()
        foreach ($entry in $requiredEntries) {
            if (-not $knownEntries.Contains($entry)) {
                $missingEntries += $entry
            }
        }

        if ($missingEntries.Count -gt 0) {
            if ($existingLines.Count -eq 0) {
                Set-Content -LiteralPath $gitIgnorePath -Value $missingEntries
            }
            else {
                Add-Content -LiteralPath $gitIgnorePath -Value $missingEntries
            }
        }
        elseif (-not (Test-Path -LiteralPath $gitIgnorePath)) {
            Set-Content -LiteralPath $gitIgnorePath -Value $requiredEntries
        }

        Write-Status -Level "OK" -Message ".gitignore updated"
    } | Out-Null
}

function Update-Graph {
    $graphOutputPath = "graphify-out"
    $graphExists = Test-Path -LiteralPath $graphOutputPath

    if (-not $graphExists) {
        $script:GraphStageLabel = "Graph Extract"

        Measure-Stage -StageName "Graph" -Action {
            Write-Status -Level "INFO" -Message "Building knowledge graph (first run)..."
            Invoke-Graphify -Arguments @("extract", ".", "--code-only")
            Write-Status -Level "OK" -Message "Knowledge graph extracted"
        } | Out-Null

        Measure-Stage -StageName "Cluster" -Action {
            Invoke-Graphify -Arguments @("cluster-only", ".")
            Write-Status -Level "OK" -Message "Clusters updated"
        } | Out-Null

        return
    }

    $script:GraphStageLabel = "Graph Update"

    # graphify update clusters by default; --no-cluster is the opt-out flag.
    Measure-Stage -StageName "Graph" -Action {
        Write-Status -Level "INFO" -Message "Updating knowledge graph..."
        Invoke-Graphify -Arguments @("update", ".")
        Write-Status -Level "OK" -Message "Knowledge graph updated"
    } | Out-Null

    $script:StageTimes["Cluster"] = 0.0
    Write-Status -Level "OK" -Message "Clusters updated (included in graph update)"
}

function Format-StageTiming {
    param(
        [string]$Label,
        [double]$Seconds
    )

    return ("{0}{1,8:N2} s" -f $Label.PadRight(24, '.'), $Seconds)
}

function Show-Summary {
    $total = 0.0
    foreach ($value in $script:StageTimes.Values) {
        $total += $value
    }

    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host "Times"
    Write-Host ""
    Write-Host (Format-StageTiming -Label "Cursor Rules" -Seconds $script:StageTimes["Cursor Rules"])
    Write-Host (Format-StageTiming -Label "GitIgnore" -Seconds $script:StageTimes["GitIgnore"])
    Write-Host (Format-StageTiming -Label $script:GraphStageLabel -Seconds $script:StageTimes["Graph"])
    Write-Host (Format-StageTiming -Label "Cluster" -Seconds $script:StageTimes["Cluster"])
    Write-Host ""
    Write-Host "------------------------------------------------------"
    Write-Host ""
    Write-Host (Format-StageTiming -Label "Total" -Seconds $total)
    Write-Host ""
    Write-Host "Workspace Ready."
    Write-Host ""
}

try {
    Write-Banner
    Test-GitRepository
    Test-GraphifyInstalled
    Ensure-CursorRules
    Ensure-GitIgnore
    Update-Graph
    Show-Summary
}
catch {
    Write-Host ""
    Write-Status -Level "ERROR" -Message $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace
    }
    exit 1
}
