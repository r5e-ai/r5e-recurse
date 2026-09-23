/* SPDX-License-Identifier: AGPL-3.0-only */
/* Cooperative POSIX group owner. Protocol v1; never accepts recovered PIDs. */
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#define FRAME 65536
#define CONFIG (1024 * 1024)
static volatile sig_atomic_t requested_stop = 0;
static void request_stop(int signal_number) {
  (void)signal_number;
  requested_stop = 1;
}
static int64_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static uint32_t u32(const unsigned char *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | p[3];
}
static void p32(unsigned char *p, uint32_t n) {
  p[0] = n >> 24;
  p[1] = n >> 16;
  p[2] = n >> 8;
  p[3] = n;
}
static void p64(unsigned char *p, uint64_t n) {
  p32(p, n >> 32);
  p32(p + 4, n);
}
static int exact(int fd, void *buf, size_t n) {
  unsigned char *p = buf;
  while (n) {
    if (requested_stop)
      return -1;
    ssize_t r = read(fd, p, n);
    if (r < 0 && errno == EINTR)
      continue;
    if (r <= 0)
      return -1;
    p += r;
    n -= r;
  }
  return 0;
}
static int writeall(int fd, const void *buf, size_t n) {
  const unsigned char *p = buf;
  while (n) {
    ssize_t r = write(fd, p, n);
    if (r < 0 && errno == EINTR)
      continue;
    if (r <= 0)
      return -1;
    p += r;
    n -= r;
  }
  return 0;
}
static void nonblock(int fd) {
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}
static void cloexec(int fd) { fcntl(fd, F_SETFD, FD_CLOEXEC); }
static void close_except(int a, int b) {
  long n = sysconf(_SC_OPEN_MAX);
  if (n > 65536)
    n = 65536;
  for (int i = 3; i < n; i++)
    if (i != a && i != b)
      close(i);
}
struct parser {
  unsigned char *p, *end;
  int bad;
};
static uint32_t number(struct parser *p) {
  if (p->end - p->p < 4) {
    p->bad = 1;
    return 0;
  }
  uint32_t n = u32(p->p);
  p->p += 4;
  return n;
}
static char *string(struct parser *p) {
  uint32_t n = number(p);
  if (p->bad || n > CONFIG || p->end - p->p < (long)n || memchr(p->p, 0, n)) {
    p->bad = 1;
    return NULL;
  }
  char *s = malloc(n + 1);
  if (!s) {
    p->bad = 1;
    return NULL;
  }
  memcpy(s, p->p, n);
  s[n] = 0;
  p->p += n;
  return s;
}
static char **strings(struct parser *p) {
  uint32_t n = number(p);
  if (n > 4096) {
    p->bad = 1;
    return NULL;
  }
  char **v = calloc(n + 1, sizeof(char *));
  if (!v) {
    p->bad = 1;
    return NULL;
  }
  for (uint32_t i = 0; i < n && !p->bad; i++)
    v[i] = string(p);
  return v;
}
/* Open every component beneath an explicit root without following links. */
static int beneath(const char *root, const char *relative) {
  if (!relative || !*relative || *relative == '/')
    return -1;
  int fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  if (fd < 0)
    return -1;
  char *copy = strdup(relative), *save = NULL;
  if (!copy) {
    close(fd);
    return -1;
  }
  char *part = strtok_r(copy, "/", &save);
  while (part) {
    char *next = strtok_r(NULL, "/", &save);
    if (!strcmp(part, ".") || !strcmp(part, "..")) {
      close(fd);
      free(copy);
      return -1;
    }
    int n =
        openat(fd, part,
               O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (next ? O_DIRECTORY : 0));
    close(fd);
    fd = n;
    if (fd < 0)
      break;
    part = next;
  }
  free(copy);
  struct stat st;
  if (fd >= 0 && (fstat(fd, &st) || !S_ISREG(st.st_mode))) {
    close(fd);
    fd = -1;
  }
  return fd;
}
static void reset_signals(void) {
  for (int i = 1; i <= 64; i++)
    if (i != SIGKILL && i != SIGSTOP)
      signal(i, SIG_DFL);
  sigset_t empty;
  sigemptyset(&empty);
  sigprocmask(SIG_SETMASK, &empty, NULL);
}
static void anchor(int status, int go, int out, int err, int input, char *cwd,
                   char **argv, char **env) {
  if (setpgid(0, 0))
    _exit(120);
#ifdef R5E_LAUNCH_TEST
  const char *fault = getenv("R5E_LAUNCH_TEST_BEFORE_READY");
  if (fault && !strcmp(fault, "exit"))
    _exit(119);
  if (fault && !strcmp(fault, "hang"))
    for (;;)
      pause();
#endif
  signal(SIGTERM, SIG_IGN);
  signal(SIGINT, SIG_IGN);
  signal(SIGHUP, SIG_IGN);
  unsigned char ready = 'R';
  if (writeall(status, &ready, 1))
    _exit(121);
  if (exact(go, &ready, 1) || ready != 'G')
    _exit(122);
  pid_t child = fork();
  if (child < 0)
    _exit(123);
  if (!child) {
    reset_signals();
    if (chdir(cwd) || dup2(input, 0) < 0 || dup2(out, 1) < 0 ||
        dup2(err, 2) < 0)
      _exit(126);
    close_except(-1, -1);
    execve(argv[0], argv, env);
    _exit(errno == ENOENT ? 127 : 126);
  }
  close(input);
  close(out);
  close(err);
  close(go);
  close(0);
  close(1);
  close(2);
  close_except(status, -1);
  int result;
  while (waitpid(child, &result, 0) < 0)
    if (errno != EINTR)
      _exit(124);
  unsigned char msg[9];
  msg[0] = 'X';
  p32(msg + 1, WIFEXITED(result) ? (uint32_t)WEXITSTATUS(result) : UINT32_MAX);
  p32(msg + 5, WIFSIGNALED(result) ? (uint32_t)WTERMSIG(result) : 0);
  writeall(status, msg, 9);
  /* Keep the PGID reserved until the controller's final group signal. */
  for (;;)
    pause();
}
int main(void) {
  /* Ignored SIGCHLD/SA_NOCLDWAIT would auto-reap the ownership anchor and
   * invalidate the no-PGID-reuse guarantee before our final group signal. */
  struct sigaction child_action;
  memset(&child_action, 0, sizeof(child_action));
  child_action.sa_handler = SIG_DFL;
  sigemptyset(&child_action.sa_mask);
  if (sigaction(SIGCHLD, &child_action, NULL))
    return 2;
  signal(SIGPIPE, SIG_IGN);
  struct sigaction stop_action;
  memset(&stop_action, 0, sizeof(stop_action));
  stop_action.sa_handler = request_stop;
  sigemptyset(&stop_action.sa_mask);
  if (sigaction(SIGTERM, &stop_action, NULL) ||
      sigaction(SIGINT, &stop_action, NULL) ||
      sigaction(SIGHUP, &stop_action, NULL))
    return 2;
  sigset_t control_signals;
  sigemptyset(&control_signals);
  sigaddset(&control_signals, SIGTERM);
  sigaddset(&control_signals, SIGINT);
  sigaddset(&control_signals, SIGHUP);
  if (sigprocmask(SIG_UNBLOCK, &control_signals, NULL))
    return 2;
  unsigned char header[4];
  if (exact(0, header, 4))
    return 2;
  uint32_t size = u32(header);
  if (size < 5 || size > CONFIG)
    return 2;
  unsigned char *config = malloc(size);
  if (!config || exact(0, config, size) || config[0] != 'S' ||
      u32(config + 1) != 1)
    return 2;
  struct parser p = {config + 5, config + size, 0};
  char *cwd = string(&p), *input_root = string(&p), *input_rel = string(&p),
       *final_root = string(&p), *final_rel = string(&p);
  char **argv = strings(&p), **env = strings(&p);
  uint32_t budget = number(&p), grace = number(&p), drain = number(&p);
  if (p.bad || p.p != p.end || !argv || !argv[0] || argv[0][0] != '/' || !cwd ||
      cwd[0] != '/' || budget > 64 * 1024 * 1024 || grace > 5000 ||
      drain > 5000 || !drain)
    return 2;
  int input = beneath(input_root, input_rel);
  if (input < 0)
    return 2;
  int out[2], err[2], status[2], gate[2];
  if (pipe(out) || pipe(err) || pipe(status) || pipe(gate))
    return 2;
  pid_t group = fork();
  if (group < 0)
    return 2;
  if (!group) {
    close(out[0]);
    close(err[0]);
    close(status[0]);
    close(gate[1]);
    anchor(status[1], gate[0], out[1], err[1], input, cwd, argv, env);
    _exit(125);
  }
  close(input);
  close(out[1]);
  close(err[1]);
  close(status[1]);
  close(gate[0]);
  unsigned char r;
  /* Child has established its own group before any signal or workload exec. */
  struct pollfd startup = {status[0], POLLIN, 0};
  if (poll(&startup, 1, 2000) <= 0 || !(startup.revents & POLLIN) ||
      exact(status[0], &r, 1) || r != 'R') {
    kill(group, SIGKILL);
    waitpid(group, NULL, 0);
    return 2;
  }
  nonblock(0);
  nonblock(1);
  nonblock(out[0]);
  nonblock(err[0]);
  nonblock(status[0]);
  cloexec(gate[1]);
  unsigned char sendbuf[FRAME + 32], control[32], xbuf[9];
  size_t sending = 21, sent = 0, cn = 0, xn = 0;
  uint64_t seq = 0, waiting = UINT64_MAX;
  uint32_t used = 0;
  int capture = 0, cleanup = 0, exitcode = -1, termsig = 0, stopping = 0,
      killed = 0, reaped = 0, started = 0, peer = 1, finalfd = -1,
      finaldone = 0, finished = 0;
  int64_t stop_at = 0, finish_at = 0, last_ack = now_ms(), ready_at = now_ms();
  p32(sendbuf, 17);
  sendbuf[4] = 'R';
  p64(sendbuf + 5, seq++);
  p32(sendbuf + 13, 1);
  p32(sendbuf + 17, (uint32_t)group);
  for (;;) {
    int64_t now = now_ms();
    if (!started && now - ready_at >= 2000)
      capture = 1;
    if (!peer || capture || exitcode != -1 || termsig || requested_stop)
      if (!stopping) {
        stopping = 1;
        stop_at = now;
        kill(-group, SIGTERM);
      }
    if (stopping && !killed && now - stop_at >= grace) {
      kill(-group, SIGKILL);
      killed = 1;
      finish_at = now + drain;
    }
    if (killed && !reaped) {
      pid_t w = waitpid(group, NULL, WNOHANG);
      if (w == group)
        reaped = 1;
    }
    /* Never signal a saved group after reaping its anchor. Read-only probe
     * only. */
    if (killed && now >= finish_at) {
      if (!reaped) {
        cleanup = 1;
      } else if (kill(-group, 0) == 0 || errno != ESRCH) {
        cleanup = 1;
      }
      if (out[0] >= 0 || err[0] >= 0) {
        capture = 1;
        if (out[0] >= 0)
          close(out[0]);
        if (err[0] >= 0)
          close(err[0]);
        out[0] = err[0] = -1;
      }
    }
    if (!peer && killed && now >= finish_at)
      break;
    if ((waiting != UINT64_MAX || sending) &&
        now - last_ack > drain + grace + 5000) {
      capture = 1;
      peer = 0;
    }
    if (stopping && killed && reaped && out[0] < 0 && err[0] < 0 && !sending &&
        waiting == UINT64_MAX &&
        ((kill(-group, 0) < 0 && errno == ESRCH) || now >= finish_at)) {
      if (!finaldone) {
        finaldone = 1;
        if (*final_rel) {
          finalfd = beneath(final_root, final_rel);
          if (finalfd < 0)
            capture = 1;
          else
            nonblock(finalfd);
        }
      }
      if (finalfd < 0 && !finished) {
        finished = 1;
        p32(sendbuf, 25);
        sendbuf[4] = 'F';
        p64(sendbuf + 5, seq++);
        p32(sendbuf + 13, (uint32_t)exitcode);
        p32(sendbuf + 17, termsig);
        p32(sendbuf + 21, capture || (exitcode == -1 && termsig == 0));
        p32(sendbuf + 25, cleanup);
        sending = 29;
        sent = 0;
      }
    }
    if (finished && !sending)
      break;
    struct pollfd fds[5] = {
        {0, POLLIN, 0},
        {1, sending ? POLLOUT : 0, 0},
        {out[0], (!sending && waiting == UINT64_MAX) ? POLLIN : 0, 0},
        {err[0], (!sending && waiting == UINT64_MAX) ? POLLIN : 0, 0},
        {status[0], POLLIN, 0}};
    poll(fds, 5, 10);
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(0, control + cn, sizeof(control) - cn);
      if (n <= 0) {
        if (n == 0 || (errno != EAGAIN && errno != EINTR))
          peer = 0;
      } else {
        cn += n;
        while (cn >= 4) {
          uint32_t len = u32(control);
          if (len > 9 || len < 1) {
            peer = 0;
            break;
          }
          if (cn < len + 4)
            break;
          unsigned char op = control[4];
          if (op == 'G' && len == 1 && !started && !stopping &&
              !requested_stop && peer && !capture) {
            started = 1;
            writeall(gate[1], "G", 1);
            close(gate[1]);
          } else if (op == 'C' && len == 1) {
            capture |= !started;
            if (!stopping) {
              stopping = 1;
              stop_at = now_ms();
              kill(-group, SIGTERM);
            }
          } else if (op == 'A' && len == 9 && waiting != UINT64_MAX &&
                     u32(control + 5) == (uint32_t)(waiting >> 32) &&
                     u32(control + 9) == (uint32_t)waiting) {
            waiting = UINT64_MAX;
            last_ack = now_ms();
          } else {
            peer = 0;
          }
          memmove(control, control + 4 + len, cn - 4 - len);
          cn -= 4 + len;
        }
      }
    }
    if (sending && (fds[1].revents & POLLOUT)) {
      ssize_t n = write(1, sendbuf + sent, sending - sent);
      if (n > 0) {
        sent += n;
        if (sent == sending) {
          sending = 0;
          sent = 0;
          last_ack = now_ms();
        }
      } else if (n < 0 && errno != EAGAIN && errno != EINTR)
        peer = 0;
    }
    if (fds[1].revents & (POLLERR | POLLHUP))
      peer = 0;
    if (fds[4].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(status[0], xbuf + xn, 9 - xn);
      if (n > 0) {
        xn += n;
        if (xn == 9) {
          if (xbuf[0] == 'X') {
            exitcode = (int32_t)u32(xbuf + 1);
            termsig = u32(xbuf + 5);
          } else
            capture = 1;
          close(status[0]);
          status[0] = -1;
        }
      } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
        capture = 1;
        close(status[0]);
        status[0] = -1;
      }
    }
    if (!sending && waiting == UINT64_MAX) {
      int *fd = NULL;
      unsigned char tag = 0;
      if (finalfd >= 0) {
        fd = &finalfd;
        tag = 'L';
      } else if (out[0] >= 0 && (fds[2].revents & (POLLIN | POLLHUP))) {
        fd = &out[0];
        tag = 'O';
      } else if (err[0] >= 0 && (fds[3].revents & (POLLIN | POLLHUP))) {
        fd = &err[0];
        tag = 'E';
      }
      if (fd) {
        ssize_t n = read(*fd, sendbuf + 13, FRAME);
        if (n == 0) {
          close(*fd);
          *fd = -1;
        } else if (n > 0) {
          if ((uint64_t)used + n > budget) {
            capture = 1;
            close(*fd);
            *fd = -1;
          } else {
            used += n;
            p32(sendbuf, 9 + n);
            sendbuf[4] = tag;
            p64(sendbuf + 5, seq);
            waiting = seq++;
            sending = 13 + n;
            sent = 0;
            last_ack = now_ms();
          }
        } else if (errno != EAGAIN && errno != EINTR) {
          capture = 1;
          close(*fd);
          *fd = -1;
        }
      }
    }
    if (killed && now >= finish_at && !reaped) {
      cleanup = 1;
      peer = 0;
      break;
    }
  }
  /* No group signal here: anchor may already have been reaped. */
  return peer ? 0 : 3;
}
