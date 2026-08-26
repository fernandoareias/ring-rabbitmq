-module(stress_test).
-author('Fernando Areias <nando.calheirosx@gmail.com>').
-export([run/2]).

run(N, Host) ->
    Req = iolist_to_binary([
        "GET / HTTP/1.0\r\n",
        "Host: ", Host, "\r\n",
        "User-Agent: Erlang-io_uring-StressTest\r\n",
        "Connection: close\r\n",
        "\r\n"
    ]),
    io:format("Enviando ~p requests para ~s...~n", [N, Host]),
    [begin
        spawn(fun() -> client_worker(Req) end),
        timer:sleep(10)
     end || _ <- lists:seq(1, N)],
    ok.

client_worker(Payload) ->
    ring_processor:send_request(Payload),
    receive
        {response, Bin} when is_binary(Bin) ->
            Size    = byte_size(Bin),
            Snippet = binary_part(Bin, 0, lists:min([80, Size])),
            io:format("Worker ~p recebeu ~p bytes: ~s~n", [self(), Size, Snippet]);
        {response, {error, Reason}} ->
            io:format("Worker ~p erro: ~p~n", [self(), Reason]);
        Any ->
            io:format("Worker ~p inesperado: ~p~n", [self(), Any])
    after 5000 ->
        io:format("Worker ~p timeout~n", [self()])
    end.
