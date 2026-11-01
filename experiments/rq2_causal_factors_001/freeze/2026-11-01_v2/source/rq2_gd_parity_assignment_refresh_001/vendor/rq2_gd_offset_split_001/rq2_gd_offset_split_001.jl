#!/usr/bin/env julia

module RQ2GDOffsetSplit001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using Statistics
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__
const TEST_PATH = joinpath(HERE, "test_rq2_gd_offset_split_001.jl")
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const PREFLIGHT_PATH = joinpath(HERE, "preflight_validation.md")
const LEGACY_RUNNER_PATH = joinpath(dirname(HERE), "rq2_gd_state_use_001",
                                    "rq2_gd_state_use_001.jl")

# Reuse the validated numerical primitives and stable serializers from the
# retained two-arm experiment.  This experiment owns a new solver schedule,
# provenance record, and result schema; it does not modify the retained source
# or terminal result.
include(LEGACY_RUNNER_PATH)
const Legacy = RQ2GDStateUse001

export VariantSpec, arm_specs, load_config, source_gate, preflight_gate,
       BridgeProblem, bridge_evaluate!, solve_variant, paired_endpoint_counts,
       factorial_interaction, atomic_write_progress, PhaseTracker,
       begin_phase!, phase_progress!, finish_phase!, freeze_inputs,
       write_primary_checkpoint, run_stage, replay_result, main

const BridgeProblem = Legacy.BridgeProblem
const EvalWorkspace = Legacy.EvalWorkspace
const bridge_evaluate! = Legacy.bridge_evaluate!
const bounded_mean_projection = Legacy.bounded_mean_projection
const independent_bounded_mean_projection = Legacy.independent_bounded_mean_projection
const vector_sha256 = Legacy.vector_sha256
const edge_sha256 = Legacy.edge_sha256
const file_sha256 = Legacy.file_sha256
const scientific_sha256 = Legacy.scientific_sha256
const canonical_json = Legacy.canonical_json
const write_new_file = Legacy.write_new_file
const write_csv = Legacy.write_csv
const parse_simple_csv = Legacy.parse_simple_csv
const float64_hex = Legacy.float64_hex
const git_output = Legacy.git_output
const zero_edge_rows = Legacy.zero_edge_rows
const copy_edge_rows = Legacy.copy_edge_rows
const flatten_edge_rows = Legacy.flatten_edge_rows
const readings_in_box = Legacy.readings_in_box
const scalar_intervals! = Legacy.scalar_intervals!
const construct_offsets! = Legacy.construct_offsets!
const finite_difference_maximum = Legacy.finite_difference_maximum
const syndrome_vector = Legacy.syndrome_vector
const hard_decision_independent = Legacy.hard_decision_independent
const native_trace = Legacy.native_trace
const native_call = Legacy.native_call
const graph_sha256 = Legacy.graph_sha256
const archive_sources = Legacy.archive_sources

struct VariantSpec
    name::String
    objective_uses_offsets::Bool
    projection_uses_offset_bounds::Bool
end

const REQUIRED_ARMS = (
    VariantSpec("objective0__bounds0", false, false),
    VariantSpec("objective1__bounds0", true, false),
    VariantSpec("objective0__bounds1", false, true),
    VariantSpec("objective1__bounds1", true, true),
)

const RETAINED_RESULT_SPECS = (
    ("prior_anchor_completion", "prior_anchor_result", "COMPLETED.toml"),
    ("prior_anchor_science", "prior_anchor_result", "science.json"),
    ("prior_anchor_frames", "prior_anchor_result", "frames.csv"),
    ("prior_anchor_iterations", "prior_anchor_result", "iterations.csv"),
    ("prior_anchor_checksum_manifest", "prior_anchor_result", "MANIFEST.sha256"),
    ("prior_heldout_completion", "prior_heldout_result", "COMPLETED.toml"),
    ("prior_heldout_science", "prior_heldout_result", "science.json"),
    ("prior_heldout_aggregate", "prior_heldout_result", "aggregate.csv"),
    ("prior_heldout_frames", "prior_heldout_result", "frames.csv"),
    ("prior_heldout_iterations", "prior_heldout_result", "iterations.csv"),
    ("prior_heldout_manifest", "prior_heldout_result", "manifest.toml"),
    ("prior_heldout_checksum_manifest", "prior_heldout_result", "MANIFEST.sha256"),
)

function arm_specs(config)
    factorial = config["factorial"]
    order = String.(factorial["arm_order"])
    expected = [spec.name for spec in REQUIRED_ARMS]
    order == expected || throw(ArgumentError(
        "factorial arm order changed: expected $(join(expected, ", "))"))
    if haskey(factorial, "arms")
        registered = factorial["arms"]
        for spec in REQUIRED_ARMS
            haskey(registered, spec.name) || throw(ArgumentError(
                "factorial arm is missing: $(spec.name)"))
            record = registered[spec.name]
            Bool(record["objective_uses_offsets"]) == spec.objective_uses_offsets ||
                throw(ArgumentError("objective switch changed for $(spec.name)"))
            Bool(record["projection_uses_offset_bounds"]) ==
                spec.projection_uses_offset_bounds || throw(ArgumentError(
                "projection-bound switch changed for $(spec.name)"))
        end
    end
    collect(REQUIRED_ARMS)
end

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq2-gd-offset-split-001/v1" ||
        throw(ArgumentError("unsupported RQ2 GD offset-split schema"))
    config["experiment_id"] == "RQ2-GD-OFFSET-SPLIT-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["research_question"] == "RQ2" ||
        throw(ArgumentError("experiment is not registered as RQ2"))
    config["scope"]["admm_included"] == false ||
        throw(ArgumentError("ADMM is outside this experiment"))
    config["scope"]["bp_arm_included"] == false ||
        throw(ArgumentError("a BP arm is outside this causal contrast"))
    config["anchor"]["frame_first"] == 20001 &&
        config["anchor"]["frame_last"] == 20024 ||
        throw(ArgumentError("anchor frame set changed"))
    config["heldout"]["frame_first"] == 30001 &&
        config["heldout"]["frame_last"] == 30200 ||
        throw(ArgumentError("held-out frame set changed"))
    arm_specs(config)
    config
end

function source_gate(config)
    base = Legacy.source_gate(config)
    records = copy(base["records"])
    passed = Bool(base["passed"])
    expected_legacy = String(config["optimization"][
        "optimized_legacy_runner_sha256"])
    actual_legacy = isfile(LEGACY_RUNNER_PATH) ?
        file_sha256(LEGACY_RUNNER_PATH) : "missing"
    legacy_equal = actual_legacy == expected_legacy
    passed &= legacy_equal
    push!(records, Dict(
        "label" => "optimized_legacy_runner",
        "path" => LEGACY_RUNNER_PATH,
        "expected_sha256" => expected_legacy,
        "actual_sha256" => actual_legacy,
        "passed" => legacy_equal,
    ))
    sources = config["sources"]
    for (label, root_key, relative) in RETAINED_RESULT_SPECS
        expected_key = label * "_sha256"
        haskey(sources, expected_key) || continue
        path = joinpath(String(sources[root_key]), relative)
        exists = isfile(path)
        actual = exists ? file_sha256(path) : "missing"
        expected = String(sources[expected_key])
        equal = exists && actual == expected
        passed &= equal
        push!(records, Dict(
            "label" => label,
            "path" => path,
            "expected_sha256" => expected,
            "actual_sha256" => actual,
            "passed" => equal,
        ))
    end
    result = copy(base)
    result["records"] = records
    result["passed"] = passed
    result
end
load_native(config) = Legacy.load_native(config)
make_code(config, native) = Legacy.make_code(config, native)
generate_input(config, native, code, frame::Integer) =
    Legacy.generate_input(config, native, code, frame)
enforce_thread_environment(config) = Legacy.enforce_thread_environment(config)

function preflight_gate(config_path::AbstractString=DEFAULT_CONFIG)
    isfile(PREFLIGHT_PATH) || return Dict(
        "passed" => false, "reason" => "missing_preflight_record")
    fields = Dict{String,String}()
    for line in eachline(PREFLIGHT_PATH)
        matched = match(r"^([a-z][a-z0-9_]*)[ ]*:[ ]*`?([^` ]+)`?[ ]*$", line)
        matched === nothing && continue
        fields[String(matched.captures[1])] = String(matched.captures[2])
    end
    expected = Dict(
        "validation_status" => "pass",
        "test_exit_code" => "0",
        "config_sha256" => file_sha256(config_path),
        "card_sha256" => file_sha256(CARD_PATH),
        "runner_sha256" => file_sha256(RUNNER_PATH),
        "test_sha256" => isfile(TEST_PATH) ? file_sha256(TEST_PATH) : "missing",
        "legacy_runner_sha256" => file_sha256(LEGACY_RUNNER_PATH),
    )
    checks = Dict(key => get(fields, key, "missing") == value
                  for (key, value) in expected)
    Dict("passed" => all(values(checks)), "checks" => checks,
         "recorded" => fields, "expected" => expected)
end

# ---------------------------------------------------------------------------
# Atomic progress journal
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

function atomic_write_progress(path::AbstractString;
                               stage::AbstractString,
                               pass_name::AbstractString,
                               status::AbstractString,
                               frames_completed::Int,
                               frames_total::Int,
                               current_frame::Int=0,
                               last_completed_frame::Int=0,
                               arms_completed::Int=0,
                               arms_total::Int=4,
                               started_utc::AbstractString="",
                               phase::AbstractString="",
                               phase_started_utc::AbstractString="",
                               previous_phase::AbstractString="",
                               previous_phase_elapsed_seconds::Real=0.0,
                               error::AbstractString="")
    now_text = string(now(UTC))
    started = isempty(started_utc) ? now_text : String(started_utc)
    payload = Dict{String,Any}(
        "schema_version" => "rq2-gd-offset-split-001/progress-v2",
        "experiment_id" => "RQ2-GD-OFFSET-SPLIT-001",
        "stage" => String(stage),
        "pass" => String(pass_name),
        "status" => String(status),
        "frames_completed" => frames_completed,
        "frames_total" => frames_total,
        "current_frame" => current_frame,
        "last_completed_frame" => last_completed_frame,
        "arms_completed_current_frame" => arms_completed,
        "arms_total" => arms_total,
        "process_id" => getpid(),
        "started_utc" => started,
        "updated_utc" => now_text,
        "phase" => String(phase),
        "phase_started_utc" => String(phase_started_utc),
        "previous_phase" => String(previous_phase),
        "previous_phase_elapsed_seconds" =>
            Float64(previous_phase_elapsed_seconds),
        "error" => String(error),
    )
    atomic_write_toml(path, payload)
    payload
end

function mark_progress_failed(path::AbstractString, stage::AbstractString,
                              frames_total::Int, started_utc::AbstractString,
                              exception)
    previous = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    atomic_write_progress(path;
        stage=String(stage),
        pass_name=String(get(previous, "pass", "failed")),
        status="failed",
        frames_completed=Int(get(previous, "frames_completed", 0)),
        frames_total=Int(get(previous, "frames_total", frames_total)),
        current_frame=Int(get(previous, "current_frame", 0)),
        last_completed_frame=Int(get(previous, "last_completed_frame", 0)),
        arms_completed=Int(get(previous, "arms_completed_current_frame", 0)),
        arms_total=Int(get(previous, "arms_total", length(REQUIRED_ARMS))),
        started_utc=String(get(previous, "started_utc", started_utc)),
        phase=String(get(previous, "phase", "failed")),
        phase_started_utc=String(get(previous, "phase_started_utc", "")),
        previous_phase=String(get(previous, "previous_phase", "")),
        previous_phase_elapsed_seconds=Float64(get(
            previous, "previous_phase_elapsed_seconds", 0.0)),
        error=sprint(showerror, exception))
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
    previous_phase_elapsed_seconds = 0.0
    if progress_path !== nothing && isfile(progress_path)
        prior = TOML.parsefile(progress_path)
        previous_phase = String(get(prior, "previous_phase", ""))
        previous_phase_elapsed_seconds = Float64(get(
            prior, "previous_phase_elapsed_seconds", 0.0))
    end
    PhaseTracker(progress_path, phase_log_path, String(stage),
        String(pass_name), String(run_started_utc), "", "", UInt64(0),
        previous_phase, previous_phase_elapsed_seconds, false)
end

function append_phase_event(path::Union{Nothing,String},
                            pass_name::AbstractString,
                            phase::AbstractString,
                            event::AbstractString,
                            seconds::Real)
    path === nothing && return nothing
    for field in (pass_name, phase, event)
        (occursin('\t', field) || occursin('\n', field) || occursin('\r', field)) &&
            throw(ArgumentError("phase-log fields cannot contain whitespace controls"))
    end
    mkpath(dirname(path))
    new_file = !isfile(path)
    open(path, "a") do io
        new_file && println(io, "utc\tpass\tphase\tseconds")
        phase_event = String(phase) * ":" * String(event)
        println(io, string(now(UTC)), '\t', String(pass_name), '\t',
                phase_event, '\t', @sprintf("%.9f", Float64(seconds)))
        flush(io)
        ccall(:fsync, Cint, (Cint,), fd(io)) == 0 ||
            error("cannot fsync phase log")
    end
    path
end

function close_current_phase!(tracker::PhaseTracker)
    tracker.phase_open || return tracker.previous_phase_elapsed_seconds
    elapsed = Float64(time_ns() - tracker.phase_started_ns) / 1.0e9
    append_phase_event(tracker.phase_log_path, tracker.pass_name,
                       tracker.phase, "end", elapsed)
    tracker.previous_phase = tracker.phase
    tracker.previous_phase_elapsed_seconds = elapsed
    tracker.phase_open = false
    elapsed
end

function phase_progress!(tracker::PhaseTracker;
                         status::AbstractString="running",
                         frames_completed::Int,
                         frames_total::Int,
                         current_frame::Int=0,
                         last_completed_frame::Int=0,
                         arms_completed::Int=0,
                         arms_total::Int=4)
    tracker.progress_path === nothing && return nothing
    atomic_write_progress(tracker.progress_path;
        stage=tracker.stage, pass_name=tracker.pass_name, status,
        frames_completed, frames_total, current_frame, last_completed_frame,
        arms_completed, arms_total, started_utc=tracker.run_started_utc,
        phase=tracker.phase, phase_started_utc=tracker.phase_started_utc,
        previous_phase=tracker.previous_phase,
        previous_phase_elapsed_seconds=
            tracker.previous_phase_elapsed_seconds)
end

function begin_phase!(tracker::PhaseTracker, phase::AbstractString;
                      status::AbstractString="running",
                      frames_completed::Int,
                      frames_total::Int,
                      current_frame::Int=0,
                      last_completed_frame::Int=0,
                      arms_completed::Int=0,
                      arms_total::Int=4)
    close_current_phase!(tracker)
    tracker.phase = String(phase)
    tracker.phase_started_utc = string(now(UTC))
    tracker.phase_started_ns = time_ns()
    tracker.phase_open = true
    append_phase_event(tracker.phase_log_path, tracker.pass_name,
                       tracker.phase, "start", 0.0)
    phase_progress!(tracker; status, frames_completed, frames_total,
                    current_frame, last_completed_frame, arms_completed,
                    arms_total)
end

function finish_phase!(tracker::PhaseTracker;
                       status::AbstractString="running",
                       frames_completed::Int,
                       frames_total::Int,
                       current_frame::Int=0,
                       last_completed_frame::Int=0,
                       arms_completed::Int=0,
                       arms_total::Int=4)
    close_current_phase!(tracker)
    phase_progress!(tracker; status, frames_completed, frames_total,
                    current_frame, last_completed_frame, arms_completed,
                    arms_total)
end

function result_checksum_entries(root::AbstractString)
    Legacy.checksum_manifest(root;
        exclude=Set(["MANIFEST.sha256", "progress.toml"]))
end

function write_result_checksum_manifest(root::AbstractString)
    path = joinpath(root, "MANIFEST.sha256")
    entries = result_checksum_entries(root)
    text = join(("$(last(entry))  $(first(entry))" for entry in entries), "\n") * "\n"
    write_new_file(path, text)
    (; path, entries)
end

function verify_result_checksum_manifest(root::AbstractString)
    manifest = joinpath(root, "MANIFEST.sha256")
    isfile(manifest) || return Dict("passed" => false,
        "reason" => "missing_manifest", "failures" => ["missing:MANIFEST.sha256"])
    failures = String[]
    listed = Set{String}()
    count = 0
    for line in readlines(manifest)
        isempty(line) && continue
        fields = split(line, "  "; limit=2)
        length(fields) == 2 || (push!(failures, "malformed:$line"); continue)
        expected, relative = fields
        push!(listed, relative)
        path = joinpath(root, relative)
        count += 1
        if !isfile(path)
            push!(failures, "missing:$relative")
        elseif file_sha256(path) != expected
            push!(failures, "hash:$relative")
        end
    end
    actual = Set(first(entry) for entry in result_checksum_entries(root))
    append!(failures, ("extra:$relative" for relative in sort!(collect(setdiff(actual, listed)))))
    append!(failures, ("missing:$relative" for relative in sort!(collect(setdiff(listed, actual)))
                       if !("missing:$relative" in failures)))
    Dict("passed" => isempty(failures), "entries" => count,
         "failures" => failures)
end

# ---------------------------------------------------------------------------
# Four-arm split solver
# ---------------------------------------------------------------------------

function operation_counts(problem::BridgeProblem, trace_rows, spec::VariantSpec)
    edges = sum(length, problem.check_vars)
    checks = length(problem.check_vars)
    n = length(problem.llr)
    evaluations = sum(Int(row["objective_evaluations"]) for row in trace_rows; init=0)
    accepted = count(row -> Bool(row["accepted"]), trace_rows)
    Dict(
        "objective_and_gradient_evaluations" => evaluations,
        "check_products" => evaluations * checks,
        "leave_one_products" => evaluations * edges,
        "parity_contribution_accumulations" => evaluations * edges,
        "offset_additions_to_parity_readings" =>
            spec.objective_uses_offsets ? evaluations * edges : 0,
        "offset_bound_intersections" =>
            spec.projection_uses_offset_bounds ? length(trace_rows) * edges : 0,
        "channel_contributions" => evaluations * n,
        "binary_contributions" => evaluations * n,
        "preconditioner_divisions" => length(trace_rows) * n,
        "scalar_projection_comparisons" =>
            sum((Int(row["trial_count"]) for row in trace_rows); init=0) * 2n,
        "offset_refreshes" => accepted,
        "bounded_mean_projection_bits" => accepted * n,
        "offset_values_constructed" => accepted * edges,
        "diagnostic_hashing_included" => false,
        "finite_difference_work_included" => false,
    )
end

function maximum_reading_excess(problem::BridgeProblem, x, delta_rows;
                                use_offsets::Bool)
    maximum_excess = 0.0
    count_outside = 0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            reading = Float64(x[bit]) +
                (use_offsets ? Float64(delta_rows[check_index][slot]) : 0.0)
            excess = max(0.0, abs(reading) - 1.0)
            maximum_excess = max(maximum_excess, excess)
            count_outside += excess > 0.0
        end
    end
    (; maximum_excess, count_outside)
end

trial_is_acceptable(projection_feasible::Bool, trial_loss::Real,
                    before_loss::Real) =
    projection_feasible && isfinite(trial_loss) && trial_loss < before_loss

function solve_variant(problem::BridgeProblem, code,
                       initial::AbstractVector{<:Real}, spec::VariantSpec;
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
    validate_derivatives && !collect_diagnostics && throw(ArgumentError(
        "finite-difference validation requires diagnostic collection"))
    n = length(problem.llr)
    x = clamp.(Float64.(initial), -1.0, 1.0)
    trial = similar(x)
    raw_trial = similar(x)
    direction = similar(x)
    lower = similar(x)
    upper = similar(x)
    delta = zero_edge_rows(problem.check_vars)
    delta_next = zero_edge_rows(problem.check_vars)
    q_rows = zero_edge_rows(problem.check_vars)
    before_workspace = EvalWorkspace(problem)
    trial_workspace = EvalWorkspace(problem)
    trace_rows = Dict{String,Any}[]
    snapshots = Dict{Int,Any}()
    0 in snapshot_updates && (snapshots[0] =
        (x=copy(x), delta=copy_edge_rows(delta)))
    accepted_steps = 0
    status = "steps_completed"
    all_projection_feasible = true
    all_refreshed_readings = true
    all_objective_readings = true
    all_mean_constraints = true
    all_finite_differences = true
    all_offsets_fixed = true
    maximum_objective_reading_excess = 0.0
    objective_readings_outside_count = 0
    first_objective_offset_use_update = nothing
    first_projection_offset_use_update = nothing
    initial_loss = NaN
    last_accepted_loss = NaN

    for update in 1:maximum_updates
        before = bridge_evaluate!(before_workspace, problem, x, delta;
            consume_offsets=spec.objective_uses_offsets)
        if update == 1
            initial_loss = before.loss
            last_accepted_loss = before.loss
        end
        need_hashes = collect_trace || validate_derivatives
        delta_hash_before = need_hashes ? edge_sha256(delta) : "not_collected"
        x_hash_before = need_hashes ? vector_sha256(x) : "not_collected"
        nonzero_before = collect_diagnostics ?
            count(value -> !iszero(value), flatten_edge_rows(delta)) : 0
        current_reading_excess = if collect_diagnostics &&
                spec.objective_uses_offsets
            maximum_reading_excess(problem, x, delta; use_offsets=true)
        else
            (; maximum_excess=0.0, count_outside=0)
        end
        maximum_objective_reading_excess = max(
            maximum_objective_reading_excess,
            current_reading_excess.maximum_excess)
        objective_readings_outside_count +=
            current_reading_excess.count_outside
        all_objective_readings &=
            current_reading_excess.count_outside == 0
        if collect_diagnostics && nonzero_before > 0
            if spec.objective_uses_offsets &&
                    first_objective_offset_use_update === nothing
                first_objective_offset_use_update = update
            end
            if spec.projection_uses_offset_bounds &&
                    first_projection_offset_use_update === nothing
                first_projection_offset_use_update = update
            end
        end
        fd = if validate_derivatives
            finite_difference_maximum(problem, x, delta, before.gradient;
                consume_offsets=spec.objective_uses_offsets,
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
            direction[bit] = -before.gradient[bit] /
                problem.curvature_bound[bit]
        end
        scalar_intervals!(lower, upper, problem, delta;
            consume_offsets=spec.projection_uses_offset_bounds)
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
        lower_hash = need_hashes ? vector_sha256(lower) : "not_collected"
        upper_hash = need_hashes ? vector_sha256(upper) : "not_collected"

        accepted = false
        accepted_step = 0.0
        accepted_loss = before.loss
        trial_count = 0
        all_trial_projection_feasible = true
        all_trial_objective_readings = true
        accepted_raw_hash = x_hash_before
        trial_maximum_reading_excess = 0.0
        trial_readings_outside_count = 0
        accepted_maximum_reading_excess = 0.0
        accepted_readings_outside_count = 0
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                raw_trial[bit] = x[bit] + step * direction[bit]
                trial[bit] = clamp(raw_trial[bit], lower[bit], upper[bit])
            end
            trial_count += 1
            trial_evaluation = bridge_evaluate!(trial_workspace, problem,
                trial, delta; consume_offsets=spec.objective_uses_offsets)
            projection_feasible = !collect_diagnostics || readings_in_box(
                problem, trial, delta;
                consume_offsets=spec.projection_uses_offset_bounds,
                tolerance=box_tolerance)
            objective_readings_in_box = !collect_diagnostics || readings_in_box(
                problem, trial, delta;
                consume_offsets=spec.objective_uses_offsets,
                tolerance=box_tolerance)
            all_trial_projection_feasible &= projection_feasible
            all_trial_objective_readings &= objective_readings_in_box
            if collect_diagnostics && spec.objective_uses_offsets
                excess = maximum_reading_excess(problem, trial, delta;
                    use_offsets=true)
                maximum_objective_reading_excess = max(
                    maximum_objective_reading_excess, excess.maximum_excess)
                objective_readings_outside_count += excess.count_outside
                trial_maximum_reading_excess = max(
                    trial_maximum_reading_excess, excess.maximum_excess)
                trial_readings_outside_count += excess.count_outside
            end
            # O1P0 deliberately evaluates the polynomial extension outside the
            # shifted-reading box.  Only the selected projection rule is an
            # acceptance constraint; objective-reading box status is diagnostic.
            if trial_is_acceptable(projection_feasible,
                                   trial_evaluation.loss, before.loss)
                accepted = true
                accepted_step = step
                accepted_loss = trial_evaluation.loss
                accepted_raw_hash = need_hashes ?
                    vector_sha256(raw_trial) : "not_collected"
                if collect_diagnostics && spec.objective_uses_offsets
                    accepted_excess = maximum_reading_excess(
                        problem, trial, delta; use_offsets=true)
                    accepted_maximum_reading_excess =
                        accepted_excess.maximum_excess
                    accepted_readings_outside_count =
                        accepted_excess.count_outside
                end
                break
            end
        end
        all_projection_feasible &= all_trial_projection_feasible
        all_objective_readings &= all_trial_objective_readings
        delta_hash_after_line_search = need_hashes ?
            edge_sha256(delta) : "not_collected"
        offsets_fixed = !need_hashes ||
            delta_hash_after_line_search == delta_hash_before
        all_offsets_fixed &= offsets_fixed
        if !accepted
            status = "line_search_stalled"
            collect_trace && push!(trace_rows, Dict(
                "update" => update,
                "accepted" => false,
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
                "gradient_sha256" => vector_sha256(before.gradient),
                "direction_sha256" => vector_sha256(direction),
                "delta_after_line_search_sha256" =>
                    delta_hash_after_line_search,
                "offsets_fixed_during_calculation" => offsets_fixed,
                "nonzero_offsets_before" => nonzero_before,
                "nonzero_offsets_after" => nonzero_before,
                "maximum_absolute_offset_after" =>
                    maximum(abs, flatten_edge_rows(delta)),
                "offset_l2_norm_after" => norm(flatten_edge_rows(delta)),
                "maximum_offset_sum_error" => 0.0,
                "projection_changed_edges" => 0,
                "projection_changed_bits" => 0,
                "maximum_projection_adjustment" => 0.0,
                "boundary_local_values" => 0,
                "finite_difference_maximum_error" => fd.maximum_error,
                "finite_difference_maximum_bit" => fd.maximum_bit,
                "finite_difference_probes_in_box" => fd.all_probes_in_box,
                "finite_difference_passed" => fd_ok,
                "all_trial_projection_feasible" =>
                    all_trial_projection_feasible,
                "all_trial_objective_readings_in_box" =>
                    all_trial_objective_readings,
                "current_maximum_objective_reading_excess" =>
                    current_reading_excess.maximum_excess,
                "current_objective_readings_outside_count" =>
                    current_reading_excess.count_outside,
                "trial_maximum_objective_reading_excess" =>
                    trial_maximum_reading_excess,
                "trial_objective_readings_outside_count" =>
                    trial_readings_outside_count,
                "accepted_maximum_objective_reading_excess" => 0.0,
                "accepted_objective_readings_outside_count" => 0,
            ))
            break
        end

        construction = construct_offsets!(delta_next, q_rows, problem,
            x, trial, accepted_step, before;
            tolerance=mean_tolerance, collect_diagnostics)
        all_mean_constraints &= !collect_diagnostics ||
            construction.maximum_mean_error <= mean_tolerance
        refreshed_readings = !collect_diagnostics || readings_in_box(
            problem, trial, delta_next;
            consume_offsets=true, tolerance=box_tolerance)
        all_refreshed_readings &= refreshed_readings
        delta_hash_after = need_hashes ?
            edge_sha256(delta_next) : "not_collected"
        x_hash_after = need_hashes ? vector_sha256(trial) : "not_collected"
        accepted_steps += 1
        last_accepted_loss = accepted_loss
        collect_trace && push!(trace_rows, Dict(
            "update" => update,
            "accepted" => true,
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
            "gradient_sha256" => vector_sha256(before.gradient),
            "direction_sha256" => vector_sha256(direction),
            "delta_after_line_search_sha256" =>
                delta_hash_after_line_search,
            "offsets_fixed_during_calculation" => offsets_fixed,
            "nonzero_offsets_before" => nonzero_before,
            "nonzero_offsets_after" => construction.nonzero_edges,
            "zero_offset_bits_after" => construction.zero_bits,
            "maximum_absolute_offset_after" =>
                construction.maximum_absolute_offset,
            "offset_l2_norm_after" => construction.offset_l2_norm,
            "maximum_offset_sum_error" => construction.maximum_mean_error,
            "projection_changed_edges" =>
                construction.projection_changed_edges,
            "projection_changed_bits" => construction.projection_changed_bits,
            "maximum_projection_adjustment" =>
                construction.maximum_projection_adjustment,
            "boundary_local_values" => construction.boundary_local_values,
            "finite_difference_maximum_error" => fd.maximum_error,
            "finite_difference_maximum_bit" => fd.maximum_bit,
            "finite_difference_probes_in_box" => fd.all_probes_in_box,
            "finite_difference_passed" => fd_ok,
            "all_trial_projection_feasible" =>
                all_trial_projection_feasible,
            "all_trial_objective_readings_in_box" =>
                all_trial_objective_readings,
            "current_maximum_objective_reading_excess" =>
                current_reading_excess.maximum_excess,
            "current_objective_readings_outside_count" =>
                current_reading_excess.count_outside,
            "trial_maximum_objective_reading_excess" =>
                trial_maximum_reading_excess,
            "trial_objective_readings_outside_count" =>
                trial_readings_outside_count,
            "accepted_maximum_objective_reading_excess" =>
                accepted_maximum_reading_excess,
            "accepted_objective_readings_outside_count" =>
                accepted_readings_outside_count,
            "refreshed_readings_in_box" => refreshed_readings,
        ))
        x, trial = trial, x
        delta, delta_next = delta_next, delta
        update in snapshot_updates && (snapshots[update] =
            (x=copy(x), delta=copy_edge_rows(delta)))
    end

    terminal_workspace = EvalWorkspace(problem)
    terminal = bridge_evaluate!(terminal_workspace, problem, x, delta;
        consume_offsets=spec.objective_uses_offsets)
    terminal_reading_excess = if collect_diagnostics &&
            spec.objective_uses_offsets
        maximum_reading_excess(problem, x, delta; use_offsets=true)
    else
        (; maximum_excess=0.0, count_outside=0)
    end
    maximum_objective_reading_excess = max(
        maximum_objective_reading_excess,
        terminal_reading_excess.maximum_excess)
    objective_readings_outside_count +=
        terminal_reading_excess.count_outside
    all_objective_readings &= terminal_reading_excess.count_outside == 0
    hard = BitVector(x .< 0.0)
    if collect_diagnostics
        hard == hard_decision_independent(x) ||
            error("independent hard decision disagrees")
    end
    independent_syndrome = syndrome_vector(problem.check_vars, hard)
    syndrome_weight = sum(independent_syndrome)
    if collect_diagnostics
        syndrome_weight == JadeJcade.ReceiverCore._syndrome_weight(code, hard) ||
            error("independent syndrome disagrees")
    end
    maximum_updates in snapshot_updates &&
        !haskey(snapshots, maximum_updates) && (snapshots[maximum_updates] =
            (x=copy(x), delta=copy_edge_rows(delta)))

    persistent_scalar_values = n
    persistent_edge_values = sum(length, delta)
    physical_persistent_state_values =
        persistent_scalar_values + persistent_edge_values
    (; spec, x=copy(x), delta=copy_edge_rows(delta), hard,
       syndrome=independent_syndrome, syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       coded_bit_errors=count(hard),
       accepted_steps, requested_steps=maximum_updates, status,
       initial_loss, last_accepted_fixed_offset_loss=last_accepted_loss,
       terminal_refreshed_loss=terminal.loss,
       terminal_terms=terminal.terms,
       fractional_bits=count(value -> abs(value) < 0.999, x),
       trace=trace_rows, snapshots,
       first_objective_offset_use_update,
       first_projection_offset_use_update,
       all_projection_feasibility_checks_passed=all_projection_feasible,
       all_refreshed_readings_in_box=all_refreshed_readings,
       all_objective_readings_in_box=all_objective_readings,
       maximum_objective_reading_excess,
       objective_readings_outside_count,
       terminal_maximum_objective_reading_excess=
           terminal_reading_excess.maximum_excess,
       terminal_objective_readings_outside_count=
           terminal_reading_excess.count_outside,
       all_mean_constraints_passed=all_mean_constraints,
       all_finite_differences_passed=all_finite_differences,
       all_offsets_fixed_during_calculation=all_offsets_fixed,
       terminal_offset_l2_norm=collect_diagnostics ?
           norm(flatten_edge_rows(delta)) : 0.0,
       operation_counts=operation_counts(problem, trace_rows, spec),
       decoder_calls=0, normalized_minsum_calls=0,
       pseudogradient_calls=0, list_calls=0, oracle_calls=0,
       logical_persistent_scalar_values=persistent_scalar_values,
       logical_persistent_edge_values=persistent_edge_values,
       physical_scalar_length=length(x),
       physical_edge_row_count=length(delta),
       physical_edge_slot_count=sum(length, delta),
       physical_edge_row_lengths_sha256=collect_diagnostics ?
           vector_sha256(Int64.(length.(delta))) : "not_collected",
       physical_persistent_state_values,
       physical_persistent_state_bytes=8physical_persistent_state_values)
end

# Compatibility entry point used only by regression tests.  It maps the old
# compound switch to the two diagonal cells without changing arithmetic.
function solve_variant(problem::BridgeProblem, code,
                       initial::AbstractVector{<:Real};
                       consume_offsets::Bool, keywords...)
    spec = consume_offsets ? REQUIRED_ARMS[4] : REQUIRED_ARMS[1]
    solve_variant(problem, code, initial, spec; keywords...)
end

# ---------------------------------------------------------------------------
# Result rows and factorial contrasts
# ---------------------------------------------------------------------------

function stage_frames(config, stage::Symbol)
    if stage === :anchor
        return Int(config["anchor"]["frame_first"]):Int(
            config["anchor"]["frame_last"])
    elseif stage === :heldout
        return Int(config["heldout"]["frame_first"]):Int(
            config["heldout"]["frame_last"])
    end
    throw(ArgumentError("unsupported stage $stage"))
end

function result_frame_row(frame, spec::VariantSpec, input, result,
                          information_positions)
    information_errors = count(@view result.hard[information_positions])
    (;
        frame,
        arm=spec.name,
        objective_uses_offsets=spec.objective_uses_offsets,
        projection_uses_offset_bounds=spec.projection_uses_offset_bounds,
        physical_esn0_db=6.0,
        noise_seed=input.noise_seed,
        coded_bit_errors=result.coded_bit_errors,
        information_bit_errors=information_errors,
        transmitted_word_equal=result.transmitted_word_equal,
        information_word_equal=information_errors == 0,
        parity_valid=result.parity_valid,
        wrong_valid_word=result.parity_valid &&
            !result.transmitted_word_equal,
        syndrome_weight=result.syndrome_weight,
        accepted_steps=result.accepted_steps,
        requested_steps=result.requested_steps,
        status=result.status,
        fractional_bits=result.fractional_bits,
        initial_objective=result.initial_loss,
        last_accepted_fixed_offset_objective=
            result.last_accepted_fixed_offset_loss,
        terminal_refreshed_objective=result.terminal_refreshed_loss,
        first_objective_offset_use_update=something(
            result.first_objective_offset_use_update, 0),
        first_projection_offset_use_update=something(
            result.first_projection_offset_use_update, 0),
        all_projection_feasibility_checks_passed=
            result.all_projection_feasibility_checks_passed,
        all_refreshed_readings_in_box=
            result.all_refreshed_readings_in_box,
        all_objective_readings_in_box=
            result.all_objective_readings_in_box,
        maximum_objective_reading_excess=
            result.maximum_objective_reading_excess,
        objective_readings_outside_count=
            result.objective_readings_outside_count,
        terminal_maximum_objective_reading_excess=
            result.terminal_maximum_objective_reading_excess,
        terminal_objective_readings_outside_count=
            result.terminal_objective_readings_outside_count,
        all_mean_constraints_passed=result.all_mean_constraints_passed,
        all_finite_differences_passed=
            result.all_finite_differences_passed,
        hard_word_sha256=vector_sha256(result.hard),
        terminal_scalar_sha256=vector_sha256(result.x),
        terminal_offset_sha256=edge_sha256(result.delta),
        received_sha256=input.identities.received_sha256,
        clipped_llr_sha256=input.identities.clipped_llr_sha256,
        decoder_calls=result.decoder_calls,
        normalized_minsum_calls=result.normalized_minsum_calls,
        pseudogradient_calls=result.pseudogradient_calls,
        list_calls=result.list_calls,
        oracle_calls=result.oracle_calls,
        logical_persistent_scalar_values=
            result.logical_persistent_scalar_values,
        logical_persistent_edge_values=
            result.logical_persistent_edge_values,
        physical_scalar_length=result.physical_scalar_length,
        physical_edge_row_count=result.physical_edge_row_count,
        physical_edge_slot_count=result.physical_edge_slot_count,
        physical_edge_row_lengths_sha256=
            result.physical_edge_row_lengths_sha256,
        physical_persistent_state_values=
            result.physical_persistent_state_values,
        physical_persistent_state_bytes=
            result.physical_persistent_state_bytes,
        terminal_offset_l2_norm=result.terminal_offset_l2_norm,
        objective_and_gradient_evaluations=result.operation_counts[
            "objective_and_gradient_evaluations"],
        check_products=result.operation_counts["check_products"],
        leave_one_products=result.operation_counts["leave_one_products"],
        parity_contribution_accumulations=result.operation_counts[
            "parity_contribution_accumulations"],
        offset_additions_to_parity_readings=result.operation_counts[
            "offset_additions_to_parity_readings"],
        offset_bound_intersections=result.operation_counts[
            "offset_bound_intersections"],
        bounded_mean_projection_bits=result.operation_counts[
            "bounded_mean_projection_bits"],
        offset_values_constructed=result.operation_counts[
            "offset_values_constructed"],
    )
end

function result_iteration_rows(frame, spec::VariantSpec, result)
    rows = NamedTuple[]
    for record in result.trace
        push!(rows, (;
            frame,
            arm=spec.name,
            objective_uses_offsets=spec.objective_uses_offsets,
            projection_uses_offset_bounds=
                spec.projection_uses_offset_bounds,
            update=Int(record["update"]),
            accepted=Bool(record["accepted"]),
            trial_count=Int(record["trial_count"]),
            objective_evaluations=Int(record["objective_evaluations"]),
            loss_before=Float64(record["loss_before"]),
            accepted_fixed_offset_loss=Float64(
                record["accepted_fixed_offset_loss"]),
            accepted_step=Float64(record["accepted_step"]),
            nonzero_offsets_before=Int(record["nonzero_offsets_before"]),
            nonzero_offsets_after=Int(record["nonzero_offsets_after"]),
            maximum_absolute_offset_after=Float64(
                record["maximum_absolute_offset_after"]),
            offset_l2_norm_after=Float64(record["offset_l2_norm_after"]),
            maximum_offset_sum_error=Float64(
                record["maximum_offset_sum_error"]),
            projection_changed_edges=Int(
                record["projection_changed_edges"]),
            projection_changed_bits=Int(
                record["projection_changed_bits"]),
            maximum_projection_adjustment=Float64(
                record["maximum_projection_adjustment"]),
            boundary_local_values=Int(record["boundary_local_values"]),
            finite_difference_maximum_error=Float64(
                record["finite_difference_maximum_error"]),
            finite_difference_maximum_bit=Int(
                record["finite_difference_maximum_bit"]),
            finite_difference_probes_in_box=Bool(
                record["finite_difference_probes_in_box"]),
            finite_difference_passed=Bool(
                record["finite_difference_passed"]),
            all_trial_projection_feasible=Bool(
                record["all_trial_projection_feasible"]),
            all_trial_objective_readings_in_box=Bool(
                record["all_trial_objective_readings_in_box"]),
            current_maximum_objective_reading_excess=Float64(
                record["current_maximum_objective_reading_excess"]),
            current_objective_readings_outside_count=Int(
                record["current_objective_readings_outside_count"]),
            trial_maximum_objective_reading_excess=Float64(
                record["trial_maximum_objective_reading_excess"]),
            trial_objective_readings_outside_count=Int(
                record["trial_objective_readings_outside_count"]),
            accepted_maximum_objective_reading_excess=Float64(
                record["accepted_maximum_objective_reading_excess"]),
            accepted_objective_readings_outside_count=Int(
                record["accepted_objective_readings_outside_count"]),
            x_before_sha256=String(record["x_before_sha256"]),
            x_after_sha256=String(record["x_after_sha256"]),
            raw_proposal_sha256=String(record["raw_proposal_sha256"]),
            lower_bound_sha256=String(record["lower_bound_sha256"]),
            upper_bound_sha256=String(record["upper_bound_sha256"]),
            delta_before_sha256=String(record["delta_before_sha256"]),
            delta_after_line_search_sha256=String(
                record["delta_after_line_search_sha256"]),
            delta_after_sha256=String(record["delta_after_sha256"]),
            offsets_fixed_during_calculation=Bool(
                record["offsets_fixed_during_calculation"]),
            gradient_sha256=String(record["gradient_sha256"]),
            direction_sha256=String(record["direction_sha256"]),
        ))
    end
    rows
end

function rows_by_frame_and_arm(frame_rows, field::Symbol,
                               required_arms::AbstractVector{String})
    grouped = Dict{Int,Dict{String,Bool}}()
    required = Set(required_arms)
    for row in frame_rows
        String(row.arm) in required || continue
        values = get!(grouped, Int(row.frame), Dict{String,Bool}())
        haskey(values, String(row.arm)) && throw(ArgumentError(
            "duplicate arm $(row.arm) for frame $(row.frame)"))
        values[String(row.arm)] = Bool(getproperty(row, field))
    end
    for (frame, values) in grouped
        Set(keys(values)) == required || throw(ArgumentError(
            "frame $frame has arms $(sort!(collect(keys(values)))) rather than $(sort(required_arms))"))
    end
    grouped
end

function validate_frame_input_identities(frame_rows)
    required = Set(spec.name for spec in REQUIRED_ARMS)
    grouped = Dict{Int,Vector{Any}}()
    for row in frame_rows
        push!(get!(grouped, Int(row.frame), Any[]), row)
    end
    isempty(grouped) && throw(ArgumentError(
        "frame input identity validation requires at least one frame"))
    for (frame, rows) in grouped
        arms = String[row.arm for row in rows]
        length(arms) == length(required) && Set(arms) == required ||
            throw(ArgumentError(
                "frame $frame does not contain each registered arm exactly once"))
        received = String[row.received_sha256 for row in rows]
        clipped = String[row.clipped_llr_sha256 for row in rows]
        seeds = Int[row.noise_seed for row in rows]
        all_equal(received) && all_equal(clipped) && all_equal(seeds) ||
            throw(ArgumentError(
                "frame $frame does not retain one common physical input across arms"))
    end
    true
end

function paired_endpoint_counts(frame_rows, field::Symbol,
                                treatment::AbstractString,
                                reference::AbstractString)
    treatment == reference && throw(ArgumentError(
        "paired contrast requires two different arms"))
    grouped = rows_by_frame_and_arm(frame_rows, field,
        [String(treatment), String(reference)])
    isempty(grouped) && throw(ArgumentError(
        "paired contrast requires at least one complete frame"))
    n11 = n10 = n01 = n00 = 0
    for frame in sort!(collect(keys(grouped)))
        values = grouped[frame]
        treated = values[String(treatment)]
        control = values[String(reference)]
        if treated && control
            n11 += 1
        elseif treated
            n10 += 1
        elseif control
            n01 += 1
        else
            n00 += 1
        end
    end
    total = n11 + n10 + n01 + n00
    Dict{String,Any}(
        "treatment" => String(treatment),
        "reference" => String(reference),
        "both_success" => n11,
        "treatment_only_success" => n10,
        "reference_only_success" => n01,
        "both_failure" => n00,
        "pairs" => total,
        "treatment_successes" => n11 + n10,
        "reference_successes" => n11 + n01,
        "risk_difference_treatment_minus_reference" =>
            (n10 - n01) / total,
    )
end

const CONTRASTS = (
    (id="objective_use_given_bounds0",
     treatment="objective1__bounds0", reference="objective0__bounds0"),
    (id="offset_bounds_given_objective0",
     treatment="objective0__bounds1", reference="objective0__bounds0"),
    (id="objective_use_given_bounds1",
     treatment="objective1__bounds1", reference="objective0__bounds1"),
    (id="offset_bounds_given_objective1",
     treatment="objective1__bounds1", reference="objective1__bounds0"),
)

function factorial_interaction(frame_rows, field::Symbol)
    arms = [spec.name for spec in REQUIRED_ARMS]
    grouped = rows_by_frame_and_arm(frame_rows, field, arms)
    score_counts = Dict(string(score) => 0 for score in -2:2)
    total_score = 0
    for outcomes in values(grouped)
        score = Int(outcomes["objective1__bounds1"]) -
                Int(outcomes["objective1__bounds0"]) -
                Int(outcomes["objective0__bounds1"]) +
                Int(outcomes["objective0__bounds0"])
        score_counts[string(score)] += 1
        total_score += score
    end
    Dict{String,Any}(
        "definition" => "p11 - p10 - p01 + p00",
        "frames" => length(grouped),
        "score_sum" => total_score,
        "risk_difference_interaction" => total_score / length(grouped),
        "frame_score_counts" => score_counts,
    )
end

function add_interaction_bootstrap!(interaction, frame_rows, field::Symbol;
                                    seed::Int,
                                    resamples::Int,
                                    confidence_level::Float64)
    arms = [spec.name for spec in REQUIRED_ARMS]
    grouped = rows_by_frame_and_arm(frame_rows, field, arms)
    scores = Int[]
    for frame in sort!(collect(keys(grouped)))
        values = grouped[frame]
        push!(scores,
            Int(values["objective1__bounds1"]) -
            Int(values["objective1__bounds0"]) -
            Int(values["objective0__bounds1"]) +
            Int(values["objective0__bounds0"]))
    end
    rng = MersenneTwister(seed)
    n = length(scores)
    draws = Vector{Float64}(undef, resamples)
    for repetition in eachindex(draws)
        total = 0
        for _ in 1:n
            total += scores[rand(rng, 1:n)]
        end
        draws[repetition] = total / n
    end
    sort!(draws)
    alpha = 1.0 - confidence_level
    lower_index = clamp(floor(Int, alpha / 2 * resamples) + 1,
                        1, resamples)
    upper_index = clamp(ceil(Int, (1.0 - alpha / 2) * resamples),
                        1, resamples)
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

function legacy_count_keys(counts)
    Dict(
        "both_success" => counts["both_success"],
        "active_only_success" => counts["treatment_only_success"],
        "control_only_success" => counts["reference_only_success"],
        "both_failure" => counts["both_failure"],
        "pairs" => counts["pairs"],
        "active_successes" => counts["treatment_successes"],
        "control_successes" => counts["reference_successes"],
        "risk_difference_active_minus_control" =>
            counts["risk_difference_treatment_minus_reference"],
    )
end

function contrast_endpoint_results(frame_rows, field::Symbol)
    Dict(contrast.id => paired_endpoint_counts(frame_rows, field,
            contrast.treatment, contrast.reference)
         for contrast in CONTRASTS)
end

function add_heldout_inference!(endpoint_results,
                                confidence_level::Float64)
    pvalues = Dict{String,Float64}()
    for endpoint in ("transmitted_word_equal", "parity_valid")
        for contrast in CONTRASTS
            result = endpoint_results[endpoint]["contrasts"][contrast.id]
            legacy = legacy_count_keys(result)
            pvalue = Legacy.mcnemar_exact_pvalue(legacy)
            result["mcnemar_exact_two_sided_pvalue"] = pvalue
            result["newcombe_interval"] =
                Legacy.newcombe_paired_interval(legacy;
                    confidence_level)
            pvalues["$endpoint::$(contrast.id)"] = pvalue
        end
    end
    adjusted = Legacy.holm_adjust(pvalues)
    for (key, value) in adjusted
        endpoint, contrast = split(key, "::"; limit=2)
        endpoint_results[endpoint]["contrasts"][contrast][
            "holm_adjusted_pvalue"] = value
    end
    endpoint_results
end

function snapshot_rows(frame, results)
    rows = NamedTuple[]
    for spec in REQUIRED_ARMS
        result = results[spec.name]
        states = copy(result.snapshots)
        states[-1] = (x=result.x, delta=result.delta)
        for update in sort!(collect(keys(states)))
            label = update == -1 ? "terminal" : string(update)
            state = states[update]
            for bit in eachindex(state.x)
                value = Float64(state.x[bit])
                push!(rows, (;
                    frame, arm=spec.name, update=label, kind="scalar",
                    check=0, slot=0, bit, value,
                    float64_hex=float64_hex(value)))
            end
            for (check_index, row) in enumerate(state.delta),
                    slot in eachindex(row)
                bit = results["problem"].check_vars[check_index][slot]
                value = Float64(row[slot])
                push!(rows, (;
                    frame, arm=spec.name, update=label, kind="offset",
                    check=check_index, slot, bit, value,
                    float64_hex=float64_hex(value)))
            end
        end
    end
    rows
end

# ---------------------------------------------------------------------------
# Source and input freeze
# ---------------------------------------------------------------------------

function authored_source_paths(config_path::AbstractString)
    Dict(
        "config.toml" => abspath(config_path),
        "experiment_card.md" => CARD_PATH,
        "rq2_gd_offset_split_001.jl" => RUNNER_PATH,
        "rq2_gd_state_use_001.jl" => LEGACY_RUNNER_PATH,
        "test_rq2_gd_offset_split_001.jl" => TEST_PATH,
        "preflight_validation.md" => PREFLIGHT_PATH,
    )
end

function freeze_source_paths(config, config_path::AbstractString)
    paths = authored_source_paths(config_path)
    for (label, (path, _)) in Legacy.static_source_specs(config)
        extension = splitext(path)[2]
        paths["retained/$label$extension"] = path
    end
    sources = config["sources"]
    for (label, root_key, relative) in RETAINED_RESULT_SPECS
        expected_key = label * "_sha256"
        haskey(sources, expected_key) || continue
        paths["retained_results/$label/$(basename(relative))"] =
            joinpath(String(sources[root_key]), relative)
    end
    jade_root = String(config["sources"]["jade_project_repo"])
    jade_src = joinpath(jade_root, "src")
    for (directory, _, files) in walkdir(jade_src)
        for name in sort(files)
            endswith(name, ".jl") || continue
            path = joinpath(directory, name)
            paths["jade_src/" * relpath(path, jade_src)] = path
        end
    end
    paths
end

function input_freeze_rows(config, native, code)
    rows = NamedTuple[]
    for (set_name, frames) in (
        ("anchor", stage_frames(config, :anchor)),
        ("heldout", stage_frames(config, :heldout)),
    )
        for frame in frames
            input = generate_input(config, native, code, frame)
            push!(rows, (;
                set=set_name,
                frame,
                noise_seed=input.noise_seed,
                physical_esn0_db=Float64(
                    config["channel"]["physical_esn0_db"]),
                noise_variance=input.variance,
                noise_variance_float64_hex=float64_hex(input.variance),
                graph_sha256=input.identities.graph_sha256,
                transmitted_word_sha256=
                    input.identities.transmitted_word_sha256,
                transmitted_symbols_sha256=
                    input.identities.transmitted_symbols_sha256,
                unit_noise_sha256=input.identities.unit_noise_sha256,
                received_sha256=input.identities.received_sha256,
                raw_llr_sha256=input.identities.raw_llr_sha256,
                clipped_llr_sha256=input.identities.clipped_llr_sha256,
            ))
        end
    end
    rows
end

function freeze_inputs(output::AbstractString;
                       config_path::AbstractString=DEFAULT_CONFIG,
                       command::AbstractString="freeze")
    output = abspath(output)
    ispath(output) && throw(ArgumentError(
        "freeze output already exists: $output"))
    config = load_config(config_path)
    preflight = preflight_gate(config_path)
    preflight["passed"] || throw(ArgumentError(
        "locked preflight record does not match the authored sources"))
    gate = source_gate(config)
    gate["passed"] || throw(ArgumentError(
        "retained-source gate failed before freeze"))
    enforce_thread_environment(config)
    native = load_native(config)
    generated = make_code(config, native)
    rows = input_freeze_rows(config, native, generated.code)

    mkpath(dirname(output))
    mkdir(output)
    input_path = joinpath(output, "input_freeze.csv")
    write_csv(input_path, rows, propertynames(first(rows)))
    source_directory = joinpath(output, "source")
    mkdir(source_directory)
    source_records = archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["freeze_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "created_utc" => string(now(UTC)),
        "command" => String(command),
        "configuration_sha256" => file_sha256(config_path),
        "input_freeze_sha256" => file_sha256(input_path),
        "input_row_count" => length(rows),
        "anchor_row_count" => count(row -> row.set == "anchor", rows),
        "heldout_row_count" => count(row -> row.set == "heldout", rows),
        "graph_sha256" => graph_sha256(generated.code.check_vars),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_threads" => Threads.nthreads(),
            "blas_threads" => BLAS.get_num_threads(),
            "cpu" => Sys.CPU_NAME,
            "gzip_version" => strip(first(split(
                read(`gzip --version`, String), '\n'))),
        ),
        "sp_repository" => Dict(
            "root" => git_output(HERE, "rev-parse", "--show-toplevel"),
            "head" => git_output(HERE, "rev-parse", "HEAD"),
            "branch" => git_output(HERE, "branch", "--show-current"),
            "status" => git_output(HERE, "status", "--porcelain=v1",
                                   "--untracked-files=all"),
        ),
        "jade_project" => Dict(
            "root" => String(config["sources"]["jade_project_repo"]),
            "head" => git_output(String(
                config["sources"]["jade_project_repo"]), "rev-parse", "HEAD"),
            "status" => git_output(String(
                config["sources"]["jade_project_repo"]), "status",
                "--porcelain=v1", "--untracked-files=all"),
        ),
        "source_gate" => gate,
        "preflight_gate" => preflight,
        "sources" => source_records,
    )
    manifest_path = joinpath(output, "freeze_manifest.toml")
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    written = Legacy.write_checksum_manifest(output)
    Dict(
        "output" => output,
        "input_rows" => length(rows),
        "input_freeze_sha256" => file_sha256(input_path),
        "freeze_manifest_sha256" => file_sha256(manifest_path),
        "checksum_entries" => length(written.entries),
    )
end

function validate_freeze(config, freeze::AbstractString;
                         config_path::AbstractString=DEFAULT_CONFIG,
                         regenerate::Bool=true)
    freeze = abspath(freeze)
    checksum = Legacy.verify_checksum_manifest(freeze)
    manifest_path = joinpath(freeze, "freeze_manifest.toml")
    table_path = joinpath(freeze, "input_freeze.csv")
    isfile(manifest_path) || throw(ArgumentError(
        "freeze manifest is missing"))
    isfile(table_path) || throw(ArgumentError("freeze input table is missing"))
    manifest = TOML.parsefile(manifest_path)
    checks = Dict{String,Bool}(
        "checksum_manifest" => Bool(checksum["passed"]),
        "schema" => manifest["schema_version"] ==
            config["provenance"]["freeze_schema"],
        "experiment" => manifest["experiment_id"] ==
            config["experiment_id"],
        "configuration" => manifest["configuration_sha256"] ==
            file_sha256(config_path),
        "input_table_hash" => manifest["input_freeze_sha256"] ==
            file_sha256(table_path),
        "input_row_count" => length(parse_simple_csv(table_path)) ==
            Int(config["anchor"]["expected_count"]) +
            Int(config["heldout"]["expected_count"]),
        "current_source_gate" => Bool(source_gate(config)["passed"]),
        "current_preflight_record" => Bool(
            preflight_gate(config_path)["passed"]),
        "frozen_preflight_record" => haskey(manifest, "preflight_gate") &&
            manifest["preflight_gate"]["passed"] == true,
    )
    frozen_sources = Dict(String(record["label"]) => record
                          for record in manifest["sources"])
    authored_ok = true
    authored_failures = String[]
    for (label, current_path) in authored_source_paths(config_path)
        if !haskey(frozen_sources, label)
            authored_ok = false
            push!(authored_failures, "missing_record:$label")
            continue
        end
        record = frozen_sources[label]
        archived_path = joinpath(freeze,
            String(record["archived_relative_path"]))
        expected = String(record["sha256"])
        ok = isfile(current_path) && file_sha256(current_path) == expected &&
             isfile(archived_path) && file_sha256(archived_path) == expected
        authored_ok &= ok
        ok || push!(authored_failures, label)
    end
    checks["current_authored_sources_equal_freeze"] = authored_ok
    regenerated_ok = true
    if regenerate
        native = load_native(config)
        generated = make_code(config, native)
        rows = input_freeze_rows(config, native, generated.code)
        temporary = tempname() * ".csv"
        write_csv(temporary, rows, propertynames(first(rows)))
        regenerated_ok = file_sha256(temporary) == file_sha256(table_path)
        rm(temporary)
    end
    checks["regenerated_input_table"] = regenerated_ok
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "manifest" => manifest,
        "checksum" => checksum,
        "authored_source_failures" => authored_failures,
        "freeze_sha256" => file_sha256(joinpath(freeze, "MANIFEST.sha256")),
    )
end

# ---------------------------------------------------------------------------
# Scientific execution
# ---------------------------------------------------------------------------

all_equal(values) = isempty(values) || all(==(first(values)), values)

function physical_signature(result)
    (
        result.physical_scalar_length,
        result.physical_edge_row_count,
        result.physical_edge_slot_count,
        result.physical_edge_row_lengths_sha256,
        result.physical_persistent_state_values,
        result.physical_persistent_state_bytes,
    )
end

function row_dict(row)
    Dict(String(name) => getproperty(row, name) for name in propertynames(row))
end

function calculate_science(config, freeze::AbstractString, stage::Symbol;
                           collect_runtime::Bool,
                           config_path::AbstractString=DEFAULT_CONFIG,
                           progress_path::Union{Nothing,String}=nothing,
                           pass_name::AbstractString="primary",
                           progress_started_utc::AbstractString="")
    frames = stage_frames(config, stage)
    total_frames = length(frames)
    started = isempty(progress_started_utc) ?
        string(now(UTC)) : String(progress_started_utc)
    phases = PhaseTracker(progress_path, String(stage), pass_name, started)
    begin_phase!(phases, "pass_preamble";
        frames_completed=0, frames_total=total_frames,
        arms_total=length(REQUIRED_ARMS))
    freeze_validation = validate_freeze(config, freeze;
        config_path, regenerate=true)
    freeze_validation["passed"] || throw(ArgumentError(
        "frozen input gate failed"))
    enforce_thread_environment(config)
    native = load_native(config)
    generated = make_code(config, native)
    code = generated.code
    information_positions = native_call(native, :_message_positions, code)
    specs = arm_specs(config)
    update_limit = Int(
        config["projected_gradient"]["maximum_update_attempts"])
    initial_step = Float64(config["projected_gradient"]["initial_step"])
    backtracks = Int(config["projected_gradient"]["maximum_backtracks"])
    fd_step = Float64(config["validation"]["finite_difference_step"])
    fd_tolerance = Float64(
        config["validation"]["finite_difference_tolerance"])
    mean_tolerance = Float64(
        config["validation"]["mean_offset_tolerance"])
    box_tolerance = Float64(config["validation"]["box_tolerance"])
    if collect_runtime
        config["timing"]["warmup_has_frame_identity"] == false ||
            throw(ArgumentError("timing warm-up must not have a frame identity"))
        config["timing"]["warmup_included_in_outcomes"] == false ||
            throw(ArgumentError("timing warm-up must be excluded from outcomes"))
        warm_llr = [2sin(0.013bit) + 0.4cos(0.031bit)
                    for bit in 1:code.n]
        warm_problem = BridgeProblem(code, warm_llr;
            parity_weight=Float64(
                config["projected_gradient"]["parity_weight"]),
            binary_weight=Float64(
                config["projected_gradient"]["binary_weight"]))
        warm_initial = tanh.(warm_llr ./ 2)
        for spec in specs
            for _ in 1:Int(config["timing"]["warmup_repetitions_per_arm"])
                solve_variant(warm_problem, code, warm_initial, spec;
                    maximum_updates=update_limit, initial_step,
                    maximum_backtracks=backtracks,
                    collect_trace=false, collect_diagnostics=false,
                    validate_derivatives=false, mean_tolerance, box_tolerance)
            end
        end
    end

    begin_phase!(phases, "frame_loop";
        frames_completed=0, frames_total=total_frames,
        arms_total=length(specs))

    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    runtime_rows = NamedTuple[]
    snapshot_payload = nothing
    frame_gate_records = Dict{String,Any}[]
    all_control_oracle = true
    all_update1_equal = true
    all_update2_entry_equal = true
    all_update2_objective_grouping = true
    all_update2_bound_grouping = true
    all_nonzero_at_update2 = true
    all_first_uses_at_update2 = true
    all_fd = true
    all_offsets_fixed = true
    all_projection_feasible = true
    all_refreshed_readings = true
    all_mean = true
    all_equal_physical_shapes = true
    all_zero_calls = true
    all_timed_trace_equal = true

    for (frame_position, frame) in enumerate(frames)
        progress_path !== nothing && phase_progress!(phases;
            status="running",
            frames_completed=frame_position-1, frames_total=total_frames,
            current_frame=frame, last_completed_frame=
                frame_position == 1 ? 0 : frames[frame_position-1],
            arms_completed=0, arms_total=length(specs))
        input = generate_input(config, native, code, frame)
        problem = BridgeProblem(code, input.clipped_llr;
            parity_weight=Float64(
                config["projected_gradient"]["parity_weight"]),
            binary_weight=Float64(
                config["projected_gradient"]["binary_weight"]))
        initial = tanh.(input.clipped_llr ./ 2)
        snapshot_set = frame_position == 1 ? Set([0, 1, 2]) : Set{Int}()

        timed_results = Dict{String,Any}()
        if collect_runtime
            rotation = mod(frame_position - 1, length(specs))
            order = circshift(specs, -rotation)
            for (order_position, spec) in enumerate(order)
                timed = @timed solve_variant(problem, code, initial, spec;
                    maximum_updates=update_limit, initial_step,
                    maximum_backtracks=backtracks,
                    collect_trace=false, collect_diagnostics=false,
                    validate_derivatives=false, mean_tolerance, box_tolerance)
                timed_results[spec.name] = timed.value
                push!(runtime_rows, (;
                    frame, arm=spec.name,
                    objective_uses_offsets=spec.objective_uses_offsets,
                    projection_uses_offset_bounds=
                        spec.projection_uses_offset_bounds,
                    order_position,
                    seconds=Float64(timed.time),
                    allocated_bytes=Int(timed.bytes),
                    garbage_collection_seconds=Float64(timed.gctime),
                ))
            end
        end

        results = Dict{String,Any}("problem" => problem)
        for (arm_position, spec) in enumerate(specs)
            results[spec.name] = solve_variant(problem, code, initial, spec;
                maximum_updates=update_limit, initial_step,
                maximum_backtracks=backtracks,
                collect_trace=true,
                validate_derivatives=spec.objective_uses_offsets,
                finite_difference_step=fd_step,
                finite_difference_tolerance=fd_tolerance,
                mean_tolerance, box_tolerance,
                snapshot_updates=snapshot_set)
            progress_path !== nothing && phase_progress!(phases;
                status="running",
                frames_completed=frame_position-1,
                frames_total=total_frames,
                current_frame=frame,
                last_completed_frame=frame_position == 1 ? 0 :
                    frames[frame_position-1],
                arms_completed=arm_position, arms_total=length(specs))
        end

        r00 = results["objective0__bounds0"]
        r10 = results["objective1__bounds0"]
        r01 = results["objective0__bounds1"]
        r11 = results["objective1__bounds1"]
        traces_have_two = all(length(results[spec.name].trace) >= 2
                              for spec in specs)
        update1_equal = traces_have_two && all_equal([
            (result.trace[1]["gradient_sha256"],
             result.trace[1]["x_after_sha256"],
             result.trace[1]["delta_after_sha256"],
             result.trace[1]["accepted_step"])
            for result in (r00, r10, r01, r11)
        ])
        update2_entry_equal = traces_have_two && all_equal([
            (result.trace[2]["x_before_sha256"],
             result.trace[2]["delta_before_sha256"])
            for result in (r00, r10, r01, r11)
        ])
        update2_objective_grouping = traces_have_two &&
            r00.trace[2]["gradient_sha256"] ==
                r01.trace[2]["gradient_sha256"] &&
            r10.trace[2]["gradient_sha256"] ==
                r11.trace[2]["gradient_sha256"] &&
            r00.trace[2]["gradient_sha256"] !=
                r10.trace[2]["gradient_sha256"]
        update2_bound_grouping = traces_have_two &&
            r00.trace[2]["lower_bound_sha256"] ==
                r10.trace[2]["lower_bound_sha256"] &&
            r00.trace[2]["upper_bound_sha256"] ==
                r10.trace[2]["upper_bound_sha256"] &&
            r01.trace[2]["lower_bound_sha256"] ==
                r11.trace[2]["lower_bound_sha256"] &&
            r01.trace[2]["upper_bound_sha256"] ==
                r11.trace[2]["upper_bound_sha256"] &&
            (r00.trace[2]["lower_bound_sha256"] !=
                r01.trace[2]["lower_bound_sha256"] ||
             r00.trace[2]["upper_bound_sha256"] !=
                r01.trace[2]["upper_bound_sha256"])
        nonzero_at_update2 = traces_have_two && all(
            result.trace[2]["nonzero_offsets_before"] > 0
            for result in (r00, r10, r01, r11))
        first_uses_at_update2 =
            r00.first_objective_offset_use_update === nothing &&
            r00.first_projection_offset_use_update === nothing &&
            r10.first_objective_offset_use_update == 2 &&
            r10.first_projection_offset_use_update === nothing &&
            r01.first_objective_offset_use_update === nothing &&
            r01.first_projection_offset_use_update == 2 &&
            r11.first_objective_offset_use_update == 2 &&
            r11.first_projection_offset_use_update == 2

        native_problem = native_call(native, :ScalarProblem, code,
            input.clipped_llr;
            parity_weight=Float64(
                config["projected_gradient"]["parity_weight"]),
            binary_weight=Float64(
                config["projected_gradient"]["binary_weight"]))
        oracle = native_trace(native, native_problem, initial;
            maximum_updates=update_limit, initial_step,
            maximum_backtracks=backtracks)
        oracle_gate = Legacy.control_oracle_comparison(r00, oracle)
        physical_shapes_equal = all_equal(
            [physical_signature(results[spec.name]) for spec in specs])
        zero_calls = all(value == 0 for spec in specs for value in (
            results[spec.name].decoder_calls,
            results[spec.name].normalized_minsum_calls,
            results[spec.name].pseudogradient_calls,
            results[spec.name].list_calls,
            results[spec.name].oracle_calls,
        ))
        finite_differences = r10.all_finite_differences_passed &&
            r11.all_finite_differences_passed
        offsets_fixed = all(
            results[spec.name].all_offsets_fixed_during_calculation
            for spec in specs)
        projection_feasible = all(
            results[spec.name].all_projection_feasibility_checks_passed
            for spec in specs)
        refreshed_readings = all(
            results[spec.name].all_refreshed_readings_in_box
            for spec in specs)
        mean_constraints = all(
            results[spec.name].all_mean_constraints_passed
            for spec in specs)
        timed_equal = true
        if collect_runtime
            for spec in specs
                timed_equal &= vector_sha256(timed_results[spec.name].x) ==
                    vector_sha256(results[spec.name].x)
                timed_equal &= edge_sha256(timed_results[spec.name].delta) ==
                    edge_sha256(results[spec.name].delta)
            end
        end

        all_control_oracle &= Bool(oracle_gate["passed"])
        all_update1_equal &= update1_equal
        all_update2_entry_equal &= update2_entry_equal
        all_update2_objective_grouping &= update2_objective_grouping
        all_update2_bound_grouping &= update2_bound_grouping
        all_nonzero_at_update2 &= nonzero_at_update2
        all_first_uses_at_update2 &= first_uses_at_update2
        all_fd &= finite_differences
        all_offsets_fixed &= offsets_fixed
        all_projection_feasible &= projection_feasible
        all_refreshed_readings &= refreshed_readings
        all_mean &= mean_constraints
        all_equal_physical_shapes &= physical_shapes_equal
        all_zero_calls &= zero_calls
        all_timed_trace_equal &= timed_equal
        push!(frame_gate_records, Dict(
            "frame" => frame,
            "native_control" => oracle_gate,
            "all_arms_equal_through_update_1" => update1_equal,
            "all_arms_equal_entering_update_2" => update2_entry_equal,
            "update_2_gradient_grouped_only_by_objective_switch" =>
                update2_objective_grouping,
            "update_2_bounds_grouped_only_by_projection_switch" =>
                update2_bound_grouping,
            "nonzero_offsets_enter_update_2" => nonzero_at_update2,
            "first_factor_use_at_update_2" => first_uses_at_update2,
            "objective_arm_finite_differences" => finite_differences,
            "offsets_fixed_during_calculation" => offsets_fixed,
            "projection_feasibility" => projection_feasible,
            "refreshed_readings_in_box" => refreshed_readings,
            "mean_offset_constraints" => mean_constraints,
            "equal_physical_array_shapes" => physical_shapes_equal,
            "zero_prohibited_calls" => zero_calls,
            "timed_and_trace_terminal_equal" => timed_equal,
            "objective1_bounds0_maximum_reading_excess" =>
                r10.maximum_objective_reading_excess,
            "objective1_bounds0_readings_outside_count" =>
                r10.objective_readings_outside_count,
        ))

        for spec in specs
            result = results[spec.name]
            push!(frame_rows, result_frame_row(frame, spec, input, result,
                                               information_positions))
            append!(iteration_rows,
                result_iteration_rows(frame, spec, result))
        end
        frame_position == 1 && (snapshot_payload = results)
        progress_path !== nothing && phase_progress!(phases;
            status="running",
            frames_completed=frame_position, frames_total=total_frames,
            current_frame=0, last_completed_frame=frame,
            arms_completed=length(specs), arms_total=length(specs))
    end

    begin_phase!(phases, "statistics";
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames), arms_completed=length(specs),
        arms_total=length(specs))
    common_frame_inputs = validate_frame_input_identities(frame_rows)
    endpoint_results = Dict{String,Any}()
    for endpoint in (:transmitted_word_equal, :parity_valid,
                     :information_word_equal)
        endpoint_results[String(endpoint)] = Dict(
            "contrasts" => contrast_endpoint_results(frame_rows, endpoint),
            "interaction" => factorial_interaction(frame_rows, endpoint),
        )
    end
    if stage === :heldout
        add_heldout_inference!(endpoint_results,
            Float64(config["inference"][
                "pairwise_interval_confidence_level"]))
        for endpoint in ("transmitted_word_equal", "parity_valid")
            add_interaction_bootstrap!(
                endpoint_results[endpoint]["interaction"], frame_rows,
                Symbol(endpoint);
                seed=Int(config["inference"]["interaction_bootstrap_seed"]),
                resamples=Int(config["inference"][
                    "interaction_bootstrap_resamples"]),
                confidence_level=Float64(config["inference"][
                    "interaction_interval_confidence_level"]))
        end
    end

    base_gates = Dict(
        "freeze" => Bool(freeze_validation["passed"]),
        "locked_preflight_validation" =>
            freeze_validation["checks"]["current_preflight_record"] &&
            freeze_validation["checks"]["frozen_preflight_record"],
        "objective0_bounds0_matches_native_path" => all_control_oracle,
        "all_arms_equal_through_update_1" => all_update1_equal,
        "all_arms_equal_entering_update_2" => all_update2_entry_equal,
        "update_2_gradient_grouped_only_by_objective_switch" =>
            all_update2_objective_grouping,
        "update_2_bounds_grouped_only_by_projection_switch" =>
            all_update2_bound_grouping,
        "nonzero_offsets_enter_update_2" => all_nonzero_at_update2,
        "first_factor_use_at_update_2" => all_first_uses_at_update2,
        "objective_arm_gradients_pass_finite_differences" => all_fd,
        "offsets_fixed_during_gradient_and_line_search" =>
            all_offsets_fixed,
        "selected_projection_feasibility_passed" =>
            all_projection_feasible,
        "refreshed_local_readings_in_box" => all_refreshed_readings,
        "mean_offset_constraints" => all_mean,
        "equal_physical_array_shapes" => all_equal_physical_shapes,
        "structural_prohibited_call_fields_zero" => all_zero_calls,
        "timed_and_trace_terminal_states_equal" => all_timed_trace_equal,
        "common_physical_input_within_each_frame" => common_frame_inputs,
        "frame_count" => length(frames) == (stage === :anchor ?
            Int(config["anchor"]["expected_count"]) :
            Int(config["heldout"]["expected_count"])),
    )
    correctness_passed = all(values(base_gates))
    expansion_authorized = stage === :anchor && correctness_passed
    frame_dicts = row_dict.(frame_rows)
    iteration_dicts = row_dict.(iteration_rows)
    begin_phase!(phases, "frame_table_hash";
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames), arms_completed=length(specs),
        arms_total=length(specs))
    frame_rows_sha256 = scientific_sha256(frame_dicts)
    begin_phase!(phases, "iteration_table_hash";
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames), arms_completed=length(specs),
        arms_total=length(specs))
    iteration_rows_sha256 = scientific_sha256(iteration_dicts)
    begin_phase!(phases, "gate_hash";
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames), arms_completed=length(specs),
        arms_total=length(specs))
    frame_gates_sha256 = scientific_sha256(frame_gate_records)
    science = Dict(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "frame_count" => length(frames),
        "arms" => [Dict(
            "name" => spec.name,
            "objective_uses_offsets" => spec.objective_uses_offsets,
            "projection_uses_offset_bounds" =>
                spec.projection_uses_offset_bounds) for spec in specs],
        "endpoint_results" => endpoint_results,
        "correctness_gates" => base_gates,
        "correctness_passed" => correctness_passed,
        "anchor_expansion_authorized" => expansion_authorized,
        "frame_rows" => Dict(
            "count" => length(frame_rows),
            "canonical_sha256" => frame_rows_sha256),
        "iteration_rows" => Dict(
            "count" => length(iteration_rows),
            "canonical_sha256" => iteration_rows_sha256),
        "frame_gates" => Dict(
            "count" => length(frame_gate_records),
            "canonical_sha256" => frame_gates_sha256),
        "claim_boundary" => "separates two uses of constructed retained offsets on a projected-gradient backbone; does not establish BP equivalence or uniquely explain the native BP-versus-projected-GD gap",
    )
    science_hash = scientific_sha256(science)
    begin_phase!(phases, "pass_completed";
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames),
        arms_completed=length(specs), arms_total=length(specs),
        status="running")
    finish_phase!(phases; status="pass_completed",
        frames_completed=total_frames, frames_total=total_frames,
        last_completed_frame=last(frames), arms_completed=length(specs),
        arms_total=length(specs))
    (; science, frame_rows, iteration_rows, runtime_rows, snapshot_payload,
       frame_gate_records, expansion_authorized, correctness_passed,
       science_hash)
end

# ---------------------------------------------------------------------------
# Immutable results, deterministic replay, and CLI
# ---------------------------------------------------------------------------

function aggregate_rows(science)
    rows = NamedTuple[]
    for endpoint in sort!(collect(keys(science["endpoint_results"])))
        contrasts = science["endpoint_results"][endpoint]["contrasts"]
        for contrast in CONTRASTS
            result = contrasts[contrast.id]
            interval = get(result, "newcombe_interval", nothing)
            push!(rows, (;
                endpoint,
                contrast_id=contrast.id,
                treatment_arm=String(result["treatment"]),
                reference_arm=String(result["reference"]),
                pairs=Int(result["pairs"]),
                both_success=Int(result["both_success"]),
                treatment_only_success=Int(
                    result["treatment_only_success"]),
                reference_only_success=Int(
                    result["reference_only_success"]),
                both_failure=Int(result["both_failure"]),
                treatment_successes=Int(result["treatment_successes"]),
                reference_successes=Int(result["reference_successes"]),
                risk_difference_treatment_minus_reference=Float64(
                    result["risk_difference_treatment_minus_reference"]),
                interval_confidence_level=interval === nothing ? missing :
                    Float64(interval["confidence_level"]),
                interval_lower=interval === nothing ? missing :
                    Float64(interval["lower"]),
                interval_upper=interval === nothing ? missing :
                    Float64(interval["upper"]),
                mcnemar_exact_two_sided_pvalue=
                    haskey(result, "mcnemar_exact_two_sided_pvalue") ?
                    Float64(result["mcnemar_exact_two_sided_pvalue"]) : missing,
                holm_adjusted_pvalue=
                    haskey(result, "holm_adjusted_pvalue") ?
                    Float64(result["holm_adjusted_pvalue"]) : missing,
            ))
        end
    end
    rows
end

function interaction_rows(science)
    rows = NamedTuple[]
    for endpoint in sort!(collect(keys(science["endpoint_results"])))
        interaction = science["endpoint_results"][endpoint]["interaction"]
        bootstrap = get(interaction, "bootstrap", nothing)
        counts = interaction["frame_score_counts"]
        push!(rows, (;
            endpoint,
            definition=String(interaction["definition"]),
            frames=Int(interaction["frames"]),
            score_sum=Int(interaction["score_sum"]),
            risk_difference_interaction=Float64(
                interaction["risk_difference_interaction"]),
            score_minus2=Int(counts["-2"]),
            score_minus1=Int(counts["-1"]),
            score_zero=Int(counts["0"]),
            score_plus1=Int(counts["1"]),
            score_plus2=Int(counts["2"]),
            bootstrap_resamples=bootstrap === nothing ? missing :
                Int(bootstrap["resamples"]),
            bootstrap_seed=bootstrap === nothing ? missing :
                Int(bootstrap["seed"]),
            interval_confidence_level=bootstrap === nothing ? missing :
                Float64(bootstrap["confidence_level"]),
            interval_lower=bootstrap === nothing ? missing :
                Float64(bootstrap["lower"]),
            interval_upper=bootstrap === nothing ? missing :
                Float64(bootstrap["upper"]),
        ))
    end
    rows
end

function write_snapshot_archive(output, frame::Int, payload)
    payload === nothing && return nothing
    rows = snapshot_rows(frame, payload)
    csv_path = joinpath(output, "frame_first_state_snapshots.csv")
    write_csv(csv_path, rows, propertynames(first(rows)))
    run(`gzip -n $csv_path`)
    csv_path * ".gz"
end

function fsync_file(path::AbstractString)
    open(path, "a") do io
        flush(io)
        ccall(:fsync, Cint, (Cint,), fd(io)) == 0 ||
            error("cannot fsync checkpoint file: $path")
    end
    path
end

function fsync_directory(path::AbstractString)
    directory = abspath(path)
    directory_fd = ccall(:open, Cint, (Cstring, Cint), directory, 0)
    directory_fd >= 0 || error("cannot open checkpoint directory for fsync: $path")
    try
        ccall(:fsync, Cint, (Cint,), directory_fd) == 0 ||
            error("cannot fsync checkpoint directory: $path")
    finally
        ccall(:close, Cint, (Cint,), directory_fd)
    end
    path
end

function write_primary_checkpoint(output::AbstractString, calculated)
    checkpoint = joinpath(abspath(output), "primary_checkpoint")
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

function write_result(output::AbstractString, config, config_path, freeze,
                      stage::Symbol, calculated, replay_hash::String,
                      replay_passed::Bool, command::String;
                      anchor_result::Union{Nothing,String}=nothing,
                      progress_started_utc::AbstractString="",
                      write_phase::Union{Nothing,PhaseTracker}=nothing)
    output = abspath(output)
    isdir(output) || throw(ArgumentError(
        "precreated result directory is missing: $output"))
    allowed = Set([
        String(config["progress"]["filename"]),
        "phase_log.tsv",
        "primary_checkpoint",
    ])
    Set(readdir(output)) == allowed || throw(ArgumentError(
        "result directory does not contain exactly the registered telemetry and primary checkpoint"))
    checkpoint = joinpath(output, "primary_checkpoint")
    Set(readdir(checkpoint)) == Set([
        "frames.csv", "iterations.csv", "science.json"]) ||
        throw(ArgumentError("primary checkpoint is incomplete or has extra files"))
    science = calculated.science
    base_scientific_sha256 = scientific_sha256(science)
    science["deterministic_replay"] = Dict(
        "first_sha256" => base_scientific_sha256,
        "second_sha256" => replay_hash,
        "passed" => replay_passed,
    )
    science["correctness_gates"]["deterministic_replay"] = replay_passed
    science["correctness_passed"] &= replay_passed
    if stage === :anchor
        science["anchor_expansion_authorized"] =
            science["correctness_passed"]
    end
    science_path = joinpath(output, "science.json")
    write_new_file(science_path, canonical_json(science) * "\n")
    write_csv(joinpath(output, "frames.csv"), calculated.frame_rows,
              propertynames(first(calculated.frame_rows)))
    write_csv(joinpath(output, "iterations.csv"), calculated.iteration_rows,
              propertynames(first(calculated.iteration_rows)))
    write_csv(joinpath(output, "runtime.csv"), calculated.runtime_rows,
              propertynames(first(calculated.runtime_rows)))
    aggregates = aggregate_rows(science)
    write_csv(joinpath(output, "aggregate.csv"), aggregates,
              propertynames(first(aggregates)))
    interactions = interaction_rows(science)
    write_csv(joinpath(output, "interaction.csv"), interactions,
              propertynames(first(interactions)))
    snapshot_path = write_snapshot_archive(output,
        Int(science["frame_first"]), calculated.snapshot_payload)

    source_directory = joinpath(output, "source")
    mkdir(source_directory)
    source_records = archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "created_utc" => string(now(UTC)),
        "command" => String(command),
        "freeze" => abspath(freeze),
        "freeze_manifest_sha256" => file_sha256(joinpath(
            freeze, "freeze_manifest.toml")),
        "freeze_checksum_manifest_sha256" => file_sha256(joinpath(
            freeze, "MANIFEST.sha256")),
        "anchor_result" => anchor_result === nothing ? "" :
            abspath(anchor_result),
        "anchor_completion_sha256" => anchor_result === nothing ? "" :
            file_sha256(joinpath(anchor_result, "COMPLETED.toml")),
        "base_scientific_sha256" => base_scientific_sha256,
        "stored_scientific_sha256" => scientific_sha256(science),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_threads" => Threads.nthreads(),
            "blas_threads" => BLAS.get_num_threads(),
            "cpu" => Sys.CPU_NAME,
        ),
        "source" => Dict(
            "sp_head" => git_output(HERE, "rev-parse", "HEAD"),
            "sp_branch" => git_output(HERE, "branch", "--show-current"),
            "sp_status" => git_output(HERE, "status", "--porcelain=v1",
                                      "--untracked-files=all"),
            "jade_head" => git_output(String(
                config["sources"]["jade_project_repo"]), "rev-parse", "HEAD"),
            "sources" => source_records,
        ),
        "snapshot" => snapshot_path === nothing ? "" : basename(snapshot_path),
        "primary_checkpoint" => "primary_checkpoint",
        "primary_checkpoint_science_sha256" => file_sha256(joinpath(
            checkpoint, "science.json")),
        "progress_journal" => String(config["progress"]["filename"]),
        "phase_log" => "phase_log.tsv",
        "progress_excluded_from_scientific_and_checksum_hashes" => true,
        "phase_log_included_in_checksum_hashes" => true,
    )
    manifest_path = joinpath(output, "manifest.toml")
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    status = science["correctness_passed"] ?
        "complete_valid" : "complete_invalid"
    completion = Dict(
        "schema_version" => String(
            config["provenance"]["completion_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "completed_utc" => string(now(UTC)),
        "status" => status,
        "correctness_passed" => Bool(science["correctness_passed"]),
        "deterministic_replay_passed" => replay_passed,
        "anchor_expansion_authorized" => Bool(
            science["anchor_expansion_authorized"]),
        "science_sha256" => file_sha256(science_path),
        "manifest_sha256" => file_sha256(manifest_path),
    )
    completion_path = joinpath(output, "COMPLETED.toml")
    open(completion_path, "w") do io
        TOML.print(io, completion; sorted=true)
    end
    write_phase !== nothing && close_current_phase!(write_phase)
    checksums = write_result_checksum_manifest(output)
    (; output, science, completion,
       checksum_entries=length(checksums.entries))
end

function validate_anchor_handoff(config, anchor_result::AbstractString,
                                 freeze::AbstractString)
    completion_path = joinpath(anchor_result, "COMPLETED.toml")
    manifest_path = joinpath(anchor_result, "manifest.toml")
    isfile(completion_path) || throw(ArgumentError(
        "anchor completion is missing"))
    isfile(manifest_path) || throw(ArgumentError("anchor manifest is missing"))
    checksum = verify_result_checksum_manifest(anchor_result)
    completion = TOML.parsefile(completion_path)
    manifest = TOML.parsefile(manifest_path)
    checks = Dict(
        "checksums" => Bool(checksum["passed"]),
        "experiment" => completion["experiment_id"] ==
            config["experiment_id"],
        "stage" => completion["stage"] == "anchor",
        "status" => completion["status"] == "complete_valid",
        "correctness" => completion["correctness_passed"] == true,
        "replay" => completion["deterministic_replay_passed"] == true,
        "expansion" => completion["anchor_expansion_authorized"] == true,
        "freeze" => manifest["freeze_manifest_sha256"] ==
            file_sha256(joinpath(freeze, "freeze_manifest.toml")),
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function run_stage(stage::Symbol, output::AbstractString,
                   freeze::AbstractString;
                   config_path::AbstractString=DEFAULT_CONFIG,
                   anchor_result::Union{Nothing,String}=nothing,
                   command::AbstractString=String(stage))
    config = load_config(config_path)
    output = abspath(output)
    ispath(output) && throw(ArgumentError(
        "result output already exists: $output"))
    if stage === :heldout
        anchor_result === nothing && throw(ArgumentError(
            "held-out execution requires --anchor-result"))
        handoff = validate_anchor_handoff(config, anchor_result, freeze)
        handoff["passed"] || throw(ArgumentError(
            "anchor did not authorize held-out execution: $(handoff["checks"])"))
    end
    mkpath(dirname(output))
    mkdir(output)
    progress_path = joinpath(output, String(config["progress"]["filename"]))
    started = string(now(UTC))
    total_frames = length(stage_frames(config, stage))
    atomic_write_progress(progress_path;
        stage=String(stage), pass_name="primary", status="starting",
        frames_completed=0, frames_total=total_frames,
        started_utc=started, phase="run_start",
        phase_started_utc=started)
    try
        calculated = calculate_science(config, freeze, stage;
            collect_runtime=true, config_path, progress_path,
            pass_name="primary", progress_started_utc=started)
        checkpoint_phase = PhaseTracker(progress_path, String(stage),
            "primary", started)
        begin_phase!(checkpoint_phase, "primary_checkpoint";
            frames_completed=total_frames, frames_total=total_frames,
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(REQUIRED_ARMS),
            arms_total=length(REQUIRED_ARMS))
        write_primary_checkpoint(output, calculated)
        finish_phase!(checkpoint_phase; status="checkpoint_complete",
            frames_completed=total_frames, frames_total=total_frames,
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(REQUIRED_ARMS),
            arms_total=length(REQUIRED_ARMS))
        replay = calculate_science(config, freeze, stage;
            collect_runtime=false, config_path, progress_path,
            pass_name="replay", progress_started_utc=started)
        first_hash = calculated.science_hash
        replay_hash = replay.science_hash
        replay_passed = first_hash == replay_hash
        write_phase = PhaseTracker(progress_path, String(stage),
            "artifact", started)
        begin_phase!(write_phase, "write_result";
            frames_completed=total_frames, frames_total=total_frames,
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(REQUIRED_ARMS),
            arms_total=length(REQUIRED_ARMS))
        written = write_result(output, config, config_path, freeze, stage,
            calculated, replay_hash, replay_passed, String(command);
            anchor_result, progress_started_utc=started, write_phase)
        finish_phase!(write_phase;
            status=String(written.completion["status"]),
            frames_completed=total_frames, frames_total=total_frames,
            last_completed_frame=last(stage_frames(config, stage)),
            arms_completed=length(REQUIRED_ARMS),
            arms_total=length(REQUIRED_ARMS))
        return written
    catch exception
        mark_progress_failed(progress_path, String(stage), total_frames,
                             started, exception)
        rethrow()
    end
end

function replay_result(result::AbstractString;
                       config_path::AbstractString=DEFAULT_CONFIG)
    result = abspath(result)
    checksum = verify_result_checksum_manifest(result)
    checksum["passed"] || throw(ArgumentError(
        "result checksum verification failed: $(checksum["failures"])"))
    manifest = TOML.parsefile(joinpath(result, "manifest.toml"))
    completion = TOML.parsefile(joinpath(result, "COMPLETED.toml"))
    config = load_config(config_path)
    stage = Symbol(manifest["stage"])
    freeze = String(manifest["freeze"])
    freeze_validation = validate_freeze(config, freeze;
        config_path, regenerate=true)
    freeze_validation["passed"] || throw(ArgumentError(
        "frozen input gate failed during replay"))
    recalculated = calculate_science(config, freeze, stage;
        collect_runtime=false, config_path)
    stored_manifest_hash = String(manifest["base_scientific_sha256"])
    recalculated_hash = scientific_sha256(recalculated.science)
    passed = recalculated_hash == stored_manifest_hash &&
        completion["status"] == "complete_valid"
    Dict(
        "passed" => passed,
        "checksum_passed" => checksum["passed"],
        "freeze_passed" => freeze_validation["passed"],
        "expected_scientific_sha256" => stored_manifest_hash,
        "recalculated_scientific_sha256" => recalculated_hash,
        "stored_science_file_sha256" => file_sha256(joinpath(
            result, "science.json")),
    )
end

function usage()
    "usage:\n" *
    "  rq2_gd_offset_split_001.jl preflight-probe [--config FILE]\n" *
    "  rq2_gd_offset_split_001.jl freeze --output DIR [--config FILE]\n" *
    "  rq2_gd_offset_split_001.jl anchor --freeze DIR --output DIR [--config FILE]\n" *
    "  rq2_gd_offset_split_001.jl heldout --freeze DIR --anchor-result DIR --output DIR [--config FILE]\n" *
    "  rq2_gd_offset_split_001.jl replay --result DIR [--config FILE]"
end

function main(arguments=ARGS)
    parsed = Legacy.parse_cli(arguments)
    parsed.help && (println(usage()); return 0)
    config_path = get(parsed.options, "config", DEFAULT_CONFIG)
    command = join(vcat(
        ["julia", "--project=" * something(Base.active_project(), ""),
         RUNNER_PATH],
        String.(arguments)), " ")
    if parsed.mode === Symbol("preflight-probe")
        config = load_config(config_path)
        preflight = preflight_gate(config_path)
        preflight["passed"] || throw(ArgumentError(
            "locked preflight record does not match the authored sources"))
        gate = source_gate(config)
        gate["passed"] || throw(ArgumentError("retained-source gate failed"))
        enforce_thread_environment(config)
        native = load_native(config)
        generated = make_code(config, native)
        println("experiment: ", config["experiment_id"])
        println("graph SHA-256: ", graph_sha256(generated.code.check_vars))
        println("arms: ", join((spec.name for spec in arm_specs(config)), ","))
        return 0
    elseif parsed.mode === :freeze
        output = get(parsed.options, "output", nothing)
        output === nothing && throw(ArgumentError("freeze requires --output"))
        frozen = freeze_inputs(output; config_path, command)
        println("frozen input rows: ", frozen["input_rows"])
        println("freeze manifest SHA-256: ",
                frozen["freeze_manifest_sha256"])
        return 0
    elseif parsed.mode in (:anchor, :heldout)
        freeze = get(parsed.options, "freeze", nothing)
        output = get(parsed.options, "output", nothing)
        freeze === nothing && throw(ArgumentError(
            "$(parsed.mode) requires --freeze"))
        output === nothing && throw(ArgumentError(
            "$(parsed.mode) requires --output"))
        anchor_result = get(parsed.options, "anchor-result", nothing)
        written = run_stage(parsed.mode, output, freeze;
            config_path, anchor_result, command)
        println("$(parsed.mode) status: ", written.completion["status"])
        println("correctness passed: ",
                written.completion["correctness_passed"])
        println("expansion authorized: ",
                written.completion["anchor_expansion_authorized"])
        return written.completion["correctness_passed"] ? 0 : 2
    elseif parsed.mode === :replay
        result_path = get(parsed.options, "result", nothing)
        result_path === nothing && throw(ArgumentError(
            "replay requires --result"))
        replay = replay_result(result_path; config_path)
        println("replay passed: ", replay["passed"])
        println("scientific SHA-256: ",
                replay["recalculated_scientific_sha256"])
        return replay["passed"] ? 0 : 2
    end
    throw(ArgumentError("unsupported mode $(parsed.mode)\n$(usage())"))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(Base.invokelatest(main))
end

end # module
