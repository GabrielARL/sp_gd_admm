using LinearAlgebra
using Random
using Statistics
using TOML
using Test

include(joinpath(@__DIR__, "rq2_gd_offset_split_001.jl"))
using .RQ2GDOffsetSplit001
const RQ2 = RQ2GDOffsetSplit001

bitwise_equal(left::AbstractVector{Float64},
              right::AbstractVector{Float64}) =
    reinterpret(UInt64, left) == reinterpret(UInt64, right)

function endpoint_row(frame, arm, success;
                      received="received-$frame",
                      clipped="clipped-$frame",
                      seed=20261012 + frame)
    (; frame, arm, success, received_sha256=received,
       clipped_llr_sha256=clipped, noise_seed=seed)
end

function full_outcome_rows(outcomes)
    rows = NamedTuple[]
    for (frame, values) in enumerate(outcomes)
        for (position, spec) in enumerate(RQ2.REQUIRED_ARMS)
            push!(rows, endpoint_row(frame, spec.name, values[position]))
        end
    end
    rows
end

function compare_diagonal(new_result, retained_result)
    @test bitwise_equal(new_result.x, retained_result.x)
    @test RQ2.edge_sha256(new_result.delta) ==
        RQ2.Legacy.edge_sha256(retained_result.delta)
    @test new_result.hard == retained_result.hard
    @test new_result.syndrome == retained_result.syndrome
    @test new_result.accepted_steps == retained_result.accepted_steps
    @test new_result.status == retained_result.status
    @test reinterpret(UInt64, [new_result.initial_loss]) ==
        reinterpret(UInt64, [retained_result.initial_loss])
    @test reinterpret(UInt64, [new_result.last_accepted_fixed_offset_loss]) ==
        reinterpret(UInt64,
                    [retained_result.last_accepted_fixed_offset_loss])
    @test reinterpret(UInt64, [new_result.terminal_refreshed_loss]) ==
        reinterpret(UInt64, [retained_result.terminal_refreshed_loss])
    @test length(new_result.trace) == length(retained_result.trace)
    common_keys = (
        "update", "accepted", "trial_count", "objective_evaluations",
        "loss_before", "accepted_fixed_offset_loss", "accepted_step",
        "x_before_sha256", "x_after_sha256", "delta_before_sha256",
        "delta_after_line_search_sha256", "delta_after_sha256",
        "gradient_sha256", "direction_sha256",
        "nonzero_offsets_before", "nonzero_offsets_after",
        "maximum_absolute_offset_after", "offset_l2_norm_after",
        "maximum_offset_sum_error", "projection_changed_edges",
        "projection_changed_bits", "maximum_projection_adjustment",
        "boundary_local_values", "finite_difference_maximum_error",
        "finite_difference_maximum_bit", "finite_difference_probes_in_box",
        "finite_difference_passed",
    )
    for (new_row, retained_row) in zip(new_result.trace,
                                       retained_result.trace)
        for key in common_keys
            @test new_row[key] == retained_row[key]
        end
    end
end

@testset "RQ2-GD-OFFSET-SPLIT-001" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = load_config(config_path)

    @testset "registered factorial and retained sources" begin
        @test config["experiment_id"] == "RQ2-GD-OFFSET-SPLIT-001"
        @test config["research_question"] == "RQ2"
        @test !config["scope"]["admm_included"]
        @test !config["scope"]["bp_arm_included"]
        @test config["anchor"]["frame_first"] == 20001
        @test config["anchor"]["frame_last"] == 20024
        @test config["heldout"]["frame_first"] == 30001
        @test config["heldout"]["frame_last"] == 30200
        @test isempty(intersect(
            config["anchor"]["frame_first"]:config["anchor"]["frame_last"],
            config["heldout"]["frame_first"]:config["heldout"]["frame_last"]))
        specs = arm_specs(config)
        @test [spec.name for spec in specs] == [
            "objective0__bounds0", "objective1__bounds0",
            "objective0__bounds1", "objective1__bounds1"]
        @test [(spec.objective_uses_offsets,
                spec.projection_uses_offset_bounds) for spec in specs] ==
            [(false, false), (true, false), (false, true), (true, true)]
        @test config["inference"]["holm_family_size"] == 8
        @test config["inference"]["pairwise_interval_confidence_level"] ==
            0.99375
        @test RQ2.enforce_thread_environment(config)

        source = source_gate(config)
        @test source["passed"]
        @test source["jade_project_head_passed"]
        @test source["jade_project_clean_passed"]
        @test length(source["records"]) == 24
        @test all(record["passed"] for record in source["records"])
        archive = RQ2.freeze_source_paths(config, config_path)
        @test haskey(archive,
            "retained_results/prior_anchor_completion/COMPLETED.toml")
        @test haskey(archive,
            "retained_results/prior_heldout_science/science.json")
    end

    @testset "objective and projection factors are independent" begin
        checks = [[1, 2], [2, 3], [1, 3]]
        edges = RQ2.Legacy.variable_edges(checks, 3)
        llr = [-0.7, 0.4, 1.1]
        curvature = [(2 * 2.0 * length(incident) + 8 * 0.2) / 3
                     for incident in edges]
        problem = BridgeProblem(checks, edges, llr, 2.0, 0.2, curvature)
        x = [0.9, 0.0, 0.0]
        delta = [[0.25, -0.1], [0.1, 0.0], [-0.25, 0.0]]

        objective0 = bridge_evaluate!(RQ2.EvalWorkspace(problem), problem,
            x, delta; consume_offsets=false)
        objective1 = bridge_evaluate!(RQ2.EvalWorkspace(problem), problem,
            x, delta; consume_offsets=true)
        @test objective0.loss != objective1.loss
        @test !bitwise_equal(copy(objective0.gradient),
                             copy(objective1.gradient))

        lower0 = similar(x)
        upper0 = similar(x)
        lower1 = similar(x)
        upper1 = similar(x)
        RQ2.scalar_intervals!(lower0, upper0, problem, delta;
            consume_offsets=false)
        RQ2.scalar_intervals!(lower1, upper1, problem, delta;
            consume_offsets=true)
        @test lower0 == fill(-1.0, 3)
        @test upper0 == fill(1.0, 3)
        @test lower1 != lower0
        @test upper1 != upper0
        expected_lower = [maximum(-1.0 - delta[check][slot]
                                  for (check, slot) in edges[bit])
                          for bit in 1:3]
        expected_upper = [minimum(1.0 - delta[check][slot]
                                  for (check, slot) in edges[bit])
                          for bit in 1:3]
        @test lower1 == expected_lower
        @test upper1 == expected_upper

        fd = RQ2.Legacy.finite_difference_maximum(
            problem, x, delta, objective1.gradient;
            consume_offsets=true,
            step=config["validation"]["finite_difference_step"])
        @test fd.maximum_error <=
            config["validation"]["finite_difference_tolerance"]
        @test fd.delta_sha256_before == fd.delta_sha256_after

        @test RQ2.readings_in_box(problem, x, delta;
            consume_offsets=false, tolerance=0.0)
        @test !RQ2.readings_in_box(problem, x, delta;
            consume_offsets=true, tolerance=0.0)
        excess = RQ2.maximum_reading_excess(problem, x, delta;
            use_offsets=true)
        @test excess.count_outside == 1
        @test excess.maximum_excess ≈ 0.15
        @test RQ2.trial_is_acceptable(true, 0.9, 1.0)
        @test !RQ2.trial_is_acceptable(false, 0.9, 1.0)
        @test !RQ2.trial_is_acceptable(true, Inf, 1.0)
        # O1P0 uses the first Boolean above for acceptance.  Its separate
        # objective-reading diagnostic may be false without clipping or veto.
        @test RQ2.trial_is_acceptable(
            RQ2.readings_in_box(problem, x, delta;
                consume_offsets=false, tolerance=0.0),
            0.9, 1.0)
    end

    @testset "bounded-mean offset primitive" begin
        adversarial = [2.540206823137588, 18.921747107377634]
        target = -0.5432809127898608
        projected = RQ2.bounded_mean_projection(adversarial, target)
        independent = RQ2.independent_bounded_mean_projection(
            adversarial, target)
        @test projected == [-1.0, -0.08656182557972159]
        @test projected == independent
        @test sum(projected) == 2target

        for degree in (1, 2, 3, 6), boundary in (-1.0, 1.0)
            proposal = degree == 1 ? [-7.0] :
                collect(range(-7.0, 8.0; length=degree))
            projected = RQ2.bounded_mean_projection(proposal, boundary)
            @test projected == fill(boundary, degree)
            @test projected == RQ2.independent_bounded_mean_projection(
                proposal, boundary)
        end
        interior = [-0.4, 0.1, 0.6]
        @test RQ2.bounded_mean_projection(interior, mean(interior)) ==
            interior
        rng = MersenneTwister(20261031)
        for degree in (1, 2, 3, 6), _ in 1:10
            proposal = 20.0 .* randn(rng, degree)
            target = 2rand(rng) - 1
            projected = RQ2.bounded_mean_projection(proposal, target)
            independent = RQ2.independent_bounded_mean_projection(
                proposal, target)
            @test all(-1.0 .<= projected .<= 1.0)
            @test abs(sum(projected) - degree * target) <= 2e-12
            @test maximum(abs, projected - independent) <= 3e-12
            @test RQ2.bounded_mean_projection(projected, target) == projected
        end
        @test_throws ArgumentError RQ2.bounded_mean_projection(
            Float64[], 0.0)
        @test_throws ArgumentError RQ2.bounded_mean_projection([0.0], 1.1)
    end

    @testset "check and local-edge relabeling" begin
        checks = [[1, 2], [2, 3], [1, 3]]
        llr = [-0.7, 0.4, 1.1]
        edges = RQ2.Legacy.variable_edges(checks, 3)
        curvature = [(2 * 2.0 * length(incident) + 8 * 0.2) / 3
                     for incident in edges]
        problem = BridgeProblem(checks, edges, llr, 2.0, 0.2, curvature)
        x = [0.2, -0.1, 0.3]
        delta = [[0.03, -0.04], [0.04, -0.02], [-0.03, 0.02]]
        evaluated = bridge_evaluate!(RQ2.EvalWorkspace(problem), problem,
            x, delta; consume_offsets=true)

        new_to_old = reverse(collect(eachindex(checks)))
        permuted_checks = [reverse(checks[index]) for index in new_to_old]
        permuted_delta = [reverse(delta[index]) for index in new_to_old]
        permuted_edges = RQ2.Legacy.variable_edges(permuted_checks, 3)
        permuted_problem = BridgeProblem(permuted_checks, permuted_edges,
            llr, 2.0, 0.2, curvature)
        permuted = bridge_evaluate!(RQ2.EvalWorkspace(permuted_problem),
            permuted_problem, x, permuted_delta; consume_offsets=true)
        @test abs(evaluated.loss - permuted.loss) <= 2e-15
        @test maximum(abs, evaluated.gradient - permuted.gradient) <= 2e-15

        hard = RQ2.hard_decision_independent(x)
        base_syndrome = RQ2.syndrome_vector(checks, hard)
        permuted_syndrome = RQ2.syndrome_vector(permuted_checks, hard)
        @test permuted_syndrome == base_syndrome[new_to_old]
    end

    native = RQ2.load_native(config)
    generated = RQ2.make_code(config, native)
    code = generated.code
    @test RQ2.graph_sha256(code.check_vars) == config["code"]["graph_sha256"]

    @testset "registered input identities without endpoint execution" begin
        rows = RQ2.input_freeze_rows(config, native, code)
        @test length(rows) == 224
        @test count(row -> row.set == "anchor", rows) == 24
        @test count(row -> row.set == "heldout", rows) == 200
        @test length(unique(row.frame for row in rows)) == 224
        @test all(row.noise_seed == 20261012 + row.frame for row in rows)
        @test all(row.graph_sha256 == config["code"]["graph_sha256"]
                  for row in rows)
        order_counts = zeros(Int, 4, 4)
        for frame_position in 1:24
            rotation = mod(frame_position - 1, 4)
            for (position, original) in enumerate(circshift(1:4, -rotation))
                order_counts[original, position] += 1
            end
        end
        @test order_counts == fill(6, 4, 4)
        fill!(order_counts, 0)
        for frame_position in 1:200
            rotation = mod(frame_position - 1, 4)
            for (position, original) in enumerate(circshift(1:4, -rotation))
                order_counts[original, position] += 1
            end
        end
        @test order_counts == fill(50, 4, 4)
    end

    @testset "four arms and diagonal compatibility" begin
        synthetic_llr = [2sin(0.013bit) + 0.4cos(0.031bit)
                         for bit in 1:code.n]
        problem = BridgeProblem(code, synthetic_llr)
        initial = tanh.(synthetic_llr ./ 2)
        results = Dict(spec.name => solve_variant(
            problem, code, initial, spec;
            maximum_updates=2, collect_trace=true)
            for spec in RQ2.REQUIRED_ARMS)
        r00 = results["objective0__bounds0"]
        r10 = results["objective1__bounds0"]
        r01 = results["objective0__bounds1"]
        r11 = results["objective1__bounds1"]

        @test all(length(result.trace) == 2 for result in values(results))
        @test length(unique((result.trace[1]["x_after_sha256"],
                             result.trace[1]["delta_after_sha256"])
                            for result in values(results))) == 1
        @test length(unique((result.trace[2]["x_before_sha256"],
                             result.trace[2]["delta_before_sha256"])
                            for result in values(results))) == 1
        @test r00.trace[2]["gradient_sha256"] ==
            r01.trace[2]["gradient_sha256"]
        @test r10.trace[2]["gradient_sha256"] ==
            r11.trace[2]["gradient_sha256"]
        @test r00.trace[2]["gradient_sha256"] !=
            r10.trace[2]["gradient_sha256"]
        @test r00.trace[2]["lower_bound_sha256"] ==
            r10.trace[2]["lower_bound_sha256"]
        @test r01.trace[2]["lower_bound_sha256"] ==
            r11.trace[2]["lower_bound_sha256"]
        @test r00.trace[2]["lower_bound_sha256"] !=
            r01.trace[2]["lower_bound_sha256"]
        @test all(result.trace[2]["nonzero_offsets_before"] > 0
                  for result in values(results))
        @test r00.first_objective_offset_use_update === nothing
        @test r00.first_projection_offset_use_update === nothing
        @test r10.first_objective_offset_use_update == 2
        @test r10.first_projection_offset_use_update === nothing
        @test r01.first_objective_offset_use_update === nothing
        @test r01.first_projection_offset_use_update == 2
        @test r11.first_objective_offset_use_update == 2
        @test r11.first_projection_offset_use_update == 2
        @test all(result.all_offsets_fixed_during_calculation
                  for result in values(results))
        @test all(result.all_projection_feasibility_checks_passed
                  for result in values(results))
        @test all(result.all_refreshed_readings_in_box
                  for result in values(results))
        @test all(result.all_mean_constraints_passed
                  for result in values(results))
        @test all(row["accepted_fixed_offset_loss"] < row["loss_before"]
                  for result in values(results) for row in result.trace
                  if row["accepted"])
        @test all(result.logical_persistent_scalar_values == 10200
                  for result in values(results))
        @test all(result.logical_persistent_edge_values == 30600
                  for result in values(results))
        @test length(unique(result.physical_edge_row_lengths_sha256
                            for result in values(results))) == 1
        @test all(all(value == 0 for value in (
            result.decoder_calls, result.normalized_minsum_calls,
            result.pseudogradient_calls, result.list_calls,
            result.oracle_calls)) for result in values(results))

        retained00 = RQ2.Legacy.solve_variant(problem, code, initial;
            consume_offsets=false, maximum_updates=2, collect_trace=true)
        retained11 = RQ2.Legacy.solve_variant(problem, code, initial;
            consume_offsets=true, maximum_updates=2, collect_trace=true)
        compare_diagonal(r00, retained00)
        compare_diagonal(r11, retained11)
        @test r11.first_objective_offset_use_update ==
            retained11.first_consumed_nonzero_update
        @test r11.first_projection_offset_use_update ==
            retained11.first_consumed_nonzero_update

        native_problem = RQ2.native_call(native, :ScalarProblem, code,
            synthetic_llr; parity_weight=2.0, binary_weight=0.2)
        oracle = RQ2.native_trace(native, native_problem, initial;
            maximum_updates=2)
        @test RQ2.Legacy.control_oracle_comparison(r00, oracle)["passed"]
    end

    @testset "exposed retained-result regression" begin
        frame = 2
        input = RQ2.generate_input(config, native, code, frame)
        problem = BridgeProblem(code, input.clipped_llr)
        initial = tanh.(input.clipped_llr ./ 2)
        retained_root = String(config["sources"]["prior_anchor_result"])
        retained_iterations = RQ2.parse_simple_csv(
            joinpath(retained_root, "iterations.csv"))
        retained_frames = RQ2.parse_simple_csv(
            joinpath(retained_root, "frames.csv"))
        for (spec, retained_arm) in (
            (RQ2.REQUIRED_ARMS[1], "control"),
            (RQ2.REQUIRED_ARMS[4], "active"),
        )
            result = solve_variant(problem, code, initial, spec;
                maximum_updates=30, collect_trace=true)
            expected_trace = [row for row in retained_iterations
                              if row.frame == string(frame) &&
                                 row.arm == retained_arm]
            @test length(expected_trace) == length(result.trace) == 30
            for (actual, expected) in zip(result.trace, expected_trace)
                @test string(actual["update"]) == expected.update
                @test lowercase(string(actual["accepted"])) == expected.accepted
                @test actual["x_before_sha256"] == expected.x_before_sha256
                @test actual["x_after_sha256"] == expected.x_after_sha256
                @test actual["delta_before_sha256"] ==
                    expected.delta_before_sha256
                @test actual["delta_after_sha256"] ==
                    expected.delta_after_sha256
                @test actual["gradient_sha256"] == expected.gradient_sha256
                @test actual["direction_sha256"] == expected.direction_sha256
                @test reinterpret(UInt64, [actual["loss_before"]]) ==
                    reinterpret(UInt64, [parse(Float64, expected.loss_before)])
                @test reinterpret(UInt64,
                    [actual["accepted_fixed_offset_loss"]]) ==
                    reinterpret(UInt64, [parse(Float64,
                        expected.accepted_fixed_offset_loss)])
            end
            expected_frame = only(row for row in retained_frames
                                  if row.frame == string(frame) &&
                                     row.arm == retained_arm)
            @test RQ2.vector_sha256(result.hard) ==
                expected_frame.hard_word_sha256
            @test RQ2.vector_sha256(result.x) ==
                expected_frame.terminal_scalar_sha256
            @test RQ2.edge_sha256(result.delta) ==
                expected_frame.terminal_offset_sha256
            @test result.syndrome_weight ==
                parse(Int, expected_frame.syndrome_weight)
            @test result.accepted_steps ==
                parse(Int, expected_frame.accepted_steps)
            @test result.status == expected_frame.status
        end
    end

    @testset "paired outcomes and interaction" begin
        rows = full_outcome_rows([
            (false, true, false, true),
            (true, true, false, false),
            (true, false, true, true),
            (false, false, true, false),
        ])
        @test RQ2.validate_frame_input_identities(rows)
        counts = paired_endpoint_counts(rows, :success,
            "objective1__bounds0", "objective0__bounds0")
        @test counts["both_success"] == 1
        @test counts["treatment_only_success"] == 1
        @test counts["reference_only_success"] == 1
        @test counts["both_failure"] == 1
        @test counts["pairs"] == 4
        @test counts["risk_difference_treatment_minus_reference"] == 0.0

        interaction = factorial_interaction(rows, :success)
        expected_scores = [0, 0, 1, -1]
        @test interaction["score_sum"] == sum(expected_scores)
        @test interaction["risk_difference_interaction"] ==
            mean(expected_scores)
        first_bootstrap = deepcopy(interaction)
        second_bootstrap = deepcopy(interaction)
        RQ2.add_interaction_bootstrap!(first_bootstrap, rows, :success;
            seed=20261031, resamples=1000, confidence_level=0.95)
        RQ2.add_interaction_bootstrap!(second_bootstrap, rows, :success;
            seed=20261031, resamples=1000, confidence_level=0.95)
        @test first_bootstrap["bootstrap"] == second_bootstrap["bootstrap"]

        endpoint_results = Dict(endpoint => Dict(
            "contrasts" => RQ2.contrast_endpoint_results(rows, :success),
            "interaction" => factorial_interaction(rows, :success))
            for endpoint in ("transmitted_word_equal", "parity_valid",
                             "information_word_equal"))
        RQ2.add_heldout_inference!(endpoint_results, 0.99375)
        adjusted = [result["holm_adjusted_pvalue"]
                    for endpoint in ("transmitted_word_equal", "parity_valid")
                    for result in values(endpoint_results[endpoint]["contrasts"])]
        @test length(adjusted) == 8
        @test all(0.0 .<= adjusted .<= 1.0)

        @test_throws ArgumentError paired_endpoint_counts(
            rows[1:1], :success,
            "objective1__bounds0", "objective0__bounds0")
        duplicate = vcat(rows, [rows[1]])
        @test_throws ArgumentError paired_endpoint_counts(duplicate, :success,
            "objective1__bounds0", "objective0__bounds0")
        wrong_input = copy(rows)
        wrong_input[2] = merge(wrong_input[2],
            (received_sha256="different",))
        @test_throws ArgumentError RQ2.validate_frame_input_identities(
            wrong_input)
    end

    @testset "durable progress and immutable result checksums" begin
        mktempdir() do directory
            progress_path = joinpath(directory, "progress.toml")
            started = "2026-10-31T00:00:00"
            for completed in 0:12
                atomic_write_progress(progress_path;
                    stage="anchor", pass_name="primary", status="running",
                    frames_completed=completed, frames_total=24,
                    current_frame=completed == 12 ? 20013 : 0,
                    last_completed_frame=completed == 0 ? 0 : 20000 + completed,
                    arms_completed=completed == 12 ? 2 : 0,
                    started_utc=started)
                parsed = TOML.parsefile(progress_path)
                @test parsed["frames_completed"] == completed
                @test parsed["started_utc"] == started
                @test parsed["experiment_id"] ==
                    "RQ2-GD-OFFSET-SPLIT-001"
                @test isempty(filter(name -> occursin(".tmp.", name),
                                    readdir(directory)))
            end
            RQ2.mark_progress_failed(progress_path, "anchor", 24, started,
                                     ErrorException("injected failure"))
            failed = TOML.parsefile(progress_path)
            @test failed["status"] == "failed"
            @test failed["frames_completed"] == 12
            @test failed["current_frame"] == 20013
            @test failed["arms_completed_current_frame"] == 2
            @test occursin("injected failure", failed["error"])

            RQ2.write_new_file(joinpath(directory, "science.json"), "{}\n")
            RQ2.write_result_checksum_manifest(directory)
            @test RQ2.verify_result_checksum_manifest(directory)["passed"]
            atomic_write_progress(progress_path;
                stage="anchor", pass_name="replay", status="running",
                frames_completed=0, frames_total=24,
                started_utc=started)
            @test RQ2.verify_result_checksum_manifest(directory)["passed"]
            RQ2.write_new_file(joinpath(directory, "extra.txt"), "extra\n")
            verification = RQ2.verify_result_checksum_manifest(directory)
            @test !verification["passed"]
            @test "extra:extra.txt" in verification["failures"]
        end
    end

    @testset "CLI registration without launching a campaign" begin
        @test occursin("preflight-probe", RQ2.usage())
        @test occursin("anchor --freeze", RQ2.usage())
        @test occursin("heldout --freeze", RQ2.usage())
        @test RQ2.Legacy.parse_cli(["preflight-probe"]).mode ==
            Symbol("preflight-probe")
        @test_throws ArgumentError RQ2.main(["anchor"])
        @test_throws ArgumentError RQ2.main(["heldout"])
        mktempdir() do existing
            @test_throws ArgumentError RQ2.freeze_inputs(existing;
                config_path)
            @test_throws ArgumentError RQ2.run_stage(
                :anchor, existing, joinpath(existing, "missing-freeze");
                config_path)
        end
    end
end
