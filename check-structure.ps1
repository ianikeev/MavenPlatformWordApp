# Search for currentVersion in all JARs
Get-ChildItem -Path ".\dist\app" -Filter "*.jar" -Recurse | ForEach-Object {
    $jar = $_.FullName
    $tempDir = Join-Path $env:TEMP "search-$(Get-Random)"
    
    try {
        Expand-Archive -Path $jar -DestinationPath $tempDir -Force
        $found = Get-ChildItem -Path $tempDir -Filter "*.properties" -Recurse | 
            Where-Object { (Get-Content $_.FullName -Raw) -match 'currentVersion' }
        
        if ($found) {
            Write-Host "Found in: $($_.Name)" -ForegroundColor Green
            $found | ForEach-Object {
                Write-Host "  File: $($_.FullName.Replace($tempDir, ''))" -ForegroundColor Cyan
                Get-Content $_.FullName | Select-String "currentVersion"
            }
        }
    } catch {
        # Skip JARs that can't be extracted
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}