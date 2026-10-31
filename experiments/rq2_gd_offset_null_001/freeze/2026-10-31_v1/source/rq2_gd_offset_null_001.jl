#!/usr/bin/env julia

module RQ2GDOffsetNull001

# RQ2-GD-OFFSET-NULL-001: null-structure controls for the retained-offset
# intervention.  Four projected-gradient arms run on the same frozen cases as
# RQ2-GD-OFFSET-SPLIT-001:
#
#   control    native scalar projected GD (offsets built and stored, never read)
#   reference  the retained compound arm (offsets read in the parity term and
#              in the projection interval)
#   permuted   as reference, but after every refresh each bit's offsets are
#              reassigned among that bit's own checks by a random derangement
#   frozen     as reference, but the offsets built after the first accepted
#              update are never refreshed
#
# The control and reference arms are executed by the retained split runner's
# own kernel, so their arithmetic is the retained arithmetic.  The permuted and
# frozen arms run a copy of that kernel with one hook each, and the copy is
# gated against the retained kernel in reference mode on the anchor stage.

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
const TEST_PATH = joinpath(HERE, "test_rq2_gd_offset_null_001.jl")
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const SPLIT_RUNNER_PATH = joinpath(dirname(HERE), "rq2_gd_offset_split_001",
                                   "rq2_gd_offset_split_001.jl")

include(SPLIT_RUNNER_PATH)
const Split = RQ2GDOffsetSplit001
const Legacy = Split.Legacy

const BridgeProblem = Legacy.BridgeProblem
const vector_sha256 = Legacy.vector_sha256
const edge_sha256 = Legacy.edge_sha256
const file_sha256 = Legacy.file_sha256
const scientific_sha256 = Legacy.scientific_sha256
const canonical_json = Legacy.canonical_json
const write_new_file = Legacy.write_new_file
const write_csv = Legacy.write_csv
const parse_simple_csv = Legacy.parse_simple_csv
const git_output = Legacy.git_output

const ARMS = ("control", "reference", "permuted", "frozen")
const COMPOUND_SPEC = Split.REQUIRED_ARMS[4]
const CONTROL_SPEC = Split.REQUIRED_ARMS[1]
const CONTRASTS = (
    (id="reference_vs_control", treatment="reference", reference="control"),
    (id="permuted_vs_control", treatment="permuted", reference="control"),
    (id="frozen_vs_control", treatment="frozen", reference="control"),
    (id="reference_vs_permuted", treatment="reference", reference="permuted"),
    (id="reference_vs_frozen", treatment="reference", reference="frozen"),
)
const ENDPOINTS = ("transmitted_word_equal", "parity_valid")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq2-gd-offset-null-001/v1" ||
        throw(ArgumentError("unsupported schema"))
    config["experiment_id"] == "RQ2-GD-OFFSET-NULL-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["scope"]["bp_arm_included"] == false ||
        throw(ArgumentError("a BP arm is outside this experiment"))
    config["anchor"]["frame_first"] == 20001 &&
        config["anchor"]["frame_last"] == 20024 ||
        throw(ArgumentError("anchor frame set changed"))
    config["heldout"]["frame_first"] == 30001 &&
        config["heldout"]["frame_last"] == 30200 ||
        throw(ArgumentError("held-out frame set changed"))
    String.(config["arms"]["order"]) == collect(ARMS) ||
        throw(ArgumentError("arm order changed"))
    config
end

split_config_path(config) = joinpath(dirname(HERE), "rq2_gd_offset_split_001",
                                     "config.toml")

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
              stage === :heldout ? config["heldout"] :
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
        "codex_freeze_table" => file_sha256(String(
            protocol["split_freeze_input_table"])) ==
            String(protocol["split_freeze_input_table_sha256"]),
    )
    split = load_split_config(config)
    legacy_gate = Legacy.source_gate(split)
    checks["retained_static_sources"] = Bool(legacy_gate["passed"])
    Dict("passed" => all(values(checks)), "checks" => checks,
         "retained_source_gate" => legacy_gate)
end

function solver_keywords(split)
    pg = split["projected_gradient"]
    validation = split["validation"]
    (; maximum_updates=Int(pg["maximum_update_attempts"]),
       initial_step=Float64(pg["initial_step"]),
       maximum_backtracks=Int(pg["maximum_backtracks"]),
       mean_tolerance=Float64(validation["mean_offset_tolerance"]),
       box_tolerance=Float64(validation["box_tolerance"]))
end

problem_for(split, code, llr) = BridgeProblem(code, llr;
    parity_weight=Float64(split["projected_gradient"]["parity_weight"]),
    binary_weight=Float64(split["projected_gradient"]["binary_weight"]))

# ---------------------------------------------------------------------------
# Null-structure kernel: the retained compound kernel plus one hook per mode
# ---------------------------------------------------------------------------

"""Reassign each bit's offsets among that bit's checks by a random derangement.

Degree 1 is left alone, degree 2 is swapped, degree 3 takes one of the two
cyclic shifts, and larger degrees draw a uniform derangement by rejection.
The multiset of offsets at every bit, hence every projection interval and
every zero-sum constraint, is unchanged; only the check assignment moves.
"""
function permute_offsets!(delta_rows, problem::BridgeProblem, rng::AbstractRNG)
    moved = 0                       # edges whose value changed
    unmoved = 0                     # edges whose value did not (duplicates, zeros)
    distinguishable_bits = 0        # bits with at least two distinct offsets
    unchanged_distinguishable = 0   # of those, bits whose assignment did not change
    multiset_preserved = true
    values = Float64[]
    permuted = Float64[]
    for incident in problem.var_edges
        degree = length(incident)
        degree >= 2 || continue
        resize!(values, degree)
        resize!(permuted, degree)
        for (position, (check_index, slot)) in enumerate(incident)
            values[position] = delta_rows[check_index][slot]
        end
        perm = derangement(rng, degree)
        for position in 1:degree
            permuted[position] = values[perm[position]]
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
    (; moved, unmoved, distinguishable_bits, unchanged_distinguishable,
       multiset_preserved)
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

function solve_null_variant(problem::BridgeProblem, code,
                            initial::AbstractVector{<:Real}, mode::Symbol;
                            permutation_seed::Int=0,
                            maximum_updates::Int=30,
                            initial_step::Float64=0.2,
                            maximum_backtracks::Int=16,
                            collect_trace::Bool=true,
                            collect_diagnostics::Bool=true,
                            mean_tolerance::Float64=2.0e-12,
                            box_tolerance::Float64=2.0e-14,
                            snapshot_updates=Set{Int}())
    mode in (:reference, :permuted, :frozen) ||
        throw(ArgumentError("unknown null mode $mode"))
    spec = COMPOUND_SPEC
    rng = MersenneTwister(permutation_seed)
    n = length(problem.llr)
    x = clamp.(Float64.(initial), -1.0, 1.0)
    trial = similar(x)
    raw_trial = similar(x)
    direction = similar(x)
    lower = similar(x)
    upper = similar(x)
    delta = Legacy.zero_edge_rows(problem.check_vars)
    delta_next = Legacy.zero_edge_rows(problem.check_vars)
    q_rows = Legacy.zero_edge_rows(problem.check_vars)
    before_workspace = Legacy.EvalWorkspace(problem)
    trial_workspace = Legacy.EvalWorkspace(problem)
    trace_rows = Dict{String,Any}[]
    snapshots = Dict{Int,Any}()
    0 in snapshot_updates && (snapshots[0] =
        (x=copy(x), delta=Legacy.copy_edge_rows(delta)))
    accepted_steps = 0
    offset_refreshes = 0
    status = "steps_completed"
    all_projection_feasible = true
    all_refreshed_readings = true
    all_mean_constraints = true
    all_offsets_fixed = true
    all_multisets_preserved = true
    permutation_moved_edges = 0
    permutation_unmoved_edges = 0
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

        @inbounds for bit in eachindex(x)
            direction[bit] = -before.gradient[bit] / problem.curvature_bound[bit]
        end
        Legacy.scalar_intervals!(lower, upper, problem, delta;
            consume_offsets=true)
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
                    consume_offsets=true, tolerance=box_tolerance)
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
                "delta_before_sha256" => delta_hash_before,
                "delta_after_sha256" => delta_hash_before,
                "offset_refreshed" => false,
                "offsets_fixed_during_calculation" => offsets_fixed,
                "nonzero_offsets_before" => nonzero_before,
                "nonzero_offsets_after" => nonzero_before,
                "permutation_moved_edges" => 0,
                "permutation_unmoved_edges" => 0,
                "maximum_offset_sum_error" => 0.0,
                "refreshed_readings_in_box" => true,
            ))
            break
        end

        # --- the single hook per mode ------------------------------------
        refresh = mode !== :frozen || accepted_steps == 0
        moved = unmoved = 0
        mean_error = 0.0
        nonzero_after = nonzero_before
        refreshed_readings = true
        if refresh
            construction = Legacy.construct_offsets!(delta_next, q_rows, problem,
                x, trial, accepted_step, before;
                tolerance=mean_tolerance, collect_diagnostics)
            if mode === :permuted
                permutation = permute_offsets!(delta_next, problem, rng)
                moved = permutation.moved
                unmoved = permutation.unmoved
                all_multisets_preserved &= permutation.multiset_preserved
                permutation_moved_edges += moved
                permutation_unmoved_edges += unmoved
                permutation_distinguishable_bits += permutation.distinguishable_bits
                permutation_unchanged_distinguishable_bits +=
                    permutation.unchanged_distinguishable
            end
            mean_error = collect_diagnostics ?
                maximum_offset_sum_error(delta_next, problem) : 0.0
            all_mean_constraints &= !collect_diagnostics ||
                mean_error <= mean_tolerance
            nonzero_after = collect_diagnostics ?
                count(value -> !iszero(value),
                      Legacy.flatten_edge_rows(delta_next)) : 0
            offset_refreshes += 1
        else
            for (row_next, row) in zip(delta_next, delta)
                copyto!(row_next, row)
            end
        end
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
            "delta_before_sha256" => delta_hash_before,
            "delta_after_sha256" => delta_hash_after,
            "offset_refreshed" => refresh,
            "offsets_fixed_during_calculation" => offsets_fixed,
            "nonzero_offsets_before" => nonzero_before,
            "nonzero_offsets_after" => nonzero_after,
            "permutation_moved_edges" => moved,
            "permutation_unmoved_edges" => unmoved,
            "maximum_offset_sum_error" => mean_error,
            "refreshed_readings_in_box" => refreshed_readings,
        ))
        x, trial = trial, x
        delta, delta_next = delta_next, delta
        update in snapshot_updates && (snapshots[update] =
            (x=copy(x), delta=Legacy.copy_edge_rows(delta)))
    end

    terminal_workspace = Legacy.EvalWorkspace(problem)
    terminal = Legacy.bridge_evaluate!(terminal_workspace, problem, x, delta;
        consume_offsets=true)
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
    (; mode, spec, x=copy(x), delta=Legacy.copy_edge_rows(delta), hard,
       syndrome=independent_syndrome, syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       coded_bit_errors=count(hard),
       accepted_steps, offset_refreshes, requested_steps=maximum_updates, status,
       initial_loss, last_accepted_fixed_offset_loss=last_accepted_loss,
       terminal_refreshed_loss=terminal.loss,
       fractional_bits=count(value -> abs(value) < 0.999, x),
       trace=trace_rows, snapshots,
       all_projection_feasibility_checks_passed=all_projection_feasible,
       all_refreshed_readings_in_box=all_refreshed_readings,
       all_mean_constraints_passed=all_mean_constraints,
       all_offsets_fixed_during_calculation=all_offsets_fixed,
       all_multisets_preserved,
       permutation_moved_edges, permutation_unmoved_edges,
       permutation_distinguishable_bits,
       permutation_unchanged_distinguishable_bits,
       maximum_objective_reading_excess, objective_readings_outside_count,
       terminal_offset_l2_norm=norm(Legacy.flatten_edge_rows(delta)),
       operation_counts=Split.operation_counts(problem, trace_rows, spec),
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
       offset_refreshes=result.accepted_steps,
       result.requested_steps, result.status, result.initial_loss,
       result.last_accepted_fixed_offset_loss, result.terminal_refreshed_loss,
       result.fractional_bits, trace=retained_trace(result.trace),
       result.snapshots,
       result.all_projection_feasibility_checks_passed,
       result.all_refreshed_readings_in_box,
       result.all_mean_constraints_passed,
       result.all_offsets_fixed_during_calculation,
       all_multisets_preserved=true,
       permutation_moved_edges=0, permutation_unmoved_edges=0,
       permutation_distinguishable_bits=0,
       permutation_unchanged_distinguishable_bits=0,
       result.maximum_objective_reading_excess,
       result.objective_readings_outside_count,
       result.terminal_offset_l2_norm, result.operation_counts,
       result.logical_persistent_scalar_values,
       result.logical_persistent_edge_values)
end

function retained_trace(trace)
    rows = Dict{String,Any}[]
    for row in trace
        copied = Dict{String,Any}(row)
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
                 snapshot_updates=Set{Int}())
    keywords = solver_keywords(split)
    if arm == "control" || arm == "reference"
        spec = arm == "control" ? CONTROL_SPEC : COMPOUND_SPEC
        result = Split.solve_variant(problem, code, initial, spec;
            keywords..., collect_trace, collect_diagnostics,
            validate_derivatives=false, snapshot_updates)
        return retained_result(result, Symbol(arm))
    end
    seed = Int(config["arms"]["permutation_seed_base"]) + frame
    solve_null_variant(problem, code, initial, Symbol(arm);
        permutation_seed=seed, keywords..., collect_trace,
        collect_diagnostics, snapshot_updates)
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
       offset_refreshes=result.offset_refreshes,
       requested_steps=result.requested_steps,
       status=result.status,
       fractional_bits=result.fractional_bits,
       initial_objective=result.initial_loss,
       last_accepted_fixed_offset_objective=result.last_accepted_fixed_offset_loss,
       terminal_refreshed_objective=result.terminal_refreshed_loss,
       all_projection_feasibility_checks_passed=
           result.all_projection_feasibility_checks_passed,
       all_refreshed_readings_in_box=result.all_refreshed_readings_in_box,
       all_mean_constraints_passed=result.all_mean_constraints_passed,
       all_offsets_fixed_during_calculation=
           result.all_offsets_fixed_during_calculation,
       all_multisets_preserved=result.all_multisets_preserved,
       permutation_moved_edges=result.permutation_moved_edges,
       permutation_unmoved_edges=result.permutation_unmoved_edges,
       permutation_distinguishable_bits=result.permutation_distinguishable_bits,
       permutation_unchanged_distinguishable_bits=
           result.permutation_unchanged_distinguishable_bits,
       maximum_objective_reading_excess=result.maximum_objective_reading_excess,
       objective_readings_outside_count=result.objective_readings_outside_count,
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
            offset_refreshed=Bool(row["offset_refreshed"]),
            offsets_fixed_during_calculation=
                Bool(row["offsets_fixed_during_calculation"]),
            nonzero_offsets_before=Int(row["nonzero_offsets_before"]),
            nonzero_offsets_after=Int(row["nonzero_offsets_after"]),
            permutation_moved_edges=Int(row["permutation_moved_edges"]),
            permutation_unmoved_edges=Int(row["permutation_unmoved_edges"]),
            maximum_offset_sum_error=Float64(row["maximum_offset_sum_error"]),
            refreshed_readings_in_box=Bool(row["refreshed_readings_in_box"]),
            x_before_sha256=String(row["x_before_sha256"]),
            x_after_sha256=String(row["x_after_sha256"]),
            delta_before_sha256=String(row["delta_before_sha256"]),
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

"""Per-frame gates on the relation among the four arms."""
function frame_gates(results, problem)
    control = results["control"]; reference = results["reference"]
    permuted = results["permuted"]; frozen = results["frozen"]
    arms = (control, reference, permuted, frozen)
    x1 = [trace_value(r, 1, "x_after_sha256") for r in arms]
    d1 = [trace_value(r, 1, "delta_after_sha256") for r in (control, reference, frozen)]
    x2_reference = trace_value(reference, 2, "x_after_sha256")
    x2_frozen = trace_value(frozen, 2, "x_after_sha256")
    x2_permuted = trace_value(permuted, 2, "x_after_sha256")
    frozen_delta = [String(row["delta_after_sha256"])
                    for row in frozen.trace if Bool(row["accepted"])]
    permuted_multiset = haskey(permuted.snapshots, 1) && haskey(reference.snapshots, 1) ?
        per_bit_sorted_offsets(permuted.snapshots[1].delta, problem) ==
            per_bit_sorted_offsets(reference.snapshots[1].delta, problem) : true
    Dict{String,Bool}(
        "all_arms_equal_through_update_1" => all(!isnothing, x1) && allequal(x1),
        "unpermuted_offsets_equal_after_update_1" =>
            all(!isnothing, d1) && allequal(d1),
        "permuted_multiset_equal_after_update_1" => permuted_multiset &&
            permuted.all_multisets_preserved,
        "permuted_assignment_changed_at_every_distinguishable_bit" =>
            permuted.permutation_distinguishable_bits > 0 &&
            permuted.permutation_unchanged_distinguishable_bits == 0,
        "frozen_equals_reference_through_update_2" =>
            x2_reference !== nothing && x2_reference == x2_frozen,
        "frozen_offsets_constant_after_first_refresh" =>
            !isempty(frozen_delta) && allequal(frozen_delta),
        "frozen_single_refresh" => frozen.offset_refreshes == min(1, frozen.accepted_steps),
        "permuted_diverges_at_update_2" =>
            x2_reference === nothing || x2_permuted === nothing ||
            x2_permuted != x2_reference,
        "projection_feasible_all_arms" =>
            all(r.all_projection_feasibility_checks_passed for r in arms),
        "refreshed_readings_in_box_all_arms" =>
            all(r.all_refreshed_readings_in_box for r in arms),
        "mean_constraints_all_arms" =>
            all(r.all_mean_constraints_passed for r in arms),
        "offsets_fixed_during_calculation_all_arms" =>
            all(r.all_offsets_fixed_during_calculation for r in arms),
        "compound_readings_in_box" =>
            all(r.objective_readings_outside_count == 0
                for r in (reference, permuted, frozen)),
    )
end

function paired_counts(frame_rows, field::Symbol, treatment, reference)
    Split.paired_endpoint_counts(frame_rows, field, treatment, reference)
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
            "mean_offset_refreshes" => isempty(rows) ? 0.0 :
                mean(r.offset_refreshes for r in rows),
        )
    end
    counts
end

# ---------------------------------------------------------------------------
# Freeze
# ---------------------------------------------------------------------------

function authored_source_paths(config_path::AbstractString)
    Dict("config.toml" => abspath(config_path),
         "experiment_card.md" => CARD_PATH,
         "rq2_gd_offset_null_001.jl" => RUNNER_PATH,
         "test_rq2_gd_offset_null_001.jl" => TEST_PATH)
end

function freeze_source_paths(config, config_path)
    paths = authored_source_paths(config_path)
    paths["retained/rq2_gd_offset_split_001.jl"] = SPLIT_RUNNER_PATH
    paths["retained/rq2_gd_state_use_001.jl"] = Split.LEGACY_RUNNER_PATH
    paths["retained/split_config.toml"] = split_config_path(config)
    paths["retained/split_input_freeze.csv"] =
        String(config["protocol"]["split_freeze_input_table"])
    paths
end

function input_rows(config, split, native, code)
    rows = NamedTuple[]
    for (set_name, frames) in (("anchor", stage_frames(config, :anchor)),
                               ("heldout", stage_frames(config, :heldout)))
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
                       command::AbstractString="freeze")
    output = abspath(output)
    ispath(output) && throw(ArgumentError("freeze output already exists: $output"))
    config = load_config(config_path)
    gate = source_gate(config)
    gate["passed"] || throw(ArgumentError("source gate failed: $(gate["checks"])"))
    split = load_split_config(config)
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = Legacy.make_code(split, native)
    rows = input_rows(config, split, native, generated.code)
    mkpath(dirname(output)); mkdir(output)
    input_path = joinpath(output, "input_freeze.csv")
    write_csv(input_path, rows, propertynames(first(rows)))
    same_as_split = file_sha256(input_path) ==
        String(config["protocol"]["split_freeze_input_table_sha256"])
    same_as_split || throw(ArgumentError(
        "regenerated input table differs from the retained split freeze"))
    source_directory = joinpath(output, "source"); mkdir(source_directory)
    records = Legacy.archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["freeze_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "created_utc" => string(now(UTC)), "command" => String(command),
        "configuration_sha256" => file_sha256(config_path),
        "input_freeze_sha256" => file_sha256(input_path),
        "input_table_identical_to_split_freeze" => same_as_split,
        "input_row_count" => length(rows),
        "graph_sha256" => Legacy.graph_sha256(generated.code.check_vars),
        "environment" => environment_record(split),
        "source_gate" => gate, "sources" => records)
    open(joinpath(output, "freeze_manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    written = Legacy.write_checksum_manifest(output)
    Dict("output" => output, "input_rows" => length(rows),
         "input_freeze_sha256" => file_sha256(input_path),
         "checksum_entries" => length(written.entries))
end

function validate_freeze(config, freeze::AbstractString; config_path=DEFAULT_CONFIG)
    freeze = abspath(freeze)
    checksum = Legacy.verify_checksum_manifest(freeze)
    manifest = TOML.parsefile(joinpath(freeze, "freeze_manifest.toml"))
    table_path = joinpath(freeze, "input_freeze.csv")
    frozen = Dict(String(r["label"]) => r for r in manifest["sources"])
    authored_ok = true
    for (label, path) in authored_source_paths(config_path)
        ok = haskey(frozen, label) && isfile(path) &&
            file_sha256(path) == String(frozen[label]["sha256"])
        authored_ok &= ok
    end
    checks = Dict{String,Bool}(
        "checksum_manifest" => Bool(checksum["passed"]),
        "experiment" => manifest["experiment_id"] == config["experiment_id"],
        "configuration" => manifest["configuration_sha256"] == file_sha256(config_path),
        "input_table_hash" => manifest["input_freeze_sha256"] == file_sha256(table_path),
        "input_table_identical_to_split_freeze" => file_sha256(table_path) ==
            String(config["protocol"]["split_freeze_input_table_sha256"]),
        "input_row_count" => length(parse_simple_csv(table_path)) ==
            length(stage_frames(config, :anchor)) + length(stage_frames(config, :heldout)),
        "current_source_gate" => Bool(source_gate(config)["passed"]),
        "authored_sources_equal_freeze" => authored_ok)
    Dict("passed" => all(values(checks)), "checks" => checks, "manifest" => manifest)
end

# ---------------------------------------------------------------------------
# Scientific execution
# ---------------------------------------------------------------------------

function write_progress(path, payload)
    path === nothing && return
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, payload; sorted=true)
    end
    mv(temporary, path; force=true)
end

function calculate_science(config, freeze::AbstractString, stage::Symbol;
                           collect_runtime::Bool, config_path=DEFAULT_CONFIG,
                           progress_path=nothing, pass_name="primary",
                           started_utc::AbstractString="")
    validation = validate_freeze(config, freeze; config_path)
    validation["passed"] || throw(ArgumentError(
        "frozen input gate failed: $(validation["checks"])"))
    split = load_split_config(config)
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = Legacy.make_code(split, native)
    code = generated.code
    information_positions = Legacy.native_call(native, :_message_positions, code)
    frames = stage_frames(config, stage)
    esn0 = Float64(split["channel"]["physical_esn0_db"])
    frozen_table = Dict(parse(Int, row.frame) => row
                        for row in parse_simple_csv(joinpath(freeze, "input_freeze.csv")))
    keywords = solver_keywords(split)
    started = isempty(started_utc) ? string(now(UTC)) : String(started_utc)
    progress = (completed, frame, arm) -> write_progress(progress_path, Dict(
        "schema_version" => String(config["provenance"]["progress_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "pass" => String(pass_name),
        "status" => "running", "frames_completed" => completed,
        "frames_total" => length(frames), "current_frame" => frame,
        "current_arm" => arm, "started_utc" => started,
        "updated_utc" => string(now(UTC)), "process_id" => getpid()))

    if collect_runtime
        warm_llr = [2sin(0.013bit) + 0.4cos(0.031bit) for bit in 1:code.n]
        warm_problem = problem_for(split, code, warm_llr)
        for arm in ARMS
            run_arm(arm, warm_problem, code, tanh.(warm_llr ./ 2), 0, split, config;
                collect_trace=false, collect_diagnostics=false)
        end
    end

    frame_rows = NamedTuple[]
    iteration_rows_all = NamedTuple[]
    runtime_rows = NamedTuple[]
    gate_records = Dict{String,Any}[]
    gates_all = Dict{String,Bool}()
    kernel_equivalence_checked = 0
    kernel_equivalence_passed = true
    frozen_inputs_ok = true
    for (position, frame) in enumerate(frames)
        progress(position - 1, frame, "")
        input = Legacy.generate_input(split, native, code, frame)
        frozen_row = frozen_table[frame]
        frozen_inputs_ok &= frozen_row.clipped_llr_sha256 ==
            input.identities.clipped_llr_sha256 &&
            frozen_row.received_sha256 == input.identities.received_sha256
        problem = problem_for(split, code, input.clipped_llr)
        initial = tanh.(input.clipped_llr ./ 2)
        if collect_runtime
            rotation = mod(position - 1, length(ARMS))
            for (order_position, arm) in enumerate(circshift(collect(ARMS), -rotation))
                timed = @timed run_arm(arm, problem, code, initial, frame, split,
                    config; collect_trace=false, collect_diagnostics=false)
                push!(runtime_rows, (; frame, arm, order_position,
                    seconds=Float64(timed.time), allocated_bytes=Int(timed.bytes)))
            end
        end
        results = Dict{String,Any}()
        snapshot_set = Set([1, 2])
        for arm in ARMS
            results[arm] = run_arm(arm, problem, code, initial, frame, split, config;
                snapshot_updates=snapshot_set)
            progress(position - 1, frame, arm)
        end
        if stage === :anchor
            # The copied kernel in reference mode must reproduce the retained
            # kernel's compound arm bit for bit.
            copy = solve_null_variant(problem, code, initial, :reference;
                keywords..., snapshot_updates=snapshot_set)
            kernel_equivalence_checked += 1
            kernel_equivalence_passed &=
                vector_sha256(copy.x) == vector_sha256(results["reference"].x) &&
                edge_sha256(copy.delta) == edge_sha256(results["reference"].delta) &&
                copy.hard == results["reference"].hard
        end
        gates = frame_gates(results, problem)
        for (key, value) in gates
            gates_all[key] = get(gates_all, key, true) & value
        end
        push!(gate_records, Dict("frame" => frame, "gates" => gates))
        for arm in ARMS
            push!(frame_rows, frame_row(frame, arm, input, results[arm],
                information_positions, esn0))
            append!(iteration_rows_all, iteration_rows(frame, arm, results[arm]))
        end
        progress(position, frame, "complete")
    end

    gates_all["frozen_inputs_regenerated_identically"] = frozen_inputs_ok
    gates_all["copied_kernel_equals_retained_kernel"] =
        stage !== :anchor || (kernel_equivalence_checked == length(frames) &&
                              kernel_equivalence_passed)
    gates_all["every_frame_has_each_arm_once"] =
        length(frame_rows) == length(frames) * length(ARMS)
    table = contrast_table(frame_rows)
    stage === :heldout && add_inference!(table,
        Float64(config["inference"]["pairwise_interval_confidence_level"]))
    science = Dict{String,Any}(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "frame_first" => first(frames),
        "frame_last" => last(frames), "frame_count" => length(frames),
        "arms" => collect(ARMS), "physical_esn0_db" => esn0,
        "arm_outcomes" => arm_success_counts(frame_rows),
        "endpoints" => table,
        "correctness_gates" => gates_all,
        "correctness_passed" => all(values(gates_all)),
        "frame_gates" => gate_records,
        "hard_words" => Dict(arm => [row.hard_word_sha256 for row in frame_rows
                                     if row.arm == arm] for arm in ARMS),
        "anchor_expansion_authorized" => false)
    (; science, frame_rows, iteration_rows=iteration_rows_all, runtime_rows)
end

function write_result(output, config, config_path, freeze, stage, calculated,
                      replay_hash, replay_passed, command; anchor_result=nothing)
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
            holm_p=get(c, "holm_adjusted_pvalue", NaN)))
    end
    write_csv(joinpath(output, "aggregate.csv"), aggregates,
              propertynames(first(aggregates)))
    split = load_split_config(config)
    source_directory = joinpath(output, "source"); mkdir(source_directory)
    records = Legacy.archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "created_utc" => string(now(UTC)),
        "command" => String(command), "freeze" => abspath(freeze),
        "freeze_manifest_sha256" => file_sha256(joinpath(freeze, "freeze_manifest.toml")),
        "anchor_result" => anchor_result === nothing ? "" : abspath(anchor_result),
        "base_scientific_sha256" => base_hash,
        "stored_scientific_sha256" => scientific_sha256(science),
        "environment" => environment_record(split),
        "sources" => records,
        "progress_excluded_from_checksums" => false)
    open(joinpath(output, "manifest.toml"), "w") do io
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
        "science_sha256" => file_sha256(science_path))
    open(joinpath(output, "COMPLETED.toml"), "w") do io
        TOML.print(io, completion; sorted=true)
    end
    write_progress(joinpath(output, "progress.toml"), Dict(
        "schema_version" => String(config["provenance"]["progress_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "pass" => "artifact_write", "status" => status,
        "frames_completed" => Int(science["frame_count"]),
        "frames_total" => Int(science["frame_count"]),
        "updated_utc" => string(now(UTC))))
    checksums = Legacy.write_checksum_manifest(output)
    (; output, science, completion, checksum_entries=length(checksums.entries))
end

function validate_anchor_handoff(config, anchor_result, freeze)
    checksum = Legacy.verify_checksum_manifest(anchor_result)
    completion = TOML.parsefile(joinpath(anchor_result, "COMPLETED.toml"))
    manifest = TOML.parsefile(joinpath(anchor_result, "manifest.toml"))
    checks = Dict(
        "checksums" => Bool(checksum["passed"]),
        "experiment" => completion["experiment_id"] == config["experiment_id"],
        "stage" => completion["stage"] == "anchor",
        "status" => completion["status"] == "complete_valid",
        "expansion" => completion["anchor_expansion_authorized"] == true,
        "freeze" => manifest["freeze_manifest_sha256"] ==
            file_sha256(joinpath(freeze, "freeze_manifest.toml")))
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function run_stage(stage::Symbol, output, freeze; config_path=DEFAULT_CONFIG,
                   anchor_result=nothing, command=String(stage))
    config = load_config(config_path)
    output = abspath(output)
    ispath(output) && throw(ArgumentError("result output already exists: $output"))
    if stage === :heldout
        anchor_result === nothing && throw(ArgumentError(
            "held-out execution requires --anchor-result"))
        handoff = validate_anchor_handoff(config, anchor_result, freeze)
        handoff["passed"] || throw(ArgumentError(
            "anchor did not authorize held-out execution: $(handoff["checks"])"))
    end
    mkpath(dirname(output)); mkdir(output)
    progress_path = joinpath(output, "progress.toml")
    started = string(now(UTC))
    try
        calculated = calculate_science(config, freeze, stage;
            collect_runtime=true, config_path, progress_path,
            pass_name="primary", started_utc=started)
        replay = calculate_science(config, freeze, stage;
            collect_runtime=false, config_path, progress_path,
            pass_name="replay", started_utc=started)
        first_hash = scientific_sha256(calculated.science)
        replay_hash = scientific_sha256(replay.science)
        write_result(output, config, config_path, freeze, stage, calculated,
            replay_hash, first_hash == replay_hash, String(command); anchor_result)
    catch exception
        write_progress(progress_path, Dict("stage" => String(stage),
            "status" => "failed", "error" => sprint(showerror, exception),
            "updated_utc" => string(now(UTC))))
        rethrow()
    end
end

function verify_result(result; config_path=DEFAULT_CONFIG)
    config = load_config(config_path)
    checksum = Legacy.verify_checksum_manifest(result)
    completion = TOML.parsefile(joinpath(result, "COMPLETED.toml"))
    science = TOML.parsefile(joinpath(result, "manifest.toml"))
    passed = Bool(checksum["passed"]) && completion["status"] == "complete_valid" &&
        completion["experiment_id"] == config["experiment_id"] &&
        completion["science_sha256"] == file_sha256(joinpath(result, "science.json"))
    Dict("passed" => passed, "checksum" => checksum, "completion" => completion,
         "stored_scientific_sha256" => science["stored_scientific_sha256"])
end

function usage()
    "usage:\n" *
    "  rq2_gd_offset_null_001.jl preflight-probe [--config FILE]\n" *
    "  rq2_gd_offset_null_001.jl freeze --output DIR\n" *
    "  rq2_gd_offset_null_001.jl anchor --freeze DIR --output DIR\n" *
    "  rq2_gd_offset_null_001.jl heldout --freeze DIR --anchor-result DIR --output DIR\n" *
    "  rq2_gd_offset_null_001.jl verify --result DIR"
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
        return 0
    elseif parsed.mode === :freeze
        output = get(parsed.options, "output", nothing)
        output === nothing && throw(ArgumentError("freeze requires --output"))
        frozen = freeze_inputs(output; config_path, command)
        println("frozen input rows: ", frozen["input_rows"])
        println("input table SHA-256: ", frozen["input_freeze_sha256"])
        return 0
    elseif parsed.mode in (:anchor, :heldout)
        freeze = get(parsed.options, "freeze", nothing)
        output = get(parsed.options, "output", nothing)
        (freeze === nothing || output === nothing) &&
            throw(ArgumentError("$(parsed.mode) requires --freeze and --output"))
        written = run_stage(parsed.mode, output, freeze; config_path,
            anchor_result=get(parsed.options, "anchor-result", nothing), command)
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
