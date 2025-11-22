# Find the branding JAR in the staged app
$brandingJar = Get-ChildItem -Path ".\dist\app" -Filter "*branding*.jar" -Recurse
$brandingJar.FullName

# Check the last modified time - it should be recent if we modified it
$brandingJar.LastWriteTime

# Create temp directory and extract
$tempDir = ".\temp-check"
Expand-Archive -Path $brandingJar.FullName -DestinationPath $tempDir -Force

# Find and display the Bundle.properties
Get-ChildItem -Path $tempDir -Filter "Bundle.properties" -Recurse | 
    Where-Object { $_.FullName -like "*startup*" } | 
    ForEach-Object { 
        Write-Host "File: $($_.FullName)" -ForegroundColor Cyan
        Get-Content $_.FullName | Select-String "currentVersion"
    }

# Cleanup
Remove-Item $tempDir -Recurse -Force
