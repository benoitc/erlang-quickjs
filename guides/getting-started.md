# Getting Started

This guide will help you get up and running with QuickJS, an embedded JavaScript engine for Erlang.

## Installation

Add `quickjs` to your `rebar.config` dependencies:

```erlang
{deps, [
    {quickjs, "1.1.0"}
]}.
```

Then fetch dependencies:

```bash
rebar3 get-deps
rebar3 compile
```

## Basic Usage

### Creating a Context

All JavaScript execution happens within a context. Create one with `new_context/0`:

```erlang
{ok, Ctx} = quickjs:new_context().
```

Contexts are isolated - variables and functions defined in one context are not visible in others.

### Evaluating JavaScript

Use `eval/2` to execute JavaScript code:

```erlang
{ok, 42} = quickjs:eval(Ctx, <<"21 * 2">>).
{ok, <<"hello">>} = quickjs:eval(Ctx, <<"'hello'">>).
{ok, true} = quickjs:eval(Ctx, <<"1 < 2">>).
```

### Cleaning Up

Contexts are automatically garbage collected, but you can explicitly destroy them:

```erlang
ok = quickjs:destroy_context(Ctx).
```

## Variable Bindings

Pass Erlang values to JavaScript using `eval/3`:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Simple bindings
{ok, 30} = quickjs:eval(Ctx, <<"x * y">>, #{x => 5, y => 6}).

%% Complex data structures
{ok, <<"Alice">>} = quickjs:eval(Ctx, <<"user.name">>, #{
    user => #{name => <<"Alice">>, age => 30}
}).

%% Arrays
{ok, 6} = quickjs:eval(Ctx, <<"nums.reduce(function(a,b){return a+b}, 0)">>, #{
    nums => [1, 2, 3]
}).
```

## Function Calls

Define JavaScript functions and call them from Erlang:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Define a function
{ok, _} = quickjs:eval(Ctx, <<"
    function greet(name) {
        return 'Hello, ' + name + '!';
    }
">>).

%% Call it
{ok, <<"Hello, World!">>} = quickjs:call(Ctx, greet, [<<"World">>]).

%% Call without arguments
{ok, _} = quickjs:eval(Ctx, <<"function now() { return Date.now(); }">>).
{ok, Timestamp} = quickjs:call(Ctx, now).
```

## Modules

Use CommonJS-style modules for code organization:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Register a module
ok = quickjs:register_module(Ctx, <<"math-utils">>, <<"
    exports.square = function(x) { return x * x; };
    exports.cube = function(x) { return x * x * x; };
">>).

%% Use the module
{ok, 25} = quickjs:eval(Ctx, <<"require('math-utils').square(5)">>).
{ok, 27} = quickjs:eval(Ctx, <<"require('math-utils').cube(3)">>).
```

## Next Steps

Now that you have the basics, explore more features:

- **[Event Framework](event-framework.html)** - Bidirectional communication between JavaScript and Erlang
- **[Erlang Functions](erlang-functions.html)** - Call Erlang functions from JavaScript
- **[CBOR Encoding](cbor-encoding.html)** - Binary serialization for efficient data transfer
- **[Metrics](metrics.html)** - Monitor memory usage and trigger garbage collection
