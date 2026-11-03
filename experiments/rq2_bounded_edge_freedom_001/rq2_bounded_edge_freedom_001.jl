#!/usr/bin/env julia

module RQ2BoundedEdgeFreedom001

using Dates
using LinearAlgebra
using Printf
using SHA
using TOML

const HERE = @__DIR__
const EXPERIMENT_ID = "RQ2-BOUNDED-EDGE-FREEDOM-001"
const CONFIG_SCHEMA = "rq2-bounded-edge-freedom-001/config-v1"
const SCIENCE_SCHEMA = "rq2-bounded-edge-freedom-001/science-v1"
const GATE_SCHEMA = "rq2-bounded-edge-freedom-001/gate-v1"
const COMPLETION_SCHEMA = "rq2-bounded-edge-freedom-001/completion-v1"
const PROGRESS_SCHEMA = "rq2-bounded-edge-freedom-001/progress-v1"
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")

# Execute the exact, hash-registered Block-A source inside the full causal
# freeze.  The new experiment has no runtime dependency on either the failed
# unbounded predecessor or the earlier tied-product experiment.
const BLOCK_A_RUNNER = normpath(joinpath(
    HERE, "..", "rq2_causal_factors_001", "freeze", "2026-11-01_v2",
    "source", "block_a", "runner.jl"))
const BLOCK_A_CONFIG = normpath(joinpath(
    HERE, "..", "rq2_causal_factors_001", "freeze", "2026-11-01_v2",
    "source", "block_a", "config.toml"))
include(BLOCK_A_RUNNER)
const BlockA = RQ2GDResidualProjectionBudget001
const Legacy = BlockA.Legacy

module LocalTiedHelpers
using Printf
using SHA
using ..RQ2BoundedEdgeFreedom001: Legacy

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
vector_sha256(values) = Legacy.vector_sha256(values)
edge_sha256(rows) = Legacy.edge_sha256(rows)
float_hex(value::Real) = @sprintf(
    "0x%016x", reinterpret(UInt64, Float64(value)))
float_bits_equal(left::Real, right::Real) =
    reinterpret(UInt64, Float64(left)) ==
    reinterpret(UInt64, Float64(right))
function vector_bits_equal(left, right)
    length(left) == length(right) || return false
    reinterpret(UInt64, Float64.(left)) ==
        reinterpret(UInt64, Float64.(right))
end
function edge_bits_equal(left, right)
    length(left) == length(right) || return false
    all(length(left[index]) == length(right[index]) &&
        reinterpret(UInt64, Float64.(left[index])) ==
        reinterpret(UInt64, Float64.(right[index]))
        for index in eachindex(left))
end
lift_scalar(x, checks) = [Float64[x[bit] for bit in check]
                          for check in checks]

struct GateMismatch <: Exception
    frame::Int
    update::Int
    trial::Int
    field::String
    reference::String
    treatment::String
end
function Base.showerror(io::IO, error::GateMismatch)
    print(io, "bounded tied-edge mismatch at frame=$(error.frame) ",
          "update=$(error.update) trial=$(error.trial) field=$(error.field): ",
          "reference=$(error.reference), treatment=$(error.treatment)")
end
mismatch(frame, update, trial, field, reference, treatment) =
    throw(GateMismatch(Int(frame), Int(update), Int(trial), String(field),
                       String(reference), String(treatment)))
function require_float(frame, update, trial, field, reference, treatment)
    float_bits_equal(reference, treatment) || mismatch(
        frame, update, trial, field, float_hex(reference), float_hex(treatment))
end
function require_vector(frame, update, trial, field, reference, treatment)
    vector_bits_equal(reference, treatment) || mismatch(
        frame, update, trial, field, vector_sha256(reference),
        vector_sha256(treatment))
end
function require_edges(frame, update, trial, field, reference, treatment)
    edge_bits_equal(reference, treatment) || mismatch(
        frame, update, trial, field, edge_sha256(reference),
        edge_sha256(treatment))
end
function require_metrics(frame, update, reference, treatment)
    reference.hard == treatment.hard || mismatch(
        frame, update, 0, "hard_decision", vector_sha256(reference.hard),
        vector_sha256(treatment.hard))
    for field in (:syndrome_weight, :parity_valid,
                  :transmitted_word_equal, :coded_bit_errors,
                  :hard_word_sha256, :scalar_sha256)
        left = getproperty(reference, field)
        right = getproperty(treatment, field)
        left == right || mismatch(frame, update, 0, String(field),
                                  string(left), string(right))
    end
    true
end
end
const Tied = LocalTiedHelpers

scientific_sha256(value) = BlockA.scientific_sha256(value)
canonical_json(value) = Legacy.canonical_json(value)

function checksum_manifest_entries(path::AbstractString)
    entries = Dict{String,String}()
    for line in eachline(path)
        isempty(strip(line)) && continue
        pieces = split(line, r"\s+"; limit=2)
        length(pieces) == 2 || throw(ArgumentError(
            "malformed checksum manifest line"))
        entries[strip(pieces[2])] = pieces[1]
    end
    entries
end

export load_config, LiftedWorkspace, mean_state!, mean_state,
       compound_lifted_evaluate!, aggregate_edge_gradient!,
       constrained_metric_direction!, free_metric_direction!,
       project_scalar_box!, project_edge_box!, pullback_direction_gate,
       edge_finite_difference_gate, paired_per_frame_solve,
       persistent_state_counts, paired_outcome_row, compare_frame,
       paired_endpoint_counts, paired_inference, source_gate,
       transfer_prerequisite_gate, run_stage, main

get_float(table, key, default) = Float64(get(table, key, default))
get_int(table, key, default) = Int(get(table, key, default))
get_bool(table, key, default) = Bool(get(table, key, default))

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    get(config, "schema_version", "") == CONFIG_SCHEMA ||
        throw(ArgumentError("unsupported configuration schema"))
    get(config, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("unexpected experiment identifier"))
    arms = config["arms"]
    String.(arms["order"]) ==
        ["equality_constrained", "equality_relaxed"] ||
        throw(ArgumentError("registered arm order changed"))
    String(arms["only_causal_difference"]) ==
        "edge_copy_equality_constraint" ||
        throw(ArgumentError("registered treatment changed"))
    Int(arms["common_update"]) == 1 ||
        throw(ArgumentError("common update changed"))
    objective = config["objective"]
    String(objective["family"]) ==
        "compound_squared_parity_residual" ||
        throw(ArgumentError("objective family changed"))
    Bool(objective["edge_coordinate_boxed"]) ||
        throw(ArgumentError("edge coordinate box was removed"))
    !Bool(objective["offset_adjusted_parity_reading_boxed"]) ||
        throw(ArgumentError("offset-adjusted readings must not be clipped"))
    solver = config["solver"]
    Int(solver["maximum_update_attempts"]) == 30 ||
        throw(ArgumentError("registered update budget changed"))
    Int.(solver["score_updates"]) == [30] ||
        throw(ArgumentError("registered score update changed"))
    Float64(solver["initial_step"]) == 0.2 ||
        throw(ArgumentError("registered initial step changed"))
    Int(solver["maximum_backtracks"]) == 16 ||
        throw(ArgumentError("registered backtracking budget changed"))
    Float64(solver["box_lower"]) == -1.0 ||
        throw(ArgumentError("registered lower box face changed"))
    Float64(solver["box_upper"]) == 1.0 ||
        throw(ArgumentError("registered upper box face changed"))
    String(solver["edge_metric"]) ==
        "scalar_curvature_bound_divided_by_variable_degree" ||
        throw(ArgumentError("registered edge metric changed"))
    String(solver["hard_decision_state"]) ==
        "mean_of_incident_edge_copies" ||
        throw(ArgumentError("registered hard-decision readout changed"))
    validation = config["validation"]
    Int.(validation["finite_difference_updates"]) == [2, 30] ||
        throw(ArgumentError("finite-difference schedule changed"))
    Int(validation["finite_difference_sample_count"]) > 0 ||
        throw(ArgumentError("finite-difference sample count must be positive"))
    Float64(validation["pullback_epsilon_multiplier"]) == 128.0 ||
        throw(ArgumentError("pullback epsilon multiplier changed"))
    Float64(validation["mean_direction_epsilon_multiplier"]) == 128.0 ||
        throw(ArgumentError("mean-direction epsilon multiplier changed"))
    Float64(validation["finite_difference_relative_tolerance"]) == 5.0e-8 ||
        throw(ArgumentError("finite-difference relative tolerance changed"))
    String(validation["finite_difference_after_stall"]) ==
        "evaluate the registered update-30 check on the persisted terminal state" ||
        throw(ArgumentError("post-stall derivative policy changed"))
    protocol = config["protocol"]
    for prefix in ("compatibility", "anchor", "transfer")
        first = Int(protocol[prefix * "_first"])
        last = Int(protocol[prefix * "_last"])
        first <= last || throw(ArgumentError("invalid $prefix frame range"))
        last - first + 1 == Int(protocol[prefix * "_case_count"]) ||
            throw(ArgumentError("$prefix frame count changed"))
    end
    inference = config["inference"]
    String(inference["primary_endpoint"]) ==
        "transmitted_word_equal_at_requested_update_30" ||
        throw(ArgumentError("registered primary endpoint changed"))
    String(inference["confirmatory_endpoint"]) ==
        "parity_valid_at_requested_update_30" ||
        throw(ArgumentError("registered confirmatory endpoint changed"))
    String(inference["contrast"]) ==
        "equality_relaxed_minus_equality_constrained" ||
        throw(ArgumentError("registered paired contrast changed"))
    String(inference["paired_test"]) ==
        "two-sided exact McNemar test" ||
        throw(ArgumentError("registered paired test changed"))
    Float64(inference["confidence_level"]) == 0.95 ||
        throw(ArgumentError("registered confidence level changed"))
    String(inference["anchor_role"]) == "descriptive validation" ||
        throw(ArgumentError("registered anchor role changed"))
    String(inference["transfer_role"]) ==
        "confirmatory paired comparison" ||
        throw(ArgumentError("registered transfer role changed"))
    Int(config["execution"]["scientific_passes"]) == 2 ||
        throw(ArgumentError("primary and deterministic replay are required"))
    config
end

function validate_edge_rows(problem, rows, label::AbstractString)
    length(rows) == length(problem.check_vars) ||
        throw(DimensionMismatch("$label row count changed"))
    for check_index in eachindex(problem.check_vars)
        length(rows[check_index]) == length(problem.check_vars[check_index]) ||
            throw(DimensionMismatch("$label slot count changed at check $check_index"))
    end
    rows
end

"""Mean of the persistent copies incident on each coded bit.

The exact-copy fast path is deliberate: it preserves signed zero and makes the
equality-constrained boundary bit-identical to the scalar Block-A endpoint.
"""
function mean_state!(destination, z, problem)
    length(destination) == length(problem.var_edges) ||
        throw(DimensionMismatch("mean-state length changed"))
    validate_edge_rows(problem, z, "persistent edge state")
    @inbounds for bit in eachindex(problem.var_edges)
        incident = problem.var_edges[bit]
        isempty(incident) && throw(ArgumentError(
            "coded bit $bit has no incident check"))
        first_check, first_slot = first(incident)
        canonical = Float64(z[first_check][first_slot])
        exact = true
        displacement = 0.0
        for (check_index, slot) in incident
            value = Float64(z[check_index][slot])
            exact &= Tied.float_bits_equal(value, canonical)
            displacement += value - canonical
        end
        destination[bit] = exact ? canonical :
            canonical + displacement / length(incident)
    end
    destination
end

mean_state(z, problem) = mean_state!(
    zeros(Float64, length(problem.var_edges)), z, problem)

mutable struct LiftedWorkspace
    scalar::Legacy.EvalWorkspace
    mean::Vector{Float64}
    edge_gradient::Vector{Vector{Float64}}
end

function LiftedWorkspace(problem)
    LiftedWorkspace(
        Legacy.EvalWorkspace(problem),
        zeros(Float64, length(problem.llr)),
        Legacy.zero_edge_rows(problem.check_vars),
    )
end

"""Evaluate the bounded successor's shared compound objective.

Channel and binary terms read the fixed mean readout.  Check `c` reads its own
persistent copy `z[c][slot]` plus its assigned, frozen offset.  The box applies
to `z`; it never clips `z + delta`.
"""
function compound_lifted_evaluate!(workspace::LiftedWorkspace, problem, z,
                                   delta_rows)
    validate_edge_rows(problem, z, "persistent edge state")
    validate_edge_rows(problem, delta_rows, "frozen offset")
    x = mean_state!(workspace.mean, z, problem)
    scalar = workspace.scalar
    n = length(problem.llr)
    fill!(scalar.gradient, 0.0)
    fill!(scalar.h, 0.0)
    for row in scalar.g_rows
        fill!(row, 0.0)
    end

    check_count = length(problem.check_vars)
    scale = 1.0 / check_count
    parity_loss = 0.0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        product = 1.0
        for (slot, bit) in enumerate(check)
            scalar.prefix[slot] = product
            product *= Float64(z[check_index][slot]) +
                Float64(delta_rows[check_index][slot])
        end
        residual = 1.0 - product
        parity_loss += scale * residual^2
        coefficient = -2.0 * scale * residual
        suffix = 1.0
        for slot in length(check):-1:1
            bit = check[slot]
            contribution = coefficient * scalar.prefix[slot] * suffix
            scalar.gradient[bit] += contribution
            scalar.g_rows[check_index][slot] = contribution
            suffix *= Float64(z[check_index][slot]) +
                Float64(delta_rows[check_index][slot])
        end
    end
    factor = problem.parity_weight * check_count / n
    scalar.gradient .*= factor
    for row in scalar.g_rows
        row .*= factor
    end
    parity = factor * parity_loss

    binary = 0.0
    @inbounds for bit in eachindex(x)
        value = Float64(x[bit])
        binary_contribution =
            4problem.binary_weight * value * (value^2 - 1.0) / n
        binary += problem.binary_weight * (1.0 - value^2)^2 / n
        scalar.gradient[bit] += binary_contribution
        scalar.h[bit] = -problem.llr[bit] / (2n) + binary_contribution
    end
    channel = -dot(problem.llr, x) / (2n)
    @inbounds for bit in eachindex(x)
        scalar.gradient[bit] -= problem.llr[bit] / (2n)
    end

    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            degree = length(problem.var_edges[bit])
            workspace.edge_gradient[check_index][slot] =
                scalar.h[bit] / degree + scalar.g_rows[check_index][slot]
        end
    end
    (; loss=channel + (parity + binary),
       terms=(; channel, parity, binary), mean=x,
       scalar_gradient=scalar.gradient, h=scalar.h,
       g_rows=scalar.g_rows, edge_gradient=workspace.edge_gradient)
end

scalar_compound_evaluate!(workspace, problem, x, delta_rows) =
    Legacy.bridge_evaluate!(workspace, problem, x, delta_rows;
                            consume_offsets=true)

function aggregate_edge_gradient!(destination, problem, edge_gradient)
    length(destination) == length(problem.var_edges) ||
        throw(DimensionMismatch("aggregate-gradient length changed"))
    validate_edge_rows(problem, edge_gradient, "edge partial")
    fill!(destination, 0.0)
    @inbounds for bit in eachindex(problem.var_edges)
        for (check_index, slot) in problem.var_edges[bit]
            destination[bit] += Float64(edge_gradient[check_index][slot])
        end
    end
    destination
end

function constrained_metric_direction!(scalar_direction, edge_direction,
                                       problem, scalar_gradient)
    @inbounds for bit in eachindex(problem.llr)
        kappa = Float64(problem.curvature_bound[bit])
        isfinite(kappa) && kappa > 0.0 ||
            throw(ArgumentError("invalid curvature bound at coded bit $bit"))
        scalar_direction[bit] = -Float64(scalar_gradient[bit]) / kappa
    end
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            edge_direction[check_index][slot] = scalar_direction[bit]
        end
    end
    scalar_direction, edge_direction
end

function free_metric_direction!(edge_direction, problem, edge_gradient)
    validate_edge_rows(problem, edge_direction, "free direction")
    validate_edge_rows(problem, edge_gradient, "edge partial")
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            degree = length(problem.var_edges[bit])
            metric = Float64(problem.curvature_bound[bit]) / degree
            isfinite(metric) && metric > 0.0 ||
                throw(ArgumentError("invalid edge metric"))
            edge_direction[check_index][slot] =
                -Float64(edge_gradient[check_index][slot]) / metric
        end
    end
    edge_direction
end

function project_scalar_box!(destination, source, lower::Real, upper::Real)
    lower <= upper || throw(ArgumentError("box faces reversed"))
    length(destination) == length(source) ||
        throw(DimensionMismatch("scalar projection length changed"))
    @inbounds for bit in eachindex(source)
        destination[bit] = clamp(Float64(source[bit]), lower, upper)
    end
    destination
end

"""Project each persistent `z` copy; assigned offsets are not arguments."""
function project_edge_box!(destination, source, lower::Real, upper::Real)
    lower <= upper || throw(ArgumentError("box faces reversed"))
    length(destination) == length(source) ||
        throw(DimensionMismatch("edge projection row count changed"))
    @inbounds for check_index in eachindex(source)
        length(destination[check_index]) == length(source[check_index]) ||
            throw(DimensionMismatch("edge projection slot count changed"))
        for slot in eachindex(source[check_index])
            destination[check_index][slot] = clamp(
                Float64(source[check_index][slot]), lower, upper)
        end
    end
    destination
end

function spread_summary(rows, problem)
    maximum_spread = 0.0
    maximum_bit = 0
    total = 0.0
    @inbounds for bit in eachindex(problem.var_edges)
        values = Float64[rows[c][s] for (c, s) in problem.var_edges[bit]]
        spread = maximum(values) - minimum(values)
        total += spread
        if spread > maximum_spread
            maximum_spread = spread
            maximum_bit = bit
        end
    end
    (; maximum_spread, maximum_bit,
       mean_spread=total / length(problem.var_edges))
end

"""Record the pullback identity and first free-direction prediction.

Unlike the failed predecessor's fixed absolute comparison, every coordinate
uses the prospectively registered `128*eps()*scale` bound.  The tied state
update itself uses the order-matched scalar evaluation, so this diagnostic
never changes the reference trajectory.
"""
function pullback_direction_gate(problem, evaluated;
                                 pullback_multiplier::Float64=128.0,
                                 direction_multiplier::Float64=128.0,
                                 require_nonzero_spread::Bool=true)
    nbits = length(problem.llr)
    pullback_errors = zeros(Float64, nbits)
    pullback_bounds = zeros(Float64, nbits)
    pullback_reconstructed = zeros(Float64, nbits)
    @inbounds for bit in eachindex(problem.var_edges)
        reconstructed = Float64(evaluated.h[bit])
        absolute_decomposition = abs(Float64(evaluated.h[bit]))
        for (check_index, slot) in problem.var_edges[bit]
            contribution = Float64(evaluated.g_rows[check_index][slot])
            reconstructed += contribution
            absolute_decomposition += abs(contribution)
        end
        reference = Float64(evaluated.scalar_gradient[bit])
        scale = max(1.0, abs(reference), absolute_decomposition)
        pullback_reconstructed[bit] = reconstructed
        pullback_errors[bit] = abs(reference - reconstructed)
        pullback_bounds[bit] = pullback_multiplier * eps(Float64) * scale
    end
    aggregate_error = maximum(pullback_errors)
    aggregate_tolerance = maximum(pullback_bounds)
    aggregate_normalized_error = maximum(
        pullback_errors[bit] / pullback_bounds[bit]
        for bit in eachindex(pullback_errors))

    constrained_scalar = zeros(Float64, nbits)
    constrained_edges = Legacy.zero_edge_rows(problem.check_vars)
    free_edges = Legacy.zero_edge_rows(problem.check_vars)
    constrained_metric_direction!(
        constrained_scalar, constrained_edges, problem,
        evaluated.scalar_gradient)
    free_metric_direction!(free_edges, problem, evaluated.edge_gradient)
    free_mean = mean_state(free_edges, problem)
    direction_errors = zeros(Float64, nbits)
    direction_bounds = zeros(Float64, nbits)
    @inbounds for bit in eachindex(problem.var_edges)
        absolute_edge_mean = sum(
            abs(Float64(free_edges[c][s]))
            for (c, s) in problem.var_edges[bit]) /
            length(problem.var_edges[bit])
        scale = max(1.0, abs(constrained_scalar[bit]),
                    absolute_edge_mean)
        direction_errors[bit] =
            abs(free_mean[bit] - constrained_scalar[bit])
        direction_bounds[bit] =
            direction_multiplier * eps(Float64) * scale
    end
    mean_direction_error = maximum(direction_errors)
    mean_direction_tolerance = maximum(direction_bounds)
    mean_direction_normalized_error = maximum(
        direction_errors[bit] / direction_bounds[bit]
        for bit in eachindex(direction_errors))
    spread = spread_summary(free_edges, problem)
    nonzero_spread = spread.maximum_spread > 0.0
    checks = Dict(
        "pullback_identity" => aggregate_normalized_error <= 1.0,
        "mean_direction_identity" =>
            mean_direction_normalized_error <= 1.0,
        "nonzero_free_direction_spread" =>
            !require_nonzero_spread || nonzero_spread,
    )
    (; passed=all(values(checks)), checks, aggregate_error,
       aggregate_tolerance, aggregate_normalized_error,
       pullback_errors, pullback_bounds, pullback_reconstructed,
       mean_direction_error, mean_direction_tolerance,
       mean_direction_normalized_error, direction_errors,
       direction_bounds, pullback_multiplier, direction_multiplier,
       nonzero_spread,
       maximum_direction_spread=spread.maximum_spread,
       maximum_direction_spread_bit=spread.maximum_bit,
       constrained_scalar, constrained_edges, free_edges, free_mean)
end

function canonical_edge_samples(problem, requested::Integer)
    requested > 0 || throw(ArgumentError("sample count must be positive"))
    all_edges = [(c, s) for (c, check) in enumerate(problem.check_vars)
                 for s in eachindex(check)]
    length(all_edges) <= requested && return all_edges
    indices = unique(round.(Int, range(1, length(all_edges); length=requested)))
    all_edges[indices]
end

"""Five-point derivative check of the actual lifted compound objective."""
function edge_finite_difference_gate(problem, z, delta_rows, edge_gradient;
                                     sample_count::Int=12,
                                     step::Float64=1.0e-6,
                                     tolerance::Float64=3.0e-8)
    samples = canonical_edge_samples(problem, sample_count)
    trial = Legacy.copy_edge_rows(z)
    workspace = LiftedWorkspace(problem)
    state_before = Tied.edge_sha256(z)
    offset_before = Tied.edge_sha256(delta_rows)
    rows = NamedTuple[]
    maximum_error = 0.0
    maximum_normalized_error = 0.0
    maximum_tolerance = 0.0
    maximum_connection = (0, 0)
    for (check_index, slot) in samples
        center = Float64(z[check_index][slot])
        function objective(replacement)
            trial[check_index][slot] = replacement
            compound_lifted_evaluate!(
                workspace, problem, trial, delta_rows).loss
        end
        numerical = (objective(center - 2step) -
                     8objective(center - step) +
                     8objective(center + step) -
                     objective(center + 2step)) / (12step)
        trial[check_index][slot] = center
        analytic = Float64(edge_gradient[check_index][slot])
        error = abs(numerical - analytic)
        mixed_bound = tolerance * max(1.0, abs(analytic), abs(numerical))
        normalized_error = error / mixed_bound
        push!(rows, (; check_index, slot,
                     bit=problem.check_vars[check_index][slot],
                     analytic, numerical, error, mixed_bound,
                     normalized_error))
        maximum_normalized_error = max(
            maximum_normalized_error, normalized_error)
        maximum_tolerance = max(maximum_tolerance, mixed_bound)
        if error > maximum_error
            maximum_error = error
            maximum_connection = (check_index, slot)
        end
    end
    checks = Dict(
        "finite_difference" => maximum_normalized_error <= 1.0,
        "persistent_state_unchanged" => state_before == Tied.edge_sha256(z),
        "frozen_offsets_unchanged" =>
            offset_before == Tied.edge_sha256(delta_rows),
    )
    (; passed=all(values(checks)), checks, maximum_error,
       maximum_normalized_error, maximum_tolerance,
       maximum_connection, rows, state_before,
       state_after=Tied.edge_sha256(z), offset_before,
       offset_after=Tied.edge_sha256(delta_rows))
end

function state_metrics(problem, code, x)
    if code !== nothing
        return BlockA.state_metrics(problem, code, x)
    end
    hard = BitVector(Float64(value) < 0.0 for value in x)
    syndrome = Legacy.syndrome_vector(problem.check_vars, hard)
    syndrome_weight = sum(syndrome)
    (; hard, syndrome, syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       coded_bit_errors=count(hard),
       hard_word_sha256=Tied.vector_sha256(hard),
       scalar_sha256=Tied.vector_sha256(x),
       maximum_absolute_scalar=maximum(abs, x))
end

function state_diagnostics(problem, z, lower, upper)
    x = mean_state(z, problem)
    values = Float64[value for row in z for value in row]
    spread = spread_summary(z, problem)
    all_finite = all(isfinite, values) && all(isfinite, x)
    inside = all_finite && all(value -> lower <= value <= upper, values)
    (; mean_state=x, all_finite, inside_box=inside,
       maximum_absolute_state=all_finite ? maximum(abs, values) : Inf,
       maximum_absolute_mean=all_finite ? maximum(abs, x) : Inf,
       maximum_within_bit_spread=spread.maximum_spread,
       maximum_within_bit_spread_bit=spread.maximum_bit,
       mean_within_bit_spread=spread.mean_spread,
       mean_state_sha256=Tied.vector_sha256(x),
       persistent_state_sha256=Tied.edge_sha256(z))
end

"""Diagnostics for private check readings versus the coherent mean word."""
function private_check_diagnostics(problem, z, delta_rows)
    x = mean_state(z, problem)
    private_squared = 0.0
    mean_squared = 0.0
    private_hard_satisfied = 0
    mean_word_hard_satisfied = 0
    hard_satisfaction_disagreement = 0
    edge_sign_disagreement = 0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        private_product = 1.0
        mean_product = 1.0
        private_sign_product = 1
        mean_sign_product = 1
        for (slot, bit) in enumerate(check)
            private_reading = Float64(z[check_index][slot]) +
                Float64(delta_rows[check_index][slot])
            mean_reading = Float64(x[bit]) +
                Float64(delta_rows[check_index][slot])
            private_product *= private_reading
            mean_product *= mean_reading
            private_sign_product *= private_reading >= 0.0 ? 1 : -1
            mean_sign_product *= Float64(x[bit]) >= 0.0 ? 1 : -1
            edge_sign = Float64(z[check_index][slot]) >= 0.0 ? 1 : -1
            mean_sign = Float64(x[bit]) >= 0.0 ? 1 : -1
            edge_sign_disagreement += edge_sign != mean_sign
        end
        private_squared += (1.0 - private_product)^2
        mean_squared += (1.0 - mean_product)^2
        private_satisfied = private_sign_product == 1
        mean_satisfied = mean_sign_product == 1
        private_hard_satisfied += private_satisfied
        mean_word_hard_satisfied += mean_satisfied
        hard_satisfaction_disagreement +=
            private_satisfied != mean_satisfied
    end
    count = length(problem.check_vars)
    (; private_check_residual_rms=sqrt(private_squared / count),
       mean_state_check_residual_rms=sqrt(mean_squared / count),
       private_hard_satisfied_checks=private_hard_satisfied,
       mean_word_hard_satisfied_checks=mean_word_hard_satisfied,
       hard_satisfaction_disagreement_checks=
           hard_satisfaction_disagreement,
       edge_sign_disagreement_count=edge_sign_disagreement)
end

function objective_identity_gate(problem, x, z, delta_rows)
    scalar_workspace = Legacy.EvalWorkspace(problem)
    lifted_workspace = LiftedWorkspace(problem)
    scalar = scalar_compound_evaluate!(
        scalar_workspace, problem, x, delta_rows)
    lifted = compound_lifted_evaluate!(
        lifted_workspace, problem, z, delta_rows)
    checks = Dict(
        "mean_state" => Tied.vector_bits_equal(x, lifted.mean),
        "loss" => Tied.float_bits_equal(scalar.loss, lifted.loss),
        "channel" => Tied.float_bits_equal(
            scalar.terms.channel, lifted.terms.channel),
        "parity" => Tied.float_bits_equal(
            scalar.terms.parity, lifted.terms.parity),
        "binary" => Tied.float_bits_equal(
            scalar.terms.binary, lifted.terms.binary),
        "scalar_gradient" => Tied.vector_bits_equal(
            scalar.gradient, lifted.scalar_gradient),
        "check_partials" => Tied.edge_bits_equal(
            scalar.g_rows, lifted.g_rows),
    )
    (; passed=all(values(checks)), checks,
       scalar_loss=scalar.loss, lifted_loss=lifted.loss)
end

function constrained_search(problem, x, delta, before, direction,
                            trial_workspace, initial_step,
                            maximum_backtracks, lower, upper)
    raw = similar(x)
    trial = similar(x)
    for backtrack in 0:maximum_backtracks
        step = initial_step * 0.5^backtrack
        @inbounds for bit in eachindex(x)
            raw[bit] = x[bit] + step * direction[bit]
        end
        project_scalar_box!(trial, raw, lower, upper)
        evaluated = scalar_compound_evaluate!(
            trial_workspace, problem, trial, delta)
        if isfinite(evaluated.loss) && evaluated.loss < before.loss
            return (; accepted=true, step,
                    trial_count=backtrack + 1, loss=evaluated.loss,
                    x=copy(trial))
        end
    end
    (; accepted=false, step=0.0,
       trial_count=maximum_backtracks + 1, loss=before.loss, x=copy(x))
end

function relaxed_search(problem, z, delta, before, direction,
                        trial_workspace, initial_step, maximum_backtracks,
                        lower, upper)
    raw = Legacy.zero_edge_rows(problem.check_vars)
    trial = Legacy.zero_edge_rows(problem.check_vars)
    for backtrack in 0:maximum_backtracks
        step = initial_step * 0.5^backtrack
        @inbounds for check_index in eachindex(z)
            for slot in eachindex(z[check_index])
                raw[check_index][slot] = z[check_index][slot] +
                    step * direction[check_index][slot]
            end
        end
        project_edge_box!(trial, raw, lower, upper)
        evaluated = compound_lifted_evaluate!(
            trial_workspace, problem, trial, delta)
        if isfinite(evaluated.loss) && evaluated.loss < before.loss
            return (; accepted=true, step,
                    trial_count=backtrack + 1, loss=evaluated.loss,
                    z=Legacy.copy_edge_rows(trial))
        end
    end
    (; accepted=false, step=0.0,
       trial_count=maximum_backtracks + 1, loss=before.loss,
       z=Legacy.copy_edge_rows(z))
end

function seed_trace(problem, seed, metrics, z, delta)
    row = seed.trace[1]
    evaluated = compound_lifted_evaluate!(
        LiftedWorkspace(problem), problem, z, delta)
    private = private_check_diagnostics(problem, z, delta)
    (; update=1, accepted=true,
       objective="compound_assigned_frozen",
       projection="scalar_box_common_update",
       feasible_set="common_tied_edge_box",
       loss_before=Float64(row["loss_before"]),
       loss_after=Float64(row["accepted_fixed_offset_loss"]),
       accepted_step=Float64(row["accepted_step"]),
       trial_count=Int(row["trial_count"]),
       finite_difference_checked=false,
       finite_difference_maximum_error=0.0,
       finite_difference_maximum_normalized_error=0.0,
       finite_difference_maximum_tolerance=0.0,
       reference_finite_difference_maximum_error=
           Float64(row["finite_difference_maximum_error"]),
       reference_finite_difference_maximum_bit=
           Int(row["finite_difference_maximum_bit"]),
       x_after_sha256=Tied.vector_sha256(seed.x),
       mean_state_sha256=Tied.vector_sha256(seed.x),
       persistent_state_sha256=Tied.edge_sha256(z),
       frozen_offset_sha256=Tied.edge_sha256(delta),
       objective_channel=evaluated.terms.channel,
       objective_parity=evaluated.terms.parity,
       objective_binary=evaluated.terms.binary,
       objective_total=evaluated.loss,
       scalar_gradient_sha256=Tied.vector_sha256(
           evaluated.scalar_gradient),
       edge_gradient_sha256=Tied.edge_sha256(evaluated.edge_gradient),
       direction_sha256="common_update_1",
       objective_identity_passed=true,
       private.private_check_residual_rms,
       private.mean_state_check_residual_rms,
       private.private_hard_satisfied_checks,
       private.mean_word_hard_satisfied_checks,
       private.hard_satisfaction_disagreement_checks,
       private.edge_sign_disagreement_count,
       metrics.coded_bit_errors, metrics.syndrome_weight,
       metrics.parity_valid, metrics.transmitted_word_equal)
end

function trace_row(update, feasible_set, projection, before, search,
                   after, direction_sha256, objective_identity_passed,
                   metrics, diagnostics, private, delta, fd, scalar_fd)
    (; update, accepted=search.accepted,
       objective="compound_assigned_frozen", projection, feasible_set,
       loss_before=before.loss, loss_after=search.loss,
       accepted_step=search.step, trial_count=search.trial_count,
       finite_difference_checked=fd !== nothing,
       finite_difference_maximum_error=
           fd === nothing ? 0.0 : fd.maximum_error,
       finite_difference_maximum_normalized_error=
           fd === nothing ? 0.0 : fd.maximum_normalized_error,
       finite_difference_maximum_tolerance=
           fd === nothing ? 0.0 : fd.maximum_tolerance,
       reference_finite_difference_maximum_error=
           scalar_fd === nothing ? 0.0 : scalar_fd.maximum_error,
       reference_finite_difference_maximum_bit=
           scalar_fd === nothing ? 0 : scalar_fd.maximum_bit,
       x_after_sha256=diagnostics.mean_state_sha256,
       mean_state_sha256=diagnostics.mean_state_sha256,
       persistent_state_sha256=diagnostics.persistent_state_sha256,
       frozen_offset_sha256=Tied.edge_sha256(delta),
       objective_channel=after.terms.channel,
       objective_parity=after.terms.parity,
       objective_binary=after.terms.binary,
       objective_total=after.loss,
       scalar_gradient_sha256=Tied.vector_sha256(after.scalar_gradient),
       edge_gradient_sha256=Tied.edge_sha256(after.edge_gradient),
       direction_sha256, objective_identity_passed,
       private.private_check_residual_rms,
       private.mean_state_check_residual_rms,
       private.private_hard_satisfied_checks,
       private.mean_word_hard_satisfied_checks,
       private.hard_satisfaction_disagreement_checks,
       private.edge_sign_disagreement_count,
       metrics.coded_bit_errors, metrics.syndrome_weight,
       metrics.parity_valid, metrics.transmitted_word_equal)
end

function boundary_gate(problem, code, x, constrained_eval, relaxed_eval,
                       constrained_delta, relaxed_delta)
    constrained_metrics = state_metrics(problem, code, x)
    relaxed_metrics = state_metrics(problem, code, relaxed_eval.mean)
    checks = Dict(
        "objective" => Tied.float_bits_equal(
            constrained_eval.loss, relaxed_eval.loss),
        "mean_state" => Tied.vector_bits_equal(x, relaxed_eval.mean),
        "scalar_gradient" => Tied.vector_bits_equal(
            constrained_eval.gradient, relaxed_eval.scalar_gradient),
        "hard_decision" =>
            constrained_metrics.hard == relaxed_metrics.hard,
        "syndrome" =>
            constrained_metrics.syndrome == relaxed_metrics.syndrome,
        "frozen_offsets" => Tied.edge_bits_equal(
            constrained_delta, relaxed_delta),
    )
    (; passed=all(values(checks)), checks,
       constrained_metrics, relaxed_metrics)
end

"""Run the equality-constrained and equality-relaxed bounded arms.

Both arms start from the same accepted compound update 1 and retain the same
assigned offsets.  From update 2 onward, the only treatment is whether copies
of one coded bit must remain equal.  Both arms keep every `z` copy in [-1, 1].
"""
function paired_per_frame_solve(problem, code, initial, seed, config;
                                frame::Int=0)
    solver = config["solver"]
    validation = config["validation"]
    maximum_updates = Int(solver["maximum_update_attempts"])
    initial_step = Float64(solver["initial_step"])
    maximum_backtracks = Int(solver["maximum_backtracks"])
    lower = Float64(solver["box_lower"])
    upper = Float64(solver["box_upper"])
    fd_updates = Set(Int.(validation["finite_difference_updates"]))
    fd_samples = Int(validation["finite_difference_sample_count"])
    fd_step = Float64(validation["finite_difference_step"])
    fd_tolerance = Float64(validation["finite_difference_tolerance"])
    pullback_multiplier = Float64(
        validation["pullback_epsilon_multiplier"])
    direction_multiplier = Float64(
        validation["mean_direction_epsilon_multiplier"])
    require_spread = get_bool(
        validation, "require_nonzero_first_direction_spread", true)

    x_constrained = copy(seed.x)
    z_constrained = Tied.lift_scalar(seed.x, problem.check_vars)
    z_relaxed = Tied.lift_scalar(seed.x, problem.check_vars)
    delta_constrained = Legacy.copy_edge_rows(seed.delta)
    delta_relaxed = Legacy.copy_edge_rows(seed.delta)
    offset_hash = Tied.edge_sha256(seed.delta)

    scalar_current_workspace = Legacy.EvalWorkspace(problem)
    scalar_trial_workspace = Legacy.EvalWorkspace(problem)
    constrained_lifted_workspace = LiftedWorkspace(problem)
    relaxed_current_workspace = LiftedWorkspace(problem)
    relaxed_trial_workspace = LiftedWorkspace(problem)
    scalar_direction = zeros(Float64, length(problem.llr))
    broadcast_direction = Legacy.zero_edge_rows(problem.check_vars)
    relaxed_direction = Legacy.zero_edge_rows(problem.check_vars)

    seed_metrics = state_metrics(problem, code, seed.x)
    constrained_trace = [seed_trace(
        problem, seed, seed_metrics, z_constrained, delta_constrained)]
    relaxed_trace = [seed_trace(
        problem, seed, seed_metrics, z_relaxed, delta_relaxed)]
    constrained_status = "steps_completed"
    relaxed_status = "steps_completed"
    constrained_active = true
    relaxed_active = true
    constrained_accepted_steps = 1
    relaxed_accepted_steps = 1
    constrained_effective_update = 1
    relaxed_effective_update = 1
    maximum_constrained_fd_error = 0.0
    maximum_relaxed_fd_error = 0.0
    maximum_constrained_fd_normalized_error = 0.0
    maximum_relaxed_fd_normalized_error = 0.0
    constrained_fd_updates_checked = Set{Int}()
    relaxed_fd_updates_checked = Set{Int}()
    maximum_pullback_error = 0.0
    maximum_pullback_tolerance = 0.0
    maximum_pullback_normalized_error = 0.0
    treatment_boundary = nothing
    first_direction = nothing
    first_identity = nothing

    for update in 2:maximum_updates
        constrained_before = constrained_active ? scalar_compound_evaluate!(
            scalar_current_workspace, problem, x_constrained,
            delta_constrained) : nothing
        constrained_lifted = constrained_active ?
            compound_lifted_evaluate!(
                constrained_lifted_workspace, problem, z_constrained,
                delta_constrained) : nothing
        relaxed_before = relaxed_active ? compound_lifted_evaluate!(
            relaxed_current_workspace, problem, z_relaxed,
            delta_relaxed) : nothing

        if update == 2
            constrained_before === nothing &&
                error("constrained arm inactive at treatment boundary")
            relaxed_before === nothing &&
                error("relaxed arm inactive at treatment boundary")
            first_identity = objective_identity_gate(
                problem, x_constrained, z_constrained,
                delta_constrained)
            first_identity.passed || error(
                "tied objective identity failed on frame $frame")
            treatment_boundary = boundary_gate(
                problem, code, x_constrained, constrained_before,
                relaxed_before, delta_constrained, delta_relaxed)
            treatment_boundary.passed || error(
                "treatment-boundary equality failed on frame $frame")
            first_direction = pullback_direction_gate(
                problem, relaxed_before;
                pullback_multiplier,
                direction_multiplier,
                require_nonzero_spread=require_spread)
            first_direction.passed || error(
                "first treatment-direction gate failed on frame $frame")
        end

        if constrained_active
            identity = objective_identity_gate(
                problem, x_constrained, z_constrained,
                delta_constrained)
            identity.passed || error(
                "order-matched tied identity failed on frame $frame update $update")
            pullback = pullback_direction_gate(
                problem, constrained_lifted;
                pullback_multiplier,
                direction_multiplier,
                require_nonzero_spread=false)
            maximum_pullback_error = max(
                maximum_pullback_error, pullback.aggregate_error,
                pullback.mean_direction_error)
            maximum_pullback_tolerance = max(
                maximum_pullback_tolerance, pullback.aggregate_tolerance,
                pullback.mean_direction_tolerance)
            maximum_pullback_normalized_error = max(
                maximum_pullback_normalized_error,
                pullback.aggregate_normalized_error,
                pullback.mean_direction_normalized_error)
            pullback.passed || error(
                "scale-aware pullback diagnostic failed on frame $frame update $update")
            fd = update in fd_updates ? edge_finite_difference_gate(
                problem, z_constrained, delta_constrained,
                constrained_lifted.edge_gradient;
                sample_count=fd_samples, step=fd_step,
                tolerance=fd_tolerance) : nothing
            fd === nothing || fd.passed || error(
                "constrained derivative gate failed on frame $frame update $update")
            fd === nothing || push!(constrained_fd_updates_checked, update)
            fd === nothing || (maximum_constrained_fd_error = max(
                maximum_constrained_fd_error, fd.maximum_error))
            fd === nothing ||
                (maximum_constrained_fd_normalized_error = max(
                    maximum_constrained_fd_normalized_error,
                    fd.maximum_normalized_error))
            scalar_fd = update in fd_updates ?
                BlockA.finite_difference_maximum(
                    problem, x_constrained, delta_constrained,
                    constrained_before.gradient, :compound;
                    step=fd_step) : nothing
            constrained_metric_direction!(
                scalar_direction, broadcast_direction, problem,
                constrained_before.gradient)
            search = constrained_search(
                problem, x_constrained, delta_constrained,
                constrained_before, scalar_direction,
                scalar_trial_workspace, initial_step,
                maximum_backtracks, lower, upper)
            if search.accepted
                search.loss < constrained_before.loss ||
                    error("constrained accepted step was not a strict decrease")
                x_constrained = search.x
                z_constrained = Tied.lift_scalar(
                    x_constrained, problem.check_vars)
                constrained_accepted_steps += 1
                constrained_effective_update = update
            else
                constrained_active = false
                constrained_status = "line_search_stalled"
            end
            diagnostics = state_diagnostics(
                problem, z_constrained, lower, upper)
            diagnostics.inside_box || error(
                "constrained projection failed on frame $frame update $update")
            metrics = state_metrics(
                problem, code, diagnostics.mean_state)
            after = compound_lifted_evaluate!(
                constrained_lifted_workspace, problem, z_constrained,
                delta_constrained)
            after_identity = objective_identity_gate(
                problem, x_constrained, z_constrained,
                delta_constrained)
            after_identity.passed || error(
                "post-update tied identity failed on frame $frame update $update")
            private = private_check_diagnostics(
                problem, z_constrained, delta_constrained)
            push!(constrained_trace, trace_row(
                update, "edge_copy_equality_constrained",
                "tied_edge_box", constrained_before, search,
                after, Tied.vector_sha256(scalar_direction), true,
                metrics, diagnostics, private,
                delta_constrained, fd, scalar_fd))
        end

        if relaxed_active
            fd = update in fd_updates ? edge_finite_difference_gate(
                problem, z_relaxed, delta_relaxed,
                relaxed_before.edge_gradient;
                sample_count=fd_samples, step=fd_step,
                tolerance=fd_tolerance) : nothing
            fd === nothing || fd.passed || error(
                "relaxed derivative gate failed on frame $frame update $update")
            fd === nothing || push!(relaxed_fd_updates_checked, update)
            fd === nothing || (maximum_relaxed_fd_error = max(
                maximum_relaxed_fd_error, fd.maximum_error))
            fd === nothing ||
                (maximum_relaxed_fd_normalized_error = max(
                    maximum_relaxed_fd_normalized_error,
                    fd.maximum_normalized_error))
            free_metric_direction!(
                relaxed_direction, problem, relaxed_before.edge_gradient)
            search = relaxed_search(
                problem, z_relaxed, delta_relaxed, relaxed_before,
                relaxed_direction, relaxed_trial_workspace,
                initial_step, maximum_backtracks, lower, upper)
            if search.accepted
                search.loss < relaxed_before.loss ||
                    error("relaxed accepted step was not a strict decrease")
                z_relaxed = search.z
                relaxed_accepted_steps += 1
                relaxed_effective_update = update
            else
                relaxed_active = false
                relaxed_status = "line_search_stalled"
            end
            diagnostics = state_diagnostics(
                problem, z_relaxed, lower, upper)
            diagnostics.inside_box || error(
                "relaxed projection failed on frame $frame update $update")
            metrics = state_metrics(
                problem, code, diagnostics.mean_state)
            after = compound_lifted_evaluate!(
                relaxed_current_workspace, problem, z_relaxed,
                delta_relaxed)
            private = private_check_diagnostics(
                problem, z_relaxed, delta_relaxed)
            push!(relaxed_trace, trace_row(
                update, "edge_copy_equality_relaxed",
                "componentwise_edge_box", relaxed_before, search,
                after, Tied.edge_sha256(relaxed_direction), false,
                metrics, diagnostics, private,
                delta_relaxed, fd, nothing))
        end

        Tied.edge_sha256(delta_constrained) == offset_hash ||
            error("constrained arm changed frozen offsets")
        Tied.edge_sha256(delta_relaxed) == offset_hash ||
            error("relaxed arm changed frozen offsets")
        !constrained_active && !relaxed_active && break
    end

    # A stalled line search persists its terminal state through the remaining
    # requested updates.  Preserve the registered update-30 derivative check
    # by evaluating that persisted state instead of silently skipping it.
    for required_update in sort!(collect(fd_updates))
        if !(required_update in constrained_fd_updates_checked)
            required_update == maximum_updates || error(
                "constrained derivative schedule missed update $required_update")
            evaluated = compound_lifted_evaluate!(
                constrained_lifted_workspace, problem, z_constrained,
                delta_constrained)
            fd = edge_finite_difference_gate(
                problem, z_constrained, delta_constrained,
                evaluated.edge_gradient; sample_count=fd_samples,
                step=fd_step, tolerance=fd_tolerance)
            fd.passed || error(
                "constrained persisted-state derivative gate failed on frame $frame update $required_update")
            push!(constrained_fd_updates_checked, required_update)
            maximum_constrained_fd_error = max(
                maximum_constrained_fd_error, fd.maximum_error)
            maximum_constrained_fd_normalized_error = max(
                maximum_constrained_fd_normalized_error,
                fd.maximum_normalized_error)
        end
        if !(required_update in relaxed_fd_updates_checked)
            required_update == maximum_updates || error(
                "relaxed derivative schedule missed update $required_update")
            evaluated = compound_lifted_evaluate!(
                relaxed_current_workspace, problem, z_relaxed,
                delta_relaxed)
            fd = edge_finite_difference_gate(
                problem, z_relaxed, delta_relaxed,
                evaluated.edge_gradient; sample_count=fd_samples,
                step=fd_step, tolerance=fd_tolerance)
            fd.passed || error(
                "relaxed persisted-state derivative gate failed on frame $frame update $required_update")
            push!(relaxed_fd_updates_checked, required_update)
            maximum_relaxed_fd_error = max(
                maximum_relaxed_fd_error, fd.maximum_error)
            maximum_relaxed_fd_normalized_error = max(
                maximum_relaxed_fd_normalized_error,
                fd.maximum_normalized_error)
        end
    end
    expected_fd_updates = sort!(collect(fd_updates))
    constrained_fd_schedule_passed =
        sort!(collect(constrained_fd_updates_checked)) == expected_fd_updates
    relaxed_fd_schedule_passed =
        sort!(collect(relaxed_fd_updates_checked)) == expected_fd_updates
    constrained_fd_schedule_passed || error(
        "constrained derivative schedule incomplete on frame $frame")
    relaxed_fd_schedule_passed || error(
        "relaxed derivative schedule incomplete on frame $frame")

    treatment_boundary === nothing &&
        error("treatment boundary was not evaluated")
    first_direction === nothing &&
        error("first direction was not evaluated")
    constrained_diagnostics = state_diagnostics(
        problem, z_constrained, lower, upper)
    relaxed_diagnostics = state_diagnostics(
        problem, z_relaxed, lower, upper)
    constrained_metrics = state_metrics(
        problem, code, constrained_diagnostics.mean_state)
    relaxed_metrics = state_metrics(
        problem, code, relaxed_diagnostics.mean_state)
    constrained_private = private_check_diagnostics(
        problem, z_constrained, delta_constrained)
    relaxed_private = private_check_diagnostics(
        problem, z_relaxed, delta_relaxed)
    (; frame, treatment_boundary, first_direction,
       first_objective_identity=first_identity,
       maximum_pullback_error, maximum_pullback_tolerance,
       maximum_pullback_normalized_error,
       constrained=(;
           x=copy(x_constrained), z=Legacy.copy_edge_rows(z_constrained),
           delta=delta_constrained, trace=constrained_trace,
           status=constrained_status,
           accepted_steps=constrained_accepted_steps,
           last_effective_update=constrained_effective_update,
           maximum_finite_difference_error=maximum_constrained_fd_error,
           maximum_finite_difference_normalized_error=
               maximum_constrained_fd_normalized_error,
           finite_difference_schedule_passed=
               constrained_fd_schedule_passed,
           finite_difference_updates_checked=join(
               sort!(collect(constrained_fd_updates_checked)), ";"),
           terminal_metrics=constrained_metrics,
           terminal_diagnostics=constrained_diagnostics,
           terminal_private=constrained_private),
       relaxed=(;
           z=Legacy.copy_edge_rows(z_relaxed), delta=delta_relaxed,
           trace=relaxed_trace, status=relaxed_status,
           accepted_steps=relaxed_accepted_steps,
           last_effective_update=relaxed_effective_update,
           maximum_finite_difference_error=maximum_relaxed_fd_error,
           maximum_finite_difference_normalized_error=
               maximum_relaxed_fd_normalized_error,
           finite_difference_schedule_passed=relaxed_fd_schedule_passed,
           finite_difference_updates_checked=join(
               sort!(collect(relaxed_fd_updates_checked)), ";"),
           terminal_metrics=relaxed_metrics,
           terminal_diagnostics=relaxed_diagnostics,
           terminal_private=relaxed_private))
end

function configured_block_a(context, config)
    block_config = deepcopy(context.block_config)
    block_config["solver"]["maximum_update_attempts"] = 30
    block_config["solver"]["score_updates"] = [30]
    block_config["solver"]["initial_step"] =
        Float64(config["solver"]["initial_step"])
    block_config["solver"]["maximum_backtracks"] =
        Int(config["solver"]["maximum_backtracks"])
    block_config["validation"]["finite_difference_updates"] =
        Int.(config["validation"]["finite_difference_updates"])
    block_config["validation"]["finite_difference_step"] =
        Float64(config["validation"]["finite_difference_step"])
    # Retain Block A's own scalar-derivative tolerance.  The new 5e-8 mixed
    # bound belongs only to the independently written lifted edge derivative.
    block_config
end

function require_trace_reproduction(frame, canonical, constrained)
    length(canonical.traces) == length(constrained.trace) ||
        Tied.mismatch(frame, 0, 0, "trace_length",
                      string(length(canonical.traces)),
                      string(length(constrained.trace)))
    for (reference, treatment) in zip(canonical.traces, constrained.trace)
        update = Int(reference.update)
        update == Int(treatment.update) || Tied.mismatch(
            frame, update, 0, "trace_update", string(update),
            string(treatment.update))
        Bool(reference.accepted) == Bool(treatment.accepted) || Tied.mismatch(
            frame, update, 0, "trace_accepted",
            string(reference.accepted), string(treatment.accepted))
        Tied.require_float(frame, update, 0, "trace_loss_before",
                           reference.loss_before, treatment.loss_before)
        Tied.require_float(frame, update, 0, "trace_loss_after",
                           reference.loss_after, treatment.loss_after)
        Tied.require_float(frame, update, 0, "trace_step",
                           reference.accepted_step,
                           treatment.accepted_step)
        Int(reference.trial_count) == Int(treatment.trial_count) ||
            Tied.mismatch(frame, update, 0, "trace_trial_count",
                          string(reference.trial_count),
                          string(treatment.trial_count))
        Tied.require_float(
            frame, update, 0, "trace_reference_fd_error",
            reference.finite_difference_maximum_error,
            treatment.reference_finite_difference_maximum_error)
        Int(reference.finite_difference_maximum_bit) ==
            Int(treatment.reference_finite_difference_maximum_bit) ||
            Tied.mismatch(
                frame, update, 0, "trace_reference_fd_bit",
                string(reference.finite_difference_maximum_bit),
                string(treatment.reference_finite_difference_maximum_bit))
        String(reference.x_after_sha256) == String(treatment.x_after_sha256) ||
            Tied.mismatch(frame, update, 0, "trace_state",
                          String(reference.x_after_sha256),
                          String(treatment.x_after_sha256))
        String(reference.delta_sha256) ==
            String(treatment.frozen_offset_sha256) || Tied.mismatch(
                frame, update, 0, "trace_offsets",
                String(reference.delta_sha256),
                String(treatment.frozen_offset_sha256))
        for field in (:coded_bit_errors, :syndrome_weight,
                      :parity_valid, :transmitted_word_equal)
            left = getproperty(reference, field)
            right = getproperty(treatment, field)
            left == right || Tied.mismatch(
                frame, update, 0, "trace_$(field)", string(left),
                string(right))
        end
    end
    true
end

parse_csv_bool(value::AbstractString) = lowercase(value) == "true"
function require_csv_text(frame, update, field, expected, observed)
    string(expected) == string(observed) || Tied.mismatch(
        frame, update, 0, field, string(expected), string(observed))
end
function require_csv_float(frame, update, field, expected, observed)
    Tied.require_float(frame, update, 0, field,
                       Float64(expected), parse(Float64, observed))
end

"""Gate the live scalar prefix against the sealed Block-A CSV evidence."""
function require_retained_block_a(frame, canonical, input,
                                  retained_frames, retained_iterations)
    length(canonical.traces) == 30 || Tied.mismatch(
        frame, 0, 0, "retained_trace_length", "30",
        string(length(canonical.traces)))
    for reference in canonical.traces
        update = Int(reference.update)
        key = (frame, update)
        haskey(retained_iterations, key) || Tied.mismatch(
            frame, update, 0, "retained_iteration", "present", "missing")
        retained = retained_iterations[key]
        require_csv_text(frame, update, "retained_accepted",
                         reference.accepted,
                         parse_csv_bool(retained.accepted))
        require_csv_float(frame, update, "retained_loss_before",
                          reference.loss_before, retained.loss_before)
        require_csv_float(frame, update, "retained_loss_after",
                          reference.loss_after, retained.loss_after)
        require_csv_float(frame, update, "retained_accepted_step",
                          reference.accepted_step, retained.accepted_step)
        require_csv_text(frame, update, "retained_trial_count",
                         reference.trial_count,
                         parse(Int, retained.trial_count))
        require_csv_text(frame, update, "retained_fd_checked",
                         reference.finite_difference_checked,
                         parse_csv_bool(retained.finite_difference_checked))
        require_csv_float(frame, update, "retained_fd_error",
                          reference.finite_difference_maximum_error,
                          retained.finite_difference_maximum_error)
        require_csv_text(frame, update, "retained_fd_bit",
                         reference.finite_difference_maximum_bit,
                         parse(Int, retained.finite_difference_maximum_bit))
        for field in (:x_before_sha256, :x_after_sha256, :delta_sha256)
            require_csv_text(frame, update, "retained_$(field)",
                             getproperty(reference, field),
                             getproperty(retained, field))
        end
        require_csv_text(frame, update, "retained_coded_bit_errors",
                         reference.coded_bit_errors,
                         parse(Int, retained.coded_bit_errors))
        require_csv_text(frame, update, "retained_syndrome_weight",
                         reference.syndrome_weight,
                         parse(Int, retained.syndrome_weight))
        require_csv_text(frame, update, "retained_parity_valid",
                         reference.parity_valid,
                         parse_csv_bool(retained.parity_valid))
        require_csv_text(frame, update, "retained_word_recovery",
                         reference.transmitted_word_equal,
                         parse_csv_bool(retained.transmitted_word_equal))
    end

    haskey(retained_frames, frame) || Tied.mismatch(
        frame, 30, 0, "retained_frame", "present", "missing")
    retained = retained_frames[frame]
    checkpoint = canonical.checkpoints[30]
    require_csv_text(frame, 30, "retained_checkpoint_update",
                     checkpoint.requested_update,
                     parse(Int, retained.checkpoint_update))
    require_csv_text(frame, 30, "retained_effective_update",
                     checkpoint.effective_update,
                     parse(Int, retained.effective_update))
    require_csv_text(frame, 30, "retained_checkpoint_reached",
                     checkpoint.reached,
                     parse_csv_bool(retained.checkpoint_reached))
    require_csv_float(frame, 30, "retained_objective",
                      checkpoint.objective, retained.objective)
    require_csv_text(frame, 30, "retained_frame_coded_errors",
                     checkpoint.coded_bit_errors,
                     parse(Int, retained.coded_bit_errors))
    require_csv_text(frame, 30, "retained_frame_syndrome",
                     checkpoint.syndrome_weight,
                     parse(Int, retained.syndrome_weight))
    require_csv_text(frame, 30, "retained_frame_parity",
                     checkpoint.parity_valid,
                     parse_csv_bool(retained.parity_valid))
    require_csv_text(frame, 30, "retained_frame_word_recovery",
                     checkpoint.transmitted_word_equal,
                     parse_csv_bool(retained.transmitted_word_equal))
    require_csv_text(frame, 30, "retained_hard_word",
                     checkpoint.hard_word_sha256,
                     retained.hard_word_sha256)
    require_csv_text(frame, 30, "retained_scalar_state",
                     checkpoint.terminal_scalar_sha256,
                     retained.terminal_scalar_sha256)
    require_csv_text(frame, 30, "retained_offsets",
                     checkpoint.terminal_offset_sha256,
                     retained.terminal_offset_sha256)
    require_csv_text(frame, 30, "retained_status", canonical.status,
                     retained.status)
    require_csv_text(frame, 30, "retained_received_input",
                     input.identities.received_sha256,
                     retained.received_sha256)
    require_csv_text(frame, 30, "retained_llr_input",
                     input.identities.clipped_llr_sha256,
                     retained.clipped_llr_sha256)
    (; passed=true,
       retained_iteration_sha256=scientific_sha256([
           retained_iterations[(frame, update)] for update in 1:30]),
       retained_frame_sha256=scientific_sha256(retained))
end

function persistent_state_counts(problem, arm::Symbol)
    edge_count = sum(length, problem.check_vars)
    scalar_count = length(problem.var_edges)
    arm in (:equality_constrained, :equality_relaxed) ||
        throw(ArgumentError("unknown arm for persistent-state accounting"))
    optimized = arm === :equality_constrained ? scalar_count : edge_count
    redundant_cache = arm === :equality_constrained ? edge_count : 0
    (; optimized_persistent_value_count=optimized,
       frozen_offset_persistent_value_count=edge_count,
       redundant_state_cache_value_count=redundant_cache,
       total_persistent_value_count=
           optimized + edge_count + redundant_cache)
end

function arm_frame_row(frame, stage, arm, input_identity_sha256,
                       seed, result, pair, counts)
    metrics = result.terminal_metrics
    diagnostics = result.terminal_diagnostics
    private = result.terminal_private
    terminal_trace = last(result.trace)
    (; frame, stage=String(stage), arm, input_identity_sha256,
       checkpoint_update=30,
       checkpoint_reached=result.last_effective_update == 30,
       common_update1_mean_sha256=Tied.vector_sha256(seed.x),
       frozen_offset_sha256=Tied.edge_sha256(seed.delta),
       terminal_mean_sha256=diagnostics.mean_state_sha256,
       terminal_persistent_state_sha256=
           diagnostics.persistent_state_sha256,
       trace_sha256=scientific_sha256(result.trace),
       counts.optimized_persistent_value_count,
       counts.frozen_offset_persistent_value_count,
       counts.redundant_state_cache_value_count,
       counts.total_persistent_value_count,
       accepted_steps=result.accepted_steps,
       effective_update=result.last_effective_update,
       status=result.status,
       terminal_accepted_step=terminal_trace.accepted_step,
       terminal_trial_count=terminal_trace.trial_count,
       objective_channel=terminal_trace.objective_channel,
       objective_parity=terminal_trace.objective_parity,
       objective_binary=terminal_trace.objective_binary,
       objective_total=terminal_trace.objective_total,
       metrics.coded_bit_errors, metrics.syndrome_weight,
       metrics.parity_valid, metrics.transmitted_word_equal,
       metrics.hard_word_sha256,
       syndrome_sha256=Tied.vector_sha256(metrics.syndrome),
       maximum_finite_difference_error=
           result.maximum_finite_difference_error,
       maximum_finite_difference_normalized_error=
           result.maximum_finite_difference_normalized_error,
       finite_difference_schedule_passed=
           result.finite_difference_schedule_passed,
       finite_difference_updates_checked=
           result.finite_difference_updates_checked,
       maximum_pullback_error=pair.maximum_pullback_error,
       maximum_pullback_tolerance=pair.maximum_pullback_tolerance,
       maximum_pullback_normalized_error=
           pair.maximum_pullback_normalized_error,
       maximum_absolute_state=diagnostics.maximum_absolute_state,
       maximum_absolute_mean=diagnostics.maximum_absolute_mean,
       maximum_within_bit_spread=
           diagnostics.maximum_within_bit_spread,
       private.private_check_residual_rms,
       private.mean_state_check_residual_rms,
       private.private_hard_satisfied_checks,
       private.mean_word_hard_satisfied_checks,
       private.hard_satisfaction_disagreement_checks,
       private.edge_sign_disagreement_count,
       all_finite=diagnostics.all_finite,
       inside_box=diagnostics.inside_box,
       boundary_gate_passed=pair.treatment_boundary.passed,
       objective_identity_passed=pair.first_objective_identity.passed,
       first_direction_gate_passed=pair.first_direction.passed,
       first_direction_mean_error=
           pair.first_direction.mean_direction_error,
       first_direction_mean_tolerance=
           pair.first_direction.mean_direction_tolerance,
       first_direction_mean_normalized_error=
           pair.first_direction.mean_direction_normalized_error,
       first_pullback_error=pair.first_direction.aggregate_error,
       first_pullback_tolerance=
           pair.first_direction.aggregate_tolerance,
       first_pullback_normalized_error=
           pair.first_direction.aggregate_normalized_error,
       first_direction_maximum_spread=
           pair.first_direction.maximum_direction_spread)
end

function paired_outcome_row(frame, stage, constrained, relaxed)
    constrained.input_identity_sha256 == relaxed.input_identity_sha256 ||
        error("paired arms do not share the same input identity")
    (; frame, stage=String(stage),
       input_identity_sha256=constrained.input_identity_sha256,
       constrained_transmitted_word_equal=
           constrained.transmitted_word_equal,
       relaxed_transmitted_word_equal=relaxed.transmitted_word_equal,
       constrained_parity_valid=constrained.parity_valid,
       relaxed_parity_valid=relaxed.parity_valid,
       relaxed_minus_constrained_coded_bit_errors=
           relaxed.coded_bit_errors - constrained.coded_bit_errors,
       relaxed_minus_constrained_syndrome_weight=
           relaxed.syndrome_weight - constrained.syndrome_weight,
       relaxed_minus_constrained_parity_valid=
           Int(relaxed.parity_valid) - Int(constrained.parity_valid),
       relaxed_minus_constrained_transmitted_word_recovery=
           Int(relaxed.transmitted_word_equal) -
           Int(constrained.transmitted_word_equal),
       relaxed_only_transmitted_word_recovery=
           relaxed.transmitted_word_equal &&
           !constrained.transmitted_word_equal,
       constrained_only_transmitted_word_recovery=
           constrained.transmitted_word_equal &&
           !relaxed.transmitted_word_equal,
       terminal_hard_words_equal=
           relaxed.hard_word_sha256 == constrained.hard_word_sha256,
       terminal_mean_states_equal=
           relaxed.terminal_mean_sha256 == constrained.terminal_mean_sha256,
       relaxed_minus_constrained_accepted_steps=
           relaxed.accepted_steps - constrained.accepted_steps,
       relaxed_minus_constrained_effective_update=
           relaxed.effective_update - constrained.effective_update,
       constrained_optimized_persistent_value_count=
           constrained.optimized_persistent_value_count,
       constrained_frozen_offset_persistent_value_count=
           constrained.frozen_offset_persistent_value_count,
       constrained_redundant_state_cache_value_count=
           constrained.redundant_state_cache_value_count,
       constrained_total_persistent_value_count=
           constrained.total_persistent_value_count,
       relaxed_optimized_persistent_value_count=
           relaxed.optimized_persistent_value_count,
       relaxed_frozen_offset_persistent_value_count=
           relaxed.frozen_offset_persistent_value_count,
       relaxed_redundant_state_cache_value_count=
           relaxed.redundant_state_cache_value_count,
       relaxed_total_persistent_value_count=
           relaxed.total_persistent_value_count)
end

function paired_endpoint_counts(rows, relaxed_field::Symbol,
                                constrained_field::Symbol)
    both_success = 0
    relaxed_only = 0
    constrained_only = 0
    both_failure = 0
    for row in rows
        relaxed = Bool(getproperty(row, relaxed_field))
        constrained = Bool(getproperty(row, constrained_field))
        if relaxed && constrained
            both_success += 1
        elseif relaxed
            relaxed_only += 1
        elseif constrained
            constrained_only += 1
        else
            both_failure += 1
        end
    end
    pairs = length(rows)
    Dict(
        "both_success" => both_success,
        "active_only_success" => relaxed_only,
        "control_only_success" => constrained_only,
        "both_failure" => both_failure,
        "pairs" => pairs,
        "active_successes" => both_success + relaxed_only,
        "control_successes" => both_success + constrained_only,
        "risk_difference_active_minus_control" =>
            pairs == 0 ? 0.0 : (relaxed_only - constrained_only) / pairs,
    )
end

function paired_endpoint_statistics(rows, relaxed_field::Symbol,
                                    constrained_field::Symbol,
                                    confidence_level::Float64)
    counts = paired_endpoint_counts(rows, relaxed_field, constrained_field)
    counts["pairs"] > 0 ||
        throw(ArgumentError("paired inference requires observations"))
    Dict(
        "counts" => counts,
        "mcnemar_exact_two_sided_pvalue" =>
            Legacy.mcnemar_exact_pvalue(counts),
        "newcombe_interval" => Legacy.newcombe_paired_interval(
            counts; confidence_level),
    )
end

function paired_inference(rows, config)
    confidence_level = Float64(
        config["inference"]["confidence_level"])
    Dict(
        "contrast" => String(config["inference"]["contrast"]),
        "confidence_level" => confidence_level,
        "primary_endpoint" =>
            "transmitted_word_equal_at_requested_update_30",
        "confirmatory_endpoint" =>
            "parity_valid_at_requested_update_30",
        "multiplicity_rule" =>
            String(config["inference"]["multiplicity_rule"]),
        "transmitted_word_equal" => paired_endpoint_statistics(
            rows, :relaxed_transmitted_word_equal,
            :constrained_transmitted_word_equal, confidence_level),
        "parity_valid" => paired_endpoint_statistics(
            rows, :relaxed_parity_valid, :constrained_parity_valid,
            confidence_level),
    )
end

function compare_frame(context, config, frame::Int; stage::Symbol)
    input = BlockA.Split.generate_input(
        context.split, context.native, context.code, frame)
    identities = Dict(String(key) => value
                      for (key, value) in pairs(input.identities))
    input_identity_sha256 = scientific_sha256(identities)
    problem = BlockA.V4.problem_for(
        context.split, context.code, input.clipped_llr)
    initial = tanh.(input.clipped_llr ./ 2.0)
    block_config = configured_block_a(context, config)
    seed = BlockA.common_update_one(
        problem, context.code, initial, context.split, block_config)
    canonical_spec = only(arm for arm in BlockA.ARMS
        if arm.name == "compound__box")
    canonical = BlockA.solve_arm(
        problem, context.code, initial, seed,
        canonical_spec, block_config)
    retained_gate = stage === :compatibility ?
        require_retained_block_a(
            frame, canonical, input, context.retained_frames,
            context.retained_iterations) : nothing
    pair = paired_per_frame_solve(
        problem, context.code, initial, seed, config; frame)

    require_trace_reproduction(frame, canonical, pair.constrained)
    update = pair.constrained.last_effective_update
    Tied.require_vector(frame, update, 0, "canonical_constrained_state",
                        canonical.x, pair.constrained.x)
    Tied.require_edges(frame, update, 0, "canonical_constrained_offsets",
                       canonical.delta, pair.constrained.delta)
    canonical.accepted_steps == pair.constrained.accepted_steps ||
        Tied.mismatch(frame, update, 0, "canonical_accepted_steps",
                      string(canonical.accepted_steps),
                      string(pair.constrained.accepted_steps))
    canonical.last_effective_update ==
        pair.constrained.last_effective_update ||
        Tied.mismatch(frame, update, 0, "canonical_effective_update",
                      string(canonical.last_effective_update),
                      string(pair.constrained.last_effective_update))
    canonical.status == pair.constrained.status ||
        Tied.mismatch(frame, update, 0, "canonical_status",
                      canonical.status, pair.constrained.status)
    Tied.require_metrics(frame, update, canonical.terminal_metrics,
                         pair.constrained.terminal_metrics)

    constrained_counts = persistent_state_counts(
        problem, :equality_constrained)
    relaxed_counts = persistent_state_counts(
        problem, :equality_relaxed)
    constrained_row = arm_frame_row(
        frame, stage, "equality_constrained", input_identity_sha256,
        seed, pair.constrained, pair, constrained_counts)
    relaxed_row = arm_frame_row(
        frame, stage, "equality_relaxed", input_identity_sha256,
        seed, pair.relaxed, pair, relaxed_counts)
    paired_row = paired_outcome_row(
        frame, stage, constrained_row, relaxed_row)
    iterations = NamedTuple[]
    for row in pair.constrained.trace
        push!(iterations, merge((; frame, stage=String(stage),
                                  arm="equality_constrained"), row))
    end
    for row in pair.relaxed.trace
        push!(iterations, merge((; frame, stage=String(stage),
                                  arm="equality_relaxed"), row))
    end
    (; frame_rows=[constrained_row, relaxed_row], paired_row,
       iteration_rows=iterations, identities,
       canonical_state_sha256=Tied.vector_sha256(canonical.x),
       canonical_trace_sha256=
           scientific_sha256(canonical.traces),
       constrained_trace_sha256=
           scientific_sha256(pair.constrained.trace),
       retained_gate,
       constrained_reproduction_passed=true)
end

function source_gate(config; config_path::AbstractString=DEFAULT_CONFIG)
    sources = config["sources"]
    resolve(path) = isabspath(path) ? normpath(path) :
        normpath(joinpath(HERE, path))
    registered_paths = Dict(
        "causal_freeze_manifest" => resolve(String(
            sources["causal_freeze_manifest"])),
        "block_a_runner" => resolve(String(sources["block_a_runner"])),
        "block_a_config" => resolve(String(sources["block_a_config"])),
        "block_a_calibration_completion" => resolve(String(
            sources["block_a_calibration_completion"])),
        "block_a_calibration_manifest" => resolve(String(
            sources["block_a_calibration_manifest"])),
        "failed_predecessor_manifest" => resolve(String(
            sources["failed_predecessor_manifest"])),
        "jade_project_toml" => String(sources["jade_project_toml"]),
        "jade_manifest_toml" => String(sources["jade_manifest_toml"]),
        "jade_receiver_core" => String(sources["jade_receiver_core"]),
        "jade_core_common" => String(sources["jade_core_common"]),
        "jade_joint_projected_gradient" => String(
            sources["jade_joint_projected_gradient"]),
    )
    jade_project_repo = realpath(String(sources["jade_project_repo"]))
    jade_head = readchomp(`git -C $jade_project_repo rev-parse HEAD`)
    identities = Dict(
        "runner_sha256" => Tied.file_sha256(@__FILE__),
        "config_sha256" => Tied.file_sha256(config_path),
        "causal_freeze_manifest_sha256" => Tied.file_sha256(
            registered_paths["causal_freeze_manifest"]),
        "block_a_runner_sha256" => Tied.file_sha256(
            registered_paths["block_a_runner"]),
        "block_a_config_sha256" => Tied.file_sha256(
            registered_paths["block_a_config"]),
        "block_a_calibration_completion_sha256" => Tied.file_sha256(
            registered_paths["block_a_calibration_completion"]),
        "block_a_calibration_manifest_sha256" => Tied.file_sha256(
            registered_paths["block_a_calibration_manifest"]),
        "failed_predecessor_manifest_sha256" => Tied.file_sha256(
            registered_paths["failed_predecessor_manifest"]),
        "jade_project_head" => jade_head,
        "jade_project_toml_sha256" => Tied.file_sha256(
            registered_paths["jade_project_toml"]),
        "jade_manifest_toml_sha256" => Tied.file_sha256(
            registered_paths["jade_manifest_toml"]),
        "jade_receiver_core_sha256" => Tied.file_sha256(
            registered_paths["jade_receiver_core"]),
        "jade_core_common_sha256" => Tied.file_sha256(
            registered_paths["jade_core_common"]),
        "jade_joint_projected_gradient_sha256" => Tied.file_sha256(
            registered_paths["jade_joint_projected_gradient"]),
    )
    completion = TOML.parsefile(
        registered_paths["block_a_calibration_completion"])
    calibration_directory = dirname(
        registered_paths["block_a_calibration_completion"])
    calibration_manifest_entries = checksum_manifest_entries(
        registered_paths["block_a_calibration_manifest"])
    calibration_frames_path = joinpath(calibration_directory, "frames.csv")
    calibration_iterations_path = joinpath(
        calibration_directory, "iterations.csv")
    checks = Dict{String,Bool}(
        "source_files_exist" => all(isfile, values(registered_paths)),
        "runtime_block_a_is_registered" =>
            normpath(registered_paths["block_a_runner"]) ==
                normpath(BLOCK_A_RUNNER) &&
            normpath(registered_paths["block_a_config"]) ==
                normpath(BLOCK_A_CONFIG),
        "causal_freeze_manifest" =>
            identities["causal_freeze_manifest_sha256"] ==
                String(sources["causal_freeze_manifest_sha256"]),
        "block_a_runner" => identities["block_a_runner_sha256"] ==
            String(sources["block_a_runner_sha256"]),
        "block_a_config" => identities["block_a_config_sha256"] ==
            String(sources["block_a_config_sha256"]),
        "block_a_calibration_completion" =>
            identities["block_a_calibration_completion_sha256"] ==
                String(sources["block_a_calibration_completion_sha256"]),
        "block_a_calibration_manifest" =>
            identities["block_a_calibration_manifest_sha256"] ==
                String(sources["block_a_calibration_manifest_sha256"]),
        "failed_predecessor_manifest" =>
            identities["failed_predecessor_manifest_sha256"] ==
                String(sources["failed_predecessor_manifest_sha256"]),
        "jade_project_head" => jade_head ==
            String(sources["jade_project_expected_head"]),
        "jade_project_toml" =>
            identities["jade_project_toml_sha256"] ==
                String(sources["jade_project_toml_sha256"]),
        "jade_manifest_toml" =>
            identities["jade_manifest_toml_sha256"] ==
                String(sources["jade_manifest_toml_sha256"]),
        "jade_receiver_core" =>
            identities["jade_receiver_core_sha256"] ==
                String(sources["jade_receiver_core_sha256"]),
        "jade_core_common" =>
            identities["jade_core_common_sha256"] ==
                String(sources["jade_core_common_sha256"]),
        "jade_joint_projected_gradient" =>
            identities["jade_joint_projected_gradient_sha256"] ==
                String(sources["jade_joint_projected_gradient_sha256"]),
        "loaded_jade_project" => realpath(dirname(dirname(
            pathof(BlockA.JadeJcade)))) == jade_project_repo,
        "block_a_calibration_status" =>
            get(completion, "status", "") ==
                String(sources["block_a_calibration_status_expected"]),
        "block_a_calibration_science" =>
            get(completion, "primary_science_sha256", "") ==
                String(sources[
                    "block_a_calibration_primary_science_sha256"]) &&
            get(completion, "replay_science_sha256", "") ==
                String(sources[
                    "block_a_calibration_primary_science_sha256"]) &&
            get(completion, "science_sha256", "") ==
                String(sources[
                    "block_a_calibration_science_file_sha256"]),
        "calibration_frames_manifest_entry" =>
            haskey(calibration_manifest_entries, "frames.csv") &&
            isfile(calibration_frames_path) &&
            Tied.file_sha256(calibration_frames_path) ==
                calibration_manifest_entries["frames.csv"],
        "calibration_iterations_manifest_entry" =>
            haskey(calibration_manifest_entries, "iterations.csv") &&
            isfile(calibration_iterations_path) &&
            Tied.file_sha256(calibration_iterations_path) ==
                calibration_manifest_entries["iterations.csv"],
    )
    all(values(checks)) || error("source identity gate failed")
    (; passed=true, checks, identities,
       calibration_frames_path, calibration_iterations_path,
       source_gate_sha256=scientific_sha256(identities))
end

function backend_context()
    block_config = BlockA.load_config(BLOCK_A_CONFIG)
    v4_config = BlockA.V4.load_config(BlockA.v4_config_path(block_config))
    split = BlockA.V4.load_split_config(v4_config)
    Legacy.enforce_thread_environment(split)
    native = BlockA.Split.load_native(split)
    generated = BlockA.Split.make_code(split, native)
    sources = load_config(DEFAULT_CONFIG)["sources"]
    calibration_completion = normpath(joinpath(
        HERE, String(sources["block_a_calibration_completion"])))
    calibration_directory = dirname(calibration_completion)
    retained_frame_rows = Legacy.parse_simple_csv(
        joinpath(calibration_directory, "frames.csv"))
    retained_iteration_rows = Legacy.parse_simple_csv(
        joinpath(calibration_directory, "iterations.csv"))
    retained_frames = Dict{Int,Any}()
    for row in retained_frame_rows
        row.arm == "compound__box" || continue
        parse(Int, row.checkpoint_update) == 30 || continue
        retained_frames[parse(Int, row.frame)] = row
    end
    retained_iterations = Dict{Tuple{Int,Int},Any}()
    for row in retained_iteration_rows
        row.arm == "compound__box" || continue
        update = parse(Int, row.update)
        update <= 30 || continue
        retained_iterations[(parse(Int, row.frame), update)] = row
    end
    (; block_config, split, native, code=generated.code,
       retained_frames, retained_iterations)
end

function transfer_prerequisite_gate(path::AbstractString,
                                    config_path::AbstractString,
                                    expected_source_hash::AbstractString)
    isfile(path) || throw(ArgumentError(
        "transfer requires an existing anchor job_gate.toml"))
    gate = TOML.parsefile(path)
    completion_path = joinpath(dirname(path), "COMPLETED.toml")
    isfile(completion_path) || throw(ArgumentError(
        "transfer requires anchor COMPLETED.toml"))
    completion = TOML.parsefile(completion_path)
    result_root = dirname(path)
    manifest_path = joinpath(result_root, "MANIFEST.sha256")
    isfile(manifest_path) || throw(ArgumentError(
        "transfer requires anchor MANIFEST.sha256"))
    manifest_entries = checksum_manifest_entries(manifest_path)
    for (relative, expected) in manifest_entries
        isabspath(relative) && error("unsafe absolute anchor manifest path")
        any(part -> part == "..", splitpath(relative)) &&
            error("unsafe parent anchor manifest path")
        candidate = joinpath(result_root, relative)
        isfile(candidate) || error(
            "anchor manifest entry is missing: $relative")
        Tied.file_sha256(candidate) == expected || error(
            "anchor manifest digest differs: $relative")
    end
    config_hash = Tied.file_sha256(config_path)
    checks = Dict(
        "experiment_id" => get(gate, "experiment_id", "") ==
            EXPERIMENT_ID && get(completion, "experiment_id", "") ==
            EXPERIMENT_ID,
        "anchor_stage" => get(gate, "stage", "") == "anchor" &&
            get(completion, "stage", "") == "anchor",
        "gate_pass" => get(gate, "status", "") == "pass" &&
            get(gate, "correctness_passed", false) == true &&
            get(gate, "projection_passed", false) == true &&
            get(gate, "deterministic_replay_passed", false) == true,
        "completion_valid" =>
            get(completion, "status", "") == "complete_valid",
        "config_hash" => get(gate, "config_sha256", "") == config_hash &&
            get(completion, "config_sha256", "") == config_hash,
        "source_hash" => get(gate, "source_gate_sha256", "") ==
            expected_source_hash &&
            get(completion, "source_gate_sha256", "") ==
                expected_source_hash,
        "science_hash" => get(gate, "primary_science_sha256", "") ==
            get(gate, "replay_science_sha256", "") &&
            get(gate, "primary_science_sha256", "") ==
                get(completion, "science_sha256", ""),
        "manifest_job_gate" =>
            get(manifest_entries, "job_gate.toml", "") ==
                Tied.file_sha256(path),
        "manifest_completion" =>
            get(manifest_entries, "COMPLETED.toml", "") ==
                Tied.file_sha256(completion_path),
        "manifest_science" =>
            haskey(manifest_entries, "science.json"),
    )
    all(values(checks)) || error("anchor prerequisite gate failed")
    science = Dict(
        "experiment_id" => EXPERIMENT_ID,
        "stage" => "anchor",
        "status" => "complete_valid",
        "config_sha256" => config_hash,
        "source_gate_sha256" => expected_source_hash,
        "science_sha256" => String(gate["primary_science_sha256"]),
        "frame_count" => Int(gate["frame_count"]),
    )
    integrity = Dict(
        "job_gate_sha256" => Tied.file_sha256(path),
        "completion_sha256" => Tied.file_sha256(completion_path),
        "manifest_sha256" => Tied.file_sha256(manifest_path),
    )
    (; passed=true, checks, science, integrity)
end

function stage_frames(config, stage::Symbol)
    protocol = config["protocol"]
    prefix = stage === :compatibility ? "compatibility" :
        stage === :anchor ? "anchor" :
        stage === :transfer ? "transfer" :
        throw(ArgumentError("unknown stage $stage"))
    Int(protocol[prefix * "_first"]):Int(protocol[prefix * "_last"])
end

function write_progress(path, stage, pass_name, phase, completed, total;
                        status="running", previous_seconds=0.0)
    payload = Dict(
        "schema_version" => PROGRESS_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "stage" => String(stage), "status" => status,
        "pass" => pass_name, "phase" => phase,
        "completed_frames" => completed, "total_frames" => total,
        "previous_phase_seconds" => previous_seconds,
        "updated_utc" => string(now(UTC)),
    )
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, payload; sorted=true)
        write(io, '\n')
    end
    mv(temporary, path; force=true)
end

function log_phase(path, pass_name, phase, event, seconds)
    new_file = !isfile(path)
    open(path, "a") do io
        new_file && println(io, "utc\tpass\tphase\tevent\tseconds")
        println(io, string(now(UTC)), '\t', pass_name, '\t', phase,
                '\t', event, '\t', @sprintf("%.6f", seconds))
    end
end

function run_pass(config, stage, source, prerequisite, pass_name,
                  progress_path, phase_log_path)
    registered_frames = stage_frames(config, stage)
    compatibility_frames = stage_frames(config, :compatibility)
    phase_started = time_ns()
    write_progress(progress_path, stage, pass_name, "context", 0,
                   length(registered_frames))
    log_phase(phase_log_path, pass_name, "context", "start", 0.0)
    context = backend_context()
    context_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "context", "end", context_seconds)

    phase_started = time_ns()
    write_progress(progress_path, stage, pass_name, "compatibility", 0,
                   length(compatibility_frames);
                   previous_seconds=context_seconds)
    log_phase(phase_log_path, pass_name, "compatibility", "start", 0.0)
    compatibility = Any[]
    timing_rows = NamedTuple[]
    for (index, frame) in enumerate(compatibility_frames)
        frame_started = time_ns()
        result = compare_frame(context, config, frame; stage=:compatibility)
        wall_seconds = (time_ns() - frame_started) / 1.0e9
        push!(timing_rows, (; pass=pass_name, stage=String(stage),
                            role="compatibility", frame, wall_seconds))
        push!(compatibility, Dict(
            "frame" => frame,
            "canonical_state_sha256" => result.canonical_state_sha256,
            "canonical_trace_sha256" => result.canonical_trace_sha256,
            "constrained_trace_sha256" =>
                result.constrained_trace_sha256,
            "retained_iteration_sha256" =>
                result.retained_gate.retained_iteration_sha256,
            "retained_frame_sha256" =>
                result.retained_gate.retained_frame_sha256,
            "retained_evidence_passed" =>
                result.retained_gate.passed,
            "constrained_reproduction_passed" =>
                result.constrained_reproduction_passed,
        ))
        write_progress(progress_path, stage, pass_name, "compatibility",
                       index, length(compatibility_frames))
    end
    compatibility_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "compatibility", "end",
              compatibility_seconds)

    phase_started = time_ns()
    write_progress(progress_path, stage, pass_name, "frames", 0,
                   length(registered_frames);
                   previous_seconds=compatibility_seconds)
    log_phase(phase_log_path, pass_name, "frames", "start", 0.0)
    frame_rows = NamedTuple[]
    paired_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    input_identities = Any[]
    for (index, frame) in enumerate(registered_frames)
        frame_started = time_ns()
        result = compare_frame(context, config, frame; stage)
        wall_seconds = (time_ns() - frame_started) / 1.0e9
        append!(frame_rows, result.frame_rows)
        push!(paired_rows, result.paired_row)
        append!(iteration_rows, result.iteration_rows)
        push!(timing_rows, (; pass=pass_name, stage=String(stage),
                            role="registered_case", frame, wall_seconds))
        push!(input_identities, Dict(
            "frame" => frame, "identities" => result.identities))
        write_progress(progress_path, stage, pass_name, "frames", index,
                       length(registered_frames))
    end
    frame_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "frames", "end", frame_seconds)
    science = Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "stage" => String(stage),
        "frame_first" => first(registered_frames),
        "frame_last" => last(registered_frames),
        "frame_count" => length(registered_frames),
        "source_gate_sha256" => source.source_gate_sha256,
        "transfer_prerequisite" => prerequisite === nothing ? nothing :
            prerequisite.science,
        "compatibility" => compatibility,
        "frames" => frame_rows,
        "paired_outcomes" => paired_rows,
        "paired_inference" => paired_inference(paired_rows, config),
        "iterations" => iteration_rows,
        "input_identities" => input_identities,
    )
    (; science, frame_rows, paired_rows, iteration_rows, timing_rows,
       seconds=context_seconds + compatibility_seconds + frame_seconds)
end

write_json(path, value) = open(path, "w") do io
    write(io, canonical_json(value)); write(io, '\n')
end
write_toml(path, value) = open(path, "w") do io
    TOML.print(io, value; sorted=true); write(io, '\n')
end
function write_csv(path, rows)
    isempty(rows) && return open(path, "w") do _ end
    Legacy.write_csv(path, rows, collect(keys(first(rows))))
end
function write_manifest(output)
    files = String[]
    for (root, _, names) in walkdir(output), name in names
        relative = relpath(joinpath(root, name), output)
        relative == "MANIFEST.sha256" && continue
        push!(files, relative)
    end
    sort!(files)
    open(joinpath(output, "MANIFEST.sha256"), "w") do io
        for relative in files
            println(io, Tied.file_sha256(joinpath(output, relative)),
                    "  ", relative)
        end
    end
end

function run_stage(stage::Symbol;
                   config_path::AbstractString=DEFAULT_CONFIG,
                   output::AbstractString,
                   prerequisite::Union{Nothing,AbstractString}=nothing)
    ispath(output) &&
        throw(ArgumentError("refusing to overwrite result $output"))
    mkpath(output)
    progress_path = joinpath(output, "progress.toml")
    phase_log_path = joinpath(output, "phase_log.tsv")
    started = time_ns()
    try
        stage in (:anchor, :transfer) ||
            throw(ArgumentError("stage must be anchor or transfer"))
        Threads.nthreads() == 1 ||
            error("registered execution requires one Julia thread")
        BLAS.get_num_threads() == 1 ||
            error("registered execution requires one BLAS thread")
        stage === :transfer && prerequisite === nothing &&
            throw(ArgumentError("transfer requires an anchor prerequisite"))
        stage === :anchor && prerequisite !== nothing &&
            throw(ArgumentError("anchor does not accept a prerequisite"))
        config = load_config(config_path)
        source = source_gate(config; config_path)
        prerequisite_gate = stage === :transfer ?
            transfer_prerequisite_gate(
                String(prerequisite), config_path,
                source.source_gate_sha256) : nothing
        primary = run_pass(config, stage, source, prerequisite_gate,
                           "primary", progress_path, phase_log_path)
        checkpoint = joinpath(output, "primary_checkpoint")
        mkpath(checkpoint)
        write_json(joinpath(checkpoint, "science.json"), primary.science)
        write_csv(joinpath(checkpoint, "frames.csv"), primary.frame_rows)
        write_csv(joinpath(checkpoint, "paired_outcomes.csv"),
                  primary.paired_rows)
        write_csv(joinpath(checkpoint, "iterations.csv"),
                  primary.iteration_rows)
        write_csv(joinpath(checkpoint, "timing_primary.csv"),
                  primary.timing_rows)
        write_manifest(checkpoint)

        replay = run_pass(config, stage, source, prerequisite_gate,
                          "replay", progress_path, phase_log_path)
        primary_hash = scientific_sha256(primary.science)
        replay_hash = scientific_sha256(replay.science)
        deterministic = primary_hash == replay_hash
        deterministic || error("deterministic replay differs")
        correctness = all(
            Bool(row.boundary_gate_passed) &&
            Bool(row.objective_identity_passed) &&
            Bool(row.first_direction_gate_passed) &&
            Bool(row.finite_difference_schedule_passed) &&
            String(row.finite_difference_updates_checked) == "2;30"
            for row in primary.frame_rows)
        projection = all(
            Bool(row.inside_box) && Bool(row.all_finite)
            for row in primary.frame_rows)
        valid = correctness && projection && deterministic

        write_json(joinpath(output, "science.json"), primary.science)
        write_csv(joinpath(output, "frames.csv"), primary.frame_rows)
        write_csv(joinpath(output, "paired_outcomes.csv"),
                  primary.paired_rows)
        write_csv(joinpath(output, "iterations.csv"),
                  primary.iteration_rows)
        write_csv(joinpath(output, "timing_primary.csv"),
                  primary.timing_rows)
        write_csv(joinpath(output, "timing_replay.csv"),
                  replay.timing_rows)
        config_hash = Tied.file_sha256(config_path)
        gate = Dict(
            "schema_version" => GATE_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "stage" => String(stage),
            "status" => valid ? "pass" : "fail",
            "correctness_passed" => correctness,
            "projection_passed" => projection,
            "deterministic_replay_passed" => deterministic,
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "primary_science_sha256" => primary_hash,
            "replay_science_sha256" => replay_hash,
            "frame_count" => length(stage_frames(config, stage)),
        )
        if prerequisite_gate !== nothing
            gate["anchor_prerequisite_job_gate_sha256"] =
                prerequisite_gate.integrity["job_gate_sha256"]
            gate["anchor_prerequisite_completion_sha256"] =
                prerequisite_gate.integrity["completion_sha256"]
            gate["anchor_prerequisite_manifest_sha256"] =
                prerequisite_gate.integrity["manifest_sha256"]
        end
        write_toml(joinpath(output, "job_gate.toml"), gate)
        completion = Dict(
            "schema_version" => COMPLETION_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "stage" => String(stage),
            "status" => valid ? "complete_valid" : "complete_invalid",
            "science_sha256" => primary_hash,
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "primary_seconds" => primary.seconds,
            "replay_seconds" => replay.seconds,
            "total_seconds" => (time_ns() - started) / 1.0e9,
            "completed_utc" => string(now(UTC)),
        )
        write_toml(joinpath(output, "COMPLETED.toml"), completion)
        write_progress(progress_path, stage, "replay", "write_result",
                       length(stage_frames(config, stage)),
                       length(stage_frames(config, stage));
                       status=String(completion["status"]))
        write_manifest(output)
        println("$(completion["status"]) science_sha256=$primary_hash")
        (; completion, gate, output=abspath(output))
    catch error
        total_frames = if @isdefined(config) && stage in (:anchor, :transfer)
            length(stage_frames(config, stage))
        else
            0
        end
        failure = Dict(
            "schema_version" =>
                "rq2-bounded-edge-freedom-001/failure-v1",
            "experiment_id" => EXPERIMENT_ID,
            "stage" => String(stage), "status" => "failed",
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
            "failed_utc" => string(now(UTC)),
        )
        write_toml(joinpath(output, "FAILURE.toml"), failure)
        write_progress(progress_path, stage, "unknown", "failed", 0,
                       total_frames; status="failed")
        write_manifest(output)
        rethrow()
    end
end

function parse_options(arguments)
    options = Dict{String,String}()
    index = 1
    while index <= length(arguments)
        startswith(arguments[index], "--") ||
            throw(ArgumentError("expected option, got $(arguments[index])"))
        index < length(arguments) ||
            throw(ArgumentError("missing value for $(arguments[index])"))
        options[arguments[index][3:end]] = arguments[index + 1]
        index += 2
    end
    options
end

function main(arguments=ARGS)
    isempty(arguments) && throw(ArgumentError(
        "usage: rq2_bounded_edge_freedom_001.jl run --config PATH " *
        "--stage anchor|transfer --output DIR [--prerequisite PATH]"))
    arguments[1] == "run" ||
        throw(ArgumentError("only the run command is supported"))
    options = parse_options(arguments[2:end])
    for required in ("config", "stage", "output")
        haskey(options, required) ||
            throw(ArgumentError("--$required is required"))
    end
    run_stage(Symbol(options["stage"]);
              config_path=options["config"], output=options["output"],
              prerequisite=get(options, "prerequisite", nothing))
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
