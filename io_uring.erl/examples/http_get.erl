-module(http_get).

-author('Fernando Areias <nando.calheirosx@gmail.com>').

-export([run/3]).

run(Ip, Port, Host) ->
    {ok, Ring} = io_uring:setup(64, 0),

    {ok, Fd} = io_uring_socket:tcp_socket(),
    io:format("socket fd: ~p~n", [Fd]),

    IpTuple = parse_ip(Ip),
    {ok, ConnRef} = io_uring_socket:connect(Ring, Fd, {IpTuple, Port}),
    {ok, 1} = io_uring:submit(Ring),
    {ok, ConnCqe} = io_uring:wait_cqe(Ring),
    ConnRef = io_uring:cqe_tag(ConnCqe),
    case io_uring:cqe_res(ConnCqe) of
        0 -> io:format("connected~n");
        E -> error({connect_failed, -E})
    end,
    ok = io_uring:cqe_seen(Ring, ConnCqe),

    Req = iolist_to_binary([
        "GET / HTTP/1.0\r\n",
        "Host: ", Host, "\r\n",
        "Connection: close\r\n",
        "\r\n"
    ]),
    {ok, SendRef} = io_uring_socket:send(Ring, Fd, Req),
    {ok, 1} = io_uring:submit(Ring),
    {ok, SendCqe} = io_uring:wait_cqe(Ring),
    SendRef = io_uring:cqe_tag(SendCqe),
    Sent = io_uring:cqe_res(SendCqe),
    io:format("sent ~p bytes~n", [Sent]),
    ok = io_uring:cqe_seen(Ring, SendCqe),

    Response = recv_loop(Ring, Fd, []),
    io:format("--- response (~p bytes) ---~n~s~n", [byte_size(Response), Response]),

    {ok, CloseRef} = io_uring_socket:close(Ring, Fd),
    {ok, 1} = io_uring:submit(Ring),
    {ok, CloseCqe} = io_uring:wait_cqe(Ring),
    CloseRef = io_uring:cqe_tag(CloseCqe),
    ok = io_uring:cqe_seen(Ring, CloseCqe),

    io_uring:teardown(Ring),
    ok.

recv_loop(Ring, Fd, Acc) ->
    {ok, RecvRef} = io_uring_socket:recv(Ring, Fd, 4096),
    {ok, 1}       = io_uring:submit(Ring),
    {ok, RecvCqe} = io_uring:wait_cqe(Ring),
    RecvRef        = io_uring:cqe_tag(RecvCqe),
    case io_uring:cqe_res(RecvCqe) of
        0 ->
            ok = io_uring:cqe_seen(Ring, RecvCqe),
            iolist_to_binary(lists:reverse(Acc));
        N when N < 0 ->
            ok = io_uring:cqe_seen(Ring, RecvCqe),
            error({recv_error, -N});
        _N ->
            {ok, Chunk} = io_uring:cqe_data(RecvCqe),
            ok = io_uring:cqe_seen(Ring, RecvCqe),
            recv_loop(Ring, Fd, [Chunk | Acc])
    end.

parse_ip(Ip) when is_tuple(Ip) -> Ip;
parse_ip(Ip) when is_list(Ip) ->
    Parts = string:tokens(Ip, "."),
    list_to_tuple([list_to_integer(P) || P <- Parts]).
