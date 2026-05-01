# Erlang Functions

Call Erlang functions synchronously from JavaScript.

## Overview

Register Erlang functions to be callable from JavaScript. This enables:
- Extending JavaScript with Erlang capabilities
- Accessing Erlang libraries from JavaScript
- Building hybrid Erlang/JavaScript applications

## Registering Functions

Use `register_function/3` to make an Erlang function available in JavaScript:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Register an anonymous function
ok = quickjs:register_function(Ctx, <<"double">>, fun(X) -> X * 2 end).

%% Call from JavaScript
{ok, 10} = quickjs:eval(Ctx, <<"double(5)">>).
```

## Function Formats

### Anonymous Functions

```erlang
ok = quickjs:register_function(Ctx, <<"add">>, fun(A, B) -> A + B end).
```

### Module Functions

```erlang
ok = quickjs:register_function(Ctx, <<"upcase">>, {string, to_upper}).
{ok, <<"HELLO">>} = quickjs:eval(Ctx, <<"upcase('hello')">>).
```

## Argument Handling

JavaScript arguments are automatically converted to Erlang terms:

```erlang
ok = quickjs:register_function(Ctx, <<"process">>, fun(Data) ->
    %% Data is already an Erlang map
    Name = maps:get(<<"name">>, Data),
    Age = maps:get(<<"age">>, Data),
    #{name => Name, age_next_year => Age + 1}
end).

{ok, Result} = quickjs:eval(Ctx, <<"process({name: 'Alice', age: 30})">>).
%% Result = #{<<"name">> => <<"Alice">>, <<"age_next_year">> => 31}
```

## Return Values

Erlang return values are converted to JavaScript:

```erlang
ok = quickjs:register_function(Ctx, <<"get_config">>, fun() ->
    #{
        host => <<"localhost">>,
        port => 8080,
        debug => true,
        tags => [<<"web">>, <<"api">>]
    }
end).

{ok, _} = quickjs:eval(Ctx, <<"
    var config = get_config();
    console.log(config.host);  // 'localhost'
    console.log(config.port);  // 8080
">>).
```

## Nested Calls

Erlang functions can be called from within other Erlang function calls:

```erlang
ok = quickjs:register_function(Ctx, <<"double">>, fun(X) -> X * 2 end).

%% Nested calls work correctly
{ok, 20} = quickjs:eval(Ctx, <<"double(double(5))">>).
{ok, 80} = quickjs:eval(Ctx, <<"double(double(double(10)))">>).
```

## Error Handling

Erlang exceptions are converted to JavaScript errors:

```erlang
ok = quickjs:register_function(Ctx, <<"divide">>, fun(A, B) ->
    case B of
        0 -> error(division_by_zero);
        _ -> A / B
    end
end).

{error, _} = quickjs:eval(Ctx, <<"divide(10, 0)">>).
```

You can also throw specific error messages:

```erlang
ok = quickjs:register_function(Ctx, <<"validate">>, fun(Age) ->
    if
        Age < 0 -> throw({invalid_age, Age});
        Age > 150 -> throw({unrealistic_age, Age});
        true -> ok
    end
end).
```

## Complex Example

```erlang
-module(erlang_functions_example).
-export([run/0]).

run() ->
    {ok, Ctx} = quickjs:new_context(),

    %% Register multiple functions
    ok = quickjs:register_function(Ctx, <<"http_get">>, fun http_get/1),
    ok = quickjs:register_function(Ctx, <<"base64_encode">>, {base64, encode}),
    ok = quickjs:register_function(Ctx, <<"md5">>, fun(Data) ->
        crypto:hash(md5, Data)
    end),

    %% Use them in JavaScript
    {ok, _} = quickjs:eval(Ctx, <<"
        var data = http_get('https://api.example.com/data');
        var encoded = base64_encode(JSON.stringify(data));
        var hash = md5(encoded);
    ">>),

    ok = quickjs:destroy_context(Ctx).

http_get(Url) ->
    %% Simplified HTTP GET
    case httpc:request(get, {binary_to_list(Url), []}, [], []) of
        {ok, {{_, 200, _}, _, Body}} ->
            #{status => 200, body => list_to_binary(Body)};
        {error, Reason} ->
            error({http_error, Reason})
    end.
```

## Best Practices

1. **Keep functions pure** - Avoid side effects when possible
2. **Handle errors gracefully** - Use `try/catch` or return error tuples
3. **Validate inputs** - Check JavaScript arguments before processing
4. **Use descriptive names** - JavaScript naming conventions (camelCase) work well
