using Test

include(joinpath(@__DIR__, "rq1_gd_state_use_001.jl"))
using .RQ1GDStateUse001

@testset "provisional internal experiment RQ1-GD-STATE-USE-001" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = load_config(config_path)

    @test config["research_question"] == "RQ1"
    @test config["identifier_status"] == "provisional internal experiment ID"
    @test !config["scope"]["admm_included"]
    @test !config["scope"]["awgn_run"]
    @test !config["scope"]["performance_claim"]
    @test config["scope"]["updates_per_case"] == 2
    @test config["cases"]["tree"]["checks"] == [[1, 2], [2, 3]]
    @test config["cases"]["tree"]["edge_order"] ==
        ["b0-c0", "b1-c0", "b1-c1", "b2-c1"]
    @test config["cases"]["cycle"]["checks"] ==
        [[1, 2], [2, 3], [1, 3]]
    @test config["cases"]["cycle"]["edge_order"] ==
        ["b0-c0", "b1-c0", "b1-c1", "b2-c1", "b0-c2", "b2-c2"]
    @test config["cases"]["cycle"]["execution_gate"] ==
        "tree_validation_passed"
    @test config["intervention"]["leave_one_check_scaling"] ==
        "degree(i)/(degree(i)-1)"
    @test config["intervention"]["degree_one_rule"] ==
        "G_tilde_(i,c) = G_i"

    sources = source_gate(config)
    @test sources["passed"]
    @test all(record["passed"] for record in values(sources["records"]))
    dependencies = load_dependencies(config)
    lock = endpoint_lock_gate(config, dependencies.endpoint_config)
    @test lock["passed"]
    @test all(values(lock["checks"]))

    temporary_parent = mktempdir()
    output = joinpath(temporary_parent, "retained")
    executed = execute(;
        config_path,
        output,
        command="test_rq1_gd_state_use_001.jl deterministic execution")
    science = executed.science

    @test science["status"] == "valid"
    @test science["validation_passed"]
    @test science["tree_executed"]
    @test science["cycle_executed"]
    @test science["deterministic_replay"]["passed"]
    @test all(values(science["validation_checks"]))

    for case_name in ("tree", "cycle")
        case_result = science[case_name]
        @test case_result["status"] == "valid"
        @test case_result["validation_passed"]
        @test case_result["cells_executed"]
        @test all(values(case_result["validation_checks"]))
        @test case_result["native"]["one_update_equivalence"]["passed"]
        @test case_result["native"]["two_update_equivalence"]["passed"]
        @test case_result["initial_finite_difference"]["passed"]
        @test case_result["update1"]["accepted"]
        @test case_result["check_indexed_values"]["passed"]
        @test all(values(case_result["check_indexed_values"]["checks"]))
        @test haskey(case_result["check_indexed_values"],
            "constructed_values_leaving_out_indexed_check")
        @test haskey(case_result["check_indexed_values"],
            "constructed_value_mean_error_by_bit")
        @test case_result["check_indexed_values"]["checks"][
            "constructed_value_mean"]
        @test case_result["check_row_relabeling"]["executed"]
        @test case_result["check_row_relabeling"]["passed"]
        @test case_result["validation_checks"]["three_control_paths_exact"]
        @test case_result["validation_checks"][
            "three_controls_match_native_two_updates"]
        @test case_result["validation_checks"][
            "retention_and_use_state_rules"]
        @test case_result["validation_checks"][
            "retained_state_hash_distinct_from_collapsed"]
        @test case_result["validation_checks"][
            "factorial_storage_and_switch_nulls_exact"]
        @test case_result["validation_checks"]["no_divergence_before_update2"]

        for control in config["intervention"]["controls"]
            comparisons = case_result["two_update_native_comparisons"][control]
            @test comparisons["current"]["passed"]
            @test comparisons["archived"]["passed"]
        end

        for cell_id in config["intervention"]["cell_order"]
            cell = case_result["cells"][cell_id]
            validation = case_result["cell_validations"][cell_id]
            @test validation["passed"]
            @test all(values(validation["checks"]))
            @test cell["entry_update1_sha256"] ==
                case_result["update1_shared_sha256"]
            @test cell["finite_difference"]["passed"]
            @test cell["finite_difference"]["all_points_in_domain"]
            @test cell["update2"]["delta_held_fixed"]
            @test cell["update2"]["all_trial_readings_in_box"]
            @test cell["update2"]["all_projection_checks"]
            @test cell["syndrome"] == cell["syndrome_recomputed"]
        end

        active = case_result["cells"]["retained__consumed"]
        baseline = case_result["cells"]["collapsed__ignored"]
        @test active["retained_state_sha256_before"] !=
            baseline["retained_state_sha256_before"]
        @test active["effective_delta_sha256_before"] !=
            baseline["effective_delta_sha256_before"]
        # The registered effect prediction is recorded but is not a validity gate.
        @test haskey(case_result["active_effect"], "nonzero_diagnostic_change")
        @test haskey(case_result, "factorial_contrasts")
        @test haskey(case_result["factorial_contrasts"],
            "storage_only_RI_minus_CI")
        @test haskey(case_result["factorial_contrasts"],
            "use_switch_CC_minus_CI")
        @test haskey(case_result["factorial_contrasts"],
            "active_RC_minus_CI")
        @test haskey(case_result["factorial_contrasts"],
            "interaction_RC_minus_RI_minus_CC_plus_CI")
    end

    tree_effect = science["tree"]["active_effect"]
    @test tree_effect["only_bit2_is_intervention_site"]
    @test tree_effect["delta_maximum_absolute_by_bit"][1] == 0.0
    @test tree_effect["delta_maximum_absolute_by_bit"][3] == 0.0
    @test haskey(science["claim_boundary"], "scoped_mechanism_claim")
    @test haskey(science["claim_boundary"], "tree")
    @test haskey(science["claim_boundary"], "cycle")

    @test isfile(joinpath(output, "trace.json"))
    @test isfile(joinpath(output, "manifest.json"))
    @test isfile(joinpath(output, "MANIFEST.sha256"))
    for retained in (
        "config.toml",
        "experiment_card.md",
        "rq1_gd_state_use_001.jl",
        "test_rq1_gd_state_use_001.jl",
        "endpoint_config.toml",
        "endpoint_experiment_card.md",
        "endpoint_rq1_endpoint_001.jl",
        "endpoint_test_rq1_endpoint_001.jl",
        "current_run_three_receivers.jl",
        "archived_r050_run_three_receivers.jl",
    )
        @test isfile(joinpath(output, "source", retained))
    end
    @test executed.written.manifest["validation_passed"]
    @test executed.written.manifest["deterministic_replay_passed"]
    @test executed.written.manifest["non_overwrite_gate"]

    altered = deepcopy(config)
    altered["sources"]["endpoint_runner_sha256"] = repeat("0", 64)
    @test !source_gate(altered)["passed"]
    @test_throws ArgumentError execute(;
        config_path,
        output,
        command="must refuse overwrite")
end
