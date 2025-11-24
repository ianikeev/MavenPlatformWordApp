#!/usr/bin/env groovy
/**
 * Optimized Automated Build Script (Maven Edition) - Groovy 5
 * Compatible with Windows, Linux, and macOS
 * Enhanced with parallel processing, incremental builds, and performance monitoring
 */

import groovy.xml.XmlSlurper
import groovy.cli.commons.CliBuilder
import groovy.ant.AntBuilder
import java.nio.file.*
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.zip.*

// --- [ Command Line Parsing with CliBuilder ] ------------------------

def cli = new CliBuilder(
    usage: 'groovy build-installer-optimized.groovy [options]',
    header: '\nNetBeans Platform Maven Build Script - Optimized Edition\n',
    footer: '\nFor more information, visit your project documentation.\n'
)

cli.with {
    h(longOpt: 'help', 'Show this help message')
    f(longOpt: 'fastbuild', 'Use fast compression for quicker builds (larger installer)')
    t(longOpt: 'skiptests', 'Skip Maven test execution (default: enabled)')
    o(longOpt: 'offline', 'Use Maven offline mode (skip dependency updates)')
    i(longOpt: 'incrementalbuild', 'Skip Maven build if source files haven\'t changed')
    j(longOpt: 'skipjre', 'Reuse existing JRE if Java version hasn\'t changed')
    v(longOpt: 'verbose', 'Show detailed timing breakdown for each build phase')
}

def options = cli.parse(args)

if (!options) {
    System.exit(1)
}

// --- [ Configuration and Global Variables ] --------------------------

// Build configuration from parsed options
def config = [
    fastBuild: options.f,
    skipTests: true,
    offline: options.o,
    incrementalBuild: options.i,
    skipJRE: options.j,
    verbose: options.v
]

def ant = new AntBuilder()
def timings = [:]
def isWindows = System.getProperty('os.name').toLowerCase().contains('windows')

// Colorize helper
def colorize = { String text, String color ->
    def colors = [
        red: '\033[31m',
        green: '\033[32m',
        yellow: '\033[33m',
        cyan: '\033[36m',
        gray: '\033[37m',
        reset: '\033[0m'
    ]
    if (System.getenv('TERM') && System.getenv('TERM') != 'dumb' && !isWindows) {
        return "${colors[color]}${text}${colors.reset}"
    }
    return text
}

// --- [ Help Message ] ------------------------------------------------

if (options.h) {
    cli.usage()
    println """
${colorize('EXAMPLES:', 'yellow')}
  # Full production build (maximum compression)
  ./build-installer.sh

  # Fast development build with all optimizations
  ./build-installer.sh -f -i -j -o

  # Production build with detailed timing
  ./build-installer.sh -v

  # Quick test build (fastest possible)
  ./build-installer.sh --fastbuild --incrementalbuild --skipjre

${colorize('PERFORMANCE TIPS:', 'yellow')}
  • First build: Run without flags to populate caches
  • Development: Use -f -i -j for 80%+ faster builds
  • Release: Run clean without flags for maximum compression
  • After dependency changes: Remove -o flag

${colorize('OUTPUT:', 'yellow')}
  Installer will be created in: ./Output/
  Build artifacts cached in: ./.build-cache/
"""
    System.exit(0)
}

// --- [ Utility Functions ] -------------------------------------------

def startTimedSection = { String name ->
    timings[name] = System.currentTimeMillis()
}

def stopTimedSection = { String name ->
    if (timings.containsKey(name)) {
        def elapsed = (System.currentTimeMillis() - timings[name]) / 1000.0
        if (config.verbose) {
            println colorize("  -> ${name} completed in ${String.format('%.2f', elapsed)}s", 'gray')
        }
        return elapsed
    }
}

def executeCommand = { String command, File workDir = null ->
    if (config.verbose) {
        println colorize("  -> Executing: ${command}", 'gray')
    }
    
    def outputBuffer = new ByteArrayOutputStream()
    def errorBuffer = new ByteArrayOutputStream()
    
    def exitCode = 0
    try {
        ant.exec(
            executable: isWindows ? 'cmd' : 'sh',
            dir: workDir,
            failonerror: false,
            outputproperty: "cmdOutput_${System.currentTimeMillis()}",
            errorproperty: "cmdError_${System.currentTimeMillis()}",
            resultproperty: "cmdResult_${System.currentTimeMillis()}"
        ) {
            if (isWindows) {
                arg(value: '/c')
                arg(line: command)
            } else {
                arg(value: '-c')
                arg(value: command)
            }
        }
        
        // Get the actual result using the timestamped property names
        def timestamp = ant.project.properties.findAll { it.key.startsWith('cmdResult_') }.max { it.key }?.key
        exitCode = (ant.project.properties[timestamp] ?: '0') as Integer
        
        def outputKey = timestamp?.replace('cmdResult_', 'cmdOutput_')
        def errorKey = timestamp?.replace('cmdResult_', 'cmdError_')
        
        def output = ant.project.properties[outputKey] ?: ''
        def error = ant.project.properties[errorKey] ?: ''
        
        // Always show output in verbose mode or if there's an error
        if (config.verbose || exitCode != 0) {
            if (output) println output
            if (error) println error
        }
        
        if (exitCode != 0) {
            throw new RuntimeException("Command failed with exit code ${exitCode}: ${command}\nOutput: ${output}\nError: ${error}")
        }
        
        return [output: output, error: error, exitCode: exitCode]
        
    } catch (Exception e) {
        println colorize("ERROR executing command: ${command}", 'red')
        println colorize("Exit code: ${exitCode}", 'red')
        throw e
    }
}

// --- [ Configuration & Setup ] ---------------------------------------

def version = LocalDateTime.now().format(DateTimeFormatter.ofPattern('yyyy.MM.dd.HHmm'))
def appGuid = '{{399564FA-54AA-412D-8B6F-05ABD9A71945}}'
def mavenAppModule = 'application'

// Set OS-specific executables
def exeExt = isWindows ? '.exe' : ''
def mvnCmd = isWindows ? 'mvn.cmd' : 'mvn'
def nsisCmd = isWindows ? 'makensis.exe' : 'makensis'

// Define paths
def rootDir = new File(getClass().protectionDomain.codeSource.location.toURI()).parentFile
def distDir = new File(rootDir, 'dist')
def appDest = new File(distDir, 'app')
def jreDest = new File(appDest, 'jre')
def outputDir = new File(rootDir, 'Output')
def mavenTargetDir = new File(rootDir, "${mavenAppModule}/target")
def cacheDir = new File(rootDir, '.build-cache')

// --- [ Incremental Build Detection ] ---------------------------------

def testSourceChanged = {
    def cacheFile = new File(cacheDir, 'last-build.txt')
    
    if (!cacheFile.exists()) {
        return true
    }
    
    def lastBuildTime = Instant.parse(cacheFile.text.trim())
    
    def changedCount = 0
    ant.fileScanner {
        fileset(dir: rootDir) {
            include(name: '**/*.java')
            include(name: '**/*.xml')
            include(name: '**/*.properties')
        }
    }.each { file ->
        def lastModified = Files.getLastModifiedTime(file.toPath()).toInstant()
        if (lastModified.isAfter(lastBuildTime)) {
            changedCount++
        }
    }
    
    return changedCount > 0
}

def saveBuildTimestamp = {
    ant.mkdir(dir: cacheDir)
    new File(cacheDir, 'last-build.txt').text = Instant.now().toString()
}

// --- [ JVM Arguments Configuration ] ---------------------------------

def addJvmArgumentsToConfig = { dest, token ->
    startTimedSection('JVM-Config')
    
    def possibleConfFiles = [
        new File(dest, "etc/${token}.conf"),
        new File(dest, 'etc/netbeans.conf')
    ]
    
    def confFile = possibleConfFiles.find { it.exists() }
    
    def requiredArgs = [
        '-J--add-opens=java.base/java.net=ALL-UNNAMED',
        '-J--enable-native-access=ALL-UNNAMED',
        '-J--add-opens=java.base/java.lang=ALL-UNNAMED',
        '-J--add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED',
        '-J--add-opens=java.base/java.security=ALL-UNNAMED',
        '-J--add-opens=java.base/java.util=ALL-UNNAMED',
        '-J--add-opens=java.base/sun.nio.ch=ALL-UNNAMED',
        '-J--add-opens=java.desktop/sun.awt=ALL-UNNAMED'
    ]
    
    if (confFile) {
        println colorize("  -> Updating configuration: ${confFile.name}", 'gray')
        def content = confFile.text
        
        // Update default_options
        def defaultOptionsPattern = ~/default_options="([^"]*)"/
        def matcher = content =~ defaultOptionsPattern
        
        if (matcher.find()) {
            def existingOptions = matcher.group(1)
            def newOptions = existingOptions
            
            requiredArgs.each { arg ->
                if (!newOptions.contains(arg)) {
                    newOptions = "${newOptions} ${arg}".trim()
                }
            }
            
            if (newOptions != existingOptions) {
                content = content.replaceFirst(defaultOptionsPattern.pattern(), "default_options=\"${newOptions}\"")
                confFile.text = content
                println colorize('  -> Added JVM arguments to default_options', 'green')
            } else {
                println colorize('  -> All required JVM arguments already present', 'green')
            }
        } else {
            def newOptionsLine = "default_options=\"${requiredArgs.join(' ')}\""
            content = content.trim() + "\n\n${newOptionsLine}\n"
            confFile.text = content
            println colorize('  -> Created default_options with JVM arguments', 'green')
        }
        
        // Also update netbeans_default_options
        content = confFile.text
        def netbeansOptionsPattern = ~/netbeans_default_options="([^"]*)"/
        matcher = content =~ netbeansOptionsPattern
        
        if (matcher.find()) {
            def existingNetbeansOptions = matcher.group(1)
            def newNetbeansOptions = existingNetbeansOptions
            
            requiredArgs.each { arg ->
                if (!newNetbeansOptions.contains(arg)) {
                    newNetbeansOptions = "${newNetbeansOptions} ${arg}".trim()
                }
            }
            
            if (newNetbeansOptions != existingNetbeansOptions) {
                content = content.replaceFirst(netbeansOptionsPattern.pattern(), "netbeans_default_options=\"${newNetbeansOptions}\"")
                confFile.text = content
                println colorize('  -> Also updated netbeans_default_options', 'green')
            }
        }
    } else {
        // Create new configuration file
        def confDir = new File(dest, 'etc')
        ant.mkdir(dir: confDir)
        def newConfFile = new File(confDir, "${token}.conf")
        
        def confContent = """# Configuration file for ${token}
# Generated automatically during build process
default_options="${requiredArgs.join(' ')}"
netbeans_default_options="${requiredArgs.join(' ')}"
"""
        
        newConfFile.text = confContent
        println colorize('  -> Created configuration file with JVM arguments', 'green')
    }
    
    stopTimedSection('JVM-Config')
}

// --- [ Main Build Process ] ------------------------------------------

def totalStartTime = System.currentTimeMillis()

// Get branding token from parent POM
def parentPomPath = new File(rootDir, 'pom.xml')
def parentPom = new XmlSlurper().parse(parentPomPath)
def brandingToken = parentPom.properties.brandingToken.text()

if (!brandingToken) {
    println colorize('WARNING: Could not find brandingToken in parent POM', 'yellow')
    brandingToken = 'mavenplatformwordapp'
}

println colorize("Branding Token: ${brandingToken}", 'gray')

// Check for Maven Wrapper
def mvnWrapper = new File(rootDir, isWindows ? 'mvnw.cmd' : 'mvnw')
if (mvnWrapper.exists()) {
    mvnCmd = mvnWrapper.absolutePath
    println colorize("Using Maven Wrapper: ${mvnCmd}", 'gray')
}

// Configure Maven options
def mavenOpts = ['-Dmaven.test.skip=true']
if (config.offline) {
    mavenOpts << '-o'
    println colorize('Maven offline mode enabled', 'gray')
}
mavenOpts += ['-T', '1C'] // Parallel builds

println colorize('========================================', 'green')
println colorize('   NetBeans Platform Maven Build', 'green')
println colorize('   OPTIMIZED EDITION', 'yellow')
println colorize('========================================', 'green')
println colorize("Version: ${version}", 'yellow')
if (config.fastBuild) {
    println colorize('Mode: FAST BUILD (development)', 'yellow')
}
println ''

// --- [ Step 1: Set Version and Build ] -------------------------------
println colorize('[1/4] Setting version and building...', 'cyan')
startTimedSection('Maven-Build')

def shouldBuild = true
if (config.incrementalBuild && !testSourceChanged()) {
    println colorize('  -> No source changes detected since last build', 'yellow')
    if (mavenTargetDir.exists()) {
        println colorize('  -> Skipping Maven build (using cached artifacts)', 'yellow')
        shouldBuild = false
    } else {
        println colorize('  -> Target directory not found, forcing rebuild', 'yellow')
    }
}

if (shouldBuild) {
    try {
        // Update all POM versions
        println colorize("  -> Setting version to ${version}...", 'gray')
        
        ant.exec(
            executable: mvnCmd,
            dir: rootDir,
            failonerror: true
        ) {
            arg(value: 'versions:set')
            arg(value: "-DnewVersion=${version}")
            arg(value: '-DgenerateBackupPoms=false')
        }
        
        // Build the application
        println colorize('  -> Building application (parallel mode)...', 'gray')
        
        ant.exec(
            executable: mvnCmd,
            dir: rootDir,
            failonerror: true
        ) {
            arg(value: 'clean')
            arg(value: 'install')
            mavenOpts.each { arg(value: it) }
        }
        
        saveBuildTimestamp()
        
    } catch (Exception e) {
        println colorize("ERROR: Build failed - ${e.message}", 'red')
        System.exit(1)
    }
    
    println colorize('Build successful!', 'green')
} else {
    println colorize('Skipped Maven build (incremental)', 'green')
}

stopTimedSection('Maven-Build')

// --- [ Step 2: Stage Application ] -----------------------------------
println colorize('[2/4] Staging application...', 'cyan')
startTimedSection('Staging')

// Clean and create dist directory
ant.delete(dir: distDir, quiet: true)
ant.mkdir(dir: distDir)

// Find the built application cluster
def builtApp = mavenTargetDir.listFiles()
    ?.findAll { it.isDirectory() && !(it.name in ['classes', 'generated-sources', 'test-classes', 'maven-archiver', 'maven-status']) }
    ?.first()

if (!builtApp) {
    println colorize("ERROR: Could not locate built application in ${mavenTargetDir}", 'red')
    System.exit(1)
}

// Copy application using Ant
ant.copy(todir: appDest) {
    fileset(dir: builtApp)
}
println colorize("  -> Staged to: ${appDest}", 'gray')

// Inject version into About dialog
println colorize('  -> Injecting version into branding...', 'gray')
startTimedSection('Version-Injection')

def brandedCoreJar = null
ant.fileScanner {
    fileset(dir: appDest) {
        include(name: "**/core_${brandingToken}.jar")
    }
}.each { file ->
    if (!brandedCoreJar) brandedCoreJar = file
}

if (brandedCoreJar) {
    println colorize("  -> Found branding JAR: ${brandedCoreJar.name}", 'gray')
    def tempDir = Files.createTempDirectory('nbm-inject').toFile()
    
    try {
        // Extract JAR using Ant
        ant.unzip(src: brandedCoreJar, dest: tempDir)
        
        // Find and update Bundle.properties
        def possibleBundlePaths = [
            "org/netbeans/core/startup/Bundle_${brandingToken}.properties",
            'org/netbeans/core/startup/Bundle.properties'
        ]
        
        def bundleFile = possibleBundlePaths.collect { new File(tempDir, it) }.find { it.exists() }
        
        if (bundleFile) {
            def content = bundleFile.text
            
            if (content.contains('currentVersion')) {
                def newContent = content.replace('{0}', version)
                
                if (newContent != content) {
                    bundleFile.text = newContent
                    println colorize("  -> Updated currentVersion to: ${version}", 'green')
                    
                    // Repack JAR using Ant
                    ant.delete(file: brandedCoreJar)
                    ant.zip(destfile: brandedCoreJar, basedir: tempDir)
                } else {
                    println colorize('  -> currentVersion has no {0} placeholder', 'yellow')
                }
            } else {
                println colorize('  -> Warning: currentVersion property not found in Bundle', 'yellow')
            }
        } else {
            println colorize('  -> Warning: Bundle.properties not found in JAR', 'yellow')
        }
        
    } finally {
        ant.delete(dir: tempDir, quiet: true)
    }
} else {
    println colorize("  -> Warning: core_${brandingToken}.jar not found", 'yellow')
}

stopTimedSection('Version-Injection')

println colorize('  -> Injecting JVM arguments into configuration...', 'gray')
addJvmArgumentsToConfig(appDest, brandingToken)

stopTimedSection('Staging')

// --- [ Step 3: Create Custom JRE ] -----------------------------------
println colorize('[3/4] Creating custom JRE...', 'cyan')
startTimedSection('JRE-Creation')

def jlinkPath = 'jlink'
def javaHome = System.getenv('JAVA_HOME')
if (javaHome) {
    jlinkPath = new File(javaHome, "bin/jlink${exeExt}").absolutePath
}

def jreVersionFile = new File(cacheDir, 'jre-version.txt')
def currentJavaVersion = ''

try {
    def versionProp = "javaVersion_${System.currentTimeMillis()}"
    def errorProp = "javaError_${System.currentTimeMillis()}"
    
    ant.exec(
        executable: 'java',
        failonerror: false,
        outputproperty: versionProp,
        errorproperty: errorProp
    ) {
        arg(value: '-version')
    }
    
    // java -version outputs to stderr, not stdout
    def versionText = ant.project.properties[errorProp] ?: ant.project.properties[versionProp] ?: ''
    if (versionText) {
        currentJavaVersion = versionText.split('\n')[0].replaceAll('"', '').trim()
    }
} catch (Exception ignored) {
    if (config.verbose) {
        println colorize("  -> Could not determine Java version", 'yellow')
    }
}

def jreUpToDate = false
if (config.skipJRE && jreVersionFile.exists() && jreDest.exists()) {
    def cachedVersion = jreVersionFile.text.trim()
    if (cachedVersion == currentJavaVersion) {
        println colorize("  -> JRE up to date (version: ${currentJavaVersion}), skipping creation", 'yellow')
        jreUpToDate = true
    }
}

if (!jreUpToDate) {
    try {
        def modulesList = [
            'java.base', 'java.desktop', 'java.logging', 'java.prefs',
            'java.xml', 'java.instrument', 'java.management', 'jdk.unsupported'
        ].join(',')
        
        println colorize('  -> Creating custom JRE with jlink...', 'gray')
        
        ant.exec(
            executable: jlinkPath,
            failonerror: false,
            resultproperty: 'jlinkResult'
        ) {
            arg(value: '--add-modules')
            arg(value: modulesList)
            arg(value: '--output')
            arg(value: jreDest.absolutePath)
            arg(value: '--strip-debug')
            arg(value: '--no-man-pages')
            arg(value: '--no-header-files')
        }
        
        if (new File(jreDest, "bin/java${exeExt}").exists()) {
            println colorize('  -> JRE created successfully', 'green')
            
            // Cache JRE version
            ant.mkdir(dir: cacheDir)
            jreVersionFile.text = currentJavaVersion
        }
    } catch (Exception e) {
        println colorize("  -> JRE creation failed: ${e.message}", 'yellow')
    }
}

stopTimedSection('JRE-Creation')

// --- [ Step 4: Create NSIS Installer ] -------------------------------
println colorize('[4/4] Creating installer...', 'cyan')
startTimedSection('NSIS-Compilation')

def nsisScript = new File(rootDir, 'installer.nsis')

if (!nsisScript.exists()) {
    println colorize("ERROR: NSIS script not found at ${nsisScript}", 'red')
    System.exit(1)
}

ant.mkdir(dir: outputDir)

// Pre-calculate application size for NSIS
println colorize('  -> Calculating installation size...', 'gray')
def appSizeKB = 0
ant.fileScanner {
    fileset(dir: appDest) {
        include(name: '**/*')
    }
}.each { file ->
    if (file.isFile()) {
        appSizeKB += file.length()
    }
}
appSizeKB = Math.round(appSizeKB / 1024.0)
println colorize("  -> Calculated size: ${appSizeKB} KB", 'gray')

// Build NSIS command
def nsisArgs = [
    "/DAPP_VERSION=${version}",
    "/DAPP_GUID=${appGuid}",
    "/DPRECALC_SIZE=${appSizeKB}"
]

if (config.fastBuild) {
    nsisArgs << '/DFASTBUILD'
    println colorize('  -> Using FASTBUILD mode (larger installer, faster compilation)', 'yellow')
}

try {
    println colorize('  -> Compiling NSIS installer...', 'gray')
    
    ant.exec(executable: nsisCmd, failonerror: true) {
        nsisArgs.each { arg(value: it) }
        arg(value: nsisScript.absolutePath)
    }
    
} catch (Exception e) {
    println colorize("ERROR: Installer creation failed - ${e.message}", 'red')
    System.exit(1)
}

stopTimedSection('NSIS-Compilation')

// --- [ Finish ] ------------------------------------------------------
def totalTime = (System.currentTimeMillis() - totalStartTime) / 1000.0

println ''
println colorize('========================================', 'green')
println colorize('Build Complete!', 'green')
println colorize('========================================', 'green')
println colorize("Installer: ${new File(outputDir, "My Word Processor Setup-${version}.exe")}", 'cyan')
println colorize("Version: ${version}", 'cyan')
println colorize("Total Time: ${String.format('%.2f', totalTime)}s", 'cyan')
println ''

// Show timing breakdown if verbose
if (config.verbose && timings.size() > 0) {
    println colorize('Timing Breakdown:', 'yellow')
    timings.sort { it.value }.each { name, startTime ->
        def elapsed = (System.currentTimeMillis() - startTime) / 1000.0
        println colorize("  ${name} : ${String.format('%.2f', elapsed)}s", 'gray')
    }
    println ''
}

// Build summary
println colorize('Build Optimizations Used:', 'yellow')
if (config.incrementalBuild) println colorize('  ✓ Incremental build detection', 'green')
if (config.offline) println colorize('  ✓ Maven offline mode', 'green')
if (config.skipJRE && jreUpToDate) println colorize('  ✓ JRE caching', 'green')
if (config.fastBuild) println colorize('  ✓ Fast build mode', 'green')
println colorize('  ✓ Parallel Maven builds (1 thread per CPU)', 'green')
println colorize('  ✓ Pre-calculated installer size', 'green')
println ''

// Open output folder
try {
    if (isWindows) {
        ant.exec(executable: 'explorer.exe', spawn: true, failonerror: false) {
            arg(value: outputDir.absolutePath)
        }
    } else if (System.getProperty('os.name').toLowerCase().contains('mac')) {
        ant.exec(executable: 'open', spawn: true, failonerror: false) {
            arg(value: outputDir.absolutePath)
        }
    } else {
        ant.exec(executable: 'xdg-open', spawn: true, failonerror: false) {
            arg(value: outputDir.absolutePath)
        }
    }
} catch (Exception ignored) {
    // Silently fail if we can't open the folder
}