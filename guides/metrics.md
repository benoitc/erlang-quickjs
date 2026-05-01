# Metrics

Monitor memory usage and trigger garbage collection for QuickJS contexts.

## Overview

Each QuickJS context tracks memory metrics via a custom allocator:
- Current and peak heap usage
- Allocation/reallocation/free counts
- Garbage collection runs

## Memory Statistics

Use `get_memory_stats/1` to retrieve current metrics:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Do some work
{ok, _} = quickjs:eval(Ctx, <<"var data = []; for(var i=0; i<1000; i++) data.push(i);">>).

%% Get memory stats
{ok, Stats} = quickjs:get_memory_stats(Ctx).
```

### Available Metrics

| Key | Type | Description |
|-----|------|-------------|
| `heap_bytes` | `non_neg_integer()` | Current allocated bytes |
| `heap_peak` | `non_neg_integer()` | Peak memory usage |
| `alloc_count` | `non_neg_integer()` | Total allocation count |
| `realloc_count` | `non_neg_integer()` | Total reallocation count |
| `free_count` | `non_neg_integer()` | Total free count |
| `gc_runs` | `non_neg_integer()` | Number of GC runs triggered |

### Example Output

```erlang
{ok, #{
    heap_bytes => 45632,
    heap_peak => 52480,
    alloc_count => 156,
    realloc_count => 23,
    free_count => 89,
    gc_runs => 2
}} = quickjs:get_memory_stats(Ctx).
```

## Garbage Collection

Manually trigger QuickJS's garbage collector:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Create garbage
{ok, _} = quickjs:eval(Ctx, <<"
    for (var i = 0; i < 10000; i++) {
        var temp = {data: new Array(100)};
    }
">>).

%% Check memory before GC
{ok, Before} = quickjs:get_memory_stats(Ctx).
io:format("Before GC: ~p bytes~n", [maps:get(heap_bytes, Before)]).

%% Trigger GC
ok = quickjs:gc(Ctx).

%% Check memory after GC
{ok, After} = quickjs:get_memory_stats(Ctx).
io:format("After GC: ~p bytes~n", [maps:get(heap_bytes, After)]).
```

## Monitoring Memory Usage

### Simple Monitoring

```erlang
monitor_context(Ctx) ->
    {ok, Stats} = quickjs:get_memory_stats(Ctx),
    HeapBytes = maps:get(heap_bytes, Stats),
    HeapPeak = maps:get(heap_peak, Stats),
    io:format("Memory: ~.2f KB (peak: ~.2f KB)~n",
              [HeapBytes / 1024, HeapPeak / 1024]).
```

### Memory Threshold Alerts

```erlang
-define(MEMORY_THRESHOLD, 10 * 1024 * 1024). %% 10 MB

check_memory(Ctx) ->
    {ok, Stats} = quickjs:get_memory_stats(Ctx),
    case maps:get(heap_bytes, Stats) of
        Bytes when Bytes > ?MEMORY_THRESHOLD ->
            %% Try to reclaim memory
            ok = quickjs:gc(Ctx),
            {ok, NewStats} = quickjs:get_memory_stats(Ctx),
            case maps:get(heap_bytes, NewStats) of
                StillHigh when StillHigh > ?MEMORY_THRESHOLD ->
                    {warning, memory_high, StillHigh};
                Reclaimed ->
                    {ok, gc_helped, Reclaimed}
            end;
        Bytes ->
            {ok, normal, Bytes}
    end.
```

### Periodic Monitoring

```erlang
-module(context_monitor).
-behaviour(gen_server).

start_link(Ctx) ->
    gen_server:start_link(?MODULE, Ctx, []).

init(Ctx) ->
    timer:send_interval(60000, check_memory),  %% Every minute
    {ok, #{ctx => Ctx, last_stats => undefined}}.

handle_info(check_memory, #{ctx := Ctx} = State) ->
    {ok, Stats} = quickjs:get_memory_stats(Ctx),
    log_stats(Stats),
    {noreply, State#{last_stats => Stats}}.

log_stats(Stats) ->
    logger:info("QuickJS memory: ~p bytes, ~p allocs, ~p GC runs",
                [maps:get(heap_bytes, Stats),
                 maps:get(alloc_count, Stats),
                 maps:get(gc_runs, Stats)]).
```

## Best Practices

1. **Monitor long-running contexts** - Track memory over time to detect leaks
2. **GC before peak load** - Trigger GC during quiet periods
3. **Set thresholds** - Alert when memory exceeds expected limits
4. **Track allocation patterns** - High alloc/free counts may indicate inefficient code
5. **Compare peak vs current** - Large gaps suggest temporary memory spikes

## Error Handling

```erlang
%% Destroyed context
ok = quickjs:destroy_context(Ctx).
{error, invalid_context} = quickjs:get_memory_stats(Ctx).
{error, invalid_context} = quickjs:gc(Ctx).

%% Invalid context reference
{error, invalid_context} = quickjs:get_memory_stats(not_a_context).
```
