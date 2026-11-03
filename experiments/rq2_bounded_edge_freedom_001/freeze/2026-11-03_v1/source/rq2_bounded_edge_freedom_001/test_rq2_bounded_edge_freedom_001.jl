#!/usr/bin/env julia

using Test
using TOML

include(joinpath(@__DIR__, "rq2_bounded_edge_freedom_001.jl"))
const Study = RQ2BoundedEdgeFreedom001

function toy_problem()
    code = (n=3, check_vars=[[1, 2], [2, 3]])
    problem = Study.Legacy.BridgeProblem(
        code, [-2.0, 0.5, 1.0]; parity_weight=2.0,
        binary_weight=0.2)
    x = [-0.0, 0.25, -0.5]
    delta = [[0.1, -0.2], [0.3, -0.4]]
    problem, x, delta
end

function synthetic_seed(problem, x, delta)
    workspace = Study.Legacy.EvalWorkspace(problem)
    loss = Study.scalar_compound_evaluate!(
        workspace, problem, x, delta).loss
    row = Dict{String,Any}(
        "loss_before" => loss + 1.0,
        "accepted_fixed_offset_loss" => loss,
        "accepted_step" => 0.2,
        "trial_count" => 1,
        "finite_difference_maximum_error" => 0.0,
        "finite_difference_maximum_bit" => 1,
        "x_before_sha256" => Study.Tied.vector_sha256(x),
        "x_after_sha256" => Study.Tied.vector_sha256(x),
    )
    (; x=copy(x), delta=Study.Legacy.copy_edge_rows(delta), trace=[row])
end

function scalar_box_oracle(problem, x0, delta, maximum_updates,
                           initial_step, maximum_backtracks, lower, upper)
    x = copy(x0)
    current_workspace = Study.Legacy.EvalWorkspace(problem)
    trial_workspace = Study.Legacy.EvalWorkspace(problem)
    raw = similar(x)
    trial = similar(x)
    direction = similar(x)
    accepted_steps = 1
    status = "steps_completed"
    trace = [Study.Tied.vector_sha256(x)]
    for _ in 2:maximum_updates
        current = Study.scalar_compound_evaluate!(
            current_workspace, problem, x, delta)
        @inbounds for bit in eachindex(x)
            direction[bit] = -current.gradient[bit] /
                problem.curvature_bound[bit]
        end
        accepted = false
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                raw[bit] = x[bit] + step * direction[bit]
            end
            Study.project_scalar_box!(trial, raw, lower, upper)
            evaluated = Study.scalar_compound_evaluate!(
                trial_workspace, problem, trial, delta)
            if isfinite(evaluated.loss) && evaluated.loss < current.loss
                x, trial = trial, x
                accepted_steps += 1
                accepted = true
                push!(trace, Study.Tied.vector_sha256(x))
                break
            end
        end
        if !accepted
            status = "line_search_stalled"
            push!(trace, Study.Tied.vector_sha256(x))
            break
        end
    end
    (; x, accepted_steps, status, trace)
end

@testset "registered configuration and source identities" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = Study.load_config(config_path)
    @test config["experiment_id"] ==
          "RQ2-BOUNDED-EDGE-FREEDOM-001"
    @test config["solver"]["maximum_update_attempts"] == 30
    @test config["solver"]["box_lower"] == -1.0
    @test config["solver"]["box_upper"] == 1.0
    @test config["objective"]["offset_adjusted_parity_reading_boxed"] == false
    @test config["inference"]["confidence_level"] == 0.95
    @test config["inference"]["contrast"] ==
          "equality_relaxed_minus_equality_constrained"
    source = Study.source_gate(config; config_path)
    @test source.passed
    @test all(values(source.checks))
    @test source.checks["calibration_frames_manifest_entry"]
    @test source.checks["calibration_iterations_manifest_entry"]
    @test source.checks["jade_project_head"]
    @test source.checks["jade_project_toml"]
    @test source.checks["jade_manifest_toml"]
    @test source.checks["jade_receiver_core"]
    @test source.checks["jade_core_common"]
    @test source.checks["jade_joint_projected_gradient"]
    @test source.checks["loaded_jade_project"]
end

@testset "paired inference reports both discordance directions" begin
    rows = [
        (; relaxed_transmitted_word_equal=true,
           constrained_transmitted_word_equal=true,
           relaxed_parity_valid=true, constrained_parity_valid=true),
        (; relaxed_transmitted_word_equal=true,
           constrained_transmitted_word_equal=false,
           relaxed_parity_valid=true, constrained_parity_valid=false),
        (; relaxed_transmitted_word_equal=true,
           constrained_transmitted_word_equal=false,
           relaxed_parity_valid=false, constrained_parity_valid=false),
        (; relaxed_transmitted_word_equal=false,
           constrained_transmitted_word_equal=true,
           relaxed_parity_valid=false, constrained_parity_valid=true),
        (; relaxed_transmitted_word_equal=false,
           constrained_transmitted_word_equal=false,
           relaxed_parity_valid=false, constrained_parity_valid=false),
    ]
    counts = Study.paired_endpoint_counts(
        rows, :relaxed_transmitted_word_equal,
        :constrained_transmitted_word_equal)
    @test counts["both_success"] == 1
    @test counts["active_only_success"] == 2
    @test counts["control_only_success"] == 1
    @test counts["both_failure"] == 1
    @test counts["active_successes"] == 3
    @test counts["control_successes"] == 2
    @test counts["risk_difference_active_minus_control"] == 0.2

    config = Study.load_config(joinpath(@__DIR__, "config.toml"))
    inference = Study.paired_inference(rows, config)
    primary = inference["transmitted_word_equal"]
    @test primary["mcnemar_exact_two_sided_pvalue"] == 1.0
    @test primary["newcombe_interval"]["confidence_level"] == 0.95
    @test primary["newcombe_interval"]["estimate"] ≈ 0.2
    @test inference["parity_valid"]["counts"]["active_only_success"] == 1
    @test inference["parity_valid"]["counts"]["control_only_success"] == 1
end

@testset "mean readout preserves exact tied values" begin
    problem, x, _ = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    observed = Study.mean_state(z, problem)
    @test Study.Tied.vector_bits_equal(observed, x)
    @test reinterpret(UInt64, observed[1]) == reinterpret(UInt64, -0.0)

    z[1][2] = -0.25
    z[2][1] = 0.75
    @test Study.mean_state(z, problem)[2] == 0.25
    @test_throws DimensionMismatch Study.mean_state([[0.0], [0.0]], problem)
end

@testset "tied lifted compound objective is bit exact" begin
    problem, x, delta = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    scalar_workspace = Study.Legacy.EvalWorkspace(problem)
    lifted_workspace = Study.LiftedWorkspace(problem)
    scalar = Study.scalar_compound_evaluate!(
        scalar_workspace, problem, x, delta)
    lifted = Study.compound_lifted_evaluate!(
        lifted_workspace, problem, z, delta)

    @test Study.Tied.vector_bits_equal(lifted.mean, x)
    @test Study.Tied.float_bits_equal(lifted.loss, scalar.loss)
    @test Study.Tied.float_bits_equal(
        lifted.terms.channel, scalar.terms.channel)
    @test Study.Tied.float_bits_equal(
        lifted.terms.parity, scalar.terms.parity)
    @test Study.Tied.float_bits_equal(
        lifted.terms.binary, scalar.terms.binary)
    @test Study.Tied.vector_bits_equal(
        lifted.scalar_gradient, scalar.gradient)
    @test Study.Tied.edge_bits_equal(lifted.g_rows, scalar.g_rows)

    identity = Study.objective_identity_gate(problem, x, z, delta)
    @test identity.passed
    @test all(values(identity.checks))
end

@testset "scale-aware pullback and direction diagnostics" begin
    problem, x, delta = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    evaluated = Study.compound_lifted_evaluate!(
        Study.LiftedWorkspace(problem), problem, z, delta)
    gate = Study.pullback_direction_gate(
        problem, evaluated; pullback_multiplier=128.0,
        direction_multiplier=128.0)
    @test gate.passed
    @test gate.aggregate_normalized_error <= 1.0
    @test gate.mean_direction_normalized_error <= 1.0
    @test gate.nonzero_spread
    @test gate.maximum_direction_spread > 0.0
    @test gate.aggregate_tolerance > 0.0
    @test gate.mean_direction_tolerance > 0.0

    changed_gradient = copy(evaluated.scalar_gradient)
    changed_gradient[2] += 1.0e-3
    changed = merge(evaluated, (; scalar_gradient=changed_gradient))
    @test !Study.pullback_direction_gate(
        problem, changed; pullback_multiplier=128.0,
        direction_multiplier=128.0,
        require_nonzero_spread=false).passed
end

@testset "mixed finite-difference bound and frozen inputs" begin
    problem, x, delta = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    evaluated = Study.compound_lifted_evaluate!(
        Study.LiftedWorkspace(problem), problem, z, delta)
    gate = Study.edge_finite_difference_gate(
        problem, z, delta, evaluated.edge_gradient;
        sample_count=4, step=1.0e-6, tolerance=5.0e-8)
    @test gate.passed
    @test length(gate.rows) == 4
    @test gate.maximum_normalized_error <= 1.0
    @test all(row.mixed_bound ==
              5.0e-8 * max(1.0, abs(row.analytic), abs(row.numerical))
              for row in gate.rows)
    @test gate.state_before == gate.state_after
    @test gate.offset_before == gate.offset_after
end

@testset "the box constrains z and never clips z plus delta" begin
    source = [[-2.0, 0.8], [1.4, -0.2]]
    projected = [[0.0, 0.0], [0.0, 0.0]]
    delta = [[-0.5, 0.6], [0.7, -1.1]]
    offset_hash = Study.Tied.edge_sha256(delta)
    Study.project_edge_box!(projected, source, -1.0, 1.0)
    @test projected == [[-1.0, 0.8], [1.0, -0.2]]
    @test projected[1][2] + delta[1][2] > 1.0
    @test projected[2][2] + delta[2][2] < -1.0
    @test Study.Tied.edge_sha256(delta) == offset_hash

    scalar = zeros(3)
    Study.project_scalar_box!(scalar, [-2.0, 0.25, 4.0], -1.0, 1.0)
    @test scalar == [-1.0, 0.25, 1.0]
end

@testset "private-check diagnostics expose incoherent copies" begin
    problem, x, delta = toy_problem()
    tied = Study.Tied.lift_scalar(x, problem.check_vars)
    tied_diagnostics = Study.private_check_diagnostics(
        problem, tied, delta)
    free = Study.Legacy.copy_edge_rows(tied)
    free[1][2] = -0.9
    free[2][1] = 0.9
    free_diagnostics = Study.private_check_diagnostics(
        problem, free, delta)
    @test free_diagnostics.edge_sign_disagreement_count > 0
    @test free_diagnostics.private_check_residual_rms !=
          tied_diagnostics.private_check_residual_rms
    @test free_diagnostics.hard_satisfaction_disagreement_checks >= 0
end

@testset "paired solver changes only the equality constraint" begin
    problem, x, delta = toy_problem()
    seed = synthetic_seed(problem, x, delta)
    config = deepcopy(Study.load_config(joinpath(@__DIR__, "config.toml")))
    config["solver"]["maximum_update_attempts"] = 5
    config["validation"]["finite_difference_updates"] = [2, 5]
    config["validation"]["finite_difference_sample_count"] = 4
    offset_hash = Study.Tied.edge_sha256(delta)
    result = Study.paired_per_frame_solve(
        problem, nothing, copy(x), seed, config; frame=0)

    @test result.treatment_boundary.passed
    @test result.first_objective_identity.passed
    @test result.first_direction.passed
    @test result.first_direction.nonzero_spread
    @test result.maximum_pullback_normalized_error <= 1.0
    @test all(row.loss_after < row.loss_before
              for row in result.constrained.trace[2:end] if row.accepted)
    @test all(row.loss_after < row.loss_before
              for row in result.relaxed.trace[2:end] if row.accepted)
    @test all(row.objective_identity_passed
              for row in result.constrained.trace)
    @test all(value -> -1.0 <= value <= 1.0,
              [value for row in result.constrained.z for value in row])
    @test all(value -> -1.0 <= value <= 1.0,
              [value for row in result.relaxed.z for value in row])
    @test Study.Tied.edge_sha256(result.constrained.delta) == offset_hash
    @test Study.Tied.edge_sha256(result.relaxed.delta) == offset_hash
    @test !first(result.constrained.trace).finite_difference_checked
    @test !first(result.relaxed.trace).finite_difference_checked
    @test result.constrained.finite_difference_schedule_passed
    @test result.relaxed.finite_difference_schedule_passed
    @test result.constrained.finite_difference_updates_checked == "2;5"
    @test result.relaxed.finite_difference_updates_checked == "2;5"

    oracle = scalar_box_oracle(
        problem, x, delta, 5,
        Float64(config["solver"]["initial_step"]),
        Int(config["solver"]["maximum_backtracks"]), -1.0, 1.0)
    @test Study.Tied.vector_bits_equal(result.constrained.x, oracle.x)
    @test result.constrained.accepted_steps == oracle.accepted_steps
    @test result.constrained.status == oracle.status
    @test [row.x_after_sha256 for row in result.constrained.trace] ==
          oracle.trace
    for bit in eachindex(problem.var_edges)
        values = [result.constrained.z[c][s]
                  for (c, s) in problem.var_edges[bit]]
        @test all(Study.Tied.float_bits_equal(first(values), value)
                  for value in values)
    end
    @test !Study.Tied.edge_bits_equal(
        result.constrained.z, result.relaxed.z)
end

@testset "persistent counts and paired discordance" begin
    problem, _, _ = toy_problem()
    constrained_counts = Study.persistent_state_counts(
        problem, :equality_constrained)
    relaxed_counts = Study.persistent_state_counts(
        problem, :equality_relaxed)
    @test constrained_counts.optimized_persistent_value_count == 3
    @test constrained_counts.frozen_offset_persistent_value_count == 4
    @test constrained_counts.redundant_state_cache_value_count == 4
    @test constrained_counts.total_persistent_value_count == 11
    @test relaxed_counts.optimized_persistent_value_count == 4
    @test relaxed_counts.frozen_offset_persistent_value_count == 4
    @test relaxed_counts.redundant_state_cache_value_count == 0
    @test relaxed_counts.total_persistent_value_count == 8
    constrained = (;
        input_identity_sha256="same", coded_bit_errors=4,
        syndrome_weight=2, parity_valid=false,
        transmitted_word_equal=false, hard_word_sha256="a",
        terminal_mean_sha256="x", accepted_steps=3,
        effective_update=3, constrained_counts...)
    relaxed = (;
        input_identity_sha256="same", coded_bit_errors=0,
        syndrome_weight=0, parity_valid=true,
        transmitted_word_equal=true, hard_word_sha256="b",
        terminal_mean_sha256="y", accepted_steps=5,
        effective_update=5, relaxed_counts...)
    paired = Study.paired_outcome_row(
        7, :unit, constrained, relaxed)
    @test paired.relaxed_only_transmitted_word_recovery
    @test paired.relaxed_minus_constrained_transmitted_word_recovery == 1
    @test paired.constrained_optimized_persistent_value_count == 3
    @test paired.relaxed_optimized_persistent_value_count == 4
    @test paired.constrained_total_persistent_value_count == 11
    @test paired.relaxed_total_persistent_value_count == 8
end

@testset "post-stall update-30 derivative schedule is preserved" begin
    problem, x, delta = toy_problem()
    seed = synthetic_seed(problem, x, delta)
    config = deepcopy(Study.load_config(joinpath(@__DIR__, "config.toml")))
    config["solver"]["maximum_update_attempts"] = 5
    config["solver"]["initial_step"] = 0.0
    config["solver"]["maximum_backtracks"] = 0
    config["validation"]["finite_difference_updates"] = [2, 5]
    config["validation"]["finite_difference_sample_count"] = 4
    result = Study.paired_per_frame_solve(
        problem, nothing, copy(x), seed, config; frame=0)
    @test result.constrained.status == "line_search_stalled"
    @test result.relaxed.status == "line_search_stalled"
    @test result.constrained.last_effective_update == 1
    @test result.relaxed.last_effective_update == 1
    @test result.constrained.finite_difference_schedule_passed
    @test result.relaxed.finite_difference_schedule_passed
    @test result.constrained.finite_difference_updates_checked == "2;5"
    @test result.relaxed.finite_difference_updates_checked == "2;5"
end

@testset "transfer gate fails closed" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = Study.load_config(config_path)
    source = Study.source_gate(config; config_path)
    config_hash = Study.Tied.file_sha256(config_path)
    mktempdir() do directory
        gate_path = joinpath(directory, "job_gate.toml")
        gate = Dict(
            "experiment_id" => Study.EXPERIMENT_ID,
            "stage" => "anchor", "status" => "pass",
            "correctness_passed" => true,
            "projection_passed" => true,
            "deterministic_replay_passed" => true,
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "primary_science_sha256" => "same-science",
            "replay_science_sha256" => "same-science",
            "frame_count" => 24,
        )
        completion = Dict{String,Any}(
            "experiment_id" => Study.EXPERIMENT_ID,
            "stage" => "anchor", "status" => "complete_valid",
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "science_sha256" => "same-science",
        )
        open(gate_path, "w") do io
            TOML.print(io, gate; sorted=true)
        end
        open(joinpath(directory, "COMPLETED.toml"), "w") do io
            TOML.print(io, completion; sorted=true)
        end
        open(joinpath(directory, "science.json"), "w") do io
            write(io, "{}\n")
        end
        Study.write_manifest(directory)
        first_gate = Study.transfer_prerequisite_gate(
            gate_path, config_path, source.source_gate_sha256)
        @test first_gate.passed
        completion["total_seconds"] = 123.456
        completion["completed_utc"] = "2099-01-01T00:00:00"
        open(joinpath(directory, "COMPLETED.toml"), "w") do io
            TOML.print(io, completion; sorted=true)
        end
        Study.write_manifest(directory)
        second_gate = Study.transfer_prerequisite_gate(
            gate_path, config_path, source.source_gate_sha256)
        @test Study.scientific_sha256(first_gate.science) ==
              Study.scientific_sha256(second_gate.science)
        @test first_gate.integrity["completion_sha256"] !=
              second_gate.integrity["completion_sha256"]
        gate["projection_passed"] = false
        open(gate_path, "w") do io
            TOML.print(io, gate; sorted=true)
        end
        Study.write_manifest(directory)
        @test_throws ErrorException Study.transfer_prerequisite_gate(
            gate_path, config_path, source.source_gate_sha256)
    end
end


@testset "source failures leave a durable failure artifact" begin
    mktempdir() do directory
        output = joinpath(directory, "failed_run")
        missing = joinpath(directory, "missing-config.toml")
        @test_throws Exception Study.run_stage(
            :anchor; config_path=missing, output)
        @test isfile(joinpath(output, "FAILURE.toml"))
        @test isfile(joinpath(output, "MANIFEST.sha256"))
        failure = TOML.parsefile(joinpath(output, "FAILURE.toml"))
        @test failure["status"] == "failed"
    end
end
