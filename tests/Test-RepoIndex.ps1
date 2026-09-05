[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'log-analytics-repo-map-' + [Guid]::NewGuid().ToString('N'))
$skillRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $skillRoot 'scripts\Build-RepoIndex.ps1'
$findScript = Join-Path $skillRoot 'scripts\Find-RelevantRepos.ps1'

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $alpha = Join-Path $testRoot 'AM-Alpha'
    $beta = Join-Path $testRoot 'AM-Beta'
    [IO.Directory]::CreateDirectory($alpha) | Out-Null
    [IO.Directory]::CreateDirectory($beta) | Out-Null

    foreach ($repository in @($alpha, $beta)) {
        & git -C $repository init --quiet
        & git -C $repository config user.email 'repo-map-test@example.invalid'
        & git -C $repository config user.name 'Repo Map Test'
    }

    [IO.File]::WriteAllText(
        (Join-Path $alpha 'README.md'),
        "# Alpha`nAlpha schedules work through AM-Beta.`n",
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $alpha 'QueryScheduler.cs'),
        "internal class QueryScheduler { }`n",
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $beta 'README.md'),
        "# Beta`nBeta executes scheduled query work.`n",
        [Text.UTF8Encoding]::new($false))

    foreach ($repository in @($alpha, $beta)) {
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'Test fixture'
    }

    $catalogPath = Join-Path $testRoot '.index\catalog.json'
    & $buildScript -RootPath $testRoot -OutputPath $catalogPath | Out-Null
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

    if ($catalog.repositoryCount -ne 2) {
        throw "Expected 2 repositories, found $($catalog.repositoryCount)."
    }

    $edge = @($catalog.relationships | Where-Object {
        $_.source -eq 'AM-Alpha' -and $_.target -eq 'AM-Beta'
    })
    if ($edge.Count -ne 1 -or $edge[0].evidence.Count -lt 1) {
        throw 'Expected an evidence-backed AM-Alpha -> AM-Beta relationship.'
    }

    $results = @(
        & $findScript `
            -CatalogPath $catalogPath `
            -Question 'Where is QueryScheduler implemented?' `
            -Top 2
    )
    if ($results.Count -lt 1 -or $results[0].Name -ne 'AM-Alpha') {
        throw 'Expected AM-Alpha to rank first for a QueryScheduler question.'
    }

    [pscustomobject]@{
        Passed = $true
        RepositoryCount = $catalog.repositoryCount
        RelationshipCount = $catalog.relationships.Count
        TopResult = $results[0].Name
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
