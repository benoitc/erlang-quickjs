# Event Framework

Bidirectional communication between JavaScript and Erlang processes.

## Overview

The event framework allows:
- Erlang processes to send data to JavaScript callbacks
- JavaScript to emit events back to Erlang
- Structured logging from JavaScript to Erlang

## Setup

Create a context with an event handler:

```erlang
{ok, Ctx} = quickjs:new_context(#{handler => self()}).
```

The handler process will receive messages from JavaScript.

## Sending Data to JavaScript

Use `send/3` to trigger JavaScript callbacks:

```erlang
%% Register a callback in JavaScript
{ok, _} = quickjs:eval(Ctx, <<"
    Erlang.on('greeting', function(data) {
        return 'Hello, ' + data.name + '!';
    });
">>).

%% Send data from Erlang
{ok, <<"Hello, Alice!">>} = quickjs:send(Ctx, greeting, #{name => <<"Alice">>}).
```

## Emitting Events from JavaScript

JavaScript can emit events to the Erlang handler:

```erlang
{ok, Ctx} = quickjs:new_context(#{handler => self()}).

{ok, _} = quickjs:eval(Ctx, <<"
    Erlang.emit('user_action', {type: 'click', x: 100, y: 200});
">>).

%% Receive the event (event type is a binary)
receive
    {quickjs, <<"user_action">>, Data} ->
        #{<<"type">> := <<"click">>, <<"x">> := 100, <<"y">> := 200} = Data
end.
```

## JavaScript API

### `Erlang.on(event, callback)`

Register a callback for an event type:

```javascript
Erlang.on('data', function(payload) {
    // Process payload
    return result;  // Returned to Erlang
});
```

### `Erlang.off(event)`

Unregister a callback:

```javascript
Erlang.off('data');
```

### `Erlang.emit(type, data)`

Emit an event to the Erlang handler:

```javascript
Erlang.emit('status', {ready: true});
```

### `Erlang.log(level, ...args)`

Send structured log messages:

```javascript
Erlang.log('info', 'User logged in', {userId: 123});
Erlang.log('error', 'Connection failed', {reason: 'timeout'});
```

## Console Object

Standard console methods are available and route to `Erlang.log`:

```javascript
console.log('Info message');      // level: info
console.info('Info message');     // level: info
console.warn('Warning message');  // level: warning
console.error('Error message');   // level: error
console.debug('Debug message');   // level: debug
```

The handler receives:

```erlang
{quickjs, log, #{level => info, message => <<"Info message">>}}
```

## Complete Example

```erlang
-module(event_example).
-export([run/0]).

run() ->
    {ok, Ctx} = quickjs:new_context(#{handler => self()}),

    %% Set up JavaScript handlers
    {ok, _} = quickjs:eval(Ctx, <<"
        var counter = 0;

        Erlang.on('increment', function(data) {
            counter += data.amount;
            Erlang.emit('counter_updated', {value: counter});
            return counter;
        });

        Erlang.on('get_counter', function() {
            return counter;
        });
    ">>),

    %% Interact from Erlang
    {ok, 5} = quickjs:send(Ctx, increment, #{amount => 5}),
    {ok, 8} = quickjs:send(Ctx, increment, #{amount => 3}),
    {ok, 8} = quickjs:send(Ctx, get_counter, #{}),

    %% Receive emitted events
    receive_events(),

    ok = quickjs:destroy_context(Ctx).

receive_events() ->
    receive
        {quickjs, Event, Data} ->
            io:format("Event: ~p, Data: ~p~n", [Event, Data]),
            receive_events()
    after 0 ->
        ok
    end.
```
