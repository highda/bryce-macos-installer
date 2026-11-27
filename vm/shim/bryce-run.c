/*
 * bryce-run.exe: starts Bryce and loads brycefix.dll into it.
 *
 *   bryce-run.exe "C:\Bryce4\Bryce4.exe" [arguments]
 *
 * Wine has no AppInit_DLLs, so the DLL is loaded the classic way: Bryce is
 * started suspended and a thread created in it calls LoadLibraryW with the path
 * of brycefix.dll (next to this program) before Bryce runs. Bryce's files are
 * not changed. bryce-run.exe then waits for Bryce to quit and returns its exit
 * code.
 *
 * Build: i686-w64-mingw32-gcc -O2 -municode -mwindows -s -o bryce-run.exe bryce-run.c
 *
 * MIT License, part of https://github.com/highda/bryce-macos-installer
 */
#include <windows.h>
#include <wchar.h>

/* The command line after our own program name. */
static WCHAR *rest_of_command_line(void)
{
    WCHAR *p = GetCommandLineW();
    if (*p == L'"') {
        p++;
        while (*p && *p != L'"') p++;
        if (*p) p++;
    } else {
        while (*p && *p != L' ' && *p != L'\t') p++;
    }
    while (*p == L' ' || *p == L'\t') p++;
    return p;
}

/* Loads the DLL into the process; TRUE if LoadLibraryW returned a module. */
static BOOL inject(HANDLE process, const WCHAR *dll)
{
    BOOL ok = FALSE;
    SIZE_T size = (wcslen(dll) + 1) * sizeof(WCHAR);
    void *remote = VirtualAllocEx(process, NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    /* kernel32 is at the same address in every 32-bit process. */
    FARPROC load = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
    HANDLE thread;
    DWORD result = 0;
    if (!remote || !load) return FALSE;
    if (WriteProcessMemory(process, remote, dll, size, NULL)) {
        thread = CreateRemoteThread(process, NULL, 0, (LPTHREAD_START_ROUTINE)load, remote, 0, NULL);
        if (thread) {
            if (WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0 && GetExitCodeThread(thread, &result))
                ok = result != 0;
            CloseHandle(thread);
        }
    }
    VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    return ok;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR cmd, int show)
{
    WCHAR dll[MAX_PATH], *slash, *target = rest_of_command_line();
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 1;

    if (!*target) return 2;
    GetModuleFileNameW(NULL, dll, MAX_PATH);
    slash = wcsrchr(dll, L'\\');
    if (!slash || (size_t)(slash - dll) + 14 >= MAX_PATH) return 3;
    wcscpy(slash + 1, L"brycefix.dll");

    /* Start Bryce suspended and load the DLL before its first instruction, so
     * even the dialogs it shows at start-up are covered. If that fails, let
     * Bryce run and load the DLL once it waits for input. */
    if (!CreateProcessW(NULL, target, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) return 4;
    if (GetFileAttributesW(dll) == INVALID_FILE_ATTRIBUTES) {
        ResumeThread(pi.hThread);
    } else if (inject(pi.hProcess, dll)) {
        ResumeThread(pi.hThread);
    } else {
        ResumeThread(pi.hThread);
        WaitForInputIdle(pi.hProcess, 20000);
        inject(pi.hProcess, dll);
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
