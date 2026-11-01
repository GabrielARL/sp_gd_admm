#!/usr/bin/env julia

using Test
using Random
using TOML

include(joinpath(@__DIR__, "rq2_gd_parity_assignment_refresh_001.jl"))
const F = RQ2GDParityAssignmentRefresh001
const Legacy = F.Legacy
const Split = F.Split

ENV["OMP_NUM_THREADS"] = "1"

function write_test_toml(path, value)
    open(path, "w") do io
        TOML.print(io, value; sorted=true)
        write(io, '\n')
    end
    path
end

function valid_preflight_fields()
    Dict(
        "validation_status" => "pass",
        "test_exit_code" => "0",
        "test_assertions_passed" => "17",
        "test_assertions_total" => "17",
        "budget_test_exit_code" => "0",
        "budget_tests_passed" => "5",
        "budget_tests_total" => "5",
        "queue_test_exit_code" => "0",
        "queue_tests_passed" => "13",
        "queue_tests_total" => "13",
        "registered_endpoint_frames_executed_during_preflight" => "0",
        "config_sha256" => F.file_sha256(F.DEFAULT_CONFIG),
        "card_sha256" => F.file_sha256(F.CARD_PATH),
        "runner_sha256" => F.file_sha256(F.RUNNER_PATH),
        "test_sha256" => F.file_sha256(F.TEST_PATH),
        "budget_tool_sha256" => F.file_sha256(F.BUDGET_TOOL_PATH),
        "budget_test_sha256" => F.file_sha256(F.BUDGET_TEST_PATH),
        "queue_status_sha256" => F.file_sha256(F.QUEUE_STATUS_PATH),
        "queue_lock_tool_sha256" => F.file_sha256(F.QUEUE_LOCK_TOOL_PATH),
        "anchor_wrapper_sha256" => F.file_sha256(F.ANCHOR_WRAPPER_PATH),
        "queue_wrapper_sha256" => F.file_sha256(F.QUEUE_WRAPPER_PATH),
        "queue_template_sha256" => F.file_sha256(F.QUEUE_TEMPLATE_PATH),
        "queue_readme_template_sha256" =>
            F.file_sha256(F.QUEUE_README_TEMPLATE_PATH),
        "queue_test_sha256" => F.file_sha256(F.QUEUE_TEST_PATH),
        "split_runner_sha256" => F.file_sha256(F.SPLIT_RUNNER_PATH),
        "legacy_runner_sha256" => F.file_sha256(Split.LEGACY_RUNNER_PATH),
    )
end

function write_valid_preflight(path)
    fields = valid_preflight_fields()
    open(path, "w") do io
        for key in sort!(collect(keys(fields)))
            println(io, key, ": ", fields[key])
        end
    end
    path
end

@testset "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001" begin
    config = F.load_config()
    split = F.load_split_config(config)
    @test F.source_gate(config)["passed"]
    @test F.scientific_sha256(Dict("a" => [1, 2, 3])) ==
          Legacy.scientific_sha256(Dict("a" => [1, 2, 3]))

    @testset "preflight record parser" begin
        mktempdir() do directory
            record = joinpath(directory, "preflight.md")
            write_valid_preflight(record)
            @test F.preflight_gate(F.DEFAULT_CONFIG;
                preflight_path=record)["passed"]
            open(record, "a") do io
                println(io, "runner_sha256: deliberately_wrong")
            end
            @test !F.preflight_gate(F.DEFAULT_CONFIG;
                preflight_path=record)["passed"]
        end
    end

    @testset "attempt-scoped frozen preflight binding" begin
        mktempdir() do directory
            freeze = joinpath(directory, "freeze")
            archived = joinpath(freeze, "source", "preflight_validation.md")
            mkpath(dirname(archived))
            record = joinpath(directory, "attempt", "preflight_validation.md")
            mkpath(dirname(record))
            write_valid_preflight(record)
            cp(record, archived)
            frozen_record = Dict{String,Any}(
                "label" => "preflight_validation.md",
                "original_path" => abspath(record),
                "sha256" => F.file_sha256(record),
                "archived_relative_path" =>
                    joinpath("source", "preflight_validation.md"),
            )
            manifest = Dict{String,Any}("sources" => [frozen_record])

            valid = F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, manifest)
            @test valid["passed"]
            @test valid["original_path"] == abspath(record)
            @test F.authored_source_paths(F.DEFAULT_CONFIG;
                preflight_path=record)["preflight_validation.md"] ==
                abspath(record)
            frozen_sources = F.freeze_source_paths(
                config, F.DEFAULT_CONFIG; preflight_path=record)
            @test frozen_sources["preflight_validation.md"] == abspath(record)
            @test haskey(
                frozen_sources, "prerequisite_result/COMPLETED.toml")

            open(record, "a") do io
                println(io, "swapped_record: different")
            end
            changed = F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, manifest)
            @test !changed["passed"]
            @test !changed["checks"]["original_sha256"]

            rm(record)
            deleted = F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, manifest)
            @test !deleted["passed"]
            @test !deleted["checks"]["original_path_regular_unlinked"]

            target = joinpath(directory, "valid-target.md")
            write_valid_preflight(target)
            symlink(target, record)
            linked = F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, manifest)
            @test !linked["passed"]
            @test !linked["checks"]["original_path_regular_unlinked"]
            rm(record)
            write_valid_preflight(record)

            swapped_manifest = deepcopy(manifest)
            swapped_manifest["sources"][1]["original_path"] = F.DEFAULT_CONFIG
            swapped_manifest["sources"][1]["sha256"] =
                F.file_sha256(F.DEFAULT_CONFIG)
            swapped = F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, swapped_manifest)
            @test !swapped["passed"]
            @test !swapped["checks"]["preflight_gate"]

            duplicate = deepcopy(manifest)
            push!(duplicate["sources"], deepcopy(frozen_record))
            @test !F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, duplicate)["passed"]

            rm(archived)
            symlink(record, archived)
            archived_link = F.validate_frozen_preflight_binding(
                F.DEFAULT_CONFIG, freeze, manifest)
            @test !archived_link["passed"]
            @test !archived_link["checks"][
                "archived_path_regular_unlinked"]
        end

        mktempdir() do empty_freeze
            invalid = F.validate_freeze(config, empty_freeze)
            @test !invalid["passed"]
            @test invalid["checks"] ==
                Dict{String,Bool}("checksum_manifest" => false)
        end
        @test_throws ArgumentError F.main([
            "freeze", "--output", joinpath(mktempdir(), "freeze")])
    end

    @testset "freeze-key inventory gate" begin
        expected = Set([("anchor", 1), ("transfer", 2)])
        @test all(values(F.freeze_input_key_gate(
            expected, [("anchor", 1), ("transfer", 2)])))
        duplicate = F.freeze_input_key_gate(
            expected, [("anchor", 1), ("anchor", 1), ("transfer", 2)])
        @test !duplicate["input_row_count"]
        @test !duplicate["input_keys_unique"]
        missing = F.freeze_input_key_gate(expected, [("anchor", 1)])
        @test !missing["input_keys_exact"]
    end

    @testset "phase telemetry and closed checksum inventory" begin
        mktempdir() do directory
            progress = joinpath(directory, "progress.toml")
            tracker = F.PhaseTracker(progress, "test", "primary",
                                     "2026-10-31T00:00:00Z")
            F.begin_phase!(tracker, "kernel";
                frames_completed=0, frames_total=1)
            F.finish_phase!(tracker; status="pass_completed",
                frames_completed=1, frames_total=1,
                last_completed_frame=1)
            payload = TOML.parsefile(progress)
            @test payload["previous_phase"] == "kernel"
            @test payload["status"] == "pass_completed"
            phase_lines = readlines(joinpath(directory, "phase_log.tsv"))
            @test length(phase_lines) == 3
            @test occursin("kernel:start", phase_lines[2])
            @test occursin("kernel:end", phase_lines[3])

            write(joinpath(directory, "payload.txt"), "bound\n")
            F.write_phase_log_binding(directory)
            F.write_result_checksum_manifest(directory)
            @test F.verify_result_checksum_manifest(directory)["passed"]
            manifest_path = joinpath(directory, "MANIFEST.sha256")
            original_manifest = read(manifest_path, String)
            open(manifest_path, "a") do io
                write(io, first(readlines(manifest_path)), '\n')
            end
            duplicate = F.verify_result_checksum_manifest(directory)
            @test !duplicate["passed"]
            @test any(startswith(failure, "duplicate:")
                      for failure in duplicate["failures"])
            write(manifest_path, original_manifest)
            rm(joinpath(directory, "phase_log.tsv"))
            missing_phase_log = F.verify_result_checksum_manifest(directory)
            @test !missing_phase_log["passed"]
            @test "missing:phase_log.tsv" in missing_phase_log["failures"]
            write(joinpath(directory, "phase_log.tsv"), join(phase_lines, '\n') * "\n")
            write(joinpath(directory, "unregistered.txt"), "extra\n")
            checksum = F.verify_result_checksum_manifest(directory)
            @test !checksum["passed"]
            @test "extra:unregistered.txt" in checksum["failures"]
        end
    end

    @testset "non-anchor execution authorization" begin
        missing = F.validate_execution_authorization(
            config, :transfer, nothing, nothing, Dict{String,Any}())
        @test !missing["passed"]

        mktempdir() do directory
            anchor_record = Dict{String,Any}(
                "science_sha256" => "science",
                "completion_sha256" => "completion",
                "manifest_sha256" => "manifest",
                "checksum_manifest_sha256" => "checksums",
                "phase_log_sha256" => "phases",
            )
            budget_path = joinpath(directory, "budget_transfer.toml")
            anchor_cases = length(F.stage_frames(config, :anchor))
            target_cases = length(F.stage_frames(config, :transfer))
            anchor_frame_seconds = 240.0
            anchor_post_seconds = 24.0
            projected_frame_seconds =
                anchor_frame_seconds / anchor_cases * target_cases
            projected_post_seconds =
                anchor_post_seconds * target_cases / anchor_cases
            projected_seconds = projected_frame_seconds + projected_post_seconds
            wall_seconds = ceil(Int,
                Float64(config["work_budget"]["heldout_budget_scale"]) *
                projected_seconds)
            grace = Int(config["work_budget"]["termination_grace_seconds"])
            budget = Dict{String,Any}(
                "schema_version" =>
                    config["execution_authorization"]["budget_schema"],
                "experiment_id" => config["experiment_id"],
                "target_stage" => "transfer",
                "anchor_science_sha256" => anchor_record["science_sha256"],
                "anchor_completion_sha256" =>
                    anchor_record["completion_sha256"],
                "anchor_manifest_sha256" => anchor_record["manifest_sha256"],
                "anchor_checksum_manifest_sha256" =>
                    anchor_record["checksum_manifest_sha256"],
                "phase_log_sha256" => anchor_record["phase_log_sha256"],
                "anchor_cases" => anchor_cases,
                "target_cases" => target_cases,
                "pass_count" =>
                    Int(config["work_budget"]["scientific_passes"]),
                "safety_factor" =>
                    Float64(config["work_budget"]["heldout_budget_scale"]),
                "absolute_safety_cap_seconds" => Int(
                    config["work_budget"]["maximum_stage_wall_budget_seconds"]),
                "termination_grace_seconds" => grace,
                "anchor_frame_loop_seconds" => anchor_frame_seconds,
                "projected_frame_seconds" => projected_frame_seconds,
                "anchor_post_loop_seconds" => anchor_post_seconds,
                "projected_post_loop_seconds" => projected_post_seconds,
                "projected_seconds_before_safety" => projected_seconds,
                "wall_budget_seconds" => wall_seconds,
                "term_after_seconds" => wall_seconds - grace,
            )
            write_test_toml(budget_path, budget)
            attribution_budget_path = joinpath(directory,
                                               "budget_attribution.toml")
            attribution_budget = copy(budget)
            attribution_budget["target_stage"] = "attribution"
            write_test_toml(attribution_budget_path, attribution_budget)
            write(joinpath(directory, "README.md"),
                  read(F.QUEUE_README_TEMPLATE_PATH, String))
            for (relative, source) in F.queue_package_governance_sources()
                cp(source, joinpath(directory, relative))
            end
            immutable = sort!(["README.md", "budget_transfer.toml",
                               "budget_attribution.toml", "queue.toml",
                               collect(keys(
                                   F.queue_package_governance_sources()))...])
            queue_id = "TEST-JULIA-AUTHORIZATION"
            registered_preflight = joinpath(
                directory, "attempt", "preflight_validation.md")
            write_test_toml(joinpath(directory, "queue.toml"), Dict(
                "schema_version" =>
                    config["execution_authorization"]["queue_schema"],
                "queue_id" => queue_id,
                "experiment_id" => config["experiment_id"],
                "stages" => ["transfer", "attribution"],
                "execution_mode" =>
                    "serial, one scientific unit, fail closed",
                "automatic_restart_allowed" => false,
                "interrupted_attempt_must_be_retained" => true,
                "manual_relaunch_requires_new_attempt_directory" => true,
                "execution" => config["queue_plan"],
                "paths" => Dict(
                    "repository_root" => dirname(F.HERE),
                    "project_root" => dirname(F.HERE),
                    "config" => F.DEFAULT_CONFIG,
                    "runner" => F.RUNNER_PATH,
                    "preflight" => registered_preflight,
                    "freeze" => joinpath(directory, "freeze"),
                    "anchor_result" => joinpath(directory, "anchor"),
                    "transfer_result" => joinpath(directory, "transfer"),
                    "attribution_result" => joinpath(directory, "attribution"),
                    "budget_transfer" => "budget_transfer.toml",
                    "budget_attribution" => "budget_attribution.toml"),
                "inventory" => Dict("immutable_files" => immutable),
                "telemetry" => Dict(
                    "files" => sort!(collect(F.QUEUE_BASE_TELEMETRY)),
                    "job_ids" => F.QUEUE_JOB_IDS)))

            queue_manifest = joinpath(directory, "QUEUE_MANIFEST.sha256")
            locked_files = immutable
            open(queue_manifest, "w") do io
                for relative in locked_files
                    println(io, F.file_sha256(joinpath(directory, relative)),
                            "  ", relative)
                end
            end
            write_test_toml(joinpath(directory, "QUEUE_PACKAGE_LOCK.toml"),
                Dict("schema_version" =>
                         config["execution_authorization"]["queue_lock_schema"],
                     "experiment_id" => config["experiment_id"],
                     "queue_id" => queue_id,
                     "queue_manifest_sha256" =>
                         F.file_sha256(queue_manifest),
                     "locked_file_count" => length(locked_files)))

            authorized = F.validate_execution_authorization(config, :transfer,
                budget_path, queue_manifest, anchor_record;
                registered_preflight_path=registered_preflight)
            @test authorized["passed"]
            @test !F.validate_execution_authorization(config, :transfer,
                budget_path, queue_manifest, anchor_record;
                registered_preflight_path=joinpath(
                    directory, "other", "preflight_validation.md"))["passed"]
            write(joinpath(directory, "unlisted_helper.sh"), "#!/bin/sh\n")
            @test !F.validate_execution_authorization(config, :transfer,
                budget_path, queue_manifest, anchor_record;
                registered_preflight_path=registered_preflight)["passed"]
            rm(joinpath(directory, "unlisted_helper.sh"))
            renamed_manifest = joinpath(directory, "renamed.sha256")
            cp(queue_manifest, renamed_manifest)
            @test !F.validate_execution_authorization(config, :transfer,
                budget_path, renamed_manifest, anchor_record;
                registered_preflight_path=registered_preflight)["passed"]
            wrong_anchor = copy(anchor_record)
            wrong_anchor["science_sha256"] = "wrong"
            @test !F.validate_execution_authorization(config, :transfer,
                budget_path, queue_manifest, wrong_anchor;
                registered_preflight_path=registered_preflight)["passed"]

            write(joinpath(directory, "status_report.py"), "# self-locked tamper\n")
            open(queue_manifest, "w") do io
                for relative in locked_files
                    println(io, F.file_sha256(joinpath(directory, relative)),
                            "  ", relative)
                end
            end
            write_test_toml(joinpath(directory, "QUEUE_PACKAGE_LOCK.toml"),
                Dict("schema_version" =>
                         config["execution_authorization"]["queue_lock_schema"],
                     "experiment_id" => config["experiment_id"],
                     "queue_id" => queue_id,
                     "queue_manifest_sha256" =>
                         F.file_sha256(queue_manifest),
                     "locked_file_count" => length(locked_files)))
            self_locked_tamper = F.validate_execution_authorization(
                config, :transfer, budget_path, queue_manifest, anchor_record;
                registered_preflight_path=registered_preflight)
            @test !self_locked_tamper["passed"]
            @test !self_locked_tamper["checks"][
                "queue_governance_status_report_py"]
        end
    end

    @testset "incomplete stage handoff fails closed" begin
        mktempdir() do directory
            result = joinpath(directory, "result")
            freeze = joinpath(directory, "freeze")
            mkdir(result)
            mkdir(freeze)
            handoff = F.validate_stage_handoff(
                config, result, freeze, "anchor"; require_expansion=true)
            @test !handoff["passed"]
            @test handoff["checks"]["required_files"] == false
        end
    end

    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = Legacy.make_code(split, native)
    code = generated.code

    @testset "fixed derangement plan" begin
        rng = MersenneTwister(7)
        plan1 = F.permutation_plan(
            F.problem_for(split, code, zeros(code.n)), rng)
        plan2 = F.permutation_plan(
            F.problem_for(split, code, zeros(code.n)), MersenneTwister(7))
        @test plan1 == plan2
        @test F.permutation_plan_sha256(plan1) ==
              F.permutation_plan_sha256(plan2)
        for permutation in plan1
            length(permutation) < 2 && continue
            @test sort(permutation) == collect(1:length(permutation))
            @test all(permutation[index] != index
                      for index in eachindex(permutation))
        end
    end

    # Preflight never generates or solves a registered endpoint frame.  This
    # deterministic synthetic vector exercises the same graph and kernels
    # without a frame identity; all registered cases remain post-freeze only.
    frame = 0
    synthetic_llr = [2sin(0.013bit) + 0.4cos(0.031bit) for bit in 1:code.n]
    problem = F.problem_for(split, code, synthetic_llr)
    initial = tanh.(synthetic_llr ./ 2)
    keywords = F.solver_keywords(split)
    seed = Int(config["arms"]["permutation_seed_base"]) + frame

    @testset "plan preserves every bit multiset and zero sum" begin
        rng = MersenneTwister(13)
        delta = Legacy.zero_edge_rows(problem.check_vars)
        for incident in problem.var_edges
            values = randn(rng, length(incident))
            values .-= sum(values) / length(values)
            for (position, (check_index, slot)) in enumerate(incident)
                delta[check_index][slot] = values[position]
            end
        end
        before = F.per_bit_sorted_offsets(delta, problem)
        plan = F.permutation_plan(problem, MersenneTwister(seed))
        report = F.apply_permutation!(delta, problem, plan)
        @test report.multiset_preserved
        @test report.moved_positions == sum(length, problem.var_edges)
        @test F.per_bit_sorted_offsets(delta, problem) == before
        @test F.maximum_offset_sum_error(delta, problem) <= 1.0e-12
    end

    results = Dict(arm => F.solve_factorial_variant(
        problem, code, initial, Symbol(arm); permutation_seed=seed,
        keywords..., snapshot_updates=Set([1, 2])) for arm in F.ARMS)

    retained = Split.solve_variant(problem, code, initial, F.PARITY_USE_SPEC;
        keywords..., collect_trace=true, collect_diagnostics=true,
        validate_derivatives=false, snapshot_updates=Set([1, 2]))

    @testset "custom reference equals retained v3 O1P0" begin
        checks = F.retained_reference_equivalence(
            results["asbuilt__refreshed"], retained)
        @test all(values(checks))
        evidence = F.retained_reference_evidence(
            results["asbuilt__refreshed"], retained)
        @test evidence["custom_terminal_scalar_sha256"] ==
              evidence["retained_terminal_scalar_sha256"]
        @test evidence["custom_terminal_offset_sha256"] ==
              evidence["retained_terminal_offset_sha256"]
        @test evidence["custom_trace_sha256"] ==
              evidence["retained_trace_sha256"]
        @test evidence["custom_trace_rows"] == evidence["retained_trace_rows"]
    end

    @testset "selector gates" begin
        gates = F.frame_gates(results, problem)
        @test all(values(gates))
        @test gates["update1_assignment_manipulation_active"]
        @test gates["asbuilt_replacement_manipulation_active"]
        @test gates["permuted_replacement_manipulation_active"]
        for result in values(results)
            @test result.candidate_calculations == result.accepted_steps
            @test result.all_native_projection_bounds
            @test result.all_offsets_fixed_during_calculation
            @test result.permutation_plan_sha256 ==
                  results["asbuilt__refreshed"].permutation_plan_sha256
        end
        @test results["asbuilt__frozen"].offset_replacements == 1
        @test results["permuted__frozen"].offset_replacements == 1
        @test results["asbuilt__refreshed"].offset_replacements ==
              results["asbuilt__refreshed"].accepted_steps
        @test results["permuted__refreshed"].offset_replacements ==
              results["permuted__refreshed"].accepted_steps
    end

    @testset "fixed-offset partial derivatives" begin
        reference = results["asbuilt__refreshed"]
        state = reference.snapshots[1]
        workspace = Legacy.EvalWorkspace(problem)
        evaluated = Legacy.bridge_evaluate!(workspace, problem,
            state.x, state.delta; consume_offsets=true)
        finite = Legacy.finite_difference_maximum(problem, state.x,
            state.delta, evaluated.gradient; consume_offsets=true,
            step=Float64(split["validation"]["finite_difference_step"]))
        @test finite.maximum_error <=
              Float64(split["validation"]["finite_difference_tolerance"])
        @test finite.delta_sha256_before == finite.delta_sha256_after

        derivative_keywords = merge(keywords, (maximum_updates=3,))
        derivative_results = Dict(arm => F.solve_factorial_variant(
            problem, code, initial, Symbol(arm); permutation_seed=seed,
            derivative_keywords..., collect_trace=true,
            collect_diagnostics=true, validate_derivatives=true,
            snapshot_updates=Set([1, 2, 3])) for arm in F.ARMS)
        for arm in F.ARMS
            result = derivative_results[arm]
            @test result.accepted_steps == 3
            @test result.all_finite_differences_passed
            @test result.all_offsets_fixed_during_calculation
            third = F.trace_at(result, 3)
            @test third !== nothing
            @test third["finite_difference_passed"]
            @test third["delta_before_sha256"] ==
                  third["delta_after_line_search_sha256"]
        end
    end

    @testset "paired effects and interaction" begin
        rows = NamedTuple[]
        patterns = (
            (true, false, true, false),
            (true, true, false, false),
            (false, false, true, true),
            (true, false, false, true),
        )
        for (frame_index, pattern) in enumerate(patterns)
            for (arm_index, arm) in enumerate(F.ARMS)
                value = pattern[arm_index]
                push!(rows, (; frame=frame_index, arm,
                    transmitted_word_equal=value, parity_valid=value))
            end
        end
        table = F.contrast_table(rows)
        F.add_inference!(table, 0.99375)
        @test haskey(table["transmitted_word_equal"]["contrasts"][
            "assignment_given_refreshed"], "holm_adjusted_pvalue")
        for endpoint in F.ENDPOINTS, contrast in F.REFRESH_CONTRASTS
            table[endpoint]["contrasts"][contrast]["newcombe_interval"] =
                contrast == "refresh_given_asbuilt" ?
                    Dict("lower" => -0.04, "upper" => 0.03) :
                    Dict("lower" => -0.06, "upper" => 0.02)
        end
        F.add_refresh_equivalence!(table, 0.05)
        for endpoint in F.ENDPOINTS
            @test table[endpoint]["contrasts"]["refresh_given_asbuilt"][
                "refresh_equivalent_within_margin"]
            @test !table[endpoint]["contrasts"]["refresh_given_permuted"][
                "refresh_equivalent_within_margin"]
        end
        equivalence = F.refresh_equivalence_summary(
            table, 0.05; evaluated=true)
        @test equivalence["evaluated"]
        @test equivalence["decisions"]["parity_valid"][
            "refresh_given_asbuilt"]
        @test !equivalence["decisions"]["parity_valid"][
            "refresh_given_permuted"]
        transfer_fields = F.refresh_equivalence_aggregate_fields(
            table["parity_valid"]["contrasts"]["refresh_given_asbuilt"],
            "refresh_given_asbuilt", :transfer)
        @test transfer_fields.evaluated
        @test transfer_fields.decision === true
        anchor_fields = F.refresh_equivalence_aggregate_fields(
            Dict{String,Any}(), "refresh_given_asbuilt", :anchor)
        @test anchor_fields.applicable
        @test !anchor_fields.evaluated
        @test anchor_fields.decision === missing
        @test anchor_fields.status == "not_evaluated"
        unrelated_fields = F.refresh_equivalence_aggregate_fields(
            Dict{String,Any}(), "assignment_given_refreshed", :transfer)
        @test !unrelated_fields.applicable
        @test unrelated_fields.decision === missing
        @test unrelated_fields.status == "not_applicable"
        interaction = F.factorial_interaction(
            rows, :transmitted_word_equal)
        F.add_interaction_bootstrap!(interaction, rows,
            :transmitted_word_equal; seed=1, resamples=1000,
            confidence_level=0.95)
        @test interaction["frames"] == length(patterns)
        @test haskey(interaction, "bootstrap")
    end
end
