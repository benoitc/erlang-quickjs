# CBOR Encoding

Binary serialization for efficient data transfer using CBOR (Concise Binary Object Representation).

## Overview

CBOR is a binary data format that is:
- More compact than JSON
- Faster to parse
- Supports binary data natively
- Self-describing

QuickJS uses its native CBOR implementation for encoding and decoding.

## Basic Usage

### Encoding

Convert Erlang values to CBOR binary:

```erlang
{ok, Ctx} = quickjs:new_context().

%% Encode simple values
{ok, Bin1} = quickjs:cbor_encode(Ctx, 42).
{ok, Bin2} = quickjs:cbor_encode(Ctx, <<"hello">>).
{ok, Bin3} = quickjs:cbor_encode(Ctx, true).

%% Encode complex structures
{ok, Bin4} = quickjs:cbor_encode(Ctx, #{
    name => <<"Alice">>,
    age => 30,
    tags => [<<"admin">>, <<"user">>]
}).
```

### Decoding

Convert CBOR binary back to Erlang values:

```erlang
{ok, 42} = quickjs:cbor_decode(Ctx, Bin1).
{ok, <<"hello">>} = quickjs:cbor_decode(Ctx, Bin2).
{ok, true} = quickjs:cbor_decode(Ctx, Bin3).

{ok, #{
    <<"name">> := <<"Alice">>,
    <<"age">> := 30,
    <<"tags">> := [<<"admin">>, <<"user">>]
}} = quickjs:cbor_decode(Ctx, Bin4).
```

## Supported Types

| Erlang Type | CBOR Type | Notes |
|-------------|-----------|-------|
| `integer()` | Integer | Full range supported |
| `float()` | Float | IEEE 754 double |
| `binary()` | Text string | UTF-8 encoded |
| `true/false` | Boolean | |
| `null` | Null | |
| `undefined` | Undefined | |
| `list()` | Array | |
| `map()` | Map | |

## Roundtrip Example

```erlang
{ok, Ctx} = quickjs:new_context().

Original = #{
    users => [
        #{id => 1, name => <<"Alice">>, active => true},
        #{id => 2, name => <<"Bob">>, active => false}
    ],
    metadata => #{
        version => <<"1.0">>,
        count => 2
    }
}.

%% Encode
{ok, Binary} = quickjs:cbor_encode(Ctx, Original).

%% Binary is compact
byte_size(Binary).  %% Much smaller than JSON

%% Decode
{ok, Decoded} = quickjs:cbor_decode(Ctx, Binary).

%% Values match (note: atom keys become binary keys)
#{<<"users">> := Users} = Decoded.
```

## Use Cases

### Inter-Process Communication

CBOR is ideal for sending data between Erlang processes and JavaScript:

```erlang
%% Encode data in one context
{ok, Ctx1} = quickjs:new_context().
{ok, Binary} = quickjs:cbor_encode(Ctx1, large_data_structure()).

%% Decode in another context
{ok, Ctx2} = quickjs:new_context().
{ok, Data} = quickjs:cbor_decode(Ctx2, Binary).
```

### File Storage

Store structured data efficiently:

```erlang
save_config(Ctx, Config, Filename) ->
    {ok, Binary} = quickjs:cbor_encode(Ctx, Config),
    file:write_file(Filename, Binary).

load_config(Ctx, Filename) ->
    {ok, Binary} = file:read_file(Filename),
    quickjs:cbor_decode(Ctx, Binary).
```

### Network Protocol

Use CBOR for wire protocols:

```erlang
send_message(Ctx, Socket, Message) ->
    {ok, Binary} = quickjs:cbor_encode(Ctx, Message),
    Size = byte_size(Binary),
    gen_tcp:send(Socket, <<Size:32, Binary/binary>>).

receive_message(Ctx, Socket) ->
    {ok, <<Size:32>>} = gen_tcp:recv(Socket, 4),
    {ok, Binary} = gen_tcp:recv(Socket, Size),
    quickjs:cbor_decode(Ctx, Binary).
```

## Performance

CBOR operations run on dirty schedulers to avoid blocking the Erlang VM:

```erlang
%% These operations won't block other Erlang processes
{ok, _} = quickjs:cbor_encode(Ctx, very_large_structure()),
{ok, _} = quickjs:cbor_decode(Ctx, large_binary()).
```

Typical performance on modern hardware:
- Encode: ~1,900 ops/sec for complex structures
- Decode: ~1,900 ops/sec for complex structures
- Roundtrip: ~1,850 ops/sec

## Error Handling

```erlang
%% Invalid CBOR binary
{error, _} = quickjs:cbor_decode(Ctx, <<"not valid cbor">>).

%% Invalid context
{error, invalid_context} = quickjs:cbor_encode(destroyed_ctx, data).
```
