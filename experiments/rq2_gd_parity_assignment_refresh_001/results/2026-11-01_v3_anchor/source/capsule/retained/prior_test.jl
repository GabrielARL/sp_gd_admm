using LinearAlgebra
using Random
using Statistics
using Test

include(joinpath(@__DIR__, "rq2_gd_state_use_001.jl"))
using .RQ2GDStateUse001
const RQ2 = RQ2GDStateUse001

function bitwise_equal(left::AbstractVector{Float64}, right::AbstractVector{Float64})
    reinterpret(UInt64, left) == reinterpret(UInt64, right)
end

function restore_relabelled_rows(rows, new_to_old)
    restored = Vector{Vector{Float64}}(undef, length(rows))
    for new_index in eachindex(rows)
        restored[new_to_old[new_index]] = reverse(Float64.(rows[new_index]))
    end
    restored
end

@testset "RQ2-GD-STATE-USE-001 preflight" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = load_config(config_path)

    @test config["research_question"] == "RQ2"
    @test !config["scope"]["admm_included"]
    @test !config["scope"]["bp_arm_included"]
    @test config["anchor"]["frame_first"] == 2
    @test config["anchor"]["frame_last"] == 25
    @test config["governance_amendment"]["quarantined_frame"] == 1
    @test !config["governance_amendment"]["confirmation_exposure"]
    @test !config["timing"]["warmup_has_frame_identity"]
    @test !config["timing"]["warmup_included_in_outcomes"]
    @test !haskey(config["timing"], "warmup_frame")
    @test isempty(intersect(
        config["anchor"]["frame_first"]:config["anchor"]["frame_last"],
        config["heldout"]["frame_first"]:config["heldout"]["frame_last"]))
    @test reinterpret(UInt64, Float64(config["channel"]["noise_variance"])) ==
        parse(UInt64, config["channel"]["noise_variance_float64_hex"])

    source = source_gate(config)
    @test source["passed"]
    @test source["jade_project_head_passed"]
    @test source["jade_project_clean_passed"]
    @test all(record["passed"] for record in source["records"])
    @test RQ2.enforce_thread_environment(config)

    cli = `$(Base.julia_cmd()) --depwarn=error --project=$(config["sources"]["jade_project_repo"]) $(RQ2.RUNNER_PATH) preflight-probe`
    cli_output = read(setenv(cli,
        "OMP_NUM_THREADS" => "1", "JULIA_NUM_THREADS" => "1",
        "OPENBLAS_NUM_THREADS" => "1"), String)
    @test occursin(config["code"]["graph_sha256"], cli_output)

    @testset "bounded mean projection" begin
        adversarial = [2.540206823137588, 18.921747107377634]
        target = -0.5432809127898608
        projected = bounded_mean_projection(adversarial, target)
        oracle = independent_bounded_mean_projection(adversarial, target)
        @test projected == [-1.0, -0.08656182557972159]
        @test projected == oracle

        mixed = bounded_mean_projection([-10.0, 0.0, 0.0, 100.0], 0.0)
        mixed_oracle = independent_bounded_mean_projection(
            [-10.0, 0.0, 0.0, 100.0], 0.0)
        @test maximum(abs, mixed - mixed_oracle) <= 2e-14
        @test sum(mixed) == 0.0

        for degree in (1, 2, 3, 6), target in (-1.0, 1.0)
            q = degree == 1 ? [-4.0] :
                collect(range(-4.0, 7.0; length=degree))
            z = bounded_mean_projection(q, target)
            @test z == fill(target, degree)
            @test maximum(abs, z - independent_bounded_mean_projection(q, target)) == 0.0
        end

        rng = MersenneTwister(20261031)
        for degree in (1, 2, 3, 6), _ in 1:40
            q = 20.0 .* randn(rng, degree)
            target = 2rand(rng) - 1
            z = bounded_mean_projection(q, target)
            independent = independent_bounded_mean_projection(q, target)
            @test all(-1.0 .<= z .<= 1.0)
            @test abs(sum(z) - degree * target) <= 2e-12
            @test maximum(abs, z - independent) <= 3e-12
            @test bounded_mean_projection(z, target) == z
        end
        q = [-0.4, 0.1, 0.6]
        @test bounded_mean_projection(q, mean(q)) == q
        @test_throws ArgumentError bounded_mean_projection(Float64[], 0.0)
        @test_throws ArgumentError bounded_mean_projection([0.0], 1.1)
    end

    native = load_native(config)
    generated = RQ2.make_code(config, native)
    code = generated.code
    @test RQ2.graph_sha256(code.check_vars) == config["code"]["graph_sha256"]
    @test sum(length, code.check_vars) == 30600

    @testset "native evaluator and ignored-state null" begin
        input = generate_input(config, native, code, 2)
        problem = BridgeProblem(code, input.clipped_llr)
        x = tanh.(input.clipped_llr ./ 2)
        zero = RQ2.zero_edge_rows(problem.check_vars)
        evaluated = bridge_evaluate!(RQ2.EvalWorkspace(problem), problem, x, zero;
            consume_offsets=false)
        native_problem = RQ2.native_call(native, :ScalarProblem, code,
            input.clipped_llr; parity_weight=2.0, binary_weight=0.2)
        native_evaluated = RQ2.native_call(native, :objective_gradient,
            native_problem, x)
        @test evaluated.loss == native_evaluated.loss
        @test bitwise_equal(copy(evaluated.gradient), native_evaluated.gradient)
        @test evaluated.terms == native_evaluated.terms

        rng = MersenneTwister(17)
        arbitrary = [0.05 .* randn(rng, length(check))
                     for check in problem.check_vars]
        ignored = bridge_evaluate!(RQ2.EvalWorkspace(problem), problem, x,
            arbitrary; consume_offsets=false)
        @test ignored.loss == evaluated.loss
        @test bitwise_equal(copy(ignored.gradient), copy(evaluated.gradient))
        for bit in eachindex(x)
            composed = evaluated.h[bit] + sum(
                evaluated.g_rows[check_index][slot]
                for (check_index, slot) in problem.var_edges[bit]; init=0.0)
            @test abs(composed - evaluated.gradient[bit]) <= 2e-18
        end
    end

    @testset "RQ1 inactive-projection composition" begin
        fixtures = Dict(
            "tree" => (
                checks=[[1, 2], [2, 3]],
                local_raw=[[0.8143218674524325, -0.25927544672797853],
                           [-0.052756928209459986, -0.38084323668989317]],
                delta=[[0.0, -0.10325925925925927],
                       [0.10325925925925927, 0.0]],
                x_after=[0.8143218674524325, -0.15601618746871926,
                         -0.38084323668989317],
            ),
            "cycle" => (
                checks=[[1, 2], [2, 3], [1, 3]],
                local_raw=[[0.7573173856435487, -0.25927544672797853],
                           [-0.052756928209459986, -0.17660299918021546],
                           [0.7890210893472523, -0.37660299918021545]],
                delta=[[-0.015851851851851784, -0.10325925925925927],
                       [0.10325925925925927, 0.1],
                       [0.015851851851851895, -0.09999999999999998]],
                x_after=[0.7731692374954005, -0.15601618746871926,
                         -0.27660299918021547],
            ),
        )
        for case_name in ("tree", "cycle")
            case = fixtures[case_name]
            checks = case.checks
            edges = RQ2.variable_edges(checks, 3)
            local_raw = case.local_raw
            registered_delta = case.delta
            x_after = case.x_after
            for bit in 1:3
                q = [local_raw[check_index][slot]
                     for (check_index, slot) in edges[bit]]
                z = bounded_mean_projection(q, x_after[bit])
                @test maximum(abs, z - q) <= 2e-15
                for (position, (check_index, slot)) in enumerate(edges[bit])
                    @test abs((z[position] - x_after[bit]) -
                              registered_delta[check_index][slot]) <= 2e-15
                end
            end
        end
    end

    @testset "synthetic retained-state mechanism" begin
        synthetic_llr = [2sin(0.013bit) + 0.4cos(0.031bit)
                         for bit in 1:code.n]
        problem = BridgeProblem(code, synthetic_llr)
        initial = tanh.(synthetic_llr ./ 2)
        control = solve_variant(problem, code, initial;
            consume_offsets=false, maximum_updates=2, collect_trace=true)
        active = solve_variant(problem, code, initial;
            consume_offsets=true, maximum_updates=2, collect_trace=true,
            validate_derivatives=true,
            finite_difference_step=config["validation"]["finite_difference_step"],
            finite_difference_tolerance=config["validation"]["finite_difference_tolerance"])
        lean_control = solve_variant(problem, code, initial;
            consume_offsets=false, maximum_updates=2, collect_trace=false,
            collect_diagnostics=false)
        @test bitwise_equal(lean_control.x, control.x)
        @test RQ2.edge_sha256(lean_control.delta) == RQ2.edge_sha256(control.delta)
        @test control.trace[1]["x_after_sha256"] == active.trace[1]["x_after_sha256"]
        @test control.trace[1]["delta_after_sha256"] == active.trace[1]["delta_after_sha256"]
        @test active.first_consumed_nonzero_update == 2
        @test active.all_finite_differences_passed
        @test active.all_offsets_fixed_during_calculation
        @test active.all_readings_in_box
        @test active.all_mean_constraints_passed
        @test active.trace[1]["offset_l2_norm_after"] > 0.0
        @test active.logical_persistent_edge_values == 30600
        @test control.logical_persistent_edge_values == 30600
        @test active.physical_persistent_state_bytes == 326400
        @test control.physical_persistent_state_bytes == 326400
        @test active.physical_edge_row_lengths_sha256 ==
            control.physical_edge_row_lengths_sha256

        stalled_problem = BridgeProblem(code, zeros(code.n))
        stalled = solve_variant(stalled_problem, code, ones(code.n);
            consume_offsets=false, maximum_updates=2, collect_trace=true)
        @test stalled.status == "line_search_stalled"
        @test stalled.accepted_steps == 0
        @test isfinite(stalled.initial_loss)
        @test stalled.last_accepted_fixed_offset_loss == stalled.initial_loss
        @test isfinite(stalled.terminal_refreshed_loss)
    end

    @testset "check-row and local-edge relabeling" begin
        checks = [[1, 2], [2, 3], [1, 3]]
        llr = [-0.7, 0.4, 1.1]
        edges = RQ2.variable_edges(checks, 3)
        curvature = [(2 * 2.0 * length(incident) + 8 * 0.2) / 3
                     for incident in edges]
        problem = BridgeProblem(checks, edges, llr, 2.0, 0.2, curvature)
        x = [0.2, -0.1, 0.3]
        delta = [[0.03, -0.04], [0.04, -0.02], [-0.03, 0.02]]
        base = bridge_evaluate!(RQ2.EvalWorkspace(problem), problem, x, delta;
            consume_offsets=true)
        base_loss = base.loss
        base_gradient = copy(base.gradient)

        new_to_old = reverse(collect(eachindex(checks)))
        relabelled_checks = [reverse(checks[index]) for index in new_to_old]
        relabelled_delta = [reverse(delta[index]) for index in new_to_old]
        relabelled_edges = RQ2.variable_edges(relabelled_checks, 3)
        relabelled = BridgeProblem(relabelled_checks, relabelled_edges, llr,
            2.0, 0.2, curvature)
        permuted = bridge_evaluate!(RQ2.EvalWorkspace(relabelled), relabelled,
            x, relabelled_delta; consume_offsets=true)
        @test abs(base_loss - permuted.loss) <= 2e-15
        @test maximum(abs, base_gradient - permuted.gradient) <= 2e-15

        step = 0.02
        x_after = clamp.(x .- step .* base_gradient ./ curvature, -1.0, 1.0)
        base_next = RQ2.zero_edge_rows(checks)
        base_q = RQ2.zero_edge_rows(checks)
        RQ2.construct_offsets!(base_next, base_q, problem, x, x_after,
            step, base)
        permuted_next = RQ2.zero_edge_rows(relabelled_checks)
        permuted_q = RQ2.zero_edge_rows(relabelled_checks)
        RQ2.construct_offsets!(permuted_next, permuted_q, relabelled,
            x, x_after, step, permuted)
        restored = restore_relabelled_rows(permuted_next, new_to_old)
        @test maximum(abs, RQ2.flatten_edge_rows(base_next) -
                           RQ2.flatten_edge_rows(restored)) <= 2e-15
        hard = RQ2.hard_decision_independent(x_after)
        base_syndrome = RQ2.syndrome_vector(checks, hard)
        relabelled_syndrome = RQ2.syndrome_vector(relabelled_checks, hard)
        @test relabelled_syndrome == base_syndrome[new_to_old]
    end

    @testset "all amended-anchor native controls" begin
        references = RQ2.reference_rows(config)
        information_positions = RQ2.native_call(native, :_message_positions, code)
        projection_activity_seen = Ref(false)
        for frame in config["anchor"]["frame_first"]:config["anchor"]["frame_last"]
            input = generate_input(config, native, code, frame)
            problem = BridgeProblem(code, input.clipped_llr)
            initial = tanh.(input.clipped_llr ./ 2)
            control = solve_variant(problem, code, initial;
                consume_offsets=false, maximum_updates=30, collect_trace=true)
            native_problem = RQ2.native_call(native, :ScalarProblem, code,
                input.clipped_llr; parity_weight=2.0, binary_weight=0.2)
            oracle = RQ2.native_trace(native, native_problem, initial;
                maximum_updates=30)
            @test RQ2.control_oracle_comparison(control, oracle)["passed"]
            information_errors = count(@view control.hard[information_positions])
            @test RQ2.reference_comparison(
                references[frame], control, information_errors)["passed"]
            @test control.physical_scalar_length == 10200
            @test control.physical_edge_slot_count == 30600
            @test control.physical_persistent_state_bytes == 326400
            projection_activity_seen[] |= any(
                record["projection_changed_edges"] > 0 for record in control.trace)
        end
        @test projection_activity_seen[]
    end

    @testset "paired statistics and immutable artifacts" begin
        counts = Dict(
            "both_success" => 5,
            "active_only_success" => 3,
            "control_only_success" => 1,
            "both_failure" => 7,
            "pairs" => 16,
            "active_successes" => 8,
            "control_successes" => 6,
            "risk_difference_active_minus_control" => 0.125,
        )
        @test RQ2.mcnemar_exact_pvalue(counts) == 0.625
        interval = RQ2.newcombe_paired_interval(counts)
        @test interval["lower"] <= interval["estimate"] <= interval["upper"]
        adjusted = RQ2.holm_adjust(Dict("a" => 0.01, "b" => 0.04))
        @test adjusted["a"] == 0.02
        @test adjusted["b"] == 0.04

        paired_rows = [
            (frame=1, arm="control", success=false),
            (frame=1, arm="active", success=true),
            (frame=2, arm="control", success=true),
            (frame=2, arm="active", success=true),
        ]
        endpoint = RQ2.endpoint_counts(paired_rows, :success)
        @test endpoint isa Dict{String,Any}
        endpoints = Dict(
            "transmitted_word_equal" => deepcopy(endpoint),
            "parity_valid" => deepcopy(endpoint),
            "information_word_equal" => deepcopy(endpoint),
        )
        RQ2.add_heldout_inference!(endpoints, 0.975)
        @test endpoints["transmitted_word_equal"]["newcombe_interval"] isa
            Dict{String,Any}
        @test haskey(endpoints["parity_valid"], "holm_adjusted_pvalue")

        mktempdir() do directory
            RQ2.write_new_file(joinpath(directory, "a.txt"), "locked\n")
            RQ2.write_checksum_manifest(directory)
            @test RQ2.verify_checksum_manifest(directory)["passed"]
            RQ2.write_new_file(joinpath(directory, "extra.txt"), "not listed\n")
            verification = RQ2.verify_checksum_manifest(directory)
            @test !verification["passed"]
            @test "extra:extra.txt" in verification["failures"]
            @test_throws ArgumentError RQ2.write_new_file(
                joinpath(directory, "a.txt"), "overwrite")
        end
    end
end
