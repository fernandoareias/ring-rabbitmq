-module(io_uring_socket).

-author('Fernando Areias <nando.calheirosx@gmail.com>').


-export([
    tcp_socket/0,
    udp_socket/0,
    connect/3,
    connect/4,
    send/3,
    send/4,
    recv/3,
    recv/4,
    accept/2,
    close/2
]).


tcp_socket() ->
    make_socket(tcp).

udp_socket() ->
    make_socket(udp).

connect(Ring, Fd, {_IP, _Port} = Addr) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {connect, Fd, Addr}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.

connect(Ring, Fd, {_IP, _Port} = Addr, Tag) ->
    case io_uring:prep(Ring, Tag, {connect, Fd, Addr}) of
        ok    -> {ok, Tag};
        Error -> Error
    end.

send(Ring, Fd, Data) when is_binary(Data) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {send, Fd, Data}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.

send(Ring, Fd, Data, Tag) when is_binary(Data) ->
    case io_uring:prep(Ring, Tag, {send, Fd, Data}) of
        ok    -> {ok, Tag};
        Error -> Error
    end.

recv(Ring, Fd, Size) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {recv, Fd, Size}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.

recv(Ring, Fd, Size, Tag) ->
    case io_uring:prep(Ring, Tag, {recv, Fd, Size}) of
        ok    -> {ok, Tag};
        Error -> Error
    end.

accept(Ring, Fd) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {accept, Fd}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.

close(Ring, Fd) ->
    Ref = make_ref(),
    case io_uring:prep(Ring, Ref, {close, Fd}) of
        ok    -> {ok, Ref};
        Error -> Error
    end.


make_socket(tcp) ->
    %% AF_INET=2, SOCK_STREAM=1, SOCK_NONBLOCK=2048
    case socket:open(inet, stream, tcp) of
        {ok, Sock} -> socket_to_fd(Sock);
        Error      -> Error
    end;
make_socket(udp) ->
    case socket:open(inet, dgram, udp) of
        {ok, Sock} -> socket_to_fd(Sock);
        Error      -> Error
    end.

socket_to_fd(Sock) ->
    case socket:getopt(Sock, otp, fd) of
        {ok, Fd} -> {ok, Fd};
        Error    -> socket:close(Sock), Error
    end.
