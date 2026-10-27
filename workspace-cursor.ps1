#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$script:StageTimes = [ordered]@{
    "Cursor Rules" = 0.0
    "GitIgnore"    = 0.0
    "Graph"        = 0.0
    "Cluster"      = 0.0
}

$script:GraphStageLabel = "Graph Update"
$script:GraphifyExe = "graphify"
$script:MinGraphifyVersion = [version]"0.9.28"
$script:GraphifyNotices = @()

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
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $script:GraphifyExe @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    if ($exitCode -ne 0) {
        throw "$commandLine failed with exit code $exitCode"
    }
}

function Get-UvGraphifyExe {
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $uvDir = $null
        try {
            $uvDir = ((uv tool dir 2>$null) | Select-Object -First 1)
        }
        catch {
            $uvDir = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($uvDir)) {
            $exe = Join-Path $uvDir.Trim() "graphifyy\Scripts\graphify.exe"
            if (Test-Path -LiteralPath $exe) {
                return $exe
            }
        }
    }

    $shim = Join-Path $env:USERPROFILE ".local\bin\graphify.exe"
    if (Test-Path -LiteralPath $shim) {
        return $shim
    }

    return $null
}

function Get-GraphifyVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe
    )

    # graphify 0.9.58+ writes skill-stale notices to stderr. Merging 2>&1 turns
    # those into ErrorRecords; with $ErrorActionPreference Stop they abort the script.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & $Exe --version 2>&1
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    $lines = @(
        $raw | ForEach-Object { "$_" }
    )

    foreach ($line in $lines) {
        if ($line -match "^\s*warning:") {
            $notice = ($line -replace "^\s*warning:\s*", "").Trim()
            if ($notice -and ($script:GraphifyNotices -notcontains $notice)) {
                $script:GraphifyNotices += $notice
            }
            continue
        }

        # Match "graphify 0.9.58", not "skill is from graphify 0.9.15".
        if ($line.Trim() -match "(?i)^graphifyy?\s+(\d+\.\d+\.\d+)\s*$") {
            return [version]$Matches[1]
        }
    }

    $semvers = [regex]::Matches(
        (($lines | Where-Object { $_ -notmatch "^\s*warning:" }) -join "`n"),
        "\d+\.\d+\.\d+"
    )
    if ($semvers.Count -gt 0) {
        return [version]$semvers[$semvers.Count - 1].Value
    }

    return $null
}

function Test-GraphifyInstalled {
    $candidates = New-Object System.Collections.Generic.List[string]
    $uvExe = Get-UvGraphifyExe
    if ($uvExe) {
        [void]$candidates.Add($uvExe)
    }

    $pathCmd = Get-Command graphify -ErrorAction SilentlyContinue
    if ($pathCmd -and -not [string]::IsNullOrWhiteSpace($pathCmd.Source)) {
        [void]$candidates.Add($pathCmd.Source)
    }

    $bestExe = $null
    $bestVersion = $null
    foreach ($candidate in $candidates) {
        $version = Get-GraphifyVersion -Exe $candidate
        if ($null -eq $version) {
            continue
        }
        if (($null -eq $bestVersion) -or ($version -gt $bestVersion)) {
            $bestExe = $candidate
            $bestVersion = $version
        }
    }

    if ($null -eq $bestExe) {
        Write-Status -Level "ERROR" -Message "Graphify is not installed or not in PATH."
        exit 1
    }

    if ($bestVersion -lt $script:MinGraphifyVersion) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            Write-Status -Level "INFO" -Message (
                "Graphify $bestVersion cannot index Maven aggregators; upgrading via uv to $($script:MinGraphifyVersion)+"
            )
            uv tool install --upgrade graphifyy
            $uvExe = Get-UvGraphifyExe
            if ($uvExe) {
                $bestExe = $uvExe
                $bestVersion = Get-GraphifyVersion -Exe $bestExe
            }
        }

        if (($null -eq $bestVersion) -or ($bestVersion -lt $script:MinGraphifyVersion)) {
            Write-Status -Level "ERROR" -Message (
                "Need graphify >= $($script:MinGraphifyVersion) (found $bestVersion). " +
                "Install with: uv tool install --upgrade graphifyy"
            )
            exit 1
        }
    }

    $script:GraphifyExe = $bestExe
    $binDir = Split-Path -Parent $bestExe
    if ($env:PATH -notlike "*$binDir*") {
        $env:PATH = "$binDir;$env:PATH"
    }

    $pathVersion = $null
    if ($pathCmd -and -not [string]::IsNullOrWhiteSpace($pathCmd.Source)) {
        $pathVersion = Get-GraphifyVersion -Exe $pathCmd.Source
    }

    if ($pathVersion -and ($pathVersion -lt $bestVersion) -and ($pathCmd.Source -ne $bestExe)) {
        Write-Status -Level "OK" -Message "Graphify $bestVersion"
        $uvShim = Join-Path $env:USERPROFILE ".local\bin\graphify.exe"
        Write-Status -Level "INFO" -Message (
            "PATH still has graphify $pathVersion (pip). A bare 'graphify' in the terminal is that old copy, not uv $bestVersion."
        )
        Write-Status -Level "INFO" -Message (
            "Fix: python -m pip uninstall graphifyy ; uv tool update-shell. Then fully quit Cursor and reopen (new terminal tabs keep the old PATH). " +
            "Skills: & `"$uvShim`" install --platform claude"
        )
    }
    else {
        Write-Status -Level "OK" -Message "Graphify $bestVersion"
    }

    foreach ($notice in $script:GraphifyNotices) {
        Write-Status -Level "INFO" -Message $notice
    }
}

function Get-GraphNodeCount {
    $graphPath = Join-Path "graphify-out" "graph.json"
    if (-not (Test-Path -LiteralPath $graphPath)) {
        return -1
    }

    try {
        $graph = Get-Content -LiteralPath $graphPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($graph.nodes).Count
    }
    catch {
        return -1
    }
}

function Test-ExistingGraphIsStub {
    $count = Get-GraphNodeCount
    return ($count -ge 0) -and ($count -lt 10)
}

function Assert-GraphCoversJava {
    param(
        [Parameter(Mandatory = $true)]
        $Plan
    )

    $nodeCount = Get-GraphNodeCount
    $minExpected = [Math]::Min(20, $Plan.JavaFileCount)
    if (($Plan.JavaFileCount -ge 20) -and ($nodeCount -ge 0) -and ($nodeCount -lt $minExpected)) {
        throw (
            "Knowledge graph is too small ($nodeCount nodes) for $($Plan.JavaFileCount) Java files. " +
            "graphify $($script:MinGraphifyVersion)+ is required so nested .gitignore files do not hide modules."
        )
    }
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

function Set-Utf8NoBomLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object[]]$Lines
    )

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $textLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($null -eq $line) {
            [void]$textLines.Add("")
        }
        else {
            [void]$textLines.Add([string]$line)
        }
    }

    $encoding = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($fullPath, $textLines.ToArray(), $encoding)
}

function Ensure-CursorIgnore {
    # Git keeps graphify-out/ untracked. These negations reopen it for Cursor.
    # With Instant Grep on, a "!" here still may not undo a gitignored path.
    $requiredPatterns = @(
        "!graphify-out/",
        "!graphify-out/**"
    )
    $cursorIgnorePath = ".cursorignore"
    $existed = Test-Path -LiteralPath $cursorIgnorePath

    $existingLines = @()
    if ($existed) {
        $existingLines = @(Get-Content -LiteralPath $cursorIgnorePath)
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

    $missingPatterns = @()
    foreach ($pattern in $requiredPatterns) {
        if (-not $knownEntries.Contains($pattern)) {
            $missingPatterns += $pattern
        }
    }

    if (-not $existed) {
        Set-Utf8NoBomLines -Path $cursorIgnorePath -Lines @(
            "# Local. Not versioned. Reopens the knowledge graph for the Cursor agent.",
            "!graphify-out/",
            "!graphify-out/**"
        )
        Write-Status -Level "OK" -Message ".cursorignore created"
        return
    }

    if ($missingPatterns.Count -eq 0) {
        Write-Status -Level "OK" -Message ".cursorignore already includes graphify-out"
        return
    }

    $updatedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $existingLines) {
        [void]$updatedLines.Add([string]$line)
    }
    if (($updatedLines.Count -gt 0) -and ($updatedLines[$updatedLines.Count - 1].Trim().Length -gt 0)) {
        [void]$updatedLines.Add("")
    }
    foreach ($pattern in $missingPatterns) {
        [void]$updatedLines.Add($pattern)
    }

    Set-Utf8NoBomLines -Path $cursorIgnorePath -Lines $updatedLines.ToArray()
    Write-Status -Level "OK" -Message ".cursorignore updated"
}

function Ensure-GitIgnore {
    $requiredEntries = @(
        ".cursor/",
        "graphify-out/",
        ".cursorignore"
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
            $gitIgnoreLines = [System.Collections.Generic.List[string]]::new()
            foreach ($line in @($existingLines)) {
                if ($null -ne $line) {
                    [void]$gitIgnoreLines.Add([string]$line)
                }
            }
            if (($gitIgnoreLines.Count -gt 0) -and ($gitIgnoreLines[$gitIgnoreLines.Count - 1].Trim().Length -gt 0)) {
                [void]$gitIgnoreLines.Add("")
            }
            foreach ($entry in $missingEntries) {
                [void]$gitIgnoreLines.Add($entry)
            }
            Set-Utf8NoBomLines -Path $gitIgnorePath -Lines $gitIgnoreLines.ToArray()
        }
        elseif (-not (Test-Path -LiteralPath $gitIgnorePath)) {
            Set-Utf8NoBomLines -Path $gitIgnorePath -Lines $requiredEntries
        }

        Write-Status -Level "OK" -Message ".gitignore updated"
        Ensure-CursorIgnore
    } | Out-Null
}

function Get-ChildMavenJavaModules {
    $names = @()
    $dirs = Get-ChildItem -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        $modPom = Join-Path $dir.Name "pom.xml"
        $srcJava = Join-Path $dir.Name "src\main\java"
        if ((Test-Path -LiteralPath $modPom) -and (Test-Path -LiteralPath $srcJava)) {
            $names += $dir.Name
        }
    }
    $names
}

function Get-JavaFileCount {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Roots
    )

    $count = 0
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }
        $count += @(
            Get-ChildItem -LiteralPath $root -Recurse -Filter *.java -File -ErrorAction SilentlyContinue
        ).Count
    }
    return $count
}

function Get-JavaExtractPlan {
    $isMaven = Test-Path -LiteralPath "pom.xml"
    $isGradle = (Test-Path -LiteralPath "build.gradle") -or
        (Test-Path -LiteralPath "build.gradle.kts")

    if (-not ($isMaven -or $isGradle)) {
        return $null
    }

    $childModules = @()
    if ($isMaven) {
        $childModules = @(Get-ChildMavenJavaModules)
    }

    $rootSrc = $null
    foreach ($candidate in @("src/main/java", "src/main")) {
        if (Test-Path -LiteralPath $candidate) {
            $rootSrc = $candidate
            break
        }
    }

    # Aggregator (BESOP): parent POM + sibling modules with src/main/java.
    # One graph at repo root so web → ejb → jpa → utils imports resolve.
    # Do not extract per module or merge-graphs (prefixes IDs and breaks identity).
    if ($childModules.Count -gt 0) {
        $countRoots = @()
        foreach ($name in $childModules) {
            $countRoots += (Join-Path $name "src\main\java")
        }
        if ($rootSrc) {
            $countRoots += $rootSrc
        }

        $javaCount = Get-JavaFileCount -Roots $countRoots
        return [pscustomobject]@{
            Kind          = "aggregator"
            ExtractPath   = "."
            UseOutRoot    = $false
            UseNoCluster  = $true
            UseNoViz      = ($javaCount -ge 500)
            ModuleCount   = $childModules.Count
            ModuleNames   = $childModules
            JavaFileCount = $javaCount
        }
    }

    if ($rootSrc) {
        $javaDir = $rootSrc
        if (($rootSrc -eq "src/main") -and (Test-Path -LiteralPath "src/main/java")) {
            $javaDir = "src/main/java"
        }

        $javaCount = Get-JavaFileCount -Roots @($javaDir)
        return [pscustomobject]@{
            Kind          = "single-module"
            ExtractPath   = $rootSrc
            UseOutRoot    = $true
            UseNoCluster  = $false
            UseNoViz      = ($javaCount -ge 500)
            ModuleCount   = 1
            ModuleNames   = @()
            JavaFileCount = $javaCount
        }
    }

    return $null
}

function Invoke-GraphExtractAndCluster {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ExtractArguments,
        [Parameter(Mandatory = $true)]
        [string]$InfoMessage,
        [string[]]$ClusterArguments = @("cluster-only", ".")
    )

    $script:GraphStageLabel = "Graph Extract"

    Measure-Stage -StageName "Graph" -Action {
        Write-Status -Level "INFO" -Message $InfoMessage
        Invoke-Graphify -Arguments $ExtractArguments
        Write-Status -Level "OK" -Message "Knowledge graph extracted"
    } | Out-Null

    Measure-Stage -StageName "Cluster" -Action {
        Invoke-Graphify -Arguments $ClusterArguments
        Write-Status -Level "OK" -Message "Clusters updated"
    } | Out-Null
}

function Update-Graph {
    $graphOutputPath = "graphify-out"
    $graphExists = Test-Path -LiteralPath $graphOutputPath
    $plan = Get-JavaExtractPlan

    # Java: never graphify update . - scan root must match the extract command.
    if ($null -ne $plan) {
        $extractArgs = [System.Collections.Generic.List[string]]::new()
        [void]$extractArgs.Add("extract")
        [void]$extractArgs.Add($plan.ExtractPath)
        [void]$extractArgs.Add("--code-only")
        if ($plan.UseOutRoot) {
            [void]$extractArgs.Add("--out")
            [void]$extractArgs.Add(".")
        }
        if ($plan.UseNoCluster) {
            [void]$extractArgs.Add("--no-cluster")
        }
        if (($plan.JavaFileCount -ge 20) -and (Test-ExistingGraphIsStub)) {
            [void]$extractArgs.Add("--force")
            Write-Status -Level "INFO" -Message (
                "Existing graph is a stub ($(Get-GraphNodeCount) nodes); forcing full re-extract"
            )
        }

        $clusterArgs = [System.Collections.Generic.List[string]]::new()
        [void]$clusterArgs.Add("cluster-only")
        [void]$clusterArgs.Add(".")
        if ($plan.UseNoViz) {
            [void]$clusterArgs.Add("--no-viz")
            Write-Status -Level "INFO" -Message (
                "Skipping graph.html (--no-viz): $($plan.JavaFileCount) Java files would produce an unreadable HTML blob. Use GRAPH_REPORT.md or graphify query."
            )
        }

        if ($plan.Kind -eq "aggregator") {
            $moduleList = $plan.ModuleNames -join ", "
            Write-Status -Level "INFO" -Message (
                "Maven aggregator: $($plan.ModuleCount) Java modules ($moduleList), " +
                "$($plan.JavaFileCount) .java - single graph at repo root"
            )
            $kindLabel = "Java aggregator"
        }
        else {
            $kindLabel = "Java"
        }

        $message = if ($graphExists) {
            "Refreshing knowledge graph ($kindLabel)..."
        }
        else {
            "Building knowledge graph (first run, $kindLabel)..."
        }

        Invoke-GraphExtractAndCluster `
            -ExtractArguments $extractArgs.ToArray() `
            -ClusterArguments $clusterArgs.ToArray() `
            -InfoMessage $message
        Assert-GraphCoversJava -Plan $plan
        return
    }

    if (-not $graphExists) {
        Invoke-GraphExtractAndCluster -ExtractArguments @("extract", ".", "--code-only") `
            -InfoMessage "Building knowledge graph (first run)..."
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
