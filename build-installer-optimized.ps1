#!/usr/bin/env pwsh
# Optimized Automated Build Script (Maven Edition)
# Compatible with Windows (PowerShell 7+), Linux, and macOS
# Enhanced with parallel processing, incremental builds, and performance monitoring

# Build optimization flags (must be first)
param(
    [switch]$FastBuild,      # Skip compression optimization for faster testing
    [switch]$SkipTests,      # Skip Maven tests (default: true)
    [switch]$Offline,        # Use Maven offline mode after first build
    [switch]$IncrementalBuild, # Enable incremental build detection
    [switch]$SkipJRE,        # Skip JRE creation if already exists
    [switch]$Verbose,        # Show detailed timing information
    [switch]$Help,           # Show help message
    [switch]$h               # Show help message (short form)
)

# --- [ Help Message ] ------------------------------------------------

if ($Help -or $h) {
    Write-Host ""
    Write-Host "NetBeans Platform Maven Build Script - Optimized Edition" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "  .\build-installer-optimized.ps1 [OPTIONS]"
    Write-Host ""
    Write-Host "OPTIONS:" -ForegroundColor Yellow
    Write-Host "  -FastBuild          Use fast compression for quicker builds (larger installer)"
    Write-Host "                      Recommended for development/testing iterations"
    Write-Host ""
    Write-Host "  -IncrementalBuild   Skip Maven build if source files haven't changed"
    Write-Host "                      Saves significant time on repeated builds"
    Write-Host ""
    Write-Host "  -SkipJRE            Reuse existing JRE if Java version hasn't changed"
    Write-Host "                      Saves 30-60 seconds on subsequent builds"
    Write-Host ""
    Write-Host "  -Offline            Use Maven offline mode (skip dependency updates)"
    Write-Host "                      Only use after first successful build"
    Write-Host ""
    Write-Host "  -SkipTests          Skip Maven test execution (default: enabled)"
    Write-Host "                      Tests are skipped by default for faster builds"
    Write-Host ""
    Write-Host "  -Verbose            Show detailed timing breakdown for each build phase"
    Write-Host "                      Useful for identifying performance bottlenecks"
    Write-Host ""
    Write-Host "  -Help, -h           Show this help message"
    Write-Host ""
    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "  # Full production build (maximum compression)"
    Write-Host "  .\build-installer-optimized.ps1"
    Write-Host ""
    Write-Host "  # Fast development build with all optimizations"
    Write-Host "  .\build-installer-optimized.ps1 -FastBuild -IncrementalBuild -SkipJRE -Offline"
    Write-Host ""
    Write-Host "  # Production build with detailed timing"
    Write-Host "  .\build-installer-optimized.ps1 -Verbose"
    Write-Host ""
    Write-Host "  # Quick test build (fastest possible)"
    Write-Host "  .\build-installer-optimized.ps1 -FastBuild -IncrementalBuild -SkipJRE"
    Write-Host ""
    Write-Host "PERFORMANCE TIPS:" -ForegroundColor Yellow
    Write-Host "  • First build: Run without flags to populate caches"
    Write-Host "  • Development: Use -FastBuild -IncrementalBuild -SkipJRE for 80%+ faster builds"
    Write-Host "  • Release: Run clean without flags for maximum compression"
    Write-Host "  • After dependency changes: Remove -Offline flag"
    Write-Host ""
    Write-Host "OUTPUT:" -ForegroundColor Yellow
    Write-Host "  Installer will be created in: .\Output\"
    Write-Host "  Build artifacts cached in: .\.build-cache\"
    Write-Host ""
    exit 0
}

# --- [ Configuration & Setup ] ---------------------------------------

$ErrorActionPreference = "Stop"
$version = Get-Date -Format "yyyy.MM.dd.HHmm"
$appGuid = "{{399564FA-54AA-412D-8B6F-05ABD9A71945}}"

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
$cacheDir = Join-Path $rootDir ".build-cache"

# Performance tracking
$script:timings = @{}

function Start-TimedSection {
    param([string]$Name)
    $script:timings[$Name] = [System.Diagnostics.Stopwatch]::StartNew()
}

function Stop-TimedSection {
    param([string]$Name)
    if ($script:timings[$Name]) {
        $script:timings[$Name].Stop()
        $elapsed = $script:timings[$Name].Elapsed.TotalSeconds
        if ($Verbose) {
            Write-Host "  -> $Name completed in $([math]::Round($elapsed, 2))s" -ForegroundColor Gray
        }
        return $elapsed
    }
}

# Enhanced JVM arguments injection function with correct -J prefixes
function Add-JvmArgumentsToConfig {
    param(
        [string]$AppDest,
        [string]$BrandingToken
    )
    
    Start-TimedSection "JVM-Config"
    
    # Find the configuration file
    $possibleConfFiles = @(
        "etc/${BrandingToken}.conf",
        "etc/netbeans.conf"
    )
    
    $confFile = $null
    foreach ($path in $possibleConfFiles) {
        $testPath = Join-Path $AppDest $path
        if (Test-Path $testPath) {
            $confFile = $testPath
            break
        }
    }
    
    # Required JVM arguments for Java 17+ compatibility (with -J prefix for NetBeans Platform)
    $requiredArgs = @(
        "-J--add-opens=java.base/java.net=ALL-UNNAMED",
        "-J--enable-native-access=ALL-UNNAMED", 
        "-J--add-opens=java.base/java.lang=ALL-UNNAMED",
        "-J--add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED",
        "-J--add-opens=java.base/java.security=ALL-UNNAMED",
        "-J--add-opens=java.base/java.util=ALL-UNNAMED",
        "-J--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",
        "-J--add-opens=java.desktop/sun.awt=ALL-UNNAMED"
    )
    
    if ($confFile) {
        Write-Host "  -> Updating configuration: $($confFile.Replace($AppDest, '...'))" -ForegroundColor Gray
        $content = Get-Content $confFile -Raw
        
        # Pattern to match default_options line (this is the main one used)
        $defaultOptionsPattern = 'default_options="([^"]*)"'
        
        if ($content -match $defaultOptionsPattern) {
            $existingOptions = $matches[1]
            
            # Add missing arguments to default_options
            $newOptions = $existingOptions
            foreach ($arg in $requiredArgs) {
                if ($newOptions -notmatch [regex]::Escape($arg)) {
                    $newOptions = "$newOptions $arg"
                }
            }
            
            # Only update if changes were made
            if ($newOptions -ne $existingOptions) {
                $newContent = $content -replace $defaultOptionsPattern, "default_options=`"$newOptions`""
                Set-Content -Path $confFile -Value $newContent -NoNewline -Encoding UTF8
                Write-Host "  -> Added JVM arguments to default_options" -ForegroundColor Green
            } else {
                Write-Host "  -> All required JVM arguments already present" -ForegroundColor Green
            }
        } else {
            # Add new default_options line if it doesn't exist
            $newOptionsLine = "default_options=`"$($requiredArgs -join ' ')`""
            $newContent = $content.Trim() + "`n`n$newOptionsLine`n"
            Set-Content -Path $confFile -Value $newContent -NoNewline -Encoding UTF8
            Write-Host "  -> Created default_options with JVM arguments" -ForegroundColor Green
        }
        
        # Also update netbeans_default_options for backward compatibility
        $content = Get-Content $confFile -Raw
        $netbeansOptionsPattern = 'netbeans_default_options="([^"]*)"'
        if ($content -match $netbeansOptionsPattern) {
            $existingNetbeansOptions = $matches[1]
            $newNetbeansOptions = $existingNetbeansOptions
            foreach ($arg in $requiredArgs) {
                if ($newNetbeansOptions -notmatch [regex]::Escape($arg)) {
                    $newNetbeansOptions = "$newNetbeansOptions $arg"
                }
            }
            
            if ($newNetbeansOptions -ne $existingNetbeansOptions) {
                $newContent = $content -replace $netbeansOptionsPattern, "netbeans_default_options=`"$newNetbeansOptions`""
                Set-Content -Path $confFile -Value $newContent -NoNewline -Encoding UTF8
                Write-Host "  -> Also updated netbeans_default_options" -ForegroundColor Green
            }
        } else {
            # Add netbeans_default_options if it doesn't exist
            $netbeansOptionsLine = "netbeans_default_options=`"$($requiredArgs -join ' ')`""
            $newContent = (Get-Content $confFile -Raw).Trim() + "`n$netbeansOptionsLine`n"
            Set-Content -Path $confFile -Value $newContent -NoNewline -Encoding UTF8
        }
        
    } else {
        # Create new configuration file if it doesn't exist
        $confDir = Join-Path $AppDest "etc"
        $newConfFile = Join-Path $confDir "${BrandingToken}.conf"
        
        if (-not (Test-Path $confDir)) {
            New-Item -ItemType Directory -Path $confDir | Out-Null
        }
        
        $confContent = @"
# Configuration file for ${BrandingToken}
# Generated automatically during build process
default_options="$($requiredArgs -join ' ')"
netbeans_default_options="$($requiredArgs -join ' ')"
"@
        
        Set-Content -Path $newConfFile -Value $confContent -Encoding UTF8
        Write-Host "  -> Created configuration file with JVM arguments" -ForegroundColor Green
    }
    
    Stop-TimedSection "JVM-Config"
}

# Incremental build detection
function Test-SourceChanged {
    $cacheFile = Join-Path $cacheDir "last-build.txt"
    
    if (-not (Test-Path $cacheFile)) {
        return $true
    }
    
    $lastBuildTime = [DateTime]::Parse((Get-Content $cacheFile))
    
    $changedFiles = Get-ChildItem -Path $rootDir -Recurse -Include "*.java","*.xml","*.properties" -File |
        Where-Object { $_.LastWriteTime -gt $lastBuildTime } |
        Measure-Object
    
    return $changedFiles.Count -gt 0
}

function Save-BuildTimestamp {
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir | Out-Null
    }
    $cacheFile = Join-Path $cacheDir "last-build.txt"
    Get-Date | Out-File $cacheFile -Encoding UTF8
}

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

# Configure Maven options for performance
$mavenOpts = @("-Dmaven.test.skip=true")
if ($Offline) {
    $mavenOpts += "-o"
    Write-Host "Maven offline mode enabled" -ForegroundColor Gray
}
# Use parallel builds (1 thread per CPU core)
$mavenOpts += "-T", "1C"

Write-Host "========================================" -ForegroundColor Green
Write-Host "   NetBeans Platform Maven Build" -ForegroundColor Green
Write-Host "   OPTIMIZED EDITION" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Green
Write-Host "Version: $version" -ForegroundColor Yellow
if ($FastBuild) { Write-Host "Mode: FAST BUILD (development)" -ForegroundColor Yellow }
Write-Host ""

$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# --- [ Step 1: Set Version and Build ] -------------------------------
Write-Host "[1/4] Setting version and building..." -ForegroundColor Cyan
Start-TimedSection "Maven-Build"

# Check for incremental build
$shouldBuild = $true
if ($IncrementalBuild -and -not (Test-SourceChanged)) {
    Write-Host "  -> No source changes detected since last build" -ForegroundColor Yellow
    if (Test-Path $mavenTargetDir) {
        Write-Host "  -> Skipping Maven build (using cached artifacts)" -ForegroundColor Yellow
        $shouldBuild = $false
    } else {
        Write-Host "  -> Target directory not found, forcing rebuild" -ForegroundColor Yellow
    }
}

if ($shouldBuild) {
    try {
        # Update all POM versions
        Write-Host "  -> Setting version to $version..." -ForegroundColor Gray
        & $mvnCmd "versions:set" "-DnewVersion=$version" "-DgenerateBackupPoms=false" | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "versions:set failed with exit code $LASTEXITCODE"
        }
        
        # Build the application with optimizations
        Write-Host "  -> Building application (parallel mode)..." -ForegroundColor Gray
        $buildArgs = @("clean", "install") + $mavenOpts
        & $mvnCmd $buildArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "Maven build failed with exit code $LASTEXITCODE"
        }
        
        Save-BuildTimestamp
        
    } catch {
        Write-Host "ERROR: Build failed - $_" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "Build successful!" -ForegroundColor Green
} else {
    Write-Host "Skipped Maven build (incremental)" -ForegroundColor Green
}

Stop-TimedSection "Maven-Build"

# --- [ Step 2: Stage Application ] -----------------------------------
Write-Host "[2/4] Staging application..." -ForegroundColor Cyan
Start-TimedSection "Staging"

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
Start-TimedSection "Version-Injection"

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

Stop-TimedSection "Version-Injection"

Write-Host "  -> Injecting JVM arguments into configuration..." -ForegroundColor Gray
Add-JvmArgumentsToConfig -AppDest $appDest -BrandingToken $brandingToken

Stop-TimedSection "Staging"

# --- [ Step 3: Create Custom JRE ] -----------------------------------
Write-Host "[3/4] Creating custom JRE..." -ForegroundColor Cyan
Start-TimedSection "JRE-Creation"

$jlinkPath = "jlink"
if ($env:JAVA_HOME) {
    $jlinkPath = Join-Path $env:JAVA_HOME "bin" "jlink$exeExt"
}

$jreVersionFile = Join-Path $cacheDir "jre-version.txt"
$currentJavaVersion = ""

if (Get-Command java -ErrorAction SilentlyContinue) {
    $currentJavaVersion = (java -version 2>&1 | Select-Object -First 1) -replace '"', ''
}

$jreUpToDate = $false
if ($SkipJRE -and (Test-Path $jreVersionFile) -and (Test-Path $jreDest)) {
    $cachedVersion = Get-Content $jreVersionFile -ErrorAction SilentlyContinue
    if ($cachedVersion -eq $currentJavaVersion) {
        Write-Host "  -> JRE up to date (version: $currentJavaVersion), skipping creation" -ForegroundColor Yellow
        $jreUpToDate = $true
    }
}

if (-not $jreUpToDate) {
    if (-not (Get-Command $jlinkPath -ErrorAction SilentlyContinue)) {
        Write-Host "  -> jlink not found, skipping JRE creation" -ForegroundColor Yellow
    } else {
        $modulesList = @(
            "java.base", "java.desktop", "java.logging", "java.prefs", 
            "java.xml", "java.instrument", "java.management", "jdk.unsupported"
        )

        try {
            Write-Host "  -> Creating custom JRE with jlink..." -ForegroundColor Gray
            & $jlinkPath --add-modules ($modulesList -join ",") --output $jreDest `
                --strip-debug --no-man-pages --no-header-files --compress=2
            
            if (Test-Path (Join-Path $jreDest "bin" "java$exeExt")) {
                Write-Host "  -> JRE created successfully" -ForegroundColor Green
                
                # Cache JRE version
                if (-not (Test-Path $cacheDir)) {
                    New-Item -ItemType Directory -Path $cacheDir | Out-Null
                }
                $currentJavaVersion | Out-File $jreVersionFile -Encoding UTF8
            }
        } catch {
            Write-Host "  -> JRE creation failed: $_" -ForegroundColor Yellow
        }
    }
}

Stop-TimedSection "JRE-Creation"

# --- [ Step 4: Create NSIS Installer ] -------------------------------
Write-Host "[4/4] Creating installer..." -ForegroundColor Cyan
Start-TimedSection "NSIS-Compilation"

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

# Pre-calculate application size for NSIS
Write-Host "  -> Calculating installation size..." -ForegroundColor Gray
$appSizeKB = [math]::Round(((Get-ChildItem -Path $appDest -Recurse -File | 
    Measure-Object -Property Length -Sum).Sum / 1KB))
Write-Host "  -> Calculated size: $appSizeKB KB" -ForegroundColor Gray

# Build NSIS command with optimizations
$nsisFlags = @(
    "/DAPP_VERSION=$version",
    "/DAPP_GUID=$appGuid",
    "/DPRECALC_SIZE=$appSizeKB"
)

if ($FastBuild) {
    $nsisFlags += "/DFASTBUILD"
    Write-Host "  -> Using FASTBUILD mode (larger installer, faster compilation)" -ForegroundColor Yellow
}

try {
    Write-Host "  -> Compiling NSIS installer..." -ForegroundColor Gray
    & $nsisCmd $nsisFlags $nsisScript
    
    if ($LASTEXITCODE -ne 0) {
        throw "NSIS compilation failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Host "ERROR: Installer creation failed - $_" -ForegroundColor Red
    exit 1
}

Stop-TimedSection "NSIS-Compilation"

# --- [ Finish ] ------------------------------------------------------
$totalStopwatch.Stop()

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Installer: $(Join-Path $outputDir "My Word Processor Setup-${version}.exe")" -ForegroundColor Cyan
Write-Host "Version: $version" -ForegroundColor Cyan
Write-Host "Total Time: $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 2))s" -ForegroundColor Cyan
Write-Host ""

# Show timing breakdown if verbose
if ($Verbose -and $script:timings.Count -gt 0) {
    Write-Host "Timing Breakdown:" -ForegroundColor Yellow
    foreach ($timing in $script:timings.GetEnumerator() | Sort-Object Value) {
        $name = $timing.Key
        $seconds = [math]::Round($timing.Value.Elapsed.TotalSeconds, 2)
        Write-Host "  $name : ${seconds}s" -ForegroundColor Gray
    }
    Write-Host ""
}

# Build summary
Write-Host "Build Optimizations Used:" -ForegroundColor Yellow
if ($IncrementalBuild) { Write-Host "  ✓ Incremental build detection" -ForegroundColor Green }
if ($Offline) { Write-Host "  ✓ Maven offline mode" -ForegroundColor Green }
if ($SkipJRE -and $jreUpToDate) { Write-Host "  ✓ JRE caching" -ForegroundColor Green }
if ($FastBuild) { Write-Host "  ✓ Fast build mode" -ForegroundColor Green }
Write-Host "  ✓ Parallel Maven builds (1 thread per CPU)" -ForegroundColor Green
Write-Host "  ✓ Pre-calculated installer size" -ForegroundColor Green
Write-Host ""

# Open output folder
if ($IsWindows) { 
    Start-Process "explorer.exe" $outputDir 
} elseif ($IsMacOS) { 
    Start-Process "open" $outputDir 
} elseif ($IsLinux) { 
    Start-Process "xdg-open" $outputDir 
}