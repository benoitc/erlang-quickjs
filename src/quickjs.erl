%%% -*- erlang -*-
%%%
%%% Copyright 2026 Benoit Chesneau
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0

%% @doc QuickJS JavaScript engine for Erlang (powered by quickjs-ng).
-module(quickjs).

-export([
    info/0,
    new_context/0,
    new_context/1,
    destroy_context/1,
    eval/2,
    eval/3,
    eval/4,
    call/2,
    call/3,
    call/4,
    register_module/3,
    require/2,
    send/3,
    register_function/3,
    cbor_encode/2,
    cbor_decode/2,
    get_memory_stats/1,
    gc/1
]).

-export_type([context/0, js_value/0, bindings/0, context_opts/0, memory_stats/0]).

-opaque context() :: reference().

-type context_opts() :: #{handler => pid()}.

-type js_value() :: integer()
                  | float()
                  | binary()
                  | true
                  | false
                  | null
                  | undefined
                  | list(js_value())
                  | #{binary() | atom() => js_value()}.

-type bindings() :: #{atom() | binary() => term()}.

-type memory_stats() :: #{
    heap_bytes := non_neg_integer(),
    heap_peak := non_neg_integer(),
    alloc_count := non_neg_integer(),
    realloc_count := non_neg_integer(),
    free_count := non_neg_integer(),
    gc_runs := non_neg_integer()
}.

-compile(no_native).
-on_load(on_load/0).

-define(nif_stub, nif_stub_error(?LINE)).
-define(DEFAULT_TIMEOUT, 5000).

nif_stub_error(Line) ->
    erlang:nif_error({nif_not_loaded, module, ?MODULE, line, Line}).

-spec on_load() -> ok | {error, any()}.
on_load() ->
    SoName = case code:priv_dir(?MODULE) of
        {error, bad_name} ->
            case code:which(?MODULE) of
                Filename when is_list(Filename) ->
                    filename:join([filename:dirname(Filename), "../priv", "quickjs"]);
                _ ->
                    filename:join("../priv", "quickjs")
            end;
        Dir ->
            filename:join(Dir, "quickjs")
    end,
    case erlang:load_nif(SoName, application:get_all_env(quickjs)) of
        ok -> ok;
        {error, _} -> ok %% NIF not built yet; stubs raise nif_not_loaded on call
    end.

-spec info() -> {ok, string()}.
info() ->
    nif_info().

-spec new_context() -> {ok, context()} | {error, term()}.
new_context() ->
    nif_new_context().

-spec new_context(context_opts()) -> {ok, context()} | {error, term()}.
new_context(Opts) when is_map(Opts) ->
    nif_new_context_opts(Opts).

-spec destroy_context(context()) -> ok | {error, term()}.
destroy_context(Ctx) ->
    nif_destroy_context(Ctx).

-spec eval(context(), iodata()) -> {ok, js_value()} | {error, term()}.
eval(Ctx, Code) ->
    eval(Ctx, Code, ?DEFAULT_TIMEOUT).

-spec eval(context(), iodata(), bindings() | timeout()) -> {ok, js_value()} | {error, term()}.
eval(Ctx, Code, Timeout) when is_integer(Timeout); Timeout =:= infinity ->
    eval_loop(Ctx, nif_eval(Ctx, Code, timeout_to_ms(Timeout)));
eval(Ctx, Code, Bindings) when is_map(Bindings) ->
    eval(Ctx, Code, Bindings, ?DEFAULT_TIMEOUT).

-spec eval(context(), iodata(), bindings(), timeout()) -> {ok, js_value()} | {error, term()}.
eval(Ctx, Code, Bindings, Timeout) when is_map(Bindings), (is_integer(Timeout) orelse Timeout =:= infinity) ->
    eval_loop(Ctx, nif_eval_bindings(Ctx, Code, Bindings, timeout_to_ms(Timeout))).

-spec call(context(), iodata() | atom()) -> {ok, js_value()} | {error, term()}.
call(Ctx, FunctionName) ->
    call(Ctx, FunctionName, []).

-spec call(context(), iodata() | atom(), [term()] | timeout()) -> {ok, js_value()} | {error, term()}.
call(Ctx, FunctionName, Timeout) when is_integer(Timeout); Timeout =:= infinity ->
    eval_loop(Ctx, nif_call(Ctx, FunctionName, [], timeout_to_ms(Timeout)));
call(Ctx, FunctionName, Args) when is_list(Args) ->
    call(Ctx, FunctionName, Args, ?DEFAULT_TIMEOUT).

-spec call(context(), iodata() | atom(), [term()], timeout()) -> {ok, js_value()} | {error, term()}.
call(Ctx, FunctionName, Args, Timeout) when is_list(Args), (is_integer(Timeout) orelse Timeout =:= infinity) ->
    eval_loop(Ctx, nif_call(Ctx, FunctionName, Args, timeout_to_ms(Timeout))).

-spec register_module(context(), iodata() | atom(), iodata()) -> ok | {error, term()}.
register_module(Ctx, ModuleId, Source) ->
    nif_register_module(Ctx, ModuleId, Source).

-spec require(context(), iodata() | atom()) -> {ok, js_value()} | {error, term()}.
require(Ctx, ModuleId) ->
    nif_require(Ctx, ModuleId).

-spec send(context(), atom() | iodata(), term()) -> {ok, js_value()} | ok | {error, term()}.
send(Ctx, Event, Data) ->
    nif_send(Ctx, Event, Data).

-spec cbor_encode(context(), term()) -> {ok, binary()} | {error, term()}.
cbor_encode(Ctx, Value) ->
    nif_cbor_encode(Ctx, Value).

-spec cbor_decode(context(), binary()) -> {ok, js_value()} | {error, term()}.
cbor_decode(Ctx, Binary) ->
    nif_cbor_decode(Ctx, Binary).

-spec get_memory_stats(context()) -> {ok, memory_stats()} | {error, term()}.
get_memory_stats(Ctx) ->
    nif_get_memory_stats(Ctx).

-spec gc(context()) -> ok | {error, term()}.
gc(Ctx) ->
    nif_gc(Ctx).

-spec register_function(context(), atom() | binary(), Fun | {atom(), atom()}) -> ok | {error, term()}
    when Fun :: fun(([term()]) -> term()).
register_function(Ctx, Name, Fun) when is_function(Fun, 1) ->
    Key = make_function_key(Ctx, Name),
    put(Key, Fun),
    nif_register_erlang_function(Ctx, Name);
register_function(Ctx, Name, {M, F}) when is_atom(M), is_atom(F) ->
    Fun = fun(Args) -> apply(M, F, [Args]) end,
    register_function(Ctx, Name, Fun).

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

-spec timeout_to_ms(timeout()) -> non_neg_integer().
timeout_to_ms(infinity) -> 0;
timeout_to_ms(Ms) when is_integer(Ms), Ms >= 0 -> Ms.

-spec eval_loop(context(), term()) -> {ok, js_value()} | {error, term()}.
eval_loop(_Ctx, {ok, Value}) ->
    {ok, Value};
eval_loop(_Ctx, {error, _} = Error) ->
    Error;
eval_loop(Ctx, {call_erlang, FuncName, Args}) ->
    Result = dispatch_erlang_call(Ctx, FuncName, Args),
    ok = nif_call_complete(Ctx, Result),
    eval_loop(Ctx, nif_eval_resume(Ctx)).

-spec dispatch_erlang_call(context(), atom(), list()) -> term().
dispatch_erlang_call(Ctx, FuncName, Args) ->
    case get_registered_function(Ctx, FuncName) of
        {ok, Fun} ->
            try Fun(Args)
            catch
                error:Reason -> {error, {erlang_error, Reason}};
                throw:Reason -> {error, {erlang_throw, Reason}};
                exit:Reason  -> {error, {erlang_exit, Reason}}
            end;
        error ->
            {error, {undefined_function, FuncName}}
    end.

-spec get_registered_function(context(), atom()) -> {ok, fun(([term()]) -> term())} | error.
get_registered_function(Ctx, FuncName) ->
    Key = make_function_key(Ctx, FuncName),
    case get(Key) of
        undefined -> error;
        Fun -> {ok, Fun}
    end.

-spec make_function_key(context(), atom() | binary()) -> {quickjs_function, integer(), atom()}.
make_function_key(Ctx, Name) when is_binary(Name) ->
    make_function_key(Ctx, binary_to_atom(Name, utf8));
make_function_key(Ctx, Name) when is_atom(Name) ->
    {quickjs_function, erlang:phash2(Ctx), Name}.

%% ---------------------------------------------------------------------------
%% NIF stubs
%% ---------------------------------------------------------------------------

nif_info() -> ?nif_stub.
nif_new_context() -> ?nif_stub.
nif_new_context_opts(_Opts) -> ?nif_stub.
nif_destroy_context(_Ctx) -> ?nif_stub.
nif_eval(_Ctx, _Code, _TimeoutMs) -> ?nif_stub.
nif_eval_bindings(_Ctx, _Code, _Bindings, _TimeoutMs) -> ?nif_stub.
nif_call(_Ctx, _FunctionName, _Args, _TimeoutMs) -> ?nif_stub.
nif_register_module(_Ctx, _ModuleId, _Source) -> ?nif_stub.
nif_require(_Ctx, _ModuleId) -> ?nif_stub.
nif_send(_Ctx, _Event, _Data) -> ?nif_stub.
nif_register_erlang_function(_Ctx, _Name) -> ?nif_stub.
nif_call_complete(_Ctx, _Result) -> ?nif_stub.
nif_eval_resume(_Ctx) -> ?nif_stub.
nif_cbor_encode(_Ctx, _Value) -> ?nif_stub.
nif_cbor_decode(_Ctx, _Binary) -> ?nif_stub.
nif_get_memory_stats(_Ctx) -> ?nif_stub.
nif_gc(_Ctx) -> ?nif_stub.
