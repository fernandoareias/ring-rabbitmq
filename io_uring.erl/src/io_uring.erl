-module(io_uring).

-author('Fernando Areias <nando.calheirosx@gmail.com>').

-export([setup/2, teardown/1]).
-export([sqpoll_flag/0, iopoll_flag/0]).
-export([sys_open/3]).
-export([prep/3, submit/1, wait_cqe/1, wait_n_cqes/2]).
-export([cqe_tag/1, cqe_res/1, cqe_data/1, cqe_seen/2]).
-export([register_buffers/2, unregister_buffers/1]).
-export([register_files/2, unregister_files/1]).

-on_load(init/0).

-define(APPNAME, io_uring).
-define(LIBNAME, io_uring_nif).

init() ->
    SoName = case code:priv_dir(?APPNAME) of
        {error, bad_name} ->
            Priv = filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]),
            filename:join(Priv, ?LIBNAME);
        Dir ->
            filename:join(Dir, ?LIBNAME)
    end,
    erlang:load_nif(SoName, 0).

not_loaded(Line) ->
    erlang:nif_error({nif_not_loaded, module, ?MODULE, line, Line}).

sqpoll_flag() -> 2.

iopoll_flag() -> 1.

setup(_Entries, _Flags) -> not_loaded(?LINE).

prep(_Ring, _Tag, _Op) -> not_loaded(?LINE).

submit(_Ring) -> not_loaded(?LINE).

wait_cqe(_Ring) -> not_loaded(?LINE).

%% Collects N CQEs in one dirty-scheduler call.
%% Returns {ok, [{Tag, Res, Data}]} where Data is {ok, Binary} for reads,
%% undefined for writes/closes.
-spec wait_n_cqes(term(), pos_integer()) ->
    {ok, [{term(), integer(), term()}]} | {error, integer()}.
wait_n_cqes(_Ring, _N) -> not_loaded(?LINE).

cqe_tag(_Cqe) -> not_loaded(?LINE).

cqe_res(_Cqe) -> not_loaded(?LINE).

cqe_data(_Cqe) -> not_loaded(?LINE).

cqe_seen(_Ring, _Cqe) -> not_loaded(?LINE).

teardown(_Ring) -> not_loaded(?LINE).

sys_open(_Path, _Flags, _Mode) -> not_loaded(?LINE).

register_buffers(_Ring, _Buffers) -> not_loaded(?LINE).

unregister_buffers(_Ring) -> not_loaded(?LINE).

register_files(_Ring, _Fds) -> not_loaded(?LINE).

unregister_files(_Ring) -> not_loaded(?LINE).
