.PHONY: all build test eunit shell dialyzer clean run-file run-socket

REBAR3 := rebar3
STRACE := strace -f -e trace=io_uring_setup,io_uring_enter,io_uring_register

all: build

build:
	$(REBAR3) compile

test:
	$(REBAR3) ct

eunit:
	$(REBAR3) eunit

shell:
	$(REBAR3) shell

dialyzer:
	$(REBAR3) dialyzer

clean:
	$(REBAR3) clean
	rm -rf _build/
	rm -f priv/*.so

run-file: build
	$(STRACE) -o /tmp/trace_file.log \
	    erl -pa _build/default/lib/io_uring/ebin -noshell \
	    -eval "file_io:run(\"/tmp/io_uring_test.txt\"), halt()."
	grep io_uring /tmp/trace_file.log

run-socket: build
	$(STRACE) -o /tmp/trace.log \
	    rebar3 shell --eval \
	    "http_get:run(\"142.251.154.119\", 80, \"www.google.com\"), halt()."
	grep io_uring /tmp/trace.log


