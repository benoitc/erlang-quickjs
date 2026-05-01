%%%-------------------------------------------------------------------
%%% @doc Benchmark runner for quickjs
%%%
%%% Provides infrastructure for running performance benchmarks and
%%% collecting metrics including throughput, latency percentiles,
%%% and memory usage.
%%%
%%% Usage:
%%%   rebar3 as bench eunit --module=quickjs_bench
%%%
%%% Or programmatically:
%%%   quickjs_bench:run_all().
%%%   quickjs_bench:run(eval_simple).
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(quickjs_bench).

-include_lib("eunit/include/eunit.hrl").

-export([
    run_all/0,
    run_all/1,
    run/1,
    run/2
]).

%% Benchmark definitions
-export([
    bench_eval_simple/1,
    bench_eval_complex/1,
    bench_eval_bindings_small/1,
    bench_eval_bindings_large/1,
    bench_call_no_args/1,
    bench_call_with_args/1,
    bench_call_many_args/1,
    bench_type_convert_simple/1,
    bench_type_convert_array/1,
    bench_type_convert_nested/1,
    bench_context_create/1,
    bench_module_require_cached/1,
    bench_concurrent_same_context/1,
    bench_concurrent_many_contexts/1,
    %% Erlang function registration benchmarks
    bench_register_function_simple/1,
    bench_register_function_complex_args/1,
    bench_register_function_nested/1,
    bench_register_function_many_calls/1,
    %% Event framework benchmarks
    bench_event_emit/1,
    bench_event_send/1,
    bench_console_log/1,
    %% CBOR benchmarks
    bench_cbor_encode_simple/1,
    bench_cbor_encode_complex/1,
    bench_cbor_decode_simple/1,
    bench_cbor_roundtrip/1
]).

-define(DEFAULT_OPTS, #{
    warmup_iterations => 100,
    iterations => 1000,
    output_format => console  % console | json | csv | all
}).

%%====================================================================
%% EUnit Test Generator
%%====================================================================

%% Smoke test - just verify benchmark infrastructure works
benchmark_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"benchmark infrastructure smoke test",
         {timeout, 60, fun() ->
             %% Just run a single quick benchmark to verify everything works
             {ok, Result} = run(eval_simple, #{
                 iterations => 10,
                 warmup_iterations => 5
             }),
             ?assert(maps:get(ops_per_sec, Result) > 0),
             ?assert(maps:get(mean_ms, Result) > 0)
         end}}
     ]}.

%%====================================================================
%% Public API
%%====================================================================

%% @doc Run all benchmarks with default options
-spec run_all() -> {ok, [map()]}.
run_all() ->
    run_all(?DEFAULT_OPTS).

%% @doc Run all benchmarks with custom options
-spec run_all(map()) -> {ok, [map()]}.
run_all(Opts) ->
    MergedOpts = maps:merge(?DEFAULT_OPTS, Opts),
    Benchmarks = [
        eval_simple,
        eval_complex,
        eval_bindings_small,
        eval_bindings_large,
        call_no_args,
        call_with_args,
        call_many_args,
        type_convert_simple,
        type_convert_array,
        type_convert_nested,
        context_create,
        module_require_cached,
        concurrent_same_context,
        concurrent_many_contexts,
        %% Erlang function registration
        register_function_simple,
        register_function_complex_args,
        register_function_nested,
        register_function_many_calls,
        %% Event framework
        event_emit,
        event_send,
        console_log,
        %% CBOR
        cbor_encode_simple,
        cbor_encode_complex,
        cbor_decode_simple,
        cbor_roundtrip
    ],
    Results = lists:map(fun(Name) ->
        {ok, Result} = run(Name, MergedOpts),
        Result
    end, Benchmarks),

    %% Print summary table
    print_summary(Results),

    %% Export results
    export_results(Results, MergedOpts),
    {ok, Results}.

%% @doc Run a single benchmark with default options
-spec run(atom()) -> {ok, map()}.
run(Name) ->
    run(Name, ?DEFAULT_OPTS).

%% @doc Run a single benchmark with custom options
-spec run(atom(), map()) -> {ok, map()}.
run(Name, Opts) ->
    MergedOpts = maps:merge(?DEFAULT_OPTS, Opts),
    io:format("~n=== Running benchmark: ~p ===~n", [Name]),

    try
        %% Get benchmark function
        BenchFun = get_bench_fun(Name),

        %% Run warmup
        WarmupIters = maps:get(warmup_iterations, MergedOpts),
        io:format("Warmup: ~p iterations...~n", [WarmupIters]),
        _ = run_iterations(BenchFun, WarmupIters, MergedOpts),

        %% Run actual benchmark
        Iterations = maps:get(iterations, MergedOpts),
        io:format("Running: ~p iterations...~n", [Iterations]),
        {Timings, OpCounts} = run_iterations(BenchFun, Iterations, MergedOpts),

        %% Calculate statistics
        Stats = calculate_stats(Name, Timings, OpCounts, MergedOpts),
        print_stats(Stats),

        {ok, Stats}
    catch
        E:R:ST ->
            io:format("Benchmark ~p failed: ~p:~p~n~p~n", [Name, E, R, ST]),
            {error, {E, R}}
    end.

%%====================================================================
%% Benchmark Implementations
%%====================================================================

%% Simple arithmetic expression evaluation
bench_eval_simple(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    try
        {ok, _} = quickjs:eval(Ctx, <<"1 + 2 * 3 - 4 / 2">>),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Complex JavaScript evaluation (function definition and loops)
bench_eval_complex(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Code = <<"
        function fibonacci(n) {
            if (n <= 1) return n;
            var a = 0, b = 1, c;
            for (var i = 2; i <= n; i++) {
                c = a + b;
                a = b;
                b = c;
            }
            return b;
        }
        fibonacci(20);
    ">>,
    try
        {ok, _} = quickjs:eval(Ctx, Code),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Eval with small bindings (5 variables)
bench_eval_bindings_small(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Bindings = #{
        a => 10,
        b => 20,
        c => 30,
        d => 40,
        e => 50
    },
    try
        {ok, _} = quickjs:eval(Ctx, <<"a + b + c + d + e">>, Bindings),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Eval with large bindings (50 variables)
bench_eval_bindings_large(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Bindings = maps:from_list([{list_to_atom("var" ++ integer_to_list(I)), I}
                               || I <- lists:seq(1, 50)]),
    Code = iolist_to_binary([
        "var sum = 0; ",
        [[io_lib:format("sum += var~p; ", [I])] || I <- lists:seq(1, 50)],
        "sum"
    ]),
    try
        {ok, _} = quickjs:eval(Ctx, Code, Bindings),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Function call with no arguments
bench_call_no_args(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function getTime() { return Date.now(); }">>),
    try
        {ok, _} = quickjs:call(Ctx, getTime),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Function call with 5 arguments
bench_call_with_args(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function sum5(a,b,c,d,e) { return a+b+c+d+e; }">>),
    try
        {ok, _} = quickjs:call(Ctx, sum5, [1, 2, 3, 4, 5]),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Function call with 20 arguments
bench_call_many_args(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Args = lists:seq(1, 20),
    ArgNames = string:join([io_lib:format("a~p", [I]) || I <- Args], ","),
    SumExpr = string:join([io_lib:format("a~p", [I]) || I <- Args], "+"),
    Code = iolist_to_binary(io_lib:format("function sum20(~s) { return ~s; }", [ArgNames, SumExpr])),
    {ok, _} = quickjs:eval(Ctx, Code),
    try
        {ok, _} = quickjs:call(Ctx, sum20, Args),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Simple type conversion (integer and string round-trip)
bench_type_convert_simple(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    try
        {ok, _} = quickjs:eval(Ctx, <<"x + ' ' + y">>, #{x => 12345, y => <<"hello">>}),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Large array conversion (1000 elements)
bench_type_convert_array(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Array = lists:seq(1, 1000),
    try
        {ok, _} = quickjs:eval(Ctx, <<"arr.length">>, #{arr => Array}),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Nested map/array conversion
bench_type_convert_nested(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    NestedData = #{
        users => [
            #{name => <<"Alice">>, age => 30, tags => [<<"admin">>, <<"user">>]},
            #{name => <<"Bob">>, age => 25, tags => [<<"user">>]},
            #{name => <<"Carol">>, age => 35, tags => [<<"admin">>, <<"moderator">>]}
        ],
        meta => #{
            version => 1,
            created => <<"2024-01-01">>
        }
    },
    try
        {ok, _} = quickjs:eval(Ctx, <<"JSON.stringify(data)">>, #{data => NestedData}),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Context creation overhead
bench_context_create(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    quickjs:destroy_context(Ctx),
    1.

%% Module require (cached - second+ calls)
bench_module_require_cached(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_module(Ctx, <<"math">>, <<"
        exports.add = function(a, b) { return a + b; };
        exports.multiply = function(a, b) { return a * b; };
    ">>),
    %% First require to cache it
    {ok, _} = quickjs:require(Ctx, <<"math">>),
    try
        %% Measure cached requires
        {ok, _} = quickjs:eval(Ctx, <<"require('math').add(1, 2)">>),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Concurrent access to same context (10 processes)
bench_concurrent_same_context(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>),
    NumProcs = 10,
    OpsPerProc = 10,
    Self = self(),

    try
        _Pids = [spawn_link(fun() ->
            lists:foreach(fun(N) ->
                {ok, _} = quickjs:call(Ctx, add, [N, N])
            end, lists:seq(1, OpsPerProc)),
            Self ! {done, P}
        end) || P <- lists:seq(1, NumProcs)],

        lists:foreach(fun(_) ->
            receive {done, _} -> ok end
        end, lists:seq(1, NumProcs)),

        NumProcs * OpsPerProc
    after
        quickjs:destroy_context(Ctx)
    end.

%% Concurrent with separate contexts (10 processes, each with own context)
bench_concurrent_many_contexts(_Opts) ->
    NumProcs = 10,
    OpsPerProc = 10,
    Self = self(),

    _Pids = [spawn_link(fun() ->
        {ok, Ctx} = quickjs:new_context(),
        {ok, _} = quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>),
        lists:foreach(fun(N) ->
            {ok, _} = quickjs:call(Ctx, add, [N, N])
        end, lists:seq(1, OpsPerProc)),
        quickjs:destroy_context(Ctx),
        Self ! {done, P}
    end) || P <- lists:seq(1, NumProcs)],

    lists:foreach(fun(_) ->
        receive {done, _} -> ok end
    end, lists:seq(1, NumProcs)),

    NumProcs * OpsPerProc.

%%--------------------------------------------------------------------
%% Erlang Function Registration Benchmarks
%%--------------------------------------------------------------------

%% Simple Erlang function call from JavaScript
bench_register_function_simple(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, double, fun([N]) -> N * 2 end),
    try
        {ok, _} = quickjs:eval(Ctx, <<"double(21)">>),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Erlang function with complex arguments (map, array)
bench_register_function_complex_args(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, process_data, fun([Data]) ->
        %% Just return the data back (tests serialization overhead)
        Data
    end),
    try
        {ok, _} = quickjs:eval(Ctx, <<"
            process_data({
                name: 'test',
                values: [1, 2, 3, 4, 5],
                nested: { a: 1, b: 2 }
            })
        ">>),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Nested Erlang function calls (tests trampoline overhead)
bench_register_function_nested(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, increment, fun([N]) -> N + 1 end),
    try
        %% Chain of 5 nested calls
        {ok, _} = quickjs:eval(Ctx, <<"increment(increment(increment(increment(increment(0)))))">>),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Many sequential Erlang function calls in one eval
bench_register_function_many_calls(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, add_one, fun([N]) -> N + 1 end),
    try
        %% 10 sequential calls
        {ok, _} = quickjs:eval(Ctx, <<"
            var sum = 0;
            for (var i = 0; i < 10; i++) {
                sum = add_one(sum);
            }
            sum
        ">>),
        10  % 10 Erlang function calls
    after
        quickjs:destroy_context(Ctx)
    end.

%%--------------------------------------------------------------------
%% Event Framework Benchmarks
%%--------------------------------------------------------------------

%% Erlang.emit() from JavaScript (requires handler)
bench_event_emit(_Opts) ->
    Self = self(),
    {ok, Ctx} = quickjs:new_context(#{handler => Self}),
    try
        {ok, _} = quickjs:eval(Ctx, <<"Erlang.emit('test', {value: 42})">>),
        %% Drain the message
        receive {quickjs, <<"test">>, _} -> ok after 100 -> ok end,
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% quickjs:send() to JavaScript callback
bench_event_send(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"
        var lastValue = null;
        Erlang.on('data', function(d) { lastValue = d; return 'ok'; });
    ">>),
    try
        {ok, _} = quickjs:send(Ctx, data, #{value => 42}),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% console.log() (requires handler)
bench_console_log(_Opts) ->
    Self = self(),
    {ok, Ctx} = quickjs:new_context(#{handler => Self}),
    try
        {ok, _} = quickjs:eval(Ctx, <<"console.log('benchmark message', 42)">>),
        %% Drain the message
        receive {quickjs, log, _} -> ok after 100 -> ok end,
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%%--------------------------------------------------------------------
%% CBOR Encoding/Decoding Benchmarks
%%--------------------------------------------------------------------

%% Simple CBOR encode (integer, string, small map)
bench_cbor_encode_simple(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Data = #{name => <<"test">>, value => 42, active => true},
    try
        {ok, _} = quickjs:cbor_encode(Ctx, Data),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Complex CBOR encode (nested structures, arrays)
bench_cbor_encode_complex(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Data = #{
        users => [
            #{name => <<"Alice">>, age => 30, scores => [95, 87, 92]},
            #{name => <<"Bob">>, age => 25, scores => [88, 91, 85]},
            #{name => <<"Carol">>, age => 35, scores => [92, 89, 94]}
        ],
        metadata => #{
            version => 1,
            created => <<"2024-01-01T00:00:00Z">>,
            tags => [<<"benchmark">>, <<"test">>, <<"cbor">>]
        }
    },
    try
        {ok, _} = quickjs:cbor_encode(Ctx, Data),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% Simple CBOR decode (pre-encoded data)
bench_cbor_decode_simple(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    %% Pre-encode the data once
    Data = #{name => <<"test">>, value => 42, active => true},
    {ok, CborBin} = quickjs:cbor_encode(Ctx, Data),
    try
        {ok, _} = quickjs:cbor_decode(Ctx, CborBin),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%% CBOR roundtrip (encode then decode)
bench_cbor_roundtrip(_Opts) ->
    {ok, Ctx} = quickjs:new_context(),
    Data = #{
        id => 12345,
        name => <<"benchmark">>,
        values => [256, 512, 1024],  %% > 255 to avoid iolist
        nested => #{inner => true}
    },
    try
        {ok, Bin} = quickjs:cbor_encode(Ctx, Data),
        {ok, _} = quickjs:cbor_decode(Ctx, Bin),
        1
    after
        quickjs:destroy_context(Ctx)
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

setup() ->
    ok.

cleanup(_) ->
    ok.

get_bench_fun(eval_simple) -> fun bench_eval_simple/1;
get_bench_fun(eval_complex) -> fun bench_eval_complex/1;
get_bench_fun(eval_bindings_small) -> fun bench_eval_bindings_small/1;
get_bench_fun(eval_bindings_large) -> fun bench_eval_bindings_large/1;
get_bench_fun(call_no_args) -> fun bench_call_no_args/1;
get_bench_fun(call_with_args) -> fun bench_call_with_args/1;
get_bench_fun(call_many_args) -> fun bench_call_many_args/1;
get_bench_fun(type_convert_simple) -> fun bench_type_convert_simple/1;
get_bench_fun(type_convert_array) -> fun bench_type_convert_array/1;
get_bench_fun(type_convert_nested) -> fun bench_type_convert_nested/1;
get_bench_fun(context_create) -> fun bench_context_create/1;
get_bench_fun(module_require_cached) -> fun bench_module_require_cached/1;
get_bench_fun(concurrent_same_context) -> fun bench_concurrent_same_context/1;
get_bench_fun(concurrent_many_contexts) -> fun bench_concurrent_many_contexts/1;
%% Erlang function registration
get_bench_fun(register_function_simple) -> fun bench_register_function_simple/1;
get_bench_fun(register_function_complex_args) -> fun bench_register_function_complex_args/1;
get_bench_fun(register_function_nested) -> fun bench_register_function_nested/1;
get_bench_fun(register_function_many_calls) -> fun bench_register_function_many_calls/1;
%% Event framework
get_bench_fun(event_emit) -> fun bench_event_emit/1;
get_bench_fun(event_send) -> fun bench_event_send/1;
get_bench_fun(console_log) -> fun bench_console_log/1;
%% CBOR
get_bench_fun(cbor_encode_simple) -> fun bench_cbor_encode_simple/1;
get_bench_fun(cbor_encode_complex) -> fun bench_cbor_encode_complex/1;
get_bench_fun(cbor_decode_simple) -> fun bench_cbor_decode_simple/1;
get_bench_fun(cbor_roundtrip) -> fun bench_cbor_roundtrip/1.

run_iterations(BenchFun, Iterations, Opts) ->
    run_iterations(BenchFun, Iterations, Opts, [], []).

run_iterations(_BenchFun, 0, _Opts, Timings, OpCounts) ->
    {lists:reverse(Timings), lists:reverse(OpCounts)};
run_iterations(BenchFun, N, Opts, Timings, OpCounts) ->
    {Time, OpCount} = timer:tc(fun() -> BenchFun(Opts) end),
    run_iterations(BenchFun, N - 1, Opts, [Time | Timings], [OpCount | OpCounts]).

calculate_stats(Name, Timings, OpCounts, _Opts) ->
    %% Convert microseconds to milliseconds
    TimingsMs = [T / 1000 || T <- Timings],
    Sorted = lists:sort(TimingsMs),

    TotalOps = lists:sum(OpCounts),
    TotalTimeMs = lists:sum(TimingsMs),
    TotalTimeSec = TotalTimeMs / 1000,

    Len = length(Sorted),

    #{
        name => Name,
        iterations => Len,
        total_ops => TotalOps,
        total_time_ms => TotalTimeMs,

        %% Throughput
        ops_per_sec => TotalOps / TotalTimeSec,

        %% Latency stats (in milliseconds)
        min_ms => lists:min(Sorted),
        max_ms => lists:max(Sorted),
        mean_ms => TotalTimeMs / Len,
        median_ms => percentile(Sorted, 50),

        %% Percentiles
        p50_ms => percentile(Sorted, 50),
        p75_ms => percentile(Sorted, 75),
        p90_ms => percentile(Sorted, 90),
        p95_ms => percentile(Sorted, 95),
        p99_ms => percentile(Sorted, 99),

        %% Standard deviation
        stddev_ms => stddev(TimingsMs),

        %% Timestamp
        timestamp => calendar:universal_time()
    }.

percentile(Sorted, P) ->
    Len = length(Sorted),
    Index = max(1, min(Len, round(Len * P / 100))),
    lists:nth(Index, Sorted).

stddev(Values) ->
    Len = length(Values),
    Mean = lists:sum(Values) / Len,
    Variance = lists:sum([(V - Mean) * (V - Mean) || V <- Values]) / Len,
    math:sqrt(Variance).

print_stats(Stats) ->
    #{
        name := Name,
        iterations := Iters,
        total_ops := TotalOps,
        ops_per_sec := OpsPerSec,
        mean_ms := Mean,
        p50_ms := P50,
        p95_ms := P95,
        p99_ms := P99,
        min_ms := Min,
        max_ms := Max
    } = Stats,

    io:format("~n--- Results for ~p ---~n", [Name]),
    io:format("  Iterations:    ~p~n", [Iters]),
    io:format("  Total ops:     ~p~n", [TotalOps]),
    io:format("  Throughput:    ~.2f ops/sec~n", [OpsPerSec]),
    io:format("  Latency:~n"),
    io:format("    Mean:        ~.3f ms~n", [Mean]),
    io:format("    P50:         ~.3f ms~n", [P50]),
    io:format("    P95:         ~.3f ms~n", [P95]),
    io:format("    P99:         ~.3f ms~n", [P99]),
    io:format("    Min:         ~.3f ms~n", [Min]),
    io:format("    Max:         ~.3f ms~n", [Max]),
    io:format("~n").

print_summary(Results) ->
    io:format("~n"),
    io:format("================================================================================~n"),
    io:format("                           BENCHMARK SUMMARY~n"),
    io:format("================================================================================~n"),
    io:format("~n"),
    io:format("~-30s ~12s ~10s ~10s ~10s~n",
              ["Benchmark", "Ops/sec", "Mean(ms)", "P95(ms)", "P99(ms)"]),
    io:format("~s~n", [string:copies("-", 76)]),
    lists:foreach(fun(Stats) ->
        #{
            name := Name,
            ops_per_sec := OpsPerSec,
            mean_ms := Mean,
            p95_ms := P95,
            p99_ms := P99
        } = Stats,
        io:format("~-30s ~12.1f ~10.3f ~10.3f ~10.3f~n",
                  [Name, OpsPerSec, Mean, P95, P99])
    end, Results),
    io:format("~s~n", [string:copies("-", 76)]),
    io:format("~n").

export_results(Results, Opts) ->
    Format = maps:get(output_format, Opts),
    case Format of
        console -> ok;
        json -> export_json(Results, "bench_results.json");
        csv -> export_csv(Results, "bench_results.csv");
        all ->
            export_json(Results, "bench_results.json"),
            export_csv(Results, "bench_results.csv")
    end.

export_json(Results, Filename) ->
    JsonResults = lists:map(fun(R) ->
        R#{
            name => atom_to_binary(maps:get(name, R), utf8),
            timestamp => iolist_to_binary(format_timestamp(maps:get(timestamp, R)))
        }
    end, Results),

    Data = #{
        benchmark_run => #{
            timestamp => iolist_to_binary(format_timestamp(calendar:universal_time())),
            results => JsonResults
        }
    },

    %% Use simple JSON encoding
    Json = encode_json(Data),
    file:write_file(Filename, Json),
    io:format("Results exported to: ~s~n", [Filename]).

export_csv(Results, Filename) ->
    Header = "name,iterations,total_ops,ops_per_sec,mean_ms,p50_ms,p95_ms,p99_ms,min_ms,max_ms,timestamp\n",

    Rows = lists:map(fun(R) ->
        io_lib:format("~s,~p,~p,~.2f,~.3f,~.3f,~.3f,~.3f,~.3f,~.3f,~s~n", [
            maps:get(name, R),
            maps:get(iterations, R),
            maps:get(total_ops, R),
            maps:get(ops_per_sec, R),
            maps:get(mean_ms, R),
            maps:get(p50_ms, R),
            maps:get(p95_ms, R),
            maps:get(p99_ms, R),
            maps:get(min_ms, R),
            maps:get(max_ms, R),
            format_timestamp(maps:get(timestamp, R))
        ])
    end, Results),

    file:write_file(Filename, [Header | Rows]),
    io:format("Results exported to: ~s~n", [Filename]).

format_timestamp({{Y, M, D}, {H, Mi, S}}) ->
    io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [Y, M, D, H, Mi, S]).

%% Simple JSON encoder (avoid external dependency)
encode_json(Map) when is_map(Map) ->
    Pairs = maps:fold(fun(K, V, Acc) ->
        Key = if is_atom(K) -> atom_to_binary(K, utf8); true -> K end,
        [io_lib:format("~s:~s", [encode_json(Key), encode_json(V)]) | Acc]
    end, [], Map),
    ["{", string:join(Pairs, ","), "}"];
encode_json(List) when is_list(List) ->
    Items = [encode_json(I) || I <- List],
    ["[", string:join(Items, ","), "]"];
encode_json(Bin) when is_binary(Bin) ->
    ["\"", Bin, "\""];
encode_json(Atom) when is_atom(Atom) ->
    ["\"", atom_to_binary(Atom, utf8), "\""];
encode_json(Int) when is_integer(Int) ->
    integer_to_binary(Int);
encode_json(Float) when is_float(Float) ->
    io_lib:format("~.6f", [Float]).
