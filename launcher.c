#include <windows.h>
#include <stdio.h>
#include <string.h> // Required for strrchr

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                   LPSTR lpCmdLine, int nCmdShow) {

    // --- START: Added Code ---
    // Try to attach to the parent process's console.
    // This will return TRUE if launched from cmd.exe
    // This will return FALSE if double-clicked (no parent console), which is fine.
    BOOL attachedToConsole = AttachConsole(ATTACH_PARENT_PROCESS);
    // --- END: Added Code ---

    char appDir[MAX_PATH];
    char appExe[MAX_PATH];
    char jrePath[MAX_PATH];
    char commandLine[2048];

    // Get the directory where the launcher is located
    GetModuleFileName(NULL, appDir, MAX_PATH);

    // Extract directory path
    char* lastBackslash = strrchr(appDir, '\\');
    if (lastBackslash) {
        *lastBackslash = '\0';
    }

    // Construct paths
    sprintf(appExe, "%s\\mavenplatformwordapp64.exe", appDir);
    sprintf(jrePath, "%s\\..\\jre", appDir);

    // Check if bundled JRE exists
    DWORD attrib = GetFileAttributes(jrePath);
    if (attrib != INVALID_FILE_ATTRIBUTES && (attrib & FILE_ATTRIBUTE_DIRECTORY)) {
        sprintf(commandLine, "\"%s\" --jdkhome \"%s\"", appExe, jrePath);
    } else {
        sprintf(commandLine, "\"%s\"", appExe);
    }

    STARTUPINFO si;
    PROCESS_INFORMATION pi;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    // NOTE: We no longer use STARTF_USESTDHANDLES.
    // If AttachConsole succeeded, our launcher now has *real* standard
    // handles, which will be inherited by the child because
    // bInheritHandles is TRUE.
    
    // Launch the process
    if (!CreateProcess(NULL,
                       commandLine,
                       NULL,
                       NULL,
                       TRUE,        // CRITICAL: Must be TRUE to pass on the attached console
                       0,           // No creation flags
                       NULL,
                       NULL,
                       &si,
                       &pi))
    {
        MessageBox(NULL, "Failed to launch application.", "Launcher Error", MB_OK | MB_ICONERROR);
        // --- START: Added Code ---
        if (attachedToConsole) {
            FreeConsole(); // Detach on error
        }
        // --- END: Added Code ---
        return 1;
    }

    // Wait for the application to exit
    if (pi.hProcess) {
        WaitForSingleObject(pi.hProcess, INFINITE);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }

    // --- START: Added Code ---
    // If we attached to a console, detach from it before we exit.
    if (attachedToConsole) {
        FreeConsole();
    }
    // --- END: Added Code ---

    return 0;
}