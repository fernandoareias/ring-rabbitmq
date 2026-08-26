-module(io_uring_file).

-author('Fernando Areias <nando.calheirosx@gmail.com>').


-export([open/2, read/4, write/4]).

-define(O_RDONLY,  0).
-define(O_WRONLY,  1).
-define(O_RDWR,    2).
-define(O_CREAT,   8#100).   %% 64
-define(O_TRUNC,   8#1000).  %% 512
-define(O_APPEND,  8#2000).  %% 1024
-define(O_NONBLOCK,8#4000).  %% 2048

open(Path, Flags) ->
    OFlags = lists:foldl(fun flag/2, 0, Flags),
    io_uring:sys_open(Path, OFlags, 8#644).

read(Ring, Fd, Size, Offset) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {read, Fd, Size, Offset}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.

write(Ring, Fd, Data, Offset) when is_binary(Data) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {write, Fd, Data, Offset}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.


flag(rdonly,   Acc) -> Acc bor ?O_RDONLY;
flag(wronly,   Acc) -> Acc bor ?O_WRONLY;
flag(rdwr,     Acc) -> Acc bor ?O_RDWR;
flag(creat,    Acc) -> Acc bor ?O_CREAT;
flag(trunc,    Acc) -> Acc bor ?O_TRUNC;
flag(append,   Acc) -> Acc bor ?O_APPEND;
flag(nonblock, Acc) -> Acc bor ?O_NONBLOCK;
flag(_,        Acc) -> Acc.
