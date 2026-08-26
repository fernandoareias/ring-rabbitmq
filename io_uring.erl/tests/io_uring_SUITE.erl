-module(io_uring_SUITE).

-author('Fernando Areias <nando.calheirosx@gmail.com>').

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, suite/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([test_nif_loads/1, test_setup_teardown/1,
         test_setup_invalid_entries/1, test_teardown_via_gc/1]).

-export([test_submit_empty/1, test_prep_unknown_op/1]).

-export([test_sys_open/1, test_write_tag_correlation/1,
         test_write_bytes_returned/1, test_read_write_roundtrip/1,
         test_cqe_data_undefined_for_write/1, test_batch_submit/1,
         test_file_module_open/1]).

-export([test_tcp_socket_open/1, test_connect_refused/1]).

suite() ->
    [{timetrap, {seconds, 30}}].

groups() ->
    [
        {nif,        [sequence], [test_nif_loads, test_setup_teardown,
                                  test_setup_invalid_entries, test_teardown_via_gc]},
        {submission, [sequence], [test_submit_empty, test_prep_unknown_op]},
        {file_io,    [sequence], [test_sys_open, test_write_tag_correlation,
                                  test_write_bytes_returned, test_read_write_roundtrip,
                                  test_cqe_data_undefined_for_write, test_batch_submit,
                                  test_file_module_open]},
        {socket_io,  [sequence], [test_tcp_socket_open, test_connect_refused]}
    ].

all() ->
    [{group, nif}, {group, submission}, {group, file_io}, {group, socket_io}].

init_per_suite(Config) ->
    ok = application:ensure_started(io_uring),
    TmpFile = filename:join(?config(priv_dir, Config), "io_uring_test.bin"),
    [{tmpfile, TmpFile} | Config].

end_per_suite(Config) ->
    file:delete(?config(tmpfile, Config)),
    ok = application:stop(io_uring),
    ok.

init_per_group(_, Config) -> Config.
end_per_group(_, _Config) -> ok.

init_per_testcase(Name, Config) when Name =:= test_tcp_socket_open;
                                     Name =:= test_connect_refused ->
    case io_uring_socket:tcp_socket() of
        {ok, Fd} ->
            {ok, Ring} = io_uring:setup(64, 0),
            [{ring, Ring}, {sock_fd, Fd} | Config];
        {error, _} ->
            {skip, "socket unavailable"}
    end;
init_per_testcase(test_nif_loads, Config) ->
    Config;
init_per_testcase(test_setup_teardown, Config) ->
    Config;
init_per_testcase(test_setup_invalid_entries, Config) ->
    Config;
init_per_testcase(test_teardown_via_gc, Config) ->
    Config;
init_per_testcase(_, Config) ->
    {ok, Ring} = io_uring:setup(64, 0),
    [{ring, Ring} | Config].

end_per_testcase(test_nif_loads, _Config) -> ok;
end_per_testcase(test_setup_teardown, _Config) -> ok;
end_per_testcase(test_setup_invalid_entries, _Config) -> ok;
end_per_testcase(test_teardown_via_gc, _Config) -> ok;
end_per_testcase(Name, Config) when Name =:= test_tcp_socket_open;
                                    Name =:= test_connect_refused ->
    Ring = ?config(ring, Config),
    io_uring:teardown(Ring),
    ok;
end_per_testcase(_, Config) ->
    io_uring:teardown(?config(ring, Config)),
    ok.


test_nif_loads(_Config) ->
    {module, io_uring} = code:ensure_loaded(io_uring),
    ok.

test_setup_teardown(_Config) ->
    {ok, Ring} = io_uring:setup(64, 0),
    ok = io_uring:teardown(Ring).

test_setup_invalid_entries(_Config) ->
    {error, _} = io_uring:setup(0, 0),
    ok.

test_teardown_via_gc(_Config) ->
    {ok, _Ring} = io_uring:setup(64, 0),
    erlang:garbage_collect(),
    ok.


test_submit_empty(Config) ->
    Ring = ?config(ring, Config),
    {ok, 0} = io_uring:submit(Ring),
    ok.

test_prep_unknown_op(Config) ->
    Ring = ?config(ring, Config),
    Result = io_uring:prep(Ring, make_ref(), {bogus_op, 0}),
    true = (Result =:= {error, unknown_op}) orelse (Result =:= {error, badarg}),
    ok.


test_sys_open(Config) ->
    Ring    = ?config(ring, Config),
    TmpFile = ?config(tmpfile, Config),
    Flags   = 2 bor 8#100 bor 8#1000,  %% O_RDWR | O_CREAT | O_TRUNC
    {ok, Fd} = io_uring:sys_open(TmpFile, Flags, 8#644),
    true = is_integer(Fd) andalso Fd >= 0,
    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1} = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, Cqe),
    ok.

test_write_tag_correlation(Config) ->
    Ring    = ?config(ring, Config),
    TmpFile = ?config(tmpfile, Config),
    {ok, Fd} = io_uring_file:open(TmpFile, [rdwr, creat, trunc]),
    {ok, Ref} = io_uring_file:write(Ring, Fd, <<"tag_test">>, 0),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    Ref       = io_uring:cqe_tag(Cqe),
    ok        = io_uring:cqe_seen(Ring, Cqe),
    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, CCqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, CCqe),
    ok.

test_write_bytes_returned(Config) ->
    Ring    = ?config(ring, Config),
    TmpFile = ?config(tmpfile, Config),
    Data    = <<"hello">>,
    {ok, Fd}  = io_uring_file:open(TmpFile, [rdwr, creat, trunc]),
    {ok, _}   = io_uring_file:write(Ring, Fd, Data, 0),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    5         = io_uring:cqe_res(Cqe),
    ok        = io_uring:cqe_seen(Ring, Cqe),
    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, CCqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, CCqe),
    ok.

test_read_write_roundtrip(Config) ->
    Ring    = ?config(ring, Config),
    TmpFile = ?config(tmpfile, Config),
    Payload = <<"roundtrip_payload">>,
    {ok, Fd} = io_uring_file:open(TmpFile, [rdwr, creat, trunc]),

    %% write
    {ok, _}    = io_uring_file:write(Ring, Fd, Payload, 0),
    {ok, 1}    = io_uring:submit(Ring),
    {ok, WCqe} = io_uring:wait_cqe(Ring),
    Written    = io_uring:cqe_res(WCqe),
    ok         = io_uring:cqe_seen(Ring, WCqe),
    Written    = byte_size(Payload),

    %% read back
    {ok, _}    = io_uring_file:read(Ring, Fd, byte_size(Payload), 0),
    {ok, 1}    = io_uring:submit(Ring),
    {ok, RCqe} = io_uring:wait_cqe(Ring),
    {ok, Data} = io_uring:cqe_data(RCqe),
    ok         = io_uring:cqe_seen(Ring, RCqe),
    Payload    = Data,

    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, CCqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, CCqe),
    ok.

test_cqe_data_undefined_for_write(Config) ->
    Ring    = ?config(ring, Config),
    TmpFile = ?config(tmpfile, Config),
    {ok, Fd}  = io_uring_file:open(TmpFile, [rdwr, creat, trunc]),
    {ok, _}   = io_uring_file:write(Ring, Fd, <<"x">>, 0),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    undefined = io_uring:cqe_data(Cqe),
    ok        = io_uring:cqe_seen(Ring, Cqe),
    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, CCqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, CCqe),
    ok.

test_batch_submit(Config) ->
    Ring    = ?config(ring, Config),
    TmpFile = ?config(tmpfile, Config),
    {ok, Fd} = io_uring_file:open(TmpFile, [rdwr, creat, trunc]),

    {ok, Ref1} = io_uring_file:write(Ring, Fd, <<"batch1">>, 0),
    {ok, Ref2} = io_uring_file:write(Ring, Fd, <<"batch2">>, 6),
    {ok, 2}    = io_uring:submit(Ring),

    {Tags, Ress} = collect_cqes(Ring, 2, [], []),
    true = lists:member(Ref1, Tags),
    true = lists:member(Ref2, Tags),
    true = lists:all(fun(R) -> R > 0 end, Ress),

    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, CCqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, CCqe),
    ok.

test_file_module_open(Config) ->
    TmpFile = ?config(tmpfile, Config),
    {ok, Fd} = io_uring_file:open(TmpFile, [rdwr, creat, trunc]),
    true = is_integer(Fd) andalso Fd >= 0,
    Ring = ?config(ring, Config),
    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, Cqe),
    ok.

%% ---- socket_io group ----

test_tcp_socket_open(Config) ->
    Ring = ?config(ring, Config),
    Fd   = ?config(sock_fd, Config),
    true = is_integer(Fd) andalso Fd >= 0,
    ok = io_uring:prep(Ring, close_ref, {close, Fd}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    ok = io_uring:cqe_seen(Ring, Cqe),
    ok.

test_connect_refused(Config) ->
    Ring = ?config(ring, Config),
    Fd   = ?config(sock_fd, Config),
    {ok, Ref} = io_uring_socket:connect(Ring, Fd, {{127,0,0,1}, 1}),
    {ok, 1}   = io_uring:submit(Ring),
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    Ref       = io_uring:cqe_tag(Cqe),
    Res       = io_uring:cqe_res(Cqe),
    true      = Res < 0,
    ok        = io_uring:cqe_seen(Ring, Cqe),
    ok.


collect_cqes(_Ring, 0, Tags, Ress) ->
    {Tags, Ress};
collect_cqes(Ring, N, Tags, Ress) ->
    {ok, Cqe} = io_uring:wait_cqe(Ring),
    Tag = io_uring:cqe_tag(Cqe),
    Res = io_uring:cqe_res(Cqe),
    ok  = io_uring:cqe_seen(Ring, Cqe),
    collect_cqes(Ring, N - 1, [Tag | Tags], [Res | Ress]).
