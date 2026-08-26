## Invoked by erlang.mk's rebar3 patch via the pre-app target.
## Compiles native/io_uring_nif.c -> priv/io_uring_nif.so.

ERLANG_DIR ?= $(shell erl -eval 'io:format("~s", [code:root_dir()])' -noshell -s init stop)
ERL_INCLUDES = $(ERLANG_DIR)/usr/include

CC ?= gcc
CFLAGS += -std=c11 -O2 -fPIC -Wall -Wextra -I$(ERL_INCLUDES)
LDFLAGS += -shared -luring

SRC = native/io_uring_nif.c
OUT = priv/io_uring_nif.so

.PHONY: all
all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $(OUT)
