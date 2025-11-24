#!/bin/bash
# Unix/Linux/macOS wrapper for Groovy build script
# Automatically detects and uses Groovy installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROOVY_SCRIPT="$SCRIPT_DIR/build-installer-optimized.groovy"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to find Groovy in common locations
find_groovy() {
    # Check if groovy is in PATH
    if command_exists groovy; then
        echo "groovy"
        return 0
    fi
    
    # Check GROOVY_HOME
    if [ -n "$GROOVY_HOME" ] && [ -x "$GROOVY_HOME/bin/groovy" ]; then
        echo "$GROOVY_HOME/bin/groovy"
        return 0
    fi
    
    # Check common installation locations
    local GROOVY_LOCATIONS=(
        "/usr/local/bin/groovy"
        "/usr/bin/groovy"
        "/opt/groovy/bin/groovy"
        "$HOME/.sdkman/candidates/groovy/current/bin/groovy"
        "$HOME/.gvm/groovy/current/bin/groovy"
        "/usr/local/opt/groovy/bin/groovy"  # Homebrew on macOS
    )
    
    for location in "${GROOVY_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            echo "$location"
            return 0
        fi
    done
    
    return 1
}

# Try to find Groovy
GROOVY_CMD=$(find_groovy)

if [ -n "$GROOVY_CMD" ]; then
    # Make the Groovy script executable if it isn't already
    chmod +x "$GROOVY_SCRIPT" 2>/dev/null || true
    
    # Execute the Groovy script with all arguments
    exec "$GROOVY_CMD" "$GROOVY_SCRIPT" "$@"
else
    # Groovy not found - try to run with Java directly
    if command_exists java; then
        echo "WARNING: Groovy not found in PATH. Attempting to run with Java..."
        echo "Please install Groovy from https://groovy.apache.org/download.html"
        echo ""
        
        # Try to find Groovy JAR in Maven repository
        GROOVY_JAR=$(find "$HOME/.m2/repository/org/apache/groovy" -name "groovy-all-*.jar" 2>/dev/null | sort -r | head -n1)
        
        if [ -n "$GROOVY_JAR" ] && [ -f "$GROOVY_JAR" ]; then
            exec java -jar "$GROOVY_JAR" "$GROOVY_SCRIPT" "$@"
        fi
    fi
    
    # If we get here, Groovy is not available
    echo "ERROR: Groovy not found!"
    echo ""
    echo "Please install Groovy from one of these sources:"
    echo "  1. Download from: https://groovy.apache.org/download.html"
    echo "  2. Install with SDKMAN: sdk install groovy"
    echo "  3. Install with Homebrew (macOS): brew install groovy"
    echo "  4. Install with package manager:"
    echo "     - Ubuntu/Debian: sudo apt-get install groovy"
    echo "     - Fedora: sudo dnf install groovy"
    echo "     - Arch Linux: sudo pacman -S groovy"
    echo ""
    echo "After installation, ensure 'groovy' is in your PATH or set GROOVY_HOME"
    exit 1
fi