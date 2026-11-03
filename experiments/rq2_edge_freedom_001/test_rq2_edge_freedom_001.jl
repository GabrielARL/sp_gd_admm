#!/usr/bin/env julia

using Test
using TOML

include(joinpath(@__DIR__, "rq2_edge_freedom_001.jl"))
const Study = RQ2EdgeFreedom001

function toy_problem()
    code = (n=3, check_vars=[[1, 2], [2, 3]])
    problem = Study.BlockA.BridgeProblem(
        code, [-2.0, 0.5, 1.0]; parity_weight=2.0, binary_weight=0.2)
    x = [-0.0, 0.25, -0.5]
    delta = [[0.1, -0.2], [0.3, -0.4]]
    problem, x, delta
end

@testset "transfer requires the complete-valid anchor identity" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = Study.load_config(config_path)
    source = Study.source_gate(config)
    config_hash = Study.Tied.file_sha256(config_path)
    mktempdir() do directory
        gate_path = joinpath(directory, "job_gate.toml")
        gate = Dict(
            "experiment_id" => "RQ2-EDGE-FREEDOM-001",
            "stage" => "anchor",
            "status" => "pass",
            "correctness_passed" => true,
            "stability_passed" => true,
            "deterministic_replay_passed" => true,
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "primary_science_sha256" => "science",
            "replay_science_sha256" => "science",
        )
        completion = Dict(
            "experiment_id" => "RQ2-EDGE-FREEDOM-001",
            "stage" => "anchor",
            "status" => "complete_valid",
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "science_sha256" => "science",
        )
        open(gate_path, "w") do io
            TOML.print(io, gate; sorted=true)
        end
        open(joinpath(directory, "COMPLETED.toml"), "w") do io
            TOML.print(io, completion; sorted=true)
        end
        checked = Study.transfer_prerequisite_gate(
            gate_path, config_path, source.source_gate_sha256)
        @test checked.passed
        gate["status"] = "fail"
        open(gate_path, "w") do io
            TOML.print(io, gate; sorted=true)
        end
        @test_throws ErrorException Study.transfer_prerequisite_gate(
            gate_path, config_path, source.source_gate_sha256)
    end
end

function synthetic_seed(problem, x, delta)
    workspace = Study.Legacy.EvalWorkspace(problem)
    loss = Study.BlockA.product_only_evaluate!(workspace, problem, x, delta).loss
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

function scalar_oracle(problem, x0, delta, maximum_updates,
                       initial_step, maximum_backtracks)
    x = copy(x0)
    trial = similar(x)
    direction = similar(x)
    current_workspace = Study.Legacy.EvalWorkspace(problem)
    trial_workspace = Study.Legacy.EvalWorkspace(problem)
    accepted_steps = 1
    status = "steps_completed"
    for _ in 2:maximum_updates
        current = Study.BlockA.product_only_evaluate!(
            current_workspace, problem, x, delta)
        @inbounds for bit in eachindex(x)
            direction[bit] = -current.gradient[bit] /
                problem.curvature_bound[bit]
        end
        accepted = false
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                trial[bit] = x[bit] + step * direction[bit]
            end
            evaluated = Study.BlockA.product_only_evaluate!(
                trial_workspace, problem, trial, delta)
            if isfinite(evaluated.loss) && evaluated.loss < current.loss
                x, trial = trial, x
                accepted_steps += 1
                accepted = true
                break
            end
        end
        if !accepted
            status = "line_search_stalled"
            break
        end
    end
    (; x, accepted_steps, status)
end

@testset "configuration contract" begin
    config = Study.load_config(joinpath(@__DIR__, "config.toml"))
    @test config["experiment_id"] == "RQ2-EDGE-FREEDOM-001"
    @test config["solver"]["maximum_update_attempts"] == 30
    @test config["solver"]["projection_after_common_update"] == false
    source = Study.source_gate(config)
    @test source.passed
    @test all(values(source.checks))
end

@testset "centered mean preserves the constrained manifold" begin
    problem, x, _ = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    mean_state = Study.centered_mean(z, problem)
    @test Study.Tied.vector_bits_equal(mean_state, x)
    @test reinterpret(UInt64, mean_state[1]) == reinterpret(UInt64, -0.0)

    z[1][2] = -0.25
    z[2][1] = 0.75
    mean_state = Study.centered_mean(z, problem)
    @test mean_state[2] == 0.25

    malformed = [[0.0], [0.0, 0.0]]
    @test_throws DimensionMismatch Study.centered_mean(malformed, problem)
    isolated = Study.Legacy.BridgeProblem(
        [[1, 2]], [Study.Legacy.variable_edges([[1, 2]], 3)...],
        [-2.0, 0.5, 1.0], 2.0, 0.2, [1.0, 1.0, 1.0])
    @test_throws ArgumentError Study.centered_mean([[0.0, 0.0]], isolated)
end

@testset "shared lifted objective and exact edge partials" begin
    problem, x, delta = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    scalar_workspace = Study.Legacy.EvalWorkspace(problem)
    lifted_workspace = Study.LiftedWorkspace(problem)
    scalar = Study.BlockA.product_only_evaluate!(
        scalar_workspace, problem, x, delta)
    lifted = Study.lifted_evaluate!(lifted_workspace, problem, z, delta)

    @test Study.Tied.float_bits_equal(scalar.loss, lifted.loss)
    @test Study.Tied.float_bits_equal(scalar.terms.channel,
                                      lifted.terms.channel)
    @test Study.Tied.float_bits_equal(scalar.terms.parity,
                                      lifted.terms.parity)
    @test Study.Tied.float_bits_equal(scalar.terms.binary,
                                      lifted.terms.binary)
    @test Study.Tied.vector_bits_equal(scalar.gradient,
                                       lifted.scalar_gradient)

    expected = [[4 / 15, -33 / 160], [541 / 480, -4 / 5]]
    for check_index in eachindex(expected), slot in eachindex(expected[check_index])
        @test lifted.edge_gradient[check_index][slot] ≈
            expected[check_index][slot] atol=2e-16 rtol=2e-16
    end
    aggregate = zeros(3)
    Study.aggregate_edge_gradient!(aggregate, problem, lifted.edge_gradient)
    @test aggregate[2] ≈ 221 / 240 atol=2e-16 rtol=2e-16
    @test maximum(abs.(aggregate .- scalar.gradient)) <= 5.0e-12
end

@testset "edge finite differences include zero-factor products" begin
    problem, x, delta = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    z[1][1] = -delta[1][1]
    z[2][2] = -delta[2][2]
    workspace = Study.LiftedWorkspace(problem)
    evaluated = Study.lifted_evaluate!(workspace, problem, z, delta)
    gate = Study.edge_finite_difference_gate(
        problem, z, delta, evaluated.edge_gradient;
        sample_count=4, step=1.0e-6, tolerance=5.0e-8)
    @test gate.passed
    @test length(gate.rows) == 4
    @test gate.maximum_error <= 5.0e-8
    @test gate.state_before == gate.state_after
    @test gate.offset_before == gate.offset_after
end

@testset "metric restriction and first-direction identity" begin
    problem, x, delta = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    workspace = Study.LiftedWorkspace(problem)
    evaluated = Study.lifted_evaluate!(workspace, problem, z, delta)
    gate = Study.direction_gate(problem, evaluated)
    @test gate.passed
    @test gate.aggregate_error <= 5.0e-12
    @test gate.mean_direction_error <= 5.0e-12
    @test gate.nonzero_spread
    @test gate.free_edges[1][2] ≈ 33 / 256 atol=2e-16 rtol=2e-16
    @test gate.free_edges[2][1] ≈ -541 / 768 atol=2e-16 rtol=2e-16
    @test gate.constrained_scalar[2] ≈ -221 / 768 atol=2e-16 rtol=2e-16

    v = [0.3, -0.7, 0.2]
    tied_metric_norm = 0.0
    for (check_index, check) in enumerate(problem.check_vars)
        for (_, bit) in enumerate(check)
            tied_metric_norm += problem.curvature_bound[bit] /
                length(problem.var_edges[bit]) * v[bit]^2
        end
    end
    scalar_metric_norm = sum(problem.curvature_bound .* v.^2)
    @test tied_metric_norm ≈ scalar_metric_norm atol=2e-16 rtol=2e-16
end

@testset "stability diagnostics" begin
    problem, x, _ = toy_problem()
    z = Study.Tied.lift_scalar(x, problem.check_vars)
    z[2][1] += 0.5
    stable = Study.stability_diagnostics(
        problem, z; absolute_state_safety_limit=10.0)
    @test stable.all_finite
    @test stable.safety_passed
    @test stable.maximum_within_bit_spread == 0.5
    limited = Study.stability_diagnostics(
        problem, z; absolute_state_safety_limit=0.1)
    @test !limited.safety_passed
    nonfinite = Study.Legacy.copy_edge_rows(z)
    nonfinite[1][1] = Inf
    @test !Study.stability_diagnostics(problem, nonfinite).all_finite
end

@testset "paired solver changes only equality freedom" begin
    problem, x, delta = toy_problem()
    seed = synthetic_seed(problem, x, delta)
    config = deepcopy(Study.load_config(joinpath(@__DIR__, "config.toml")))
    config["solver"]["maximum_update_attempts"] = 5
    config["validation"]["finite_difference_updates"] = [2, 5]
    config["validation"]["finite_difference_sample_count"] = 4
    result = Study.paired_per_frame_solve(
        problem, nothing, copy(x), seed, config; frame=0)

    @test result.treatment_boundary.passed
    @test result.first_direction.passed
    @test result.first_direction.nonzero_spread
    @test all(row.loss_after < row.loss_before
              for row in result.constrained.trace[2:end] if row.accepted)
    @test all(row.loss_after < row.loss_before
              for row in result.relaxed.trace[2:end] if row.accepted)
    @test Study.Tied.edge_sha256(result.constrained.delta) ==
          Study.Tied.edge_sha256(delta)
    @test Study.Tied.edge_sha256(result.relaxed.delta) ==
          Study.Tied.edge_sha256(delta)

    oracle = scalar_oracle(
        problem, x, delta, 5,
        Float64(config["solver"]["initial_step"]),
        Int(config["solver"]["maximum_backtracks"]))
    @test Study.Tied.vector_bits_equal(result.constrained.x, oracle.x)
    @test result.constrained.accepted_steps == oracle.accepted_steps
    @test result.constrained.status == oracle.status
    @test !Study.Tied.edge_bits_equal(result.constrained.z, result.relaxed.z)
end
