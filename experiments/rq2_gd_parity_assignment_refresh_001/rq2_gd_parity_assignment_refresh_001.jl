#!/usr/bin/env julia

module RQ2GDParityAssignmentRefresh001

# Four constructed projected-GD arms cross two selectors while holding the
# objective and native projection rule fixed:
#
#   assignment: as-built or one fixed within-bit derangement per frame
#   replacement: adopt every new candidate or retain the first candidate
#
# Every arm calculates both candidates after every accepted update.  The
# frozen arms discard later candidates, so persistence is not confounded with
# whether the candidate calculation was performed.

using Dates
using JadeJcade
using LinearAlgebra
using Random
using SHA
using Statistics
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__
const TEST_PATH = joinpath(HERE, "test_rq2_gd_parity_assignment_refresh_001.jl")
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const PREFLIGHT_PATH = joinpath(HERE, "preflight_validation.md")
const BUDGET_TOOL_PATH = joinpath(HERE, "queue_tools", "derive_budget.py")
const BUDGET_TEST_PATH = joinpath(HERE, "queue_tools", "test_derive_budget.py")
const QUEUE_STATUS_PATH = joinpath(HERE, "queue_tools", "status_report.py")
const QUEUE_LOCK_TOOL_PATH = joinpath(HERE, "queue_tools", "lock_queue_package.py")
const ANCHOR_WRAPPER_PATH = joinpath(HERE, "queue_tools", "run_anchor_once.sh")
const QUEUE_WRAPPER_PATH = joinpath(HERE, "queue_tools", "run_queue.sh")
const QUEUE_TEMPLATE_PATH = joinpath(HERE, "queue_tools", "queue_template.toml")
const QUEUE_README_TEMPLATE_PATH = joinpath(
    HERE, "queue_tools", "QUEUE_PACKAGE_README.template.md")
const QUEUE_TEST_PATH = joinpath(HERE, "queue_tools", "test_queue_tools.py")
const VENDOR_ROOT = joinpath(HERE, "vendor")
const SPLIT_ROOT = joinpath(VENDOR_ROOT, "rq2_gd_offset_split_001")
const SPLIT_RUNNER_PATH = joinpath(SPLIT_ROOT, "rq2_gd_offset_split_001.jl")
const SPLIT_CONFIG_PATH = joinpath(SPLIT_ROOT, "config.toml")
const SPLIT_TEST_PATH = joinpath(SPLIT_ROOT, "test_rq2_gd_offset_split_001.jl")

include(SPLIT_RUNNER_PATH)
const Split = RQ2GDOffsetSplit001
const Legacy = Split.Legacy

const BridgeProblem = Legacy.BridgeProblem
const vector_sha256 = Legacy.vector_sha256
const edge_sha256 = Legacy.edge_sha256
const file_sha256 = Legacy.file_sha256
const canonical_json = Legacy.canonical_json
const write_new_file = Legacy.write_new_file
const write_csv = Legacy.write_csv
const parse_simple_csv = Legacy.parse_simple_csv
const git_output = Legacy.git_output

scientific_sha256(value) = bytes2hex(sha256(
    Vector{UInt8}(codeunits(canonical_json(value)))))

const ARMS = ("asbuilt__refreshed", "permuted__refreshed",
              "asbuilt__frozen", "permuted__frozen")
const PARITY_USE_SPEC = Split.REQUIRED_ARMS[2]
const CONTRASTS = (
    (id="assignment_given_refreshed", treatment="asbuilt__refreshed",
     reference="permuted__refreshed"),
    (id="assignment_given_frozen", treatment="asbuilt__frozen",
     reference="permuted__frozen"),
    (id="refresh_given_asbuilt", treatment="asbuilt__refreshed",
     reference="asbuilt__frozen"),
    (id="refresh_given_permuted", treatment="permuted__refreshed",
     reference="permuted__frozen"),
)
const ENDPOINTS = ("transmitted_word_equal", "parity_valid")
const REFRESH_CONTRASTS = ("refresh_given_asbuilt", "refresh_given_permuted")
const QUEUE_TOP_LEVEL_KEYS = Set((
    "schema_version", "queue_id", "experiment_id", "stages",
    "execution_mode", "automatic_restart_allowed",
    "interrupted_attempt_must_be_retained",
    "manual_relaunch_requires_new_attempt_directory",
    "execution", "paths", "inventory", "telemetry"))
const QUEUE_PATH_KEYS = Set((
    "repository_root", "project_root", "config", "runner", "preflight", "freeze",
    "anchor_result", "transfer_result", "attribution_result",
    "budget_transfer", "budget_attribution"))
const QUEUE_BASE_TELEMETRY = Set((
    "queue.lock", "queue.log", "progress.toml", "status_history.tsv",
    "QUEUE_COMPLETED.toml", "QUEUE_FAILED.toml"))
const QUEUE_JOB_IDS = ["J01", "J02"]

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq2-gd-parity-assignment-refresh-001/v1" ||
        throw(ArgumentError("unsupported schema"))
    config["experiment_id"] == "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["scope"]["bp_arm_included"] == false ||
        throw(ArgumentError("a BP arm is outside this experiment"))
    config["anchor"]["frame_first"] == 20001 &&
        config["anchor"]["frame_last"] == 20024 ||
        throw(ArgumentError("anchor frame set changed"))
    config["transfer"]["frame_first"] == 40001 &&
        config["transfer"]["frame_last"] == 40200 ||
        throw(ArgumentError("transfer frame set changed"))
    config["attribution"]["frame_first"] == 30001 &&
        config["attribution"]["frame_last"] == 30200 ||
        throw(ArgumentError("attribution frame set changed"))
    String.(config["arms"]["order"]) == collect(ARMS) ||
        throw(ArgumentError("arm order changed"))
    config
end

split_config_path(config) = SPLIT_CONFIG_PATH

function resolve_local_path(path::AbstractString)
    isabspath(path) ? normpath(path) : normpath(joinpath(HERE, path))
end

retained_input_path(config) = resolve_local_path(
    String(config["protocol"]["retained_split_input_table"]))

prerequisite_result_path(config) = resolve_local_path(
    String(config["prerequisite"]["result"]))

attribution_reference_path(config) = resolve_local_path(
    String(config["attribution_reference"]["frames"]))

function load_split_config(config)
    path = split_config_path(config)
    file_sha256(path) == String(config["protocol"]["split_config_sha256"]) ||
        throw(ArgumentError("retained split configuration changed"))
    split = TOML.parsefile(path)
    split["experiment_id"] == "RQ2-GD-OFFSET-SPLIT-001" ||
        throw(ArgumentError("protocol source is not the split experiment"))
    split
end

function stage_frames(config, stage::Symbol)
    section = stage === :anchor ? config["anchor"] :
              stage === :transfer ? config["transfer"] :
              stage === :attribution ? config["attribution"] :
              throw(ArgumentError("unknown stage $stage"))
    Int(section["frame_first"]):Int(section["frame_last"])
end

function source_gate(config)
    protocol = config["protocol"]
    checks = Dict{String,Bool}(
        "split_config" => file_sha256(split_config_path(config)) ==
            String(protocol["split_config_sha256"]),
        "split_runner" => file_sha256(SPLIT_RUNNER_PATH) ==
            String(protocol["split_runner_sha256"]),
        "legacy_runner" => file_sha256(Split.LEGACY_RUNNER_PATH) ==
            String(protocol["legacy_runner_sha256"]),
        "split_test" => file_sha256(SPLIT_TEST_PATH) ==
            String(protocol["split_test_sha256"]),
        "retained_input_table" => file_sha256(retained_input_path(config)) ==
            String(protocol["retained_split_input_table_sha256"]),
        "attribution_reference" =>
            file_sha256(attribution_reference_path(config)) ==
            String(config["attribution_reference"]["frames_sha256"]),
    )
    split = load_split_config(config)
    legacy_gate = Legacy.source_gate(split)
    checks["retained_static_sources"] = Bool(legacy_gate["passed"])
    Dict("passed" => all(values(checks)), "checks" => checks,
         "retained_source_gate" => legacy_gate)
end

function prerequisite_gate(config)
    result = prerequisite_result_path(config)
    completion_path = joinpath(result, "COMPLETED.toml")
    manifest_path = joinpath(result, "manifest.toml")
    science_path = joinpath(result, "science.json")
    aggregate_path = joinpath(result, "aggregate.csv")
    checks = Dict{String,Bool}(
        "completion_exists" => isfile(completion_path),
        "manifest_exists" => isfile(manifest_path),
        "science_exists" => isfile(science_path),
        "aggregate_exists" => isfile(aggregate_path),
        "checksum_manifest_exists" => isfile(joinpath(result, "MANIFEST.sha256")),
    )
    if all(values(checks))
        completion = TOML.parsefile(completion_path)
        manifest = TOML.parsefile(manifest_path)
        checksum = Split.verify_result_checksum_manifest(result)
        checks["checksum_manifest"] = Bool(checksum["passed"])
        checks["experiment"] = get(completion, "experiment_id", "") ==
            config["prerequisite"]["experiment_id"] &&
            get(manifest, "experiment_id", "") ==
                config["prerequisite"]["experiment_id"]
        checks["heldout_stage"] = get(completion, "stage", "") == "heldout" &&
            get(manifest, "stage", "") == "heldout"
        checks["complete_valid"] = get(completion, "status", "") ==
            "complete_valid" && get(completion, "correctness_passed", false)
        checks["deterministic_replay"] = get(
            completion, "deterministic_replay_passed", false)
        checks["science_file_bound_to_completion"] =
            get(completion, "science_sha256", "") == file_sha256(science_path)
        rows = parse_simple_csv(aggregate_path)
        selected = Dict((row.endpoint, row.contrast_id) => row for row in rows)
        key_rows = [(endpoint, String(config["prerequisite"]["selection_contrast"]))
                    for endpoint in String.(config["prerequisite"]["selection_endpoint"])]
        checks["selection_rows_exist"] = all(haskey(selected, key) for key in key_rows)
        checks["selection_arm_identity"] = checks["selection_rows_exist"] && all(
            selected[key].treatment_arm == "objective1__bounds0" &&
            selected[key].reference_arm == "objective0__bounds0"
            for key in key_rows)
        checks["selection_rule"] = checks["selection_arm_identity"] && all(
            parse(Int, selected[key].treatment_only_success) >
            parse(Int, selected[key].reference_only_success) for key in key_rows)
    end
    Dict("passed" => all(values(checks)), "checks" => checks, "result" => result)
end

function preflight_gate(config_path::AbstractString=DEFAULT_CONFIG;
                        preflight_path::AbstractString=PREFLIGHT_PATH)
    preflight_path = abspath(preflight_path)
    isfile(preflight_path) || return Dict(
        "passed" => false, "reason" => "missing_preflight_record")
    (!islink(preflight_path) && try
        realpath(preflight_path) == preflight_path
    catch
        false
    end) || return Dict(
        "passed" => false, "reason" => "symlinked_preflight_record")
    fields = Dict{String,String}()
    for line in eachline(preflight_path)
        matched = match(r"^([a-z][a-z0-9_]*)[ ]*:[ ]*`?([^` ]+)`?[ ]*$", line)
        matched === nothing && continue
        fields[String(matched.captures[1])] = String(matched.captures[2])
    end
    expected = Dict(
        "validation_status" => "pass",
        "test_exit_code" => "0",
        "budget_test_exit_code" => "0",
        "budget_tests_passed" => "5",
        "budget_tests_total" => "5",
        "queue_test_exit_code" => "0",
        "queue_tests_passed" => "13",
        "queue_tests_total" => "13",
        "registered_endpoint_frames_executed_during_preflight" => "0",
        "config_sha256" => file_sha256(config_path),
        "card_sha256" => file_sha256(CARD_PATH),
        "runner_sha256" => file_sha256(RUNNER_PATH),
        "test_sha256" => isfile(TEST_PATH) ? file_sha256(TEST_PATH) : "missing",
        "budget_tool_sha256" => isfile(BUDGET_TOOL_PATH) ?
            file_sha256(BUDGET_TOOL_PATH) : "missing",
        "budget_test_sha256" => isfile(BUDGET_TEST_PATH) ?
            file_sha256(BUDGET_TEST_PATH) : "missing",
        "queue_status_sha256" => isfile(QUEUE_STATUS_PATH) ?
            file_sha256(QUEUE_STATUS_PATH) : "missing",
        "queue_lock_tool_sha256" => isfile(QUEUE_LOCK_TOOL_PATH) ?
            file_sha256(QUEUE_LOCK_TOOL_PATH) : "missing",
        "anchor_wrapper_sha256" => isfile(ANCHOR_WRAPPER_PATH) ?
            file_sha256(ANCHOR_WRAPPER_PATH) : "missing",
        "queue_wrapper_sha256" => isfile(QUEUE_WRAPPER_PATH) ?
            file_sha256(QUEUE_WRAPPER_PATH) : "missing",
        "queue_template_sha256" => isfile(QUEUE_TEMPLATE_PATH) ?
            file_sha256(QUEUE_TEMPLATE_PATH) : "missing",
        "queue_readme_template_sha256" => isfile(QUEUE_README_TEMPLATE_PATH) ?
            file_sha256(QUEUE_README_TEMPLATE_PATH) : "missing",
        "queue_test_sha256" => isfile(QUEUE_TEST_PATH) ?
            file_sha256(QUEUE_TEST_PATH) : "missing",
        "split_runner_sha256" => file_sha256(SPLIT_RUNNER_PATH),
        "legacy_runner_sha256" => file_sha256(Split.LEGACY_RUNNER_PATH),
    )
    checks = Dict(key => get(fields, key, "missing") == value
                  for (key, value) in expected)
    assertion_passed = tryparse(Int, get(
        fields, "test_assertions_passed", "missing"))
    assertion_total = tryparse(Int, get(
        fields, "test_assertions_total", "missing"))
    checks["julia_assertions_nonzero_and_complete"] =
        assertion_passed !== nothing && assertion_total !== nothing &&
        assertion_passed > 0 && assertion_passed == assertion_total
    Dict("passed" => all(values(checks)), "checks" => checks,
         "recorded" => fields, "expected" => expected)
end

function solver_keywords(split)
    pg = split["projected_gradient"]
    validation = split["validation"]
    (; maximum_updates=Int(pg["maximum_update_attempts"]),
       initial_step=Float64(pg["initial_step"]),
       maximum_backtracks=Int(pg["maximum_backtracks"]),
       finite_difference_step=Float64(validation["finite_difference_step"]),
       finite_difference_tolerance=Float64(
           validation["finite_difference_tolerance"]),
       mean_tolerance=Float64(validation["mean_offset_tolerance"]),
       box_tolerance=Float64(validation["box_tolerance"]))
end

problem_for(split, code, llr) = BridgeProblem(code, llr;
    parity_weight=Float64(split["projected_gradient"]["parity_weight"]),
    binary_weight=Float64(split["projected_gradient"]["binary_weight"]))

# ---------------------------------------------------------------------------
# Fixed assignment plan and factorial kernel
# ---------------------------------------------------------------------------

function permutation_plan(problem::BridgeProblem, rng::AbstractRNG)
    [length(incident) < 2 ? collect(1:length(incident)) :
     derangement(rng, length(incident)) for incident in problem.var_edges]
end

permutation_plan_sha256(plan) = scientific_sha256(plan)

"""Apply one fixed within-bit derangement plan to an edge array in place."""
function apply_permutation!(delta_rows, problem::BridgeProblem, plan)
    length(plan) == length(problem.var_edges) ||
        throw(ArgumentError("permutation plan has the wrong number of bits"))
    moved = 0                       # edges whose value changed
    unmoved = 0                     # edges whose value did not (duplicates, zeros)
    moved_positions = 0             # graph-edge positions changed by the plan
    distinguishable_bits = 0        # bits with at least two distinct offsets
    unchanged_distinguishable = 0   # of those, bits whose assignment did not change
    multiset_preserved = true
    values = Float64[]
    permuted = Float64[]
    for (bit, incident) in enumerate(problem.var_edges)
        degree = length(incident)
        perm = plan[bit]
        length(perm) == degree ||
            throw(ArgumentError("permutation plan degree mismatch at bit $bit"))
        sort(perm) == collect(1:degree) ||
            throw(ArgumentError("invalid permutation at bit $bit"))
        degree >= 2 || continue
        all(perm[position] != position for position in 1:degree) ||
            throw(ArgumentError("plan is not a derangement at bit $bit"))
        resize!(values, degree)
        resize!(permuted, degree)
        for (position, (check_index, slot)) in enumerate(incident)
            values[position] = delta_rows[check_index][slot]
        end
        for position in 1:degree
            permuted[position] = values[perm[position]]
            moved_positions += perm[position] != position
        end
        multiset_preserved &= sort(values) == sort(permuted)
        if !allequal(values)
            distinguishable_bits += 1
            unchanged_distinguishable += permuted == values
        end
        for (position, (check_index, slot)) in enumerate(incident)
            moved += permuted[position] != values[position]
            unmoved += permuted[position] == values[position]
            delta_rows[check_index][slot] = permuted[position]
        end
    end
    (; moved, unmoved, moved_positions, distinguishable_bits,
       unchanged_distinguishable,
       multiset_preserved)
end

function permute_offsets!(delta_rows, problem::BridgeProblem, rng::AbstractRNG)
    apply_permutation!(delta_rows, problem, permutation_plan(problem, rng))
end

function derangement(rng::AbstractRNG, degree::Int)
    degree == 2 && return [2, 1]
    degree == 3 && return rand(rng, Bool) ? [2, 3, 1] : [3, 1, 2]
    perm = collect(1:degree)
    while true
        shuffle!(rng, perm)
        all(perm[k] != k for k in 1:degree) && return perm
    end
end

function copy_edge_rows!(destination, source)
    for (destination_row, source_row) in zip(destination, source)
        copyto!(destination_row, source_row)
    end
    destination
end

function edge_difference_count(left, right)
    differences = 0
    for (left_row, right_row) in zip(left, right),
            (left_value, right_value) in zip(left_row, right_row)
        differences += left_value != right_value
    end
    differences
end

function solve_factorial_variant(problem::BridgeProblem, code,
                            initial::AbstractVector{<:Real}, mode::Symbol;
                            permutation_seed::Int=0,
                            permutation_plan_input=nothing,
                            maximum_updates::Int=30,
                            initial_step::Float64=0.2,
                            maximum_backtracks::Int=16,
                            collect_trace::Bool=true,
                            collect_diagnostics::Bool=true,
                            validate_derivatives::Bool=false,
                            finite_difference_step::Float64=1.0e-6,
                            finite_difference_tolerance::Float64=3.0e-8,
                            mean_tolerance::Float64=2.0e-12,
                            box_tolerance::Float64=2.0e-14,
                            snapshot_updates=Set{Int}())
    mode in Symbol.(ARMS) || throw(ArgumentError("unknown factorial mode $mode"))
    validate_derivatives && !collect_diagnostics && throw(ArgumentError(
        "finite-difference validation requires diagnostic collection"))
    spec = PARITY_USE_SPEC
    assignment_is_permuted = startswith(String(mode), "permuted__")
    replacement_is_refreshed = endswith(String(mode), "__refreshed")
    plan = permutation_plan_input === nothing ?
        permutation_plan(problem, MersenneTwister(permutation_seed)) :
        permutation_plan_input
    plan_sha256 = collect_trace ? permutation_plan_sha256(plan) : "not_collected"
    n = length(problem.llr)
    x = clamp.(Float64.(initial), -1.0, 1.0)
    trial = similar(x)
    raw_trial = similar(x)
    direction = similar(x)
    lower = similar(x)
    upper = similar(x)
    delta = Legacy.zero_edge_rows(problem.check_vars)
    delta_next = Legacy.zero_edge_rows(problem.check_vars)
    candidate_asbuilt = Legacy.zero_edge_rows(problem.check_vars)
    candidate_permuted = Legacy.zero_edge_rows(problem.check_vars)
    q_rows = Legacy.zero_edge_rows(problem.check_vars)
    before_workspace = Legacy.EvalWorkspace(problem)
    trial_workspace = Legacy.EvalWorkspace(problem)
    trace_rows = Dict{String,Any}[]
    snapshots = Dict{Int,Any}()
    0 in snapshot_updates && (snapshots[0] =
        (x=copy(x), delta=Legacy.copy_edge_rows(delta)))
    accepted_steps = 0
    candidate_calculations = 0
    offset_replacements = 0
    status = "steps_completed"
    all_projection_feasible = true
    all_native_projection_bounds = true
    all_refreshed_readings = true
    all_mean_constraints = true
    all_finite_differences = true
    all_offsets_fixed = true
    all_multisets_preserved = true
    permutation_moved_edges = 0
    permutation_unmoved_edges = 0
    permutation_moved_positions = 0
    permutation_distinguishable_bits = 0
    permutation_unchanged_distinguishable_bits = 0
    maximum_objective_reading_excess = 0.0
    objective_readings_outside_count = 0
    initial_loss = NaN
    last_accepted_loss = NaN

    for update in 1:maximum_updates
        before = Legacy.bridge_evaluate!(before_workspace, problem, x, delta;
            consume_offsets=true)
        update == 1 && (initial_loss = before.loss; last_accepted_loss = before.loss)
        delta_hash_before = collect_trace ? edge_sha256(delta) : "not_collected"
        x_hash_before = collect_trace ? vector_sha256(x) : "not_collected"
        nonzero_before = collect_diagnostics ?
            count(value -> !iszero(value), Legacy.flatten_edge_rows(delta)) : 0
        if collect_diagnostics
            excess = Split.maximum_reading_excess(problem, x, delta;
                use_offsets=true)
            maximum_objective_reading_excess = max(
                maximum_objective_reading_excess, excess.maximum_excess)
            objective_readings_outside_count += excess.count_outside
        end

        fd = if validate_derivatives
            Legacy.finite_difference_maximum(problem, x, delta,
                before.gradient; consume_offsets=true,
                step=finite_difference_step)
        else
            (; maximum_error=0.0, maximum_bit=0,
               all_probes_in_box=true,
               delta_sha256_before=delta_hash_before,
               delta_sha256_after=delta_hash_before)
        end
        fd_ok = !validate_derivatives ||
            (fd.maximum_error <= finite_difference_tolerance &&
             fd.delta_sha256_before == fd.delta_sha256_after)
        all_finite_differences &= fd_ok

        @inbounds for bit in eachindex(x)
            direction[bit] = -before.gradient[bit] / problem.curvature_bound[bit]
        end
        gradient_hash = collect_trace ?
            vector_sha256(before.gradient) : "not_collected"
        direction_hash = collect_trace ? vector_sha256(direction) : "not_collected"
        Legacy.scalar_intervals!(lower, upper, problem, delta;
            consume_offsets=false)
        all_native_projection_bounds &=
            all(value -> value == -1.0, lower) &&
            all(value -> value == 1.0, upper)
        lower_hash = collect_trace ? vector_sha256(lower) : "not_collected"
        upper_hash = collect_trace ? vector_sha256(upper) : "not_collected"
        for bit in eachindex(x)
            if x[bit] < lower[bit]
                lower[bit] - x[bit] <= box_tolerance || throw(ArgumentError(
                    "current scalar state is below its registered interval"))
                lower[bit] = x[bit]
            elseif x[bit] > upper[bit]
                x[bit] - upper[bit] <= box_tolerance || throw(ArgumentError(
                    "current scalar state is above its registered interval"))
                upper[bit] = x[bit]
            end
        end

        accepted = false
        accepted_step = 0.0
        accepted_loss = before.loss
        accepted_raw_hash = x_hash_before
        trial_count = 0
        all_trial_projection_feasible = true
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                raw_trial[bit] = x[bit] + step * direction[bit]
                trial[bit] = clamp(raw_trial[bit], lower[bit], upper[bit])
            end
            trial_count += 1
            trial_evaluation = Legacy.bridge_evaluate!(trial_workspace, problem,
                trial, delta; consume_offsets=true)
            projection_feasible = !collect_diagnostics ||
                Legacy.readings_in_box(problem, trial, delta;
                    consume_offsets=false, tolerance=box_tolerance)
            all_trial_projection_feasible &= projection_feasible
            if collect_diagnostics
                excess = Split.maximum_reading_excess(problem, trial, delta;
                    use_offsets=true)
                maximum_objective_reading_excess = max(
                    maximum_objective_reading_excess, excess.maximum_excess)
                objective_readings_outside_count += excess.count_outside
            end
            if Split.trial_is_acceptable(projection_feasible,
                                         trial_evaluation.loss, before.loss)
                accepted = true
                accepted_step = step
                accepted_loss = trial_evaluation.loss
                accepted_raw_hash = collect_trace ?
                    vector_sha256(raw_trial) : "not_collected"
                break
            end
        end
        all_projection_feasible &= all_trial_projection_feasible
        delta_hash_after_line_search = collect_trace ?
            edge_sha256(delta) : "not_collected"
        offsets_fixed = !collect_trace ||
            delta_hash_after_line_search == delta_hash_before
        all_offsets_fixed &= offsets_fixed
        if !accepted
            status = "line_search_stalled"
            collect_trace && push!(trace_rows, Dict{String,Any}(
                "update" => update, "accepted" => false,
                "trial_count" => trial_count,
                "objective_evaluations" => 1 + trial_count,
                "loss_before" => before.loss,
                "accepted_fixed_offset_loss" => before.loss,
                "accepted_step" => 0.0,
                "x_before_sha256" => x_hash_before,
                "x_after_sha256" => x_hash_before,
                "raw_proposal_sha256" => accepted_raw_hash,
                "lower_bound_sha256" => lower_hash,
                "upper_bound_sha256" => upper_hash,
                "delta_before_sha256" => delta_hash_before,
                "delta_after_sha256" => delta_hash_before,
                "gradient_sha256" => gradient_hash,
                "direction_sha256" => direction_hash,
                "delta_after_line_search_sha256" =>
                    delta_hash_after_line_search,
                "candidate_calculated" => false,
                "selected_candidate_changed_edges" => 0,
                "offset_replaced" => false,
                "offset_refreshed" => false,
                "offsets_fixed_during_calculation" => offsets_fixed,
                "nonzero_offsets_before" => nonzero_before,
                "nonzero_offsets_after" => nonzero_before,
                "permutation_moved_edges" => 0,
                "permutation_unmoved_edges" => 0,
                "maximum_offset_sum_error" => 0.0,
                "refreshed_readings_in_box" => true,
                "finite_difference_maximum_error" => fd.maximum_error,
                "finite_difference_maximum_bit" => fd.maximum_bit,
                "finite_difference_probes_in_box" => fd.all_probes_in_box,
                "finite_difference_passed" => fd_ok,
            ))
            break
        end

        # Every arm calculates both candidates.  Only the two selectors below
        # choose which candidate is retained and whether it replaces the
        # current retained state after the first accepted update.
        construction = Legacy.construct_offsets!(candidate_asbuilt, q_rows,
            problem, x, trial, accepted_step, before;
            tolerance=mean_tolerance, collect_diagnostics)
        copy_edge_rows!(candidate_permuted, candidate_asbuilt)
        permutation = apply_permutation!(candidate_permuted, problem, plan)
        candidate_calculations += 1
        moved = permutation.moved
        unmoved = permutation.unmoved
        permutation_moved_edges += moved
        permutation_unmoved_edges += unmoved
        permutation_moved_positions += permutation.moved_positions
        permutation_distinguishable_bits += permutation.distinguishable_bits
        permutation_unchanged_distinguishable_bits +=
            permutation.unchanged_distinguishable
        all_multisets_preserved &= permutation.multiset_preserved

        selected_candidate = assignment_is_permuted ?
            candidate_permuted : candidate_asbuilt
        selected_candidate_changed_edges = edge_difference_count(
            selected_candidate, delta)
        replace = replacement_is_refreshed || accepted_steps == 0
        if replace
            copy_edge_rows!(delta_next, selected_candidate)
            offset_replacements += 1
        else
            copy_edge_rows!(delta_next, delta)
        end
        mean_error = collect_diagnostics ? max(
            maximum_offset_sum_error(candidate_asbuilt, problem),
            maximum_offset_sum_error(candidate_permuted, problem)) : 0.0
        all_mean_constraints &= !collect_diagnostics ||
            mean_error <= mean_tolerance
        nonzero_after = collect_diagnostics ?
            count(value -> !iszero(value),
                  Legacy.flatten_edge_rows(delta_next)) : 0
        refreshed_readings = !collect_diagnostics || Legacy.readings_in_box(
            problem, trial, delta_next; consume_offsets=true,
            tolerance=box_tolerance)
        all_refreshed_readings &= refreshed_readings
        delta_hash_after = collect_trace ? edge_sha256(delta_next) : "not_collected"
        x_hash_after = collect_trace ? vector_sha256(trial) : "not_collected"
        accepted_steps += 1
        last_accepted_loss = accepted_loss
        collect_trace && push!(trace_rows, Dict{String,Any}(
            "update" => update, "accepted" => true,
            "trial_count" => trial_count,
            "objective_evaluations" => 1 + trial_count,
            "loss_before" => before.loss,
            "accepted_fixed_offset_loss" => accepted_loss,
            "accepted_step" => accepted_step,
            "x_before_sha256" => x_hash_before,
            "x_after_sha256" => x_hash_after,
            "raw_proposal_sha256" => accepted_raw_hash,
            "lower_bound_sha256" => lower_hash,
            "upper_bound_sha256" => upper_hash,
            "delta_before_sha256" => delta_hash_before,
            "delta_after_sha256" => delta_hash_after,
            "gradient_sha256" => gradient_hash,
            "direction_sha256" => direction_hash,
            "delta_after_line_search_sha256" => delta_hash_after_line_search,
            "candidate_calculated" => true,
            "selected_candidate_changed_edges" =>
                selected_candidate_changed_edges,
            "offset_replaced" => replace,
            "offset_refreshed" => replace,
            "offsets_fixed_during_calculation" => offsets_fixed,
            "nonzero_offsets_before" => nonzero_before,
            "nonzero_offsets_after" => nonzero_after,
            "permutation_moved_edges" => moved,
            "permutation_unmoved_edges" => unmoved,
            "permutation_moved_positions" => permutation.moved_positions,
            "permutation_plan_sha256" => plan_sha256,
            "asbuilt_candidate_sha256" => edge_sha256(candidate_asbuilt),
            "permuted_candidate_sha256" => edge_sha256(candidate_permuted),
            "selected_candidate_sha256" => edge_sha256(selected_candidate),
            "maximum_offset_sum_error" => mean_error,
            "refreshed_readings_in_box" => refreshed_readings,
            "finite_difference_maximum_error" => fd.maximum_error,
            "finite_difference_maximum_bit" => fd.maximum_bit,
            "finite_difference_probes_in_box" => fd.all_probes_in_box,
            "finite_difference_passed" => fd_ok,
        ))
        x, trial = trial, x
        delta, delta_next = delta_next, delta
        update in snapshot_updates && (snapshots[update] =
            (x=copy(x), delta=Legacy.copy_edge_rows(delta)))
    end

    terminal_workspace = Legacy.EvalWorkspace(problem)
    terminal = Legacy.bridge_evaluate!(terminal_workspace, problem, x, delta;
        consume_offsets=true)
    terminal_reading_excess = collect_diagnostics ?
        Split.maximum_reading_excess(problem, x, delta; use_offsets=true) :
        (; maximum_excess=0.0, count_outside=0)
    maximum_objective_reading_excess = max(maximum_objective_reading_excess,
        terminal_reading_excess.maximum_excess)
    objective_readings_outside_count += terminal_reading_excess.count_outside
    hard = BitVector(x .< 0.0)
    if collect_diagnostics
        hard == Legacy.hard_decision_independent(x) ||
            error("independent hard decision disagrees")
    end
    independent_syndrome = Legacy.syndrome_vector(problem.check_vars, hard)
    syndrome_weight = sum(independent_syndrome)
    if collect_diagnostics
        syndrome_weight == JadeJcade.ReceiverCore._syndrome_weight(code, hard) ||
            error("independent syndrome disagrees")
    end
    maximum_updates in snapshot_updates && !haskey(snapshots, maximum_updates) &&
        (snapshots[maximum_updates] =
            (x=copy(x), delta=Legacy.copy_edge_rows(delta)))
    operation_counts = Split.operation_counts(problem, trace_rows, spec)
    operation_counts["offset_refreshes"] = offset_replacements
    operation_counts["offset_candidate_calculations"] = candidate_calculations
    operation_counts["permuted_shadow_applications"] = candidate_calculations
    (; mode, spec, x=copy(x), delta=Legacy.copy_edge_rows(delta), hard,
       syndrome=independent_syndrome, syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       coded_bit_errors=count(hard),
       accepted_steps, candidate_calculations, offset_replacements,
       offset_refreshes=offset_replacements,
       requested_steps=maximum_updates, status,
       initial_loss, last_accepted_fixed_offset_loss=last_accepted_loss,
       terminal_refreshed_loss=terminal.loss,
       fractional_bits=count(value -> abs(value) < 0.999, x),
       trace=trace_rows, snapshots,
       all_projection_feasibility_checks_passed=all_projection_feasible,
       all_native_projection_bounds,
       all_refreshed_readings_in_box=all_refreshed_readings,
       all_mean_constraints_passed=all_mean_constraints,
       all_finite_differences_passed=all_finite_differences,
       all_offsets_fixed_during_calculation=all_offsets_fixed,
       all_multisets_preserved,
       permutation_moved_edges, permutation_unmoved_edges,
       permutation_moved_positions, permutation_plan_sha256=plan_sha256,
       permutation_distinguishable_bits,
       permutation_unchanged_distinguishable_bits,
       maximum_objective_reading_excess, objective_readings_outside_count,
       terminal_maximum_objective_reading_excess=
           terminal_reading_excess.maximum_excess,
       terminal_objective_readings_outside_count=
           terminal_reading_excess.count_outside,
       terminal_offset_l2_norm=norm(Legacy.flatten_edge_rows(delta)),
       operation_counts,
       logical_persistent_scalar_values=n,
       logical_persistent_edge_values=sum(length, delta))
end

function maximum_offset_sum_error(delta_rows, problem::BridgeProblem)
    worst = 0.0
    for incident in problem.var_edges
        total = 0.0
        for (check_index, slot) in incident
            total += delta_rows[check_index][slot]
        end
        worst = max(worst, abs(total))
    end
    worst
end

# Adapt a retained-kernel result to the fields this experiment records.
function retained_result(result, mode::Symbol)
    (; mode, result.spec, result.x, result.delta, result.hard, result.syndrome,
       result.syndrome_weight, result.parity_valid, result.transmitted_word_equal,
       result.coded_bit_errors, result.accepted_steps,
       candidate_calculations=result.accepted_steps,
       offset_replacements=result.accepted_steps,
       offset_refreshes=result.accepted_steps,
       result.requested_steps, result.status, result.initial_loss,
       result.last_accepted_fixed_offset_loss, result.terminal_refreshed_loss,
       result.fractional_bits, trace=retained_trace(result.trace),
       result.snapshots,
       result.all_projection_feasibility_checks_passed,
       all_native_projection_bounds=true,
       result.all_refreshed_readings_in_box,
       result.all_mean_constraints_passed,
       result.all_finite_differences_passed,
       result.all_offsets_fixed_during_calculation,
       all_multisets_preserved=true,
       permutation_moved_edges=0, permutation_unmoved_edges=0,
       permutation_moved_positions=0, permutation_plan_sha256="",
       permutation_distinguishable_bits=0,
       permutation_unchanged_distinguishable_bits=0,
       result.maximum_objective_reading_excess,
       result.objective_readings_outside_count,
       result.terminal_maximum_objective_reading_excess,
       result.terminal_objective_readings_outside_count,
       result.terminal_offset_l2_norm, result.operation_counts,
       result.logical_persistent_scalar_values,
       result.logical_persistent_edge_values)
end

function retained_trace(trace)
    rows = Dict{String,Any}[]
    for row in trace
        copied = Dict{String,Any}(row)
        copied["candidate_calculated"] = Bool(row["accepted"])
        copied["offset_replaced"] = Bool(row["accepted"])
        copied["offset_refreshed"] = Bool(row["accepted"])
        copied["permutation_moved_edges"] = 0
        copied["permutation_unmoved_edges"] = 0
        haskey(copied, "refreshed_readings_in_box") ||
            (copied["refreshed_readings_in_box"] = true)
        push!(rows, copied)
    end
    rows
end

function run_arm(arm::String, problem, code, initial, frame::Int, split, config;
                 collect_trace::Bool=true, collect_diagnostics::Bool=true,
                 snapshot_updates=Set{Int}(), permutation_plan_input=nothing)
    keywords = solver_keywords(split)
    seed = Int(config["arms"]["permutation_seed_base"]) + frame
    solve_factorial_variant(problem, code, initial, Symbol(arm);
        permutation_seed=seed, permutation_plan_input, keywords..., collect_trace,
        collect_diagnostics, validate_derivatives=collect_diagnostics,
        snapshot_updates)
end

# ---------------------------------------------------------------------------
# Rows, gates and contrasts
# ---------------------------------------------------------------------------

function frame_row(frame, arm, input, result, information_positions, esn0)
    information_errors = count(@view result.hard[information_positions])
    (; frame, arm, physical_esn0_db=esn0, noise_seed=input.noise_seed,
       coded_bit_errors=result.coded_bit_errors,
       information_bit_errors=information_errors,
       transmitted_word_equal=result.transmitted_word_equal,
       information_word_equal=information_errors == 0,
       parity_valid=result.parity_valid,
       wrong_valid_word=result.parity_valid && !result.transmitted_word_equal,
       syndrome_weight=result.syndrome_weight,
       accepted_steps=result.accepted_steps,
       candidate_calculations=result.candidate_calculations,
       offset_replacements=result.offset_replacements,
       offset_refreshes=result.offset_refreshes,
       requested_steps=result.requested_steps,
       status=result.status,
       fractional_bits=result.fractional_bits,
       initial_objective=result.initial_loss,
       last_accepted_fixed_offset_objective=result.last_accepted_fixed_offset_loss,
       terminal_refreshed_objective=result.terminal_refreshed_loss,
       all_projection_feasibility_checks_passed=
           result.all_projection_feasibility_checks_passed,
       all_native_projection_bounds=result.all_native_projection_bounds,
       all_refreshed_readings_in_box=result.all_refreshed_readings_in_box,
       all_mean_constraints_passed=result.all_mean_constraints_passed,
       all_finite_differences_passed=result.all_finite_differences_passed,
       all_offsets_fixed_during_calculation=
           result.all_offsets_fixed_during_calculation,
       all_multisets_preserved=result.all_multisets_preserved,
       permutation_moved_edges=result.permutation_moved_edges,
       permutation_unmoved_edges=result.permutation_unmoved_edges,
       permutation_moved_positions=result.permutation_moved_positions,
       permutation_plan_sha256=result.permutation_plan_sha256,
       permutation_distinguishable_bits=result.permutation_distinguishable_bits,
       permutation_unchanged_distinguishable_bits=
           result.permutation_unchanged_distinguishable_bits,
       maximum_objective_reading_excess=result.maximum_objective_reading_excess,
       objective_readings_outside_count=result.objective_readings_outside_count,
       terminal_maximum_objective_reading_excess=
           result.terminal_maximum_objective_reading_excess,
       terminal_objective_readings_outside_count=
           result.terminal_objective_readings_outside_count,
       terminal_offset_l2_norm=result.terminal_offset_l2_norm,
       hard_word_sha256=vector_sha256(result.hard),
       terminal_scalar_sha256=vector_sha256(result.x),
       terminal_offset_sha256=edge_sha256(result.delta),
       received_sha256=input.identities.received_sha256,
       clipped_llr_sha256=input.identities.clipped_llr_sha256,
       logical_persistent_scalar_values=result.logical_persistent_scalar_values,
       logical_persistent_edge_values=result.logical_persistent_edge_values,
       objective_and_gradient_evaluations=
           result.operation_counts["objective_and_gradient_evaluations"])
end

function iteration_rows(frame, arm, result)
    rows = NamedTuple[]
    for row in result.trace
        push!(rows, (; frame, arm,
            update=Int(row["update"]), accepted=Bool(row["accepted"]),
            trial_count=Int(row["trial_count"]),
            objective_evaluations=Int(row["objective_evaluations"]),
            loss_before=Float64(row["loss_before"]),
            accepted_fixed_offset_loss=Float64(row["accepted_fixed_offset_loss"]),
            accepted_step=Float64(row["accepted_step"]),
            candidate_calculated=Bool(get(row, "candidate_calculated", false)),
            selected_candidate_changed_edges=Int(get(
                row, "selected_candidate_changed_edges", 0)),
            offset_replaced=Bool(get(row, "offset_replaced", false)),
            offset_refreshed=Bool(row["offset_refreshed"]),
            offsets_fixed_during_calculation=
                Bool(row["offsets_fixed_during_calculation"]),
            nonzero_offsets_before=Int(row["nonzero_offsets_before"]),
            nonzero_offsets_after=Int(row["nonzero_offsets_after"]),
            permutation_moved_edges=Int(row["permutation_moved_edges"]),
            permutation_unmoved_edges=Int(row["permutation_unmoved_edges"]),
            permutation_moved_positions=Int(get(
                row, "permutation_moved_positions", 0)),
            permutation_plan_sha256=String(get(
                row, "permutation_plan_sha256", "")),
            asbuilt_candidate_sha256=String(get(
                row, "asbuilt_candidate_sha256", "")),
            permuted_candidate_sha256=String(get(
                row, "permuted_candidate_sha256", "")),
            selected_candidate_sha256=String(get(
                row, "selected_candidate_sha256", "")),
            maximum_offset_sum_error=Float64(row["maximum_offset_sum_error"]),
            refreshed_readings_in_box=Bool(row["refreshed_readings_in_box"]),
            finite_difference_maximum_error=Float64(get(
                row, "finite_difference_maximum_error", 0.0)),
            finite_difference_maximum_bit=Int(get(
                row, "finite_difference_maximum_bit", 0)),
            finite_difference_probes_in_box=Bool(get(
                row, "finite_difference_probes_in_box", true)),
            finite_difference_passed=Bool(get(
                row, "finite_difference_passed", true)),
            x_before_sha256=String(row["x_before_sha256"]),
            x_after_sha256=String(row["x_after_sha256"]),
            raw_proposal_sha256=String(row["raw_proposal_sha256"]),
            lower_bound_sha256=String(row["lower_bound_sha256"]),
            upper_bound_sha256=String(row["upper_bound_sha256"]),
            gradient_sha256=String(row["gradient_sha256"]),
            direction_sha256=String(row["direction_sha256"]),
            delta_before_sha256=String(row["delta_before_sha256"]),
            delta_after_line_search_sha256=String(
                row["delta_after_line_search_sha256"]),
            delta_after_sha256=String(row["delta_after_sha256"])))
    end
    rows
end

trace_value(result, update::Int, key::String) =
    (index = findfirst(row -> Int(row["update"]) == update, result.trace);
     index === nothing ? nothing : result.trace[index][key])

function per_bit_sorted_offsets(delta_rows, problem)
    [sort([delta_rows[check_index][slot] for (check_index, slot) in incident])
     for incident in problem.var_edges]
end

const PRE_ADOPTION_TRACE_KEYS = (
    "update", "accepted", "trial_count", "objective_evaluations",
    "loss_before", "accepted_fixed_offset_loss", "accepted_step",
    "x_before_sha256", "x_after_sha256", "raw_proposal_sha256",
    "lower_bound_sha256", "upper_bound_sha256", "delta_before_sha256",
    "gradient_sha256", "direction_sha256", "delta_after_line_search_sha256",
    "candidate_calculated", "asbuilt_candidate_sha256",
    "permuted_candidate_sha256")

trace_at(result, update::Int) = begin
    index = findfirst(row -> Int(row["update"]) == update, result.trace)
    index === nothing ? nothing : result.trace[index]
end

function trace_fields_equal(results, update::Int, keys=PRE_ADOPTION_TRACE_KEYS)
    rows = [trace_at(result, update) for result in results]
    all(row -> row !== nothing, rows) || return false
    signatures = [Tuple(get(row, key, nothing) for key in keys) for row in rows]
    allequal(signatures)
end

function selector_mechanics_pass(result, assignment::Symbol, replacement::Symbol)
    accepted_index = 0
    for row in result.trace
        accepted = Bool(row["accepted"])
        if !accepted
            Bool(get(row, "candidate_calculated", false)) && return false
            Bool(get(row, "offset_replaced", false)) && return false
            row["delta_after_sha256"] == row["delta_before_sha256"] || return false
            continue
        end
        accepted_index += 1
        Bool(get(row, "candidate_calculated", false)) || return false
        selected = String(get(row, "selected_candidate_sha256", ""))
        expected = assignment === :permuted ?
            String(get(row, "permuted_candidate_sha256", "")) :
            String(get(row, "asbuilt_candidate_sha256", ""))
        !isempty(expected) && selected == expected || return false
        should_replace = replacement === :refreshed || accepted_index == 1
        Bool(get(row, "offset_replaced", false)) == should_replace || return false
        if should_replace
            row["delta_after_sha256"] == selected || return false
        else
            row["delta_after_sha256"] == row["delta_before_sha256"] || return false
        end
    end
    true
end

"""Prove that the replacement selector creates the registered update-2 split."""
function replacement_manipulation_pass(refreshed, frozen)
    refreshed_row = trace_at(refreshed, 2)
    frozen_row = trace_at(frozen, 2)
    refreshed_row === nothing && return false
    frozen_row === nothing && return false
    Bool(refreshed_row["accepted"]) || return false
    Bool(frozen_row["accepted"]) || return false

    selected_refreshed = String(get(
        refreshed_row, "selected_candidate_sha256", ""))
    selected_frozen = String(get(frozen_row, "selected_candidate_sha256", ""))
    !isempty(selected_refreshed) || return false
    selected_refreshed == selected_frozen || return false

    changed_refreshed = Int(get(
        refreshed_row, "selected_candidate_changed_edges", 0))
    changed_frozen = Int(get(frozen_row, "selected_candidate_changed_edges", 0))
    changed_refreshed > 0 || return false
    changed_refreshed == changed_frozen || return false

    Bool(refreshed_row["offset_replaced"]) || return false
    !Bool(frozen_row["offset_replaced"]) || return false
    refreshed_row["delta_after_sha256"] == selected_refreshed || return false
    frozen_row["delta_after_sha256"] ==
        frozen_row["delta_before_sha256"] || return false
    refreshed_row["delta_before_sha256"] ==
        frozen_row["delta_before_sha256"] || return false
    refreshed_row["delta_after_sha256"] !=
        frozen_row["delta_after_sha256"] || return false
    true
end

"""Prove that the assignment selector creates the registered update-1 split."""
function assignment_manipulation_pass(asbuilt_refreshed, permuted_refreshed,
                                      asbuilt_frozen, permuted_frozen)
    results = (asbuilt_refreshed, permuted_refreshed,
               asbuilt_frozen, permuted_frozen)
    rows = [trace_at(result, 1) for result in results]
    all(row -> row !== nothing && Bool(row["accepted"]), rows) || return false

    asbuilt_hashes = [String(get(row, "asbuilt_candidate_sha256", ""))
                      for row in rows]
    permuted_hashes = [String(get(row, "permuted_candidate_sha256", ""))
                       for row in rows]
    all(hash -> !isempty(hash), asbuilt_hashes) || return false
    all(hash -> !isempty(hash), permuted_hashes) || return false
    allequal(asbuilt_hashes) || return false
    allequal(permuted_hashes) || return false
    first(asbuilt_hashes) != first(permuted_hashes) || return false
    all(Int(get(row, "permutation_moved_edges", 0)) > 0 for row in rows) ||
        return false

    asbuilt_rows = (rows[1], rows[3])
    permuted_rows = (rows[2], rows[4])
    all(row -> row["selected_candidate_sha256"] == first(asbuilt_hashes) &&
               row["delta_after_sha256"] == first(asbuilt_hashes),
        asbuilt_rows) || return false
    all(row -> row["selected_candidate_sha256"] == first(permuted_hashes) &&
               row["delta_after_sha256"] == first(permuted_hashes),
        permuted_rows) || return false
    allequal([row["delta_after_sha256"] for row in asbuilt_rows]) || return false
    allequal([row["delta_after_sha256"] for row in permuted_rows]) || return false
    first(asbuilt_rows)["delta_after_sha256"] !=
        first(permuted_rows)["delta_after_sha256"] || return false
    true
end

"""Per-frame correctness gates for the two-by-two selector design."""
function frame_gates(results, problem)
    asbuilt_refreshed = results["asbuilt__refreshed"]
    permuted_refreshed = results["permuted__refreshed"]
    asbuilt_frozen = results["asbuilt__frozen"]
    permuted_frozen = results["permuted__frozen"]
    arms = (asbuilt_refreshed, permuted_refreshed,
            asbuilt_frozen, permuted_frozen)
    x1 = [trace_value(result, 1, "x_after_sha256") for result in arms]
    x2_asbuilt = [trace_value(result, 2, "x_after_sha256")
                  for result in (asbuilt_refreshed, asbuilt_frozen)]
    x2_permuted = [trace_value(result, 2, "x_after_sha256")
                   for result in (permuted_refreshed, permuted_frozen)]
    asbuilt_delta1 = [trace_value(result, 1, "delta_after_sha256")
                      for result in (asbuilt_refreshed, asbuilt_frozen)]
    permuted_delta1 = [trace_value(result, 1, "delta_after_sha256")
                       for result in (permuted_refreshed, permuted_frozen)]
    frozen_deltas = [[String(row["delta_after_sha256"])
                      for row in result.trace if Bool(row["accepted"])]
                     for result in (asbuilt_frozen, permuted_frozen)]
    permuted_multiset = all(haskey(result.snapshots, 1)
                            for result in (asbuilt_refreshed,
                                           permuted_refreshed)) &&
        per_bit_sorted_offsets(permuted_refreshed.snapshots[1].delta, problem) ==
        per_bit_sorted_offsets(asbuilt_refreshed.snapshots[1].delta, problem)
    edge_count = sum(length, problem.var_edges)
    Dict{String,Bool}(
        "all_arms_equal_before_update_1_adoption" =>
            trace_fields_equal(arms, 1),
        "all_arms_scalar_equal_through_update_1" =>
            all(!isnothing, x1) && allequal(x1),
        "asbuilt_equal_before_update_2_adoption" =>
            trace_fields_equal((asbuilt_refreshed, asbuilt_frozen), 2),
        "permuted_equal_before_update_2_adoption" =>
            trace_fields_equal((permuted_refreshed, permuted_frozen), 2),
        "asbuilt_refreshed_and_frozen_scalar_equal_through_update_2" =>
            all(!isnothing, x2_asbuilt) && allequal(x2_asbuilt),
        "permuted_refreshed_and_frozen_scalar_equal_through_update_2" =>
            all(!isnothing, x2_permuted) && allequal(x2_permuted),
        "asbuilt_first_adoption_equal" =>
            all(!isnothing, asbuilt_delta1) && allequal(asbuilt_delta1),
        "permuted_first_adoption_equal" =>
            all(!isnothing, permuted_delta1) && allequal(permuted_delta1),
        "same_fixed_permutation_plan" =>
            allequal([result.permutation_plan_sha256 for result in arms]),
        "permuted_multiset_equal_after_update_1" =>
            permuted_multiset && all(result.all_multisets_preserved
                                     for result in arms),
        "every_edge_position_deranged" =>
            all(result.accepted_steps == 0 ||
                result.permutation_moved_positions ==
                    result.candidate_calculations * edge_count for result in arms),
        "permuted_assignment_changed_at_every_distinguishable_bit" =>
            all(result.permutation_distinguishable_bits > 0 &&
                result.permutation_unchanged_distinguishable_bits == 0
                for result in arms),
        "update1_assignment_manipulation_active" =>
            assignment_manipulation_pass(
                asbuilt_refreshed, permuted_refreshed,
                asbuilt_frozen, permuted_frozen),
        "candidate_calculated_after_every_accepted_update" =>
            all(result.candidate_calculations == result.accepted_steps
                for result in arms),
        "refreshed_replaces_after_every_accepted_update" =>
            all(result.offset_replacements == result.accepted_steps
                for result in (asbuilt_refreshed, permuted_refreshed)),
        "frozen_replaces_once" =>
            all(result.offset_replacements == min(1, result.accepted_steps)
                for result in (asbuilt_frozen, permuted_frozen)),
        "frozen_offsets_constant_after_first_adoption" =>
            all(!isempty(values) && allequal(values) for values in frozen_deltas),
        "asbuilt_refreshed_selector_hashes" =>
            selector_mechanics_pass(asbuilt_refreshed, :asbuilt, :refreshed),
        "permuted_refreshed_selector_hashes" =>
            selector_mechanics_pass(permuted_refreshed, :permuted, :refreshed),
        "asbuilt_frozen_selector_hashes" =>
            selector_mechanics_pass(asbuilt_frozen, :asbuilt, :frozen),
        "permuted_frozen_selector_hashes" =>
            selector_mechanics_pass(permuted_frozen, :permuted, :frozen),
        "asbuilt_replacement_manipulation_active" =>
            replacement_manipulation_pass(asbuilt_refreshed, asbuilt_frozen),
        "permuted_replacement_manipulation_active" =>
            replacement_manipulation_pass(permuted_refreshed, permuted_frozen),
        "projection_feasible_all_arms" =>
            all(result.all_projection_feasibility_checks_passed for result in arms),
        "native_projection_bounds_all_arms" =>
            all(result.all_native_projection_bounds for result in arms),
        "mean_constraints_all_candidates" =>
            all(result.all_mean_constraints_passed for result in arms),
        "fixed_offset_partial_derivatives_all_arms" =>
            all(result.all_finite_differences_passed for result in arms),
        "offsets_fixed_during_calculation_all_arms" =>
            all(result.all_offsets_fixed_during_calculation for result in arms),
    )
end

function paired_counts(frame_rows, field::Symbol, treatment, reference)
    counts = Split.paired_endpoint_counts(frame_rows, field, treatment, reference)
    grouped = Split.rows_by_frame_and_arm(frame_rows, field,
                                          [treatment, reference])
    counts["treatment_only_frames"] = sort!([frame for (frame, outcomes) in grouped
        if Bool(outcomes[treatment]) && !Bool(outcomes[reference])])
    counts["reference_only_frames"] = sort!([frame for (frame, outcomes) in grouped
        if !Bool(outcomes[treatment]) && Bool(outcomes[reference])])
    counts["both_success_frames"] = sort!([frame for (frame, outcomes) in grouped
        if Bool(outcomes[treatment]) && Bool(outcomes[reference])])
    counts["both_failure_frames"] = sort!([frame for (frame, outcomes) in grouped
        if !Bool(outcomes[treatment]) && !Bool(outcomes[reference])])
    counts
end

function contrast_table(frame_rows)
    table = Dict{String,Any}()
    for endpoint in ENDPOINTS
        contrasts = Dict{String,Any}()
        for contrast in CONTRASTS
            contrasts[contrast.id] = paired_counts(frame_rows, Symbol(endpoint),
                contrast.treatment, contrast.reference)
        end
        table[endpoint] = Dict("contrasts" => contrasts)
    end
    table
end

function factorial_interaction(frame_rows, field::Symbol)
    grouped = Split.rows_by_frame_and_arm(frame_rows, field, collect(ARMS))
    score_counts = Dict(string(score) => 0 for score in -2:2)
    total_score = 0
    for outcomes in values(grouped)
        score = Int(outcomes["asbuilt__refreshed"]) -
                Int(outcomes["permuted__refreshed"]) -
                Int(outcomes["asbuilt__frozen"]) +
                Int(outcomes["permuted__frozen"])
        score_counts[string(score)] += 1
        total_score += score
    end
    Dict{String,Any}(
        "definition" => "asbuilt__refreshed - permuted__refreshed - asbuilt__frozen + permuted__frozen",
        "frames" => length(grouped),
        "score_sum" => total_score,
        "risk_difference_interaction" => total_score / length(grouped),
        "frame_score_counts" => score_counts,
    )
end

function add_interaction_bootstrap!(interaction, frame_rows, field::Symbol;
                                    seed::Int, resamples::Int,
                                    confidence_level::Float64)
    grouped = Split.rows_by_frame_and_arm(frame_rows, field, collect(ARMS))
    scores = Int[]
    for frame in sort!(collect(keys(grouped)))
        outcomes = grouped[frame]
        push!(scores, Int(outcomes["asbuilt__refreshed"]) -
                      Int(outcomes["permuted__refreshed"]) -
                      Int(outcomes["asbuilt__frozen"]) +
                      Int(outcomes["permuted__frozen"]))
    end
    rng = MersenneTwister(seed)
    draws = Vector{Float64}(undef, resamples)
    for repetition in eachindex(draws)
        total = 0
        for _ in eachindex(scores)
            total += scores[rand(rng, eachindex(scores))]
        end
        draws[repetition] = total / length(scores)
    end
    sort!(draws)
    alpha = 1.0 - confidence_level
    lower_index = clamp(floor(Int, alpha / 2 * resamples) + 1, 1, resamples)
    upper_index = clamp(ceil(Int, (1.0 - alpha / 2) * resamples), 1, resamples)
    interaction["bootstrap"] = Dict(
        "method" => "paired-case percentile bootstrap of complete four-arm outcome vectors",
        "seed" => seed,
        "resamples" => resamples,
        "confidence_level" => confidence_level,
        "lower" => draws[lower_index],
        "upper" => draws[upper_index],
    )
    interaction
end

function add_inference!(table, confidence_level::Float64)
    pvalues = Dict{String,Float64}()
    for endpoint in ENDPOINTS, contrast in CONTRASTS
        result = table[endpoint]["contrasts"][contrast.id]
        legacy = Split.legacy_count_keys(result)
        pvalue = Legacy.mcnemar_exact_pvalue(legacy)
        result["mcnemar_exact_two_sided_pvalue"] = pvalue
        result["newcombe_interval"] =
            Legacy.newcombe_paired_interval(legacy; confidence_level)
        pvalues["$endpoint::$(contrast.id)"] = pvalue
    end
    for (key, value) in Legacy.holm_adjust(pvalues)
        endpoint, contrast = split(key, "::"; limit=2)
        table[endpoint]["contrasts"][contrast]["holm_adjusted_pvalue"] = value
    end
    table
end

function add_refresh_equivalence!(table, margin::Float64)
    margin > 0.0 || throw(ArgumentError(
        "refresh equivalence margin must be positive"))
    criterion = "simultaneous Newcombe interval lies wholly inside [-margin,+margin]"
    for endpoint in ENDPOINTS, contrast_id in REFRESH_CONTRASTS
        result = table[endpoint]["contrasts"][contrast_id]
        interval = get(result, "newcombe_interval", nothing)
        interval === nothing && throw(ArgumentError(
            "refresh equivalence requires a Newcombe interval"))
        lower = Float64(interval["lower"])
        upper = Float64(interval["upper"])
        isfinite(lower) && isfinite(upper) || throw(ArgumentError(
            "refresh equivalence requires finite interval bounds"))
        result["refresh_equivalence_margin"] = margin
        result["refresh_equivalence_criterion"] = criterion
        result["refresh_equivalent_within_margin"] =
            lower >= -margin && upper <= margin
    end
    table
end

function refresh_equivalence_summary(table, margin::Float64;
                                     evaluated::Bool)
    criterion = "simultaneous Newcombe interval lies wholly inside [-margin,+margin]"
    decisions = Dict{String,Any}()
    if evaluated
        for endpoint in ENDPOINTS
            endpoint_decisions = Dict{String,Bool}()
            for contrast_id in REFRESH_CONTRASTS
                result = table[endpoint]["contrasts"][contrast_id]
                endpoint_decisions[contrast_id] = Bool(
                    result["refresh_equivalent_within_margin"])
            end
            decisions[endpoint] = endpoint_decisions
        end
    end
    Dict{String,Any}(
        "evaluated" => evaluated,
        "margin" => margin,
        "criterion" => criterion,
        "nonsignificance_alone_is_not_equivalence" => true,
        "decisions" => decisions,
    )
end

function refresh_equivalence_aggregate_fields(result, contrast_id, stage)
    applicable = contrast_id in REFRESH_CONTRASTS
    evaluated = stage === :transfer && applicable
    status = !applicable ? "not_applicable" :
             evaluated ? "evaluated" : "not_evaluated"
    (; applicable, evaluated, status,
       margin=evaluated ? result["refresh_equivalence_margin"] : missing,
       decision=evaluated ?
           result["refresh_equivalent_within_margin"] : missing,
       criterion=evaluated ? result["refresh_equivalence_criterion"] : "")
end

function arm_success_counts(frame_rows)
    counts = Dict{String,Any}()
    for arm in ARMS
        rows = [row for row in frame_rows if row.arm == arm]
        counts[arm] = Dict(
            "frames" => length(rows),
            "transmitted_word_equal" => count(r -> r.transmitted_word_equal, rows),
            "parity_valid" => count(r -> r.parity_valid, rows),
            "information_word_equal" => count(r -> r.information_word_equal, rows),
            "wrong_valid_word" => count(r -> r.wrong_valid_word, rows),
            "mean_coded_bit_errors" => isempty(rows) ? 0.0 :
                mean(r.coded_bit_errors for r in rows),
            "mean_information_bit_errors" => isempty(rows) ? 0.0 :
                mean(r.information_bit_errors for r in rows),
            "mean_accepted_steps" => isempty(rows) ? 0.0 :
                mean(r.accepted_steps for r in rows),
            "mean_candidate_calculations" => isempty(rows) ? 0.0 :
                mean(r.candidate_calculations for r in rows),
            "mean_offset_replacements" => isempty(rows) ? 0.0 :
                mean(r.offset_replacements for r in rows),
        )
    end
    counts
end

parse_csv_bool(value) = lowercase(String(value)) == "true"

function attribution_accounting(config, frame_rows)
    reference_config = config["attribution_reference"]
    method = String(reference_config["method"])
    native_rows = [row for row in parse_simple_csv(
        attribution_reference_path(config)) if row.method == method]
    native_pairs = [(parse(Int, row.frame), row) for row in native_rows]
    native = Dict(native_pairs)
    expected_frames = Int(reference_config["expected_frames"])
    baseline_successes = count(row -> parse_csv_bool(
        row.transmitted_word_equal), native_rows)
    expected_frame_set = Set(stage_frames(config, :attribution))
    native_frame_set = Set(first.(native_pairs))
    identities_equal = length(native) == expected_frames &&
        length(native_pairs) == expected_frames &&
        native_frame_set == expected_frame_set
    for row in frame_rows
        old = get(native, row.frame, nothing)
        identities_equal &= old !== nothing &&
            old.received_sha256 == row.received_sha256 &&
            old.clipped_llr_sha256 == row.clipped_llr_sha256
    end
    accounting = Dict{String,Any}()
    for arm in ARMS
        rows = sort([row for row in frame_rows if row.arm == arm]; by=row -> row.frame)
        recovered = Int[]
        lost = Int[]
        unresolved = Int[]
        retained_success = Int[]
        for row in rows
            baseline = parse_csv_bool(native[row.frame].transmitted_word_equal)
            current = row.transmitted_word_equal
            !baseline && current && push!(recovered, row.frame)
            baseline && !current && push!(lost, row.frame)
            !baseline && !current && push!(unresolved, row.frame)
            baseline && current && push!(retained_success, row.frame)
        end
        accounting[arm] = Dict(
            "newly_recovered_native_gd_failures" => length(recovered),
            "native_gd_successes_lost" => length(lost),
            "net_change" => length(recovered) - length(lost),
            "original_failures_unresolved" => length(unresolved),
            "native_gd_successes_retained" => length(retained_success),
            "recovered_frames" => recovered,
            "lost_frames" => lost,
            "unresolved_frames" => unresolved,
            "retained_success_frames" => retained_success,
            "current_successes" => count(row -> row.transmitted_word_equal, rows),
        )
    end
    checks = Dict{String,Bool}(
        "reference_frame_count" => length(native) == expected_frames,
        "reference_success_count" => baseline_successes ==
            Int(reference_config["expected_successes"]),
        "reference_failure_count" => expected_frames - baseline_successes ==
            Int(reference_config["expected_failures"]),
        "reference_inputs_equal" => identities_equal,
    )
    for arm in ARMS
        record = accounting[arm]
        checks["$arm rows_exact"] =
            length([row for row in frame_rows if row.arm == arm]) == expected_frames &&
            Set(row.frame for row in frame_rows if row.arm == arm) == expected_frame_set
        checks["$arm native_failures_partition"] =
            record["newly_recovered_native_gd_failures"] +
            record["original_failures_unresolved"] ==
            Int(reference_config["expected_failures"])
        checks["$arm native_successes_partition"] =
            record["native_gd_successes_lost"] +
            record["native_gd_successes_retained"] ==
            Int(reference_config["expected_successes"])
        checks["$arm net_identity"] = record["net_change"] ==
            record["current_successes"] - Int(reference_config["expected_successes"])
    end
    (; accounting, checks)
end

# ---------------------------------------------------------------------------
# Freeze
# ---------------------------------------------------------------------------

function queue_package_governance_sources()
    Dict(
        "derive_budget.py" => BUDGET_TOOL_PATH,
        "lock_queue_package.py" => QUEUE_LOCK_TOOL_PATH,
        "run_anchor_once.sh" => ANCHOR_WRAPPER_PATH,
        "run_queue.sh" => QUEUE_WRAPPER_PATH,
        "status_report.py" => QUEUE_STATUS_PATH,
    )
end

function authored_source_paths(config_path::AbstractString;
                               preflight_path::AbstractString)
    Dict("config.toml" => abspath(config_path),
         "experiment_card.md" => CARD_PATH,
         "preflight_validation.md" => abspath(preflight_path),
         "queue_tools/derive_budget.py" => BUDGET_TOOL_PATH,
         "queue_tools/test_derive_budget.py" => BUDGET_TEST_PATH,
         "queue_tools/status_report.py" => QUEUE_STATUS_PATH,
         "queue_tools/lock_queue_package.py" => QUEUE_LOCK_TOOL_PATH,
         "queue_tools/run_anchor_once.sh" => ANCHOR_WRAPPER_PATH,
         "queue_tools/run_queue.sh" => QUEUE_WRAPPER_PATH,
         "queue_tools/queue_template.toml" => QUEUE_TEMPLATE_PATH,
         "queue_tools/QUEUE_PACKAGE_README.template.md" =>
             QUEUE_README_TEMPLATE_PATH,
         "queue_tools/test_queue_tools.py" => QUEUE_TEST_PATH,
         "rq2_gd_parity_assignment_refresh_001.jl" => RUNNER_PATH,
         "test_rq2_gd_parity_assignment_refresh_001.jl" => TEST_PATH)
end

function canonical_queue_relative(value)
    relative = String(value)
    isempty(relative) && return nothing
    isabspath(relative) && return nothing
    parts = splitpath(relative)
    any(part -> part == "." || part == "..", parts) && return nothing
    normpath(relative) == relative || return nothing
    relative
end

function resolve_queue_config_path(queue_root::AbstractString, queue_config,
                                   key::AbstractString)
    paths = get(queue_config, "paths", Dict{String,Any}())
    haskey(paths, key) || return nothing
    candidate = String(paths[key])
    if key == "budget_transfer" || key == "budget_attribution"
        relative = canonical_queue_relative(candidate)
        return relative === nothing ? nothing : normpath(joinpath(
            queue_root, relative))
    end
    isabspath(candidate) && return normpath(candidate)
    repository = String(get(paths, "repository_root", ""))
    isabspath(repository) || return nothing
    normpath(joinpath(repository, candidate))
end

function freeze_source_paths(config, config_path;
                             preflight_path::AbstractString)
    paths = authored_source_paths(config_path; preflight_path)
    paths["vendor/rq2_gd_offset_split_001.jl"] = SPLIT_RUNNER_PATH
    paths["vendor/test_rq2_gd_offset_split_001.jl"] = SPLIT_TEST_PATH
    paths["vendor/rq2_gd_state_use_001.jl"] = Split.LEGACY_RUNNER_PATH
    paths["vendor/split_config.toml"] = split_config_path(config)
    paths["retained/split_input_freeze.csv"] =
        retained_input_path(config)
    paths["retained/native_gap_frames.csv"] =
        attribution_reference_path(config)
    prerequisite = prerequisite_result_path(config)
    paths["prerequisite/COMPLETED.toml"] =
        joinpath(prerequisite, "COMPLETED.toml")
    paths["prerequisite/manifest.toml"] =
        joinpath(prerequisite, "manifest.toml")
    paths["prerequisite/MANIFEST.sha256"] =
        joinpath(prerequisite, "MANIFEST.sha256")
    paths["prerequisite/science.json"] = joinpath(prerequisite, "science.json")
    paths["prerequisite/aggregate.csv"] = joinpath(prerequisite, "aggregate.csv")
    prerequisite_manifest = joinpath(prerequisite, "MANIFEST.sha256")
    if isfile(prerequisite_manifest)
        for line in readlines(prerequisite_manifest)
            isempty(line) && continue
            fields = split(line, "  "; limit=2)
            length(fields) == 2 || throw(ArgumentError(
                "malformed prerequisite checksum row: $line"))
            relative = fields[2]
            (isabspath(relative) || ".." in splitpath(relative)) &&
                throw(ArgumentError(
                    "unsafe prerequisite checksum path: $relative"))
            paths["prerequisite_result/" * relative] =
                joinpath(prerequisite, relative)
        end
    end
    split_config = load_split_config(config)
    for (label, path) in Split.freeze_source_paths(
            split_config, SPLIT_CONFIG_PATH)
        paths["capsule/" * label] = path
    end
    paths
end

function input_rows(config, split, native, code)
    rows = NamedTuple[]
    for (set_name, frames) in (("anchor", stage_frames(config, :anchor)),
                               ("transfer", stage_frames(config, :transfer)),
                               ("attribution", stage_frames(config, :attribution)))
        for frame in frames
            input = Legacy.generate_input(split, native, code, frame)
            push!(rows, (; set=set_name, frame, noise_seed=input.noise_seed,
                physical_esn0_db=Float64(split["channel"]["physical_esn0_db"]),
                noise_variance=input.variance,
                noise_variance_float64_hex=Legacy.float64_hex(input.variance),
                graph_sha256=input.identities.graph_sha256,
                transmitted_word_sha256=input.identities.transmitted_word_sha256,
                transmitted_symbols_sha256=
                    input.identities.transmitted_symbols_sha256,
                unit_noise_sha256=input.identities.unit_noise_sha256,
                received_sha256=input.identities.received_sha256,
                raw_llr_sha256=input.identities.raw_llr_sha256,
                clipped_llr_sha256=input.identities.clipped_llr_sha256))
        end
    end
    rows
end

function retained_rows_match(config, rows)
    retained = Dict(parse(Int, row.frame) => row
        for row in parse_simple_csv(retained_input_path(config)))
    comparison_fields = (:noise_seed, :graph_sha256,
        :transmitted_word_sha256, :transmitted_symbols_sha256,
        :unit_noise_sha256, :received_sha256, :raw_llr_sha256,
        :clipped_llr_sha256)
    for row in rows
        row.set == "transfer" && continue
        haskey(retained, row.frame) || return false
        old = retained[row.frame]
        for field in comparison_fields
            string(getproperty(row, field)) == getproperty(old, field) ||
                return false
        end
    end
    true
end

function environment_record(split)
    Dict("julia_version" => string(VERSION),
         "julia_threads" => Threads.nthreads(),
         "blas_threads" => BLAS.get_num_threads(),
         "cpu" => Sys.CPU_NAME,
         "sp_head" => git_output(HERE, "rev-parse", "HEAD"),
         "sp_branch" => git_output(HERE, "branch", "--show-current"),
         "sp_status" => git_output(HERE, "status", "--porcelain=v1",
                                   "--untracked-files=all"),
         "jade_root" => String(split["sources"]["jade_project_repo"]),
         "jade_head" => git_output(String(split["sources"]["jade_project_repo"]),
                                   "rev-parse", "HEAD"))
end

function freeze_inputs(output::AbstractString; config_path=DEFAULT_CONFIG,
                       preflight_path::AbstractString,
                       command::AbstractString="freeze")
    output = abspath(output)
    preflight_path = abspath(preflight_path)
    ispath(output) && throw(ArgumentError("freeze output already exists: $output"))
    config = load_config(config_path)
    gate = source_gate(config)
    gate["passed"] || throw(ArgumentError("source gate failed: $(gate["checks"])"))
    preflight = preflight_gate(config_path; preflight_path)
    preflight["passed"] || throw(ArgumentError(
        "locked preflight record does not match the authored sources"))
    prerequisite = prerequisite_gate(config)
    prerequisite["passed"] || throw(ArgumentError(
        "offset-split v3 prerequisite failed: $(prerequisite["checks"])"))
    split = load_split_config(config)
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = Legacy.make_code(split, native)
    rows = input_rows(config, split, native, generated.code)
    mkpath(dirname(output)); mkdir(output)
    input_path = joinpath(output, "input_freeze.csv")
    write_csv(input_path, rows, propertynames(first(rows)))
    retained_rows_equal = retained_rows_match(config, rows)
    retained_rows_equal || throw(ArgumentError(
        "anchor or attribution input differs from the retained split freeze"))
    source_directory = joinpath(output, "source"); mkdir(source_directory)
    records = Legacy.archive_sources(source_directory,
        freeze_source_paths(config, config_path; preflight_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["freeze_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "created_utc" => string(now(UTC)), "command" => String(command),
        "configuration_sha256" => file_sha256(config_path),
        "input_freeze_sha256" => file_sha256(input_path),
        "anchor_and_attribution_rows_equal_retained_split" => retained_rows_equal,
        "input_row_count" => length(rows),
        "graph_sha256" => Legacy.graph_sha256(generated.code.check_vars),
        "environment" => environment_record(split),
        "source_gate" => gate, "preflight_gate" => preflight,
        "prerequisite_gate" => prerequisite,
        "sources" => records)
    open(joinpath(output, "freeze_manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    written = Legacy.write_checksum_manifest(output)
    Dict("output" => output, "input_rows" => length(rows),
         "input_freeze_sha256" => file_sha256(input_path),
         "checksum_entries" => length(written.entries))
end

function regular_unlinked_file(path::AbstractString)
    absolute = abspath(path)
    isfile(absolute) || return false
    islink(absolute) && return false
    try
        realpath(absolute) == absolute
    catch
        false
    end
end

function frozen_archive_path(freeze::AbstractString, value)
    relative = try
        String(value)
    catch
        return nothing
    end
    isempty(relative) && return nothing
    isabspath(relative) && return nothing
    normpath(relative) == relative || return nothing
    any(part -> part == "." || part == "..", splitpath(relative)) &&
        return nothing
    root = abspath(freeze)
    candidate = normpath(joinpath(root, relative))
    inside = relpath(candidate, root)
    any(==(".."), splitpath(inside)) && return nothing
    candidate
end

function validate_frozen_preflight_binding(config_path::AbstractString,
                                           freeze::AbstractString, manifest)
    checks = Dict{String,Bool}()
    raw_sources = get(manifest, "sources", Any[])
    checks["source_table"] = raw_sources isa AbstractVector &&
        all(record -> record isa AbstractDict, raw_sources)
    sources = checks["source_table"] ? raw_sources : Any[]
    matches = [record for record in sources
               if get(record, "label", nothing) == "preflight_validation.md"]
    checks["one_source_record"] = length(matches) == 1
    if !checks["one_source_record"]
        return Dict("passed" => false, "checks" => checks,
                    "original_path" => "")
    end

    record = only(matches)
    raw_original = try
        String(get(record, "original_path", ""))
    catch
        ""
    end
    raw_sha256 = try
        String(get(record, "sha256", ""))
    catch
        ""
    end
    raw_archived = get(record, "archived_relative_path", "")
    original_path = isabspath(raw_original) ? normpath(raw_original) : ""
    archived_path = frozen_archive_path(freeze, raw_archived)

    checks["original_path_absolute"] = isabspath(raw_original)
    checks["original_path_normalized"] = !isempty(raw_original) &&
        normpath(raw_original) == raw_original
    checks["sha256_well_formed"] = occursin(r"^[0-9a-f]{64}$", raw_sha256)
    checks["original_path_regular_unlinked"] =
        !isempty(original_path) && regular_unlinked_file(original_path)
    checks["original_sha256"] = checks["original_path_regular_unlinked"] &&
        file_sha256(original_path) == raw_sha256
    checks["archived_path_safe"] = archived_path !== nothing
    checks["archived_path_registered"] = try
        String(raw_archived) == normpath(joinpath(
            "source", "preflight_validation.md"))
    catch
        false
    end
    checks["archived_path_regular_unlinked"] = archived_path !== nothing &&
        regular_unlinked_file(archived_path)
    checks["archived_sha256"] =
        checks["archived_path_regular_unlinked"] &&
        file_sha256(archived_path) == raw_sha256
    checks["preflight_gate"] = checks["original_sha256"] &&
        Bool(preflight_gate(config_path;
            preflight_path=original_path)["passed"])
    Dict("passed" => all(values(checks)), "checks" => checks,
         "original_path" => original_path, "record" => record)
end

function validate_freeze(config, freeze::AbstractString; config_path=DEFAULT_CONFIG)
    freeze = abspath(freeze)
    checksum = Legacy.verify_checksum_manifest(freeze)
    Bool(get(checksum, "passed", false)) || return Dict(
        "passed" => false,
        "checks" => Dict{String,Bool}("checksum_manifest" => false),
        "manifest" => Dict{String,Any}())
    manifest = TOML.parsefile(joinpath(freeze, "freeze_manifest.toml"))
    table_path = joinpath(freeze, "input_freeze.csv")
    preflight_binding = validate_frozen_preflight_binding(
        config_path, freeze, manifest)
    registered_preflight_path = String(preflight_binding["original_path"])
    inventory_preflight_path = isempty(registered_preflight_path) ?
        joinpath(freeze, ".invalid-registered-preflight") :
        registered_preflight_path
    source_records = manifest["sources"]
    source_labels = String[String(record["label"])
                           for record in source_records]
    frozen = Dict(String(r["label"]) => r for r in source_records)
    expected_source_labels = Set(keys(freeze_source_paths(
        config, config_path; preflight_path=inventory_preflight_path)))
    authored_ok = true
    for (label, path) in authored_source_paths(
            config_path; preflight_path=inventory_preflight_path)
        ok = haskey(frozen, label) && regular_unlinked_file(path) &&
            abspath(path) == String(get(frozen[label], "original_path", "")) &&
            file_sha256(path) == String(frozen[label]["sha256"])
        authored_ok &= ok
    end
    archived_sources_ok = all(begin
        archived = frozen_archive_path(
            freeze, get(record, "archived_relative_path", ""))
        archived !== nothing && regular_unlinked_file(archived) &&
            file_sha256(archived) == String(record["sha256"])
    end for record in source_records)
    frozen_rows = parse_simple_csv(table_path)
    expected_keys = expected_freeze_input_keys(config)
    actual_keys = [(String(row.set), parse(Int, row.frame)) for row in frozen_rows]
    key_gate = freeze_input_key_gate(expected_keys, actual_keys)
    checks = Dict{String,Bool}(
        "checksum_manifest" => Bool(checksum["passed"]),
        "experiment" => manifest["experiment_id"] == config["experiment_id"],
        "configuration" => manifest["configuration_sha256"] ==
            file_sha256(config_path),
        "input_table_hash" => manifest["input_freeze_sha256"] ==
            file_sha256(table_path),
        "anchor_and_attribution_rows_equal_retained_split" =>
            get(manifest, "anchor_and_attribution_rows_equal_retained_split", false),
        "input_row_count" => key_gate["input_row_count"],
        "input_keys_unique" => key_gate["input_keys_unique"],
        "input_keys_exact" => key_gate["input_keys_exact"],
        "current_source_gate" => Bool(source_gate(config)["passed"]),
        "registered_preflight_binding" => Bool(preflight_binding["passed"]),
        "current_preflight_record" => get(
            preflight_binding["checks"], "preflight_gate", false),
        "frozen_preflight_record" => haskey(manifest, "preflight_gate") &&
            manifest["preflight_gate"]["passed"] == true,
        "frozen_prerequisite_record" => haskey(manifest, "prerequisite_gate") &&
            manifest["prerequisite_gate"]["passed"] == true,
        "source_label_inventory_exact" => Set(keys(frozen)) ==
            expected_source_labels,
        "source_labels_unique" => length(source_labels) ==
            length(Set(source_labels)),
        "archived_source_record_hashes" => archived_sources_ok,
        "authored_sources_equal_freeze" => authored_ok)
    Dict("passed" => all(values(checks)), "checks" => checks,
         "manifest" => manifest,
         "preflight_binding" => preflight_binding)
end

function expected_freeze_input_keys(config)
    expected_keys = Set{Tuple{String,Int}}()
    for (set_name, stage) in (("anchor", :anchor), ("transfer", :transfer),
                              ("attribution", :attribution)),
            frame in stage_frames(config, stage)
        push!(expected_keys, (set_name, frame))
    end
    expected_keys
end

function freeze_input_key_gate(expected_keys, actual_keys)
    Dict{String,Bool}(
        "input_row_count" => length(actual_keys) == length(expected_keys),
        "input_keys_unique" => length(Set(actual_keys)) == length(actual_keys),
        "input_keys_exact" => Set(actual_keys) == expected_keys)
end

# ---------------------------------------------------------------------------
# Scientific execution
# ---------------------------------------------------------------------------

function atomic_write_toml(path::AbstractString, payload)
    directory = dirname(abspath(path))
    mkpath(directory)
    temporary = joinpath(directory,
        ".$(basename(path)).tmp.$(getpid()).$(time_ns())")
    try
        open(temporary, "w") do io
            TOML.print(io, payload; sorted=true)
            write(io, '\n')
            flush(io)
            ccall(:fsync, Cint, (Cint,), fd(io)) == 0 ||
                error("cannot fsync temporary progress file")
        end
        Base.Filesystem.rename(temporary, abspath(path))
        directory_fd = ccall(:open, Cint, (Cstring, Cint), directory, 0)
        directory_fd >= 0 || error("cannot open progress directory for fsync")
        try
            ccall(:fsync, Cint, (Cint,), directory_fd) == 0 ||
                error("cannot fsync progress directory")
        finally
            ccall(:close, Cint, (Cint,), directory_fd)
        end
    finally
        ispath(temporary) && rm(temporary; force=true)
    end
    path
end

function write_progress(path, payload)
    path === nothing && return nothing
    atomic_write_toml(String(path), payload)
    payload
end

mutable struct PhaseTracker
    progress_path::Union{Nothing,String}
    phase_log_path::Union{Nothing,String}
    stage::String
    pass_name::String
    run_started_utc::String
    phase::String
    phase_started_utc::String
    phase_started_ns::UInt64
    previous_phase::String
    previous_phase_elapsed_seconds::Float64
    phase_open::Bool
end

function PhaseTracker(progress_path::Union{Nothing,String},
                      stage::AbstractString, pass_name::AbstractString,
                      run_started_utc::AbstractString)
    phase_log_path = progress_path === nothing ? nothing :
        joinpath(dirname(progress_path), "phase_log.tsv")
    previous_phase = ""
    previous_seconds = 0.0
    if progress_path !== nothing && isfile(progress_path)
        prior = TOML.parsefile(progress_path)
        previous_phase = String(get(prior, "previous_phase", ""))
        previous_seconds = Float64(get(
            prior, "previous_phase_elapsed_seconds", 0.0))
    end
    PhaseTracker(progress_path, phase_log_path, String(stage),
        String(pass_name), String(run_started_utc), "", "", UInt64(0),
        previous_phase, previous_seconds, false)
end

function append_phase_event(path::Union{Nothing,String},
                            pass_name::AbstractString,
                            phase::AbstractString,
                            event::AbstractString, seconds::Real)
    path === nothing && return nothing
    for field in (pass_name, phase, event)
        (occursin('\t', field) || occursin('\n', field) || occursin('\r', field)) &&
            throw(ArgumentError("phase-log fields cannot contain controls"))
    end
    new_file = !isfile(path)
    open(path, "a") do io
        new_file && println(io, "utc\tpass\tphase\tseconds")
        println(io, string(now(UTC)), '\t', pass_name, '\t', phase, ':', event,
                '\t', Float64(seconds))
        flush(io)
        ccall(:fsync, Cint, (Cint,), fd(io)) == 0 ||
            error("cannot fsync phase log")
    end
    path
end

function progress_payload(tracker::PhaseTracker;
                          status::AbstractString="running",
                          frames_completed::Int, frames_total::Int,
                          current_frame::Int=0, last_completed_frame::Int=0,
                          arms_completed::Int=0, arms_total::Int=length(ARMS),
                          error::AbstractString="")
    Dict{String,Any}(
        "schema_version" => "rq2-gd-parity-assignment-refresh-001/progress-v1",
        "experiment_id" => "RQ2-GD-PARITY-ASSIGNMENT-REFRESH-001",
        "stage" => tracker.stage, "pass" => tracker.pass_name,
        "status" => String(status), "frames_completed" => frames_completed,
        "frames_total" => frames_total, "current_frame" => current_frame,
        "last_completed_frame" => last_completed_frame,
        "arms_completed_current_frame" => arms_completed,
        "arms_total" => arms_total, "process_id" => getpid(),
        "started_utc" => tracker.run_started_utc,
        "updated_utc" => string(now(UTC)), "phase" => tracker.phase,
        "phase_started_utc" => tracker.phase_started_utc,
        "previous_phase" => tracker.previous_phase,
        "previous_phase_elapsed_seconds" =>
            tracker.previous_phase_elapsed_seconds,
        "error" => String(error))
end

function phase_progress!(tracker::PhaseTracker; kwargs...)
    tracker.progress_path === nothing && return nothing
    write_progress(tracker.progress_path, progress_payload(tracker; kwargs...))
end

function close_current_phase!(tracker::PhaseTracker; event::String="end")
    tracker.phase_open || return tracker.previous_phase_elapsed_seconds
    elapsed = Float64(time_ns() - tracker.phase_started_ns) / 1.0e9
    append_phase_event(tracker.phase_log_path, tracker.pass_name,
                       tracker.phase, event, elapsed)
    tracker.previous_phase = tracker.phase
    tracker.previous_phase_elapsed_seconds = elapsed
    tracker.phase_open = false
    elapsed
end

function begin_phase!(tracker::PhaseTracker, phase::AbstractString;
                      status::AbstractString="running", kwargs...)
    close_current_phase!(tracker)
    tracker.phase = String(phase)
    tracker.phase_started_utc = string(now(UTC))
    tracker.phase_started_ns = time_ns()
    tracker.phase_open = true
    append_phase_event(tracker.phase_log_path, tracker.pass_name,
                       tracker.phase, "start", 0.0)
    phase_progress!(tracker; status, kwargs...)
end

function finish_phase!(tracker::PhaseTracker;
                       status::AbstractString="running", kwargs...)
    close_current_phase!(tracker)
    phase_progress!(tracker; status, kwargs...)
end

function mark_progress_failed(progress_path::AbstractString,
                              stage::AbstractString, frames_total::Int,
                              started::AbstractString, exception;
                              append_error_event::Bool=true)
    prior = isfile(progress_path) ? TOML.parsefile(progress_path) :
        Dict{String,Any}()
    pass_name = String(get(prior, "pass", "failed"))
    phase = String(get(prior, "phase", "failed"))
    append_error_event && append_phase_event(
        joinpath(dirname(progress_path), "phase_log.tsv"),
        pass_name, phase, "error", 0.0)
    tracker = PhaseTracker(progress_path, stage, pass_name,
        String(get(prior, "started_utc", started)))
    tracker.phase = phase
    tracker.phase_started_utc = String(get(prior, "phase_started_utc", ""))
    tracker.previous_phase = String(get(prior, "previous_phase", ""))
    tracker.previous_phase_elapsed_seconds = Float64(get(
        prior, "previous_phase_elapsed_seconds", 0.0))
    write_progress(progress_path, progress_payload(tracker;
        status="failed", frames_completed=Int(get(prior, "frames_completed", 0)),
        frames_total=Int(get(prior, "frames_total", frames_total)),
        current_frame=Int(get(prior, "current_frame", 0)),
        last_completed_frame=Int(get(prior, "last_completed_frame", 0)),
        arms_completed=Int(get(prior, "arms_completed_current_frame", 0)),
        arms_total=Int(get(prior, "arms_total", length(ARMS))),
        error=sprint(showerror, exception)))
end

const REFERENCE_TRACE_KEYS = ("update", "accepted", "trial_count",
    "objective_evaluations", "loss_before",
    "accepted_fixed_offset_loss", "accepted_step",
    "x_before_sha256", "x_after_sha256", "raw_proposal_sha256",
    "lower_bound_sha256", "upper_bound_sha256",
    "delta_before_sha256", "delta_after_sha256", "gradient_sha256",
    "direction_sha256", "delta_after_line_search_sha256")

function reference_trace_signature(trace)
    [Dict(key => row[key] for key in REFERENCE_TRACE_KEYS) for row in trace]
end

function retained_reference_equivalence(custom, retained)
    trace_equal = length(custom.trace) == length(retained.trace) && all(
        all(haskey(custom.trace[index], key) &&
            haskey(retained.trace[index], key) &&
            isequal(custom.trace[index][key], retained.trace[index][key])
            for key in REFERENCE_TRACE_KEYS) for index in eachindex(custom.trace))
    Dict{String,Bool}(
        "terminal_scalar" => vector_sha256(custom.x) ==
            vector_sha256(retained.x),
        "terminal_offsets" => edge_sha256(custom.delta) ==
            edge_sha256(retained.delta),
        "hard_decision" => custom.hard == retained.hard,
        "syndrome" => custom.syndrome == retained.syndrome,
        "accepted_steps" => custom.accepted_steps == retained.accepted_steps,
        "trace" => trace_equal,
    )
end

function retained_reference_evidence(custom, retained)
    custom_trace = reference_trace_signature(custom.trace)
    retained_trace = reference_trace_signature(retained.trace)
    Dict{String,Any}(
        "custom_terminal_scalar_sha256" => vector_sha256(custom.x),
        "retained_terminal_scalar_sha256" => vector_sha256(retained.x),
        "custom_terminal_offset_sha256" => edge_sha256(custom.delta),
        "retained_terminal_offset_sha256" => edge_sha256(retained.delta),
        "custom_hard_word_sha256" => scientific_sha256(collect(custom.hard)),
        "retained_hard_word_sha256" => scientific_sha256(collect(retained.hard)),
        "custom_syndrome_sha256" => scientific_sha256(custom.syndrome),
        "retained_syndrome_sha256" => scientific_sha256(retained.syndrome),
        "custom_trace_sha256" => scientific_sha256(custom_trace),
        "retained_trace_sha256" => scientific_sha256(retained_trace),
        "custom_trace_rows" => length(custom_trace),
        "retained_trace_rows" => length(retained_trace),
    )
end

function calculate_science(config, freeze::AbstractString, stage::Symbol;
                           collect_runtime::Bool, config_path=DEFAULT_CONFIG,
                           progress_path=nothing, pass_name="primary",
                           started_utc::AbstractString="")
    frames = stage_frames(config, stage)
    total_frames = length(frames)
    started = isempty(started_utc) ? string(now(UTC)) : String(started_utc)
    phases = PhaseTracker(progress_path, String(stage), String(pass_name), started)
    begin_phase!(phases, "pass_preamble"; frames_completed=0,
        frames_total=total_frames, arms_total=length(ARMS))
    validation = validate_freeze(config, freeze; config_path)
    validation["passed"] || throw(ArgumentError(
        "frozen input gate failed: $(validation["checks"])"))
    split = load_split_config(config)
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = Legacy.make_code(split, native)
    code = generated.code
    information_positions = Legacy.native_call(native, :_message_positions, code)
    esn0 = Float64(split["channel"]["physical_esn0_db"])
    frozen_table = Dict(parse(Int, row.frame) => row
                        for row in parse_simple_csv(joinpath(freeze, "input_freeze.csv")))
    keywords = solver_keywords(split)

    if collect_runtime
        warm_llr = [2sin(0.013bit) + 0.4cos(0.031bit) for bit in 1:code.n]
        warm_problem = problem_for(split, code, warm_llr)
        warm_plan = permutation_plan(warm_problem, MersenneTwister(
            Int(config["arms"]["permutation_seed_base"])))
        for arm in ARMS
            run_arm(arm, warm_problem, code, tanh.(warm_llr ./ 2), 0, split, config;
                collect_trace=false, collect_diagnostics=false,
                permutation_plan_input=warm_plan)
        end
    end

    begin_phase!(phases, "frame_loop"; frames_completed=0,
        frames_total=total_frames, arms_total=length(ARMS))

    frame_rows = NamedTuple[]
    iteration_rows_all = NamedTuple[]
    runtime_rows = NamedTuple[]
    gate_records = Dict{String,Any}[]
    gates_all = Dict{String,Bool}()
    kernel_equivalence_checked = 0
    kernel_equivalence_passed = true
    kernel_equivalence_records = Dict{String,Any}[]
    frozen_inputs_ok = true
    for (position, frame) in enumerate(frames)
        phase_progress!(phases; frames_completed=position - 1,
            frames_total=total_frames, current_frame=frame,
            last_completed_frame=position == 1 ? 0 : frames[position - 1],
            arms_completed=0, arms_total=length(ARMS))
        input = Legacy.generate_input(split, native, code, frame)
        frozen_row = frozen_table[frame]
        frozen_inputs_ok &= frozen_row.clipped_llr_sha256 ==
            input.identities.clipped_llr_sha256 &&
            frozen_row.received_sha256 == input.identities.received_sha256
        problem = problem_for(split, code, input.clipped_llr)
        initial = tanh.(input.clipped_llr ./ 2)
        frame_plan = permutation_plan(problem, MersenneTwister(
            Int(config["arms"]["permutation_seed_base"]) + frame))
        timed_results = Dict{String,Any}()
        if collect_runtime
            rotation = mod(position - 1, length(ARMS))
            for (order_position, arm) in enumerate(circshift(collect(ARMS), -rotation))
                timed = @timed run_arm(arm, problem, code, initial, frame, split,
                    config; collect_trace=false, collect_diagnostics=false,
                    permutation_plan_input=frame_plan)
                timed_results[arm] = timed.value
                push!(runtime_rows, (; frame, arm, order_position,
                    seconds=Float64(timed.time), allocated_bytes=Int(timed.bytes)))
            end
        end
        results = Dict{String,Any}()
        snapshot_set = Set([1, 2])
        for (arm_position, arm) in enumerate(ARMS)
            results[arm] = run_arm(arm, problem, code, initial, frame, split, config;
                snapshot_updates=snapshot_set,
                permutation_plan_input=frame_plan)
            phase_progress!(phases; frames_completed=position - 1,
                frames_total=total_frames, current_frame=frame,
                last_completed_frame=position == 1 ? 0 : frames[position - 1],
                arms_completed=arm_position, arms_total=length(ARMS))
        end
        if stage === :anchor
            retained = Split.solve_variant(problem, code, initial,
                PARITY_USE_SPEC; keywords..., collect_trace=true,
                collect_diagnostics=true, validate_derivatives=false,
                snapshot_updates=snapshot_set)
            equivalence = retained_reference_equivalence(
                results["asbuilt__refreshed"], retained)
            evidence = retained_reference_evidence(
                results["asbuilt__refreshed"], retained)
            kernel_equivalence_checked += 1
            kernel_equivalence_passed &= all(values(equivalence))
            push!(kernel_equivalence_records,
                  Dict("frame" => frame, "checks" => equivalence,
                       "evidence" => evidence))
        end
        gates = frame_gates(results, problem)
        gates["timed_and_traced_terminal_states_equal"] = !collect_runtime || all(
            vector_sha256(timed_results[arm].x) == vector_sha256(results[arm].x) &&
            edge_sha256(timed_results[arm].delta) == edge_sha256(results[arm].delta) &&
            timed_results[arm].hard == results[arm].hard &&
            timed_results[arm].syndrome == results[arm].syndrome &&
            timed_results[arm].accepted_steps == results[arm].accepted_steps &&
            timed_results[arm].candidate_calculations ==
                results[arm].candidate_calculations &&
            timed_results[arm].offset_replacements ==
                results[arm].offset_replacements for arm in ARMS)
        for (key, value) in gates
            gates_all[key] = get(gates_all, key, true) & value
        end
        push!(gate_records, Dict("frame" => frame, "gates" => gates))
        for arm in ARMS
            push!(frame_rows, frame_row(frame, arm, input, results[arm],
                information_positions, esn0))
            append!(iteration_rows_all, iteration_rows(frame, arm, results[arm]))
        end
        phase_progress!(phases; frames_completed=position,
            frames_total=total_frames, current_frame=0,
            last_completed_frame=frame, arms_completed=length(ARMS),
            arms_total=length(ARMS))
    end

    begin_phase!(phases, "statistics"; frames_completed=total_frames,
        frames_total=total_frames, last_completed_frame=last(frames),
        arms_completed=length(ARMS), arms_total=length(ARMS))
    gates_all["frozen_inputs_regenerated_identically"] = frozen_inputs_ok
    gates_all["custom_reference_equals_v3_o1p0"] =
        stage !== :anchor || (kernel_equivalence_checked == length(frames) &&
                              kernel_equivalence_passed)
    expected_frame_arm_keys = Set((frame, arm) for frame in frames for arm in ARMS)
    actual_frame_arm_keys = [(row.frame, String(row.arm)) for row in frame_rows]
    gates_all["every_frame_has_each_arm_once"] =
        length(actual_frame_arm_keys) == length(expected_frame_arm_keys) &&
        length(Set(actual_frame_arm_keys)) == length(actual_frame_arm_keys) &&
        Set(actual_frame_arm_keys) == expected_frame_arm_keys
    table = contrast_table(frame_rows)
    interactions = Dict{String,Any}(endpoint =>
        factorial_interaction(frame_rows, Symbol(endpoint))
        for endpoint in ENDPOINTS)
    if stage === :transfer
        add_inference!(table,
            Float64(config["inference"]["pairwise_interval_confidence_level"]))
        add_refresh_equivalence!(table,
            Float64(config["inference"]["refresh_equivalence_margin"]))
        for (endpoint_index, endpoint) in enumerate(ENDPOINTS)
            add_interaction_bootstrap!(interactions[endpoint], frame_rows,
                Symbol(endpoint);
                seed=Int(config["inference"]["interaction_bootstrap_seed"]) +
                    endpoint_index - 1,
                resamples=Int(config["inference"]["interaction_bootstrap_resamples"]),
                confidence_level=Float64(config["inference"]["interaction_interval_confidence_level"]))
        end
    end
    begin_phase!(phases, "frame_table_hash"; frames_completed=total_frames,
        frames_total=total_frames, last_completed_frame=last(frames),
        arms_completed=length(ARMS), arms_total=length(ARMS))
    frame_rows_sha256 = scientific_sha256(Split.row_dict.(frame_rows))
    begin_phase!(phases, "iteration_table_hash"; frames_completed=total_frames,
        frames_total=total_frames, last_completed_frame=last(frames),
        arms_completed=length(ARMS), arms_total=length(ARMS))
    iteration_rows_sha256 = scientific_sha256(
        Split.row_dict.(iteration_rows_all))
    attribution = Dict{String,Any}()
    if stage === :attribution
        begin_phase!(phases, "attribution_accounting";
            frames_completed=total_frames, frames_total=total_frames,
            last_completed_frame=last(frames), arms_completed=length(ARMS),
            arms_total=length(ARMS))
        transition = attribution_accounting(config, frame_rows)
        attribution = transition.accounting
        for (key, value) in transition.checks
            gates_all["attribution_" * key] = value
        end
    end
    begin_phase!(phases, "gate_hash"; frames_completed=total_frames,
        frames_total=total_frames, last_completed_frame=last(frames),
        arms_completed=length(ARMS), arms_total=length(ARMS))
    frame_gates_sha256 = scientific_sha256(gate_records)
    science = Dict{String,Any}(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "frame_first" => first(frames),
        "frame_last" => last(frames), "frame_count" => length(frames),
        "arms" => collect(ARMS), "physical_esn0_db" => esn0,
        "arm_outcomes" => arm_success_counts(frame_rows),
        "endpoints" => table,
        "refresh_equivalence" => refresh_equivalence_summary(table,
            Float64(config["inference"]["refresh_equivalence_margin"]);
            evaluated=stage === :transfer),
        "interactions" => interactions,
        "native_gd_transition_accounting" => attribution,
        "table_hashes" => Dict(
            "frames" => frame_rows_sha256,
            "iterations" => iteration_rows_sha256,
            "frame_gates" => frame_gates_sha256),
        "correctness_gates" => gates_all,
        "correctness_passed" => all(values(gates_all)),
        "frame_gates" => gate_records,
        "anchor_reference_equivalence" => kernel_equivalence_records,
        "hard_words" => Dict(arm => [row.hard_word_sha256 for row in frame_rows
                                     if row.arm == arm] for arm in ARMS),
        "anchor_expansion_authorized" => false)
    begin_phase!(phases, "pass_completed"; frames_completed=total_frames,
        frames_total=total_frames, last_completed_frame=last(frames),
        arms_completed=length(ARMS), arms_total=length(ARMS))
    finish_phase!(phases; status="pass_completed",
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames), arms_completed=length(ARMS),
        arms_total=length(ARMS))
    (; science, frame_rows, iteration_rows=iteration_rows_all, runtime_rows)
end

function fsync_file(path::AbstractString)
    open(path, "r") do io
        ccall(:fsync, Cint, (Cint,), fd(io)) == 0 ||
            error("cannot fsync file $path")
    end
    path
end

function fsync_directory(path::AbstractString)
    descriptor = ccall(:open, Cint, (Cstring, Cint), path, 0)
    descriptor >= 0 || error("cannot open directory for fsync: $path")
    try
        ccall(:fsync, Cint, (Cint,), descriptor) == 0 ||
            error("cannot fsync directory $path")
    finally
        ccall(:close, Cint, (Cint,), descriptor)
    end
    path
end

function result_checksum_entries(root::AbstractString)
    Legacy.checksum_manifest(root;
        exclude=Set(["MANIFEST.sha256", "PHASE_LOG.sha256",
                     "progress.toml", "phase_log.tsv"]))
end

function write_phase_log_binding(root::AbstractString)
    phase_log = joinpath(root, "phase_log.tsv")
    record = joinpath(root, "PHASE_LOG.sha256")
    write_new_file(record, "$(file_sha256(phase_log))  phase_log.tsv\n")
    fsync_file(record)
    record
end

function write_result_checksum_manifest(root::AbstractString;
                                        precomputed_entries=nothing)
    path = joinpath(root, "MANIFEST.sha256")
    entries = precomputed_entries === nothing ? result_checksum_entries(root) :
        collect(precomputed_entries)
    phase_record = joinpath(root, "PHASE_LOG.sha256")
    isfile(phase_record) || throw(ArgumentError("phase-log binding is missing"))
    push!(entries, "PHASE_LOG.sha256" => file_sha256(phase_record))
    sort!(entries; by=first)
    content = join(("$(last(entry))  $(first(entry))" for entry in entries), "\n") * "\n"
    write_new_file(path, content)
    fsync_file(path)
    fsync_directory(root)
    (; path, entries)
end

function verify_result_checksum_manifest(root::AbstractString)
    manifest = joinpath(root, "MANIFEST.sha256")
    isfile(manifest) || return Dict("passed" => false,
        "failures" => ["missing:MANIFEST.sha256"])
    failures = String[]
    phase_record = joinpath(root, "PHASE_LOG.sha256")
    if !isfile(phase_record)
        push!(failures, "missing:PHASE_LOG.sha256")
    else
        rows = readlines(phase_record)
        if length(rows) != 1
            push!(failures, "malformed:PHASE_LOG.sha256")
        else
            fields = split(rows[1], "  "; limit=2)
            phase_log = joinpath(root, "phase_log.tsv")
            if !isfile(phase_log)
                push!(failures, "missing:phase_log.tsv")
            elseif length(fields) != 2 || fields[2] != "phase_log.tsv" ||
                    fields[1] != file_sha256(phase_log)
                push!(failures, "hash:phase_log.tsv")
            end
        end
    end
    listed = Set{String}()
    for line in readlines(manifest)
        isempty(line) && continue
        fields = split(line, "  "; limit=2)
        length(fields) == 2 || (push!(failures, "malformed:$line"); continue)
        expected, relative = fields
        if isabspath(relative) || ".." in splitpath(relative)
            push!(failures, "unsafe:$relative")
            continue
        end
        if relative in listed
            push!(failures, "duplicate:$relative")
            continue
        end
        push!(listed, relative)
        path = joinpath(root, relative)
        !isfile(path) ? push!(failures, "missing:$relative") :
            file_sha256(path) == expected || push!(failures, "hash:$relative")
    end
    actual = Set(first(entry) for entry in result_checksum_entries(root))
    isfile(phase_record) && push!(actual, "PHASE_LOG.sha256")
    append!(failures, ("extra:$relative" for relative in
        sort!(collect(setdiff(actual, listed)))))
    append!(failures, ("missing:$relative" for relative in
        sort!(collect(setdiff(listed, actual))) if !("missing:$relative" in failures)))
    Dict("passed" => isempty(failures), "failures" => failures,
         "entries" => length(listed))
end

function write_primary_checkpoint(output::AbstractString, calculated)
    checkpoint = joinpath(output, "primary_checkpoint")
    ispath(checkpoint) && throw(ArgumentError(
        "primary checkpoint already exists: $checkpoint"))
    mkdir(checkpoint)
    write_csv(joinpath(checkpoint, "frames.csv"), calculated.frame_rows,
              propertynames(first(calculated.frame_rows)))
    write_csv(joinpath(checkpoint, "iterations.csv"),
              calculated.iteration_rows,
              propertynames(first(calculated.iteration_rows)))
    write_new_file(joinpath(checkpoint, "science.json"),
        canonical_json(calculated.science) * "\n")
    for filename in ("frames.csv", "iterations.csv", "science.json")
        fsync_file(joinpath(checkpoint, filename))
    end
    fsync_directory(checkpoint)
    fsync_directory(dirname(checkpoint))
    checkpoint
end

function write_result(output, config, config_path, freeze, stage, calculated,
                      replay_hash, replay_passed, command; handoff_result=nothing,
                      handoff_record=Dict{String,Any}(),
                      execution_authorization=Dict{String,Any}(),
                      write_phase::Union{Nothing,PhaseTracker}=nothing)
    output = abspath(output)
    isdir(output) || throw(ArgumentError(
        "precreated result directory is missing: $output"))
    Set(readdir(output)) == Set(["progress.toml", "phase_log.tsv",
                                 "primary_checkpoint"]) ||
        throw(ArgumentError(
            "result directory does not contain exactly telemetry and primary checkpoint"))
    checkpoint = joinpath(output, "primary_checkpoint")
    Set(readdir(checkpoint)) == Set(["frames.csv", "iterations.csv", "science.json"]) ||
        throw(ArgumentError("primary checkpoint is incomplete or has extra files"))
    science = calculated.science
    base_hash = scientific_sha256(science)
    science["deterministic_replay"] = Dict("first_sha256" => base_hash,
        "second_sha256" => replay_hash, "passed" => replay_passed)
    science["correctness_gates"]["deterministic_replay"] = replay_passed
    science["correctness_passed"] &= replay_passed
    stage === :anchor && (science["anchor_expansion_authorized"] =
        science["correctness_passed"])
    science_path = joinpath(output, "science.json")
    write_new_file(science_path, canonical_json(science) * "\n")
    write_csv(joinpath(output, "frames.csv"), calculated.frame_rows,
              propertynames(first(calculated.frame_rows)))
    write_csv(joinpath(output, "iterations.csv"), calculated.iteration_rows,
              propertynames(first(calculated.iteration_rows)))
    isempty(calculated.runtime_rows) || write_csv(joinpath(output, "runtime.csv"),
        calculated.runtime_rows, propertynames(first(calculated.runtime_rows)))
    aggregates = NamedTuple[]
    for endpoint in ENDPOINTS, contrast in CONTRASTS
        c = science["endpoints"][endpoint]["contrasts"][contrast.id]
        interval = get(c, "newcombe_interval", Dict("lower" => NaN, "upper" => NaN))
        equivalence = refresh_equivalence_aggregate_fields(
            c, contrast.id, stage)
        push!(aggregates, (; endpoint, contrast=contrast.id,
            treatment=contrast.treatment, reference=contrast.reference,
            pairs=c["pairs"], both_success=c["both_success"],
            treatment_only_success=c["treatment_only_success"],
            reference_only_success=c["reference_only_success"],
            both_failure=c["both_failure"],
            treatment_successes=c["treatment_successes"],
            reference_successes=c["reference_successes"],
            risk_difference=c["risk_difference_treatment_minus_reference"],
            interval_lower=get(interval, "lower", NaN),
            interval_upper=get(interval, "upper", NaN),
            mcnemar_p=get(c, "mcnemar_exact_two_sided_pvalue", NaN),
            holm_p=get(c, "holm_adjusted_pvalue", NaN),
            refresh_equivalence_applicable=equivalence.applicable,
            refresh_equivalence_evaluated=equivalence.evaluated,
            refresh_equivalence_status=equivalence.status,
            refresh_equivalence_margin=equivalence.margin,
            refresh_equivalent_within_margin=equivalence.decision,
            refresh_equivalence_criterion=equivalence.criterion))
    end
    write_csv(joinpath(output, "aggregate.csv"), aggregates,
              propertynames(first(aggregates)))
    interaction_rows = NamedTuple[]
    for endpoint in ENDPOINTS
        interaction = science["interactions"][endpoint]
        bootstrap = get(interaction, "bootstrap", Dict{String,Any}())
        counts = interaction["frame_score_counts"]
        push!(interaction_rows, (; endpoint,
            frames=interaction["frames"],
            score_sum=interaction["score_sum"],
            risk_difference_interaction=
                interaction["risk_difference_interaction"],
            score_minus2=counts["-2"], score_minus1=counts["-1"],
            score_zero=counts["0"], score_plus1=counts["1"],
            score_plus2=counts["2"],
            bootstrap_lower=get(bootstrap, "lower", NaN),
            bootstrap_upper=get(bootstrap, "upper", NaN),
            bootstrap_seed=get(bootstrap, "seed", 0),
            bootstrap_resamples=get(bootstrap, "resamples", 0)))
    end
    write_csv(joinpath(output, "interaction.csv"), interaction_rows,
              propertynames(first(interaction_rows)))
    split = load_split_config(config)
    source_directory = joinpath(output, "source")
    cp(joinpath(freeze, "source"), source_directory; force=false)
    freeze_manifest = TOML.parsefile(joinpath(freeze, "freeze_manifest.toml"))
    records = freeze_manifest["sources"]
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "created_utc" => string(now(UTC)),
        "command" => String(command), "freeze" => abspath(freeze),
        "freeze_manifest_sha256" => file_sha256(joinpath(freeze, "freeze_manifest.toml")),
        "freeze_checksum_manifest_sha256" => file_sha256(joinpath(freeze, "MANIFEST.sha256")),
        "handoff_result" => handoff_result === nothing ? "" :
            abspath(handoff_result),
        "handoff" => handoff_record,
        "execution_authorization" => execution_authorization,
        "base_scientific_sha256" => base_hash,
        "stored_scientific_sha256" => scientific_sha256(science),
        "environment" => environment_record(split),
        "sources" => records,
        "primary_checkpoint_science_sha256" => file_sha256(joinpath(
            checkpoint, "science.json")),
        "progress_excluded_from_scientific_and_checksum_hashes" => true,
        "phase_log_excluded_from_manifest_and_bound_by_sidecar" => true)
    manifest_path = joinpath(output, "manifest.toml")
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    status = science["correctness_passed"] ? "complete_valid" : "complete_invalid"
    completion = Dict(
        "schema_version" => String(config["provenance"]["completion_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "completed_utc" => string(now(UTC)),
        "status" => status,
        "correctness_passed" => Bool(science["correctness_passed"]),
        "deterministic_replay_passed" => replay_passed,
        "anchor_expansion_authorized" => Bool(science["anchor_expansion_authorized"]),
        "science_sha256" => file_sha256(science_path),
        "manifest_sha256" => file_sha256(manifest_path))
    open(joinpath(output, "COMPLETED.toml"), "w") do io
        TOML.print(io, completion; sorted=true)
    end
    if write_phase !== nothing
        close_current_phase!(write_phase)
        total_frames = Int(science["frame_count"])
        begin_phase!(write_phase, "checksum_manifest";
            frames_completed=total_frames, frames_total=total_frames,
            last_completed_frame=Int(science["frame_last"]),
            arms_completed=length(ARMS), arms_total=length(ARMS))
    end
    precomputed_entries = result_checksum_entries(output)
    write_phase !== nothing && finish_phase!(write_phase;
        status="checksum_complete", frames_completed=Int(science["frame_count"]),
        frames_total=Int(science["frame_count"]),
        last_completed_frame=Int(science["frame_last"]),
        arms_completed=length(ARMS), arms_total=length(ARMS))
    write_phase_log_binding(output)
    checksums = write_result_checksum_manifest(output;
        precomputed_entries)
    (; output, science, completion, checksum_entries=length(checksums.entries))
end

function validate_stage_handoff(config, result, freeze, expected_stage::String;
                                require_expansion::Bool=false)
    completion_path = joinpath(result, "COMPLETED.toml")
    manifest_path = joinpath(result, "manifest.toml")
    science_path = joinpath(result, "science.json")
    required = (completion_path, manifest_path, science_path,
                joinpath(result, "MANIFEST.sha256"),
                joinpath(result, "phase_log.tsv"),
                joinpath(result, "PHASE_LOG.sha256"),
                joinpath(freeze, "freeze_manifest.toml"),
                joinpath(freeze, "MANIFEST.sha256"))
    if !all(isfile, required)
        return Dict("passed" => false,
            "checks" => Dict("required_files" => false),
            "record" => Dict{String,Any}())
    end
    checksum = verify_result_checksum_manifest(result)
    completion = TOML.parsefile(completion_path)
    manifest = TOML.parsefile(manifest_path)
    checks = Dict(
        "checksums" => Bool(checksum["passed"]),
        "experiment" => get(completion, "experiment_id", "") ==
            config["experiment_id"] && get(manifest, "experiment_id", "") ==
            config["experiment_id"],
        "stage" => get(completion, "stage", "") == expected_stage &&
            get(manifest, "stage", "") == expected_stage,
        "status" => get(completion, "status", "") == "complete_valid" &&
            get(completion, "correctness_passed", false),
        "deterministic_replay" => get(
            completion, "deterministic_replay_passed", false),
        "science_hash" => get(completion, "science_sha256", "") ==
            file_sha256(science_path),
        "manifest_hash" => get(completion, "manifest_sha256", "") ==
            file_sha256(manifest_path),
        "freeze" => get(manifest, "freeze_manifest_sha256", "") ==
            file_sha256(joinpath(freeze, "freeze_manifest.toml")) &&
            get(manifest, "freeze_checksum_manifest_sha256", "") ==
                file_sha256(joinpath(freeze, "MANIFEST.sha256")))
    require_expansion && (checks["expansion"] =
        get(completion, "anchor_expansion_authorized", false) == true)
    if expected_stage == "transfer"
        embedded = get(manifest, "handoff", Dict{String,Any}())
        embedded_checks = get(embedded, "checks", Dict{String,Any}())
        checks["embedded_anchor_handoff"] =
            get(embedded, "stage", "") == "anchor" &&
            !isempty(String(get(embedded, "completion_sha256", ""))) &&
            !isempty(String(get(embedded, "science_sha256", ""))) &&
            !isempty(embedded_checks) && all(Bool(value) for value in
                                             values(embedded_checks))
        authorization = get(manifest, "execution_authorization",
                            Dict{String,Any}())
        authorization_checks = get(authorization, "checks",
                                   Dict{String,Any}())
        checks["transfer_execution_authorization"] =
            get(authorization, "target_stage", "") == "transfer" &&
            !isempty(String(get(authorization, "budget_record_sha256", ""))) &&
            !isempty(String(get(authorization, "queue_manifest_sha256", ""))) &&
            !isempty(authorization_checks) && all(Bool(value) for value in
                                                  values(authorization_checks))
    end
    record = Dict{String,Any}(
        "result" => abspath(result), "stage" => expected_stage,
        "completion_sha256" => file_sha256(completion_path),
        "manifest_sha256" => file_sha256(manifest_path),
        "science_sha256" => file_sha256(science_path),
        "checksum_manifest_sha256" => file_sha256(joinpath(
            result, "MANIFEST.sha256")),
        "phase_log_sha256" => file_sha256(joinpath(result, "phase_log.tsv")),
        "freeze_manifest_sha256" => file_sha256(joinpath(
            freeze, "freeze_manifest.toml")),
        "freeze_checksum_manifest_sha256" => file_sha256(joinpath(
            freeze, "MANIFEST.sha256")),
        "predecessor_handoff" => get(manifest, "handoff", Dict{String,Any}()),
        "checks" => checks)
    Dict("passed" => all(values(checks)), "checks" => checks,
         "record" => record)
end

function verify_external_checksum_manifest(path::AbstractString)
    isfile(path) || return Dict("passed" => false,
        "failures" => ["missing:$(basename(path))"])
    root = dirname(abspath(path))
    failures = String[]
    seen = Set{String}()
    listed = Dict{String,String}()
    for line in readlines(path)
        isempty(line) && continue
        fields = split(line, "  "; limit=2)
        if length(fields) != 2
            push!(failures, "malformed:$line")
            continue
        end
        expected, relative = fields
        if isabspath(relative) || ".." in splitpath(relative)
            push!(failures, "unsafe:$relative")
            continue
        end
        relative in seen && (push!(failures, "duplicate:$relative"); continue)
        push!(seen, relative)
        listed[relative] = expected
        target = joinpath(root, relative)
        !isfile(target) ? push!(failures, "missing:$relative") :
            file_sha256(target) == expected || push!(failures, "hash:$relative")
    end
    Dict("passed" => isempty(failures) && !isempty(seen),
         "failures" => failures, "entries" => length(seen),
         "listed" => listed)
end

function queue_closed_inventory(config, queue_root::AbstractString, listed)
    authorization = config["execution_authorization"]
    allowed = Set(String.(keys(listed)))
    union!(allowed, String.(
        authorization["queue_unlisted_immutable_sidecars"]))
    union!(allowed, String.(
        authorization["queue_allowed_mutable_relative_paths"]))
    actual = Set{String}()
    symlinks = String[]
    for (root, directories, files) in walkdir(queue_root; follow_symlinks=false)
        for name in directories
            path = joinpath(root, name)
            islink(path) && push!(symlinks, relpath(path, queue_root))
        end
        for name in files
            path = joinpath(root, name)
            relative = relpath(path, queue_root)
            islink(path) && push!(symlinks, relative)
            push!(actual, relative)
        end
    end
    extras = sort!(collect(setdiff(actual, allowed)))
    Dict{String,Any}(
        "passed" => isempty(extras) && isempty(symlinks),
        "extras" => extras,
        "symlinks" => sort!(unique(symlinks)),
        "actual" => sort!(collect(actual)),
        "allowed" => sort!(collect(allowed)),
    )
end

function validate_execution_authorization(config, stage::Symbol,
                                          budget_record,
                                          queue_manifest,
                                          handoff_record;
                                          registered_preflight_path=nothing)
    stage === :anchor && return Dict("passed" => true,
        "checks" => Dict("anchor_not_required" => true),
        "record" => Dict{String,Any}())
    required = budget_record !== nothing && queue_manifest !== nothing &&
        isfile(String(budget_record)) && isfile(String(queue_manifest))
    required || return Dict("passed" => false,
        "checks" => Dict("required_files" => false),
        "record" => Dict{String,Any}())
    budget_path = abspath(String(budget_record))
    queue_path = abspath(String(queue_manifest))
    queue_root = dirname(queue_path)
    budget = TOML.parsefile(budget_path)
    queue_gate = verify_external_checksum_manifest(queue_path)
    listed = get(queue_gate, "listed", Dict{String,String}())
    budget_relative = relpath(budget_path, queue_root)
    queue_config_path = joinpath(queue_root, "queue.toml")
    queue_lock_path = joinpath(queue_root, "QUEUE_PACKAGE_LOCK.toml")
    queue_config = isfile(queue_config_path) ? TOML.parsefile(queue_config_path) :
        Dict{String,Any}()
    queue_lock = isfile(queue_lock_path) ? TOML.parsefile(queue_lock_path) :
        Dict{String,Any}()
    queue_paths = get(queue_config, "paths", Dict{String,Any}())
    budget_relatives = String[]
    for key in ("budget_transfer", "budget_attribution")
        relative = canonical_queue_relative(get(queue_paths, key, ""))
        relative === nothing || push!(budget_relatives, relative)
    end
    required_listed = Set(["README.md", "queue.toml",
                           collect(keys(queue_package_governance_sources()))...,
                           budget_relatives...])
    declared_inventory = String.(get(get(queue_config, "inventory",
        Dict{String,Any}()), "immutable_files", String[]))
    queue_inventory = queue_closed_inventory(
        config, queue_root, get(queue_gate, "listed", Dict{String,String}()))
    expected_cases = length(stage_frames(config, stage))
    anchor_record = stage === :transfer ? handoff_record :
        get(handoff_record, "predecessor_handoff", Dict{String,Any}())
    checks = Dict{String,Bool}(
        "budget_schema" => get(budget, "schema_version", "") ==
            config["execution_authorization"]["budget_schema"],
        "experiment" => get(budget, "experiment_id", "") ==
            config["experiment_id"],
        "target_stage" => get(budget, "target_stage", "") == String(stage),
        "target_cases" => get(budget, "target_cases", 0) == expected_cases,
        "anchor_cases" => get(budget, "anchor_cases", 0) ==
            length(stage_frames(config, :anchor)),
        "pass_count" => get(budget, "pass_count", 0) ==
            Int(config["work_budget"]["scientific_passes"]),
        "safety_factor" => get(budget, "safety_factor", 0.0) ==
            Float64(config["work_budget"]["heldout_budget_scale"]),
        "absolute_cap" => get(budget, "absolute_safety_cap_seconds", 0) ==
            Int(config["work_budget"]["maximum_stage_wall_budget_seconds"]),
        "termination_grace" => get(budget, "termination_grace_seconds", 0) ==
            Int(config["work_budget"]["termination_grace_seconds"]),
        "wall_budget_positive" => get(budget, "wall_budget_seconds", 0) >
            get(budget, "termination_grace_seconds", 0),
        "wall_budget_within_cap" => get(budget, "wall_budget_seconds", typemax(Int)) <=
            Int(config["work_budget"]["maximum_stage_wall_budget_seconds"]),
        "term_identity" => get(budget, "term_after_seconds", -1) +
            get(budget, "termination_grace_seconds", -1) ==
            get(budget, "wall_budget_seconds", -3),
        "anchor_science_bound" => get(budget, "anchor_science_sha256", "") ==
            get(anchor_record, "science_sha256", "missing"),
        "anchor_completion_bound" =>
            get(budget, "anchor_completion_sha256", "") ==
                get(anchor_record, "completion_sha256", "missing"),
        "anchor_manifest_bound" => get(budget, "anchor_manifest_sha256", "") ==
            get(anchor_record, "manifest_sha256", "missing"),
        "anchor_checksum_manifest_bound" =>
            get(budget, "anchor_checksum_manifest_sha256", "") ==
                get(anchor_record, "checksum_manifest_sha256", "missing"),
        "anchor_phase_log_bound" => get(budget, "phase_log_sha256", "") ==
            get(anchor_record, "phase_log_sha256", "missing"),
        "budget_formula" => isapprox(
            get(budget, "projected_seconds_before_safety", NaN),
            get(budget, "projected_frame_seconds", NaN) +
                get(budget, "projected_post_loop_seconds", NaN);
            rtol=0.0, atol=1.0e-6) &&
            isapprox(get(budget, "projected_frame_seconds", NaN),
                get(budget, "anchor_frame_loop_seconds", NaN) /
                    get(budget, "anchor_cases", 0) *
                    get(budget, "target_cases", 0);
                rtol=0.0, atol=1.0e-6) &&
            isapprox(get(budget, "projected_post_loop_seconds", NaN),
                get(budget, "anchor_post_loop_seconds", NaN) *
                    get(budget, "target_cases", 0) /
                    get(budget, "anchor_cases", 0);
                rtol=0.0, atol=1.0e-6) &&
            get(budget, "wall_budget_seconds", -1) == ceil(Int,
                Float64(config["work_budget"]["heldout_budget_scale"]) *
                get(budget, "projected_seconds_before_safety", NaN)),
        "queue_manifest" => Bool(queue_gate["passed"]),
        "queue_root_inventory_closed" => Bool(queue_inventory["passed"]),
        "queue_contains_no_symlinks" => isempty(queue_inventory["symlinks"]),
        "queue_manifest_filename" => basename(queue_path) == String(
            config["execution_authorization"]["queue_manifest_filename"]),
        "budget_listed_by_queue" => get(listed, budget_relative, "") ==
            file_sha256(budget_path),
        "queue_readme_is_authored_template" =>
            get(listed, "README.md", "") ==
                file_sha256(QUEUE_README_TEMPLATE_PATH),
        "budget_inside_queue_root" => !startswith(budget_relative, "..") &&
            !isabspath(budget_relative),
        "required_queue_inventory" => required_listed == Set(keys(listed)),
        "queue_manifest_equals_declared_immutable_inventory" =>
            length(declared_inventory) == length(Set(declared_inventory)) &&
            Set(declared_inventory) == Set(keys(listed)),
        "queue_configuration" => isfile(queue_config_path) &&
            Set(String.(keys(queue_config))) == QUEUE_TOP_LEVEL_KEYS &&
            get(queue_config, "schema_version", "") ==
                config["execution_authorization"]["queue_schema"] &&
            get(queue_config, "experiment_id", "") == config["experiment_id"] &&
            String.(get(queue_config, "stages", String[])) ==
                ["transfer", "attribution"] &&
            get(queue_config, "execution_mode", "") ==
                "serial, one scientific unit, fail closed" &&
            get(queue_config, "automatic_restart_allowed", true) == false &&
            get(queue_config, "interrupted_attempt_must_be_retained", false) ==
                true &&
            get(queue_config, "manual_relaunch_requires_new_attempt_directory",
                false) == true &&
            get(queue_config, "execution", Dict{String,Any}()) ==
                config["queue_plan"] &&
            !isempty(String(get(queue_config, "queue_id", ""))),
        "queue_path_key_inventory" => Set(String.(keys(queue_paths))) ==
            QUEUE_PATH_KEYS,
        "queue_telemetry" => begin
            telemetry = get(queue_config, "telemetry", Dict{String,Any}())
            files = String.(get(telemetry, "files", String[]))
            jobs = String.(get(telemetry, "job_ids", String[]))
            Set(String.(keys(telemetry))) == Set(["files", "job_ids"]) &&
                length(files) == length(Set(files)) &&
                Set(files) == QUEUE_BASE_TELEMETRY &&
                jobs == QUEUE_JOB_IDS
        end,
        "queue_config_and_runner_paths" =>
            resolve_queue_config_path(queue_root, queue_config, "config") ==
                normpath(DEFAULT_CONFIG) &&
            resolve_queue_config_path(queue_root, queue_config, "runner") ==
                normpath(RUNNER_PATH),
        "queue_preflight_matches_freeze" =>
            registered_preflight_path !== nothing &&
            resolve_queue_config_path(queue_root, queue_config, "preflight") ==
                normpath(abspath(String(registered_preflight_path))),
        "queue_budget_path" =>
            resolve_queue_config_path(queue_root, queue_config,
                "budget_$(stage)") == normpath(budget_path),
        "queue_lock" => isfile(queue_lock_path) &&
            get(queue_lock, "schema_version", "") ==
                config["execution_authorization"]["queue_lock_schema"] &&
            get(queue_lock, "experiment_id", "") == config["experiment_id"] &&
            get(queue_lock, "queue_id", "") ==
                get(queue_config, "queue_id", nothing) &&
            get(queue_lock, "queue_manifest_sha256", "") ==
                file_sha256(queue_path) &&
            get(queue_lock, "locked_file_count", -1) == length(listed),
    )
    for (relative, source) in queue_package_governance_sources()
        key = "queue_governance_" * replace(relative, r"[^A-Za-z0-9]+" => "_")
        checks[key] = isfile(source) &&
            get(listed, relative, "") == file_sha256(source)
    end
    record = Dict{String,Any}(
        "budget_record" => budget_path,
        "budget_record_sha256" => file_sha256(budget_path),
        "queue_manifest" => queue_path,
        "queue_manifest_sha256" => file_sha256(queue_path),
        "target_stage" => String(stage),
        "wall_budget_seconds" => get(budget, "wall_budget_seconds", 0),
        "term_after_seconds" => get(budget, "term_after_seconds", 0),
        "queue_inventory" => queue_inventory,
        "checks" => checks)
    Dict("passed" => all(values(checks)), "checks" => checks,
         "record" => record)
end

function run_stage(stage::Symbol, output, freeze; config_path=DEFAULT_CONFIG,
                   anchor_result=nothing, transfer_result=nothing,
                   budget_record=nothing, queue_manifest=nothing,
                   command=String(stage))
    config = load_config(config_path)
    output = abspath(output)
    ispath(output) && throw(ArgumentError("result output already exists: $output"))
    handoff_result = nothing
    handoff_record = Dict{String,Any}()
    if stage === :transfer
        anchor_result === nothing && throw(ArgumentError(
            "transfer execution requires --anchor-result"))
        handoff_result = anchor_result
        handoff = validate_stage_handoff(config, anchor_result, freeze, "anchor";
                                         require_expansion=true)
        handoff["passed"] || throw(ArgumentError(
            "anchor did not authorize transfer execution: $(handoff["checks"])"))
        handoff_record = handoff["record"]
    elseif stage === :attribution
        transfer_result === nothing && throw(ArgumentError(
            "attribution execution requires --transfer-result"))
        handoff_result = transfer_result
        handoff = validate_stage_handoff(config, transfer_result, freeze,
                                         "transfer")
        handoff["passed"] || throw(ArgumentError(
            "transfer did not authorize attribution execution: $(handoff["checks"])"))
        handoff_record = handoff["record"]
    elseif stage !== :anchor
        throw(ArgumentError("unsupported scientific stage $stage"))
    end
    registered_preflight_path = nothing
    if stage !== :anchor
        freeze_validation = validate_freeze(config, freeze; config_path)
        freeze_validation["passed"] || throw(ArgumentError(
            "frozen input gate failed before queue authorization: " *
            string(freeze_validation["checks"])))
        registered_preflight_path =
            freeze_validation["preflight_binding"]["original_path"]
    end
    authorization = validate_execution_authorization(config, stage,
        budget_record, queue_manifest, handoff_record;
        registered_preflight_path)
    authorization["passed"] || throw(ArgumentError(
        "execution authorization failed: $(authorization["checks"])"))
    mkpath(dirname(output)); mkdir(output)
    progress_path = joinpath(output, "progress.toml")
    started = string(now(UTC))
    active_tracker = nothing
    try
        calculated = calculate_science(config, freeze, stage;
            collect_runtime=true, config_path, progress_path,
            pass_name="primary", started_utc=started)
        checkpoint_tracker = PhaseTracker(progress_path, String(stage),
            "primary", started)
        active_tracker = checkpoint_tracker
        begin_phase!(checkpoint_tracker, "primary_checkpoint";
            frames_completed=length(stage_frames(config, stage)),
            frames_total=length(stage_frames(config, stage)),
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(ARMS), arms_total=length(ARMS))
        write_primary_checkpoint(output, calculated)
        finish_phase!(checkpoint_tracker; status="checkpoint_complete",
            frames_completed=length(stage_frames(config, stage)),
            frames_total=length(stage_frames(config, stage)),
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(ARMS), arms_total=length(ARMS))
        active_tracker = nothing
        replay = calculate_science(config, freeze, stage;
            collect_runtime=false, config_path, progress_path,
            pass_name="replay", started_utc=started)
        first_hash = scientific_sha256(calculated.science)
        replay_hash = scientific_sha256(replay.science)
        write_tracker = PhaseTracker(progress_path, String(stage),
            "artifact", started)
        active_tracker = write_tracker
        begin_phase!(write_tracker, "write_result";
            frames_completed=length(stage_frames(config, stage)),
            frames_total=length(stage_frames(config, stage)),
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(ARMS), arms_total=length(ARMS))
        written = write_result(output, config, config_path, freeze, stage, calculated,
            replay_hash, first_hash == replay_hash, String(command);
            handoff_result, handoff_record,
            execution_authorization=authorization["record"],
            write_phase=write_tracker)
        finish_phase!(write_tracker; status=String(written.completion["status"]),
            frames_completed=length(stage_frames(config, stage)),
            frames_total=length(stage_frames(config, stage)),
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(ARMS), arms_total=length(ARMS))
        active_tracker = nothing
        return written
    catch exception
        had_active_tracker = active_tracker !== nothing
        had_active_tracker && close_current_phase!(active_tracker; event="error")
        mark_progress_failed(progress_path, String(stage),
            length(stage_frames(config, stage)), started, exception;
            append_error_event=!had_active_tracker)
        rethrow()
    end
end

function verify_result(result; config_path=DEFAULT_CONFIG)
    config = load_config(config_path)
    checksum = verify_result_checksum_manifest(result)
    completion = TOML.parsefile(joinpath(result, "COMPLETED.toml"))
    science = TOML.parsefile(joinpath(result, "manifest.toml"))
    passed = Bool(checksum["passed"]) && completion["status"] == "complete_valid" &&
        completion["experiment_id"] == config["experiment_id"] &&
        completion["science_sha256"] == file_sha256(joinpath(result, "science.json")) &&
        completion["manifest_sha256"] == file_sha256(joinpath(result, "manifest.toml"))
    Dict("passed" => passed, "checksum" => checksum, "completion" => completion,
         "stored_scientific_sha256" => science["stored_scientific_sha256"])
end

function usage()
    "usage:\n" *
    "  rq2_gd_parity_assignment_refresh_001.jl preflight-probe [--config FILE]\n" *
    "  rq2_gd_parity_assignment_refresh_001.jl freeze --output DIR --preflight FILE\n" *
    "  rq2_gd_parity_assignment_refresh_001.jl anchor --freeze DIR --output DIR\n" *
    "  rq2_gd_parity_assignment_refresh_001.jl transfer --freeze DIR --anchor-result DIR --budget-record FILE --queue-manifest FILE --output DIR\n" *
    "  rq2_gd_parity_assignment_refresh_001.jl attribution --freeze DIR --transfer-result DIR --budget-record FILE --queue-manifest FILE --output DIR\n" *
    "  rq2_gd_parity_assignment_refresh_001.jl verify --result DIR"
end

function main(arguments=ARGS)
    parsed = Legacy.parse_cli(arguments)
    parsed.help && (println(usage()); return 0)
    config_path = get(parsed.options, "config", DEFAULT_CONFIG)
    command = join(vcat(["julia", "--project=" * something(Base.active_project(), ""),
                         RUNNER_PATH], String.(arguments)), " ")
    if parsed.mode === Symbol("preflight-probe")
        config = load_config(config_path)
        gate = source_gate(config)
        gate["passed"] || throw(ArgumentError("source gate failed: $(gate["checks"])"))
        split = load_split_config(config)
        Legacy.enforce_thread_environment(split)
        native = Legacy.load_native(split)
        generated = Legacy.make_code(split, native)
        println("experiment: ", config["experiment_id"])
        println("graph SHA-256: ", Legacy.graph_sha256(generated.code.check_vars))
        println("arms: ", join(ARMS, ","))
        prerequisite = prerequisite_gate(config)
        println("offset-split v3 prerequisite: ", prerequisite["passed"])
        return 0
    elseif parsed.mode === :freeze
        output = get(parsed.options, "output", nothing)
        preflight_path = get(parsed.options, "preflight", nothing)
        (output === nothing || preflight_path === nothing) &&
            throw(ArgumentError(
                "freeze requires --output and --preflight"))
        frozen = freeze_inputs(output; config_path, preflight_path, command)
        println("frozen input rows: ", frozen["input_rows"])
        println("input table SHA-256: ", frozen["input_freeze_sha256"])
        return 0
    elseif parsed.mode in (:anchor, :transfer, :attribution)
        freeze = get(parsed.options, "freeze", nothing)
        output = get(parsed.options, "output", nothing)
        (freeze === nothing || output === nothing) &&
            throw(ArgumentError("$(parsed.mode) requires --freeze and --output"))
        written = run_stage(parsed.mode, output, freeze; config_path,
            anchor_result=get(parsed.options, "anchor-result", nothing),
            transfer_result=get(parsed.options, "transfer-result", nothing),
            budget_record=get(parsed.options, "budget-record", nothing),
            queue_manifest=get(parsed.options, "queue-manifest", nothing),
            command)
        println("$(parsed.mode) status: ", written.completion["status"])
        for arm in ARMS
            outcome = written.science["arm_outcomes"][arm]
            println("  ", arm, ": transmitted-word ", outcome["transmitted_word_equal"],
                    "/", outcome["frames"], "  parity-valid ", outcome["parity_valid"],
                    "/", outcome["frames"])
        end
        return written.completion["correctness_passed"] ? 0 : 2
    elseif parsed.mode === :verify
        result = get(parsed.options, "result", nothing)
        result === nothing && throw(ArgumentError("verify requires --result"))
        verified = verify_result(result; config_path)
        println("verify passed: ", verified["passed"])
        return verified["passed"] ? 0 : 2
    end
    throw(ArgumentError("unsupported mode $(parsed.mode)\n$(usage())"))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(Base.invokelatest(main))
end

end # module
