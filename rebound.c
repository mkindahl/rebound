/*
 * rebound - minimal process supervisor for Docker containers
 *
 * Spawns a child process via fork/exec, forwards signals, reaps zombies,
 * and restarts the child on unexpected exits. Suitable as PID 1.
 *
 * Usage: rebound [-0] [-g] <binary> [args...]
 *   -0  Also restart when child exits with code 0
 *   -g  Place the child in its own process group
 */

#define _POSIX_C_SOURCE 199309L

#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/wait.h>

#define RAPID_FAIL_THRESHOLD 5
#define RAPID_FAIL_WINDOW_NS 1000000000L /* 1 second */
#define RESTART_DELAY_NS 1000000000L     /* 1 second */

static const char* progname = "rebound";
static volatile pid_t child_pid = -1;
static sigset_t all_signals;
static sigset_t original_mask;
static bool restart_on_zero = false;
static bool own_group = false;
static bool got_term = false;
static int rapid_fail_count = 0;

static struct option long_options[] = {
    {"restart-on-zero", no_argument, NULL, '0'},
    {"own-group", no_argument, NULL, 'g'},
    {NULL, 0, NULL, 0}};

/*
 * Function: usage
 *
 * Prints usage information to stderr and exits with code 1.
 */
static void usage(void) {
  fprintf(stderr, "Usage: %s [-0] [-g] <binary> [args...]\n", progname);
  fprintf(stderr, "  -0  Also restart when child exits with code 0\n");
  fprintf(stderr, "  -g  Place the child in its own process group\n");
  exit(1);
}

/*
 * Function: setup_signals
 *
 * Blocks all catchable signals except hardware faults (SIGFPE, SIGILL,
 * SIGSEGV, SIGBUS, SIGABRT) using sigprocmask. Saves the original mask
 * for later restoration in child processes. Ignores SIGTTIN and SIGTTOU
 * to prevent blocking on tty operations when backgrounded.
 *
 * The blocked signals are later dequeued synchronously via sigtimedwait
 * in the main loop, avoiding async signal handler bugs.
 */
static void setup_signals(void) {
  struct sigaction sa;

  sigfillset(&all_signals);

  /* Do not block hardware fault signals — let them crash rebound */
  sigdelset(&all_signals, SIGFPE);
  sigdelset(&all_signals, SIGILL);
  sigdelset(&all_signals, SIGSEGV);
  sigdelset(&all_signals, SIGBUS);
  sigdelset(&all_signals, SIGABRT);

  /* Cannot be caught */
  sigdelset(&all_signals, SIGKILL);
  sigdelset(&all_signals, SIGSTOP);

  if (sigprocmask(SIG_BLOCK, &all_signals, &original_mask) < 0) {
    fprintf(stderr, "%s: sigprocmask: %s\n", progname, strerror(errno));
    exit(1);
  }

  /* Ignore SIGTTIN/SIGTTOU to prevent blocking on tty ops */
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = SIG_IGN;
  sigaction(SIGTTIN, &sa, NULL);
  sigaction(SIGTTOU, &sa, NULL);
}

/*
 * Function: restore_signals_in_child
 *
 * Restores the original signal mask and resets ignored signals to their
 * default disposition. Called in the child process after fork and before
 * exec, so the child starts with standard signal behavior.
 */
static void restore_signals_in_child(void) {
  struct sigaction sa;

  sigprocmask(SIG_SETMASK, &original_mask, NULL);

  /* Reset ignored signals to default */
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = SIG_DFL;
  sigaction(SIGTTIN, &sa, NULL);
  sigaction(SIGTTOU, &sa, NULL);
}

/*
 * Function: spawn_child
 *
 * Forks a new child process and execs the command specified in argv.
 * By default the child inherits the parent's process group. If own_group
 * is set, the child is placed in its own process group via setpgid for
 * signal isolation. Signal mask and dispositions are restored before exec.
 *
 * Parameters:
 *
 *   argv      - Null-terminated argument vector. argv[0] is the binary name,
 *               looked up via PATH (execvp).
 *   own_group - If non-zero, place the child in its own process group.
 *
 * Returns:
 *
 *   The child PID on success, or -1 if fork fails.
 */
static pid_t spawn_child(char** argv, int own_group) {
  pid_t pid = fork();

  if (pid < 0) {
    fprintf(stderr, "%s: fork: %s\n", progname, strerror(errno));
    return -1;
  }

  if (pid == 0) {
    /* Child */
    if (own_group)
      setpgid(0, 0);
    restore_signals_in_child();
    execvp(argv[0], argv);
    fprintf(stderr, "%s: exec %s: %s\n", progname, argv[0], strerror(errno));
    _exit(127);
  }

  return pid;
}

/*
 * Function: reap_zombies
 *
 * Reaps all waitable children using waitpid with WNOHANG. This handles
 * both the main child and any orphaned processes re-parented to PID 1.
 * Only the main child's exit status is recorded.
 *
 * Parameters:
 *
 *   main_child   - PID of the supervised child process.
 *   child_status - Output parameter. Set to the wait status of main_child
 *                  if it was reaped.
 *
 * Returns:
 *
 *   1 if main_child was reaped, 0 otherwise.
 */
static bool reap_zombies(pid_t main_child, int* child_status) {
  bool found_main = false;

  for (;;) {
    int status;
    pid_t pid = waitpid(-1, &status, WNOHANG);
    if (pid <= 0)
      break;
    if (pid == main_child) {
      *child_status = status;
      found_main = true;
    }
  }

  return found_main;
}

/*
 * Function: exit_code_from_status
 *
 * Converts a raw wait status to a shell-style exit code. Normal exits
 * return WEXITSTATUS (0-255). Signal deaths return 128 + signal number,
 * following the standard Unix convention.
 *
 * Parameters:
 *
 *   status - Raw wait status from waitpid.
 *
 * Returns:
 *
 *   The exit code as an integer.
 */
static int exit_code_from_status(int status) {
  if (WIFEXITED(status))
    return WEXITSTATUS(status);
  if (WIFSIGNALED(status))
    return 128 + WTERMSIG(status);
  return 1;
}

/*
 * Function: should_restart
 *
 * Determines whether the child should be restarted based on how it exited.
 * Does not restart if the child was killed by SIGTERM or SIGINT, or if it
 * exited normally with code 0 (unless restart_on_zero is set).
 * All other exits (non-zero codes, other signals) trigger a restart.
 *
 * Parameters:
 *
 *   status          - Raw wait status from waitpid.
 *   restart_on_zero - If non-zero, also restart when child exits with code 0.
 *
 * Returns:
 *
 *   true if the child should be restarted, false otherwise.
 */
static bool should_restart(int status, int restart_on_zero) {
  /* Killed by SIGTERM or SIGINT — do not restart */
  if (WIFSIGNALED(status)) {
    int sig = WTERMSIG(status);
    if (sig == SIGTERM || sig == SIGINT)
      return false;
    return true;
  }

  /* Normal exit */
  if (WIFEXITED(status)) {
    int code = WEXITSTATUS(status);
    if (code == 0 && !restart_on_zero)
      return false;
    return true;
  }

  return true;
}

/*
 * Function: parse_options
 *
 * Parses command-line options and returns a pointer to the remaining arguments.
 *
 * Parameters:
 *
 *   argc - Number of command-line arguments.
 *   argv - Array of command-line arguments.
 *
 * Returns:
 *
 *   A pointer to the array of remaining arguments.
 */
char** parse_options(int argc, char** argv) {
  int opt;

  if (argc > 0)
    progname = argv[0];

  while ((opt = getopt_long(argc, argv, "+0g", long_options, NULL)) != -1) {
    switch (opt) {
      case '0':
        restart_on_zero = true;
        break;
      case 'g':
        own_group = true;
        break;
      default:
        usage();
    }
  }

  if (optind >= argc)
    usage();

  return argv + optind;
}

int main(int argc, char** argv) {
  char** child_argv = parse_options(argc, argv);

  setup_signals();

  fprintf(stderr, "%s: starting %s\n", progname, child_argv[0]);

  for (;;) {
    struct timespec spawn_time;
    struct timespec ts = {.tv_sec = 1, .tv_nsec = 0};
    int child_status = 0;
    bool child_exited = false;

    clock_gettime(CLOCK_MONOTONIC, &spawn_time);

    child_pid = spawn_child(child_argv, own_group);
    if (child_pid < 0) {
      struct timespec delay = {.tv_sec = 1, .tv_nsec = 0};
      nanosleep(&delay, NULL);
      continue;
    }

    /* Main signal loop */
    while (!child_exited) {
      siginfo_t info;
      int sig = sigtimedwait(&all_signals, &info, &ts);

      if (sig < 0 && (errno == EAGAIN || errno == EINTR)) {
        child_exited = reap_zombies(child_pid, &child_status);
      } else if (sig > 0) {
        switch (sig) {
          case SIGCHLD:
            child_exited = reap_zombies(child_pid, &child_status);
            break;
          case SIGTERM:
          case SIGINT:
            got_term = true;
            /* FALLTHROUGH */
          default:
            kill(child_pid, sig);
            fprintf(stderr, "%s: received signal %d, forwarding to child\n",
                    progname, sig);
            break;
        }
      }
    }

    /* Child has exited */
    int code = exit_code_from_status(child_status);

    if (got_term) {
      fprintf(stderr, "%s: child (pid %d) exited, shutting down\n", progname,
              (int)child_pid);
      return code;
    }

    if (!should_restart(child_status, restart_on_zero)) {
      if (WIFSIGNALED(child_status))
        fprintf(stderr, "%s: child (pid %d) terminated by signal %d, exiting\n",
                progname, (int)child_pid, WTERMSIG(child_status));
      return code;
    }

    /* Crash loop protection */
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long elapsed_ns = (now.tv_sec - spawn_time.tv_sec) * 1000000000L +
                      (now.tv_nsec - spawn_time.tv_nsec);

    if (elapsed_ns < RAPID_FAIL_WINDOW_NS)
      rapid_fail_count++;
    else
      rapid_fail_count = 0;

    if (WIFSIGNALED(child_status))
      fprintf(stderr, "%s: child (pid %d) killed by signal %d, restarting\n",
              progname, (int)child_pid, WTERMSIG(child_status));
    else
      fprintf(stderr, "%s: child (pid %d) exited with status %d, restarting\n",
              progname, (int)child_pid, WEXITSTATUS(child_status));

    if (rapid_fail_count >= RAPID_FAIL_THRESHOLD) {
      struct timespec delay = {.tv_sec = 1, .tv_nsec = 0};
      fprintf(stderr, "%s: child failing rapidly, delaying restart\n",
              progname);
      nanosleep(&delay, NULL);
    }
  }

  return EXIT_SUCCESS;
}
