# rebound: auto-restart binaries inside containers

A minimal process supervisor for Docker containers, written in C. Rebound
spawns a child process, forwards signals, reaps zombies, and restarts the
child on unexpected exits. It is designed to run as PID 1 inside a container.

## Benefits

- **Tiny footprint** — single static binary, under 50 KB with musl. No runtime
  dependencies, works in `FROM scratch` images.
- **Correct PID 1 behavior** — handles signal forwarding and zombie reaping so
  your application doesn't have to. Fixes the common Docker problem where
  SIGTERM is silently ignored because PID 1 has no default signal handlers.
- **Automatic crash recovery** — restarts the child on segfaults, assertion
  failures, and non-zero exits without external orchestration. Keeps your
  container running through transient failures.
- **Crash loop protection** — detects rapid restarts and backs off, preventing
  CPU spin when the child can't start.
- **Clean shutdown** — SIGTERM and SIGINT are forwarded and cause rebound to
  exit, so `docker stop` works as expected with no restart loop.
- **Zero configuration** — no config files, no environment variables. One
  binary, one flag (`-0`), done.
- **Transparent to the child** — signals are restored before exec, the child
  runs in its own process group, and stdout/stderr pass through untouched.
  The child doesn't know rebound is there.

## How it works

Rebound forks and execs the given command, then sits in a signal loop:

- **Signals** are forwarded to the child process (SIGTERM, SIGINT, SIGHUP,
  SIGUSR1, etc.).
- **Zombie processes** are reaped, including orphans re-parented to PID 1.
- **On child exit**, the restart decision depends on how the child exited:
  - Exit code 0 — stop (unless `-0` is given)
  - Killed by SIGTERM or SIGINT — stop
  - Any other exit (non-zero code, other signals) — restart the child
- **Crash loop protection** kicks in after 5 rapid failures, inserting a
  1-second delay between restarts.

## Usage

```
rebound [-0] <binary> [args...]
```

### Options

| Option                    | Description                                   |
|---------------------------|-----------------------------------------------|
| `-0`, `--restart-on-zero` | Also restart when the child exits with code 0 |

### Examples

Run a web server, restart on crash:

```sh
rebound /usr/bin/my-server --port 8080
```

Run a worker that should restart even on clean exit:

```sh
rebound -0 /usr/bin/batch-worker
```

Use as a Docker entrypoint:

```dockerfile
COPY rebound /usr/local/bin/rebound
ENTRYPOINT ["rebound"]
CMD ["my-server", "--port", "8080"]
```

## Building

### Prerequisites

- C11 compiler (gcc or clang)
- CMake 3.10+
- POSIX system (Linux, macOS)

### Build with CMake

```sh
mkdir build && cd build
cmake ..
cmake --build .
```

### Build options

| Option                   | Description                                             |
|--------------------------|---------------------------------------------------------|
| `-DBUILD_STATIC=ON`      | Static binary with the current compiler                 |
| `-DBUILD_MUSL_STATIC=ON` | Static binary with musl-gcc (for minimal Docker images) |

Example — static musl build:

```sh
cmake -DBUILD_MUSL_STATIC=ON ..
cmake --build .
```

### Build with Make

```sh
make            # dynamic build
make static     # static musl build (requires musl-gcc)
```

## Testing

Tests are written in Perl using `prove` (TAP harness).

```sh
# Via CMake/CTest
cd build
ctest --output-on-failure

# Directly with prove
prove -v t/
```

### Test files

| File            | Coverage                                                             |
|-----------------|----------------------------------------------------------------------|
| `t/exit_zero.t` | Exit code 0 handling, `-0` flag, exit code propagation               |
| `t/signals.t`   | Signal forwarding, SIGTERM/SIGINT shutdown, restart on crash signals |
| `t/failures.t`  | Restart on non-zero exit, crash loop protection, recovery            |

## Docker

Example Dockerfiles are provided in `examples/`:

| File                          | Description                                  |
|-------------------------------|----------------------------------------------|
| `examples/Dockerfile.musl`    | Static musl binary on Alpine                 |
| `examples/Dockerfile.scratch` | Static musl binary in a `FROM scratch` image |
| `examples/Dockerfile.libc`    | Dynamic glibc binary on Debian               |

Build an example:

```sh
docker build -f examples/Dockerfile.scratch -t rebound:scratch .
```

## Documentation

Generate reference documentation from source comments (requires
[NaturalDocs](https://www.naturaldocs.org/)):

```sh
cd build
cmake --build . --target docs
```

Output is written to `build/docs/`.

## Comparison with tini and gosu

|                       | rebound | tini | gosu            |
|-----------------------|---------|------|-----------------|
| PID 1 signal handling | Yes     | Yes  | No (execs away) |
| Zombie reaping        | Yes     | Yes  | No              |
| Signal forwarding     | Yes     | Yes  | No              |
| Restart on crash      | Yes     | No   | No              |
| User switching        | No      | No   | Yes             |

**tini** is a pure init — it runs a child, forwards signals, reaps zombies, and
exits when the child exits. **gosu** switches user and execs, removing itself
from the process tree. **rebound** adds restart-on-crash semantics on top of
tini-style PID 1 responsibilities.
