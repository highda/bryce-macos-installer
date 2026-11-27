/*
 * brycefix.dll: makes "copy from the screen" behave as on Windows for Bryce.
 *
 * Bryce (2, 3D and 4) draws drop shadows and similar effects by copying the
 * pixels behind a dialog or palette from the screen (BitBlt/StretchBlt with a
 * screen DC as the source) and darkening them. Wine keeps every window's
 * pixels separately, so a screen DC only sees the empty desktop: the copy is
 * black and the "shadow" becomes a black slab.
 *
 * This DLL is loaded into Bryce through AppInit_DLLs. It patches the import
 * tables of Bryce's modules (not Wine) so that BitBlt and StretchBlt from a
 * screen DC first compose the requested area from Bryce's visible top-level
 * windows, bottom to top, the way the screen would look on Windows, and copy
 * from that. All other calls go straight to gdi32.
 *
 * Build (32-bit, like Bryce): i686-w64-mingw32-gcc -O2 -shared -s -o brycefix.dll brycefix.c -lgdi32 -luser32
 * Debug log: set BRYCEFIX_LOG=C:\path\to\file.log in the environment.
 *
 * MIT License, part of https://github.com/highda/bryce-macos-installer
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef BOOL (WINAPI *BitBlt_t)(HDC, int, int, int, int, HDC, int, int, DWORD);
typedef BOOL (WINAPI *StretchBlt_t)(HDC, int, int, int, int, HDC, int, int, int, int, DWORD);
typedef HMODULE (WINAPI *LoadLibraryA_t)(LPCSTR);
typedef HMODULE (WINAPI *LoadLibraryW_t)(LPCWSTR);
typedef HMODULE (WINAPI *LoadLibraryExA_t)(LPCSTR, HANDLE, DWORD);
typedef HMODULE (WINAPI *LoadLibraryExW_t)(LPCWSTR, HANDLE, DWORD);
typedef FARPROC (WINAPI *GetProcAddress_t)(HMODULE, LPCSTR);

static BitBlt_t real_BitBlt;
static StretchBlt_t real_StretchBlt;
static LoadLibraryA_t real_LoadLibraryA;
static LoadLibraryW_t real_LoadLibraryW;
static LoadLibraryExA_t real_LoadLibraryExA;
static LoadLibraryExW_t real_LoadLibraryExW;
static GetProcAddress_t real_GetProcAddress;
static HMODULE self;
static FILE *logf;

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    if (!logf) return;
    va_start(ap, fmt);
    vfprintf(logf, fmt, ap);
    va_end(ap);
    fflush(logf);
}

/* A DC that draws on the screen itself: a display DC of the desktop (GetDC(0),
 * GetWindowDC(GetDesktopWindow())) or one from CreateDC("DISPLAY"). */
static BOOL is_screen_dc(HDC hdc)
{
    HWND w;
    if (!hdc || GetObjectType(hdc) != OBJ_DC) return FALSE;
    if (GetDeviceCaps(hdc, TECHNOLOGY) != DT_RASDISPLAY) return FALSE;
    w = WindowFromDC(hdc);
    return w == NULL || w == GetDesktopWindow();
}

#define MAX_WINDOWS 512
struct winlist { HWND w[MAX_WINDOWS]; int n; DWORD pid; };

static BOOL CALLBACK collect(HWND w, LPARAM lp)
{
    struct winlist *l = (struct winlist *)lp;
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    if (pid == l->pid && IsWindowVisible(w) && !IsIconic(w) && l->n < MAX_WINDOWS)
        l->w[l->n++] = w;                       /* top to bottom */
    return TRUE;
}

/* Builds the screen area (x, y, cx, cy) in a new memory DC: what the screen DC
 * gives (the desktop), then this process's visible top-level windows from the
 * bottom of the stacking order to the top, each clipped to its window shape. */
static HDC compose(HDC screen, int x, int y, int cx, int cy, HBITMAP *bmp_out, HGDIOBJ *old_out)
{
    struct winlist l;
    HDC mem;
    HBITMAP bmp;
    RECT area = { x, y, x + cx, y + cy };
    int i;

    if (cx <= 0 || cy <= 0) return NULL;
    mem = CreateCompatibleDC(screen);
    bmp = CreateCompatibleBitmap(screen, cx, cy);
    if (!mem || !bmp) { if (mem) DeleteDC(mem); if (bmp) DeleteObject(bmp); return NULL; }
    *old_out = SelectObject(mem, bmp);
    *bmp_out = bmp;
    real_BitBlt(mem, 0, 0, cx, cy, screen, x, y, SRCCOPY);

    l.n = 0;
    l.pid = GetCurrentProcessId();
    EnumWindows(collect, (LPARAM)&l);
    for (i = l.n - 1; i >= 0; i--) {
        RECT wr, hit;
        HDC wdc;
        HRGN shape;
        if (!GetWindowRect(l.w[i], &wr) || !IntersectRect(&hit, &wr, &area)) continue;
        wdc = GetWindowDC(l.w[i]);
        if (!wdc) continue;
        /* Shaped windows (SetWindowRgn): copy only their shape. The region is
         * relative to the window; move it into the memory DC's coordinates. */
        shape = CreateRectRgn(0, 0, 0, 0);
        if (GetWindowRgn(l.w[i], shape) != ERROR) {
            OffsetRgn(shape, wr.left - x, wr.top - y);
            SelectClipRgn(mem, shape);
        } else {
            SelectClipRgn(mem, NULL);
        }
        real_BitBlt(mem, wr.left - x, wr.top - y, wr.right - wr.left, wr.bottom - wr.top, wdc, 0, 0, SRCCOPY);
        SelectClipRgn(mem, NULL);
        DeleteObject(shape);
        ReleaseDC(l.w[i], wdc);
    }
    return mem;
}

static void release(HDC mem, HBITMAP bmp, HGDIOBJ old)
{
    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
}

/* Screen DC coordinates are screen coordinates once the DC's own origin is added. */
static void to_screen(HDC hdc, int *x, int *y)
{
    POINT p = { *x, *y };
    POINT org;
    LPtoDP(hdc, &p, 1);
    if (GetDCOrgEx(hdc, &org)) { p.x += org.x; p.y += org.y; }
    *x = p.x; *y = p.y;
}

static BOOL WINAPI my_BitBlt(HDC dst, int dx, int dy, int cx, int cy, HDC src, int sx, int sy, DWORD rop)
{
    if (src && is_screen_dc(src) && cx > 0 && cy > 0) {
        HBITMAP bmp; HGDIOBJ old; HDC mem;
        int x = sx, y = sy;
        to_screen(src, &x, &y);
        mem = compose(src, x, y, cx, cy, &bmp, &old);
        if (mem) {
            BOOL r = real_BitBlt(dst, dx, dy, cx, cy, mem, 0, 0, rop);
            logmsg("BitBlt from screen %d,%d %dx%d\n", x, y, cx, cy);
            release(mem, bmp, old);
            return r;
        }
    }
    return real_BitBlt(dst, dx, dy, cx, cy, src, sx, sy, rop);
}

static BOOL WINAPI my_StretchBlt(HDC dst, int dx, int dy, int dcx, int dcy,
                                 HDC src, int sx, int sy, int scx, int scy, DWORD rop)
{
    if (src && is_screen_dc(src) && scx > 0 && scy > 0) {
        HBITMAP bmp; HGDIOBJ old; HDC mem;
        int x = sx, y = sy;
        to_screen(src, &x, &y);
        mem = compose(src, x, y, scx, scy, &bmp, &old);
        if (mem) {
            BOOL r = real_StretchBlt(dst, dx, dy, dcx, dcy, mem, 0, 0, scx, scy, rop);
            logmsg("StretchBlt from screen %d,%d %dx%d\n", x, y, scx, scy);
            release(mem, bmp, old);
            return r;
        }
    }
    return real_StretchBlt(dst, dx, dy, dcx, dcy, src, sx, sy, scx, scy, rop);
}

static void patch_module(HMODULE mod);

static HMODULE WINAPI my_LoadLibraryA(LPCSTR n) { HMODULE m = real_LoadLibraryA(n); patch_module(m); return m; }
static HMODULE WINAPI my_LoadLibraryW(LPCWSTR n) { HMODULE m = real_LoadLibraryW(n); patch_module(m); return m; }
static HMODULE WINAPI my_LoadLibraryExA(LPCSTR n, HANDLE f, DWORD fl) { HMODULE m = real_LoadLibraryExA(n, f, fl); patch_module(m); return m; }
static HMODULE WINAPI my_LoadLibraryExW(LPCWSTR n, HANDLE f, DWORD fl) { HMODULE m = real_LoadLibraryExW(n, f, fl); patch_module(m); return m; }

static FARPROC WINAPI my_GetProcAddress(HMODULE m, LPCSTR name)
{
    FARPROC p = real_GetProcAddress(m, name);
    if ((ULONG_PTR)name > 0xffff && p) {
        if (p == (FARPROC)real_BitBlt) return (FARPROC)my_BitBlt;
        if (p == (FARPROC)real_StretchBlt) return (FARPROC)my_StretchBlt;
    }
    return p;
}

/* Wine's own DLLs (and anything else in the Windows folder) are left alone:
 * only Bryce, its DLLs and plug-ins are patched. */
static BOOL in_windows_dir(HMODULE mod)
{
    char path[MAX_PATH], win[MAX_PATH];
    UINT n = GetWindowsDirectoryA(win, sizeof(win));
    if (!n || n >= sizeof(win) || !GetModuleFileNameA(mod, path, sizeof(path))) return TRUE;
    return _strnicmp(path, win, n) == 0 && (path[n] == '\\' || path[n] == 0);
}

/* Replaces the given functions in one module's import address table. */
static void patch_module(HMODULE mod)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY *dir;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    int patched = 0;

    if (!mod || mod == self || in_windows_dir(mod)) return;
    dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir->VirtualAddress || !dir->Size) return;

    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir->VirtualAddress); imp->Name; imp++) {
        IMAGE_THUNK_DATA *thunk = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; thunk->u1.Function; thunk++) {
            void **slot = (void **)&thunk->u1.Function;
            void *repl = NULL;
            if (*slot == (void *)real_BitBlt) repl = (void *)my_BitBlt;
            else if (*slot == (void *)real_StretchBlt) repl = (void *)my_StretchBlt;
            else if (*slot == (void *)real_LoadLibraryA) repl = (void *)my_LoadLibraryA;
            else if (*slot == (void *)real_LoadLibraryW) repl = (void *)my_LoadLibraryW;
            else if (*slot == (void *)real_LoadLibraryExA) repl = (void *)my_LoadLibraryExA;
            else if (*slot == (void *)real_LoadLibraryExW) repl = (void *)my_LoadLibraryExW;
            else if (*slot == (void *)real_GetProcAddress) repl = (void *)my_GetProcAddress;
            if (repl) {
                DWORD prot;
                if (VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &prot)) {
                    *slot = repl;
                    VirtualProtect(slot, sizeof(void *), prot, &prot);
                    patched++;
                }
            }
        }
    }
    if (patched) {
        char name[MAX_PATH] = "";
        GetModuleFileNameA(mod, name, sizeof(name));
        logmsg("patched %d imports in %s\n", patched, name);
    }
}

/* Patches every module loaded so far (walking the loader's module list). */
static void patch_all(void)
{
    MEMORY_BASIC_INFORMATION mbi;
    BYTE *p = NULL;
    HMODULE last = NULL;
    while (VirtualQuery(p, &mbi, sizeof(mbi)) == sizeof(mbi)) {
        if (mbi.State == MEM_COMMIT && mbi.Type == MEM_IMAGE && mbi.AllocationBase == mbi.BaseAddress
            && (HMODULE)mbi.AllocationBase != last) {
            last = (HMODULE)mbi.AllocationBase;
            patch_module(last);
        }
        p = (BYTE *)mbi.BaseAddress + mbi.RegionSize;
        if ((ULONG_PTR)p < (ULONG_PTR)mbi.BaseAddress) break;
    }
}

/* Only act inside Bryce (AppInit_DLLs loads the DLL into every GUI program). */
static BOOL is_bryce(void)
{
    char path[MAX_PATH], *name;
    GetModuleFileNameA(NULL, path, sizeof(path));
    name = strrchr(path, '\\');
    name = name ? name + 1 : path;
    return _strnicmp(name, "bryce", 5) == 0;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        HMODULE gdi = GetModuleHandleA("gdi32.dll"), k32 = GetModuleHandleA("kernel32.dll");
        char logpath[MAX_PATH];
        self = inst;
        DisableThreadLibraryCalls(inst);
        if (!is_bryce() || !gdi || !k32) return TRUE;
        if (GetEnvironmentVariableA("BRYCEFIX_LOG", logpath, sizeof(logpath)))
            logf = fopen(logpath, "a");
        real_BitBlt = (BitBlt_t)GetProcAddress(gdi, "BitBlt");
        real_StretchBlt = (StretchBlt_t)GetProcAddress(gdi, "StretchBlt");
        real_LoadLibraryA = (LoadLibraryA_t)GetProcAddress(k32, "LoadLibraryA");
        real_LoadLibraryW = (LoadLibraryW_t)GetProcAddress(k32, "LoadLibraryW");
        real_LoadLibraryExA = (LoadLibraryExA_t)GetProcAddress(k32, "LoadLibraryExA");
        real_LoadLibraryExW = (LoadLibraryExW_t)GetProcAddress(k32, "LoadLibraryExW");
        real_GetProcAddress = (GetProcAddress_t)GetProcAddress(k32, "GetProcAddress");
        logmsg("brycefix loaded\n");
        patch_all();
    }
    return TRUE;
}
