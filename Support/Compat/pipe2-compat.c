// pipe2() for release builds that must run on macOS 26.
//
// Scripts/release.sh links Homebrew's static libevent into the app. That archive is built for
// macOS 27 and calls pipe2(), which libSystem only provides from macOS 27.0, so a plain static
// link would import _pipe2 and the app would refuse to launch on macOS 26 ("Symbol not found").
// This definition satisfies libevent's reference inside the executable instead. It is hidden, so
// the app does not export it and system libraries keep using their own pipe2().
//
// libevent is only reached by chiaki-ng's internet "holepunch" connection, which FluidPlay never
// starts (LAN only), but the shim is a complete, correct implementation regardless.
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

__attribute__((visibility("hidden")))
int pipe2(int fds[2], int flags)
{
    if (flags & ~(O_CLOEXEC | O_NONBLOCK)) {
        errno = EINVAL;
        return -1;
    }
    if (pipe(fds) != 0) {
        return -1;
    }
    for (int i = 0; i < 2; i++) {
        if ((flags & O_CLOEXEC) && fcntl(fds[i], F_SETFD, FD_CLOEXEC) == -1) {
            goto fail;
        }
        if (flags & O_NONBLOCK) {
            int status = fcntl(fds[i], F_GETFL);
            if (status == -1 || fcntl(fds[i], F_SETFL, status | O_NONBLOCK) == -1) {
                goto fail;
            }
        }
    }
    return 0;

fail: {
        int saved = errno;
        close(fds[0]);
        close(fds[1]);
        errno = saved;
        return -1;
    }
}
