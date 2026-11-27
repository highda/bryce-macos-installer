/*
 * bryce-xfix.so: preloaded into Wine (LD_PRELOAD). Keeps Bryce's palettes in
 * front of their main window without flicker.
 *
 * Wine runs Bryce's windows unmanaged (Managed=N). When it activates one, for
 * instance Bryce's main window after a pop-up menu closes, it raises that X
 * window to the top of the stack, above the palettes the window owns. On
 * Windows an owned window always stays above its owner, so for a moment X
 * shows the main window over the palettes (they flicker black) until
 * bryce-stack puts them back.
 *
 * This library intercepts the two calls Wine's X11 driver uses to restack
 * windows. A request to put a window on top (stack mode Above without a
 * sibling) for a window that owns visible windows (WM_TRANSIENT_FOR) becomes
 * "just below the lowest of them": where Windows keeps it. Everything else is
 * passed on unchanged.
 *
 * Build: gcc -O2 -shared -fPIC -o bryce-xfix.so bryce-xfix.c -lX11 -ldl
 *
 * MIT License, part of https://github.com/highda/bryce-macos-installer
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

typedef int (*XConfigureWindow_t)(Display *, Window, unsigned int, XWindowChanges *);
typedef Status (*XReconfigureWMWindow_t)(Display *, Window, int, unsigned int, XWindowChanges *);

/* The lowest viewable top-level window owned by `w`, or None. Top-level means a
 * direct child of the root window; Wine's windows for Bryce are all of those. */
static Window lowest_owned(Display *dpy, Window w)
{
    Window root, parent, *kids = NULL, found = None;
    unsigned int n = 0, i;
    if (!XQueryTree(dpy, DefaultRootWindow(dpy), &root, &parent, &kids, &n)) return None;
    for (i = 0; i < n && found == None; i++) {        /* bottom to top */
        Window owner = None;
        XWindowAttributes a;
        if (kids[i] == w) continue;
        if (!XGetTransientForHint(dpy, kids[i], &owner) || owner != w) continue;
        if (XGetWindowAttributes(dpy, kids[i], &a) && a.map_state == IsViewable) found = kids[i];
    }
    if (kids) XFree(kids);
    return found;
}

/* Rewrites "put w on top" into "put w below its lowest owned window". */
static void adjust(Display *dpy, Window w, unsigned int *mask, XWindowChanges *ch)
{
    Window below;
    if (!(*mask & CWStackMode) || (*mask & CWSibling) || ch->stack_mode != Above) return;
    below = lowest_owned(dpy, w);
    if (below == None) return;
    ch->sibling = below;
    ch->stack_mode = Below;
    *mask |= CWSibling;
    if (getenv("BRYCE_XFIX_LOG")) fprintf(stderr, "bryce-xfix: raise of 0x%lx kept below 0x%lx\n", w, below);
}

int XConfigureWindow(Display *dpy, Window w, unsigned int mask, XWindowChanges *ch)
{
    static XConfigureWindow_t real;
    XWindowChanges copy;
    if (!real) real = (XConfigureWindow_t)dlsym(RTLD_NEXT, "XConfigureWindow");
    if (ch) {
        copy = *ch;
        adjust(dpy, w, &mask, &copy);
        return real(dpy, w, mask, &copy);
    }
    return real(dpy, w, mask, ch);
}

Status XReconfigureWMWindow(Display *dpy, Window w, int screen, unsigned int mask, XWindowChanges *ch)
{
    static XReconfigureWMWindow_t real;
    XWindowChanges copy;
    if (!real) real = (XReconfigureWMWindow_t)dlsym(RTLD_NEXT, "XReconfigureWMWindow");
    if (ch) {
        copy = *ch;
        adjust(dpy, w, &mask, &copy);
        return real(dpy, w, screen, mask, &copy);
    }
    return real(dpy, w, screen, mask, ch);
}
