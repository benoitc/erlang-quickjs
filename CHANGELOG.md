# Changelog

## 0.1.0 (unreleased)

Initial release. API-compatible replacement for `erlang-duktape`, backed by [QuickJS-NG](https://github.com/quickjs-ng/quickjs) v0.14.0.

- Multiple isolated JavaScript contexts.
- `eval/2,3,4` and `call/2,3,4` with bindings, arguments, and execution timeouts.
- Bidirectional Erlang/JS type conversion (integer, float, binary, atom, list, map, tuple, NaN/Infinity).
- CommonJS modules via `register_module/3` and `require/2`.
- Event framework: `Erlang.emit`, `Erlang.log`, `Erlang.on/off`, `console.{log,info,warn,error,debug}`, `quickjs:send/3`.
- Erlang functions callable from JS via `register_function/3` (re-eval trampoline pattern).
- CBOR `cbor_encode/2` and `cbor_decode/2` via embedded JS shim.
- Memory metrics (`get_memory_stats/1`) and forced GC (`gc/1`) via custom allocator and `JS_RunGC`.
- Execution timeouts via `JS_SetInterruptHandler`.
- Test suite ported from `erlang-duktape` (183 tests, all passing).
