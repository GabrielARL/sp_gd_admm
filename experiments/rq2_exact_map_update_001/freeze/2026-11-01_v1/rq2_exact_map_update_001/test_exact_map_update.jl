using Test

include(joinpath(@__DIR__, "exact_map_update.jl"))
using .RQ2ExactMapUpdate001

const STUDY = RQ2ExactMapUpdate001
const CONFIG_PATH = joinpath(@__DIR__, "config.toml")

function synthetic_case_rows(channel, frame, outcomes; ever=outcomes)
    [(;
        channel=String(channel), frame=Int(frame), arm_id=arm,
        terminal_outcome_eligible=true,
        terminal_exact_word=Bool(outcomes[index]),
        first_exact_word_update=Bool(ever[index]) ? 1 : 0,
    ) for (index, arm) in enumerate(STUDY.ARMS)]
end

@testset "registered four-job experiment" begin
    config = load_config(CONFIG_PATH)
    @test config["experiment_id"] == "RQ2-EXACT-MAP-UPDATE-001"
    @test config["scope"]["native_projected_gd_included"] == false
    @test config["scope"]["admm_included"] == false
    @test config["factorial"]["arm_order"] == collect(STUDY.ARMS)
    @test config["budget"]["update_attempts_per_arm"] == 30
    @test config["budget"]["outcome_altering_early_stop"] == false
    @test config["inference"]["atomic_contrast_count"] == 4
    @test config["inference"]["simultaneous_interval_confidence_level"] == 0.9875
    @test job_case_specs(config, STUDY.JOB_ORDER[1]) ==
          [("six_db", frame) for frame in 20001:20024]
    @test first(job_case_specs(config, STUDY.JOB_ORDER[2])) ==
          ("six_db", 60425)
    @test last(job_case_specs(config, STUDY.JOB_ORDER[2])) ==
          ("second_snr", 60448)
    @test length(job_case_specs(config, STUDY.JOB_ORDER[2])) == 48
    @test job_case_specs(config, STUDY.JOB_ORDER[3]) ==
          [("six_db", frame) for frame in 60449:60648]
    @test job_case_specs(config, STUDY.JOB_ORDER[4]) ==
          [("second_snr", frame) for frame in 60649:60848]
end

@testset "four cells and retained trajectory identities" begin
    config = load_config(CONFIG_PATH)
    graph = STUDY.BlockB.GraphView([[1, 2], [2, 3]], 3)
    llr = [1.0, -0.4, 0.7]
    results = Dict(arm => run_arm(config, graph, llr, arm) for arm in STUDY.ARMS)
    @test all(result.updates_attempted == 30 for result in values(results))
    @test all(length(result.iteration_rows) == 30 for result in values(results))

    retained_gradient = STUDY.BlockB.run_arm(
        config, graph, llr, "full__residual_gradient")
    gradient_gate = trajectory_reproduction_gate(
        results["true_gradient__armijo"], retained_gradient;
        operator=:residual_gradient)
    @test gradient_gate["passed"]

    retained_direct = STUDY.BlockB.run_arm(config, graph, llr, "full__direct")
    direct_gate = trajectory_reproduction_gate(
        results["map_minus_state__unit"], retained_direct;
        operator=:direct)
    @test direct_gate["passed"]
    @test results["map_minus_state__unit"].unit_assignment_exact_all
    @test results["map_minus_state__unit"].unit_assignment_max_abs_error == 0.0
    @test all(!row.gradient_evaluated
              for row in results["map_minus_state__unit"].iteration_rows)
    @test all(row.gradient_norm == 0.0
              for row in results["map_minus_state__unit"].iteration_rows)

    # The algebraic floating-point expression u + (F-u) is a diagnostic,
    # distinct from the exact assignment to a copied F output.
    @test results["map_minus_state__unit"].unit_identity_max_abs_error >= 0.0
    @test results["map_minus_state__unit"].unit_assignment_exact_all

    # At alpha=1, map Armijo uses the same copied F candidate as map-unit.
    map_armijo_first = results["map_minus_state__armijo"].iteration_rows[1]
    map_unit_first = results["map_minus_state__unit"].iteration_rows[1]
    @test map_armijo_first.step_size == 1.0
    @test map_armijo_first.state_sha256 == map_unit_first.state_sha256
    @test map_armijo_first.unit_assignment_exact
end

@testset "true-gradient zero direction follows retained Armijo loop" begin
    config = load_config(CONFIG_PATH)
    graph = STUDY.BlockB.GraphView([[1, 2]], 2)
    llr = [0.0, 0.0]
    observed = run_arm(config, graph, llr, "true_gradient__armijo")
    retained = STUDY.BlockB.run_arm(
        config, graph, llr, "full__residual_gradient")
    @test trajectory_reproduction_gate(
        observed, retained; operator=:residual_gradient)["passed"]
    @test observed.iteration_rows[1].directional_derivative == 0.0
    @test !observed.iteration_rows[1].non_descent
    @test observed.iteration_rows[1].backtracks == 25
    @test observed.stalls == 30
end

@testset "hard decision, syndrome, derivative, and replay checks" begin
    config = load_config(CONFIG_PATH)
    graph = STUDY.BlockB.GraphView([[1, 2, 3], [1, 3, 4], [1, 2, 4]], 4)
    llr = [1.3, -0.7, 0.45, -1.1]
    result = run_arm(config, graph, llr, "map_minus_state__unit")
    gate = STUDY.independent_decision_gate(
        graph, llr, result.u, result.terminal)
    @test gate["passed"]
    @test STUDY.BlockB.toy_derivative_gate(config)["passed"]
    replay = run_arm(config, graph, llr, "map_minus_state__unit")
    @test scientific_sha256(result.iteration_rows) ==
          scientific_sha256(replay.iteration_rows)
end

@testset "terminal outcome cannot be replaced by ever-recovered shadow" begin
    config = load_config(CONFIG_PATH)
    # true-gradient Armijo reaches the word and then leaves it; map Armijo
    # remains at the word. The registered terminal contrast is therefore +1.
    outcomes = [false, true, false, false]
    ever = [true, true, false, false]
    rows = synthetic_case_rows("six_db", 1, outcomes; ever)
    contrasts = STUDY.paired_contrasts(rows)
    direction = contrasts["direction_effect_under_armijo"]
    @test direction["gained"] == 1
    @test direction["lost"] == 0
    @test direction["net"] == 1
    @test STUDY.arm_ever_success(rows[1])
    @test !STUDY.arm_terminal_success(rows[1])
end

@testset "paired inference is stratified by channel" begin
    config = load_config(CONFIG_PATH)
    six_rows = synthetic_case_rows(
        "six_db", 60425, [false, true, false, true])
    second_rows = synthetic_case_rows(
        "second_snr", 60425, [true, false, true, false])
    rows = vcat(six_rows, second_rows)
    inference = STUDY.inference_by_channel(
        rows, config, STUDY.JOB_ORDER[2])
    @test inference["applied"]
    @test !inference["pooled_across_snr"]
    @test Set(keys(inference["families"])) == Set(("six_db", "second_snr"))
    @test all(family["case_count"] == 1
              for family in values(inference["families"]))
    @test all(family["contrast_count"] == 4
              for family in values(inference["families"]))
    @test all(!family["confirmatory"]
              for family in values(inference["families"]))
    for family in values(inference["families"]),
        contrast in values(family["contrasts"])
        interval = contrast["paired_risk_difference_interval"]
        @test -1.0 <= interval["lower"] <= interval["upper"] <= 1.0
        @test 0.0 <= contrast["raw_p_value"] <= 1.0
        @test 0.0 <= contrast["holm_adjusted_p_value"] <= 1.0
    end
    @test STUDY.exact_two_sided_mcnemar(3, 0) == 0.25
    @test STUDY.exact_two_sided_mcnemar(0, 0) == 1.0
end

@testset "science endpoint artifact contract" begin
    digest = repeat("0", 64)
    arm_records = Dict(arm => Dict(
        "first_valid_update" => 1,
        "first_exact_word_update" => 1,
        "first_valid_hard_word_sha256" => digest,
        "terminal_hard_word_sha256" => digest,
    ) for arm in STUDY.ARMS)
    aggregates = Dict("six_db" => Dict(arm => Dict(
        "terminal_exact_word_count" => 1,
        "absorbing_failure_count" => 0,
    ) for arm in STUDY.ARMS))
    science = Dict(
        "cases" => [Dict(
            "channel" => "six_db", "frame" => 1,
            "llr_sha256" => digest,
            "native" => Dict("hard_word_sha256" => digest,
                             "exact_word" => true),
            "direct_oracle_80" => Dict(
                "first_valid_update" => 1,
                "first_valid_exact_word" => true,
                "first_valid_hard_word_sha256" => digest,
                "terminal_hard_word_sha256" => digest,
            ),
            "arms" => arm_records,
        )],
        "aggregates" => aggregates,
    )
    gates = Dict(
        "native_exact_sum_product_oracle_endpoint_equal" => true,
        "map_unit_first30_oracle_equal" => true,
        "map_unit_assignment_exact" => true,
    )
    endpoint = STUDY.endpoint_payload(
        (science=science, gates=gates, frame_rows=NamedTuple[]),
        STUDY.JOB_ORDER[2])
    @test Set(keys(endpoint)) == Set((
        "schema_version", "experiment_id", "job_id", "status", "case_count",
        "case_ids_sha256", "channel_llrs_sha256", "native_bp_successes",
        "direct_oracle_80_successes", "native_bp_direct_oracle_equal",
        "map_unit_fixed30_successes", "map_unit_first30_oracle_equal",
        "unit_assignment_exact", "native_hard_words_sha256",
        "direct_oracle_80_hard_words_sha256", "arm_success_counts",
        "absorbing_failure_counts",
    ))
    @test endpoint["status"] == "pass"
    @test endpoint["native_bp_successes"] == 1
    @test endpoint["direct_oracle_80_successes"] == 1
    @test endpoint["map_unit_fixed30_successes"] == 1
    @test endpoint["arm_success_counts"] == Dict(arm => 1 for arm in STUDY.ARMS)
    @test length(STUDY.frame_columns()) == 38
    @test length(STUDY.iteration_columns()) == 32
end
