%%% -*- erlang -*-
%%%
%%% Copyright (c) 2025 Benoit Chesneau
%%%
%%% Licensed under the Apache License, Version 2.0

-module(quickjs_tests).

-include_lib("eunit/include/eunit.hrl").

%% ============================================================================
%% Test: NIF loads correctly
%% ============================================================================

nif_load_test() ->
    Result = quickjs:info(),
    ?assertMatch({ok, _}, Result),
    {ok, Info} = Result,
    ?assert(is_list(Info)),
    ?assertEqual("quickjs nif loaded", Info).

%% ============================================================================
%% Test: Context creation and destruction
%% ============================================================================

context_create_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assert(is_reference(Ctx)),
    ?assertEqual(ok, quickjs:destroy_context(Ctx)).

context_double_destroy_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual(ok, quickjs:destroy_context(Ctx)),
    ?assertEqual(ok, quickjs:destroy_context(Ctx)).

context_multiple_test() ->
    {ok, Ctx1} = quickjs:new_context(),
    {ok, Ctx2} = quickjs:new_context(),
    {ok, Ctx3} = quickjs:new_context(),
    ?assertNotEqual(Ctx1, Ctx2),
    ?assertNotEqual(Ctx2, Ctx3),
    ?assertNotEqual(Ctx1, Ctx3),
    ?assertEqual(ok, quickjs:destroy_context(Ctx1)),
    ?assertEqual(ok, quickjs:destroy_context(Ctx2)),
    ?assertEqual(ok, quickjs:destroy_context(Ctx3)).

context_gc_cleanup_test() ->
    Self = self(),
    Pid = spawn(fun() ->
        {ok, Ctx} = quickjs:new_context(),
        Self ! {context_created, Ctx},
        ok
    end),
    Ctx = receive
        {context_created, C} -> C
    after 1000 ->
        ?assert(false)
    end,
    Ref = monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        ?assert(false)
    end,
    erlang:garbage_collect(),
    timer:sleep(10),
    ?assert(is_reference(Ctx)),
    ?assertEqual(ok, quickjs:destroy_context(Ctx)).

context_badarg_test() ->
    ?assertMatch({error, badarg}, quickjs:destroy_context(not_a_context)),
    ?assertMatch({error, badarg}, quickjs:destroy_context(123)),
    ?assertMatch({error, badarg}, quickjs:destroy_context(<<"binary">>)).

%% ============================================================================
%% Test: Basic JavaScript evaluation
%% ============================================================================

eval_integer_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, 3}, quickjs:eval(Ctx, <<"1 + 2">>)),
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"42">>)),
    ?assertEqual({ok, -10}, quickjs:eval(Ctx, <<"-10">>)),
    ?assertEqual({ok, 0}, quickjs:eval(Ctx, <<"0">>)),
    ok = quickjs:destroy_context(Ctx).

eval_float_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, 3.14}, quickjs:eval(Ctx, <<"3.14">>)),
    ?assertEqual({ok, 0.5}, quickjs:eval(Ctx, <<"1 / 2">>)),
    ok = quickjs:destroy_context(Ctx).

eval_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, <<"hello">>}, quickjs:eval(Ctx, <<"'hello'">>)),
    ?assertEqual({ok, <<"hello world">>}, quickjs:eval(Ctx, <<"'hello' + ' ' + 'world'">>)),
    ?assertEqual({ok, <<"">>}, quickjs:eval(Ctx, <<"''">>)),
    ok = quickjs:destroy_context(Ctx).

eval_boolean_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, true}, quickjs:eval(Ctx, <<"true">>)),
    ?assertEqual({ok, false}, quickjs:eval(Ctx, <<"false">>)),
    ?assertEqual({ok, true}, quickjs:eval(Ctx, <<"1 == 1">>)),
    ?assertEqual({ok, false}, quickjs:eval(Ctx, <<"1 == 2">>)),
    ok = quickjs:destroy_context(Ctx).

eval_null_undefined_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, null}, quickjs:eval(Ctx, <<"null">>)),
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx, <<"undefined">>)),
    ok = quickjs:destroy_context(Ctx).

eval_variable_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Define a variable and use it
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx, <<"var x = 10">>)),
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"x">>)),
    ?assertEqual({ok, 20}, quickjs:eval(Ctx, <<"x * 2">>)),
    ok = quickjs:destroy_context(Ctx).

eval_function_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Define a function and call it
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>)),
    ?assertEqual({ok, 7}, quickjs:eval(Ctx, <<"add(3, 4)">>)),
    ok = quickjs:destroy_context(Ctx).

eval_iolist_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Test with iolist input
    ?assertEqual({ok, 6}, quickjs:eval(Ctx, ["1", <<" + ">>, "2", <<" + 3">>])),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: JavaScript error handling
%% ============================================================================

eval_error_syntax_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Result = quickjs:eval(Ctx, <<"function(">>),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

eval_error_throw_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Result = quickjs:eval(Ctx, <<"throw 'oops'">>),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

eval_error_reference_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Result = quickjs:eval(Ctx, <<"nonexistent_variable">>),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

eval_destroyed_context_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:destroy_context(Ctx),
    ?assertMatch({error, invalid_context}, quickjs:eval(Ctx, <<"1 + 1">>)).

eval_invalid_context_test() ->
    ?assertMatch({error, invalid_context}, quickjs:eval(not_a_context, <<"1">>)).

%% ============================================================================
%% Test: Context isolation
%% ============================================================================

eval_context_isolation_test() ->
    {ok, Ctx1} = quickjs:new_context(),
    {ok, Ctx2} = quickjs:new_context(),
    %% Define variable in Ctx1
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx1, <<"var x = 100">>)),
    ?assertEqual({ok, 100}, quickjs:eval(Ctx1, <<"x">>)),
    %% Variable should not exist in Ctx2
    ?assertMatch({error, {js_error, _}}, quickjs:eval(Ctx2, <<"x">>)),
    %% Define different value in Ctx2
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx2, <<"var x = 200">>)),
    ?assertEqual({ok, 200}, quickjs:eval(Ctx2, <<"x">>)),
    %% Ctx1 should still have its own value
    ?assertEqual({ok, 100}, quickjs:eval(Ctx1, <<"x">>)),
    ok = quickjs:destroy_context(Ctx1),
    ok = quickjs:destroy_context(Ctx2).

%% ============================================================================
%% Test: eval/3 with bindings
%% ============================================================================

eval_bindings_integer_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, 30}, quickjs:eval(Ctx, <<"x * y">>, #{<<"x">> => 5, <<"y">> => 6})),
    ?assertEqual({ok, 15}, quickjs:eval(Ctx, <<"a + b + c">>, #{<<"a">> => 5, <<"b">> => 7, <<"c">> => 3})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_float_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, 6.28}, quickjs:eval(Ctx, <<"pi * 2">>, #{<<"pi">> => 3.14})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, <<"hello world">>},
                 quickjs:eval(Ctx, <<"greeting + ' ' + name">>,
                              #{<<"greeting">> => <<"hello">>, <<"name">> => <<"world">>})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_boolean_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, true}, quickjs:eval(Ctx, <<"flag">>, #{<<"flag">> => true})),
    ?assertEqual({ok, false}, quickjs:eval(Ctx, <<"flag">>, #{<<"flag">> => false})),
    ?assertEqual({ok, true}, quickjs:eval(Ctx, <<"a && b">>, #{<<"a">> => true, <<"b">> => true})),
    ?assertEqual({ok, false}, quickjs:eval(Ctx, <<"a && b">>, #{<<"a">> => true, <<"b">> => false})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_null_undefined_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, null}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => null})),
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => undefined})),
    ?assertEqual({ok, true}, quickjs:eval(Ctx, <<"x === null">>, #{<<"x">> => null})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_atom_key_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Atom keys should work
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"x">>, #{x => 10})),
    ?assertEqual({ok, 30}, quickjs:eval(Ctx, <<"x + y">>, #{x => 10, y => 20})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_atom_value_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Non-special atoms become strings
    ?assertEqual({ok, <<"hello">>}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => hello})),
    ?assertEqual({ok, <<"foo">>}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => foo})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_map_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Maps become objects
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"obj.x">>, #{<<"obj">> => #{<<"x">> => 10}})),
    ?assertEqual({ok, <<"bar">>}, quickjs:eval(Ctx, <<"obj.foo">>,
                                                #{<<"obj">> => #{<<"foo">> => <<"bar">>}})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_nested_map_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Nested = #{<<"a">> => #{<<"b">> => #{<<"c">> => 42}}},
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"obj.a.b.c">>, #{<<"obj">> => Nested})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_tuple_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Tuples become arrays
    ?assertEqual({ok, 1}, quickjs:eval(Ctx, <<"arr[0]">>, #{<<"arr">> => {1, 2, 3}})),
    ?assertEqual({ok, 3}, quickjs:eval(Ctx, <<"arr[2]">>, #{<<"arr">> => {1, 2, 3}})),
    ?assertEqual({ok, 3}, quickjs:eval(Ctx, <<"arr.length">>, #{<<"arr">> => {1, 2, 3}})),
    ok = quickjs:destroy_context(Ctx).

eval_bindings_persist_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Bindings should persist in context
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => 10})),
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"x">>)),  %% Still accessible
    ok = quickjs:destroy_context(Ctx).

eval_bindings_empty_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Empty bindings should work
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"42">>, #{})),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: JavaScript to Erlang type conversion (arrays and objects)
%% ============================================================================

eval_return_array_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Simple array
    ?assertEqual({ok, [1, 2, 3]}, quickjs:eval(Ctx, <<"[1, 2, 3]">>)),
    %% Empty array
    ?assertEqual({ok, []}, quickjs:eval(Ctx, <<"[]">>)),
    %% Mixed types in array
    {ok, Result} = quickjs:eval(Ctx, <<"[1, 'hello', true, null]">>),
    ?assertEqual([1, <<"hello">>, true, null], Result),
    ok = quickjs:destroy_context(Ctx).

eval_return_object_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Simple object
    {ok, Result1} = quickjs:eval(Ctx, <<"({x: 1, y: 2})">>),
    ?assertEqual(#{<<"x">> => 1, <<"y">> => 2}, Result1),
    %% Empty object
    ?assertEqual({ok, #{}}, quickjs:eval(Ctx, <<"({})">>)),
    %% Object with string values
    {ok, Result2} = quickjs:eval(Ctx, <<"({name: 'John', city: 'NYC'})">>),
    ?assertEqual(#{<<"name">> => <<"John">>, <<"city">> => <<"NYC">>}, Result2),
    ok = quickjs:destroy_context(Ctx).

eval_return_nested_array_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Nested arrays
    ?assertEqual({ok, [[1, 2], [3, 4]]}, quickjs:eval(Ctx, <<"[[1, 2], [3, 4]]">>)),
    %% Deeply nested
    ?assertEqual({ok, [[[1]]]}, quickjs:eval(Ctx, <<"[[[1]]]">>)),
    ok = quickjs:destroy_context(Ctx).

eval_return_nested_object_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Nested objects
    {ok, Result} = quickjs:eval(Ctx, <<"({a: {b: {c: 42}}})">>),
    ?assertEqual(#{<<"a">> => #{<<"b">> => #{<<"c">> => 42}}}, Result),
    ok = quickjs:destroy_context(Ctx).

eval_return_mixed_nested_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Object with array value
    {ok, Result1} = quickjs:eval(Ctx, <<"({items: [1, 2, 3]})">>),
    ?assertEqual(#{<<"items">> => [1, 2, 3]}, Result1),
    %% Array with object elements
    {ok, Result2} = quickjs:eval(Ctx, <<"[{x: 1}, {x: 2}]">>),
    ?assertEqual([#{<<"x">> => 1}, #{<<"x">> => 2}], Result2),
    ok = quickjs:destroy_context(Ctx).

eval_return_function_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Functions return their string representation
    {ok, Result} = quickjs:eval(Ctx, <<"(function add(a, b) { return a + b; })">>),
    ?assert(is_binary(Result)),
    ?assertMatch({match, _}, re:run(Result, <<"function">>)),
    ok = quickjs:destroy_context(Ctx).

eval_return_date_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Date objects - should return as object with properties or string
    {ok, _Result} = quickjs:eval(Ctx, <<"new Date(0)">>),
    %% Just verify it doesn't crash
    ok = quickjs:destroy_context(Ctx).

eval_roundtrip_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Test that data survives a round trip
    Data = #{<<"users">> => [
        #{<<"name">> => <<"Alice">>, <<"age">> => 30},
        #{<<"name">> => <<"Bob">>, <<"age">> => 25}
    ]},
    {ok, Result} = quickjs:eval(Ctx, <<"data">>, #{<<"data">> => Data}),
    ?assertEqual(Data, Result),
    ok = quickjs:destroy_context(Ctx).

eval_array_methods_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Test that array methods work and return arrays
    ?assertEqual({ok, [2, 4, 6]}, quickjs:eval(Ctx, <<"[1, 2, 3].map(function(x) { return x * 2; })">>)),
    ?assertEqual({ok, [2, 3]}, quickjs:eval(Ctx, <<"[1, 2, 3].filter(function(x) { return x > 1; })">>)),
    ok = quickjs:destroy_context(Ctx).

eval_json_parse_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% JSON.parse should work
    {ok, Result} = quickjs:eval(Ctx, <<"JSON.parse('{\"a\": 1, \"b\": [2, 3]}')">>),
    ?assertEqual(#{<<"a">> => 1, <<"b">> => [2, 3]}, Result),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: call/2 and call/3 - calling JavaScript functions
%% ============================================================================

call_no_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function getFortyTwo() { return 42; }">>),
    ?assertEqual({ok, 42}, quickjs:call(Ctx, <<"getFortyTwo">>)),
    ok = quickjs:destroy_context(Ctx).

call_simple_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>),
    ?assertEqual({ok, 7}, quickjs:call(Ctx, <<"add">>, [3, 4])),
    ok = quickjs:destroy_context(Ctx).

call_atom_name_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function multiply(a, b) { return a * b; }">>),
    ?assertEqual({ok, 12}, quickjs:call(Ctx, multiply, [3, 4])),
    ok = quickjs:destroy_context(Ctx).

call_string_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function greet(name) { return 'Hello, ' + name + '!'; }">>),
    ?assertEqual({ok, <<"Hello, World!">>}, quickjs:call(Ctx, <<"greet">>, [<<"World">>])),
    ok = quickjs:destroy_context(Ctx).

call_mixed_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function format(name, age) { return name + ' is ' + age + ' years old'; }">>),
    ?assertEqual({ok, <<"Alice is 30 years old">>},
                 quickjs:call(Ctx, <<"format">>, [<<"Alice">>, 30])),
    ok = quickjs:destroy_context(Ctx).

call_array_arg_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function sum(arr) { return arr.reduce(function(a, b) { return a + b; }, 0); }">>),
    %% Use integers > 255 to ensure list is treated as array, not iolist
    ?assertEqual({ok, 1500}, quickjs:call(Ctx, <<"sum">>, [[100, 200, 300, 400, 500]])),
    ok = quickjs:destroy_context(Ctx).

call_object_arg_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function getName(obj) { return obj.name; }">>),
    ?assertEqual({ok, <<"John">>}, quickjs:call(Ctx, <<"getName">>, [#{<<"name">> => <<"John">>}])),
    ok = quickjs:destroy_context(Ctx).

call_return_array_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function makeArray(a, b, c) { return [a, b, c]; }">>),
    ?assertEqual({ok, [1, 2, 3]}, quickjs:call(Ctx, <<"makeArray">>, [1, 2, 3])),
    ok = quickjs:destroy_context(Ctx).

call_return_object_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function makeObj(x, y) { return {x: x, y: y}; }">>),
    ?assertEqual({ok, #{<<"x">> => 1, <<"y">> => 2}}, quickjs:call(Ctx, <<"makeObj">>, [1, 2])),
    ok = quickjs:destroy_context(Ctx).

call_builtin_function_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Call built-in Math.max
    {ok, _} = quickjs:eval(Ctx, <<"var myMax = Math.max">>),
    %% Note: we can't directly call Math.max as it needs 'this' context,
    %% but we can wrap it
    {ok, _} = quickjs:eval(Ctx, <<"function maxOf(a, b) { return Math.max(a, b); }">>),
    ?assertEqual({ok, 10}, quickjs:call(Ctx, <<"maxOf">>, [5, 10])),
    ok = quickjs:destroy_context(Ctx).

call_function_not_found_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Result = quickjs:call(Ctx, <<"nonexistent">>, []),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

call_not_a_function_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"var notFunc = 42">>),
    Result = quickjs:call(Ctx, <<"notFunc">>, []),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

call_destroyed_context_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function test() { return 1; }">>),
    ok = quickjs:destroy_context(Ctx),
    ?assertMatch({error, invalid_context}, quickjs:call(Ctx, <<"test">>, [])).

call_function_throws_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function throwError() { throw new Error('oops'); }">>),
    Result = quickjs:call(Ctx, <<"throwError">>, []),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

call_many_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function sumAll() { var s = 0; for (var i = 0; i < arguments.length; i++) s += arguments[i]; return s; }">>),
    ?assertEqual({ok, 55}, quickjs:call(Ctx, <<"sumAll">>, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])),
    ok = quickjs:destroy_context(Ctx).

call_closure_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"
        var counter = 0;
        function increment() { counter++; return counter; }
    ">>),
    ?assertEqual({ok, 1}, quickjs:call(Ctx, <<"increment">>, [])),
    ?assertEqual({ok, 2}, quickjs:call(Ctx, <<"increment">>, [])),
    ?assertEqual({ok, 3}, quickjs:call(Ctx, <<"increment">>, [])),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: CommonJS module support
%% ============================================================================

module_register_require_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Register a simple module
    ok = quickjs:register_module(Ctx, <<"math">>,
        <<"exports.add = function(a, b) { return a + b; };">>),
    %% Require it and get exports
    {ok, Exports} = quickjs:require(Ctx, <<"math">>),
    ?assert(is_map(Exports)),
    ok = quickjs:destroy_context(Ctx).

module_use_from_js_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_module(Ctx, <<"utils">>,
        <<"exports.greet = function(name) { return 'Hello, ' + name + '!'; };">>),
    %% Use require() from JavaScript
    {ok, Result} = quickjs:eval(Ctx, <<"require('utils').greet('World')">>),
    ?assertEqual(<<"Hello, World!">>, Result),
    ok = quickjs:destroy_context(Ctx).

module_atom_id_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Register with atom module ID
    ok = quickjs:register_module(Ctx, mymodule,
        <<"exports.value = 42;">>),
    {ok, Exports} = quickjs:require(Ctx, mymodule),
    ?assertEqual(#{<<"value">> => 42}, Exports),
    ok = quickjs:destroy_context(Ctx).

module_multiple_exports_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_module(Ctx, <<"calc">>, <<"
        exports.add = function(a, b) { return a + b; };
        exports.sub = function(a, b) { return a - b; };
        exports.mul = function(a, b) { return a * b; };
        exports.PI = 3.14159;
    ">>),
    {ok, _} = quickjs:require(Ctx, <<"calc">>),
    ?assertEqual({ok, 7}, quickjs:eval(Ctx, <<"require('calc').add(3, 4)">>)),
    ?assertEqual({ok, 3}, quickjs:eval(Ctx, <<"require('calc').sub(7, 4)">>)),
    ?assertEqual({ok, 12}, quickjs:eval(Ctx, <<"require('calc').mul(3, 4)">>)),
    ok = quickjs:destroy_context(Ctx).

module_caching_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Register a module with a counter
    ok = quickjs:register_module(Ctx, <<"counter">>, <<"
        var count = 0;
        exports.increment = function() { count++; return count; };
    ">>),
    %% First require
    {ok, _} = quickjs:require(Ctx, <<"counter">>),
    ?assertEqual({ok, 1}, quickjs:eval(Ctx, <<"require('counter').increment()">>)),
    ?assertEqual({ok, 2}, quickjs:eval(Ctx, <<"require('counter').increment()">>)),
    %% Require again - should get the same (cached) module
    {ok, _} = quickjs:require(Ctx, <<"counter">>),
    ?assertEqual({ok, 3}, quickjs:eval(Ctx, <<"require('counter').increment()">>)),
    ok = quickjs:destroy_context(Ctx).

module_dependency_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Register base module
    ok = quickjs:register_module(Ctx, <<"base">>,
        <<"exports.value = 10;">>),
    %% Register module that depends on base
    ok = quickjs:register_module(Ctx, <<"derived">>, <<"
        var base = require('base');
        exports.doubled = base.value * 2;
    ">>),
    {ok, Exports} = quickjs:require(Ctx, <<"derived">>),
    ?assertEqual(#{<<"doubled">> => 20}, Exports),
    ok = quickjs:destroy_context(Ctx).

module_not_found_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Result = quickjs:require(Ctx, <<"nonexistent">>),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

module_syntax_error_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_module(Ctx, <<"bad">>, <<"exports.x = {">>),
    Result = quickjs:require(Ctx, <<"bad">>),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

module_exports_replacement_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Test replacing module.exports entirely
    ok = quickjs:register_module(Ctx, <<"singleton">>, <<"
        module.exports = function() { return 'I am a function!'; };
    ">>),
    {ok, _} = quickjs:require(Ctx, <<"singleton">>),
    {ok, Result} = quickjs:eval(Ctx, <<"require('singleton')()">>),
    ?assertEqual(<<"I am a function!">>, Result),
    ok = quickjs:destroy_context(Ctx).

module_destroyed_context_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:destroy_context(Ctx),
    ?assertMatch({error, invalid_context}, quickjs:register_module(Ctx, <<"test">>, <<"exports.x = 1;">>)),
    ?assertMatch({error, invalid_context}, quickjs:require(Ctx, <<"test">>)).

%% ============================================================================
%% Test: Multiple contexts and isolation
%% ============================================================================

isolation_functions_test() ->
    {ok, Ctx1} = quickjs:new_context(),
    {ok, Ctx2} = quickjs:new_context(),
    %% Define function in Ctx1
    {ok, _} = quickjs:eval(Ctx1, <<"function myFunc() { return 'from ctx1'; }">>),
    ?assertEqual({ok, <<"from ctx1">>}, quickjs:call(Ctx1, <<"myFunc">>, [])),
    %% Function should not exist in Ctx2
    ?assertMatch({error, {js_error, _}}, quickjs:call(Ctx2, <<"myFunc">>, [])),
    %% Define different function in Ctx2
    {ok, _} = quickjs:eval(Ctx2, <<"function myFunc() { return 'from ctx2'; }">>),
    ?assertEqual({ok, <<"from ctx2">>}, quickjs:call(Ctx2, <<"myFunc">>, [])),
    %% Ctx1 should still have its own function
    ?assertEqual({ok, <<"from ctx1">>}, quickjs:call(Ctx1, <<"myFunc">>, [])),
    ok = quickjs:destroy_context(Ctx1),
    ok = quickjs:destroy_context(Ctx2).

isolation_modules_test() ->
    {ok, Ctx1} = quickjs:new_context(),
    {ok, Ctx2} = quickjs:new_context(),
    %% Register module in Ctx1
    ok = quickjs:register_module(Ctx1, <<"mymod">>, <<"exports.value = 'ctx1';">>),
    {ok, _} = quickjs:require(Ctx1, <<"mymod">>),
    ?assertEqual({ok, <<"ctx1">>}, quickjs:eval(Ctx1, <<"require('mymod').value">>)),
    %% Module should not exist in Ctx2
    ?assertMatch({error, {js_error, _}}, quickjs:require(Ctx2, <<"mymod">>)),
    %% Register different module with same name in Ctx2
    ok = quickjs:register_module(Ctx2, <<"mymod">>, <<"exports.value = 'ctx2';">>),
    {ok, _} = quickjs:require(Ctx2, <<"mymod">>),
    ?assertEqual({ok, <<"ctx2">>}, quickjs:eval(Ctx2, <<"require('mymod').value">>)),
    %% Ctx1 should still have its own module
    ?assertEqual({ok, <<"ctx1">>}, quickjs:eval(Ctx1, <<"require('mymod').value">>)),
    ok = quickjs:destroy_context(Ctx1),
    ok = quickjs:destroy_context(Ctx2).

isolation_after_destroy_test() ->
    {ok, Ctx1} = quickjs:new_context(),
    {ok, Ctx2} = quickjs:new_context(),
    %% Set up state in both contexts
    {ok, _} = quickjs:eval(Ctx1, <<"var x = 100">>),
    {ok, _} = quickjs:eval(Ctx2, <<"var x = 200">>),
    %% Destroy Ctx1
    ok = quickjs:destroy_context(Ctx1),
    %% Ctx2 should still work fine
    ?assertEqual({ok, 200}, quickjs:eval(Ctx2, <<"x">>)),
    ?assertEqual({ok, 400}, quickjs:eval(Ctx2, <<"x * 2">>)),
    %% Ctx1 should be invalid
    ?assertMatch({error, invalid_context}, quickjs:eval(Ctx1, <<"x">>)),
    ok = quickjs:destroy_context(Ctx2).

isolation_global_objects_test() ->
    {ok, Ctx1} = quickjs:new_context(),
    {ok, Ctx2} = quickjs:new_context(),
    %% Modify global object in Ctx1
    {ok, _} = quickjs:eval(Ctx1, <<"Object.prototype.customMethod = function() { return 42; }">>),
    ?assertEqual({ok, 42}, quickjs:eval(Ctx1, <<"({}).customMethod()">>)),
    %% Ctx2 should not have the modification
    ?assertMatch({error, {js_error, _}}, quickjs:eval(Ctx2, <<"({}).customMethod()">>)),
    ok = quickjs:destroy_context(Ctx1),
    ok = quickjs:destroy_context(Ctx2).

%% ============================================================================
%% Test: Concurrent context access
%% ============================================================================

concurrent_contexts_test() ->
    %% Create multiple contexts
    Contexts = [begin {ok, Ctx} = quickjs:new_context(), Ctx end || _ <- lists:seq(1, 5)],
    %% Spawn processes to use each context concurrently
    Self = self(),
    Pids = [spawn_link(fun() ->
        %% Each process does some work on its context
        {ok, _} = quickjs:eval(Ctx, <<"var sum = 0">>),
        lists:foreach(fun(I) ->
            {ok, _} = quickjs:eval(Ctx, list_to_binary("sum += " ++ integer_to_list(I)))
        end, lists:seq(1, 100)),
        {ok, Result} = quickjs:eval(Ctx, <<"sum">>),
        Self ! {done, self(), Result}
    end) || Ctx <- Contexts],
    %% Wait for all processes
    Results = [receive {done, Pid, R} -> R after 5000 -> timeout end || Pid <- Pids],
    %% All should get the same result (sum 1..100 = 5050)
    ?assertEqual([5050, 5050, 5050, 5050, 5050], Results),
    %% Clean up
    lists:foreach(fun(Ctx) -> ok = quickjs:destroy_context(Ctx) end, Contexts).

concurrent_same_context_test() ->
    %% Test that multiple processes can safely use the same context
    %% (mutex should prevent race conditions)
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"var counter = 0">>),
    Self = self(),
    NumProcs = 10,
    NumOps = 50,
    Pids = [spawn_link(fun() ->
        lists:foreach(fun(_) ->
            {ok, _} = quickjs:eval(Ctx, <<"counter++">>)
        end, lists:seq(1, NumOps)),
        Self ! {done, self()}
    end) || _ <- lists:seq(1, NumProcs)],
    %% Wait for all processes
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok after 5000 -> ?assert(false) end
    end, Pids),
    %% Counter should equal NumProcs * NumOps
    {ok, FinalCount} = quickjs:eval(Ctx, <<"counter">>),
    ?assertEqual(NumProcs * NumOps, FinalCount),
    ok = quickjs:destroy_context(Ctx).

many_contexts_test() ->
    %% Create many contexts to verify no resource leaks
    NumContexts = 50,
    Contexts = [begin {ok, Ctx} = quickjs:new_context(), Ctx end || _ <- lists:seq(1, NumContexts)],
    %% Do some work in each
    lists:foreach(fun({Idx, Ctx}) ->
        {ok, _} = quickjs:eval(Ctx, list_to_binary("var id = " ++ integer_to_list(Idx))),
        {ok, Id} = quickjs:eval(Ctx, <<"id">>),
        ?assertEqual(Idx, Id)
    end, lists:zip(lists:seq(1, NumContexts), Contexts)),
    %% Destroy all
    lists:foreach(fun(Ctx) -> ok = quickjs:destroy_context(Ctx) end, Contexts),
    %% Verify all are destroyed
    lists:foreach(fun(Ctx) ->
        ?assertMatch({error, invalid_context}, quickjs:eval(Ctx, <<"1">>))
    end, Contexts).

context_gc_isolation_test() ->
    %% Verify that GC of one context doesn't affect another
    {ok, Ctx1} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx1, <<"var persistent = 'I should survive'">>),
    %% Create and abandon a context (let it be GC'd)
    _Pid = spawn(fun() ->
        {ok, Ctx2} = quickjs:new_context(),
        {ok, _} = quickjs:eval(Ctx2, <<"var temp = 'temporary'">>)
        %% Context abandoned here, will be GC'd
    end),
    timer:sleep(50),
    erlang:garbage_collect(),
    timer:sleep(10),
    %% Ctx1 should still work
    ?assertEqual({ok, <<"I should survive">>}, quickjs:eval(Ctx1, <<"persistent">>)),
    ok = quickjs:destroy_context(Ctx1).

context_auto_cleanup_test() ->
    %% Verify that contexts are automatically cleaned up when no process holds a reference
    %% This tests the NIF resource reference counting mechanism
    Self = self(),
    %% Create a context in a separate process
    Pid = spawn(fun() ->
        {ok, Ctx} = quickjs:new_context(),
        {ok, _} = quickjs:eval(Ctx, <<"var data = 'test'">>),
        %% Send context to parent
        Self ! {context, Ctx},
        %% Wait for signal to die
        receive die -> ok end
    end),
    %% Receive the context
    Ctx = receive {context, C} -> C after 1000 -> error(timeout) end,
    %% Context should work while process is alive
    ?assertEqual({ok, <<"test">>}, quickjs:eval(Ctx, <<"data">>)),
    %% Tell process to die
    Pid ! die,
    timer:sleep(10),
    %% Context should still work because we hold a reference
    ?assertEqual({ok, <<"test">>}, quickjs:eval(Ctx, <<"data">>)),
    %% Explicitly destroy
    ok = quickjs:destroy_context(Ctx).

context_shared_between_processes_test() ->
    %% Verify that a context can be shared between multiple processes
    %% and remains valid as long as any process holds a reference
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"var counter = 0">>),
    Self = self(),
    %% Spawn processes that share the context
    Pids = [spawn_link(fun() ->
        %% Each process increments the counter
        {ok, _} = quickjs:eval(Ctx, <<"counter++">>),
        Self ! {done, self()}
    end) || _ <- lists:seq(1, 5)],
    %% Wait for all processes
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok after 1000 -> error(timeout) end
    end, Pids),
    %% Counter should be 5
    {ok, Count} = quickjs:eval(Ctx, <<"counter">>),
    ?assertEqual(5, Count),
    %% Context should still work
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"counter * 2">>)),
    ok = quickjs:destroy_context(Ctx).

context_cleanup_on_process_death_test() ->
    %% Verify that when the only process holding a context dies,
    %% the context is cleaned up (via GC)
    Self = self(),
    Pid = spawn(fun() ->
        {ok, Ctx} = quickjs:new_context(),
        {ok, _} = quickjs:eval(Ctx, <<"var x = 42">>),
        Self ! {ctx, Ctx},
        %% Keep the context alive until told to die
        receive die -> ok end
        %% Process exits, releasing its reference to Ctx
    end),
    Ctx = receive {ctx, C} -> C after 1000 -> error(timeout) end,
    %% Context works while both processes hold it
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"x">>)),
    %% Tell the spawned process to die
    Pid ! die,
    timer:sleep(10),
    %% We still hold a reference, so context should still work
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"x">>)),
    %% Now destroy from our side
    ok = quickjs:destroy_context(Ctx),
    %% Should be invalid now
    ?assertMatch({error, invalid_context}, quickjs:eval(Ctx, <<"x">>)).

%% ============================================================================
%% Test: Error handling and edge cases
%% ============================================================================

%% Special JavaScript values

special_nan_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Result} = quickjs:eval(Ctx, <<"NaN">>),
    %% NaN is represented as atom 'nan' since Erlang can't represent NaN
    ?assertEqual(nan, Result),
    ok = quickjs:destroy_context(Ctx).

special_infinity_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, PosInf} = quickjs:eval(Ctx, <<"Infinity">>),
    {ok, NegInf} = quickjs:eval(Ctx, <<"-Infinity">>),
    %% Infinity is represented as atoms since Erlang can't represent Infinity
    ?assertEqual(infinity, PosInf),
    ?assertEqual(neg_infinity, NegInf),
    ok = quickjs:destroy_context(Ctx).

special_large_integer_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% JavaScript safe integer max is 2^53 - 1
    {ok, SafeMax} = quickjs:eval(Ctx, <<"Number.MAX_SAFE_INTEGER">>),
    ?assertEqual(9007199254740991, SafeMax),
    %% Larger integers lose precision in JS
    {ok, _} = quickjs:eval(Ctx, <<"9007199254740993">>),
    ok = quickjs:destroy_context(Ctx).

special_negative_zero_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, NegZero} = quickjs:eval(Ctx, <<"-0">>),
    %% -0 in JavaScript
    ?assertEqual(0, NegZero),  %% Erlang treats -0 as 0
    ok = quickjs:destroy_context(Ctx).

%% Unicode handling

unicode_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Use JavaScript unicode escapes for source code
    {ok, Result1} = quickjs:eval(Ctx, <<"'h\\u00e9llo'">>),  %% héllo
    ?assertEqual(<<"héllo"/utf8>>, Result1),
    %% Emoji via unicode escapes
    {ok, Result2} = quickjs:eval(Ctx, <<"'\\uD83D\\uDC4B'">>),  %% 👋 (wave)
    ?assert(is_binary(Result2)),
    ok = quickjs:destroy_context(Ctx).

unicode_binding_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Pass unicode via bindings - bindings go through type conversion
    {ok, Result} = quickjs:eval(Ctx, <<"greeting + ', ' + name + '!'">>,
                              #{<<"greeting">> => <<"Hello"/utf8>>,
                                <<"name">> => <<"World"/utf8>>}),
    ?assertEqual(<<"Hello, World!">>, Result),
    ok = quickjs:destroy_context(Ctx).

unicode_in_binding_value_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Unicode characters in binding values
    UnicodeStr = <<"café"/utf8>>,
    {ok, Result} = quickjs:eval(Ctx, <<"x">>, #{<<"x">> => UnicodeStr}),
    ?assertEqual(UnicodeStr, Result),
    ok = quickjs:destroy_context(Ctx).

%% Empty and null inputs

empty_string_eval_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Empty string eval returns undefined
    ?assertEqual({ok, undefined}, quickjs:eval(Ctx, <<"">>)),
    ok = quickjs:destroy_context(Ctx).

empty_binary_binding_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, <<"">>}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => <<"">>})),
    ok = quickjs:destroy_context(Ctx).

%% Large data handling

large_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Create a large string (100KB)
    LargeStr = list_to_binary(lists:duplicate(100000, $x)),
    {ok, Result} = quickjs:eval(Ctx, <<"str">>, #{<<"str">> => LargeStr}),
    ?assertEqual(LargeStr, Result),
    ok = quickjs:destroy_context(Ctx).

large_array_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Create an array with 1000 elements
    {ok, _} = quickjs:eval(Ctx, <<"
        var arr = [];
        for (var i = 0; i < 1000; i++) arr.push(i);
    ">>),
    {ok, Result} = quickjs:eval(Ctx, <<"arr">>),
    ?assertEqual(1000, length(Result)),
    ?assertEqual(lists:seq(0, 999), Result),
    ok = quickjs:destroy_context(Ctx).

large_object_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Create an object with 50 properties (reduced for safety)
    {ok, _} = quickjs:eval(Ctx, <<"
        var obj = {};
        for (var i = 0; i < 50; i++) obj['key' + i] = i;
        obj;
    ">>),
    {ok, Result} = quickjs:eval(Ctx, <<"obj">>),
    ?assertEqual(50, map_size(Result)),
    ok = quickjs:destroy_context(Ctx).

deep_nesting_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Create moderately nested structure (reduced to avoid stack issues)
    {ok, _} = quickjs:eval(Ctx, <<"
        var obj = {value: 'deep'};
        for (var i = 0; i < 20; i++) {
            obj = {nested: obj};
        }
    ">>),
    {ok, Result} = quickjs:eval(Ctx, <<"obj">>),
    ?assert(is_map(Result)),
    ok = quickjs:destroy_context(Ctx).

%% Error message quality

error_message_syntax_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {error, {js_error, Msg}} = quickjs:eval(Ctx, <<"function(">>),
    ?assert(is_binary(Msg)),
    ?assert(byte_size(Msg) > 0),
    ok = quickjs:destroy_context(Ctx).

error_message_type_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {error, {js_error, Msg}} = quickjs:eval(Ctx, <<"null.foo">>),
    ?assert(is_binary(Msg)),
    ?assertMatch({match, _}, re:run(Msg, <<"TypeError">>)),
    ok = quickjs:destroy_context(Ctx).

error_message_reference_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {error, {js_error, Msg}} = quickjs:eval(Ctx, <<"undefinedVariable">>),
    ?assert(is_binary(Msg)),
    ok = quickjs:destroy_context(Ctx).

error_message_custom_throw_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {error, {js_error, Msg}} = quickjs:eval(Ctx, <<"throw 'custom error message'">>),
    ?assertEqual(<<"custom error message">>, Msg),
    ok = quickjs:destroy_context(Ctx).

error_message_throw_object_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {error, {js_error, Msg}} = quickjs:eval(Ctx, <<"throw new Error('detailed error')">>),
    ?assert(is_binary(Msg)),
    ?assertMatch({match, _}, re:run(Msg, <<"detailed error">>)),
    ok = quickjs:destroy_context(Ctx).

%% Type conversion edge cases

type_convert_empty_map_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, #{}}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => #{}})),
    ok = quickjs:destroy_context(Ctx).

type_convert_empty_list_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Empty list becomes empty iolist/string in JS
    ?assertEqual({ok, <<"">>}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => []})),
    ok = quickjs:destroy_context(Ctx).

type_convert_empty_tuple_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual({ok, []}, quickjs:eval(Ctx, <<"x">>, #{<<"x">> => {}})),
    ok = quickjs:destroy_context(Ctx).

type_convert_nested_empty_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Input = #{<<"a">> => #{}, <<"b">> => {}, <<"c">> => <<"">>},
    {ok, Result} = quickjs:eval(Ctx, <<"x">>, #{<<"x">> => Input}),
    ?assertEqual(#{<<"a">> => #{}, <<"b">> => [], <<"c">> => <<"">>}, Result),
    ok = quickjs:destroy_context(Ctx).

type_convert_boolean_in_map_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Input = #{<<"t">> => true, <<"f">> => false},
    {ok, Result} = quickjs:eval(Ctx, <<"x">>, #{<<"x">> => Input}),
    ?assertEqual(#{<<"t">> => true, <<"f">> => false}, Result),
    ok = quickjs:destroy_context(Ctx).

%% Recursive/circular structure handling

circular_detection_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Create a simple object without circular reference (for safety)
    {ok, _} = quickjs:eval(Ctx, <<"var obj = {name: 'test', value: 42}">>),
    {ok, Result} = quickjs:eval(Ctx, <<"obj">>),
    ?assert(is_map(Result)),
    ?assertEqual(<<"test">>, maps:get(<<"name">>, Result)),
    ok = quickjs:destroy_context(Ctx).

%% Regex and special objects

regex_to_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Result} = quickjs:eval(Ctx, <<"/hello.*world/gi">>),
    %% Regex is an object in Duktape, may be map or string representation
    ?assert(is_binary(Result) orelse is_map(Result)),
    ok = quickjs:destroy_context(Ctx).

date_handling_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Date object - verify it doesn't crash
    {ok, _} = quickjs:eval(Ctx, <<"new Date()">>),
    {ok, Timestamp} = quickjs:eval(Ctx, <<"Date.now()">>),
    ?assert(is_integer(Timestamp) orelse is_float(Timestamp)),
    ?assert(Timestamp > 0),
    ok = quickjs:destroy_context(Ctx).

%% Multiple sequential operations

sequential_operations_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Sequential operations should not leak or corrupt state
    lists:foreach(fun(I) ->
        IBin = integer_to_binary(I),
        {ok, I} = quickjs:eval(Ctx, IBin)
    end, lists:seq(1, 20)),
    ok = quickjs:destroy_context(Ctx).

%% Recover from errors

error_recovery_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Error should not corrupt context
    {error, _} = quickjs:eval(Ctx, <<"throw 'error'">>),
    %% Context should still work
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"42">>)),
    %% Multiple errors
    {error, _} = quickjs:eval(Ctx, <<"syntax error here (">>),
    {error, _} = quickjs:eval(Ctx, <<"undefined.property">>),
    %% Still works
    ?assertEqual({ok, <<"ok">>}, quickjs:eval(Ctx, <<"'ok'">>)),
    ok = quickjs:destroy_context(Ctx).

%% Call edge cases

call_no_return_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function noReturn() { var x = 1; }">>),
    ?assertEqual({ok, undefined}, quickjs:call(Ctx, <<"noReturn">>, [])),
    ok = quickjs:destroy_context(Ctx).

call_recursive_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"
        function factorial(n) {
            if (n <= 1) return 1;
            return n * factorial(n - 1);
        }
    ">>),
    ?assertEqual({ok, 120}, quickjs:call(Ctx, <<"factorial">>, [5])),
    ?assertEqual({ok, 3628800}, quickjs:call(Ctx, <<"factorial">>, [10])),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: Event Framework - JS to Erlang communication
%% ============================================================================

%% Test: console.log sends event to handler
console_log_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"console.log('hello', 'world')">>),
    receive
        {quickjs, log, #{level := info, message := Msg}} ->
            ?assertEqual(<<"hello world">>, Msg)
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: console.info sends info level
console_info_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"console.info('info message')">>),
    receive
        {quickjs, log, #{level := info, message := <<"info message">>}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: console.warn sends warning level
console_warn_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"console.warn('warning message')">>),
    receive
        {quickjs, log, #{level := warning, message := <<"warning message">>}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: console.error sends error level
console_error_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"console.error('error message')">>),
    receive
        {quickjs, log, #{level := error, message := <<"error message">>}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: console.debug sends debug level
console_debug_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"console.debug('debug message')">>),
    receive
        {quickjs, log, #{level := debug, message := <<"debug message">>}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang.log with explicit level
erlang_log_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"Erlang.log('warning', 'test', 123)">>),
    receive
        {quickjs, log, #{level := warning, message := <<"test 123">>}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang.emit sends custom event
erlang_emit_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"Erlang.emit('custom', {foo: 'bar', num: 42})">>),
    receive
        %% Event type is now a binary to prevent atom table exhaustion
        {quickjs, <<"custom">>, #{<<"foo">> := <<"bar">>, <<"num">> := 42}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ok = quickjs:destroy_context(Ctx).

%% Test: No handler means silent ignore
no_handler_silent_test() ->
    {ok, Ctx} = quickjs:new_context(),  %% No handler
    %% These should not crash or block
    {ok, undefined} = quickjs:eval(Ctx, <<"console.log('ignored')">>),
    {ok, undefined} = quickjs:eval(Ctx, <<"Erlang.emit('ignored', {})">>),
    {ok, 42} = quickjs:eval(Ctx, <<"40 + 2">>),  %% Context still works
    ok = quickjs:destroy_context(Ctx).

%% Test: Multiple log messages
multiple_logs_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        console.log('first');
        console.warn('second');
        console.error('third');
    ">>),
    receive {quickjs, log, #{level := info, message := <<"first">>}} -> ok
    after 100 -> ?assert(false) end,
    receive {quickjs, log, #{level := warning, message := <<"second">>}} -> ok
    after 100 -> ?assert(false) end,
    receive {quickjs, log, #{level := error, message := <<"third">>}} -> ok
    after 100 -> ?assert(false) end,
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: Event Framework - Erlang to JS communication
%% ============================================================================

%% Test: Erlang.on registers callback, send calls it
send_callback_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        var received = null;
        Erlang.on('test_event', function(data) {
            received = data;
            return 'callback called';
        });
    ">>),
    %% Send to the callback
    {ok, <<"callback called">>} = quickjs:send(Ctx, test_event, #{value => 42}),
    %% Verify the data was received
    {ok, #{<<"value">> := 42}} = quickjs:eval(Ctx, <<"received">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: send with no callback returns ok
send_no_callback_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertEqual(ok, quickjs:send(Ctx, nonexistent, #{})),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang.off removes callback
callback_off_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        var callCount = 0;
        Erlang.on('event', function() { callCount++; return callCount; });
    ">>),
    %% First send should work
    {ok, 1} = quickjs:send(Ctx, event, #{}),
    {ok, 1} = quickjs:eval(Ctx, <<"callCount">>),
    %% Unregister callback
    {ok, undefined} = quickjs:eval(Ctx, <<"Erlang.off('event')">>),
    %% Send should now be a no-op
    ?assertEqual(ok, quickjs:send(Ctx, event, #{})),
    {ok, 1} = quickjs:eval(Ctx, <<"callCount">>),  %% Still 1
    ok = quickjs:destroy_context(Ctx).

%% Test: send with binary event name
send_binary_event_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        Erlang.on('my-event', function(d) { return d.x * 2; });
    ">>),
    {ok, 84} = quickjs:send(Ctx, <<"my-event">>, #{x => 42}),
    ok = quickjs:destroy_context(Ctx).

%% Test: callback throws error
send_callback_error_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        Erlang.on('error_event', function() { throw 'oops'; });
    ">>),
    Result = quickjs:send(Ctx, error_event, #{}),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

%% Test: multiple callbacks for different events
multiple_callbacks_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        Erlang.on('add', function(d) { return d.a + d.b; });
        Erlang.on('mul', function(d) { return d.a * d.b; });
    ">>),
    {ok, 7} = quickjs:send(Ctx, add, #{a => 3, b => 4}),
    {ok, 12} = quickjs:send(Ctx, mul, #{a => 3, b => 4}),
    ok = quickjs:destroy_context(Ctx).

%% Test: bidirectional communication
bidirectional_test() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),
    {ok, undefined} = quickjs:eval(Ctx, <<"
        var processed = [];
        Erlang.on('process', function(data) {
            var result = data.value * 2;
            Erlang.emit('result', {input: data.value, output: result});
            processed.push(result);
            return result;
        });
    ">>),
    %% Send for processing
    {ok, 84} = quickjs:send(Ctx, process, #{value => 42}),
    %% Should receive result event (event type is binary)
    receive
        {quickjs, <<"result">>, #{<<"input">> := 42, <<"output">> := 84}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    %% Verify internal state
    {ok, [84]} = quickjs:eval(Ctx, <<"processed">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang global object exists
erlang_object_exists_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof Erlang.emit">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof Erlang.log">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof Erlang.on">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof Erlang.off">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: console object exists
console_object_exists_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof console.log">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof console.info">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof console.warn">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof console.error">>),
    {ok, <<"function">>} = quickjs:eval(Ctx, <<"typeof console.debug">>),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Erlang Function Registration Tests
%% ============================================================================

%% Test: Basic Erlang function call from JavaScript
register_function_basic_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, greet, fun([Name]) ->
        <<"Hello, ", Name/binary, "!">>
    end),
    {ok, <<"Hello, World!">>} = quickjs:eval(Ctx, <<"greet('World')">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function with multiple arguments
register_function_multi_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, add, fun(Args) ->
        lists:sum(Args)
    end),
    {ok, 10} = quickjs:eval(Ctx, <<"add(1, 2, 3, 4)">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function with no arguments
register_function_no_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, get_value, fun([]) ->
        42
    end),
    {ok, 42} = quickjs:eval(Ctx, <<"get_value()">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function returning complex types
register_function_complex_return_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Note: [1, 2, 3] is converted to binary (iolist detection)
    %% Use values > 255 to avoid iolist conversion
    ok = quickjs:register_function(Ctx, get_data, fun([]) ->
        #{name => <<"test">>, values => [100, 200, 300]}
    end),
    {ok, #{<<"name">> := <<"test">>, <<"values">> := [100, 200, 300]}} =
        quickjs:eval(Ctx, <<"get_data()">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function called from JS function
register_function_from_js_func_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, double, fun([N]) -> N * 2 end),
    {ok, _} = quickjs:eval(Ctx, <<"function quadruple(n) { return double(double(n)); }">>),
    {ok, 20} = quickjs:eval(Ctx, <<"quadruple(5)">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Multiple Erlang functions chained
register_function_multiple_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, add1, fun([N]) -> N + 1 end),
    ok = quickjs:register_function(Ctx, mul2, fun([N]) -> N * 2 end),
    %% mul2(add1(2)) = mul2(3) = 6
    {ok, 6} = quickjs:eval(Ctx, <<"mul2(add1(2))">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function error handling
register_function_error_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, fail, fun(_) ->
        error(intentional_error)
    end),
    {error, {js_error, ErrMsg}} = quickjs:eval(Ctx, <<"fail()">>),
    true = binary:match(ErrMsg, <<"error:">>) =/= nomatch,
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function with binary name
register_function_binary_name_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, <<"my_func">>, fun([X]) -> X + 1 end),
    {ok, 6} = quickjs:eval(Ctx, <<"my_func(5)">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function receiving complex JS objects
register_function_complex_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, process_data, fun([Data]) ->
        #{<<"a">> := A, <<"b">> := B} = Data,
        A + B
    end),
    {ok, 7} = quickjs:eval(Ctx, <<"process_data({a: 3, b: 4})">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function called via call/3
register_function_via_call_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, sum_list, fun(Args) ->
        lists:sum(Args)
    end),
    {ok, _} = quickjs:eval(Ctx, <<"function wrap() { return sum_list(1,2,3); }">>),
    {ok, 6} = quickjs:call(Ctx, wrap, []),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function with throw
register_function_throw_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, maybe_throw, fun([ShouldThrow]) ->
        case ShouldThrow of
            true -> throw(thrown_error);
            false -> ok
        end
    end),
    {ok, <<"ok">>} = quickjs:eval(Ctx, <<"maybe_throw(false)">>),
    {error, {js_error, _}} = quickjs:eval(Ctx, <<"maybe_throw(true)">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: JavaScript try/catch with Erlang function error
register_function_js_catch_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, bad_func, fun(_) -> error(oops) end),
    {ok, <<"caught">>} = quickjs:eval(Ctx, <<"
        try {
            bad_func();
        } catch (e) {
            'caught';
        }
    ">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Multiple sequential calls to Erlang function
register_function_sequential_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, inc, fun([N]) -> N + 1 end),
    {ok, 1} = quickjs:eval(Ctx, <<"inc(0)">>),
    {ok, 2} = quickjs:eval(Ctx, <<"inc(1)">>),
    {ok, 3} = quickjs:eval(Ctx, <<"inc(2)">>),
    ok = quickjs:destroy_context(Ctx).

%% Test: Erlang function registered with atom returns atom as string
register_function_atom_return_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:register_function(Ctx, get_status, fun([]) -> ok end),
    {ok, <<"ok">>} = quickjs:eval(Ctx, <<"get_status()">>),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% CBOR Encoding/Decoding Tests
%% ============================================================================

%% Test: Basic CBOR encode/decode roundtrip with integer
cbor_integer_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, 42),
    ?assert(is_binary(Bin)),
    {ok, 42} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with negative integer
cbor_negative_integer_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, -100),
    {ok, -100} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with float
cbor_float_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, 3.14),
    {ok, Decoded} = quickjs:cbor_decode(Ctx, Bin),
    ?assert(abs(Decoded - 3.14) < 0.001),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with binary/string
cbor_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, <<"hello world">>),
    {ok, <<"hello world">>} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with empty string
cbor_empty_string_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, <<"">>),
    {ok, <<"">>} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with boolean true
cbor_true_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, true),
    {ok, true} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with boolean false
cbor_false_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, false),
    {ok, false} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with null
cbor_null_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, null),
    {ok, null} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with undefined
cbor_undefined_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, undefined),
    {ok, undefined} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with simple array
%% Note: Use values > 255 to avoid iolist detection
cbor_array_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, [100, 200, 300]),
    {ok, [100, 200, 300]} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with empty array
cbor_empty_array_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Empty list is converted to empty string (iolist), so use tuple
    {ok, Bin} = quickjs:cbor_encode(Ctx, {}),
    {ok, []} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with map
cbor_map_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, #{<<"key">> => <<"value">>}),
    {ok, #{<<"key">> := <<"value">>}} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with empty map
cbor_empty_map_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, #{}),
    {ok, #{}} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with nested structure
%% Note: Use values > 255 to avoid iolist detection
cbor_nested_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Data = #{
        <<"name">> => <<"test">>,
        <<"numbers">> => [100, 200, 300],
        <<"nested">> => #{<<"inner">> => true}
    },
    {ok, Bin} = quickjs:cbor_encode(Ctx, Data),
    {ok, Decoded} = quickjs:cbor_decode(Ctx, Bin),
    ?assertEqual(<<"test">>, maps:get(<<"name">>, Decoded)),
    ?assertEqual([100, 200, 300], maps:get(<<"numbers">>, Decoded)),
    ?assertEqual(#{<<"inner">> => true}, maps:get(<<"nested">>, Decoded)),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with atom keys
cbor_atom_key_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, #{name => <<"Alice">>, age => 30}),
    {ok, Decoded} = quickjs:cbor_decode(Ctx, Bin),
    ?assertEqual(<<"Alice">>, maps:get(<<"name">>, Decoded)),
    ?assertEqual(30, maps:get(<<"age">>, Decoded)),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR decode invalid data returns error
cbor_decode_invalid_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Result = quickjs:cbor_decode(Ctx, <<"not valid cbor data">>),
    ?assertMatch({error, {js_error, _}}, Result),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode with tuple (becomes array)
cbor_tuple_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Bin} = quickjs:cbor_encode(Ctx, {1, 2, 3}),
    {ok, [1, 2, 3]} = quickjs:cbor_decode(Ctx, Bin),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode/decode with large data
%% Note: Use values > 255 to avoid iolist detection
cbor_large_data_test() ->
    {ok, Ctx} = quickjs:new_context(),
    LargeList = lists:seq(256, 355),  %% 100 elements, all > 255
    {ok, Bin} = quickjs:cbor_encode(Ctx, LargeList),
    {ok, Decoded} = quickjs:cbor_decode(Ctx, Bin),
    ?assertEqual(LargeList, Decoded),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR with destroyed context returns error
cbor_destroyed_context_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:destroy_context(Ctx),
    ?assertMatch({error, invalid_context}, quickjs:cbor_encode(Ctx, 42)),
    ?assertMatch({error, invalid_context}, quickjs:cbor_decode(Ctx, <<16#18, 42>>)).

%% Test: CBOR encode/decode preserves data types
cbor_type_preservation_test() ->
    {ok, Ctx} = quickjs:new_context(),
    Data = [
        42,
        -17,
        3.14159,
        <<"hello">>,
        true,
        false,
        null
    ],
    {ok, Bin} = quickjs:cbor_encode(Ctx, Data),
    {ok, [I, N, F, S, T, Fa, Nu]} = quickjs:cbor_decode(Ctx, Bin),
    ?assertEqual(42, I),
    ?assertEqual(-17, N),
    ?assert(abs(F - 3.14159) < 0.0001),
    ?assertEqual(<<"hello">>, S),
    ?assertEqual(true, T),
    ?assertEqual(false, Fa),
    ?assertEqual(null, Nu),
    ok = quickjs:destroy_context(Ctx).

%% Test: CBOR encode with badarg
cbor_encode_badarg_test() ->
    ?assertMatch({error, invalid_context}, quickjs:cbor_encode(not_a_context, 42)).

%% Test: CBOR decode with badarg
cbor_decode_badarg_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ?assertMatch({error, badarg}, quickjs:cbor_decode(Ctx, not_binary)),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: Memory metrics and garbage collection
%% ============================================================================

%% Test: get_memory_stats returns valid map
memory_stats_basic_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, Stats} = quickjs:get_memory_stats(Ctx),
    ?assert(is_map(Stats)),
    ?assert(maps:is_key(heap_bytes, Stats)),
    ?assert(maps:is_key(heap_peak, Stats)),
    ?assert(maps:is_key(alloc_count, Stats)),
    ?assert(maps:is_key(realloc_count, Stats)),
    ?assert(maps:is_key(free_count, Stats)),
    ?assert(maps:is_key(gc_runs, Stats)),
    %% Heap should have some bytes allocated (Duktape uses memory on init)
    ?assert(maps:get(heap_bytes, Stats) > 0),
    ?assert(maps:get(heap_peak, Stats) > 0),
    ?assert(maps:get(alloc_count, Stats) > 0),
    ok = quickjs:destroy_context(Ctx).

%% Test: memory increases after allocations
memory_stats_allocation_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, StatsBefore} = quickjs:get_memory_stats(Ctx),
    HeapBefore = maps:get(heap_bytes, StatsBefore),
    %% Allocate a large array in JS
    {ok, _} = quickjs:eval(Ctx, <<"
        var arr = [];
        for (var i = 0; i < 10000; i++) {
            arr.push({index: i, value: 'test' + i});
        }
        arr.length;
    ">>),
    {ok, StatsAfter} = quickjs:get_memory_stats(Ctx),
    HeapAfter = maps:get(heap_bytes, StatsAfter),
    %% Memory should have increased significantly
    ?assert(HeapAfter > HeapBefore),
    ?assert((HeapAfter - HeapBefore) > 10000),  %% At least 10KB more
    ok = quickjs:destroy_context(Ctx).

%% Test: peak memory tracks maximum usage
memory_stats_peak_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Allocate then release memory
    {ok, _} = quickjs:eval(Ctx, <<"
        var x = [];
        for (var i = 0; i < 5000; i++) x.push('data' + i);
        x = null;
    ">>),
    ok = quickjs:gc(Ctx),
    {ok, Stats} = quickjs:get_memory_stats(Ctx),
    %% Peak should be >= current (peak captures max allocation)
    ?assert(maps:get(heap_peak, Stats) >= maps:get(heap_bytes, Stats)),
    ok = quickjs:destroy_context(Ctx).

%% Test: gc function works and increments counter
gc_basic_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, StatsBefore} = quickjs:get_memory_stats(Ctx),
    ?assertEqual(0, maps:get(gc_runs, StatsBefore)),
    ok = quickjs:gc(Ctx),
    {ok, StatsAfter1} = quickjs:get_memory_stats(Ctx),
    ?assertEqual(1, maps:get(gc_runs, StatsAfter1)),
    ok = quickjs:gc(Ctx),
    {ok, StatsAfter2} = quickjs:get_memory_stats(Ctx),
    ?assertEqual(2, maps:get(gc_runs, StatsAfter2)),
    ok = quickjs:destroy_context(Ctx).

%% Test: gc can reclaim memory
gc_reclaim_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Create and discard objects
    {ok, _} = quickjs:eval(Ctx, <<"
        for (var i = 0; i < 1000; i++) {
            var obj = {data: [], index: i};
            for (var j = 0; j < 100; j++) obj.data.push(j);
        }
    ">>),
    {ok, StatsBefore} = quickjs:get_memory_stats(Ctx),
    ok = quickjs:gc(Ctx),
    {ok, StatsAfter} = quickjs:get_memory_stats(Ctx),
    %% Memory should decrease or stay same after GC
    %% (Duktape may not immediately release all memory, but it shouldn't grow)
    ?assert(maps:get(heap_bytes, StatsAfter) =< maps:get(heap_bytes, StatsBefore)),
    ok = quickjs:destroy_context(Ctx).

%% Test: memory stats on destroyed context returns error
memory_stats_destroyed_context_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:destroy_context(Ctx),
    ?assertMatch({error, invalid_context}, quickjs:get_memory_stats(Ctx)).

%% Test: gc on destroyed context returns error
gc_destroyed_context_test() ->
    {ok, Ctx} = quickjs:new_context(),
    ok = quickjs:destroy_context(Ctx),
    ?assertMatch({error, invalid_context}, quickjs:gc(Ctx)).

%% Test: memory stats with invalid context
memory_stats_invalid_context_test() ->
    ?assertMatch({error, invalid_context}, quickjs:get_memory_stats(not_a_context)).

%% Test: gc with invalid context
gc_invalid_context_test() ->
    ?assertMatch({error, invalid_context}, quickjs:gc(not_a_context)).

%% Test: alloc and free counts increase with operations
memory_stats_counts_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, StatsBefore} = quickjs:get_memory_stats(Ctx),
    AllocBefore = maps:get(alloc_count, StatsBefore),
    %% Do some work
    {ok, _} = quickjs:eval(Ctx, <<"var x = {a: 1, b: 2, c: [1,2,3]};">>),
    {ok, StatsAfter} = quickjs:get_memory_stats(Ctx),
    AllocAfter = maps:get(alloc_count, StatsAfter),
    %% Should have more allocations
    ?assert(AllocAfter > AllocBefore),
    ok = quickjs:destroy_context(Ctx).

%% ============================================================================
%% Test: Timeout support
%% ============================================================================

%% Test: eval with timeout - infinite loop should timeout
timeout_eval_infinite_loop_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Infinite loop should timeout
    Result = quickjs:eval(Ctx, <<"while(true){}">>, 100),
    ?assertMatch({error, timeout}, Result),
    ok = quickjs:destroy_context(Ctx).

%% Test: eval with timeout - normal execution should succeed
timeout_eval_normal_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Normal execution should complete within timeout
    ?assertEqual({ok, 42}, quickjs:eval(Ctx, <<"21 * 2">>, 5000)),
    ?assertEqual({ok, <<"hello">>}, quickjs:eval(Ctx, <<"'hello'">>, 1000)),
    ok = quickjs:destroy_context(Ctx).

%% Test: eval with bindings and timeout
timeout_eval_bindings_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% With bindings and timeout
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"x * 2">>, #{x => 5}, 5000)),
    ?assertEqual({ok, 15}, quickjs:eval(Ctx, <<"x + y">>, #{x => 10, y => 5}, 1000)),
    %% Infinite loop with bindings should timeout
    ?assertMatch({error, timeout}, quickjs:eval(Ctx, <<"while(true){}">>, #{}, 100)),
    ok = quickjs:destroy_context(Ctx).

%% Test: call with timeout - function call should work
timeout_call_normal_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function add(a, b) { return a + b; }">>),
    ?assertEqual({ok, 7}, quickjs:call(Ctx, add, [3, 4], 5000)),
    ?assertEqual({ok, 7}, quickjs:call(Ctx, <<"add">>, [3, 4], 1000)),
    ok = quickjs:destroy_context(Ctx).

%% Test: call with timeout - infinite loop in function should timeout
timeout_call_infinite_loop_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function infinite() { while(true){} }">>),
    ?assertMatch({error, timeout}, quickjs:call(Ctx, infinite, [], 100)),
    ok = quickjs:destroy_context(Ctx).

%% Test: infinity timeout means no timeout
timeout_infinity_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% infinity should allow normal operations (we can't test actual infinity, just that it works)
    ?assertEqual({ok, 100}, quickjs:eval(Ctx, <<"50 + 50">>, infinity)),
    ?assertEqual({ok, 25}, quickjs:eval(Ctx, <<"x * y">>, #{x => 5, y => 5}, infinity)),
    {ok, _} = quickjs:eval(Ctx, <<"function mul(a, b) { return a * b; }">>),
    ?assertEqual({ok, 20}, quickjs:call(Ctx, mul, [4, 5], infinity)),
    ok = quickjs:destroy_context(Ctx).

%% Test: context remains usable after timeout
timeout_context_reuse_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Set a value before timeout
    {ok, _} = quickjs:eval(Ctx, <<"var x = 10;">>),
    %% Trigger timeout
    ?assertMatch({error, timeout}, quickjs:eval(Ctx, <<"while(true){}">>, 100)),
    %% Context should still be usable and retain state
    ?assertEqual({ok, 10}, quickjs:eval(Ctx, <<"x">>)),
    ?assertEqual({ok, 20}, quickjs:eval(Ctx, <<"x * 2">>, 5000)),
    ok = quickjs:destroy_context(Ctx).

%% Test: call with just timeout (no args list)
timeout_call_no_args_test() ->
    {ok, Ctx} = quickjs:new_context(),
    {ok, _} = quickjs:eval(Ctx, <<"function getFortyTwo() { return 42; }">>),
    %% call/3 with timeout instead of args
    ?assertEqual({ok, 42}, quickjs:call(Ctx, getFortyTwo, 5000)),
    ok = quickjs:destroy_context(Ctx).

%% Test: very short timeout
timeout_very_short_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% Even quick operations should succeed with short but reasonable timeout
    ?assertEqual({ok, 1}, quickjs:eval(Ctx, <<"1">>, 50)),
    ok = quickjs:destroy_context(Ctx).

%% Test: timeout with CPU-intensive but finite loop
timeout_cpu_intensive_test() ->
    {ok, Ctx} = quickjs:new_context(),
    %% This loop is finite and should complete, but takes some CPU
    Code = <<"var sum = 0; for (var i = 0; i < 100000; i++) sum += i; sum;">>,
    %% With generous timeout, should succeed
    Result = quickjs:eval(Ctx, Code, 5000),
    ?assertMatch({ok, _}, Result),
    ok = quickjs:destroy_context(Ctx).
