# ring-rabbitmq

This repository holds an experiment in wiring io_uring into RabbitMQ, aimed at cutting down the number of syscalls on the message write and read paths.

The idea is simple. RabbitMQ currently writes messages using `file:pwrite/2` and `file:write/2`, which costs one syscall per operation (or per call, in the writev case). With io_uring you can queue up several I/O operations and submit all of them with a single call into the kernel, and in SQPOLL mode you don't even need that, since a kernel thread watches the submission queue on its own. The point of this project was to measure how much that actually matters in practice, both for throughput and for latency.

## Repository layout

* [`io_uring.erl/`](io_uring.erl/) is a standalone library with Erlang NIF bindings for the Linux io_uring API. It has no dependency on RabbitMQ and can be used in any Erlang project that needs low level async I/O for files or sockets.
* [`rabbitmq-server/`](rabbitmq-server/) is a fork of RabbitMQ with a new adapter, `rabbit_io_uring.erl` (under `deps/rabbit/src`), used by the message store and by the classic queue index (v2) whenever io_uring is available on the kernel. When it isn't, the broker just falls back to the usual POSIX path.
* The `bench_*.sh` scripts and `bench_io_uring.escript`, at the root of the fork, compare the broker running with and without io_uring, and the results live under `bench-results-nvme/` (CSVs, plots, and an analysis notebook).
* [`SYSCALLS.md`](rabbitmq-server/SYSCALLS.md) documents how the syscall counts quoted in the benchmarks were obtained, separating what was directly measured with `strace` from what was derived from the code.

## io_uring.erl

A low level library with a single generic entry point, `prep/3`, which accepts operations like read, write, connect, accept, and their variants with fixed buffers and file descriptors (zero copy). On top of it sit two convenience modules, `io_uring_file` and `io_uring_socket`, so you don't have to build each operation by hand.

Requirements:

| Dependency | Version |
|---|---|
| Linux kernel | 5.1 or newer |
| liburing | 2.0 or newer (`liburing-dev`) |
| Erlang/OTP | 24 or newer |
| rebar3 | 3.20 or newer |

```sh
cd io_uring.erl
make build
```

Full API details, usage examples, and the list of supported operations are in the [library's own README](io_uring.erl/README.md).

## The adapter inside RabbitMQ

`rabbit_io_uring` lives at `rabbitmq-server/deps/rabbit/src/rabbit_io_uring.erl` and exposes higher level operations consumed by the rest of the broker:

* `writev/4` preps one SQE per binary in an iolist and submits everything at once, avoiding `iolist_to_binary` and the extra copy it implies.
* `pwritev/3` takes a list of `{Offset, Binary}` pairs and replaces the `file:pwrite/2` call used today in the classic queue and index v2 flush paths.
* `preadv/3` does a scatter gather read across multiple offsets in a single submission.
* `writev_fdatasync_async/4` chains an fdatasync after the writes without blocking, meant to be drained later with `drain_fdatasync/2`.

Kernel support for io_uring is checked once in `start/0` and cached in a `persistent_term`, so checking availability on every operation is essentially free. If the ring isn't available, the broker just falls back to the normal path, no extra configuration needed.

## Running the benchmarks

The scripts assume Erlang/OTP 27 (RabbitMQ 4.x doesn't start cleanly on newer builds because of a horus incompatibility with the OTP 29 compiler, detailed in `SYSCALLS.md`). Before running any benchmark you need to build the broker once, from `rabbitmq-server/`:

```sh
make dist
```

After that:

```sh
# compares io_uring against the baseline, one broker at a time
bash bench_broker.sh                  # 30s, 4 producers, 1 KB messages
bash bench_broker.sh 60 8 4096        # 60s, 8 producers, 4 KB messages

# brings up both brokers at the same time, interleaving pairs, to remove cold start
bash bench_statistical.sh

# measures consume throughput (preadv vs sequential pread)
bash bench_consumer.sh

# runs everything inside OTP 27 containers, useful if the host has a different Erlang version
bash bench_docker.sh build
bash bench_docker.sh
```

Raw results and generated plots end up under `bench-results-nvme/`, including a notebook (`bench_analyze.ipynb`) used for the statistical analysis.

## Project status

This is a research and experimentation project, not a production ready feature. The RabbitMQ fork keeps all of the original documentation under `rabbitmq-server/` (see `rabbitmq-server/README.md` and `rabbitmq-server/CONTRIBUTING.md` for how the broker itself works).

## License

The code under `io_uring.erl/` is MIT. The fork under `rabbitmq-server/` follows the project's original licenses (MPL 2.0 and Apache 2.0), available in `rabbitmq-server/LICENSE*`.
