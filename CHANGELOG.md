# Changelog

## 0.2.0 (2026-08-10)

- Update the embedded engine to [QuickJS-NG](https://github.com/quickjs-ng/quickjs) v0.16.1 (from v0.14.0). No API changes.
- Build QuickJS with optimization. `c_src/CMakeLists.txt` never set `CMAKE_BUILD_TYPE`, so CMake passed no `-O` flag and every prior release shipped an unoptimized engine. Upstream defaults to `Release`; this now does the same. Benchmarks are ~3.4x faster (`eval_simple` 1,197 to 4,133 ops/sec).
- Stop the compile hook from resetting the `quickjs-ng` submodule. The unconditional `git submodule update` ran on every compile and discarded a deliberate version bump before it could be staged. It now only populates the submodule when missing, which also lets a hex tarball build without git.
- README benchmark tables re-measured. They track context creation and teardown rather than JavaScript execution, since each iteration builds and destroys a context; the README now says so.

## 0.1.0 (2026-05-01)

Initial release. API-compatible replacement for `erlang-duktape`, backed by [QuickJS-NG](https://github.com/quickjs-ng/quickjs) v0.16.1.

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
