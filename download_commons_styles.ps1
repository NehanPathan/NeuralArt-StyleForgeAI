$ErrorActionPreference = 'Stop'

$styleDir = Join-Path $PSScriptRoot 'style_data'
$manifestPath = Join-Path $styleDir 'commons_sources.csv'
$apiBase = 'https://commons.wikimedia.org/w/api.php'
$headers = @{ 'User-Agent' = 'NST-DL-Project-style-data-collector/1.0 (training dataset; contact through Wikimedia Commons)' }
$targetCount = 80
$candidateLimit = 2000
$titles = [System.Collections.Generic.List[string]]::new()
$continueToken = $null

while ($titles.Count -lt $candidateLimit) {
    $uri = "$apiBase`?action=query&list=categorymembers&cmtitle=Category:Paintings&cmtype=file&cmlimit=500&format=json"
    if ($continueToken) {
        $uri += '&cmcontinue=' + [uri]::EscapeDataString($continueToken)
    }
    $page = Invoke-RestMethod -Uri $uri -Headers $headers
    foreach ($member in $page.query.categorymembers) {
        $titles.Add($member.title)
        if ($titles.Count -ge $candidateLimit) { break }
    }
    if (-not $page.continue.cmcontinue) { break }
    $continueToken = $page.continue.cmcontinue
}

New-Item -ItemType Directory -Path $styleDir -Force | Out-Null
$manifest = [System.Collections.Generic.List[object]]::new()
$downloaded = 0

for ($offset = 0; $offset -lt $titles.Count -and $downloaded -lt $targetCount; $offset += 50) {
    $end = [Math]::Min($offset + 49, $titles.Count - 1)
    $titleBatch = @($titles.GetRange($offset, $end - $offset + 1))
    $encodedTitles = [uri]::EscapeDataString(($titleBatch -join '|'))
    $uri = "$apiBase`?action=query&titles=$encodedTitles&prop=imageinfo&iiprop=url%7Cextmetadata&iiurlwidth=512&format=json"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers

    foreach ($entry in $response.query.pages.PSObject.Properties) {
        $pageInfo = $entry.Value
        if (-not $pageInfo.imageinfo -or $pageInfo.imageinfo.Count -eq 0) { continue }
        $imageInfo = $pageInfo.imageinfo[0]
        $license = [string]$imageInfo.extmetadata.LicenseShortName.value
        if ($license -notmatch '^(Public domain|CC0)(\s|$)') { continue }

        $thumbUrl = [string]$imageInfo.thumburl
        if (-not $thumbUrl) { continue }
        $extension = [IO.Path]::GetExtension(([uri]$thumbUrl).AbsolutePath).ToLowerInvariant()
        if ($extension -notin @('.jpg', '.jpeg', '.png')) { $extension = '.jpg' }

        $localName = "commons_$($pageInfo.pageid)$extension"
        $destination = Join-Path $styleDir $localName
        if (Test-Path -LiteralPath $destination) { continue }

        try {
            Invoke-WebRequest -Uri $thumbUrl -Headers $headers -OutFile $destination -UseBasicParsing
            if ((Get-Item -LiteralPath $destination).Length -lt 4096) {
                Remove-Item -LiteralPath $destination
                continue
            }
        } catch {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            continue
        }

        $manifest.Add([pscustomobject]@{
            local_file = $localName
            commons_title = $pageInfo.title
            license = $license
            license_url = [string]$imageInfo.extmetadata.LicenseUrl.value
            artist = [string]$imageInfo.extmetadata.Artist.value
            source_page = [string]$imageInfo.descriptionurl
        })
        $downloaded++
        Write-Progress -Activity 'Collecting public-domain/CC0 painting styles' -Status "$downloaded of $targetCount" -PercentComplete (($downloaded / $targetCount) * 100)
        if ($downloaded -ge $targetCount) { break }
    }
    Start-Sleep -Milliseconds 250
}

if ($manifest.Count -gt 0) {
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Append
    } else {
        $manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation
    }
}

Write-Output "Downloaded $downloaded images into $styleDir"
Write-Output "Source and license records: $manifestPath"
if ($downloaded -lt $targetCount) { exit 2 }
