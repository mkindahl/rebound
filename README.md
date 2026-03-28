# rebound: auto-restart binaries inside containers

A minimal process supervisor for Docker containers, written in C. Rebound
spawns a child process, forwards signals, reaps zombies, and restarts the
child on unexpected exits. It is designed to run as PID 1 inside a container.

It is intended to be used when you have a process inside a constainer that need
to restart on failure. For example, if you have a control plan process inside a
container that is stateless and just need to restart on failure. Kubernetes can
normally handle restart of failing containers, but if you for some reason need
to have multiple processes inside a container and do not want to restart the
container if certain processes fails, you can use this.

A typical example is if you have a control plan process to control a database
server, such as a PostgreSQL process, but you do not want to restart the
container if the control plan process fails since that would restart the
database as well.

## Benefits

- **Tiny footprint** — single static binary, under 50 KB with `musl`. No runtime
  dependencies so it works also in `FROM scratch` images.

- **Correct PID 1 behavior** — handles signal forwarding and zombie reaping so
  your application doesn't have to. Fixes the common Docker problem where
  `SIGTERM` is silently ignored because PID 1 has no default signal handlers.

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

- **Signals** are forwarded to the child process (`SIGTERM`, `SIGINT`, `SIGHUP`,
  `SIGUSR1`, etc.).

- **Zombie processes** are reaped, including orphans re-parented to PID 1.

- **On child exit**, the restart decision depends on how the child exited:
  - Exit code 0 — stop (unless `-0` is given)
  - Killed by `SIGTERM` or `SIGINT` — stop
  - Any other exit (non-zero code, other signals) — restart the child

- **Crash loop protection** kicks in after 5 rapid failures, inserting a
  1-second delay between restarts.

## Usage

```
rebound [-0] [-g] [-q] <binary> [args...]
```

### Options

| Option                    | Description                                   |
|---------------------------|-----------------------------------------------|
| `-0`, `--restart-on-zero` | Also restart when the child exits with code 0 |
| `-g`, `--own-group`       | Place the child in its own process group      |
| `-q`, `--quiet`           | Suppress all log output                       |

### Process groups

By default, the child shares the parent's process group. This means
terminal-generated signals (Ctrl-C, Ctrl-Z) are delivered by the kernel to both
`rebound` process and the child simultaneously, which is the expected behavior
for interactive use.

With `-g`, the child is placed in its own process group via `setpgid`. This
is useful when:

- Running as PID 1 in a Docker container, where terminal signals are not
  relevant and you want `rebound` to have exclusive control over signal
  delivery to the child.

- The child uses `kill(0, ...)` to signal its own process tree, and you want
  to prevent that from accidentally reaching `rebound`.

- You plan to signal the entire child process tree at once (e.g., via
  `kill(-pid, sig)` from an external tool).

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
cmake -S . -B cmake-build
cmake --build cmake-build
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
ctest --output-on-failure --test-dir cmake-build

# Directly with prove
prove -v t/
```

### Test files

| File          | Coverage                                                             |
|---------------|----------------------------------------------------------------------|
| `exit_zero.t` | Exit code 0 handling, `-0` flag, exit code propagation               |
| `signals.t`   | Signal forwarding, SIGTERM/SIGINT shutdown, restart on crash signals |
| `failures.t`  | Restart on non-zero exit, crash loop protection, recovery            |

## Docker

### Pre-built images

Pre-built images are available on Docker Hub:

| Image                      | Description                                  |
|----------------------------|----------------------------------------------|
| `mkindahl/rebound:musl`    | Static musl binary on Alpine                 |
| `mkindahl/rebound:scratch` | Static musl binary in a `FROM scratch` image |
| `mkindahl/rebound:libc`    | Dynamic glibc binary on Debian               |

Version-specific tags are also available (e.g., `mkindahl/rebound:1.0.0-musl`).

### Using `rebound` in your own image

You can use the pre-built images in your own multi-stage build to copy `rebound`
into your application image:

```dockerfile
FROM mkindahl/rebound:musl AS rebound

FROM debian:bookworm-slim
COPY --from=rebound /usr/local/bin/rebound /usr/local/bin/rebound
COPY my-server /usr/local/bin/my-server
ENTRYPOINT ["rebound"]
CMD ["my-server", "--port", "8080"]
```

For Alpine-based images:

```dockerfile
FROM mkindahl/rebound:musl AS rebound

FROM alpine:3
COPY --from=rebound /usr/local/bin/rebound /usr/local/bin/rebound
RUN apk add --no-cache my-app
ENTRYPOINT ["rebound"]
CMD ["my-app"]
```

For minimal images where both `rebound` and your binary are statically linked:

```dockerfile
FROM mkindahl/rebound:scratch AS rebound

FROM scratch
COPY --from=rebound /rebound /rebound
COPY my-static-binary /my-app
ENTRYPOINT ["/rebound"]
CMD ["/my-app"]
```

### Building Dockerfiles from source

Example Dockerfiles are provided in `docker/`:

| File                 | Description                                  |
|----------------------|----------------------------------------------|
| `Dockerfile.musl`    | Static musl binary on Alpine                 |
| `Dockerfile.scratch` | Static musl binary in a `FROM scratch` image |
| `Dockerfile.libc`    | Dynamic glibc binary on Debian               |

Build an example:

```sh
docker build -f docker/Dockerfile.scratch -t rebound:scratch .
```

## Documentation

Generate reference documentation from source comments (requires
[NaturalDocs](https://www.naturaldocs.org/)):

```sh
cd cmake-build
cmake --build . --target docs
```

Output is written to `cmake-build/docs/`.
