@echo off
setlocal enabledelayedexpansion

REM Windows wrapper for Groovy build script
REM Automatically detects and uses Groovy installation

set SCRIPT_DIR=%~dp0
set GROOVY_SCRIPT=%SCRIPT_DIR%build-installer-optimized.groovy

REM Check if groovy is in PATH
where groovy >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    groovy "%GROOVY_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

REM Check for GROOVY_HOME environment variable
if defined GROOVY_HOME (
    if exist "%GROOVY_HOME%\bin\groovy.bat" (
        "%GROOVY_HOME%\bin\groovy.bat" "%GROOVY_SCRIPT%" %*
        exit /b %ERRORLEVEL%
    )
    if exist "%GROOVY_HOME%\bin\groovy.cmd" (
        "%GROOVY_HOME%\bin\groovy.cmd" "%GROOVY_SCRIPT%" %*
        exit /b %ERRORLEVEL%
    )
)

REM Check common installation locations
set GROOVY_LOCATIONS=^
    "C:\Program Files\Groovy\bin\groovy.bat"^
    "C:\Program Files (x86)\Groovy\bin\groovy.bat"^
    "C:\Groovy\bin\groovy.bat"^
    "%USERPROFILE%\.sdkman\candidates\groovy\current\bin\groovy.bat"

for %%L in (%GROOVY_LOCATIONS%) do (
    if exist %%L (
        %%L "%GROOVY_SCRIPT%" %*
        exit /b %ERRORLEVEL%
    )
)

REM If Groovy not found, try to use Java directly with Groovy JAR
if defined JAVA_HOME (
    set JAVA_CMD=%JAVA_HOME%\bin\java.exe
) else (
    set JAVA_CMD=java.exe
)

where !JAVA_CMD! >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    REM Check for Groovy JARs in common Maven locations
    if exist "%USERPROFILE%\.m2\repository\org\apache\groovy" (
        echo WARNING: Groovy not found in PATH. Attempting to run with Java...
        echo Please install Groovy from https://groovy.apache.org/download.html
        echo Or use: sdk install groovy (if using SDKMAN)
        echo.
        
        REM Try to find the latest Groovy JAR
        for /f "delims=" %%i in ('dir /b /s "%USERPROFILE%\.m2\repository\org\apache\groovy\groovy-all-*.jar" 2^>nul ^| sort /r') do (
            set GROOVY_JAR=%%i
            goto :found_jar
        )
    )
)

:not_found
echo ERROR: Groovy not found!
echo.
echo Please install Groovy from one of these sources:
echo   1. Download from: https://groovy.apache.org/download.html
echo   2. Install with SDKMAN: sdk install groovy
echo   3. Install with Chocolatey: choco install groovy
echo   4. Install with Scoop: scoop install groovy
echo.
echo After installation, ensure 'groovy' is in your PATH or set GROOVY_HOME
exit /b 1

:found_jar
!JAVA_CMD! -jar "!GROOVY_JAR!" "%GROOVY_SCRIPT%" %*
exit /b %ERRORLEVEL%