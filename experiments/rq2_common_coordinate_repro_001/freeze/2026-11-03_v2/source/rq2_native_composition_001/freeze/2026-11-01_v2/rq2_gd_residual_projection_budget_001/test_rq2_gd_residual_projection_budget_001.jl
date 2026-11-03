#!/usr/bin/env julia

using Test

include(joinpath(@__DIR__, "rq2_gd_residual_projection_budget_001.jl"))
const Study = RQ2GDResidualProjectionBudget001

@testset "registered configuration and frozen v4 evidence" begin
    config = Study.load_config()
    @test Study.source_gate(config)["passed"]
    @test collect(Study.stage_frames(config, :calibration)) == collect(20001:20024)
    @test collect(Study.stage_frames(config, :anchor)) == collect(50001:50024)
    @test collect(Study.stage_frames(config, :transfer)) == collect(50025:50224)
    @test collect(Study.stage_frames(config, :attribution)) == collect(30001:30200)
    @test [arm.name for arm in Study.ARMS] == [
        "compound__box", "product_only__box",
        "compound__unconstrained", "product_only__unconstrained"]

    mktempdir() do root
        freeze = joinpath(root, "freeze")
        Study.prepare_freeze(freeze)
        gate = Study.frozen_reference_gate(config, freeze)
        @test gate["passed"]
        @test isfile(joinpath(freeze, "freeze_manifest.toml"))
        @test_throws ArgumentError Study.prepare_freeze(freeze)
    end
end

@testset "both declared objectives pass independent derivatives" begin
    code = (n=3, check_vars=[Int[1, 2], Int[2, 3]])
    problem = Study.BridgeProblem(code, [0.7, -0.2, 0.4];
        parity_weight=2.0, binary_weight=0.2)
    x = [0.35, -0.15, 0.55]
    delta = [[0.04, -0.03], [0.02, -0.01]]
    for rule in (:compound, :product_only)
        workspace = Study.Legacy.EvalWorkspace(problem)
        evaluated = Study.evaluate_objective!(workspace, problem, x, delta, rule)
        fd = Study.finite_difference_maximum(
            problem, x, delta, copy(evaluated.gradient), rule; step=1.0e-6)
        @test fd.maximum_error <= 3.0e-9
        @test fd.delta_sha256_before == fd.delta_sha256_after
    end

    workspace = Study.Legacy.EvalWorkspace(problem)
    evaluated = Study.product_only_evaluate!(workspace, problem, x, delta)
    products = (x[1] + delta[1][1]) * (x[2] + delta[1][2]) +
        (x[2] + delta[2][1]) * (x[3] + delta[2][2])
    @test evaluated.terms.parity == -2problem.parity_weight / length(x) * products
end

@testset "compound boxed continuation is exactly the retained frozen kernel" begin
    config = Study.load_config()
    split_config = Study.V4.load_config(Study.v4_config_path(config))
    split = Study.V4.load_split_config(split_config)
    Study.Legacy.enforce_thread_environment(split)
    native = Study.Split.load_native(split)
    generated = Study.Split.make_code(split, native)
    input = Study.Split.generate_input(split, native, generated.code, 20001)
    problem = Study.V4.problem_for(split, generated.code, input.clipped_llr)
    initial = tanh.(input.clipped_llr ./ 2.0)
    seed = Study.common_update_one(
        problem, generated.code, initial, split, config)

    short = deepcopy(config)
    short["solver"]["maximum_update_attempts"] = 3
    short["solver"]["score_updates"] = [2, 3]
    short["validation"]["finite_difference_updates"] = [2, 3]
    observed = Study.solve_arm(
        problem, generated.code, initial, seed, Study.ARMS[1], short)
    reference = Study.V4.solve_factorial_variant(
        problem, generated.code, initial, :asbuilt__frozen;
        permutation_seed=0, maximum_updates=3,
        initial_step=Float64(short["solver"]["initial_step"]),
        maximum_backtracks=Int(short["solver"]["maximum_backtracks"]),
        collect_trace=true, collect_diagnostics=true,
        validate_derivatives=true,
        finite_difference_step=Float64(
            short["validation"]["finite_difference_step"]),
        finite_difference_tolerance=Float64(
            short["validation"]["finite_difference_tolerance"]),
        mean_tolerance=Float64(split["validation"]["mean_offset_tolerance"]),
        box_tolerance=Float64(split["validation"]["box_tolerance"]))
    @test Study.vector_sha256(observed.x) == Study.vector_sha256(reference.x)
    @test Study.edge_sha256(observed.delta) == Study.edge_sha256(reference.delta)
    @test observed.checkpoints[3].hard_word_sha256 ==
        Study.vector_sha256(reference.hard)
    @test observed.all_strict_decrease
end

@testset "endpoint sentinel gate keeps fresh outcomes open" begin
    config = Study.load_config()
    rows = NamedTuple[]
    methods = String.(config["endpoint_gate"]["methods"])
    for frame in 1:200, method in methods
        threshold = method == "gd_native_projected" ? 107 :
            method == "v4_asbuilt_frozen" ? 167 : 200
        success = frame <= threshold
        push!(rows, (; frame, method,
            hard_word_sha256="$(method)-$(frame)",
            coded_bit_errors=success ? 0 : 1,
            syndrome_weight=success ? 0 : 1,
            parity_valid=success,
            transmitted_word_equal=success,
            iterations=method == "v4_asbuilt_frozen" ? 30 : 1,
            status=method == "v4_asbuilt_frozen" ? "steps_completed" :
                "synthetic"))
    end
    attribution = Study.endpoint_gate_summary(rows, config, :attribution)
    @test attribution["passed"]
    @test attribution["expected_counts_applied"]
    @test length(attribution["hard_word_table_sha256"]) == 64

    rows[1] = merge(rows[1], (transmitted_word_equal=false,
                              parity_valid=false,))
    fresh = Study.endpoint_gate_summary(rows, config, :transfer)
    @test fresh["passed"]
    @test !fresh["expected_counts_applied"]
end

@testset "campaign queue accepts Block A's exact artifact contract" begin
    frame = 50001
    llr_hash = repeat("d", 64)
    rows = NamedTuple[]
    for (method, hard_hash, success) in (
            ("gd_native_projected", repeat("a", 64), false),
            ("v4_asbuilt_frozen", repeat("b", 64), true),
            ("bp_exact_sum_product", repeat("c", 64), true))
        push!(rows, (; frame, method,
            clipped_llr_sha256=llr_hash,
            hard_word_sha256=hard_hash,
            transmitted_word_equal=success))
    end
    endpoint = Study.campaign_endpoint_gate(rows, deepcopy(rows), :anchor)
    @test endpoint["schema_version"] ==
        "rq2-causal-factors-001/endpoint-gate-v1"
    @test endpoint["experiment_id"] == "RQ2-CAUSAL-FACTORS-001"
    @test endpoint["block"] == "A"
    @test endpoint["stage"] == "anchor"
    @test endpoint["gate_mode"] == "self_consistency"
    @test endpoint["primary_sentinel_sha256"] ==
        endpoint["replay_sentinel_sha256"]

    mktempdir() do root
        output = joinpath(root, "result")
        mkpath(output)
        science_path = joinpath(output, "science.json")
        open(science_path, "w") do io
            write(io, Study.canonical_json(Dict(
                "block" => "A", "stage" => "anchor",
                "synthetic_writer_fixture" => true)), '\n')
        end
        endpoint_path = joinpath(output, "endpoint_gate.toml")
        open(endpoint_path, "w") do io
            Study.TOML.print(io, endpoint; sorted=true)
            write(io, '\n')
        end
        pass_hash = Study.scientific_sha256(Dict(
            "synthetic_writer_fixture" => true))
        completion = Study.campaign_completion(
            :anchor, science_path, endpoint_path, pass_hash, pass_hash)
        open(joinpath(output, "COMPLETED.toml"), "w") do io
            Study.TOML.print(io, completion; sorted=true)
            write(io, '\n')
        end
        timing = Study.campaign_timing(:anchor, 1, 1.25, 0.25)
        open(joinpath(output, "timing.toml"), "w") do io
            Study.TOML.print(io, timing; sorted=true)
            write(io, '\n')
        end
        open(joinpath(output, "progress.toml"), "w") do io
            write(io, "phase = \"complete\"\n")
        end
        open(joinpath(output, "MANIFEST.sha256"), "w") do io
            write(io, Study.manifest_text(output))
        end
        @test !occursin("progress.toml",
            read(joinpath(output, "MANIFEST.sha256"), String))

        verifier = normpath(joinpath(@__DIR__, "..",
            "rq2_causal_factors_001", "campaign_queue.py"))
        python = """
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("campaign_queue", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
verified = module.verify_result(
    Path(sys.argv[2]), "A", "fresh_anchor",
    {"mode": "self_consistency", "frame_first": 50001,
     "frame_last": 50001, "frame_count": 1})
assert verified["block"] == "A"
assert verified["stage"] == "fresh_anchor"
"""
        @test success(`python3 -c $python $verifier $output`)
    end
end

