[CmdletBinding()]
param(
    [string] $RootPath = 'C:\LA',

    [string] $OutputPath,

    [string] $IncludePattern = 'AM-*',

    [ValidateRange(1, 20)]
    [int] $MaxEvidencePerRelationship = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryPath,

        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & git -C $RepositoryPath @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return @($output)
}

function Get-FirstMeaningfulReadmeLine {
    param(
        [string] $RepositoryPath,
        [string[]] $Files
    )

    $readme = $Files |
        Where-Object { $_ -match '^(?i)(readme|docs[/\\]readme)(\.[^/\\]+)?$' } |
        Sort-Object Length |
        Select-Object -First 1

    if (-not $readme) {
        return ''
    }

    $fullPath = Join-Path $RepositoryPath $readme
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return ''
    }

    foreach ($line in @(Get-Content -LiteralPath $fullPath -TotalCount 80 -ErrorAction SilentlyContinue)) {
        $clean = ([string]$line) `
            -replace '<[^>]+>', ' ' `
            -replace '^\s{0,3}#{1,6}\s*', '' `
            -replace '!\[[^\]]*\]\([^)]+\)', '' `
            -replace '\[([^\]]+)\]\([^)]+\)', '$1' `
            -replace '[*_`>|]', ' '
        $clean = ($clean -replace '\s+', ' ').Trim()

        if ($clean.Length -ge 20 -and $clean -notmatch '^(build|status|license|table of contents)\b') {
            return $clean.Substring(0, [Math]::Min(280, $clean.Length))
        }
    }

    return ''
}

function Get-RepositoryRole {
    param([string] $Name)

    switch -Regex ($Name) {
        '(?i)(docs?)$' { return 'documentation' }
        '(?i)(e2e|test)' { return 'testing' }
        '(?i)(armtemplates|infra|geneva)$' { return 'infrastructure' }
        '(?i)(tools?|artifacts)$' { return 'tooling' }
        '(?i)(apispecs?)$' { return 'api-contracts' }
        '(?i)(common)$' { return 'shared-library' }
        default { return 'service-or-component' }
    }
}

function Get-Technologies {
    param([string[]] $Files)

    $technologies = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $Files) {
        $lower = $file.ToLowerInvariant()
        $extension = [IO.Path]::GetExtension($lower)

        switch ($extension) {
            '.cs' { [void]$technologies.Add('C#') }
            '.csproj' { [void]$technologies.Add('.NET') }
            '.fs' { [void]$technologies.Add('F#') }
            '.go' { [void]$technologies.Add('Go') }
            '.java' { [void]$technologies.Add('Java') }
            '.js' { [void]$technologies.Add('JavaScript') }
            '.ts' { [void]$technologies.Add('TypeScript') }
            '.tsx' { [void]$technologies.Add('TypeScript') }
            '.py' { [void]$technologies.Add('Python') }
            '.ps1' { [void]$technologies.Add('PowerShell') }
            '.bicep' { [void]$technologies.Add('Bicep') }
            '.json' {
                if ($lower -match '(arm|template|deployment)') {
                    [void]$technologies.Add('ARM')
                }
            }
            '.yml' { [void]$technologies.Add('YAML') }
            '.yaml' { [void]$technologies.Add('YAML') }
            '.proto' { [void]$technologies.Add('Protocol Buffers') }
        }

        if ($lower -match '(^|[/\\])dockerfile') {
            [void]$technologies.Add('Docker')
        }
        if ($lower -match '(^|[/\\])azure-pipelines[^/\\]*\.(yml|yaml)$') {
            [void]$technologies.Add('Azure Pipelines')
        }
        if ($lower -match '\.sln$') {
            [void]$technologies.Add('Visual Studio')
        }
    }

    return @($technologies | Sort-Object)
}

function Get-Manifests {
    param([string[]] $Files)

    return @(
        $Files |
            Where-Object {
                $_ -match '(?i)(^|[/\\])(' +
                    'azure-pipelines[^/\\]*\.(yml|yaml)|' +
                    'package\.json|go\.mod|cargo\.toml|pom\.xml|' +
                    'directory\.(build|packages)\.props|' +
                    '[^/\\]+\.(sln|csproj|fsproj|bicep)|' +
                    'dockerfile[^/\\]*|' +
                    'service(model|group)?[^/\\]*\.json' +
                    ')$'
            } |
            Sort-Object -Unique |
            Select-Object -First 120
    )
}

function Get-PathKeywords {
    param(
        [string] $RepositoryName,
        [string[]] $Files
    )

    $stopWords = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($word in @(
        'src', 'source', 'test', 'tests', 'main', 'master', 'common', 'public',
        'private', 'internal', 'client', 'server', 'service', 'services', 'project',
        'projects', 'properties', 'config', 'configuration', 'debug', 'release',
        'readme', 'docs', 'documentation', 'json', 'yaml', 'yml', 'xml', 'csproj',
        'sln', 'packages', 'package', 'scripts', 'tools', 'build', 'bin', 'obj',
        'microsoft', 'azure', 'analytics'
    )) {
        [void]$stopWords.Add($word)
    }

    $counts = @{}
    $inputs = @($RepositoryName) + @($Files | Select-Object -First 20000)
    foreach ($inputValue in $inputs) {
        foreach ($tokenMatch in [Regex]::Matches(
            [string]$inputValue,
            '[A-Za-z][A-Za-z0-9]{2,}')) {
            $token = $tokenMatch.Value.ToLowerInvariant()
            if ($stopWords.Contains($token)) {
                continue
            }

            if ($counts.ContainsKey($token)) {
                $counts[$token]++
            }
            else {
                $counts[$token] = 1
            }
        }
    }

    return @(
        $counts.GetEnumerator() |
            Sort-Object -Property @{ Expression = 'Value'; Descending = $true },
                @{ Expression = 'Name'; Descending = $false } |
            Select-Object -First 100 -ExpandProperty Name
    )
}

$resolvedRoot = [IO.Path]::GetFullPath($RootPath)
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "Repository root '$resolvedRoot' does not exist."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $resolvedRoot '.log-analytics-index\catalog.json'
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)

$repositoryDirectories = @(
    Get-ChildItem -LiteralPath $resolvedRoot -Force -Directory |
        Where-Object { $_.Name -like $IncludePattern } |
        Sort-Object Name
)

$repositories = [Collections.Generic.List[object]]::new()
foreach ($directory in $repositoryDirectories) {
    $gitRoot = Invoke-Git $directory.FullName @('rev-parse', '--show-toplevel')
    if (@($gitRoot).Count -eq 0) {
        continue
    }

    $files = @(Invoke-Git $directory.FullName @('ls-files'))
    $remote = @(Invoke-Git $directory.FullName @('remote', 'get-url', 'origin')) |
        Select-Object -First 1
    $branch = @(Invoke-Git $directory.FullName @('branch', '--show-current')) |
        Select-Object -First 1
    $commit = @(Invoke-Git $directory.FullName @('rev-parse', 'HEAD')) |
        Select-Object -First 1

    $repositories.Add([ordered]@{
        name = $directory.Name
        path = $directory.FullName
        remote = if ($remote) { [string]$remote } else { '' }
        branch = if ($branch) { [string]$branch } else { '' }
        sourceCommit = if ($commit) { [string]$commit } else { '' }
        description = Get-FirstMeaningfulReadmeLine $directory.FullName $files
        role = Get-RepositoryRole $directory.Name
        technologies = @(Get-Technologies $files)
        keywords = @(Get-PathKeywords $directory.Name $files)
        manifests = @(Get-Manifests $files)
        trackedFileCount = $files.Count
    })
}

$knownNames = @($repositories | ForEach-Object { [string]$_.name })
$namePattern = '(' + (($knownNames |
    Sort-Object Length -Descending |
    ForEach-Object { [Regex]::Escape($_) }) -join '|') + ')'
$nameLookup = @{}
foreach ($name in $knownNames) {
    $nameLookup[$name.ToLowerInvariant()] = $name
}

$relationshipMap = @{}
if ($knownNames.Count -gt 0) {
    foreach ($repository in $repositories) {
        $grepLines = & git -C $repository.path grep -I -n -i -E $namePattern -- 2>$null
        if ($LASTEXITCODE -gt 1) {
            throw "git grep failed in '$($repository.path)'."
        }

        foreach ($grepLine in @($grepLines)) {
            if ([string]$grepLine -notmatch '^(?<path>[^:]+):(?<line>\d+):(?<text>.*)$') {
                continue
            }

            $evidencePath = $Matches.path
            $lineNumber = [int]$Matches.line
            $content = $Matches.text
            $targetMatches = [Regex]::Matches(
                $content,
                $namePattern,
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)

            foreach ($targetMatch in $targetMatches) {
                $targetKey = $targetMatch.Value.ToLowerInvariant()
                if (-not $nameLookup.ContainsKey($targetKey)) {
                    continue
                }

                $targetName = $nameLookup[$targetKey]
                if ($targetName -eq $repository.name) {
                    continue
                }

                $edgeKey = "$($repository.name)`0$targetName"
                if (-not $relationshipMap.ContainsKey($edgeKey)) {
                    $relationshipMap[$edgeKey] = [ordered]@{
                        source = $repository.name
                        target = $targetName
                        type = 'reference'
                        referenceCount = 0
                        evidence = [Collections.Generic.List[object]]::new()
                    }
                }

                $edge = $relationshipMap[$edgeKey]
                $edge.referenceCount++
                if ($edge.evidence.Count -lt $MaxEvidencePerRelationship) {
                    $alreadyRecorded = @(
                        $edge.evidence |
                            Where-Object {
                                $_.path -eq $evidencePath -and
                                $_.line -eq $lineNumber
                            }
                    ).Count -gt 0

                    if (-not $alreadyRecorded) {
                        $edge.evidence.Add([ordered]@{
                            path = $evidencePath
                            line = $lineNumber
                        })
                    }
                }
            }
        }
    }
}

$relationships = @(
    $relationshipMap.Values |
        ForEach-Object {
            [ordered]@{
                source = $_.source
                target = $_.target
                type = $_.type
                referenceCount = $_.referenceCount
                evidence = @($_.evidence)
            }
        } |
        Sort-Object source, target
)

$catalog = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    rootPath = $resolvedRoot
    includePattern = $IncludePattern
    repositoryCount = $repositories.Count
    repositories = @($repositories)
    relationships = $relationships
}

$outputDirectory = Split-Path -Parent $resolvedOutput
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$temporaryPath = "$resolvedOutput.tmp"
$json = $catalog | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))

$verification = Get-Content -LiteralPath $temporaryPath -Raw | ConvertFrom-Json
if ($verification.schemaVersion -ne 1 -or
    $verification.repositoryCount -ne $repositories.Count) {
    Remove-Item -LiteralPath $temporaryPath -Force
    throw 'Generated catalog failed round-trip verification.'
}

Move-Item -LiteralPath $temporaryPath -Destination $resolvedOutput -Force

[pscustomobject]@{
    CatalogPath = $resolvedOutput
    RepositoryCount = $repositories.Count
    RelationshipCount = $relationships.Count
    GeneratedAtUtc = $catalog.generatedAtUtc
}
