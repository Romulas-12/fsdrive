#include "CUserAccess.h"

#include <grp.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/fsuid.h>
#include <sys/syscall.h>
#endif

int fsdrive_user_groups(const char *user, gid_t gid, gid_t *out, int max) {
    int n = max;
#ifdef __APPLE__
    if (getgrouplist(user, (int)gid, (int *)out, &n) < 0) return -1;
#else
    if (getgrouplist(user, gid, out, &n) < 0) return -1;
#endif
    return n;
}

int fsdrive_thread_groups(gid_t *out, int max) { return getgroups(max, out); }

#ifdef __linux__
// The libc wrappers of setgroups apply to every thread of the process; the raw system
// call changes only this one, which is what a server serving many users at once needs.
static int thread_setgroups(const gid_t *groups, int count) {
    return (int)syscall(SYS_setgroups, (size_t)count, groups);
}

// setfsuid reports the previous value instead of an error; reading it back tells.
int fsdrive_thread_become(uid_t uid, gid_t gid, const gid_t *groups, int count) {
    if (thread_setgroups(groups, count) != 0) return -1;
    setfsgid(gid);
    if ((gid_t)setfsgid((gid_t)-1) != gid) return -1;
    setfsuid(uid);
    if ((uid_t)setfsuid((uid_t)-1) != uid) return -1;
    return 0;
}

int fsdrive_thread_restore(const gid_t *groups, int count) {
    setfsuid(0);
    setfsgid(0);
    return thread_setgroups(groups, count);
}
#else
int fsdrive_thread_become(uid_t uid, gid_t gid, const gid_t *groups, int count) { return -1; }
int fsdrive_thread_restore(const gid_t *groups, int count) { return -1; }
#endif
