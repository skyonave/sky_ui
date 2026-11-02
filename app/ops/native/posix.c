// Keep platform-dependent structs in C; Dart consumes fixed-width metadata.
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>

int sky_uid(void) { return geteuid(); }
int sky_gid(void) { return getegid(); }
int sky_close(int fd) { return close(fd); }
int sky_sync(int fd) { return fsync(fd); }
int sky_lock(int fd, int operation) { return flock(fd, operation); }
int sky_mode(int fd, int mode) { return fchmod(fd, mode); }
int sky_owner(int fd, int uid, int gid) { return fchown(fd, uid, gid); }
int sky_umask(int mode) { return umask(mode); }
int sky_metadata(int fd, int64_t *out) {
  struct stat value;
  if (fstat(fd, &value)) return -1;
  out[0] = value.st_mode; out[1] = value.st_uid; out[2] = value.st_gid;
  out[3] = value.st_nlink; out[4] = value.st_size;
  out[5] = value.st_mtim.tv_sec; out[6] = value.st_mtim.tv_nsec;
  out[7] = value.st_ino; out[8] = value.st_dev;
  return 0;
}
// Walk every parent with O_NOFOLLOW, including API-owned data directories.
int sky_open(const char *path, int flags, int mode) {
  if (!path || path[0] != '/' || !path[1]) { errno = EINVAL; return -1; }
  char *copy = strdup(path + 1), *saved = NULL;
  if (!copy) return -1;
  int parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  char *part = strtok_r(copy, "/", &saved);
  while (part && parent >= 0) {
    if (!strcmp(part, ".") || !strcmp(part, "..")) { close(parent); parent=-1; break; }
    char *next = strtok_r(NULL, "/", &saved);
    int fd = openat(parent, part, (next ? O_RDONLY | O_DIRECTORY : flags) | O_NOFOLLOW | O_CLOEXEC, mode);
    close(parent); parent = fd; part = next;
  }
  free(copy); return parent;
}
int sky_open_read(const char *path) { return sky_open(path, O_RDONLY | O_NONBLOCK, 0); }
int sky_open_lock(const char *path) { return sky_open(path, O_RDWR | O_CREAT, 0600); }
int sky_open_dir(const char *path) { return sky_open(path, O_RDONLY | O_DIRECTORY, 0); }
// Atomic operations remain relative to a pinned, non-symlink directory.
int sky_create(int parent, const char *name) {
  return openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
}
int sky_replace(int parent, const char *from, const char *to) { return renameat(parent, from, parent, to); }
int sky_unlink(int parent, const char *name) { return unlinkat(parent, name, 0); }
int64_t sky_write(int fd, const uint8_t *data, int64_t size) { return write(fd, data, size); }
int64_t sky_read(int fd, uint8_t *data, int64_t size) { return read(fd, data, size); }
int sky_spawn(char *const *args, char *const *env, int lock, int *out) {
  int pipefd[2], statusfd[2];
  if (pipe2(pipefd, O_CLOEXEC)) return -1;
  if (fcntl(pipefd[0], F_SETFL, O_NONBLOCK)) { close(pipefd[0]); close(pipefd[1]); return -1; }
  if (pipe2(statusfd, O_CLOEXEC)) { close(pipefd[0]); close(pipefd[1]); return -1; }
  fcntl(statusfd[0], F_SETFL, O_NONBLOCK);
  // Relocate sources so mappings to 9/10 cannot overwrite another source fd.
  int output = fcntl(pipefd[1], F_DUPFD_CLOEXEC, 64);
  int status = fcntl(statusfd[1], F_DUPFD_CLOEXEC, 64);
  int inherited = lock >= 0 ? fcntl(lock, F_DUPFD_CLOEXEC, 64) : -1;
  if (output < 0 || status < 0 || (lock >= 0 && inherited < 0)) {
    close(pipefd[0]); close(pipefd[1]); close(statusfd[0]); close(statusfd[1]);
    if (output >= 0) close(output);
    if (status >= 0) close(status);
    if (inherited >= 0) close(inherited);
    return -1;
  }
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  // Only the installer transaction lock is explicitly inherited across exec.
  if (lock >= 0) posix_spawn_file_actions_adddup2(&actions, inherited, 9);
  posix_spawn_file_actions_adddup2(&actions, status, 10);
  pid_t pid;
  int result = posix_spawnp(&pid, args[0], &actions, NULL, args, env);
  posix_spawn_file_actions_destroy(&actions); close(pipefd[1]); close(statusfd[1]);
  close(output); close(status); if (inherited >= 0) close(inherited);
  if (result) { close(pipefd[0]); close(statusfd[0]); return -1; }
  out[0] = pid; out[1] = pipefd[0]; out[2] = statusfd[0]; return 0;
}
int sky_poll(int pid) {
  int status;
  int result=waitpid(pid, &status, WNOHANG);
  if (result==0) return -1;
  if (result<0) return -2;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
int sky_kill(int pid) { kill(-pid, SIGKILL); return kill(pid, SIGKILL); }
static int remove_children(int descriptor) {
  DIR *directory = fdopendir(dup(descriptor));
  if (!directory) return -1;
  int result = 0;
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    struct stat value;
    if (fstatat(descriptor, entry->d_name, &value, AT_SYMLINK_NOFOLLOW)) { result=-1; break; }
    if (S_ISDIR(value.st_mode)) {
      int child = openat(descriptor, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0) { result=-1; break; }
      result = remove_children(child); close(child);
      if (result || unlinkat(descriptor, entry->d_name, AT_REMOVEDIR)) { result=-1; break; }
    } else if (unlinkat(descriptor, entry->d_name, 0)) { result=-1; break; }
  }
  closedir(directory); return result;
}
int sky_remove_tree(const char *path) {
  char *copy = strdup(path);
  if (!copy) return -1;
  char *slash = strrchr(copy, '/');
  if (!slash || slash == copy || !slash[1]) { free(copy); return -1; }
  *slash = 0;
  int parent = sky_open_dir(copy), result=-1;
  if (parent >= 0) {
    int child = openat(parent, slash+1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child >= 0) {
      result=remove_children(child); close(child);
      if (!result) result=unlinkat(parent, slash+1, AT_REMOVEDIR);
    }
    close(parent);
  }
  free(copy); return result;
}
