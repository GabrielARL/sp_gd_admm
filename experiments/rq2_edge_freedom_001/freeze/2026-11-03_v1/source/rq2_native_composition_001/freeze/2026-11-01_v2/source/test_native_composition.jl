using Test
using TOML

include(joinpath(@__DIR__, "native_composition.jl"))
using .RQ2NativeComposition001

const Study = RQ2NativeComposition001

function registry_fixture(; joint_atomic=false, joint_attributable=false)
    backends = Study.EXPECTED_BACKENDS
    changed_fields = [
        ["state_family"],
        ["state_family"],
        ["target_family"],
        ["projection_family"],
        ["state_family", "target_family", "update_family"],
        ["target_family"],
        ["state_family"],
        ["update_family"],
        ["protocol_family"],
        ["protocol_family"],
    ]
    fingerprint = Dict(
        "state_family" => "state_1",
        "target_family" => "target_1",
        "update_family" => "update_1",
        "projection_family" => "projection_1",
        "protocol_family" => "protocol_1",
    )
    rungs = Dict{String,Any}[]
    for (position, id) in enumerate(Study.FORWARD_ORDER)
        record = Dict{String,Any}(
            "id" => id,
            "position" => position,
            "backend" => backends[id],
        )
        for field in Study.FINGERPRINT_FIELDS
            record[field] = fingerprint[field]
        end
        push!(rungs, record)
        if position <= length(changed_fields)
            for field in changed_fields[position]
                fingerprint[field] = "$(field)_$(position + 1)"
            end
        end
    end
    transitions = Dict{String,Any}[]
    for index in 1:length(Study.FORWARD_ORDER)-1
        from = Study.FORWARD_ORDER[index]
        to = Study.FORWARD_ORDER[index + 1]
        joint = from == Study.JOINT_FROM && to == Study.JOINT_TO
        push!(transitions, Dict(
            "from" => from,
            "to" => to,
            "atomic" => joint ? joint_atomic : true,
            "attributable" => joint ? joint_attributable : true,
            "changed_operation" => joint ? "registered joint handoff" :
                "one registered operation",
            "changed_fingerprint_fields" => changed_fields[index],
        ))
    end
    Dict(
        "schema_version" => Study.REGISTRY_SCHEMA,
        "experiment_id" => Study.EXPERIMENT_ID,
        "forward_order" => collect(Study.FORWARD_ORDER),
        "rungs" => rungs,
        "transitions" => transitions,
    )
end

function write_toml_fixture(path, payload)
    open(path, "w") do io
        TOML.print(io, payload; sorted=true)
    end
end

@testset "registered rung fingerprints fail closed at the joint handoff" begin
    valid = registry_fixture()
    gate = registry_gate(valid)
    @test gate["passed"]
    @test gate["checks"]["one_registered_joint_handoff"]
    @test !gate["joint_handoff"]["atomic"]
    @test !gate["joint_handoff"]["attributable"]

    falsely_atomic = registry_fixture(joint_atomic=true)
    @test !registry_gate(falsely_atomic)["passed"]
    falsely_attributable = registry_fixture(joint_attributable=true)
    @test !registry_gate(falsely_attributable)["passed"]

    wrong_fingerprint = registry_fixture()
    wrong_fingerprint["transitions"][1]["changed_fingerprint_fields"] =
        ["target_family"]
    wrong_gate = registry_gate(wrong_fingerprint)
    @test !wrong_gate["passed"]
    @test !wrong_gate["checks"]["adjacent_fingerprint_differences"]

    runtime = Dict(id => (id=id, backend=Study.EXPECTED_BACKENDS[id])
                   for id in Study.FORWARD_ORDER)
    @test Study.runtime_rung_identity_gate(runtime)["passed"]
    runtime[Study.FORWARD_ORDER[6]] =
        (id=Study.FORWARD_ORDER[6], backend="block_b")
    @test !Study.runtime_rung_identity_gate(runtime)["passed"]

    registered = load_registry(joinpath(@__DIR__, "rung_registry.toml"))
    @test registry_gate(registered)["passed"]
    @test Study.EXPECTED_BACKENDS["edge_product_residual_gradient_tied"] ==
        "product_edge"
    config = load_config(joinpath(@__DIR__, "config.toml"))
    @test config["inference"]["atomic_transition_count"] == 9

    wrong_order = registry_fixture()
    reverse!(wrong_order["forward_order"])
    temporary = mktempdir()
    path = joinpath(temporary, "rungs.toml")
    write_toml_fixture(path, wrong_order)
    @test_throws ArgumentError load_registry(path)
end

@testset "inactive directed-edge storage is a strict null" begin
    x = [0.8, -0.2, 0.13, -0.91]
    bits_before = copy(reinterpret(UInt64, x))
    gate = shadow_state_null_gate(x, [[1, 2, 3], [2, 3, 4]])
    @test gate["passed"]
    @test reinterpret(UInt64, x) == bits_before
    @test gate["checks"]["shadow_allocated"]
    @test gate["checks"]["shadow_is_zero"]
end

@testset "shadow rerun compares the complete projected-GD trajectory" begin
    trajectory = (;
        x=[0.8, -0.2], delta=[[0.1, -0.1]], hard=BitVector([false, true]),
        syndrome=BitVector([true]), accepted_steps=2, requested_steps=3,
        status="iteration_limit", trace=[Dict("update" => 1, "loss" => 2.0)],
        initial_loss=4.0, last_accepted_fixed_offset_loss=2.0,
        terminal_refreshed_loss=1.5,
        terminal_terms=(channel=0.5, parity=0.75, binary=0.25))
    oracle = Dict("passed" => true)
    gate = Study.shadow_trajectory_gate(
        trajectory, deepcopy(trajectory), oracle, oracle, [[0.0, 0.0]])
    @test gate["passed"]
    @test gate["primary_trace_sha256"] == gate["shadow_trace_sha256"]
    @test gate["primary_terminal_scalar_sha256"] ==
        gate["shadow_terminal_scalar_sha256"]

    changed = merge(trajectory, (;
        trace=[Dict("update" => 1, "loss" => 1.99)]))
    changed_gate = Study.shadow_trajectory_gate(
        trajectory, changed, oracle, oracle, [[0.0, 0.0]])
    @test !changed_gate["passed"]
    @test !changed_gate["checks"]["objective_trace"]
end

@testset "unavailable projected-GD iteration diagnostics remain null" begin
    result = (trace=[Dict(
        "update" => 1,
        "accepted" => true,
        "loss_before" => 2.0,
        "accepted_fixed_offset_loss" => 1.5,
        "x_after_sha256" => "state-hash",
    )],)
    rows = Study.iteration_rows_for(7, "six_db", "native_projected_gd", result)
    @test length(rows) == 1
    @test rows[1].hard_word_sha256 === nothing
    @test rows[1].syndrome_weight === nothing
    @test rows[1].parity_valid === nothing
    @test rows[1].transmitted_word_equal === nothing
    @test occursin("\"hard_word_sha256\":null", canonical_json(rows))
    @test occursin("\"syndrome_weight\":null", canonical_json(rows))

    edge_result = (iteration_rows=[(;
        update=1, accepted=true, objective_before=2.0, objective_after=1.0,
        hard_word_sha256="hard-hash", syndrome_weight=0,
        parity_valid=true, exact_word=true)],)
    edge_rows = Study.iteration_rows_for(
        7, "six_db", "exact_sp_residual_gradient_full", edge_result)
    @test edge_rows[1].state_sha256 === nothing
    @test edge_rows[1].hard_word_sha256 == "hard-hash"

    block_a_result = (traces=[(;
        update=1, accepted=true, loss_before=2.0, loss_after=1.0,
        x_after_sha256="state-hash", syndrome_weight=0,
        parity_valid=true, transmitted_word_equal=true)],)
    block_a_rows = Study.iteration_rows_for(
        7, "six_db", "assigned_frozen_compound_box", block_a_result)
    @test block_a_rows[1].state_sha256 == "state-hash"
    @test block_a_rows[1].hard_word_sha256 === nothing

    product_result = (rows=[(;
        update=1, accepted=true, objective_before=2.0, objective_after=1.0,
        state_sha256="edge-state-hash", hard_word_sha256="edge-hard-hash",
        syndrome_weight=0, parity_valid=true,
        transmitted_word_equal=true)],)
    product_rows = Study.iteration_rows_for(
        7, "six_db", "edge_product_residual_gradient_tied", product_result)
    @test product_rows[1].state_sha256 == "edge-state-hash"
    @test product_rows[1].hard_word_sha256 == "edge-hard-hash"
end

@testset "product-edge and exact sum-product residual derivatives" begin
    config = Dict{String,Any}(
        "validation" => Dict{String,Any}(
            "finite_difference_step" => 1.0e-6,
            "finite_difference_tolerance" => 3.0e-6,
        ),
    )
    gate = common_harness_gate(config)
    @test gate["passed"]
    @test gate["checks"]["product_and_exact_derivatives"]
    @test gate["checks"]["product_target_is_not_exact_target"]
    @test gate["checks"]["independent_box_projection"]
    @test gate["checks"]["exact_local_check_enumeration"]
    @test gate["exact_check_enumeration"]["maximum_absolute_error"] <= 2.0e-12
    @test all(record["maximum_absolute_error"] <= 3.0e-6
              for record in values(gate["derivative_records"]))

    graph = Study.BlockB.GraphView([[1, 2]], 2)
    llr = [0.7, -0.4]
    u = zeros(2)
    observed = product_map(graph, llr, u, :full).output
    @test observed[1] == tanh(llr[2] / 2)
    @test observed[2] == tanh(llr[1] / 2)
end

@testset "fixed-30 rung is separate from the 80-attempt BP endpoint oracle" begin
    graph = Study.BlockB.GraphView([[1, 2], [2, 3]], 3)
    runs = Study.run_exact_direct_endpoint_oracle(
        graph, [0.31, -0.27, 0.44]; fixed_attempts=3,
        endpoint_attempts=8)
    @test length(runs.rung.iteration_rows) == 3
    @test length(runs.endpoint.iteration_rows) == 8
    @test runs.rung.accepted_updates == 3
    @test runs.endpoint.endpoint_attempts == 8
    expected = zeros(Study.BlockB.edge_count(graph))
    for _ in 1:3
        expected = Study.BlockB.evaluate_map(
            graph, [0.31, -0.27, 0.44], expected, :full).output
    end
    @test runs.rung.u == expected
    stop_rung = Study.rung_from_stop30(runs; cap=3)
    @test stop_rung.id == "exact_sp_direct_full_stop30"
    @test stop_rung.updates <= 3
end

@testset "native BP oracle covers valid late stops and invalid cap terminals" begin
    graph = Study.BlockB.GraphView([[1, 2]], 2)
    hard = BitVector([false, false])
    snapshot = (;
        update=40, hard, lpost_metric=[1.0, 2.0], q=[0.1, 0.2],
        u=[0.3, 0.4], syndrome_weight=0)
    late_endpoint = (;
        first_valid_snapshot=snapshot, first_valid_update=40,
        endpoint_attempts=80, terminal_snapshot=snapshot)
    late_native = (;
        valid=true, iterations=40, hard, lpost_metric=[1.0, 2.0],
        q=[[0.1, 0.2]], u=[[0.3, 0.4]], syndrome_weight=0)
    late_gate = Study.native_bp_endpoint_gate(graph, late_endpoint, late_native)
    @test late_gate["passed"]
    @test late_gate["mode"] == "first_valid_stopping_endpoint"
    @test late_gate["native_iteration"] == 40

    invalid_terminal = (;
        hard=BitVector([false, true]), lpost_metric=[1.0, -2.0],
        q=[0.5, -0.25], u=[0.2, -0.1], syndrome_weight=1)
    invalid_endpoint = (;
        first_valid_snapshot=nothing, first_valid_update=0,
        endpoint_attempts=80, terminal_snapshot=invalid_terminal)
    invalid_native = (;
        valid=false, iterations=80, hard=copy(invalid_terminal.hard),
        lpost_metric=copy(invalid_terminal.lpost_metric),
        q=[[0.5, -0.25]], u=[[0.2, -0.1]], syndrome_weight=1)
    invalid_gate = Study.native_bp_endpoint_gate(
        graph, invalid_endpoint, invalid_native)
    @test invalid_gate["passed"]
    @test invalid_gate["mode"] == "invalid_iteration_cap_terminal_endpoint"

    changed_native = merge(invalid_native, (; q=[[0.5, -0.24]]))
    changed_gate = Study.native_bp_endpoint_gate(
        graph, invalid_endpoint, changed_native)
    @test !changed_gate["passed"]
    @test !changed_gate["checks"]["variable_to_check_float_bits"]
end


@testset "Job 6 keeps fresh and locked evidence separate" begin
    rows = NamedTuple[]
    function add_case(frame, offset)
        for (position, id) in enumerate(Study.FORWARD_ORDER)
            success = position >= 5 + offset
            push!(rows, (; channel="six_db", frame, rung_id=id,
                transmitted_word_equal=success))
        end
        for id in ("assigned_frozen_compound_unconstrained",
                   "exact_sp_direct_tied_fixed30")
            push!(rows, (; channel="six_db", frame, rung_id=id,
                transmitted_word_equal=offset == 0))
        end
    end
    add_case(60025, 0)
    add_case(30001, 1)
    config = Dict{String,Any}(
        "frames" => Dict{String,Any}(
            "six_db_first" => 60025, "six_db_last" => 60025,
            "locked_first" => 30001, "locked_last" => 30001,
        ),
    )
    separated = Study.job6_evidence_groups(rows, config)
    @test Set(keys(separated.ledgers)) ==
        Set(("six_db_transfer", "locked_attribution"))
    @test separated.ledgers["six_db_transfer"]["case_count"] == 1
    @test separated.ledgers["locked_attribution"]["case_count"] == 1
    @test separated.ledgers["six_db_transfer"]["native_gap_accounted"]
    @test separated.ledgers["locked_attribution"]["native_gap_accounted"]
    @test Set(keys(separated.controls)) ==
        Set(("six_db_transfer", "locked_attribution"))
    @test all(haskey(control, "interaction_detected")
              for control in values(separated.controls))
    @test all(!haskey(control, "order_sensitive")
              for control in values(separated.controls))
end

@testset "Job 6 locked endpoints reproduce the registered 107-to-200 gap" begin
    ledger = Dict(
        "case_count" => 200,
        "native_projected_gd_successes" => 107,
        "native_exact_sum_product_successes" => 200,
        "native_net_gap" => 93,
        "native_gap_accounted" => true,
    )
    config = Dict("job6" => Dict("locked_expected" => Dict(
        "case_count" => 200,
        "native_projected_gd_successes" => 107,
        "native_exact_sum_product_successes" => 200,
        "native_net_gap" => 93,
    )))
    gate = Study.locked_endpoint_reproduction_gate(
        Dict("locked_attribution" => ledger), config)
    @test gate["passed"]
    changed = deepcopy(ledger)
    changed["native_projected_gd_successes"] = 108
    @test !Study.locked_endpoint_reproduction_gate(
        Dict("locked_attribution" => changed), config)["passed"]
end

@testset "signed transition ledger telescopes but remains non-atomic" begin
    rows = NamedTuple[]
    for frame in 1:2
        for (position, id) in enumerate(Study.FORWARD_ORDER)
            success = frame == 1 ? position >= 6 : position >= 9
            push!(rows, (; channel="six_db", frame, rung_id=id,
                transmitted_word_equal=success))
        end
    end
    ledger = Study.transition_ledger(rows)
    @test ledger["native_gap_accounted"]
    @test ledger["transition_net_sum"] == ledger["native_net_gap"] == 2
    @test !ledger["atomic_causal_decomposition_complete"]
    joint = only(filter(record -> !record["atomic"], ledger["transitions"]))
    @test joint["from"] == Study.JOINT_FROM
    @test joint["to"] == Study.JOINT_TO
    @test !joint["attributable"]
    @test all(transition["both_success"] +
              transition["to_only_success"] +
              transition["from_only_success"] +
              transition["both_failure"] == transition["pairs"]
              for transition in ledger["transitions"])

    config = Dict("inference" => Dict(
        "familywise_alpha" => 0.05,
        "atomic_transition_count" => 9,
        "simultaneous_interval_confidence_level" => 1.0 - 0.05 / 9,
        "holm_family" => "unit family of atomic transitions",
    ))
    inference = Study.paired_transition_inference(ledger, config)
    @test inference["applied"]
    @test inference["family_size"] == 9
    @test !inference["non_atomic_handoff_included"]
    @test length(inference["records"]) == 9
    @test inference["non_atomic_handoff"]["descriptive_only"]
    @test !haskey(inference["records"],
        Study.JOINT_FROM * "__to__" * Study.JOINT_TO)
    @test all(0.0 <= record["holm_adjusted_pvalue"] <= 1.0
              for record in values(inference["records"]))
    @test all(record["newcombe_interval"]["confidence_level"] ==
              1.0 - 0.05 / 9
              for record in values(inference["records"]))
end

@testset "atomic result contract and deterministic hashes" begin
    temporary = mktempdir()
    config_path = joinpath(temporary, "config.toml")
    registry_path = joinpath(temporary, "rungs.toml")
    write_toml_fixture(config_path, Dict("fixture" => true))
    write_toml_fixture(registry_path, registry_fixture())

    validation = Dict("passed" => true, "value" => 7)
    science = Study.validation_science("01_switch_registry_gate", validation)
    primary = Study.result_wrapper(science; correctness_passed=true)
    replay = deepcopy(primary)
    timing = Dict(
        "schema_version" => Study.TIMING_SCHEMA,
        "experiment_id" => Study.EXPERIMENT_ID,
        "job_id" => "01_switch_registry_gate",
        "frame_count" => 0,
        "validation_case_count" => 0,
        "rung_count" => 0,
        "execution_variant_count" => 0,
        "pass_count" => 0,
        "primary_seconds" => 0.1,
        "replay_seconds" => 0.1,
        "write_seconds" => 0.0,
        "total_seconds" => 0.2,
        "seconds_per_frame_variant" => 0.0,
        "seconds_per_frame_rung" => 0.0,
    )
    output = joinpath(temporary, "result")
    completion = Study.write_atomic_result(
        output, "01_switch_registry_gate", config_path, registry_path,
        primary, replay, timing; validation_only=true)
    @test completion["status"] == "complete_valid"
    @test completion["deterministic_replay_passed"]
    @test isfile(joinpath(output, "science.json"))
    @test isfile(joinpath(output, "job_gate.toml"))
    @test isfile(joinpath(output, "COMPLETED.toml"))
    @test isfile(joinpath(output, "MANIFEST.sha256"))
    @test !isfile(joinpath(output, "endpoint_gate.toml"))
    job_gate = TOML.parsefile(joinpath(output, "job_gate.toml"))
    @test job_gate["primary_science_sha256"] ==
        Study.file_sha256(joinpath(output, "science.json"))
    @test job_gate["replay_science_sha256"] ==
        Study.file_sha256(joinpath(output, "science.json"))
    written_timing = TOML.parsefile(joinpath(output, "timing.toml"))
    @test written_timing["total_seconds"] ==
        written_timing["primary_seconds"] +
        written_timing["replay_seconds"] + written_timing["write_seconds"]
    @test_throws ArgumentError Study.write_atomic_result(
        output, "01_switch_registry_gate", config_path, registry_path,
        primary, replay, timing; validation_only=true)

    for line in eachline(joinpath(output, "MANIFEST.sha256"))
        digest, name = split(line; limit=2)
        @test Study.file_sha256(joinpath(output, strip(name))) == digest
    end
end

@testset "science endpoint contract forbids a single-factor handoff claim" begin
    temporary = mktempdir()
    config_path = joinpath(temporary, "config.toml")
    registry_path = joinpath(temporary, "rungs.toml")
    write_toml_fixture(config_path, Dict("fixture" => true))
    write_toml_fixture(registry_path, registry_fixture())
    science = Dict(
        "schema_version" => Study.SCIENCE_SCHEMA,
        "experiment_id" => Study.EXPERIMENT_ID,
        "case_count" => 1,
    )
    gates = Dict(
        "native_gd_endpoint_equal" => true,
        "native_bp_endpoint_equal" => true,
        "native_gap_accounted" => true,
    )
    ledger = Dict(
        "native_projected_gd_successes" => 0,
        "native_exact_sum_product_successes" => 1,
        "native_net_gap" => 1,
        "transition_net_sum" => 1,
    )
    result = Study.result_wrapper(science; gates, ledger,
                                  correctness_passed=true)
    timing = Dict(
        "schema_version" => Study.TIMING_SCHEMA,
        "experiment_id" => Study.EXPERIMENT_ID,
        "job_id" => "04_fresh_dual_snr_anchor",
        "frame_count" => 1,
        "rung_count" => 11, "execution_variant_count" => 11,
        "pass_count" => 2, "primary_seconds" => 1.0,
        "replay_seconds" => 1.0, "write_seconds" => 0.0,
        "total_seconds" => 2.0, "seconds_per_frame_variant" => 2.0 / 11,
        "seconds_per_frame_rung" => 2.0 / 11,
    )
    output = joinpath(temporary, "science_result")
    Study.write_atomic_result(
        output, "04_fresh_dual_snr_anchor", config_path, registry_path,
        result, deepcopy(result), timing; validation_only=false)
    endpoint = TOML.parsefile(joinpath(output, "endpoint_gate.toml"))
    @test endpoint["joint_handoff_registered_non_atomic"]
    @test !endpoint["joint_handoff_single_factor_claim_made"]
    @test !endpoint["atomic_causal_decomposition_complete"]
    @test endpoint["native_gap_accounted"]
end

