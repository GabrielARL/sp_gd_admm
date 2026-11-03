#!/usr/bin/env julia

module RQ2GDResidualProjectionBudget001

using Dates
using JadeJcade
using LinearAlgebra
using SHA
using Statistics
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const V4_RUNNER_PATH = normpath(joinpath(
    HERE, "..", "rq2_gd_parity_assignment_refresh_001",
    "rq2_gd_parity_assignment_refresh_001.jl"))

include(V4_RUNNER_PATH)
const V4 = RQ2GDParityAssignmentRefresh001
const Split = V4.Split
const Legacy = V4.Legacy
const BridgeProblem = Legacy.BridgeProblem
const CORE = JadeJcade.ReceiverCore

const file_sha256 = Legacy.file_sha256
const vector_sha256 = Legacy.vector_sha256
const edge_sha256 = Legacy.edge_sha256
const canonical_json = Legacy.canonical_json
const scientific_sha256 = V4.scientific_sha256

const CAMPAIGN_EXPERIMENT_ID = "RQ2-CAUSAL-FACTORS-001"
const CAMPAIGN_COMPLETION_SCHEMA =
    "rq2-causal-factors-001/result-completion-v1"
const CAMPAIGN_ENDPOINT_SCHEMA =
    "rq2-causal-factors-001/endpoint-gate-v1"
const CAMPAIGN_TIMING_SCHEMA = "rq2-causal-factors-001/stage-timing-v1"

struct ArmSpec
    name::String
    parity_rule::Symbol
    projection_rule::Symbol
end

const ARMS = (
    ArmSpec("compound__box", :compound, :box),
    ArmSpec("product_only__box", :product_only, :box),
    ArmSpec("compound__unconstrained", :compound, :unconstrained),
    ArmSpec("product_only__unconstrained", :product_only, :unconstrained),
)

const STAGES = (:calibration, :anchor, :transfer, :attribution)

resolve_here(path::AbstractString) = isabspath(path) ? normpath(path) :
    normpath(joinpath(HERE, path))

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] ==
        "rq2-gd-residual-projection-budget-001/v1" ||
        throw(ArgumentError("unsupported schema"))
    config["experiment_id"] ==
        "RQ2-GD-RESIDUAL-PROJECTION-BUDGET-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["scope"]["admm_included"] == false ||
        throw(ArgumentError("ADMM is outside this experiment"))
    config["scope"]["bp_arm_included"] == false ||
        throw(ArgumentError("a BP arm is outside this experiment"))
    String.(config["arms"]["order"]) == [arm.name for arm in ARMS] ||
        throw(ArgumentError("arm order changed"))
    Int(config["arms"]["common_update"]) == 1 ||
        throw(ArgumentError("common update changed"))
    Int(config["solver"]["maximum_update_attempts"]) == 90 ||
        throw(ArgumentError("registered update budget changed"))
    Int.(config["solver"]["score_updates"]) == [30, 90] ||
        throw(ArgumentError("registered score updates changed"))
    provenance = config["provenance"]
    String(provenance["campaign_experiment_id"]) ==
        CAMPAIGN_EXPERIMENT_ID ||
        throw(ArgumentError("campaign experiment identifier changed"))
    String(provenance["completion_schema"]) ==
        CAMPAIGN_COMPLETION_SCHEMA ||
        throw(ArgumentError("campaign completion schema changed"))
    String(provenance["endpoint_gate_schema"]) ==
        CAMPAIGN_ENDPOINT_SCHEMA ||
        throw(ArgumentError("campaign endpoint schema changed"))
    String(provenance["timing_schema"]) == CAMPAIGN_TIMING_SCHEMA ||
        throw(ArgumentError("campaign timing schema changed"))
    for stage in STAGES
        section = config[String(stage)]
        first = Int(section["frame_first"])
        last = Int(section["frame_last"])
        last - first + 1 == Int(section["expected_count"]) ||
            throw(ArgumentError("$stage frame count does not match its range"))
    end
    config
end

function stage_frames(config, stage::Symbol)
    stage in STAGES || throw(ArgumentError("unknown stage $stage"))
    section = config[String(stage)]
    Int(section["frame_first"]):Int(section["frame_last"])
end

v4_config_path(config) = resolve_here(String(config["sources"]["v4_config"]))

function source_gate(config)
    sources = config["sources"]
    checks = Dict(
        "v4_runner" => file_sha256(V4_RUNNER_PATH) ==
            String(sources["v4_runner_sha256"]),
        "v4_config" => file_sha256(v4_config_path(config)) ==
            String(sources["v4_config_sha256"]),
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function frozen_reference_paths(config, freeze::AbstractString)
    inputs = config["freeze_inputs"]
    Dict(
        "frames" => normpath(joinpath(freeze,
            String(inputs["frozen_calibration_frames"]))),
        "completion" => normpath(joinpath(freeze,
            String(inputs["frozen_calibration_completion"]))),
        "manifest" => normpath(joinpath(freeze,
            String(inputs["frozen_calibration_manifest"]))),
    )
end

function frozen_reference_gate(config, freeze::AbstractString)
    paths = frozen_reference_paths(config, freeze)
    inputs = config["freeze_inputs"]
    checks = Dict(
        "frames" => isfile(paths["frames"]) &&
            file_sha256(paths["frames"]) ==
                String(inputs["calibration_v4_frames_sha256"]),
        "completion" => isfile(paths["completion"]) &&
            file_sha256(paths["completion"]) ==
                String(inputs["calibration_v4_completion_sha256"]),
        "manifest" => isfile(paths["manifest"]) &&
            file_sha256(paths["manifest"]) ==
                String(inputs["calibration_v4_manifest_sha256"]),
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "paths" => paths)
end

function copy_new(source::AbstractString, destination::AbstractString)
    isfile(source) || throw(ArgumentError("missing freeze input $source"))
    ispath(destination) && throw(ArgumentError("refusing to overwrite $destination"))
    mkpath(dirname(destination))
    cp(source, destination; force=false)
    destination
end

"""Copy and hash-pin the retained v4 anchor evidence used by calibration."""
function prepare_freeze(output::AbstractString;
                        config_path::AbstractString=DEFAULT_CONFIG)
    config = load_config(config_path)
    ispath(output) && throw(ArgumentError("refusing to overwrite freeze $output"))
    source = String(config["freeze_inputs"]["calibration_v4_result_source"])
    mkpath(output)
    try
        paths = frozen_reference_paths(config, output)
        copy_new(joinpath(source, "frames.csv"), paths["frames"])
        copy_new(joinpath(source, "COMPLETED.toml"), paths["completion"])
        copy_new(joinpath(source, "MANIFEST.sha256"), paths["manifest"])
        gate = frozen_reference_gate(config, output)
        gate["passed"] || error("frozen v4 reference hash gate failed")
        manifest = Dict(
            "schema_version" =>
                "rq2-gd-residual-projection-budget-001/freeze-v1",
            "experiment_id" => config["experiment_id"],
            "created_utc" => string(now(UTC)),
            "v4_frames_sha256" => file_sha256(paths["frames"]),
            "v4_completion_sha256" => file_sha256(paths["completion"]),
            "v4_manifest_sha256" => file_sha256(paths["manifest"]),
            "config_sha256" => file_sha256(config_path),
            "runner_sha256" => file_sha256(@__FILE__),
        )
        open(joinpath(output, "freeze_manifest.toml"), "w") do io
            TOML.print(io, manifest; sorted=true)
            write(io, '\n')
        end
        return manifest
    catch
        rm(output; recursive=true, force=true)
        rethrow()
    end
end

# ---------------------------------------------------------------------------
# Declared objectives and independent derivative checks
# ---------------------------------------------------------------------------

"""Evaluate the product-only objective in the same check/bit order as v4."""
function product_only_evaluate!(workspace::Legacy.EvalWorkspace,
                                problem::BridgeProblem, x, delta_rows)
    n = length(problem.llr)
    length(x) == n || throw(DimensionMismatch("scalar state length changed"))
    fill!(workspace.gradient, 0.0)
    fill!(workspace.h, 0.0)
    for row in workspace.g_rows
        fill!(row, 0.0)
    end

    coefficient = -2.0 * problem.parity_weight / n
    parity = 0.0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        product = 1.0
        for (slot, bit) in enumerate(check)
            workspace.prefix[slot] = product
            product *= Float64(x[bit]) + Float64(delta_rows[check_index][slot])
        end
        parity += coefficient * product
        suffix = 1.0
        for slot in length(check):-1:1
            bit = check[slot]
            contribution = coefficient * workspace.prefix[slot] * suffix
            workspace.gradient[bit] += contribution
            workspace.g_rows[check_index][slot] = contribution
            suffix *= Float64(x[bit]) + Float64(delta_rows[check_index][slot])
        end
    end

    binary = 0.0
    @inbounds for bit in eachindex(x)
        value = Float64(x[bit])
        binary_contribution =
            4problem.binary_weight * value * (value^2 - 1.0) / n
        binary += problem.binary_weight * (1.0 - value^2)^2 / n
        workspace.gradient[bit] += binary_contribution
        workspace.h[bit] = -problem.llr[bit] / (2n) + binary_contribution
    end
    channel = -dot(problem.llr, x) / (2n)
    @inbounds for bit in eachindex(x)
        workspace.gradient[bit] -= problem.llr[bit] / (2n)
    end
    (; loss=channel + parity + binary,
       terms=(; channel, parity, binary),
       gradient=workspace.gradient, h=workspace.h, g_rows=workspace.g_rows)
end

function evaluate_objective!(workspace::Legacy.EvalWorkspace,
                             problem::BridgeProblem, x, delta_rows,
                             parity_rule::Symbol)
    parity_rule === :compound && return Legacy.bridge_evaluate!(
        workspace, problem, x, delta_rows; consume_offsets=true)
    parity_rule === :product_only && return product_only_evaluate!(
        workspace, problem, x, delta_rows)
    throw(ArgumentError("unknown parity rule $parity_rule"))
end

function independent_local_objective(problem::BridgeProblem, x, delta_rows,
                                     bit::Int, replacement::Float64,
                                     parity_rule::Symbol)
    n = length(x)
    value = -problem.llr[bit] * replacement / (2n) +
        problem.binary_weight * (1.0 - replacement^2)^2 / n
    for (check_index, _) in problem.var_edges[bit]
        product = 1.0
        for (slot, other_bit) in enumerate(problem.check_vars[check_index])
            scalar = other_bit == bit ? replacement : Float64(x[other_bit])
            product *= scalar + Float64(delta_rows[check_index][slot])
        end
        if parity_rule === :compound
            value += problem.parity_weight * (1.0 - product)^2 / n
        elseif parity_rule === :product_only
            value += -2.0 * problem.parity_weight * product / n
        else
            throw(ArgumentError("unknown parity rule $parity_rule"))
        end
    end
    value
end

function finite_difference_maximum(problem::BridgeProblem, x, delta_rows,
                                   analytic_gradient, parity_rule::Symbol;
                                   step::Float64=1.0e-6)
    maximum_error = 0.0
    maximum_bit = 0
    delta_before = edge_sha256(delta_rows)
    for bit in eachindex(x)
        center = Float64(x[bit])
        objective(replacement) = independent_local_objective(
            problem, x, delta_rows, bit, replacement, parity_rule)
        numerical = (objective(center - 2step) - 8objective(center - step) +
                     8objective(center + step) - objective(center + 2step)) /
                    (12step)
        error = abs(numerical - Float64(analytic_gradient[bit]))
        if error > maximum_error
            maximum_error = error
            maximum_bit = bit
        end
    end
    (; maximum_error, maximum_bit,
       delta_sha256_before=delta_before,
       delta_sha256_after=edge_sha256(delta_rows))
end

function state_metrics(problem::BridgeProblem, code, x)
    hard = BitVector(Float64(value) < 0.0 for value in x)
    hard == Legacy.hard_decision_independent(x) ||
        error("independent hard decision disagrees")
    syndrome = Legacy.syndrome_vector(problem.check_vars, hard)
    syndrome_weight = sum(syndrome)
    syndrome_weight == JadeJcade.ReceiverCore._syndrome_weight(code, hard) ||
        error("independent syndrome disagrees")
    (; hard, syndrome, syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       coded_bit_errors=count(hard),
       hard_word_sha256=vector_sha256(hard),
       scalar_sha256=vector_sha256(x),
       maximum_absolute_scalar=maximum(abs, x))
end

function make_bp_code(split, maximum_iterations::Int)
    modem = JadeJcade.Jade.Modulation(
        ldpc_k=Int(split["code"]["k"]),
        ldpc_n=Int(split["code"]["n"]),
        ldpc_npc=Int(split["code"]["variable_degree"]),
        ldpc_method=:evenboth,
        ldpc_seed=Int(split["code"]["graph_seed"]),
        ldpc_no4cycle=false,
        inner_pilot_ratio=0.0,
        pilot_ratio=0.0,
        bp_iterations=maximum_iterations)
    code = CORE._code(modem)
    Legacy.graph_sha256(code.check_vars) == String(split["code"]["graph_sha256"]) ||
        error("BP endpoint graph differs from the registered graph")
    (; modem, code)
end

function decode_bp_endpoint(modem, code, llr)
    value = CORE._bp_decode_sum_product(modem, code, -llr)
    scratch = CORE._bp_scratch(modem, code)
    hard = BitVector(copy(scratch.bits))
    syndrome = Legacy.syndrome_vector([Int.(check) for check in code.check_vars], hard)
    syndrome_weight = sum(syndrome)
    syndrome_weight == CORE._syndrome_weight(code, hard) ||
        error("BP endpoint syndrome disagrees")
    (; hard, coded_bit_errors=count(hard), syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       iterations=Int(value.iterations), status="native_bp")
end

function decode_native_gd_endpoint(split, code, llr, maximum_updates::Int)
    problem = BridgeProblem(code, llr;
        parity_weight=Float64(split["projected_gradient"]["parity_weight"]),
        binary_weight=Float64(split["projected_gradient"]["binary_weight"]))
    validation = split["validation"]
    result = Split.solve_variant(
        problem, code, tanh.(llr ./ 2.0), Split.REQUIRED_ARMS[1];
        maximum_updates,
        initial_step=Float64(split["projected_gradient"]["initial_step"]),
        maximum_backtracks=Int(split["projected_gradient"]["maximum_backtracks"]),
        collect_trace=false, collect_diagnostics=true,
        validate_derivatives=false,
        mean_tolerance=Float64(validation["mean_offset_tolerance"]),
        box_tolerance=Float64(validation["box_tolerance"]))
    (; result.hard, result.coded_bit_errors, result.syndrome_weight,
       result.parity_valid, result.transmitted_word_equal,
       iterations=result.accepted_steps, status=result.status)
end

function endpoint_row(frame::Int, method::String, decoded, input)
    (; frame, method,
       coded_bit_errors=decoded.coded_bit_errors,
       syndrome_weight=decoded.syndrome_weight,
       parity_valid=decoded.parity_valid,
       transmitted_word_equal=decoded.transmitted_word_equal,
       iterations=decoded.iterations,
       status=decoded.status,
       hard_word_sha256=vector_sha256(decoded.hard),
       received_sha256=input.identities.received_sha256,
       clipped_llr_sha256=input.identities.clipped_llr_sha256)
end

function endpoint_row_from_v4(frame::Int, observed, input)
    (; frame, method="v4_asbuilt_frozen",
       coded_bit_errors=observed.coded_bit_errors,
       syndrome_weight=observed.syndrome_weight,
       parity_valid=observed.parity_valid,
       transmitted_word_equal=observed.transmitted_word_equal,
       iterations=observed.effective_update,
       status=observed.checkpoint_reached ? "steps_completed" :
           "line_search_stalled",
       hard_word_sha256=observed.hard_word_sha256,
       received_sha256=input.identities.received_sha256,
       clipped_llr_sha256=input.identities.clipped_llr_sha256)
end

function endpoint_gate_summary(rows, config, stage::Symbol)
    methods = String.(config["endpoint_gate"]["methods"])
    frames = sort!(unique(row.frame for row in rows))
    counts = Dict{String,Any}()
    for method in methods
        selected = [row for row in rows if row.method == method]
        length(selected) == length(frames) ||
            error("endpoint method $method does not have one row per frame")
        counts[method] = Dict(
            "cases" => length(selected),
            "transmitted_word_equal" =>
                count(row -> row.transmitted_word_equal, selected),
            "parity_valid" => count(row -> row.parity_valid, selected),
        )
    end
    canonical_rows = [(; row.frame, row.method,
        row.hard_word_sha256, row.coded_bit_errors, row.syndrome_weight,
        row.parity_valid, row.transmitted_word_equal)
        for row in sort(rows; by=row -> (row.frame, row.method))]
    hard_table_hash = scientific_sha256(canonical_rows)
    v4_budget_passed = all(
        row.method != "v4_asbuilt_frozen" ||
            (row.iterations == 30 && row.status == "steps_completed")
        for row in rows)
    expected_passed = true
    expected_applied = stage === :attribution
    if expected_applied
        expected_exact = config["endpoint_gate"][
            "attribution_expected_transmitted_word_equal"]
        expected_valid = config["endpoint_gate"][
            "attribution_expected_parity_valid"]
        for method in methods
            expected_passed &=
                counts[method]["transmitted_word_equal"] ==
                    Int(expected_exact[method])
            expected_passed &=
                counts[method]["parity_valid"] ==
                    Int(expected_valid[method])
        end
    end
    Dict(
        "schema_version" =>
            "rq2-gd-residual-projection-budget-001/endpoint-gate-v1",
        "stage" => String(stage),
        "methods" => methods,
        "counts" => counts,
        "hard_word_table_sha256" => hard_table_hash,
        "expected_counts_applied" => expected_applied,
        "expected_counts_passed" => expected_passed,
        "v4_update30_reached" => v4_budget_passed,
        "passed" => v4_budget_passed &&
            (!expected_applied || expected_passed),
    )
end

"""Return Block A's exact campaign-level endpoint sentinel fields."""
function campaign_endpoint_fields(rows)
    method_names = (
        native_gd="gd_native_projected",
        v4_asbuilt_frozen="v4_asbuilt_frozen",
        native_bp="bp_exact_sum_product",
    )
    frames = sort!(unique(Int(row.frame) for row in rows))
    isempty(frames) && throw(ArgumentError("endpoint rows are empty"))
    lookup = Dict{Tuple{Int,String},Any}()
    for row in rows
        key = (Int(row.frame), String(row.method))
        haskey(lookup, key) && error("duplicate endpoint row $key")
        lookup[key] = row
    end
    expected_keys = Set((frame, method) for frame in frames
                        for method in values(method_names))
    Set(keys(lookup)) == expected_keys || error(
        "endpoint rows do not contain exactly one row per frame and method")

    channel_pairs = Any[]
    for frame in frames
        hashes = unique(String(lookup[(frame, method)].clipped_llr_sha256)
                        for method in values(method_names))
        length(hashes) == 1 || error(
            "endpoint methods used different channel LLRs on frame $frame")
        push!(channel_pairs, Any[frame, only(hashes)])
    end
    hard_words(method) = scientific_sha256(Any[
        Any[frame, String(lookup[(frame, method)].hard_word_sha256)]
        for frame in frames
    ])
    successes(method) = count(frame -> Bool(
        lookup[(frame, method)].transmitted_word_equal), frames)

    Dict{String,Any}(
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "frame_count" => length(frames),
        "frame_ids_sha256" => scientific_sha256(frames),
        "channel_llrs_sha256" => scientific_sha256(channel_pairs),
        "native_gd_successes" => successes(method_names.native_gd),
        "v4_asbuilt_frozen_successes" =>
            successes(method_names.v4_asbuilt_frozen),
        "native_bp_successes" => successes(method_names.native_bp),
        "native_gd_hard_words_sha256" => hard_words(method_names.native_gd),
        "v4_asbuilt_frozen_hard_words_sha256" =>
            hard_words(method_names.v4_asbuilt_frozen),
        "native_bp_hard_words_sha256" => hard_words(method_names.native_bp),
    )
end

"""Build the exact endpoint_gate.toml payload required by the campaign."""
function campaign_endpoint_gate(primary_rows, replay_rows, stage::Symbol)
    primary = campaign_endpoint_fields(primary_rows)
    replay = campaign_endpoint_fields(replay_rows)
    primary_digest = scientific_sha256(primary)
    replay_digest = scientific_sha256(replay)
    primary == replay || error("endpoint sentinel replay mismatch")
    gate_mode = stage in (:calibration, :attribution) ?
        "exact" : "self_consistency"
    merge(primary, Dict{String,Any}(
        "schema_version" => CAMPAIGN_ENDPOINT_SCHEMA,
        "experiment_id" => CAMPAIGN_EXPERIMENT_ID,
        "block" => "A",
        "stage" => String(stage),
        "gate_mode" => gate_mode,
        "sentinel_self_consistency_passed" => true,
        "primary_sentinel_sha256" => primary_digest,
        "replay_sentinel_sha256" => replay_digest,
    ))
end

function common_update_one(problem, code, initial, split, config)
    solver = config["solver"]
    validation = config["validation"]
    result = V4.solve_factorial_variant(
        problem, code, initial, :asbuilt__frozen;
        permutation_seed=0,
        maximum_updates=1,
        initial_step=Float64(solver["initial_step"]),
        maximum_backtracks=Int(solver["maximum_backtracks"]),
        collect_trace=true,
        collect_diagnostics=true,
        validate_derivatives=true,
        finite_difference_step=Float64(validation["finite_difference_step"]),
        finite_difference_tolerance=
            Float64(validation["finite_difference_tolerance"]),
        mean_tolerance=Float64(split["validation"]["mean_offset_tolerance"]),
        box_tolerance=Float64(split["validation"]["box_tolerance"]),
    )
    result.accepted_steps == 1 ||
        error("common update 1 was not accepted")
    result.offset_replacements == 1 ||
        error("common update 1 did not adopt exactly one offset state")
    result.all_finite_differences_passed ||
        error("common update 1 failed its derivative gate")
    result
end

function checkpoint_record(requested_update::Int, effective_update::Int,
                           reached::Bool, objective::Float64,
                           metrics, delta_rows)
    (; requested_update, effective_update, reached, objective,
       metrics.coded_bit_errors, metrics.syndrome_weight,
       metrics.parity_valid, metrics.transmitted_word_equal,
       metrics.hard_word_sha256,
       terminal_scalar_sha256=metrics.scalar_sha256,
       terminal_offset_sha256=edge_sha256(delta_rows),
       metrics.maximum_absolute_scalar)
end

function solve_arm(problem::BridgeProblem, code, initial, seed, spec::ArmSpec,
                   config)
    solver = config["solver"]
    validation = config["validation"]
    maximum_updates = Int(solver["maximum_update_attempts"])
    score_updates = Set(Int.(solver["score_updates"]))
    fd_updates = Set(Int.(validation["finite_difference_updates"]))
    fd_step = Float64(validation["finite_difference_step"])
    fd_tolerance = Float64(validation["finite_difference_tolerance"])
    initial_step = Float64(solver["initial_step"])
    maximum_backtracks = Int(solver["maximum_backtracks"])
    lower = Float64(solver["box_lower"])
    upper = Float64(solver["box_upper"])

    x = copy(seed.x)
    delta = Legacy.copy_edge_rows(seed.delta)
    trial = similar(x)
    raw_trial = similar(x)
    direction = similar(x)
    before_workspace = Legacy.EvalWorkspace(problem)
    trial_workspace = Legacy.EvalWorkspace(problem)
    traces = NamedTuple[]
    checkpoints = Dict{Int,Any}()
    accepted_steps = 1
    last_effective_update = 1
    status = "steps_completed"
    finite_difference_checks = 1
    maximum_fd_error = Float64(seed.trace[1]["finite_difference_maximum_error"])
    all_strict_decrease = true

    initial_metrics = state_metrics(problem, code, initial)
    seed_metrics = state_metrics(problem, code, x)
    first_valid_update = initial_metrics.parity_valid ? 0 :
        (seed_metrics.parity_valid ? 1 : nothing)
    first_exact_update = initial_metrics.transmitted_word_equal ? 0 :
        (seed_metrics.transmitted_word_equal ? 1 : nothing)

    seed_trace = seed.trace[1]
    push!(traces, (
        update=1, accepted=true, parity_rule="compound_common_update",
        projection_rule="box_common_update",
        loss_before=Float64(seed_trace["loss_before"]),
        loss_after=Float64(seed_trace["accepted_fixed_offset_loss"]),
        accepted_step=Float64(seed_trace["accepted_step"]),
        trial_count=Int(seed_trace["trial_count"]),
        finite_difference_checked=true,
        finite_difference_maximum_error=
            Float64(seed_trace["finite_difference_maximum_error"]),
        finite_difference_maximum_bit=
            Int(seed_trace["finite_difference_maximum_bit"]),
        x_before_sha256=String(seed_trace["x_before_sha256"]),
        x_after_sha256=String(seed_trace["x_after_sha256"]),
        delta_sha256=edge_sha256(delta),
        coded_bit_errors=seed_metrics.coded_bit_errors,
        syndrome_weight=seed_metrics.syndrome_weight,
        parity_valid=seed_metrics.parity_valid,
        transmitted_word_equal=seed_metrics.transmitted_word_equal,
    ))

    last_objective = evaluate_objective!(
        before_workspace, problem, x, delta, spec.parity_rule).loss

    for update in 2:maximum_updates
        before = evaluate_objective!(
            before_workspace, problem, x, delta, spec.parity_rule)
        x_before_hash = vector_sha256(x)
        fd_checked = update in fd_updates
        fd = if fd_checked
            finite_difference_maximum(problem, x, delta, before.gradient,
                                      spec.parity_rule; step=fd_step)
        else
            (; maximum_error=0.0, maximum_bit=0,
               delta_sha256_before=edge_sha256(delta),
               delta_sha256_after=edge_sha256(delta))
        end
        if fd_checked
            finite_difference_checks += 1
            maximum_fd_error = max(maximum_fd_error, fd.maximum_error)
            fd.delta_sha256_before == fd.delta_sha256_after ||
                error("finite differences changed the frozen offsets")
            fd.maximum_error <= fd_tolerance || error(
                "$(spec.name) derivative gate failed at update $update: " *
                "$(fd.maximum_error) > $fd_tolerance")
        end

        @inbounds for bit in eachindex(x)
            direction[bit] = -before.gradient[bit] /
                problem.curvature_bound[bit]
        end
        accepted = false
        accepted_step = 0.0
        accepted_loss = before.loss
        trial_count = 0
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                raw_trial[bit] = x[bit] + step * direction[bit]
                trial[bit] = spec.projection_rule === :box ?
                    clamp(raw_trial[bit], lower, upper) : raw_trial[bit]
            end
            trial_count += 1
            evaluated = evaluate_objective!(
                trial_workspace, problem, trial, delta, spec.parity_rule)
            if isfinite(evaluated.loss) && evaluated.loss < before.loss
                accepted = true
                accepted_step = step
                accepted_loss = evaluated.loss
                break
            end
        end

        if !accepted
            status = "line_search_stalled"
            metrics = state_metrics(problem, code, x)
            push!(traces, (
                update, accepted=false, parity_rule=String(spec.parity_rule),
                projection_rule=String(spec.projection_rule),
                loss_before=before.loss, loss_after=before.loss,
                accepted_step=0.0, trial_count,
                finite_difference_checked=fd_checked,
                finite_difference_maximum_error=fd.maximum_error,
                finite_difference_maximum_bit=fd.maximum_bit,
                x_before_sha256=x_before_hash,
                x_after_sha256=x_before_hash,
                delta_sha256=edge_sha256(delta),
                coded_bit_errors=metrics.coded_bit_errors,
                syndrome_weight=metrics.syndrome_weight,
                parity_valid=metrics.parity_valid,
                transmitted_word_equal=metrics.transmitted_word_equal,
            ))
            break
        end

        all_strict_decrease &= accepted_loss < before.loss
        x, trial = trial, x
        accepted_steps += 1
        last_effective_update = update
        last_objective = accepted_loss
        metrics = state_metrics(problem, code, x)
        first_valid_update === nothing && metrics.parity_valid &&
            (first_valid_update = update)
        first_exact_update === nothing && metrics.transmitted_word_equal &&
            (first_exact_update = update)
        push!(traces, (
            update, accepted=true, parity_rule=String(spec.parity_rule),
            projection_rule=String(spec.projection_rule),
            loss_before=before.loss, loss_after=accepted_loss,
            accepted_step, trial_count,
            finite_difference_checked=fd_checked,
            finite_difference_maximum_error=fd.maximum_error,
            finite_difference_maximum_bit=fd.maximum_bit,
            x_before_sha256=x_before_hash,
            x_after_sha256=vector_sha256(x),
            delta_sha256=edge_sha256(delta),
            coded_bit_errors=metrics.coded_bit_errors,
            syndrome_weight=metrics.syndrome_weight,
            parity_valid=metrics.parity_valid,
            transmitted_word_equal=metrics.transmitted_word_equal,
        ))
        if update in score_updates
            checkpoints[update] = checkpoint_record(
                update, update, true, accepted_loss, metrics, delta)
        end
    end

    terminal_metrics = state_metrics(problem, code, x)
    for requested in score_updates
        haskey(checkpoints, requested) && continue
        checkpoints[requested] = checkpoint_record(
            requested, last_effective_update, false, last_objective,
            terminal_metrics, delta)
    end
    all_strict_decrease || error("accepted step did not strictly decrease objective")

    (; spec, x=copy(x), delta=Legacy.copy_edge_rows(delta), traces,
       checkpoints, accepted_steps, last_effective_update, status,
       first_valid_update, first_exact_update, finite_difference_checks,
       maximum_finite_difference_error=maximum_fd_error,
       all_strict_decrease,
       common_update1_scalar_sha256=vector_sha256(seed.x),
       common_update1_offset_sha256=edge_sha256(seed.delta),
       terminal_metrics)
end

# ---------------------------------------------------------------------------
# Stage calculation, endpoint gates, and paired summaries
# ---------------------------------------------------------------------------

bool_text(value::Bool) = value ? "true" : "false"
parse_bool(value::AbstractString) = lowercase(value) == "true"
optional_update(value) = value === nothing ? -1 : Int(value)

function frame_row(frame::Int, input, result, checkpoint)
    (; frame, arm=result.spec.name,
       parity_rule=String(result.spec.parity_rule),
       projection_rule=String(result.spec.projection_rule),
       checkpoint_update=checkpoint.requested_update,
       effective_update=checkpoint.effective_update,
       checkpoint_reached=checkpoint.reached,
       noise_seed=input.noise_seed,
       coded_bit_errors=checkpoint.coded_bit_errors,
       syndrome_weight=checkpoint.syndrome_weight,
       parity_valid=checkpoint.parity_valid,
       transmitted_word_equal=checkpoint.transmitted_word_equal,
       objective=checkpoint.objective,
       first_valid_update=optional_update(result.first_valid_update),
       first_exact_update=optional_update(result.first_exact_update),
       accepted_steps=result.accepted_steps,
       status=result.status,
       finite_difference_checks=result.finite_difference_checks,
       maximum_finite_difference_error=
           result.maximum_finite_difference_error,
       all_strict_decrease=result.all_strict_decrease,
       common_update1_scalar_sha256=
           result.common_update1_scalar_sha256,
       common_update1_offset_sha256=
           result.common_update1_offset_sha256,
       hard_word_sha256=checkpoint.hard_word_sha256,
       terminal_scalar_sha256=checkpoint.terminal_scalar_sha256,
       terminal_offset_sha256=checkpoint.terminal_offset_sha256,
       maximum_absolute_scalar=checkpoint.maximum_absolute_scalar,
       received_sha256=input.identities.received_sha256,
       clipped_llr_sha256=input.identities.clipped_llr_sha256)
end

function iteration_rows(frame::Int, result)
    [(; frame, arm=result.spec.name, row...) for row in result.traces]
end

function calibration_reference(config, freeze::AbstractString)
    path = frozen_reference_paths(config, freeze)["frames"]
    arm = String(config["sources"]["calibration_reference_arm"])
    selected = Dict{Int,Any}()
    for row in Legacy.parse_simple_csv(path)
        row.arm == arm || continue
        selected[parse(Int, row.frame)] = row
    end
    selected
end

function calibration_gate_row(frame::Int, observed, expected)
    checks = (
        scalar_sha256=observed.terminal_scalar_sha256 ==
            expected.terminal_scalar_sha256,
        offset_sha256=observed.terminal_offset_sha256 ==
            expected.terminal_offset_sha256,
        hard_word_sha256=observed.hard_word_sha256 ==
            expected.hard_word_sha256,
        coded_bit_errors=observed.coded_bit_errors ==
            parse(Int, expected.coded_bit_errors),
        syndrome_weight=observed.syndrome_weight ==
            parse(Int, expected.syndrome_weight),
        parity_valid=observed.parity_valid ==
            parse_bool(expected.parity_valid),
        transmitted_word_equal=observed.transmitted_word_equal ==
            parse_bool(expected.transmitted_word_equal),
        received_sha256=observed.received_sha256 == expected.received_sha256,
        clipped_llr_sha256=observed.clipped_llr_sha256 ==
            expected.clipped_llr_sha256,
    )
    (; frame, checks..., passed=all(checks))
end

const CONTRASTS = (
    (id="parity_shape_given_box", treatment="product_only__box",
     reference="compound__box"),
    (id="parity_shape_given_unconstrained",
     treatment="product_only__unconstrained",
     reference="compound__unconstrained"),
    (id="projection_given_compound",
     treatment="compound__unconstrained", reference="compound__box"),
    (id="projection_given_product_only",
     treatment="product_only__unconstrained",
     reference="product_only__box"),
)

endpoint_value(row, endpoint::String) = endpoint == "transmitted_word_equal" ?
    row.transmitted_word_equal : endpoint == "parity_valid" ?
    row.parity_valid : throw(ArgumentError("unknown endpoint $endpoint"))

function aggregate_rows(frame_rows, config)
    rows = NamedTuple[]
    for checkpoint in Int.(config["solver"]["score_updates"]), spec in ARMS
        selected = [row for row in frame_rows
                    if row.checkpoint_update == checkpoint &&
                       row.arm == spec.name]
        for endpoint in ("transmitted_word_equal", "parity_valid")
            successes = count(row -> endpoint_value(row, endpoint), selected)
            push!(rows, (; checkpoint_update=checkpoint, arm=spec.name,
                endpoint, cases=length(selected), successes,
                proportion=successes / length(selected)))
        end
    end
    rows
end

function contrast_rows(frame_rows, config)
    rows = NamedTuple[]
    interaction = NamedTuple[]
    checkpoints = Int.(config["solver"]["score_updates"])
    frames = sort!(unique(row.frame for row in frame_rows))
    lookup = Dict((row.frame, row.arm, row.checkpoint_update) => row
                  for row in frame_rows)
    for checkpoint in checkpoints,
            endpoint in ("transmitted_word_equal", "parity_valid")
        for contrast in CONTRASTS
            treatment = [endpoint_value(
                lookup[(frame, contrast.treatment, checkpoint)], endpoint)
                for frame in frames]
            reference = [endpoint_value(
                lookup[(frame, contrast.reference, checkpoint)], endpoint)
                for frame in frames]
            treatment_success = count(identity, treatment)
            reference_success = count(identity, reference)
            treatment_only = count(index -> treatment[index] &&
                !reference[index], eachindex(frames))
            reference_only = count(index -> reference[index] &&
                !treatment[index], eachindex(frames))
            push!(rows, (; checkpoint_update=checkpoint,
                endpoint, contrast_id=contrast.id,
                treatment_arm=contrast.treatment,
                reference_arm=contrast.reference,
                cases=length(frames), treatment_success, reference_success,
                treatment_only_success=treatment_only,
                reference_only_success=reference_only,
                paired_risk_difference=(treatment_success-reference_success) /
                    length(frames)))
        end

        success(arm) = count(frame -> endpoint_value(
            lookup[(frame, arm, checkpoint)], endpoint), frames)
        interaction_count = success("product_only__unconstrained") -
            success("compound__unconstrained") -
            success("product_only__box") + success("compound__box")
        push!(interaction, (; checkpoint_update=checkpoint, endpoint,
            cases=length(frames), interaction_success_count=interaction_count,
            interaction_risk_difference=interaction_count / length(frames)))
    end
    rows, interaction
end

function calculate_pass(config, freeze::AbstractString, stage::Symbol;
                        progress_callback=(completed, total)->nothing)
    source_gate(config)["passed"] || error("source gate failed")
    frozen_reference_gate(config, freeze)["passed"] ||
        error("frozen v4 reference gate failed")
    v4_config = V4.load_config(v4_config_path(config))
    split = V4.load_split_config(v4_config)
    Legacy.enforce_thread_environment(split)
    native = Split.load_native(split)
    generated = Split.make_code(split, native)
    code = generated.code
    bp = make_bp_code(split, Int(config["endpoint_gate"][
        "bp_maximum_message_passing_iterations"]))
    frames = collect(stage_frames(config, stage))
    reference = stage === :calibration ?
        calibration_reference(config, freeze) : Dict{Int,Any}()
    if stage === :calibration
        Set(keys(reference)) == Set(frames) ||
            error("frozen calibration table does not contain exactly the registered frames")
    end

    frame_rows = NamedTuple[]
    update_rows = NamedTuple[]
    gate_rows = NamedTuple[]
    common_update_rows = NamedTuple[]
    endpoint_rows = NamedTuple[]
    for (frame_index, frame) in enumerate(frames)
        input = Split.generate_input(split, native, code, frame)
        problem = V4.problem_for(split, code, input.clipped_llr)
        initial = tanh.(input.clipped_llr ./ 2.0)
        native_gd = decode_native_gd_endpoint(
            split, code, input.clipped_llr,
            Int(config["endpoint_gate"]["native_gd_maximum_updates"]))
        push!(endpoint_rows, endpoint_row(
            frame, "gd_native_projected", native_gd, input))
        native_bp = decode_bp_endpoint(
            bp.modem, bp.code, input.clipped_llr)
        push!(endpoint_rows, endpoint_row(
            frame, "bp_exact_sum_product", native_bp, input))
        seed = common_update_one(problem, code, initial, split, config)
        seed_x_hash = vector_sha256(seed.x)
        seed_delta_hash = edge_sha256(seed.delta)
        arm_seed_x_hashes = String[]
        arm_seed_delta_hashes = String[]
        observed_calibration = nothing
        observed_v4 = nothing
        for spec in ARMS
            result = solve_arm(problem, code, initial, seed, spec, config)
            push!(arm_seed_x_hashes, result.common_update1_scalar_sha256)
            push!(arm_seed_delta_hashes, result.common_update1_offset_sha256)
            for checkpoint in sort!(collect(keys(result.checkpoints)))
                row = frame_row(frame, input, result,
                                result.checkpoints[checkpoint])
                push!(frame_rows, row)
                if stage === :calibration && spec.name == "compound__box" &&
                        checkpoint == 30
                    observed_calibration = row
                end
                if spec.name == "compound__box" && checkpoint == 30
                    observed_v4 = row
                end
            end
            append!(update_rows, iteration_rows(frame, result))
        end
        common_passed = all(==(seed_x_hash), arm_seed_x_hashes) &&
            all(==(seed_delta_hash), arm_seed_delta_hashes)
        push!(common_update_rows, (; frame,
            common_update1_scalar_sha256=seed_x_hash,
            common_update1_offset_sha256=seed_delta_hash,
            passed=common_passed))
        common_passed || error("common update-1 gate failed on frame $frame")
        observed_v4 === nothing && error("missing v4 endpoint checkpoint")
        push!(endpoint_rows, endpoint_row_from_v4(
            frame, observed_v4, input))
        if stage === :calibration
            observed_calibration === nothing &&
                error("missing compound__box update-30 calibration row")
            gate = calibration_gate_row(
                frame, observed_calibration, reference[frame])
            push!(gate_rows, gate)
            gate.passed || error("v4 endpoint gate failed on frame $frame")
        end
        progress_callback(frame_index, length(frames))
    end

    aggregates = aggregate_rows(frame_rows, config)
    contrasts, interactions = contrast_rows(frame_rows, config)
    endpoint_gate = endpoint_gate_summary(endpoint_rows, config, stage)
    gates = Dict(
        "source_gate_passed" => true,
        "frozen_reference_gate_passed" => true,
        "common_update1_passed" => all(row.passed for row in common_update_rows),
        "calibration_endpoint_gate_passed" =>
            stage !== :calibration || all(row.passed for row in gate_rows),
        "strict_decrease_passed" => all(row.all_strict_decrease
                                         for row in frame_rows),
        "finite_difference_passed" => all(
            row.maximum_finite_difference_error <=
                Float64(config["validation"]["finite_difference_tolerance"])
            for row in frame_rows),
        "endpoint_gate_passed" => Bool(endpoint_gate["passed"]),
    )
    all(values(gates)) || error("scientific correctness gate failed")
    (; stage=String(stage), frames=frame_rows, iterations=update_rows,
       aggregate=aggregates, contrasts, interactions,
       calibration_gates=gate_rows,
       common_update_gates=common_update_rows,
       endpoint_words=endpoint_rows, endpoint_gate, gates)
end

function pass_hash(calculated)
    scientific_sha256(Dict(
        "stage" => calculated.stage,
        "frames" => calculated.frames,
        "iterations" => calculated.iterations,
        "aggregate" => calculated.aggregate,
        "contrasts" => calculated.contrasts,
        "interactions" => calculated.interactions,
        "calibration_gates" => calculated.calibration_gates,
        "common_update_gates" => calculated.common_update_gates,
        "endpoint_words" => calculated.endpoint_words,
        "endpoint_gate" => calculated.endpoint_gate,
        "gates" => calculated.gates,
    ))
end

# ---------------------------------------------------------------------------
# Durable output and command-line entry point
# ---------------------------------------------------------------------------

function atomic_progress(path::AbstractString, payload)
    temporary = path * ".tmp.$(getpid()).$(time_ns())"
    open(temporary, "w") do io
        TOML.print(io, payload; sorted=true)
        write(io, '\n')
    end
    mv(temporary, path; force=true)
end

function write_table(path, rows)
    isempty(rows) && return nothing
    Legacy.write_csv(path, rows, collect(keys(first(rows))))
end

function write_primary_tables(output, calculated)
    write_table(joinpath(output, "frames.csv"), calculated.frames)
    write_table(joinpath(output, "iterations.csv"), calculated.iterations)
    write_table(joinpath(output, "aggregate.csv"), calculated.aggregate)
    write_table(joinpath(output, "contrasts.csv"), calculated.contrasts)
    write_table(joinpath(output, "interaction.csv"), calculated.interactions)
    write_table(joinpath(output, "calibration_gates.csv"),
                calculated.calibration_gates)
    write_table(joinpath(output, "common_update_gates.csv"),
                calculated.common_update_gates)
    write_table(joinpath(output, "endpoint_words.csv"),
                calculated.endpoint_words)
end

function manifest_text(root)
    entries = Pair{String,String}[]
    for (directory, _, files) in walkdir(root), name in files
        relative = relpath(joinpath(directory, name), root)
        relative in ("MANIFEST.sha256", "progress.toml", "phase_log.tsv") &&
            continue
        push!(entries, relative => file_sha256(joinpath(directory, name)))
    end
    sort!(entries; by=first)
    join(("$(last(entry))  $(first(entry))" for entry in entries), "\n") * "\n"
end

function campaign_completion(stage::Symbol, science_path::AbstractString,
                             endpoint_path::AbstractString,
                             primary_hash::AbstractString,
                             replay_hash::AbstractString;
                             correctness_passed::Bool=true)
    Dict{String,Any}(
        "schema_version" => CAMPAIGN_COMPLETION_SCHEMA,
        "experiment_id" => CAMPAIGN_EXPERIMENT_ID,
        "block" => "A",
        "stage" => String(stage),
        "status" => correctness_passed ? "complete_valid" : "invalid",
        "correctness_passed" => correctness_passed,
        "deterministic_replay_passed" => primary_hash == replay_hash,
        "science_sha256" => file_sha256(science_path),
        "endpoint_gate_sha256" => file_sha256(endpoint_path),
        "primary_science_sha256" => String(primary_hash),
        "replay_science_sha256" => String(replay_hash),
    )
end

function campaign_timing(stage::Symbol, frame_count::Int,
                         scientific_frame_loop_seconds::Real,
                         post_loop_seconds::Real; pass_count::Int=2)
    Dict{String,Any}(
        "schema_version" => CAMPAIGN_TIMING_SCHEMA,
        "experiment_id" => CAMPAIGN_EXPERIMENT_ID,
        "block" => "A",
        "stage" => String(stage),
        "frame_count" => frame_count,
        "pass_count" => pass_count,
        "scientific_frame_loop_seconds" =>
            Float64(scientific_frame_loop_seconds),
        "post_loop_seconds" => Float64(post_loop_seconds),
    )
end

function run_stage(stage::Symbol, output::AbstractString,
                   freeze::AbstractString;
                   config_path::AbstractString=DEFAULT_CONFIG)
    config = load_config(config_path)
    stage in STAGES || throw(ArgumentError("unknown stage $stage"))
    ispath(output) && throw(ArgumentError("refusing to overwrite $output"))
    mkpath(output)
    started = now(UTC)
    try
        scientific_started_ns = time_ns()
        scientific_frame_loop_ns = UInt64(0)
        atomic_progress(joinpath(output, "progress.toml"), Dict(
            "schema_version" => config["provenance"]["progress_schema"],
            "stage" => String(stage), "pass" => "primary",
            "phase" => "frame_loop", "completed_frames" => 0,
            "total_frames" => length(stage_frames(config, stage)),
            "updated_utc" => string(now(UTC))))
        primary_loop_started_ns = time_ns()
        primary = calculate_pass(config, freeze, stage;
            progress_callback=(completed, total)->atomic_progress(
                joinpath(output, "progress.toml"), Dict(
                    "schema_version" => config["provenance"]["progress_schema"],
                    "stage" => String(stage), "pass" => "primary",
                    "phase" => "frame_loop", "completed_frames" => completed,
                    "total_frames" => total,
                    "updated_utc" => string(now(UTC)))))
        scientific_frame_loop_ns += time_ns() - primary_loop_started_ns
        primary_hash = pass_hash(primary)
        write_primary_tables(output, primary)
        checkpoint_root = joinpath(output, "primary_checkpoint")
        mkpath(checkpoint_root)
        for name in ("frames.csv", "iterations.csv")
            cp(joinpath(output, name), joinpath(checkpoint_root, name);
               force=false)
        end
        open(joinpath(checkpoint_root, "science.toml"), "w") do io
            TOML.print(io, Dict("stage" => String(stage),
                "scientific_sha256" => primary_hash); sorted=true)
            write(io, '\n')
        end

        atomic_progress(joinpath(output, "progress.toml"), Dict(
            "schema_version" => config["provenance"]["progress_schema"],
            "stage" => String(stage), "pass" => "replay",
            "phase" => "frame_loop", "completed_frames" => 0,
            "total_frames" => length(stage_frames(config, stage)),
            "updated_utc" => string(now(UTC))))
        replay_loop_started_ns = time_ns()
        replay = calculate_pass(config, freeze, stage;
            progress_callback=(completed, total)->atomic_progress(
                joinpath(output, "progress.toml"), Dict(
                    "schema_version" => config["provenance"]["progress_schema"],
                    "stage" => String(stage), "pass" => "replay",
                    "phase" => "frame_loop", "completed_frames" => completed,
                    "total_frames" => total,
                    "updated_utc" => string(now(UTC)))))
        scientific_frame_loop_ns += time_ns() - replay_loop_started_ns
        replay_hash = pass_hash(replay)
        primary_hash == replay_hash || error(
            "deterministic replay mismatch: $primary_hash != $replay_hash")

        primary_endpoint_hash = String(
            primary.endpoint_gate["hard_word_table_sha256"])
        replay_endpoint_hash = String(
            replay.endpoint_gate["hard_word_table_sha256"])
        primary_endpoint_hash == replay_endpoint_hash || error(
            "endpoint hard-word table replay mismatch")
        scientific_endpoint_gate = deepcopy(primary.endpoint_gate)
        scientific_endpoint_gate["primary_hard_word_table_sha256"] =
            primary_endpoint_hash
        scientific_endpoint_gate["replay_hard_word_table_sha256"] =
            replay_endpoint_hash
        scientific_endpoint_gate["deterministic_replay_passed"] = true
        scientific_endpoint_gate["passed"] =
            Bool(scientific_endpoint_gate["passed"]) &&
            primary_endpoint_hash == replay_endpoint_hash
        endpoint_gate = campaign_endpoint_gate(
            primary.endpoint_words, replay.endpoint_words, stage)
        open(joinpath(output, "endpoint_gate.toml"), "w") do io
            TOML.print(io, endpoint_gate; sorted=true)
            write(io, '\n')
        end

        science = Dict(
            "schema_version" => config["provenance"]["science_schema"],
            "experiment_id" => config["experiment_id"],
            "stage" => String(stage),
            "frame_first" => first(stage_frames(config, stage)),
            "frame_last" => last(stage_frames(config, stage)),
            "frame_count" => length(stage_frames(config, stage)),
            "arm_order" => [arm.name for arm in ARMS],
            "score_updates" => Int.(config["solver"]["score_updates"]),
            "primary_scientific_sha256" => primary_hash,
            "replay_scientific_sha256" => replay_hash,
            "deterministic_replay_passed" => true,
            "gates" => primary.gates,
            "endpoint_gate" => scientific_endpoint_gate,
            "table_sha256" => Dict(
                name => file_sha256(joinpath(output, name))
                for name in ("frames.csv", "iterations.csv", "aggregate.csv",
                             "contrasts.csv", "interaction.csv",
                             "common_update_gates.csv", "endpoint_words.csv",
                             "endpoint_gate.toml")
                if isfile(joinpath(output, name))),
        )
        open(joinpath(output, "science.json"), "w") do io
            write(io, canonical_json(science), '\n')
        end
        completed = campaign_completion(
            stage, joinpath(output, "science.json"),
            joinpath(output, "endpoint_gate.toml"), primary_hash, replay_hash;
            correctness_passed=true)
        open(joinpath(output, "COMPLETED.toml"), "w") do io
            TOML.print(io, completed; sorted=true)
            write(io, '\n')
        end
        atomic_progress(joinpath(output, "progress.toml"), Dict(
            "schema_version" => config["provenance"]["progress_schema"],
            "stage" => String(stage), "pass" => "replay",
            "phase" => "complete", "completed_frames" =>
                length(stage_frames(config, stage)),
            "total_frames" => length(stage_frames(config, stage)),
            "updated_utc" => string(now(UTC))))
        total_measured_ns = time_ns() - scientific_started_ns
        post_loop_ns = total_measured_ns - scientific_frame_loop_ns
        open(joinpath(output, "timing.toml"), "w") do io
            TOML.print(io, campaign_timing(
                stage, length(stage_frames(config, stage)),
                Float64(scientific_frame_loop_ns) / 1.0e9,
                Float64(post_loop_ns) / 1.0e9); sorted=true)
            write(io, '\n')
        end
        open(joinpath(output, "MANIFEST.sha256"), "w") do io
            write(io, manifest_text(output))
        end
        completed
    catch error_value
        open(joinpath(output, "FAILED.toml"), "w") do io
            TOML.print(io, Dict(
                "experiment_id" => config["experiment_id"],
                "stage" => String(stage), "status" => "failed",
                "failed_utc" => string(now(UTC)),
                "error" => sprint(showerror, error_value)); sorted=true)
            write(io, '\n')
        end
        rethrow()
    end
end

function parse_options(arguments)
    options = Dict{String,String}()
    index = 1
    while index <= length(arguments)
        startswith(arguments[index], "--") ||
            throw(ArgumentError("unexpected argument $(arguments[index])"))
        index < length(arguments) ||
            throw(ArgumentError("missing value for $(arguments[index])"))
        options[arguments[index][3:end]] = arguments[index + 1]
        index += 2
    end
    options
end

function main(arguments=ARGS)
    isempty(arguments) && throw(ArgumentError(
        "usage: runner (freeze|calibration|anchor|transfer|attribution) " *
        "--config PATH --output PATH [--freeze PATH]"))
    command = arguments[1]
    options = parse_options(arguments[2:end])
    config_path = get(options, "config", DEFAULT_CONFIG)
    output = get(options, "output", "")
    isempty(output) && throw(ArgumentError("--output is required"))
    if command == "freeze"
        prepare_freeze(output; config_path)
        return 0
    end
    stage = Symbol(command)
    stage in STAGES || throw(ArgumentError("unknown command $command"))
    freeze = get(options, "freeze", "")
    isempty(freeze) && throw(ArgumentError("--freeze is required for a stage"))
    run_stage(stage, output, freeze; config_path)
    0
end

export ArmSpec, ARMS, load_config, stage_frames, source_gate,
       frozen_reference_gate, prepare_freeze, product_only_evaluate!,
       evaluate_objective!, finite_difference_maximum, common_update_one,
       solve_arm, calculate_pass, pass_hash, campaign_endpoint_fields,
       campaign_endpoint_gate, campaign_completion, campaign_timing,
       manifest_text, run_stage, main

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    exit(RQ2GDResidualProjectionBudget001.main())
end

