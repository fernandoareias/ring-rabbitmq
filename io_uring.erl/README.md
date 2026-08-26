# io_uring.erl

Erlang NIF bindings for the Linux **io_uring** high-performance asynchronous I/O interface (available since Linux 5.1).

This library provides a single generic entry point (`prep/3`) for disk and network I/O, supported by high-level modules (`io_uring_file`, `io_uring_socket`) for ergonomic development.

## Requirements

| Dependency | Version |
|---|---|
| Linux kernel | ≥ 5.1 |
| liburing | ≥ 2.0 (`liburing-dev`) |
| Erlang/OTP | ≥ 24 |
| rebar3 | ≥ 3.20 |

### Dependencies Installation
* **Arch / CachyOS:** `pacman -S liburing`
* **Ubuntu / Debian:** `apt install liburing-dev`

## Build

```sh
make build
```

## Architecture

The data flow operates through the following layers:
1. **Application Layer:** `io_uring_file` / `io_uring_socket`
2. **Generic API:** `io_uring.erl`
3. **Native Interface:** `priv/io_uring_nif.so` (C NIF)
4. **Kernel:** Linux io_uring

## Core API (`io_uring`)

### Ring Lifecycle

* `setup(Entries, Flags)`: Initializes submission and completion rings.
* `teardown(Ring)`: Destroys the ring and frees resources.
* `sqpoll_flag()`: Returns the `IORING_SETUP_SQPOLL` flag value (`2`) for use with `setup/2`.
* `iopoll_flag()`: Returns the `IORING_SETUP_IOPOLL` flag value (`1`) for use with `setup/2`.

### Submission

* `prep(Ring, Tag, Op)`: Enqueues an asynchronous operation. The `Tag` correlates the completion.
* `submit(Ring)`: Flushes pending Submission Queue Entries (SQEs) to the kernel. Returns `{ok, NSubmitted}`.

### Completion

* `wait_cqe(Ring)`: Blocks until at least one completion event is available. Returns `{ok, Cqe}`.
* `cqe_tag(Cqe)`: Retrieves the correlation `Tag` from a completion.
* `cqe_res(Cqe)`: Returns the integer result (bytes transferred or `-errno`).
* `cqe_data(Cqe)`: Returns the data payload for `read` and `recv` operations.
* `cqe_seen(Ring, Cqe)`: Advances the ring head after processing a completion.

### File Descriptors

* `sys_open(Path, OFlags, Mode)`: Returns a raw file descriptor (fd) for io_uring operations.

### Fixed Buffers & Files (zero-copy optimization)

* `register_buffers(Ring, Buffers)`: Pre-registers a list of binaries as fixed I/O buffers.
* `unregister_buffers(Ring)`: Unregisters previously registered buffers.
* `register_files(Ring, Fds)`: Pre-registers a list of file descriptors.
* `unregister_files(Ring)`: Unregisters previously registered file descriptors.

### Supported Operations (`prep/3`)

| Operation | Equivalent Syscall |
|---|---|
| `{read, Fd, Size, Offset}` | `pread(2)` |
| `{write, Fd, Data, Offset}` | `pwrite(2)` |
| `{recv, Fd, Size}` | `recv(2)` |
| `{send, Fd, Data}` | `send(2)` |
| `{connect, Fd, {Addr, Port}}` | `connect(2)` |
| `{accept, Fd}` | `accept(2)` |
| `{close, Fd}` | `close(2)` |
| `{read_fixed, Fd, BufIdx, Size, Offset}` | `pread(2)` with registered buffer |
| `{write_fixed, Fd, BufIdx, Data, Offset}` | `pwrite(2)` with registered buffer |
| `{read_file, Fd, Size, Offset}` | `pread(2)` with registered fd |
| `{write_file, Fd, Data, Offset}` | `pwrite(2)` with registered fd |

## File API (`io_uring_file`)

* `open(Path, Flags)`: Opens a file and returns `{ok, Fd}`. Supported flags: `rdonly`, `wronly`, `rdwr`, `creat`, `trunc`, `append`, `nonblock`.
* `read(Ring, Fd, Size, Offset)`: Enqueues a read. Returns `{ok, Ref}`.
* `write(Ring, Fd, Data, Offset)`: Enqueues a write. `Data` must be a binary. Returns `{ok, Ref}`.

## Socket API (`io_uring_socket`)

* `tcp_socket()`: Creates a non-blocking TCP socket. Returns `{ok, Fd}`.
* `udp_socket()`: Creates a non-blocking UDP socket. Returns `{ok, Fd}`.
* `connect(Ring, Fd, {Addr, Port})`: Enqueues a connect. Returns `{ok, Ref}`.
* `connect(Ring, Fd, {Addr, Port}, Tag)`: Same as above with a custom tag.
* `send(Ring, Fd, Data)`: Enqueues a send. `Data` must be a binary. Returns `{ok, Ref}`.
* `send(Ring, Fd, Data, Tag)`: Same as above with a custom tag.
* `recv(Ring, Fd, Size)`: Enqueues a recv. Returns `{ok, Ref}`.
* `recv(Ring, Fd, Size, Tag)`: Same as above with a custom tag.
* `accept(Ring, Fd)`: Enqueues an accept. Returns `{ok, Ref}`.
* `close(Ring, Fd)`: Enqueues a close. Returns `{ok, Ref}`.

## Usage Pattern

```erlang
{ok, Ring} = io_uring:setup(64, 0),

{ok, Ref1} = io_uring_file:read(Ring, FileFd, 4096, 0),
{ok, Ref2} = io_uring_socket:send(Ring, SockFd, <<"ping">>),

{ok, 2} = io_uring:submit(Ring),

{ok, Cqe1} = io_uring:wait_cqe(Ring),
Ref1 = io_uring:cqe_tag(Cqe1),
Data = io_uring:cqe_data(Cqe1),
ok = io_uring:cqe_seen(Ring, Cqe1),

io_uring:teardown(Ring).
```

## Examples

| File | Description |
|---|---|
| [`examples/file_io.erl`](examples/file_io.erl) | File write/read roundtrip with tag correlation |
| [`examples/http_get.erl`](examples/http_get.erl) | Single HTTP GET over TCP |
| [`examples/stress_test.erl`](examples/stress_test.erl) | Concurrent HTTP load test with N workers |
| [`examples/ring_processor.erl`](examples/ring_processor.erl) | `gen_server` managing a shared ring with batch submission |

## License

MIT
