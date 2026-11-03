#!/usr/bin/env julia

module RQ2EdgeFreedom001

using Dates
using LinearAlgebra
using Printf
using TOML

const HERE = @__DIR__
const EXPERIMENT_ID = "RQ2-EDGE-FREEDOM-001"
const CONFIG_SCHEMA = "rq2-edge-freedom-001/config-v1"
const SCIENCE_SCHEMA = "rq2-edge-freedom-001/science-v1"
const GATE_SCHEMA = "rq2-edge-freedom-001/gate-v1"
const COMPLETION_SCHEMA = "rq2-edge-freedom-001/completion-v1"
const PROGRESS_SCHEMA = "rq2-edge-freedom-001/progress-v1"
const TIED_RUNNER = normpath(joinpath(
    HERE, "..", "rq2_tied_scalar_edge_repro_001",
    "rq2_tied_scalar_edge_repro_001.jl"))

include(TIED_RUNNER)
const Tied = RQ2TiedScalarEdgeRepro001
const Composition = Tied.Composition
const BlockA = Tied.BlockA
const Legacy = Tied.Legacy
const TIED_CONFIG = normpath(joinpath(
    HERE, "..", "rq2_tied_scalar_edge_repro_001", "config.toml"))
const TIED_RESULT = normpath(joinpath(
    HERE, "..", "rq2_tied_scalar_edge_repro_001", "results",
    "2026-11-03_v1"))

export load_config, LiftedWorkspace, centered_mean!, centered_mean,
       lifted_evaluate!, aggregate_edge_gradient!,
       constrained_metric_direction!, free_metric_direction!,
       canonical_edge_samples, edge_finite_difference_gate,
       direction_gate, stability_diagnostics, paired_per_frame_solve
export source_gate, transfer_prerequisite_gate, compare_frame,
       run_stage, main

"""Reusable storage for the shared lifted objective and its edge partials."""
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

function load_config(path::AbstractString=joinpath(HERE, "config.toml"))
    config = TOML.parsefile(path)
    get(config, "schema_version", "") == CONFIG_SCHEMA ||
        throw(ArgumentError("unsupported configuration schema"))
    get(config, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("unexpected experiment identifier"))
    solver = config["solver"]
    Int(solver["maximum_update_attempts"]) == 30 ||
        throw(ArgumentError("registered update budget changed"))
    Float64(solver["initial_step"]) == 0.2 ||
        throw(ArgumentError("registered initial step changed"))
    Int(solver["maximum_backtracks"]) == 16 ||
        throw(ArgumentError("registered backtracking budget changed"))
    Bool(solver["projection_after_common_update"]) == false ||
        throw(ArgumentError("a post-common-update projection is forbidden"))
    String(solver["edge_metric"]) ==
        "scalar_curvature_bound_divided_by_variable_degree" ||
        throw(ArgumentError("registered edge metric changed"))
    String(solver["hard_decision_state"]) ==
        "canonical_copy_plus_mean_deviation" ||
        throw(ArgumentError("registered hard-decision state changed"))
    Float64(solver["absolute_state_safety_limit"]) > 0.0 ||
        throw(ArgumentError("absolute-state safety limit must be positive"))
    validation = config["validation"]
    Int(validation["finite_difference_sample_count"]) > 0 ||
        throw(ArgumentError("finite-difference sample count must be positive"))
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

"""
Compute each bit's state as one canonical copy plus the mean deviation from it.

The exact-copy fast path preserves every bit pattern, including signed zero,
when the input is on the equality-constrained manifold.
"""
function centered_mean!(destination, z, problem)
    length(destination) == length(problem.var_edges) ||
        throw(DimensionMismatch("mean-state length changed"))
    validate_edge_rows(problem, z, "persistent state")
    @inbounds for bit in eachindex(problem.var_edges)
        incident = problem.var_edges[bit]
        isempty(incident) && throw(ArgumentError("coded bit $bit has no incident check"))
        first_check, first_slot = first(incident)
        canonical = Float64(z[first_check][first_slot])
        all_exact_copies = true
        deviation_sum = 0.0
        for (check_index, slot) in incident
            value = Float64(z[check_index][slot])
            all_exact_copies &= Tied.float_bits_equal(value, canonical)
            deviation_sum += value - canonical
        end
        destination[bit] = all_exact_copies ? canonical :
            canonical + deviation_sum / length(incident)
    end
    destination
end

function centered_mean(z, problem)
    destination = zeros(Float64, length(problem.var_edges))
    centered_mean!(destination, z, problem)
end

"""Evaluate the single objective used by both arms and all edge partials."""
function lifted_evaluate!(workspace::LiftedWorkspace, problem, z, delta_rows)
    validate_edge_rows(problem, delta_rows, "frozen offset")
    centered_mean!(workspace.mean, z, problem)
    scalar = Tied.tied_evaluate!(
        workspace.scalar, problem, workspace.mean, z, delta_rows;
        enforce_tied=false)
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            degree = length(problem.var_edges[bit])
            workspace.edge_gradient[check_index][slot] =
                scalar.h[bit] / degree + scalar.g_rows[check_index][slot]
        end
    end
    (; loss=scalar.loss, terms=scalar.terms,
       mean=workspace.mean, scalar_gradient=scalar.gradient,
       h=scalar.h, g_rows=scalar.g_rows,
       edge_gradient=workspace.edge_gradient)
end

"""Sum edge-coordinate partials back to one scalar partial per coded bit."""
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

"""Constrained metric-gradient direction, broadcast to every incident copy."""
function constrained_metric_direction!(scalar_direction, edge_direction,
                                       problem, scalar_gradient)
    length(scalar_direction) == length(problem.llr) ||
        throw(DimensionMismatch("constrained direction length changed"))
    validate_edge_rows(problem, edge_direction, "constrained direction")
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

"""Free metric-gradient direction using M_(c,i)=kappa_i/d_i."""
function free_metric_direction!(edge_direction, problem, edge_gradient)
    validate_edge_rows(problem, edge_direction, "free direction")
    validate_edge_rows(problem, edge_gradient, "edge partial")
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            degree = length(problem.var_edges[bit])
            metric = Float64(problem.curvature_bound[bit]) / degree
            isfinite(metric) && metric > 0.0 ||
                throw(ArgumentError("invalid edge metric at check $check_index slot $slot"))
            edge_direction[check_index][slot] =
                -Float64(edge_gradient[check_index][slot]) / metric
        end
    end
    edge_direction
end

function spread_summary(rows, problem)
    maximum_spread = 0.0
    maximum_bit = 0
    spread_sum = 0.0
    @inbounds for bit in eachindex(problem.var_edges)
        incident = problem.var_edges[bit]
        first_check, first_slot = first(incident)
        low = Float64(rows[first_check][first_slot])
        high = low
        for (check_index, slot) in incident
            value = Float64(rows[check_index][slot])
            low = min(low, value)
            high = max(high, value)
        end
        spread = high - low
        spread_sum += spread
        if spread > maximum_spread
            maximum_spread = spread
            maximum_bit = bit
        end
    end
    (; maximum_spread, maximum_bit,
       mean_spread=spread_sum / length(problem.var_edges))
end

"""Gate the tied pullback identity and the first free-direction prediction."""
function direction_gate(problem, evaluated;
                        aggregate_tolerance::Float64=5.0e-12,
                        mean_tolerance::Float64=5.0e-12,
                        require_nonzero_spread::Bool=true)
    aggregate = zeros(Float64, length(problem.llr))
    aggregate_edge_gradient!(aggregate, problem, evaluated.edge_gradient)
    aggregate_error = maximum(abs.(aggregate .- evaluated.scalar_gradient))

    constrained_scalar = similar(aggregate)
    constrained_edges = Legacy.zero_edge_rows(problem.check_vars)
    constrained_metric_direction!(
        constrained_scalar, constrained_edges, problem,
        evaluated.scalar_gradient)
    free_edges = Legacy.zero_edge_rows(problem.check_vars)
    free_metric_direction!(free_edges, problem, evaluated.edge_gradient)
    free_mean = centered_mean(free_edges, problem)
    mean_direction_error = maximum(abs.(free_mean .- constrained_scalar))
    spread = spread_summary(free_edges, problem)
    nonzero_spread = spread.maximum_spread > 0.0
    checks = Dict(
        "aggregate_gradient" => aggregate_error <= aggregate_tolerance,
        "mean_direction" => mean_direction_error <= mean_tolerance,
        "nonzero_within_bit_directional_spread" =>
            !require_nonzero_spread || nonzero_spread,
    )
    (; passed=all(values(checks)), checks, aggregate_error,
       mean_direction_error, nonzero_spread,
       maximum_direction_spread=spread.maximum_spread,
       maximum_direction_spread_bit=spread.maximum_bit,
       aggregate, constrained_scalar, constrained_edges, free_edges, free_mean)
end

"""Select deterministic, graph-order-spanning edge coordinates."""
function canonical_edge_samples(problem, requested::Integer)
    requested > 0 || throw(ArgumentError("sample count must be positive"))
    edges = Tuple{Int,Int}[]
    for (check_index, check) in enumerate(problem.check_vars)
        for slot in eachindex(check)
            push!(edges, (check_index, slot))
        end
    end
    count = min(Int(requested), length(edges))
    count == length(edges) && return edges
    [edges[fld((2sample - 1) * length(edges), 2count) + 1]
     for sample in 1:count]
end

function edge_local_objective(problem, mean_state, z, delta_rows,
                              check_index::Int, slot::Int,
                              replacement::Float64)
    bit = problem.check_vars[check_index][slot]
    n = length(problem.llr)
    degree = length(problem.var_edges[bit])
    current = Float64(z[check_index][slot])
    changed_mean = Float64(mean_state[bit]) + (replacement - current) / degree
    value = -problem.llr[bit] * changed_mean / (2n) +
        problem.binary_weight * (1.0 - changed_mean^2)^2 / n
    product = 1.0
    @inbounds for (other_slot, _) in enumerate(problem.check_vars[check_index])
        state = other_slot == slot ? replacement :
            Float64(z[check_index][other_slot])
        product *= state + Float64(delta_rows[check_index][other_slot])
    end
    value - 2.0 * problem.parity_weight * product / n
end

"""Five-point finite-difference gate on a deterministic edge sample."""
function edge_finite_difference_gate(problem, z, delta_rows, edge_gradient;
                                     sample_count::Int=12,
                                     step::Float64=1.0e-6,
                                     tolerance::Float64=5.0e-8)
    step > 0.0 || throw(ArgumentError("finite-difference step must be positive"))
    samples = canonical_edge_samples(problem, sample_count)
    mean_state = centered_mean(z, problem)
    state_before = Tied.edge_sha256(z)
    offset_before = Tied.edge_sha256(delta_rows)
    rows = NamedTuple[]
    maximum_error = 0.0
    maximum_connection = (0, 0)
    for (check_index, slot) in samples
        center = Float64(z[check_index][slot])
        objective(replacement) = edge_local_objective(
            problem, mean_state, z, delta_rows, check_index, slot, replacement)
        numerical = (objective(center - 2step) - 8objective(center - step) +
                     8objective(center + step) - objective(center + 2step)) /
                    (12step)
        analytic = Float64(edge_gradient[check_index][slot])
        error = abs(numerical - analytic)
        push!(rows, (; check_index, slot,
                     bit=problem.check_vars[check_index][slot],
                     analytic, numerical, error))
        if error > maximum_error
            maximum_error = error
            maximum_connection = (check_index, slot)
        end
    end
    state_after = Tied.edge_sha256(z)
    offset_after = Tied.edge_sha256(delta_rows)
    checks = Dict(
        "finite_difference" => maximum_error <= tolerance,
        "persistent_state_unchanged" => state_before == state_after,
        "frozen_offsets_unchanged" => offset_before == offset_after,
    )
    (; passed=all(values(checks)), checks, maximum_error,
       maximum_connection, rows, state_before, state_after,
       offset_before, offset_after)
end

"""State-growth diagnostics for the noncoercive equality-relaxed objective."""
function stability_diagnostics(problem, z;
                               absolute_state_safety_limit::Float64=1.0e6)
    mean_state = centered_mean(z, problem)
    all_finite = all(row -> all(isfinite, row), z) && all(isfinite, mean_state)
    maximum_absolute_state = all_finite ?
        maximum(abs(Float64(value)) for row in z for value in row) : Inf
    maximum_absolute_mean = all_finite ? maximum(abs, mean_state) : Inf
    spread = all_finite ? spread_summary(z, problem) :
        (; maximum_spread=Inf, maximum_bit=0, mean_spread=Inf)
    safety_passed = all_finite &&
        maximum_absolute_state <= absolute_state_safety_limit
    (; all_finite, safety_passed, maximum_absolute_state,
       maximum_absolute_mean,
       maximum_within_bit_spread=spread.maximum_spread,
       maximum_within_bit_spread_bit=spread.maximum_bit,
       mean_within_bit_spread=spread.mean_spread,
       mean_state_sha256=Tied.vector_sha256(mean_state),
       persistent_state_sha256=Tied.edge_sha256(z),
       mean_state)
end

function independent_state_metrics(problem, x)
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

state_metrics(problem, code, x) = code === nothing ?
    independent_state_metrics(problem, x) : BlockA.state_metrics(problem, code, x)

function boundary_equal(problem, code, constrained_evaluation,
                        relaxed_evaluation, constrained_delta, relaxed_delta)
    constrained_metrics = state_metrics(
        problem, code, constrained_evaluation.mean)
    relaxed_metrics = state_metrics(problem, code, relaxed_evaluation.mean)
    checks = Dict(
        "objective" => Tied.float_bits_equal(
            constrained_evaluation.loss, relaxed_evaluation.loss),
        "mean_state" => Tied.vector_bits_equal(
            constrained_evaluation.mean, relaxed_evaluation.mean),
        "hard_decision" => constrained_metrics.hard == relaxed_metrics.hard,
        "syndrome" => constrained_metrics.syndrome == relaxed_metrics.syndrome,
        "frozen_offsets" => Tied.edge_bits_equal(
            constrained_delta, relaxed_delta),
    )
    (; passed=all(values(checks)), checks,
       constrained_metrics, relaxed_metrics)
end

function seed_trace(seed, metrics, z, delta, stability, shared)
    row = seed.trace[1]
    (; update=1, accepted=true, parity_rule="compound_common_update",
       feasible_set="common_tied_state", loss_before=Float64(row["loss_before"]),
       loss_after=Float64(row["accepted_fixed_offset_loss"]),
       shared_objective_before=Float64(shared.loss),
       shared_channel_before=Float64(shared.terms.channel),
       shared_parity_before=Float64(shared.terms.parity),
       shared_binary_before=Float64(shared.terms.binary),
       accepted_step=Float64(row["accepted_step"]),
       trial_count=Int(row["trial_count"]),
       finite_difference_checked=true,
       finite_difference_maximum_error=
           Float64(row["finite_difference_maximum_error"]),
       mean_state_sha256=Tied.vector_sha256(seed.x),
       persistent_state_sha256=Tied.edge_sha256(z),
       frozen_offset_sha256=Tied.edge_sha256(delta),
       coded_bit_errors=metrics.coded_bit_errors,
       syndrome_weight=metrics.syndrome_weight,
       parity_valid=metrics.parity_valid,
       transmitted_word_equal=metrics.transmitted_word_equal,
       maximum_absolute_state=stability.maximum_absolute_state,
       maximum_within_bit_spread=stability.maximum_within_bit_spread,
       stability_event="")
end

function trial_safety_event(z, limit)
    for row in z, value in row
        isfinite(value) || return "nonfinite_trial_state"
        abs(Float64(value)) <= limit ||
            return "absolute_state_safety_limit_exceeded"
    end
    nothing
end

function constrained_search(problem, x, z, delta, evaluated,
                            scalar_direction, trial_workspace,
                            initial_step, maximum_backtracks, safety_limit)
    trial_x = similar(x)
    trial_z = Legacy.zero_edge_rows(problem.check_vars)
    for backtrack in 0:maximum_backtracks
        step = initial_step * 0.5^backtrack
        @inbounds for bit in eachindex(x)
            trial_x[bit] = x[bit] + step * scalar_direction[bit]
        end
        lifted = Tied.lift_scalar(trial_x, problem.check_vars)
        for check_index in eachindex(trial_z)
            copyto!(trial_z[check_index], lifted[check_index])
        end
        safety_event = trial_safety_event(trial_z, safety_limit)
        safety_event === nothing || return (;
            accepted=false, step=0.0, trial_count=backtrack + 1,
            loss=evaluated.loss, x=copy(x),
            z=Legacy.copy_edge_rows(z), failure_status=safety_event)
        trial = lifted_evaluate!(trial_workspace, problem, trial_z, delta)
        isfinite(trial.loss) || return (;
            accepted=false, step=0.0, trial_count=backtrack + 1,
            loss=evaluated.loss, x=copy(x),
            z=Legacy.copy_edge_rows(z),
            failure_status="nonfinite_trial_objective")
        if isfinite(trial.loss) && trial.loss < evaluated.loss
            return (; accepted=true, step, trial_count=backtrack + 1,
                    loss=trial.loss, x=copy(trial_x),
                    z=Legacy.copy_edge_rows(trial_z), failure_status=nothing)
        end
    end
    (; accepted=false, step=0.0,
       trial_count=maximum_backtracks + 1, loss=evaluated.loss,
       x=copy(x), z=Legacy.copy_edge_rows(z), failure_status=nothing)
end

function relaxed_search(problem, z, delta, evaluated, edge_direction,
                        trial_workspace, initial_step, maximum_backtracks,
                        safety_limit)
    trial_z = Legacy.zero_edge_rows(problem.check_vars)
    for backtrack in 0:maximum_backtracks
        step = initial_step * 0.5^backtrack
        @inbounds for check_index in eachindex(z)
            for slot in eachindex(z[check_index])
                trial_z[check_index][slot] = z[check_index][slot] +
                    step * edge_direction[check_index][slot]
            end
        end
        safety_event = trial_safety_event(trial_z, safety_limit)
        safety_event === nothing || return (;
            accepted=false, step=0.0, trial_count=backtrack + 1,
            loss=evaluated.loss, z=Legacy.copy_edge_rows(z),
            failure_status=safety_event)
        trial = lifted_evaluate!(trial_workspace, problem, trial_z, delta)
        isfinite(trial.loss) || return (;
            accepted=false, step=0.0, trial_count=backtrack + 1,
            loss=evaluated.loss, z=Legacy.copy_edge_rows(z),
            failure_status="nonfinite_trial_objective")
        if isfinite(trial.loss) && trial.loss < evaluated.loss
            return (; accepted=true, step, trial_count=backtrack + 1,
                    loss=trial.loss, z=Legacy.copy_edge_rows(trial_z),
                    failure_status=nothing)
        end
    end
    (; accepted=false, step=0.0,
       trial_count=maximum_backtracks + 1, loss=evaluated.loss,
       z=Legacy.copy_edge_rows(z), failure_status=nothing)
end

function trace_row(update, feasible_set, before, search, metrics, stability,
                   delta, fd)
    (; update, accepted=search.accepted, parity_rule="shared_lifted_product",
       feasible_set, loss_before=before.loss, loss_after=search.loss,
       shared_objective_before=before.loss,
       shared_channel_before=before.terms.channel,
       shared_parity_before=before.terms.parity,
       shared_binary_before=before.terms.binary,
       accepted_step=search.step, trial_count=search.trial_count,
       finite_difference_checked=fd !== nothing,
       finite_difference_maximum_error=
           fd === nothing ? 0.0 : fd.maximum_error,
       mean_state_sha256=stability.mean_state_sha256,
       persistent_state_sha256=stability.persistent_state_sha256,
       frozen_offset_sha256=Tied.edge_sha256(delta),
       coded_bit_errors=metrics.coded_bit_errors,
       syndrome_weight=metrics.syndrome_weight,
       parity_valid=metrics.parity_valid,
       transmitted_word_equal=metrics.transmitted_word_equal,
       maximum_absolute_state=stability.maximum_absolute_state,
       maximum_within_bit_spread=stability.maximum_within_bit_spread,
       stability_event=search.failure_status === nothing ? "" :
           String(search.failure_status))
end

"""
Run the registered pair from the common update-1 seed.

`code=nothing` is reserved for synthetic unit tests; scientific frame runners
must pass the retained LDPC code so the independent syndrome cross-check runs.
"""
function paired_per_frame_solve(problem, code, initial, seed, config;
                                frame::Int=0)
    solver = config["solver"]
    validation = config["validation"]
    maximum_updates = Int(solver["maximum_update_attempts"])
    initial_step = Float64(solver["initial_step"])
    maximum_backtracks = Int(solver["maximum_backtracks"])
    safety_limit = Float64(solver["absolute_state_safety_limit"])
    fd_updates = Set(Int.(validation["finite_difference_updates"]))
    fd_samples = Int(validation["finite_difference_sample_count"])
    fd_step = Float64(validation["finite_difference_step"])
    fd_tolerance = Float64(validation["finite_difference_tolerance"])
    aggregate_tolerance = Float64(validation["aggregate_gradient_tolerance"])
    mean_tolerance = Float64(validation["mean_direction_tolerance"])
    require_spread = Bool(validation["require_nonzero_first_direction_spread"])

    x_constrained = copy(seed.x)
    z_constrained = Tied.lift_scalar(seed.x, problem.check_vars)
    z_relaxed = Tied.lift_scalar(seed.x, problem.check_vars)
    delta_constrained = Legacy.copy_edge_rows(seed.delta)
    delta_relaxed = Legacy.copy_edge_rows(seed.delta)
    offset_hash = Tied.edge_sha256(seed.delta)

    constrained_current_workspace = LiftedWorkspace(problem)
    constrained_trial_workspace = LiftedWorkspace(problem)
    relaxed_current_workspace = LiftedWorkspace(problem)
    relaxed_trial_workspace = LiftedWorkspace(problem)
    constrained_scalar_direction = zeros(Float64, length(problem.llr))
    constrained_edge_direction = Legacy.zero_edge_rows(problem.check_vars)
    relaxed_edge_direction = Legacy.zero_edge_rows(problem.check_vars)

    seed_mean = centered_mean(z_constrained, problem)
    seed_metrics = state_metrics(problem, code, seed_mean)
    seed_shared = lifted_evaluate!(
        constrained_current_workspace, problem, z_constrained,
        delta_constrained)
    constrained_stability = stability_diagnostics(
        problem, z_constrained; absolute_state_safety_limit=safety_limit)
    relaxed_stability = stability_diagnostics(
        problem, z_relaxed; absolute_state_safety_limit=safety_limit)
    constrained_stability.safety_passed ||
        error("common constrained state failed the safety gate")
    relaxed_stability.safety_passed ||
        error("common relaxed state failed the safety gate")
    constrained_trace = [seed_trace(
        seed, seed_metrics, z_constrained, delta_constrained,
        constrained_stability, seed_shared)]
    relaxed_trace = [seed_trace(
        seed, seed_metrics, z_relaxed, delta_relaxed, relaxed_stability,
        seed_shared)]

    constrained_status = "steps_completed"
    relaxed_status = "steps_completed"
    constrained_active = true
    relaxed_active = true
    constrained_accepted_steps = 1
    relaxed_accepted_steps = 1
    constrained_effective_update = 1
    relaxed_effective_update = 1
    maximum_constrained_fd_error =
        Float64(seed.trace[1]["finite_difference_maximum_error"])
    maximum_relaxed_fd_error = maximum_constrained_fd_error
    treatment_boundary = nothing
    first_direction = nothing

    for update in 2:maximum_updates
        constrained_before = constrained_active ? lifted_evaluate!(
            constrained_current_workspace, problem, z_constrained,
            delta_constrained) : nothing
        relaxed_before = relaxed_active ? lifted_evaluate!(
            relaxed_current_workspace, problem, z_relaxed, delta_relaxed) : nothing

        if update == 2
            constrained_before === nothing && error("constrained arm inactive at treatment boundary")
            relaxed_before === nothing && error("relaxed arm inactive at treatment boundary")
            treatment_boundary = boundary_equal(
                problem, code, constrained_before, relaxed_before,
                delta_constrained, delta_relaxed)
            treatment_boundary.passed || error(
                "treatment-boundary equality gate failed on frame $frame")
            first_direction = direction_gate(
                problem, relaxed_before;
                aggregate_tolerance, mean_tolerance,
                require_nonzero_spread=require_spread)
            first_direction.passed || error(
                "first treatment-direction gate failed on frame $frame")
        end

        if constrained_active
            aggregate = zeros(Float64, length(problem.llr))
            aggregate_edge_gradient!(
                aggregate, problem, constrained_before.edge_gradient)
            maximum(abs.(aggregate .- constrained_before.scalar_gradient)) <=
                aggregate_tolerance || error(
                    "constrained pullback-gradient gate failed on frame $frame update $update")
            constrained_fd = update in fd_updates ? edge_finite_difference_gate(
                problem, z_constrained, delta_constrained,
                constrained_before.edge_gradient;
                sample_count=fd_samples, step=fd_step,
                tolerance=fd_tolerance) : nothing
            constrained_fd === nothing || constrained_fd.passed || error(
                "constrained finite-difference gate failed on frame $frame update $update")
            constrained_fd === nothing ||
                (maximum_constrained_fd_error = max(
                    maximum_constrained_fd_error,
                    constrained_fd.maximum_error))
            constrained_metric_direction!(
                constrained_scalar_direction, constrained_edge_direction,
                problem, constrained_before.scalar_gradient)
            search = constrained_search(
                problem, x_constrained, z_constrained, delta_constrained,
                constrained_before, constrained_scalar_direction,
                constrained_trial_workspace, initial_step,
                maximum_backtracks, safety_limit)
            if search.accepted
                search.loss < constrained_before.loss || error(
                    "constrained accepted step was not a strict decrease")
                x_constrained = search.x
                z_constrained = search.z
                constrained_accepted_steps += 1
                constrained_effective_update = update
            else
                constrained_active = false
                constrained_status = search.failure_status === nothing ?
                    "line_search_stalled" : String(search.failure_status)
            end
            constrained_stability = stability_diagnostics(
                problem, z_constrained;
                absolute_state_safety_limit=safety_limit)
            constrained_metrics = state_metrics(
                problem, code, constrained_stability.mean_state)
            push!(constrained_trace, trace_row(
                update, "edge_copy_equality_constrained",
                constrained_before, search, constrained_metrics,
                constrained_stability, delta_constrained, constrained_fd))
            if !constrained_stability.safety_passed
                constrained_active = false
                constrained_status = constrained_stability.all_finite ?
                    "absolute_state_safety_limit_exceeded" : "nonfinite_state"
            end
        end

        if relaxed_active
            relaxed_fd = update in fd_updates ? edge_finite_difference_gate(
                problem, z_relaxed, delta_relaxed,
                relaxed_before.edge_gradient;
                sample_count=fd_samples, step=fd_step,
                tolerance=fd_tolerance) : nothing
            relaxed_fd === nothing || relaxed_fd.passed || error(
                "relaxed finite-difference gate failed on frame $frame update $update")
            relaxed_fd === nothing ||
                (maximum_relaxed_fd_error = max(
                    maximum_relaxed_fd_error, relaxed_fd.maximum_error))
            free_metric_direction!(
                relaxed_edge_direction, problem, relaxed_before.edge_gradient)
            search = relaxed_search(
                problem, z_relaxed, delta_relaxed, relaxed_before,
                relaxed_edge_direction, relaxed_trial_workspace,
                initial_step, maximum_backtracks, safety_limit)
            if search.accepted
                search.loss < relaxed_before.loss || error(
                    "relaxed accepted step was not a strict decrease")
                z_relaxed = search.z
                relaxed_accepted_steps += 1
                relaxed_effective_update = update
            else
                relaxed_active = false
                relaxed_status = search.failure_status === nothing ?
                    "line_search_stalled" : String(search.failure_status)
            end
            relaxed_stability = stability_diagnostics(
                problem, z_relaxed;
                absolute_state_safety_limit=safety_limit)
            relaxed_metrics = state_metrics(
                problem, code, relaxed_stability.mean_state)
            push!(relaxed_trace, trace_row(
                update, "edge_copy_equality_relaxed", relaxed_before,
                search, relaxed_metrics, relaxed_stability,
                delta_relaxed, relaxed_fd))
            if !relaxed_stability.safety_passed
                relaxed_active = false
                relaxed_status = relaxed_stability.all_finite ?
                    "absolute_state_safety_limit_exceeded" : "nonfinite_state"
            end
        end

        Tied.edge_sha256(delta_constrained) == offset_hash ||
            error("constrained arm changed frozen offsets")
        Tied.edge_sha256(delta_relaxed) == offset_hash ||
            error("relaxed arm changed frozen offsets")
        !constrained_active && !relaxed_active && break
    end

    treatment_boundary === nothing && error("treatment boundary was not evaluated")
    first_direction === nothing && error("first treatment direction was not evaluated")
    constrained_terminal_stability = stability_diagnostics(
        problem, z_constrained; absolute_state_safety_limit=safety_limit)
    relaxed_terminal_stability = stability_diagnostics(
        problem, z_relaxed; absolute_state_safety_limit=safety_limit)
    constrained_terminal_metrics = state_metrics(
        problem, code, constrained_terminal_stability.mean_state)
    relaxed_terminal_metrics = state_metrics(
        problem, code, relaxed_terminal_stability.mean_state)

    (; frame, treatment_boundary, first_direction,
       constrained=(;
           x=copy(x_constrained), z=Legacy.copy_edge_rows(z_constrained),
           delta=delta_constrained, trace=constrained_trace,
           status=constrained_status,
           accepted_steps=constrained_accepted_steps,
           last_effective_update=constrained_effective_update,
           maximum_finite_difference_error=maximum_constrained_fd_error,
           terminal_metrics=constrained_terminal_metrics,
           terminal_stability=constrained_terminal_stability),
       relaxed=(;
           z=Legacy.copy_edge_rows(z_relaxed), delta=delta_relaxed,
           trace=relaxed_trace, status=relaxed_status,
           accepted_steps=relaxed_accepted_steps,
           last_effective_update=relaxed_effective_update,
           maximum_finite_difference_error=maximum_relaxed_fd_error,
           terminal_metrics=relaxed_terminal_metrics,
           terminal_stability=relaxed_terminal_stability))
end

# ---------------------------------------------------------------------------
# Stage runner. Queue construction and launch remain separate from this file.
# ---------------------------------------------------------------------------

function source_gate(config)
    tied_config = Tied.load_config(TIED_CONFIG)
    tied_sources = Tied.source_gate(tied_config)
    tied_job_gate_path = joinpath(TIED_RESULT, "job_gate.toml")
    tied_completion_path = joinpath(TIED_RESULT, "COMPLETED.toml")
    tied_manifest_path = joinpath(TIED_RESULT, "MANIFEST.sha256")
    isfile(tied_job_gate_path) || error("missing sealed tied prerequisite gate")
    isfile(tied_completion_path) || error("missing sealed tied prerequisite completion")
    isfile(tied_manifest_path) || error("missing sealed tied prerequisite manifest")
    tied_job_gate = TOML.parsefile(tied_job_gate_path)
    tied_completion = TOML.parsefile(tied_completion_path)
    expected_science = String(config["sources"]["prerequisite_science_sha256"])
    checks = Dict(
        "sealed_source_gate" => Bool(tied_sources["passed"]),
        "prerequisite_gate_status" => get(tied_job_gate, "status", "") == "pass",
        "prerequisite_completion_status" =>
            get(tied_completion, "status", "") == "complete_valid",
        "prerequisite_experiment" =>
            get(tied_job_gate, "experiment_id", "") ==
                "RQ2-TIED-SCALAR-EDGE-REPRO-001" &&
            get(tied_completion, "experiment_id", "") ==
                "RQ2-TIED-SCALAR-EDGE-REPRO-001",
        "prerequisite_science" =>
            get(tied_job_gate, "primary_science_sha256", "") == expected_science &&
            get(tied_job_gate, "replay_science_sha256", "") == expected_science &&
            get(tied_completion, "science_sha256", "") == expected_science,
    )
    identities = Dict(
        "runner_sha256" => Tied.file_sha256(@__FILE__),
        "config_sha256" => Tied.file_sha256(joinpath(HERE, "config.toml")),
        "tied_runner_sha256" => Tied.file_sha256(TIED_RUNNER),
        "tied_config_sha256" => Tied.file_sha256(TIED_CONFIG),
        "tied_job_gate_sha256" => Tied.file_sha256(tied_job_gate_path),
        "tied_completion_sha256" => Tied.file_sha256(tied_completion_path),
        "tied_manifest_sha256" => Tied.file_sha256(tied_manifest_path),
        "composition_runner_sha256" => Tied.file_sha256(Tied.COMPOSITION_RUNNER),
        "composition_config_sha256" => Tied.file_sha256(Tied.COMPOSITION_CONFIG),
    )
    all(values(checks)) || error("sealed tied prerequisite gate failed")
    (; passed=true, checks, identities,
       source_gate_sha256=Composition.scientific_sha256(identities))
end

function transfer_prerequisite_gate(path::AbstractString,
                                    config_path::AbstractString,
                                    expected_source_hash::AbstractString)
    isfile(path) || throw(ArgumentError(
        "transfer requires an existing anchor job_gate.toml"))
    gate = TOML.parsefile(path)
    completion_path = joinpath(dirname(path), "COMPLETED.toml")
    isfile(completion_path) || throw(ArgumentError(
        "transfer requires the anchor COMPLETED.toml beside its gate"))
    completion = TOML.parsefile(completion_path)
    config_hash = Tied.file_sha256(config_path)
    checks = Dict(
        "experiment_id" => get(gate, "experiment_id", "") == EXPERIMENT_ID &&
            get(completion, "experiment_id", "") == EXPERIMENT_ID,
        "anchor_stage" => get(gate, "stage", "") == "anchor" &&
            get(completion, "stage", "") == "anchor",
        "gate_pass" => get(gate, "status", "") == "pass" &&
            get(gate, "correctness_passed", false) == true &&
            get(gate, "stability_passed", false) == true &&
            get(gate, "deterministic_replay_passed", false) == true,
        "completion_valid" =>
            get(completion, "status", "") == "complete_valid",
        "config_hash" => get(gate, "config_sha256", "") == config_hash &&
            get(completion, "config_sha256", "") == config_hash,
        "source_hash" => get(gate, "source_gate_sha256", "") ==
            expected_source_hash &&
            get(completion, "source_gate_sha256", "") == expected_source_hash,
        "science_hash" => get(gate, "primary_science_sha256", "") ==
            get(gate, "replay_science_sha256", "") &&
            get(gate, "primary_science_sha256", "") ==
                get(completion, "science_sha256", ""),
    )
    all(values(checks)) || error("anchor prerequisite gate failed")
    (; passed=true, checks,
       job_gate_sha256=Tied.file_sha256(path),
       completion_sha256=Tied.file_sha256(completion_path),
       science_sha256=String(gate["primary_science_sha256"]))
end

function configured_block_a(context, config)
    block_config = Composition.composition_block_a_config(context)
    block_config["solver"]["maximum_update_attempts"] =
        Int(config["solver"]["maximum_update_attempts"])
    block_config["solver"]["score_updates"] =
        [Int(config["solver"]["maximum_update_attempts"])]
    block_config["solver"]["initial_step"] =
        Float64(config["solver"]["initial_step"])
    block_config["solver"]["maximum_backtracks"] =
        Int(config["solver"]["maximum_backtracks"])
    block_config["validation"]["finite_difference_updates"] =
        Int.(config["validation"]["finite_difference_updates"])
    block_config["validation"]["finite_difference_step"] =
        Float64(config["validation"]["finite_difference_step"])
    block_config["validation"]["finite_difference_tolerance"] =
        Float64(config["validation"]["finite_difference_tolerance"])
    block_config
end

function arm_frame_row(frame, stage, arm, input_identity_sha256,
                       seed, result, pair)
    metrics = result.terminal_metrics
    stability = result.terminal_stability
    safety_status = !(result.status in (
        "nonfinite_trial_state", "nonfinite_trial_objective",
        "nonfinite_state", "absolute_state_safety_limit_exceeded"))
    (; frame, stage=String(stage), arm,
       input_identity_sha256,
       common_update1_mean_sha256=Tied.vector_sha256(seed.x),
       frozen_offset_sha256=Tied.edge_sha256(seed.delta),
       terminal_mean_sha256=stability.mean_state_sha256,
       terminal_persistent_state_sha256=stability.persistent_state_sha256,
       trace_sha256=Composition.scientific_sha256(result.trace),
       accepted_steps=result.accepted_steps,
       effective_update=result.last_effective_update,
       status=result.status,
       coded_bit_errors=metrics.coded_bit_errors,
       syndrome_weight=metrics.syndrome_weight,
       parity_valid=metrics.parity_valid,
       transmitted_word_equal=metrics.transmitted_word_equal,
       hard_word_sha256=metrics.hard_word_sha256,
       maximum_finite_difference_error=result.maximum_finite_difference_error,
       maximum_absolute_state=stability.maximum_absolute_state,
       maximum_absolute_mean=stability.maximum_absolute_mean,
       maximum_within_bit_spread=stability.maximum_within_bit_spread,
       all_finite=stability.all_finite && safety_status,
       safety_passed=stability.safety_passed && safety_status,
       boundary_gate_passed=pair.treatment_boundary.passed,
       first_direction_gate_passed=pair.first_direction.passed,
       first_direction_mean_error=pair.first_direction.mean_direction_error,
       first_direction_maximum_spread=
           pair.first_direction.maximum_direction_spread)
end

function compare_frame(context, config, frame::Int; stage::Symbol)
    input = Legacy.generate_input(
        context.split, context.native, context.code, frame)
    identities = Dict(String(key) => value
                      for (key, value) in pairs(input.identities))
    input_identity_sha256 = Composition.scientific_sha256(identities)
    problem = BlockA.V4.problem_for(
        context.split, context.code, input.clipped_llr)
    initial = tanh.(input.clipped_llr ./ 2.0)
    block_config = configured_block_a(context, config)
    seed = BlockA.common_update_one(
        problem, context.code, initial, context.split, block_config)
    canonical_spec = only(arm for arm in BlockA.ARMS
        if arm.name == "product_only__unconstrained")
    canonical = BlockA.solve_arm(
        problem, context.code, initial, seed, canonical_spec, block_config)
    pair = paired_per_frame_solve(
        problem, context.code, initial, seed, config; frame)

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

    constrained_row = arm_frame_row(
        frame, stage, "equality_constrained", input_identity_sha256,
        seed, pair.constrained, pair)
    relaxed_row = arm_frame_row(
        frame, stage, "equality_relaxed", input_identity_sha256,
        seed, pair.relaxed, pair)
    iterations = NamedTuple[]
    for row in pair.constrained.trace
        push!(iterations, merge(
            (; frame, stage=String(stage), arm="equality_constrained"), row))
    end
    for row in pair.relaxed.trace
        push!(iterations, merge(
            (; frame, stage=String(stage), arm="equality_relaxed"), row))
    end
    (; frame_rows=[constrained_row, relaxed_row], iteration_rows=iterations,
       identities, canonical_state_sha256=Tied.vector_sha256(canonical.x),
       constrained_reproduction_passed=true)
end

function stage_frames(config, stage::Symbol)
    protocol = config["protocol"]
    if stage === :anchor
        return Int(protocol["anchor_first"]):Int(protocol["anchor_last"])
    elseif stage === :transfer
        return Int(protocol["transfer_first"]):Int(protocol["transfer_last"])
    end
    throw(ArgumentError("stage must be anchor or transfer"))
end

function write_progress(path, stage, pass_name, phase, completed, total;
                        status="running", previous_seconds=0.0)
    payload = Dict(
        "schema_version" => PROGRESS_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "stage" => String(stage),
        "status" => status,
        "pass" => pass_name,
        "phase" => phase,
        "completed_frames" => completed,
        "total_frames" => total,
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
        println(io, string(now(UTC)), '\t', pass_name, '\t', phase, '\t',
                event, '\t', @sprintf("%.6f", seconds))
    end
end

function run_pass(config, stage, source, prerequisite, pass_name,
                  progress_path, phase_log_path)
    frames = stage_frames(config, stage)
    total = length(frames)
    phase_started = time_ns()
    write_progress(progress_path, stage, pass_name, "context", 0, total)
    log_phase(phase_log_path, pass_name, "context", "start", 0.0)
    composition_config = Composition.load_config(Tied.COMPOSITION_CONFIG)
    context = Composition.backend_context(
        composition_config, Tied.COMPOSITION_CONFIG)
    context_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "context", "end", context_seconds)

    phase_started = time_ns()
    write_progress(progress_path, stage, pass_name, "compatibility", 0, 2;
                   previous_seconds=context_seconds)
    log_phase(phase_log_path, pass_name, "compatibility", "start", 0.0)
    compatibility = Any[]
    for frame in Int.(config["validation"]["compatibility_frames"])
        result = compare_frame(context, config, frame; stage=:compatibility)
        push!(compatibility, Dict(
            "frame" => frame,
            "canonical_state_sha256" => result.canonical_state_sha256,
            "constrained_reproduction_passed" =>
                result.constrained_reproduction_passed,
            "frame_rows_sha256" =>
                Composition.scientific_sha256(result.frame_rows),
        ))
    end
    compatibility_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "compatibility", "end",
              compatibility_seconds)

    phase_started = time_ns()
    write_progress(progress_path, stage, pass_name, "frames", 0, total;
                   previous_seconds=compatibility_seconds)
    log_phase(phase_log_path, pass_name, "frames", "start", 0.0)
    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    input_identities = Any[]
    for (index, frame) in enumerate(frames)
        result = compare_frame(context, config, frame; stage)
        append!(frame_rows, result.frame_rows)
        append!(iteration_rows, result.iteration_rows)
        push!(input_identities, Dict(
            "frame" => frame, "identities" => result.identities))
        write_progress(progress_path, stage, pass_name, "frames", index, total)
    end
    frame_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "frames", "end", frame_seconds)
    science = Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "stage" => String(stage),
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "frame_count" => length(frames),
        "source_gate_sha256" => source.source_gate_sha256,
        "transfer_prerequisite" => prerequisite,
        "compatibility" => compatibility,
        "frames" => frame_rows,
        "iterations" => iteration_rows,
        "input_identities" => input_identities,
    )
    (; science, frame_rows, iteration_rows,
       seconds=context_seconds + compatibility_seconds + frame_seconds)
end

function write_json(path, value)
    open(path, "w") do io
        write(io, Composition.canonical_json(value))
        write(io, '\n')
    end
end

function write_toml(path, value)
    open(path, "w") do io
        TOML.print(io, value; sorted=true)
        write(io, '\n')
    end
end

function write_csv(path, rows)
    isempty(rows) && return open(path, "w") do _ end
    Composition.write_csv(path, rows, collect(keys(first(rows))))
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
                   config_path::AbstractString=joinpath(HERE, "config.toml"),
                   output::AbstractString,
                   prerequisite::Union{Nothing,AbstractString}=nothing)
    stage in (:anchor, :transfer) ||
        throw(ArgumentError("stage must be anchor or transfer"))
    ispath(output) && throw(ArgumentError("refusing to overwrite result $output"))
    Threads.nthreads() == 1 || error("registered execution requires one Julia thread")
    BLAS.get_num_threads() == 1 || error("registered execution requires one BLAS thread")
    stage === :transfer && prerequisite === nothing &&
        throw(ArgumentError("transfer requires --prerequisite anchor/job_gate.toml"))
    stage === :anchor && prerequisite !== nothing &&
        throw(ArgumentError("anchor does not accept a transfer prerequisite"))
    config = load_config(config_path)
    source = source_gate(config)
    prerequisite_gate = stage === :transfer ? transfer_prerequisite_gate(
        String(prerequisite), config_path, source.source_gate_sha256) : nothing
    mkpath(output)
    progress_path = joinpath(output, "progress.toml")
    phase_log_path = joinpath(output, "phase_log.tsv")
    started = time_ns()
    try
        primary = run_pass(config, stage, source, prerequisite_gate,
                           "primary", progress_path, phase_log_path)
        checkpoint = joinpath(output, "primary_checkpoint")
        mkpath(checkpoint)
        write_json(joinpath(checkpoint, "science.json"), primary.science)
        write_csv(joinpath(checkpoint, "frames.csv"), primary.frame_rows)
        write_csv(joinpath(checkpoint, "iterations.csv"), primary.iteration_rows)
        write_manifest(checkpoint)
        replay = run_pass(config, stage, source, prerequisite_gate,
                          "replay", progress_path, phase_log_path)
        primary_hash = Composition.scientific_sha256(primary.science)
        replay_hash = Composition.scientific_sha256(replay.science)
        deterministic = primary_hash == replay_hash
        deterministic || error("deterministic replay differs")
        correctness = all(Bool(row.boundary_gate_passed) &&
                          Bool(row.first_direction_gate_passed)
                          for row in primary.frame_rows)
        stability = all(Bool(row.safety_passed) && Bool(row.all_finite)
                        for row in primary.frame_rows)
        valid = correctness && stability && deterministic

        write_json(joinpath(output, "science.json"), primary.science)
        write_csv(joinpath(output, "frames.csv"), primary.frame_rows)
        write_csv(joinpath(output, "iterations.csv"), primary.iteration_rows)
        config_hash = Tied.file_sha256(config_path)
        gate = Dict(
            "schema_version" => GATE_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "stage" => String(stage),
            "status" => valid ? "pass" : "fail",
            "correctness_passed" => correctness,
            "stability_passed" => stability,
            "deterministic_replay_passed" => deterministic,
            "config_sha256" => config_hash,
            "source_gate_sha256" => source.source_gate_sha256,
            "primary_science_sha256" => primary_hash,
            "replay_science_sha256" => replay_hash,
            "frame_count" => length(stage_frames(config, stage)),
        )
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
        completion_status = String(completion["status"])
        println("$completion_status science_sha256=$primary_hash")
        (; completion, gate, output=abspath(output))
    catch error
        failure = Dict(
            "schema_version" => "rq2-edge-freedom-001/failure-v1",
            "experiment_id" => EXPERIMENT_ID,
            "stage" => String(stage),
            "status" => "failed",
            "error_type" => string(typeof(error)),
            "error" => sprint(showerror, error),
            "failed_utc" => string(now(UTC)),
        )
        write_toml(joinpath(output, "FAILURE.toml"), failure)
        write_progress(progress_path, stage, "unknown", "failed", 0,
                       length(stage_frames(config, stage)); status="failed")
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
        "usage: rq2_edge_freedom_001.jl run --config PATH " *
        "--stage anchor|transfer --output DIR [--prerequisite PATH]"))
    arguments[1] == "run" ||
        throw(ArgumentError("only the run command is supported"))
    options = parse_options(arguments[2:end])
    for required in ("config", "stage", "output")
        haskey(options, required) ||
            throw(ArgumentError("--$required is required"))
    end
    stage = Symbol(options["stage"])
    prerequisite = get(options, "prerequisite", nothing)
    run_stage(stage; config_path=options["config"],
              output=options["output"], prerequisite)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
