#!/bin/sh
#
# Run quickjs benchmarks
#
# Usage:
#   ./run_bench.sh              # Run all benchmarks
#   ./run_bench.sh eval_simple  # Run specific benchmark
#   ./run_bench.sh --help       # Show help
#

set -e

BENCH_MODULE="quickjs_bench"

show_help() {
    echo "Usage: $0 [OPTIONS] [BENCHMARK]"
    echo ""
    echo "Run quickjs performance benchmarks"
    echo ""
    echo "Options:"
    echo "  --help, -h     Show this help message"
    echo "  --list, -l     List available benchmarks"
    echo "  --smoke        Run smoke test only (quick validation)"
    echo ""
    echo "Benchmarks:"
    echo "  eval_simple              Simple arithmetic expressions"
    echo "  eval_complex             Complex JS (functions, loops)"
    echo "  eval_bindings_small      eval/3 with 5 bindings"
    echo "  eval_bindings_large      eval/3 with 50 bindings"
    echo "  call_no_args             call/2 overhead"
    echo "  call_with_args           call/3 with 5 arguments"
    echo "  call_many_args           call/3 with 20 arguments"
    echo "  type_convert_simple      Integer/string round-trip"
    echo "  type_convert_array       Large array conversion (1000 elements)"
    echo "  type_convert_nested      Nested map/array conversion"
    echo "  context_create           new_context/0 overhead"
    echo "  module_require_cached    require/2 cached module"
    echo "  concurrent_same_context  Multi-process same context"
    echo "  concurrent_many_contexts Multi-process separate contexts"
    echo ""
    echo "Examples:"
    echo "  $0                       # Run all benchmarks"
    echo "  $0 eval_simple           # Run single benchmark"
    echo "  $0 --smoke               # Quick validation"
}

list_benchmarks() {
    echo "Available benchmarks:"
    echo "  eval_simple"
    echo "  eval_complex"
    echo "  eval_bindings_small"
    echo "  eval_bindings_large"
    echo "  call_no_args"
    echo "  call_with_args"
    echo "  call_many_args"
    echo "  type_convert_simple"
    echo "  type_convert_array"
    echo "  type_convert_nested"
    echo "  context_create"
    echo "  module_require_cached"
    echo "  concurrent_same_context"
    echo "  concurrent_many_contexts"
}

run_smoke() {
    echo "Running smoke test..."
    rebar3 as bench eunit --module=$BENCH_MODULE
}

run_all() {
    echo "Running all benchmarks..."
    rebar3 as bench compile
    erl -pa _build/bench/lib/*/ebin -pa _build/bench/lib/*/bench -noshell -eval "${BENCH_MODULE}:run_all(), init:stop()."
}

run_single() {
    echo "Running benchmark: $1"
    rebar3 as bench compile
    erl -pa _build/bench/lib/*/ebin -pa _build/bench/lib/*/bench -noshell -eval "${BENCH_MODULE}:run($1), init:stop()."
}

# Parse arguments
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --list|-l)
        list_benchmarks
        exit 0
        ;;
    --smoke)
        run_smoke
        ;;
    "")
        run_all
        ;;
    *)
        run_single "$1"
        ;;
esac
