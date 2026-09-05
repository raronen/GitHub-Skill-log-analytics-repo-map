[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $CatalogPath,

    [Parameter(Mandatory)]
    [string] $Question,

    [ValidateRange(1, 50)]
    [int] $Top = 8,

    [ValidateRange(0, 1000)]
    [int] $MinScore = 1,

    [switch] $AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Tokens {
    param([string] $Text)

    $stopWords = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($word in @(
        'about', 'after', 'also', 'and', 'analytics', 'are', 'because', 'could',
        'define', 'defines', 'does', 'from', 'have', 'how', 'implemented',
        'implements', 'into', 'is', 'log', 'relate', 'related', 'that', 'the',
        'their', 'then', 'there', 'these', 'this', 'through', 'to', 'what',
        'when', 'where', 'which', 'with', 'would', 'repository', 'repositories',
        'repo', 'repos'
    )) {
        [void]$stopWords.Add($word)
    }

    return @(
        [Regex]::Matches($Text.ToLowerInvariant(), '[a-z0-9][a-z0-9._-]{1,}') |
            ForEach-Object { $_.Value.Trim('-', '_', '.') } |
            Where-Object { $_.Length -ge 2 -and -not $stopWords.Contains($_) } |
            Sort-Object -Unique
    )
}

function Get-MatchForms {
    param([string] $Token)

    $forms = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    [void]$forms.Add($Token)

    if ($Token.Length -ge 7 -and $Token.EndsWith('ing')) {
        [void]$forms.Add($Token.Substring(0, $Token.Length - 3))
    }
    if ($Token.Length -ge 6 -and $Token.EndsWith('ed')) {
        [void]$forms.Add($Token.Substring(0, $Token.Length - 2))
    }
    if ($Token.Length -ge 6 -and $Token.EndsWith('ers')) {
        [void]$forms.Add($Token.Substring(0, $Token.Length - 3))
    }
    elseif ($Token.Length -ge 5 -and $Token.EndsWith('er')) {
        [void]$forms.Add($Token.Substring(0, $Token.Length - 2))
    }

    return @($forms)
}

function Add-Match {
    param(
        [hashtable] $ReasonMap,
        [string] $Reason,
        [int] $Weight,
        [ref] $Score
    )

    if (-not $ReasonMap.ContainsKey($Reason)) {
        $ReasonMap[$Reason] = $Weight
        $Score.Value += $Weight
    }
}

$resolvedCatalog = [IO.Path]::GetFullPath($CatalogPath)
if (-not (Test-Path -LiteralPath $resolvedCatalog -PathType Leaf)) {
    throw "Catalog '$resolvedCatalog' does not exist."
}
if ([string]::IsNullOrWhiteSpace($Question)) {
    throw 'Question must not be empty.'
}

$catalog = Get-Content -LiteralPath $resolvedCatalog -Raw | ConvertFrom-Json
if ($catalog.schemaVersion -ne 1) {
    throw "Unsupported catalog schema version '$($catalog.schemaVersion)'."
}

$tokens = @(Get-Tokens $Question)
$questionLower = $Question.ToLowerInvariant()
$scored = [Collections.Generic.List[object]]::new()
$scoreByName = @{}

foreach ($repository in @($catalog.repositories)) {
    $score = 0
    $scoreReference = [ref]$score
    $reasons = @{}
    $nameLower = ([string]$repository.name).ToLowerInvariant()
    $descriptionLower = ([string]$repository.description).ToLowerInvariant()
    $roleLower = ([string]$repository.role).ToLowerInvariant()
    $technologies = @($repository.technologies | ForEach-Object {
        ([string]$_).ToLowerInvariant()
    })
    $keywords = @($repository.keywords | ForEach-Object {
        ([string]$_).ToLowerInvariant()
    })
    $manifestsLower = (@($repository.manifests) -join ' ').ToLowerInvariant()

    if ($questionLower.Contains($nameLower)) {
        Add-Match $reasons "exact name: $($repository.name)" 30 $scoreReference
    }

    foreach ($token in $tokens) {
        $forms = @(Get-MatchForms $token)
        if (@($forms | Where-Object { $nameLower.Contains($_) }).Count -gt 0) {
            Add-Match $reasons "name: $token" 10 $scoreReference
        }
        if (@($forms | Where-Object { $roleLower.Contains($_) }).Count -gt 0) {
            Add-Match $reasons "role: $token" 7 $scoreReference
        }
        if ($technologies -contains $token) {
            Add-Match $reasons "technology: $token" 6 $scoreReference
        }
        if (@(
            $keywords |
                Where-Object {
                    $keyword = $_
                    @($forms | Where-Object {
                        $keyword.StartsWith($_) -or $_.StartsWith($keyword)
                    }).Count -gt 0
                }
        ).Count -gt 0) {
            Add-Match $reasons "keyword: $token" 5 $scoreReference
        }
        if (@($forms | Where-Object {
            $descriptionLower.Contains($_)
        }).Count -gt 0) {
            Add-Match $reasons "description: $token" 3 $scoreReference
        }
        if (@($forms | Where-Object {
            $manifestsLower.Contains($_)
        }).Count -gt 0) {
            Add-Match $reasons "manifest: $token" 2 $scoreReference
        }
    }

    $entry = [pscustomobject]@{
        name = [string]$repository.name
        score = $score
        role = [string]$repository.role
        reasons = @($reasons.Keys | Sort-Object)
        path = [string]$repository.path
        sourceCommit = [string]$repository.sourceCommit
        relatedVia = [Collections.Generic.List[string]]::new()
    }
    $scored.Add($entry)
    $scoreByName[$entry.name] = $entry
}

$initialScores = @{}
foreach ($entry in $scored) {
    $initialScores[$entry.name] = $entry.score
}

foreach ($relationship in @($catalog.relationships)) {
    $source = [string]$relationship.source
    $target = [string]$relationship.target

    if ($scoreByName.ContainsKey($source) -and
        $scoreByName.ContainsKey($target)) {
        $sourceEntry = $scoreByName[$source]
        $targetEntry = $scoreByName[$target]

        if ($initialScores[$source] -gt 0 -and $initialScores[$target] -eq 0) {
            $targetEntry.score += 2
            $targetEntry.relatedVia.Add("$source -> $target")
        }
        if ($initialScores[$target] -gt 0 -and $initialScores[$source] -eq 0) {
            $sourceEntry.score += 2
            $sourceEntry.relatedVia.Add("$source -> $target")
        }
    }
}

$results = @(
    $scored |
        Where-Object { $_.score -ge $MinScore } |
        Sort-Object -Property @{ Expression = { $_.score }; Descending = $true },
            @{ Expression = { $_.name }; Descending = $false } |
        Select-Object -First $Top |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.name
                Score = $_.score
                Role = $_.role
                Reasons = ($_.reasons -join ', ')
                RelatedVia = ($_.relatedVia -join ', ')
                Path = $_.path
                SourceCommit = $_.sourceCommit
            }
        }
)

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
}
else {
    $results
}
