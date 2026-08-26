-module(ring_processor).
-author('Fernando Areias <nando.calheirosx@gmail.com>').

-behaviour(gen_server).

-export([start_link/2, send_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    ring,
    addr,
    batch_count = 0         :: non_neg_integer(),
    timer_ref   = undefined :: reference() | undefined,
    requests    = #{}       :: #{integer() => tuple()}
}).

-define(THRESHOLD, 50).
-define(FLUSH_TIMEOUT, 10).
-define(RECV_SIZE, 4096).

start_link(Ip, Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Ip, Port], []).

send_request(Data) ->
    gen_server:cast(?MODULE, {enqueue, Data, self()}).
init([Ip, Port]) ->
    {ok, Ring} = io_uring:setup(4096, 0),
    Self = self(),
    spawn_link(fun() -> completion_loop(Ring, Self) end),
    IpTuple = parse_ip(Ip),
    io:format("[INIT] ring_processor ~p:~p ring=~p~n", [Ip, Port, Ring]),
    {ok, #state{ring = Ring, addr = {IpTuple, Port}}}.

handle_call(_Req, _From, State) -> {reply, ok, State}.

handle_cast({enqueue, Data, ClientPid},
            State = #state{ring = Ring, addr = Addr,
                           batch_count = BC, timer_ref = TRef,
                           requests = Reqs}) ->
    {ok, Fd}    = io_uring_socket:tcp_socket(),
    ReqId       = erlang:unique_integer([positive]),
    {ok, ReqId} = io_uring_socket:connect(Ring, Fd, Addr, ReqId),
    NewReqs     = Reqs#{ReqId => {connecting, ClientPid, Fd, Data}},
    NewCount    = BC + 1,
    NewState = if
        NewCount >= ?THRESHOLD ->
            cancel_timer(TRef),
            io_uring:submit(Ring),
            State#state{requests = NewReqs, batch_count = 0, timer_ref = undefined};
        BC =:= 0 ->
            NewTRef = erlang:send_after(?FLUSH_TIMEOUT, self(), flush_batch),
            State#state{requests = NewReqs, batch_count = NewCount, timer_ref = NewTRef};
        true ->
            State#state{requests = NewReqs, batch_count = NewCount}
    end,
    {noreply, NewState};

handle_cast({completed, ReqId, Res, Data},
            State = #state{ring = Ring, requests = Reqs}) ->
    case maps:get(ReqId, Reqs, undefined) of
        undefined ->
            {noreply, State};

        {connecting, ClientPid, Fd, ReqData} when Res =:= 0 ->
            {ok, ReqId} = io_uring_socket:send(Ring, Fd, ReqData, ReqId),
            io_uring:submit(Ring),
            {noreply, State#state{requests = Reqs#{ReqId => {sending, ClientPid, Fd, ReqData}}}};

        {connecting, ClientPid, Fd, _ReqData} ->
            ClientPid ! {response, {error, {connect_failed, -Res}}},
            close_and_submit(Ring, Fd),
            {noreply, State#state{requests = maps:remove(ReqId, Reqs)}};

        {sending, ClientPid, Fd, Remaining} when Res > 0 ->
            case binary:part(Remaining, Res, byte_size(Remaining) - Res) of
                <<>> ->
                    {ok, ReqId} = io_uring_socket:recv(Ring, Fd, ?RECV_SIZE, ReqId),
                    io_uring:submit(Ring),
                    {noreply, State#state{requests = Reqs#{ReqId => {receiving, ClientPid, Fd, []}}}};
                Rest ->
                    {ok, ReqId} = io_uring_socket:send(Ring, Fd, Rest, ReqId),
                    io_uring:submit(Ring),
                    {noreply, State#state{requests = Reqs#{ReqId => {sending, ClientPid, Fd, Rest}}}}
            end;

        {sending, ClientPid, Fd, _Remaining} ->
            ClientPid ! {response, {error, {send_failed, -Res}}},
            close_and_submit(Ring, Fd),
            {noreply, State#state{requests = maps:remove(ReqId, Reqs)}};

        {receiving, ClientPid, Fd, _Acc} when Res < 0 ->
            ClientPid ! {response, {error, {recv_failed, -Res}}},
            close_and_submit(Ring, Fd),
            {noreply, State#state{requests = maps:remove(ReqId, Reqs)}};

        {receiving, ClientPid, Fd, Acc} when Res =:= 0 ->
            Response = iolist_to_binary(lists:reverse(Acc)),
            ClientPid ! {response, Response},
            close_and_submit(Ring, Fd),
            {noreply, State#state{requests = maps:remove(ReqId, Reqs)}};

        {receiving, ClientPid, Fd, Acc} ->
            Chunk = normalize_chunk(Data),
            {ok, ReqId} = io_uring_socket:recv(Ring, Fd, ?RECV_SIZE, ReqId),
            io_uring:submit(Ring),
            {noreply, State#state{requests = Reqs#{ReqId => {receiving, ClientPid, Fd, [Chunk | Acc]}}}}
    end.

handle_info(flush_batch, State = #state{ring = Ring, batch_count = BC}) ->
    if BC > 0 -> io_uring:submit(Ring); true -> ok end,
    {noreply, State#state{batch_count = 0, timer_ref = undefined}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{ring = Ring, requests = Reqs}) ->
    maps:foreach(fun
        (_, {connecting, Pid, Fd, _})  -> Pid ! {response, {error, shutdown}}, close_and_submit(Ring, Fd);
        (_, {sending,    Pid, Fd, _})  -> Pid ! {response, {error, shutdown}}, close_and_submit(Ring, Fd);
        (_, {receiving,  Pid, Fd, _})  -> Pid ! {response, {error, shutdown}}, close_and_submit(Ring, Fd)
    end, Reqs),
    io_uring:teardown(Ring),
    ok.

completion_loop(Ring, ParentPid) ->
    case io_uring:wait_cqe(Ring) of
        {ok, Cqe} ->
            Tag  = io_uring:cqe_tag(Cqe),
            Res  = io_uring:cqe_res(Cqe),
            Data = io_uring:cqe_data(Cqe),
            gen_server:cast(ParentPid, {completed, Tag, Res, Data}),
            io_uring:cqe_seen(Ring, Cqe),
            completion_loop(Ring, ParentPid);
        _ ->
            completion_loop(Ring, ParentPid)
    end.

normalize_chunk({ok, B}) when is_binary(B) -> B;
normalize_chunk(B) when is_binary(B)       -> B.

close_and_submit(Ring, Fd) ->
    io_uring_socket:close(Ring, Fd),
    io_uring:submit(Ring).

cancel_timer(undefined) -> ok;
cancel_timer(Ref)       -> erlang:cancel_timer(Ref).

parse_ip(Ip) when is_tuple(Ip) -> Ip;
parse_ip(Ip) when is_list(Ip) ->
    Parts = string:tokens(Ip, "."),
    list_to_tuple([list_to_integer(P) || P <- Parts]).
