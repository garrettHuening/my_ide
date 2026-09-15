#ifndef CForkpty_h
#define CForkpty_h

#include <sys/types.h>
#include <sys/ioctl.h>
#include <util.h>
#include <termios.h>

// Thin wrapper around macOS's forkpty(3).
// Returns the pid of the child (0 in the child), or -1 on error.
// `master_fd_out` receives the master file descriptor in the parent.
// `name_out` may be NULL; if non-NULL it should be at least 64 bytes.
// `term` / `winsize` may be NULL to use defaults.
static inline pid_t cforkpty_open(
    int *master_fd_out,
    char *name_out,
    const struct termios *term,
    const struct winsize *winsize
) {
    return forkpty(
        master_fd_out,
        name_out,
        (struct termios *)term,
        (struct winsize *)winsize
    );
}

// Tell the kernel about a window-size change on a master pty.
// Returns 0 on success.
static inline int cforkpty_setwinsize(int master_fd, unsigned short rows, unsigned short cols) {
    struct winsize w;
    w.ws_row = rows;
    w.ws_col = cols;
    w.ws_xpixel = 0;
    w.ws_ypixel = 0;
    return ioctl(master_fd, TIOCSWINSZ, &w);
}

#endif /* CForkpty_h */
