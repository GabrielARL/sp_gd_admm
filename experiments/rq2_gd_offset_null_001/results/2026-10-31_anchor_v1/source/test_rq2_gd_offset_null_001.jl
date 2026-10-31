#!/usr/bin/env julia
# Focused tests for RQ2-GD-OFFSET-NULL-001.  Run with the registered one-thread
# environment:  OMP_NUM_THREADS=1 julia --project=<jade worktree> this_file.jl

using Test
using Random
include(joinpath(@__DIR__, "rq2_gd_offset_null_001.jl"))
const N = RQ2GDOffsetNull001
const Legacy = N.Legacy
const Split = N.Split

ENV["OMP_NUM_THREADS"] = "1"

@testset "RQ2-GD-OFFSET-NULL-001" begin
    config = N.load_config()
    split = N.load_split_config(config)
    gate = N.source_gate(config)
    @test gate["passed"]
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = Legacy.make_code(split, native)
    code = generated.code

    @testset "derangements" begin
        rng = MersenneTwister(1)
        for degree in 2:6, _ in 1:50
            perm = N.derangement(rng, degree)
            @test sort(perm) == 1:degree
            @test all(perm[k] != k for k in 1:degree)
        end
    end

    frame = first(N.stage_frames(config, :anchor))
    input = Legacy.generate_input(split, native, code, frame)
    problem = N.problem_for(split, code, input.clipped_llr)
    initial = tanh.(input.clipped_llr ./ 2)
    keywords = N.solver_keywords(split)

    @testset "permutation preserves each bit's multiset and zero sum" begin
        rng = MersenneTwister(7)
        delta = Legacy.zero_edge_rows(problem.check_vars)
        for incident in problem.var_edges
            values = randn(rng, length(incident))
            values .-= sum(values) / length(values)
            for (position, (check_index, slot)) in enumerate(incident)
                delta[check_index][slot] = values[position]
            end
        end
        before = N.per_bit_sorted_offsets(delta, problem)
        sums_before = [sum(delta[c][s] for (c, s) in incident)
                       for incident in problem.var_edges]
        report = N.permute_offsets!(delta, problem, MersenneTwister(3))
        @test report.multiset_preserved
        @test report.unmoved == 0
        @test report.moved == sum(length, problem.var_edges)
        @test N.per_bit_sorted_offsets(delta, problem) == before
        sums_after = [sum(delta[c][s] for (c, s) in incident)
                      for incident in problem.var_edges]
        @test maximum(abs.(sums_after .- sums_before)) <= 1.0e-12
    end

    reference = Split.solve_variant(problem, code, initial, N.COMPOUND_SPEC;
        keywords..., collect_trace=true, collect_diagnostics=true,
        validate_derivatives=false, snapshot_updates=Set([1, 2]))
    copied = N.solve_null_variant(problem, code, initial, :reference;
        keywords..., snapshot_updates=Set([1, 2]))

    @testset "copied kernel equals retained compound kernel" begin
        @test copied.hard == reference.hard
        @test N.vector_sha256(copied.x) == N.vector_sha256(reference.x)
        @test N.edge_sha256(copied.delta) == N.edge_sha256(reference.delta)
        @test copied.accepted_steps == reference.accepted_steps
        @test [r["x_after_sha256"] for r in copied.trace] ==
              [r["x_after_sha256"] for r in reference.trace]
    end

    frozen = N.solve_null_variant(problem, code, initial, :frozen;
        keywords..., snapshot_updates=Set([1, 2]))
    permuted = N.solve_null_variant(problem, code, initial, :permuted;
        permutation_seed=20261101 + frame, keywords...,
        snapshot_updates=Set([1, 2]))
    control = Split.solve_variant(problem, code, initial, N.CONTROL_SPEC;
        keywords..., collect_trace=true, collect_diagnostics=true,
        validate_derivatives=false, snapshot_updates=Set([1, 2]))

    @testset "frozen arm: one refresh, equal to reference through update 2" begin
        @test frozen.offset_refreshes == 1
        deltas = [r["delta_after_sha256"] for r in frozen.trace if r["accepted"]]
        @test allequal(deltas)
        @test N.trace_value(frozen, 1, "delta_after_sha256") ==
              N.trace_value(reference, 1, "delta_after_sha256")
        @test N.trace_value(frozen, 2, "x_after_sha256") ==
              N.trace_value(reference, 2, "x_after_sha256")
        @test frozen.all_refreshed_readings_in_box
        @test frozen.all_projection_feasibility_checks_passed
    end

    @testset "permuted arm: same multiset at update 1, moved edges, divergence at 2" begin
        @test permuted.all_multisets_preserved
        @test permuted.permutation_distinguishable_bits > 0
        @test permuted.permutation_unchanged_distinguishable_bits == 0
        # Most bits carry all-equal (zero) offsets at a typical refresh, so the
        # raw moved/unmoved edge counts are diagnostics, not a gate.
        @test permuted.permutation_moved_edges > 0
        @test N.per_bit_sorted_offsets(permuted.snapshots[1].delta, problem) ==
              N.per_bit_sorted_offsets(reference.snapshots[1].delta, problem)
        @test N.trace_value(permuted, 1, "x_after_sha256") ==
              N.trace_value(reference, 1, "x_after_sha256")
        @test N.trace_value(permuted, 2, "x_after_sha256") !=
              N.trace_value(reference, 2, "x_after_sha256")
        @test permuted.all_refreshed_readings_in_box
        @test permuted.all_mean_constraints_passed
        again = N.solve_null_variant(problem, code, initial, :permuted;
            permutation_seed=20261101 + frame, keywords...)
        @test N.vector_sha256(again.x) == N.vector_sha256(permuted.x)
    end

    @testset "frame gates on one frame" begin
        results = Dict{String,Any}("control" => N.retained_result(control, :control),
            "reference" => N.retained_result(reference, :reference),
            "permuted" => permuted, "frozen" => frozen)
        gates = N.frame_gates(results, problem)
        for (key, value) in gates
            @test value
        end
        @test all(values(gates))
    end

    @testset "paired contrasts" begin
        rows = [(; frame=1, arm="reference", transmitted_word_equal=true, parity_valid=true),
                (; frame=1, arm="control", transmitted_word_equal=false, parity_valid=false),
                (; frame=1, arm="permuted", transmitted_word_equal=false, parity_valid=false),
                (; frame=1, arm="frozen", transmitted_word_equal=true, parity_valid=true),
                (; frame=2, arm="reference", transmitted_word_equal=true, parity_valid=true),
                (; frame=2, arm="control", transmitted_word_equal=true, parity_valid=true),
                (; frame=2, arm="permuted", transmitted_word_equal=true, parity_valid=true),
                (; frame=2, arm="frozen", transmitted_word_equal=false, parity_valid=false)]
        table = N.contrast_table(rows)
        c = table["transmitted_word_equal"]["contrasts"]["reference_vs_permuted"]
        @test c["treatment_only_success"] == 1 && c["reference_only_success"] == 0
        N.add_inference!(table, 0.995)
        @test haskey(c, "holm_adjusted_pvalue")
        @test 0.0 <= c["holm_adjusted_pvalue"] <= 1.0
    end
end
