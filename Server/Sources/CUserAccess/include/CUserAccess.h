#ifndef CUSERACCESS_H
#define CUSERACCESS_H

#include <sys/types.h>

/// Groups of a user from the system group database. Returns how many were written to
/// `out` (at most `max`), or -1 if there were more.
int fsdrive_user_groups(const char *user, gid_t gid, gid_t *out, int max);

/// Switches the file-system identity of the calling thread only (Linux setfsuid,
/// setfsgid and a per-thread setgroups), so the kernel checks permissions and ACLs as
/// that user. Returns 0 on success. Not available on other systems (returns -1).
int fsdrive_thread_become(uid_t uid, gid_t gid, const gid_t *groups, int count);

/// Back to root for the calling thread, with root's own groups.
int fsdrive_thread_restore(const gid_t *groups, int count);

/// Root's supplementary groups, to restore them later. Same return as fsdrive_user_groups.
int fsdrive_thread_groups(gid_t *out, int max);

#endif
