# erlang-quickjs

[![CI](https://github.com/benoitc/erlang-quickjs/actions/workflows/ci.yml/badge.svg)](https://github.com/benoitc/erlang-quickjs/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/quickjs.svg)](https://hex.pm/packages/quickjs)

QuickJS JavaScript engine for Erlang.

This library embeds the [QuickJS-NG](https://github.com/quickjs-ng/quickjs) JavaScript engine (v0.14.0) as an Erlang NIF, allowing you to evaluate JavaScript code directly from Erlang.

## Features

- Execute JavaScript code from Erlang
- Bidirectional type conversion between Erlang and JavaScript
- Multiple isolated JavaScript contexts
- CommonJS module support
- **Execution timeouts to prevent infinite loops**
- **Event framework for JS ↔ Erlang communication**
- **Register Erlang functions callable from JavaScript**
- **console.log/info/warn/error/debug support**
- **Memory metrics and manual garbage collection**
- Thread-safe with automatic resource cleanup
- No external dependencies - QuickJS is embedded

## Requirements

- Erlang/OTP 24 or later
- CMake 3.10 or later
- C compiler (gcc, clang, or MSVC)

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {quickjs, {git, "https://github.com/benoitc/erlang-quickjs.git", {branch, "main"}}}
]}.
```

Then run:

```bash
rebar3 compile
```

## Quick Start

```erlang
%% Create a JavaScript context
{ok, Ctx} = quickjs:new_context().

%% Evaluate JavaScript code
{ok, 42} = quickjs:eval(Ctx, <<"21 * 2">>).
{ok, <<"hello">>} = quickjs:eval(Ctx, <<"'hello'">>).

%% Evaluate with variable bindings
{ok, 30} = quickjs:eval(Ctx, <<"x * y">>, #{x => 5, y => 6}).

%% Define and call functions
{ok, _} = quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>).
{ok, 7} = quickjs:call(Ctx, add, [3, 4]).

%% CommonJS modules
ok = quickjs:register_module(Ctx, <<"utils">>, <<"
    exports.greet = function(name) {
        return 'Hello, ' + name + '!';
    };
">>).
{ok, <<"Hello, World!">>} = quickjs:eval(Ctx, <<"require('utils').greet('World')">>).
```

## API Reference

- [Context Management](#context-management) | [Evaluation](#evaluation) | [Function Calls](#function-calls) | [CommonJS Modules](#commonjs-modules)
- [Event Framework](#event-framework) | [Erlang Functions](#erlang-functions) | [CBOR Encoding/Decoding](#cbor-encodingdecoding)
- [Utility](#utility) | [Metrics](#metrics)

### Context Management

#### `new_context() -> {ok, context()} | {error, term()}`

Create a new JavaScript context. Contexts are isolated - variables and functions defined in one context are not visible in others.

Contexts are automatically cleaned up when garbage collected, but you can also explicitly destroy them with `destroy_context/1`.

#### `new_context(Opts) -> {ok, context()} | {error, term()}`

Create a new JavaScript context with options.

Options:
- `handler => pid()`: Process to receive events from JavaScript. The handler will receive messages of the form `{quickjs, Type, Data}` where Type is a binary (e.g., `<<"custom">>`) or atom (for log events: `log`) and Data is the event payload.

```erlang
{ok, Ctx} = quickjs:new_context(#{handler => self()}),
{ok, _} = quickjs:eval(Ctx, <<"console.log('hello')">>),
receive
    {quickjs, log, #{level := info, message := <<"hello">>}} ->
        io:format("Got log message~n")
end.
```

#### `destroy_context(Ctx) -> ok | {error, term()}`

Explicitly destroy a JavaScript context. This is optional - contexts are automatically cleaned up on garbage collection. Calling destroy on an already-destroyed context is safe (idempotent).

### Evaluation

#### `eval(Ctx, Code) -> {ok, Value} | {error, term()}`

Evaluate JavaScript code and return the result of the last expression. Uses default timeout of 5000ms.

```erlang
{ok, 3} = quickjs:eval(Ctx, <<"1 + 2">>).
{ok, <<"hello">>} = quickjs:eval(Ctx, <<"'hello'">>).
{error, {js_error, _}} = quickjs:eval(Ctx, <<"throw 'oops'">>).
```

#### `eval(Ctx, Code, Timeout) -> {ok, Value} | {error, term()}`
#### `eval(Ctx, Code, Bindings) -> {ok, Value} | {error, term()}`

With an integer or `infinity` as third argument, sets execution timeout in milliseconds. With a map, sets variable bindings.

```erlang
%% With timeout (100ms)
{error, timeout} = quickjs:eval(Ctx, <<"while(true){}">>, 100).
{ok, 42} = quickjs:eval(Ctx, <<"21 * 2">>, 1000).
{ok, 42} = quickjs:eval(Ctx, <<"21 * 2">>, infinity).  %% No timeout

%% With bindings (uses default 5000ms timeout)
{ok, 30} = quickjs:eval(Ctx, <<"x * y">>, #{x => 5, y => 6}).
```

#### `eval(Ctx, Code, Bindings, Timeout) -> {ok, Value} | {error, term()}`

Evaluate with both variable bindings and explicit timeout.

```erlang
{ok, 30} = quickjs:eval(Ctx, <<"x * y">>, #{x => 5, y => 6}, 1000).
{error, timeout} = quickjs:eval(Ctx, <<"while(x){}">>, #{x => true}, 100).
```

### Function Calls

#### `call(Ctx, FunctionName) -> {ok, Value} | {error, term()}`

Call a global JavaScript function with no arguments. Uses default timeout of 5000ms.

```erlang
{ok, _} = quickjs:eval(Ctx, <<"function getTime() { return Date.now(); }">>).
{ok, Timestamp} = quickjs:call(Ctx, <<"getTime">>).
```

#### `call(Ctx, FunctionName, Timeout) -> {ok, Value} | {error, term()}`
#### `call(Ctx, FunctionName, Args) -> {ok, Value} | {error, term()}`

With an integer or `infinity` as third argument, sets execution timeout. With a list, passes arguments to the function.

```erlang
%% With timeout
{ok, _} = quickjs:eval(Ctx, <<"function slow() { while(true){} }">>).
{error, timeout} = quickjs:call(Ctx, slow, 100).

%% With args (uses default 5000ms timeout)
{ok, _} = quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>).
{ok, 7} = quickjs:call(Ctx, <<"add">>, [3, 4]).
{ok, 7} = quickjs:call(Ctx, add, [3, 4]).
```

#### `call(Ctx, FunctionName, Args, Timeout) -> {ok, Value} | {error, term()}`

Call a function with both arguments and explicit timeout.

```erlang
{ok, 7} = quickjs:call(Ctx, add, [3, 4], 1000).
{ok, 7} = quickjs:call(Ctx, add, [3, 4], infinity).  %% No timeout
```

### CommonJS Modules

#### `register_module(Ctx, ModuleId, Source) -> ok | {error, term()}`

Register a CommonJS module with source code. The module can then be loaded with `require/2` or via `require()` in JavaScript.

```erlang
ok = quickjs:register_module(Ctx, <<"math">>, <<"
    exports.add = function(a, b) { return a + b; };
    exports.multiply = function(a, b) { return a * b; };
">>).
```

#### `require(Ctx, ModuleId) -> {ok, Exports} | {error, term()}`

Load a CommonJS module and return its exports. Modules are cached - subsequent requires return the same exports object.

```erlang
{ok, Exports} = quickjs:require(Ctx, <<"math">>).
```

### Event Framework

The event framework enables bidirectional communication between JavaScript and Erlang.

#### `send(Ctx, Event, Data) -> {ok, Value} | ok | {error, term()}`

Send data to a registered JavaScript callback. If JavaScript code has registered a callback using `Erlang.on(event, fn)`, this function will call that callback with the provided data.

Returns `{ok, Result}` where Result is the return value of the callback, or `ok` if no callback is registered for the event.

```erlang
{ok, Ctx} = quickjs:new_context(),
%% JavaScript registers a callback
{ok, _} = quickjs:eval(Ctx, <<"
    var received = null;
    Erlang.on('data', function(d) { received = d; return 'got it'; });
">>),
%% Erlang sends data to the callback
{ok, <<"got it">>} = quickjs:send(Ctx, data, #{value => 42}),
{ok, #{<<"value">> := 42}} = quickjs:eval(Ctx, <<"received">>).
```

#### JavaScript API

The `Erlang` global object provides the following methods:

**`Erlang.emit(type, data)`** - Send an event to the Erlang handler process.

```javascript
Erlang.emit('custom_event', {key: 'value', count: 42});
```

The handler receives: `{quickjs, <<"custom_event">>, #{<<"key">> => <<"value">>, <<"count">> => 42}}`

**`Erlang.log(level, ...args)`** - Send a log message to the Erlang handler.

```javascript
Erlang.log('info', 'User logged in:', userId);
Erlang.log('warning', 'Rate limit exceeded');
Erlang.log('error', 'Connection failed:', error);
Erlang.log('debug', 'Request details:', request);
```

The handler receives: `{quickjs, log, #{level => info, message => <<"User logged in: 123">>}}`

**`Erlang.on(event, callback)`** - Register a callback for events from Erlang.

```javascript
Erlang.on('config_update', function(config) {
    applyConfig(config);
    return 'applied';
});
```

**`Erlang.off(event)`** - Unregister a callback.

```javascript
Erlang.off('config_update');
```

#### Console Object

A standard `console` object is available that wraps `Erlang.log`:

```javascript
console.log('Hello, world!');      // level: info
console.info('Information');        // level: info
console.warn('Warning message');    // level: warning
console.error('Error occurred');    // level: error
console.debug('Debug info');        // level: debug
```

#### Complete Example

```erlang
%% Create context with event handler
{ok, Ctx} = quickjs:new_context(#{handler => self()}),

%% Set up JavaScript callback
{ok, _} = quickjs:eval(Ctx, <<"
    var messages = [];
    Erlang.on('message', function(msg) {
        messages.push(msg);
        console.log('Received:', msg.text);
        return messages.length;
    });
">>),

%% Send from Erlang
{ok, 1} = quickjs:send(Ctx, message, #{text => <<"Hello">>}),
{ok, 2} = quickjs:send(Ctx, message, #{text => <<"World">>}),

%% Receive console.log events
receive {quickjs, log, #{message := <<"Received: Hello">>}} -> ok end,
receive {quickjs, log, #{message := <<"Received: World">>}} -> ok end,

%% Verify messages were stored
{ok, [#{<<"text">> := <<"Hello">>}, #{<<"text">> := <<"World">>}]} =
    quickjs:eval(Ctx, <<"messages">>).
```

### Erlang Functions

Register Erlang functions that can be called synchronously from JavaScript.

#### `register_function(Ctx, Name, Fun) -> ok | {error, term()}`

Register an Erlang function callable from JavaScript. The function receives a list of arguments passed from JavaScript.

Supports both anonymous functions and `{Module, Function}` tuples. The function must accept a single argument (the list of JS arguments).

```erlang
{ok, Ctx} = quickjs:new_context(),

%% Register with anonymous function
ok = quickjs:register_function(Ctx, greet, fun([Name]) ->
    <<"Hello, ", Name/binary, "!">>
end),
{ok, <<"Hello, World!">>} = quickjs:eval(Ctx, <<"greet('World')">>).

%% Register with {Module, Function} tuple
ok = quickjs:register_function(Ctx, my_func, {my_module, my_function}).
```

**Multiple Arguments:**

```erlang
ok = quickjs:register_function(Ctx, add, fun(Args) ->
    lists:sum(Args)
end),
{ok, 10} = quickjs:eval(Ctx, <<"add(1, 2, 3, 4)">>).
```

**Nested Calls (Erlang functions calling each other):**

```erlang
ok = quickjs:register_function(Ctx, double, fun([N]) -> N * 2 end),
{ok, _} = quickjs:eval(Ctx, <<"function quadruple(n) { return double(double(n)); }">>),
{ok, 20} = quickjs:eval(Ctx, <<"quadruple(5)">>).
```

**Error Handling:**

Erlang exceptions are converted to JavaScript errors:

```erlang
ok = quickjs:register_function(Ctx, fail, fun(_) ->
    error(something_bad)
end),
%% JavaScript can catch the error
{ok, _} = quickjs:eval(Ctx, <<"
    try {
        fail();
    } catch (e) {
        console.log('Caught:', e.message);
    }
">>).
```

**Note:** Registered functions are stored in the calling process's dictionary. The process that registers the function must also be the one that calls `eval/call`.

### CBOR Encoding/Decoding

QuickJS has built-in CBOR (Concise Binary Object Representation) support.

#### `cbor_encode(Ctx, Value) -> {ok, binary()} | {error, term()}`

Encode an Erlang value to CBOR binary. The value is first converted to a JavaScript value, then encoded to CBOR.

```erlang
{ok, Ctx} = quickjs:new_context(),
{ok, Bin} = quickjs:cbor_encode(Ctx, #{name => <<"Alice">>, age => 30}).
```

#### `cbor_decode(Ctx, Binary) -> {ok, Value} | {error, term()}`

Decode a CBOR binary to an Erlang value. The CBOR is decoded to a JavaScript value, then converted to Erlang.

```erlang
{ok, Decoded} = quickjs:cbor_decode(Ctx, Bin),
%% #{<<"name">> => <<"Alice">>, <<"age">> => 30}
```

CBOR type mappings follow the same rules as regular Erlang ↔ JavaScript type conversions.

### Utility

#### `info() -> {ok, string()}`

Get NIF information. Used to verify the NIF is loaded correctly.

### Metrics

#### `get_memory_stats(Ctx) -> {ok, Stats} | {error, term()}`

Get memory statistics for a JavaScript context. Returns a map with:

| Key | Description |
|-----|-------------|
| `heap_bytes` | Current allocated bytes in the QuickJS heap |
| `heap_peak` | Peak memory usage since context creation |
| `alloc_count` | Total number of allocations |
| `realloc_count` | Total number of reallocations |
| `free_count` | Total number of frees |
| `gc_runs` | Number of garbage collection runs triggered |

```erlang
{ok, Ctx} = quickjs:new_context(),
{ok, _} = quickjs:eval(Ctx, <<"var x = []; for(var i=0; i<1000; i++) x.push(i);">>),
{ok, Stats} = quickjs:get_memory_stats(Ctx),
io:format("Heap: ~p bytes, Peak: ~p bytes~n",
          [maps:get(heap_bytes, Stats), maps:get(heap_peak, Stats)]).
```

#### `gc(Ctx) -> ok | {error, term()}`

Trigger garbage collection on a JavaScript context. Forces QuickJS's mark-and-sweep garbage collector to run.

```erlang
{ok, Ctx} = quickjs:new_context(),
{ok, _} = quickjs:eval(Ctx, <<"var x = {}; x = null;">>),
ok = quickjs:gc(Ctx),
{ok, #{gc_runs := 1}} = quickjs:get_memory_stats(Ctx).
```

## Type Conversions

### Erlang to JavaScript

| Erlang | JavaScript |
|--------|------------|
| `integer()` | number |
| `float()` | number |
| `binary()` | string |
| `true` | true |
| `false` | false |
| `null` | null |
| `undefined` | undefined |
| other atoms | string |
| `list()` | array (or string if iolist) |
| `map()` | object |
| `tuple()` | array |

### JavaScript to Erlang

| JavaScript | Erlang |
|------------|--------|
| number (integer) | `integer()` |
| number (float) | `float()` |
| NaN | `nan` (atom) |
| Infinity | `infinity` (atom) |
| -Infinity | `neg_infinity` (atom) |
| string | `binary()` |
| true | `true` |
| false | `false` |
| null | `null` |
| undefined | `undefined` |
| array | `list()` |
| object | `map()` |

## Error Handling

JavaScript errors are returned as `{error, {js_error, Message}}` where `Message` is a binary containing the error message and stack trace.

```erlang
{error, {js_error, <<"ReferenceError: x is not defined", _/binary>>}} =
    quickjs:eval(Ctx, <<"x + 1">>).
```

Contexts remain usable after errors - you can continue to evaluate code in the same context.

## Thread Safety

All context operations are thread-safe. Multiple Erlang processes can share a context, though operations are serialized via a mutex. For maximum parallelism, create separate contexts for concurrent workloads.

## Resource Management

Contexts are managed as Erlang NIF resources with automatic cleanup:

- Contexts are garbage collected when no Erlang process holds a reference
- Multiple processes can share a context safely
- Explicit `destroy_context/1` is optional but can be used for immediate cleanup
- Reference counting ensures contexts are not destroyed while in use

## Benchmarks

Apple M4 Pro, Erlang/OTP 28, quickjs-ng v0.14.0, 1000 iterations per benchmark after a 100-iteration warmup.

### Core operations

| Benchmark | Ops/sec | Mean (ms) | P95 (ms) | P99 (ms) |
|---|--:|--:|--:|--:|
| eval_simple | 1,445 | 0.692 | 0.741 | 0.809 |
| eval_complex | 1,412 | 0.708 | 0.756 | 0.810 |
| eval_bindings_small (5 vars) | 1,445 | 0.692 | 0.757 | 0.816 |
| eval_bindings_large (50 vars) | 1,279 | 0.782 | 0.846 | 0.939 |
| call_no_args | 1,424 | 0.702 | 0.757 | 0.816 |
| call_with_args (5 args) | 1,429 | 0.700 | 0.733 | 0.783 |
| call_many_args (20 args) | 1,391 | 0.719 | 0.754 | 0.804 |
| type_convert_simple | 1,450 | 0.689 | 0.710 | 0.739 |
| type_convert_array (1000 elem) | 1,403 | 0.713 | 0.741 | 0.773 |
| type_convert_nested | 1,388 | 0.721 | 0.781 | 0.864 |
| context_create | 1,442 | 0.694 | 0.745 | 0.810 |
| module_require_cached | 1,399 | 0.715 | 0.761 | 0.802 |

### Erlang function registration

| Benchmark | Ops/sec | Mean (ms) | P95 (ms) | P99 (ms) |
|---|--:|--:|--:|--:|
| register_function_simple | 1,402 | 0.713 | 0.752 | 0.845 |
| register_function_complex_args | 1,373 | 0.728 | 0.773 | 1.180 |
| register_function_nested (5 calls) | 1,350 | 0.741 | 0.790 | 0.854 |
| register_function_many_calls (10) | 11,969 | 0.835 | 0.926 | 1.163 |

### Event framework

| Benchmark | Ops/sec | Mean (ms) | P95 (ms) | P99 (ms) |
|---|--:|--:|--:|--:|
| event_emit | 1,247 | 0.802 | 0.860 | 0.921 |
| event_send | 1,424 | 0.702 | 0.738 | 0.786 |
| console_log | 1,242 | 0.805 | 0.856 | 0.914 |

### CBOR

| Benchmark | Ops/sec | Mean (ms) | P95 (ms) | P99 (ms) |
|---|--:|--:|--:|--:|
| cbor_encode_simple | 1,353 | 0.739 | 0.783 | 0.837 |
| cbor_encode_complex | 1,175 | 0.851 | 0.901 | 0.993 |
| cbor_decode_simple | 1,187 | 0.843 | 1.029 | 1.100 |
| cbor_roundtrip | 1,139 | 0.878 | 1.107 | 1.332 |

The CBOR codec is a JS shim, not a native C path; it lags duktape's built-in CBOR by roughly 35% on this micro-bench. The other operations sit ~15-25% behind duktape on per-call latency in exchange for full ES2023 support.

### Concurrency

| Benchmark | Ops/sec | Mean (ms) | P95 (ms) | P99 (ms) |
|---|--:|--:|--:|--:|
| concurrent_same_context (10 procs) | 98,859 | 1.012 | 1.234 | 1.334 |
| concurrent_many_contexts (10 procs) | 22,321 | 4.480 | 4.763 | 5.111 |

Run benchmarks yourself:

```bash
./run_bench.sh                  # all
./run_bench.sh eval_simple      # one
./run_bench.sh --smoke          # quick validation
```

## Security Considerations

When running untrusted JavaScript code, be aware of these limitations:

### Execution Timeouts

All `eval` and `call` functions support execution timeouts to prevent infinite loops:

```erlang
%% Default timeout is 5000ms
{error, timeout} = quickjs:eval(Ctx, <<"while(true){}">>, 100).

%% Use infinity for no timeout (only for trusted code)
{ok, _} = quickjs:eval(Ctx, Code, infinity).
```

After a timeout, the context remains valid and can be reused for subsequent calls.

### Memory Limits

QuickJS does not have built-in memory limits. JavaScript code can allocate unbounded memory.

**Recommendation**: For untrusted code, monitor memory usage via `get_memory_stats/1` and destroy contexts that exceed limits.

### Event Types

Event types from `Erlang.emit()` are returned as binaries to prevent atom table exhaustion. Known log levels (`debug`, `info`, `warning`, `error`) remain atoms for ergonomics.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

QuickJS-NG is licensed under the MIT License.
