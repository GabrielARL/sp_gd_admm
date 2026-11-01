using Test
using LinearAlgebra

include(joinpath(@__DIR__, "rq2_bp_target_state_update_001.jl"))
using .RQ2BPTargetStateUpdate001

const BLOCK = RQ2BPTargetStateUpdate001
const CONFIG_PATH = joinpath(@__DIR__, "config.toml")

@testset "registered two-by-two design" begin
    config = load_config(CONFIG_PATH)
    @test config["experiment_id"] == "RQ2-BP-TARGET-STATE-UPDATE-001"
    @test config["scope"]["native_projected_gd_included"] == false
    @test config["scope"]["admm_included"] == false
    @test config["budget"]["update_attempts_per_arm"] == 30
    @test config["budget"]["outcome_altering_early_stop"] == false
    @test config["gradient"]["parameter_tuning_allowed"] == false
    @test config["factorial"]["arm_order"] == collect(BLOCK.ARMS)
    @test config["provenance"]["completion_schema"] ==
          "rq2-causal-factors-001/result-completion-v1"
    @test config["provenance"]["endpoint_schema"] ==
          "rq2-causal-factors-001/endpoint-gate-v1"
    @test config["provenance"]["timing_schema"] ==
          "rq2-causal-factors-001/stage-timing-v1"
    @test collect(BLOCK.stage_frames(config, :calibration)) == collect(20001:20024)
    @test collect(BLOCK.stage_frames(config, :anchor)) == collect(50001:50024)
    @test collect(BLOCK.stage_frames(config, :transfer)) == collect(50025:50224)
    @test collect(BLOCK.stage_frames(config, :attribution)) == collect(30001:30200)
end

@testset "recipient-specific and mean-tied maps" begin
    graph = GraphView([[1, 2, 3], [1, 3, 4], [1, 2, 4]], 4)
    llr = [1.3, -0.7, 0.45, -1.1]
    zero_state = zeros(BLOCK.edge_count(graph))
    full_zero = evaluate_map(graph, llr, zero_state, :full)
    tied_zero = evaluate_map(graph, llr, zero_state, :qbar_tied)
    @test full_zero.output == tied_zero.output

    next_state = full_zero.output
    full = BLOCK.variable_values(graph, llr, next_state, :full)
    tied = BLOCK.variable_values(graph, llr, next_state, :qbar_tied)
    @test full.q_used != tied.q_used
    for variable in 1:graph.n
        incident = graph.variable_edges[variable]
        full_mean = sum(full.qstar[edge] for edge in incident) / length(incident)
        @test tied.qbar[variable] == full_mean
        @test all(tied.q_used[edge] == tied.qbar[variable] for edge in incident)
    end
end

@testset "analytic Jacobian adjoint and residual gradient" begin
    config = load_config(CONFIG_PATH)
    gate = toy_derivative_gate(config)
    @test gate["passed"]
    @test all(record["gradient_maximum_absolute_error"] <=
              config["validation"]["toy_gradient_absolute_tolerance"]
              for record in values(gate["records"]))
    @test all(record["vjp_directional_absolute_error"] <=
              config["validation"]["toy_vjp_absolute_tolerance"]
              for record in values(gate["records"]))
end

@testset "fixed 30-attempt budget does not stop on syndrome" begin
    config = load_config(CONFIG_PATH)
    graph = GraphView([[1, 2]], 2)
    llr = [10.0, 10.0]
    direct = run_arm(config, graph, llr, "full__direct";
                     frame=1, stage="unit")
    @test direct.first_valid_update == 1
    @test direct.first_exact_update == 1
    @test direct.updates_attempted == 30
    @test direct.accepted_updates == 30
    @test length(direct.iteration_rows) == 30
    @test all(row.parity_valid for row in direct.iteration_rows)

    gradient = run_arm(config, graph, llr, "full__residual_gradient";
                       frame=1, stage="unit")
    @test gradient.updates_attempted == 30
    @test length(gradient.iteration_rows) == 30
    @test all(row.objective_after <= row.objective_before
              for row in gradient.iteration_rows)

    replay = run_arm(config, graph, llr, "full__residual_gradient";
                     frame=1, stage="unit")
    @test canonical_json(gradient.iteration_rows) ==
          canonical_json(replay.iteration_rows)
end

@testset "stage artifact contract" begin
    config = load_config(CONFIG_PATH)
    graph = GraphView([[1, 2]], 2)
    result = run_arm(config, graph, [10.0, 10.0], "full__direct";
                     frame=1, stage="anchor")
    native = (valid=true, exact_word=true, iterations=1,
              coded_bit_errors=0, hard=falses(2))
    gate = Dict("passed" => true)
    input = (noise_seed=1, llr_sha256="synthetic")
    frame_row = BLOCK.arm_frame_row(:anchor, 1, input, result, native, gate)
    native_hash = BLOCK.vector_sha256(native.hard)
    frame_science = Dict(
        "frame" => 1,
        "llr_sha256" => input.llr_sha256,
        "native" => Dict(
            "exact_word" => true,
            "hard_word_sha256" => native_hash,
        ),
        "native_endpoint_gate" => gate,
        "arms" => Dict("full__direct" => BLOCK.arm_science(frame_row)),
    )
    science = Dict(
        "complete_valid" => true,
        "frame_count" => 1,
        "frames" => [frame_science],
        "native_endpoint_gates_passed" => true,
        "stage" => "anchor",
        "synthetic_writer_fixture" => true,
    )
    primary = (science=science, frame_rows=[frame_row],
               iteration_rows=result.iteration_rows)
    replay = deepcopy(primary)
    temporary = mktempdir()
    output = joinpath(temporary, "result")
    completion = BLOCK.write_result(output, CONFIG_PATH, :anchor,
                                    primary, replay;
                                    scientific_frame_loop_seconds=1.25,
                                    pass_count=2)
    @test completion["status"] == "complete_valid"
    @test completion["deterministic_replay_passed"]
    @test completion["correctness_passed"]
    @test completion["schema_version"] ==
          "rq2-causal-factors-001/result-completion-v1"
    @test completion["experiment_id"] == "RQ2-CAUSAL-FACTORS-001"
    @test completion["block"] == "B"
    @test completion["stage"] == "anchor"
    required = ("science.json", "frames.csv", "iterations.csv",
                "endpoint_gate.toml", "COMPLETED.toml", "timing.toml",
                "MANIFEST.sha256")
    @test all(isfile(joinpath(output, name)) for name in required)
    endpoint = BLOCK.TOML.parsefile(joinpath(output, "endpoint_gate.toml"))
    endpoint_field_set = Set((
        "schema_version", "experiment_id", "block", "stage", "gate_mode",
        "sentinel_self_consistency_passed", "primary_sentinel_sha256",
        "replay_sentinel_sha256", "frame_first", "frame_last", "frame_count",
        "frame_ids_sha256", "channel_llrs_sha256", "native_bp_successes",
        "native_bp_hard_words_sha256", "full_direct_successes",
        "full_direct_hard_words_sha256", "native_bp_full_direct_equal",
    ))
    @test Set(keys(endpoint)) == endpoint_field_set
    @test endpoint["schema_version"] == "rq2-causal-factors-001/endpoint-gate-v1"
    @test endpoint["experiment_id"] == "RQ2-CAUSAL-FACTORS-001"
    @test endpoint["block"] == "B"
    @test endpoint["stage"] == "anchor"
    @test endpoint["gate_mode"] == "cross_block_bp"
    @test endpoint["sentinel_self_consistency_passed"]
    @test endpoint["native_bp_full_direct_equal"]
    @test endpoint["native_bp_successes"] == endpoint["full_direct_successes"] == 1
    @test endpoint["native_bp_hard_words_sha256"] ==
          endpoint["full_direct_hard_words_sha256"]
    @test endpoint["frame_ids_sha256"] == scientific_sha256([1])
    @test endpoint["channel_llrs_sha256"] ==
          scientific_sha256([(1, input.llr_sha256)])
    @test endpoint["native_bp_hard_words_sha256"] ==
          scientific_sha256([(1, native_hash)])
    sentinel_fields = Dict(key => endpoint[key] for key in (
        "frame_first", "frame_last", "frame_count", "frame_ids_sha256",
        "channel_llrs_sha256", "native_bp_successes",
        "native_bp_hard_words_sha256", "full_direct_successes",
        "full_direct_hard_words_sha256", "native_bp_full_direct_equal",
    ))
    @test endpoint["primary_sentinel_sha256"] == scientific_sha256(sentinel_fields)
    @test endpoint["replay_sentinel_sha256"] == scientific_sha256(sentinel_fields)
    timing = BLOCK.TOML.parsefile(joinpath(output, "timing.toml"))
    @test Set(keys(timing)) == Set((
        "schema_version", "experiment_id", "block", "stage", "frame_count",
        "pass_count", "scientific_frame_loop_seconds", "post_loop_seconds",
    ))
    @test timing["schema_version"] == "rq2-causal-factors-001/stage-timing-v1"
    @test timing["experiment_id"] == "RQ2-CAUSAL-FACTORS-001"
    @test timing["block"] == "B"
    @test timing["stage"] == "anchor"
    @test timing["frame_count"] == 1
    @test timing["pass_count"] == 2
    @test timing["scientific_frame_loop_seconds"] == 1.25
    @test timing["post_loop_seconds"] >= 0.0
    for line in eachline(joinpath(output, "MANIFEST.sha256"))
        hash, name = split(line; limit=2)
        @test BLOCK.file_sha256(joinpath(output, strip(name))) == hash
    end

    campaign_path = normpath(joinpath(@__DIR__, "..", "rq2_causal_factors_001",
                                      "campaign_queue.py"))
    verifier = raw"""
import importlib.util
from pathlib import Path
import sys

result = Path(sys.argv[1])
campaign_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("rq2_campaign_contract", campaign_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
endpoint = module.load_toml(result / "endpoint_gate.toml")
expected = {
    "mode": "cross_block_bp",
    "frame_first": 1,
    "frame_last": 1,
    "frame_count": 1,
}
cross_fields = (
    "frame_first", "frame_last", "frame_count", "frame_ids_sha256",
    "channel_llrs_sha256", "native_bp_successes",
    "native_bp_hard_words_sha256",
)
reference = {key: endpoint[key] for key in cross_fields}
module.verify_result(result, "B", "fresh_anchor", expected, reference)
bad_reference = dict(reference)
bad_reference["channel_llrs_sha256"] = "0" * 64
try:
    module.verify_result(result, "B", "fresh_anchor", expected, bad_reference)
except module.GateError:
    pass
else:
    raise AssertionError("cross-block channel-LLR mismatch was not rejected")
"""
    run(`python3 -c $verifier $output $campaign_path`)
end

@testset "long-code derivative and native endpoint gates" begin
    config = load_config(CONFIG_PATH)
    BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))
    @test source_gate(config)["passed"]
    native = load_native(config)
    built = make_code(config, native)
    graph = graph_view(built.code)
    input = generate_input(config, native, built.code, 20001)

    long_gate = long_directional_gate(config, graph, input.llr)
    @test long_gate["passed"]
    @test all(record["gradient_directional_relative_error"] <=
              config["validation"]["long_directional_relative_tolerance"]
              for record in values(long_gate["records"]))
    @test all(record["vjp_directional_relative_error"] <=
              config["validation"]["long_vjp_relative_tolerance"]
              for record in values(long_gate["records"]))

    full_direct = run_arm(config, graph, input.llr, "full__direct";
                          frame=20001, stage="calibration")
    native_result = native_decode(built.modem, built.code, input.llr)
    gate = endpoint_gate(graph, full_direct, native_result)
    @test gate["passed"]
    @test all(values(gate["checks"]))
    @test full_direct.first_valid_update == native_result.iterations == 2
    @test full_direct.updates_attempted == 30
    @test length(full_direct.iteration_rows) == 30
end

