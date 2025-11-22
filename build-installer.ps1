#!/usr/bin/env pwsh
# Automated Build Script (Maven Edition)
# Compatible with Windows (PowerShell 7+), Linux, and macOS

# --- [ Configuration & Setup ] ---------------------------------------

$ErrorActionPreference = "Stop"
$version = Get-Date -Format "yyyy.MM.dd.HHmm"
$appGuid = "{{399564FA-54AA-412D-8B6F-05ABD9A71945}"

# Maven app module name (usually "application")
$mavenAppModule = "application" 

# Set OS-specific Executables
if ($IsWindows) {
    $exeExt = ".exe"
    $mvnCmd = "mvn.cmd"
    $nsisCmd = "makensis.exe" 
} else {
    $exeExt = ""
    $mvnCmd = "mvn"
    $nsisCmd = "makensis"
}

# Define Paths
$rootDir   = $PSScriptRoot
$distDir   = Join-Path $rootDir "dist"
$appDest   = Join-Path $distDir "app"
$jreDest   = Join-Path $appDest "jre"
$outputDir = Join-Path $rootDir "Output"
$mavenTargetDir = Join-Path $rootDir $mavenAppModule | Join-Path -ChildPath "target"

# Get branding token from parent POM
$parentPomPath = Join-Path $rootDir "pom.xml"
[xml]$parentPom = Get-Content $parentPomPath
$brandingToken = $parentPom.project.properties.brandingToken

if (-not $brandingToken) {
    Write-Host "WARNING: Could not find brandingToken in parent POM" -ForegroundColor Yellow
    $brandingToken = "mavenplatformwordapp"
}

Write-Host "Branding Token: $brandingToken" -ForegroundColor Gray

# Check for Maven Wrapper
if (Test-Path (Join-Path $rootDir "mvnw")) {
    if ($IsWindows) { $mvnCmd = ".\mvnw.cmd" } else { $mvnCmd = "./mvnw" }
    Write-Host "Using Maven Wrapper: $mvnCmd" -ForegroundColor Gray
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "   NetBeans Platform Maven Build" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Version: $version" -ForegroundColor Yellow
Write-Host ""

# --- [ Step 1: Set Version and Build ] -------------------------------
Write-Host "[1/4] Setting version and building..." -ForegroundColor Cyan

try {
    # Update all POM versions
    Write-Host "  -> Setting version to $version..." -ForegroundColor Gray
    & $mvnCmd "versions:set" "-DnewVersion=$version" "-DgenerateBackupPoms=false" | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        throw "versions:set failed with exit code $LASTEXITCODE"
    }
    
    # Build the application
    Write-Host "  -> Building application..." -ForegroundColor Gray
    & $mvnCmd "clean" "install" "-Dmaven.test.skip=true"
    
    if ($LASTEXITCODE -ne 0) {
        throw "Maven build failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Host "ERROR: Build failed - $_" -ForegroundColor Red
    exit 1
}

Write-Host "Build successful!" -ForegroundColor Green

# --- [ Step 2: Stage Application ] -----------------------------------
Write-Host "[2/4] Staging application..." -ForegroundColor Cyan

if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }
New-Item -ItemType Directory -Path $distDir | Out-Null

# Find the built application cluster
$builtApp = Get-ChildItem -Path $mavenTargetDir -Directory | 
    Where-Object { $_.Name -notin @("classes", "generated-sources", "test-classes", "maven-archiver", "maven-status") } | 
    Select-Object -First 1

if (-not $builtApp) {
    Write-Host "ERROR: Could not locate built application in $mavenTargetDir" -ForegroundColor Red
    exit 1
}

Copy-Item -Path $builtApp.FullName -Destination $appDest -Recurse
Write-Host "  -> Staged to: $appDest" -ForegroundColor Gray

# Inject version into About dialog
Write-Host "  -> Injecting version into branding..." -ForegroundColor Gray

# Find the branded core JAR (can be in locale directory or modules directory)
$brandedCoreJar = Get-ChildItem -Path $appDest -Filter "core_${brandingToken}.jar" -Recurse | Select-Object -First 1

if ($brandedCoreJar) {
    Write-Host "  -> Found branding JAR: $($brandedCoreJar.FullName.Replace($appDest, '...'))" -ForegroundColor Gray
    $tempDir = Join-Path $env:TEMP "nbm-inject-$(Get-Random)"
    
    try {
        # Extract JAR
        Add-Type -Assembly System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($brandedCoreJar.FullName, $tempDir)
        
        # Find the branded Bundle properties file (could be with or without branding suffix)
        $possibleBundlePaths = @(
            "org\netbeans\core\startup\Bundle_${brandingToken}.properties",
            "org\netbeans\core\startup\Bundle.properties"
        )
        
        $bundleFile = $null
        foreach ($path in $possibleBundlePaths) {
            $testPath = Join-Path $tempDir $path
            if (Test-Path $testPath) {
                $bundleFile = $testPath
                break
            }
        }
        
        if ($bundleFile) {
            $content = Get-Content $bundleFile -Raw -Encoding UTF8
            
            if ($content -match 'currentVersion') {
                # Replace {0} placeholder with actual version
                $newContent = $content -replace '\{0\}', $version
                
                if ($newContent -ne $content) {
                    Set-Content -Path $bundleFile -Value $newContent -NoNewline -Encoding UTF8
                    Write-Host "  -> Updated currentVersion to: $version" -ForegroundColor Green
                    
                    # Repack JAR
                    Remove-Item $brandedCoreJar.FullName -Force
                    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $brandedCoreJar.FullName)
                } else {
                    Write-Host "  -> currentVersion has no {0} placeholder" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  -> Warning: currentVersion property not found in Bundle" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  -> Warning: Bundle.properties not found in JAR" -ForegroundColor Yellow
        }
        
    } finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force
        }
    }
} else {
    Write-Host "  -> Warning: core_${brandingToken}.jar not found" -ForegroundColor Yellow
}

# --- [ Step 3: Create Custom JRE ] -----------------------------------
Write-Host "[3/4] Creating custom JRE..." -ForegroundColor Cyan

$jlinkPath = "jlink"
if ($env:JAVA_HOME) {
    $jlinkPath = Join-Path $env:JAVA_HOME "bin" "jlink$exeExt"
}

if (-not (Get-Command $jlinkPath -ErrorAction SilentlyContinue)) {
    Write-Host "  -> jlink not found, skipping JRE creation" -ForegroundColor Yellow
} else {
    $modulesList = @(
        "java.base", "java.desktop", "java.logging", "java.prefs", 
        "java.xml", "java.instrument", "java.management", "jdk.unsupported"
    )

    try {
        & $jlinkPath --add-modules ($modulesList -join ",") --output $jreDest `
            --strip-debug --no-man-pages --no-header-files --compress=2
        
        if (Test-Path (Join-Path $jreDest "bin" "java$exeExt")) {
            Write-Host "  -> JRE created successfully" -ForegroundColor Green
        }
    } catch {
        Write-Host "  -> JRE creation failed: $_" -ForegroundColor Yellow
    }
}

# --- [ Step 4: Create NSIS Installer ] -------------------------------
Write-Host "[4/4] Creating installer..." -ForegroundColor Cyan

$nsisScript = Join-Path $rootDir "installer.nsis"

if (-not (Test-Path $nsisScript)) {
    Write-Host "ERROR: NSIS script not found at $nsisScript" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $outputDir)) { 
    New-Item -ItemType Directory -Path $outputDir | Out-Null 
}

if (-not (Get-Command $nsisCmd -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: NSIS not found. Install from https://nsis.sourceforge.io/" -ForegroundColor Red
    exit 1
}

try {
    & $nsisCmd /DAPP_VERSION=$version /DAPP_GUID=$appGuid $nsisScript
    
    if ($LASTEXITCODE -ne 0) {
        throw "NSIS compilation failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Host "ERROR: Installer creation failed - $_" -ForegroundColor Red
    exit 1
}

# --- [ Finish ] ------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Installer: $(Join-Path $outputDir "MyWordProcessorSetup-${version}.exe")" -ForegroundColor Cyan
Write-Host "Version: $version" -ForegroundColor Cyan
Write-Host ""

# Open output folder
if ($IsWindows) { 
    Start-Process "explorer.exe" $outputDir 
} elseif ($IsMacOS) { 
    Start-Process "open" $outputDir 
} elseif ($IsLinux) { 
    Start-Process "xdg-open" $outputDir 
}