-module(file_io).

-author('Fernando Areias <nando.calheirosx@gmail.com>').

-export([run/1]).

run(Path) ->
    {ok, Ring} = io_uring:setup(64, 0),

    {ok, Fd} = io_uring_file:open(Path, [rdwr, creat, trunc]),
    io:format("fd: ~p  path: ~s~n", [Fd, Path]),

    Payload = <<"hello from io_uring!\n">>,
    {ok, WRef} = io_uring_file:write(Ring, Fd, Payload, 0),
    {ok, 1}    = io_uring:submit(Ring),
    {ok, WCqe} = io_uring:wait_cqe(Ring),
    WRef        = io_uring:cqe_tag(WCqe),
    Written     = io_uring:cqe_res(WCqe),
    ok          = io_uring:cqe_seen(Ring, WCqe),
    io:format("wrote ~p bytes~n", [Written]),

    {ok, RRef} = io_uring_file:read(Ring, Fd, byte_size(Payload), 0),
    {ok, 1}    = io_uring:submit(Ring),
    {ok, RCqe} = io_uring:wait_cqe(Ring),
    RRef        = io_uring:cqe_tag(RCqe),
    Read        = io_uring:cqe_res(RCqe),
    {ok, Data}  = io_uring:cqe_data(RCqe),
    ok          = io_uring:cqe_seen(Ring, RCqe),
    io:format("read ~p bytes: ~s~n", [Read, Data]),

    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}    = io_uring:submit(Ring),
    {ok, CCqe} = io_uring:wait_cqe(Ring),
    ok          = io_uring:cqe_seen(Ring, CCqe),

    io_uring:teardown(Ring),

    Payload = Data,
    io:format("roundtrip OK~n").
