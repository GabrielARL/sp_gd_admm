#!/usr/bin/env julia

module RQ2TiedScalarEdgeRepro001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using SHA
using TOML

const HERE = @__DIR__
const EXPERIMENT_ID = "RQ2-TIED-SCALAR-EDGE-REPRO-001"
const CONFIG_SCHEMA = "rq2-tied-scalar-edge-repro-001/config-v1"
const SCIENCE_SCHEMA = "rq2-tied-scalar-edge-repro-001/science-v1"
const GATE_SCHEMA = "rq2-tied-scalar-edge-repro-001/gate-v1"
const COMPLETION_SCHEMA = "rq2-tied-scalar-edge-repro-001/completion-v1"
const PROGRESS_SCHEMA = "rq2-tied-scalar-edge-repro-001/progress-v1"

const NATIVE_FREEZE = normpath(joinpath(
    HERE, "..", "rq2_native_composition_001", "freeze", "2026-11-01_v2"))
const COMPOSITION_RUNNER = joinpath(NATIVE_FREEZE, "source", "native_composition.jl")
const COMPOSITION_CONFIG = joinpath(NATIVE_FREEZE, "source", "config.toml")
const ORACLE_RESULT = normpath(joinpath(
    HERE, "..", "rq2_native_composition_001", "results", "2026-11-01_v2",
    "03_native_endpoint_and_rung_gate"))
const ORACLE_FRAMES = joinpath(ORACLE_RESULT, "frames.csv")

include(COMPOSITION_RUNNER)
const Composition = RQ2NativeComposition001
const BlockA = Composition.BlockA
const Legacy = BlockA.Legacy

export load_config, lift_scalar, collapse_tied!, tied_evaluate!,
       tied_finite_difference_maximum, active_read_gate, compare_frame,
       run_gate, main

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
vector_sha256(values) = Legacy.vector_sha256(values)
edge_sha256(rows) = Legacy.edge_sha256(rows)
scientific_sha256(value) = Composition.scientific_sha256(value)
float_hex(value::Real) = @sprintf("0x%016x", reinterpret(UInt64, Float64(value)))

struct GateMismatch <: Exception
    frame::Int
    update::Int
    trial::Int
    field::String
    reference::String
    treatment::String
end

function Base.showerror(io::IO, error::GateMismatch)
    print(io, "tied scalar-to-edge mismatch at frame=$(error.frame) ",
          "update=$(error.update) trial=$(error.trial) field=$(error.field): ",
          "reference=$(error.reference), treatment=$(error.treatment)")
end

float_bits_equal(left::Real, right::Real) =
    reinterpret(UInt64, Float64(left)) == reinterpret(UInt64, Float64(right))

function vector_bits_equal(left, right)
    length(left) == length(right) || return false
    reinterpret(UInt64, Float64.(left)) == reinterpret(UInt64, Float64.(right))
end

function edge_bits_equal(left, right)
    length(left) == length(right) || return false
    all(length(left[index]) == length(right[index]) &&
        reinterpret(UInt64, Float64.(left[index])) ==
        reinterpret(UInt64, Float64.(right[index]))
        for index in eachindex(left))
end

function mismatch(frame, update, trial, field, reference, treatment)
    throw(GateMismatch(Int(frame), Int(update), Int(trial), String(field),
                       String(reference), String(treatment)))
end

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
        frame, update, trial, field, edge_sha256(reference), edge_sha256(treatment))
end

resolve_here(path::AbstractString) = isabspath(path) ? normpath(path) :
    normpath(joinpath(HERE, path))

function load_config(path::AbstractString=joinpath(HERE, "config.toml"))
    config = TOML.parsefile(path)
    get(config, "schema_version", "") == CONFIG_SCHEMA ||
        throw(ArgumentError("unsupported configuration schema"))
    get(config, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("unexpected experiment identifier"))
    protocol = config["protocol"]
    Int(protocol["frame_first"]) == 20001 ||
        throw(ArgumentError("retained first frame changed"))
    Int(protocol["frame_last"]) == 20024 ||
        throw(ArgumentError("retained last frame changed"))
    String(protocol["channel_label"]) == "six_db" ||
        throw(ArgumentError("retained channel changed"))
    Int(config["execution"]["scientific_passes"]) == 2 ||
        throw(ArgumentError("primary and deterministic replay are required"))
    Int(config["solver"]["maximum_update_attempts"]) == 30 ||
        throw(ArgumentError("update budget changed"))
    Bool(config["solver"]["projection_after_common_update"]) == false ||
        throw(ArgumentError("lower endpoint must remain unconstrained"))
    config
end

function source_gate(config)
    sources = config["sources"]
    paths = Dict(
        "native_freeze_manifest" => joinpath(NATIVE_FREEZE, "MANIFEST.sha256"),
        "composition_runner" => COMPOSITION_RUNNER,
        "composition_config" => COMPOSITION_CONFIG,
        "oracle_frames" => ORACLE_FRAMES,
        "oracle_completion" => joinpath(ORACLE_RESULT, "COMPLETED.toml"),
    )
    checks = Dict{String,Bool}()
    for (name, path) in paths
        key = name * "_sha256"
        checks[name] = isfile(path) && haskey(sources, key) &&
            file_sha256(path) == String(sources[key])
    end
    all(values(checks)) || error("source or retained-oracle hash gate failed")
    Dict("passed" => true, "checks" => checks,
         "paths" => Dict(key => abspath(value) for (key, value) in paths))
end

function lift_scalar(x, check_vars)
    [[Float64(x[bit]) for bit in check] for check in check_vars]
end

function assert_tied!(z, problem; frame::Int=0, update::Int=0, trial::Int=0)
    length(z) == length(problem.check_vars) || mismatch(
        frame, update, trial, "edge_row_count", string(length(problem.check_vars)),
        string(length(z)))
    for bit in eachindex(problem.var_edges)
        incident = problem.var_edges[bit]
        isempty(incident) && mismatch(frame, update, trial,
            "isolated_bit_$bit", "incident edge", "none")
        first_check, first_slot = first(incident)
        canonical = z[first_check][first_slot]
        for (check_index, slot) in incident
            float_bits_equal(canonical, z[check_index][slot]) || mismatch(
                frame, update, trial, "tied_copy_bit_$bit",
                float_hex(canonical), float_hex(z[check_index][slot]))
        end
    end
    true
end

function collapse_tied!(x, z, problem; frame::Int=0, update::Int=0, trial::Int=0)
    length(x) == length(problem.var_edges) || throw(DimensionMismatch(
        "temporary scalar length changed"))
    assert_tied!(z, problem; frame, update, trial)
    for bit in eachindex(problem.var_edges)
        check_index, slot = first(problem.var_edges[bit])
        x[bit] = z[check_index][slot]
    end
    x
end

"""Evaluate the retained product-only objective while parity products read z."""
function tied_evaluate!(workspace::Legacy.EvalWorkspace, problem, x, z,
                        delta_rows; enforce_tied::Bool=true,
                        frame::Int=0, update::Int=0, trial::Int=0)
    n = length(problem.llr)
    length(x) == n || throw(DimensionMismatch("temporary scalar length changed"))
    enforce_tied && assert_tied!(z, problem; frame, update, trial)
    fill!(workspace.gradient, 0.0)
    fill!(workspace.h, 0.0)
    for row in workspace.g_rows
        fill!(row, 0.0)
    end

    coefficient = -2.0 * problem.parity_weight / n
    parity = 0.0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        length(z[check_index]) == length(check) ||
            throw(DimensionMismatch("edge slot count changed"))
        product = 1.0
        for (slot, bit) in enumerate(check)
            workspace.prefix[slot] = product
            product *= Float64(z[check_index][slot]) +
                Float64(delta_rows[check_index][slot])
        end
        parity += coefficient * product
        suffix = 1.0
        for slot in length(check):-1:1
            bit = check[slot]
            contribution = coefficient * workspace.prefix[slot] * suffix
            workspace.gradient[bit] += contribution
            workspace.g_rows[check_index][slot] = contribution
            suffix *= Float64(z[check_index][slot]) +
                Float64(delta_rows[check_index][slot])
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

function compare_evaluation!(records, reference_workspace, treatment_workspace,
                             problem, reference_x, treatment_x, z,
                             reference_delta, treatment_delta;
                             frame::Int, update::Int, trial::Int, role::String)
    reference = BlockA.product_only_evaluate!(
        reference_workspace, problem, reference_x, reference_delta)
    treatment = tied_evaluate!(
        treatment_workspace, problem, treatment_x, z, treatment_delta;
        frame, update, trial)
    require_edges(frame, update, trial, "$(role)_frozen_offsets",
                  reference_delta, treatment_delta)
    for term in (:channel, :parity, :binary)
        require_float(frame, update, trial, "$(role)_$(term)",
            getproperty(reference.terms, term), getproperty(treatment.terms, term))
    end
    require_float(frame, update, trial, "$(role)_loss",
                  reference.loss, treatment.loss)
    require_vector(frame, update, trial, "$(role)_gradient",
                   reference.gradient, treatment.gradient)
    require_vector(frame, update, trial, "$(role)_h", reference.h, treatment.h)
    require_edges(frame, update, trial, "$(role)_check_partials",
                  reference.g_rows, treatment.g_rows)
    push!(records, (
        frame, update, trial, role,
        scalar_sha256=vector_sha256(reference_x),
        tied_scalar_sha256=vector_sha256(treatment_x),
        edge_state_sha256=edge_sha256(z),
        gradient_sha256=vector_sha256(reference.gradient),
        check_partial_sha256=edge_sha256(reference.g_rows),
        loss_hex=float_hex(reference.loss),
        channel_hex=float_hex(reference.terms.channel),
        parity_hex=float_hex(reference.terms.parity),
        binary_hex=float_hex(reference.terms.binary),
    ))
    reference, treatment
end

function tied_local_objective(problem, x, z, delta_rows, bit::Int,
                              replacement::Float64)
    n = length(x)
    value = -problem.llr[bit] * replacement / (2n) +
        problem.binary_weight * (1.0 - replacement^2)^2 / n
    for (check_index, _) in problem.var_edges[bit]
        product = 1.0
        for (slot, other_bit) in enumerate(problem.check_vars[check_index])
            scalar = other_bit == bit ? replacement :
                Float64(z[check_index][slot])
            product *= scalar + Float64(delta_rows[check_index][slot])
        end
        value += -2.0 * problem.parity_weight * product / n
    end
    value
end

function tied_finite_difference_maximum(problem, x, z, delta_rows,
                                        analytic_gradient;
                                        step::Float64=1.0e-6)
    maximum_error = 0.0
    maximum_bit = 0
    z_before = edge_sha256(z)
    delta_before = edge_sha256(delta_rows)
    for bit in eachindex(x)
        center = Float64(x[bit])
        objective(replacement) = tied_local_objective(
            problem, x, z, delta_rows, bit, replacement)
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
       z_sha256_before=z_before, z_sha256_after=edge_sha256(z),
       delta_sha256_before=delta_before,
       delta_sha256_after=edge_sha256(delta_rows))
end

function active_read_gate(problem, x, delta_rows)
    z = lift_scalar(x, problem.check_vars)
    baseline_workspace = Legacy.EvalWorkspace(problem)
    perturbed_workspace = Legacy.EvalWorkspace(problem)
    baseline = tied_evaluate!(baseline_workspace, problem, x, z, delta_rows)
    perturbed = Legacy.copy_edge_rows(z)
    # Slot (check 1, position 2) belongs to bit 2, which also occurs in check 2.
    # Changing only this stored copy proves both that the evaluator reads it and
    # that the tied-state invariant detects the disagreement.
    perturbed[1][2] += 0.25
    changed = tied_evaluate!(perturbed_workspace, problem, x, perturbed,
                             delta_rows; enforce_tied=false)
    untouched_rows = all(edge_bits_equal([baseline.g_rows[index]],
                                         [changed.g_rows[index]])
                         for index in 2:length(problem.check_vars))
    checks = Dict(
        "parity_reads_edge_state" =>
            !float_bits_equal(baseline.terms.parity, changed.terms.parity),
        "total_reads_edge_state" => !float_bits_equal(baseline.loss, changed.loss),
        "other_checks_unchanged" => untouched_rows,
        "perturbation_breaks_tied_invariant" => try
            assert_tied!(perturbed, problem)
            false
        catch error
            error isa GateMismatch
        end,
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function seed_trace_tuple(seed, metrics, delta)
    row = seed.trace[1]
    (
        update=1, accepted=true, parity_rule="compound_common_update",
        projection_rule="box_common_update",
        loss_before=Float64(row["loss_before"]),
        loss_after=Float64(row["accepted_fixed_offset_loss"]),
        accepted_step=Float64(row["accepted_step"]),
        trial_count=Int(row["trial_count"]),
        finite_difference_checked=true,
        finite_difference_maximum_error=
            Float64(row["finite_difference_maximum_error"]),
        finite_difference_maximum_bit=Int(row["finite_difference_maximum_bit"]),
        x_before_sha256=String(row["x_before_sha256"]),
        x_after_sha256=String(row["x_after_sha256"]),
        delta_sha256=edge_sha256(delta),
        coded_bit_errors=metrics.coded_bit_errors,
        syndrome_weight=metrics.syndrome_weight,
        parity_valid=metrics.parity_valid,
        transmitted_word_equal=metrics.transmitted_word_equal,
    )
end

function require_metrics(frame, update, reference, treatment)
    reference.hard == treatment.hard || mismatch(
        frame, update, 0, "hard_decision", vector_sha256(reference.hard),
        vector_sha256(treatment.hard))
    for field in (:syndrome_weight, :parity_valid, :transmitted_word_equal,
                  :coded_bit_errors, :hard_word_sha256, :scalar_sha256)
        left = getproperty(reference, field)
        right = getproperty(treatment, field)
        left == right || mismatch(frame, update, 0, String(field),
                                  string(left), string(right))
    end
end

function dual_solve(problem, code, initial, seed, config; frame::Int)
    solver = config["solver"]
    validation = config["validation"]
    maximum_updates = Int(solver["maximum_update_attempts"])
    initial_step = Float64(solver["initial_step"])
    maximum_backtracks = Int(solver["maximum_backtracks"])
    fd_updates = Set(Int.(validation["finite_difference_updates"]))
    fd_step = Float64(validation["finite_difference_step"])
    fd_tolerance = Float64(validation["finite_difference_tolerance"])

    x_reference = copy(seed.x)
    delta_reference = Legacy.copy_edge_rows(seed.delta)
    delta_treatment = Legacy.copy_edge_rows(seed.delta)
    z = lift_scalar(seed.x, problem.check_vars)
    z_trial = lift_scalar(seed.x, problem.check_vars)
    x_treatment = similar(x_reference)
    collapse_tied!(x_treatment, z, problem; frame, update=1, trial=0)
    require_vector(frame, 1, 0, "common_update_scalar", x_reference, x_treatment)

    reference_trial = similar(x_reference)
    treatment_trial = similar(x_reference)
    raw_reference = similar(x_reference)
    raw_treatment = similar(x_reference)
    reference_direction = similar(x_reference)
    treatment_direction = similar(x_reference)
    reference_workspace = Legacy.EvalWorkspace(problem)
    treatment_workspace = Legacy.EvalWorkspace(problem)
    trial_reference_workspace = Legacy.EvalWorkspace(problem)
    trial_treatment_workspace = Legacy.EvalWorkspace(problem)
    evaluations = NamedTuple[]

    initial_metrics = BlockA.state_metrics(problem, code, initial)
    reference_metrics = BlockA.state_metrics(problem, code, x_reference)
    treatment_metrics = BlockA.state_metrics(problem, code, x_treatment)
    require_metrics(frame, 1, reference_metrics, treatment_metrics)
    trace_reference = [seed_trace_tuple(
        seed, reference_metrics, delta_reference)]
    trace_treatment = [seed_trace_tuple(
        seed, treatment_metrics, delta_treatment)]
    scientific_sha256(trace_reference) == scientific_sha256(trace_treatment) ||
        mismatch(frame, 1, 0, "common_update_trace",
                 scientific_sha256(trace_reference),
                 scientific_sha256(trace_treatment))
    accepted_steps = 1
    last_effective_update = 1
    status = "steps_completed"
    first_valid_update = initial_metrics.parity_valid ? 0 :
        (reference_metrics.parity_valid ? 1 : nothing)
    first_exact_update = initial_metrics.transmitted_word_equal ? 0 :
        (reference_metrics.transmitted_word_equal ? 1 : nothing)
    maximum_fd_error = Float64(seed.trace[1]["finite_difference_maximum_error"])
    finite_difference_checks = 1
    all_strict_decrease = true
    last_objective = NaN

    for update in 2:maximum_updates
        collapse_tied!(x_treatment, z, problem; frame, update, trial=0)
        require_vector(frame, update, 0, "state_boundary", x_reference, x_treatment)
        reference, treatment = compare_evaluation!(
            evaluations, reference_workspace, treatment_workspace, problem,
            x_reference, x_treatment, z, delta_reference, delta_treatment;
            frame, update, trial=0, role="current")
        last_objective = reference.loss

        fd_checked = update in fd_updates
        fd_reference = if fd_checked
            BlockA.finite_difference_maximum(
                problem, x_reference, delta_reference, reference.gradient,
                :product_only;
                step=fd_step)
        else
            (; maximum_error=0.0, maximum_bit=0,
               delta_sha256_before=edge_sha256(delta_reference),
               delta_sha256_after=edge_sha256(delta_reference))
        end
        fd_treatment = if fd_checked
            tied_finite_difference_maximum(
                problem, x_treatment, z, delta_treatment,
                treatment.gradient; step=fd_step)
        else
            (; maximum_error=0.0, maximum_bit=0,
               z_sha256_before=edge_sha256(z), z_sha256_after=edge_sha256(z),
               delta_sha256_before=edge_sha256(delta_treatment),
               delta_sha256_after=edge_sha256(delta_treatment))
        end
        if fd_checked
            finite_difference_checks += 1
            require_float(frame, update, 0, "finite_difference_error",
                          fd_reference.maximum_error,
                          fd_treatment.maximum_error)
            fd_reference.maximum_bit == fd_treatment.maximum_bit || mismatch(
                frame, update, 0, "finite_difference_maximum_bit",
                string(fd_reference.maximum_bit), string(fd_treatment.maximum_bit))
            fd_treatment.maximum_error <= fd_tolerance || error(
                "tied finite-difference gate failed at frame $frame update $update")
            fd_treatment.z_sha256_before == fd_treatment.z_sha256_after ||
                error("finite differences changed authoritative edge state")
            fd_treatment.delta_sha256_before == fd_treatment.delta_sha256_after ||
                error("finite differences changed frozen offsets")
            maximum_fd_error = max(maximum_fd_error, fd_treatment.maximum_error)
        end

        for bit in eachindex(x_reference)
            reference_direction[bit] = -reference.gradient[bit] /
                problem.curvature_bound[bit]
            treatment_direction[bit] = -treatment.gradient[bit] /
                problem.curvature_bound[bit]
        end
        require_vector(frame, update, 0, "preconditioned_direction",
                       reference_direction, treatment_direction)

        accepted = false
        accepted_step = 0.0
        accepted_loss = reference.loss
        trial_count = 0
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            for bit in eachindex(x_reference)
                raw_reference[bit] = x_reference[bit] +
                    step * reference_direction[bit]
                raw_treatment[bit] = x_treatment[bit] +
                    step * treatment_direction[bit]
                reference_trial[bit] = raw_reference[bit]
                treatment_trial[bit] = raw_treatment[bit]
            end
            trial_count += 1
            require_vector(frame, update, trial_count, "raw_trial",
                           raw_reference, raw_treatment)
            require_vector(frame, update, trial_count, "unconstrained_trial",
                           reference_trial, treatment_trial)
            lifted = lift_scalar(treatment_trial, problem.check_vars)
            for check_index in eachindex(z_trial)
                copyto!(z_trial[check_index], lifted[check_index])
            end
            evaluated_reference, evaluated_treatment = compare_evaluation!(
                evaluations, trial_reference_workspace,
                trial_treatment_workspace, problem,
                reference_trial, treatment_trial, z_trial,
                delta_reference, delta_treatment;
                frame, update, trial=trial_count, role="trial")
            reference_accepts = isfinite(evaluated_reference.loss) &&
                evaluated_reference.loss < reference.loss
            treatment_accepts = isfinite(evaluated_treatment.loss) &&
                evaluated_treatment.loss < treatment.loss
            reference_accepts == treatment_accepts || mismatch(
                frame, update, trial_count, "acceptance_decision",
                string(reference_accepts), string(treatment_accepts))
            if reference_accepts
                accepted = true
                accepted_step = step
                accepted_loss = evaluated_reference.loss
                break
            end
        end

        x_before_hash = vector_sha256(x_reference)
        if !accepted
            status = "line_search_stalled"
            reference_metrics = BlockA.state_metrics(problem, code, x_reference)
            collapse_tied!(x_treatment, z, problem; frame, update, trial=0)
            treatment_metrics = BlockA.state_metrics(problem, code, x_treatment)
            require_metrics(frame, update, reference_metrics, treatment_metrics)
            row = (
                update, accepted=false, parity_rule="product_only",
                projection_rule="unconstrained", loss_before=reference.loss,
                loss_after=reference.loss, accepted_step=0.0, trial_count,
                finite_difference_checked=fd_checked,
                finite_difference_maximum_error=fd_reference.maximum_error,
                finite_difference_maximum_bit=fd_reference.maximum_bit,
                x_before_sha256=x_before_hash, x_after_sha256=x_before_hash,
                delta_sha256=edge_sha256(delta_reference),
                coded_bit_errors=reference_metrics.coded_bit_errors,
                syndrome_weight=reference_metrics.syndrome_weight,
                parity_valid=reference_metrics.parity_valid,
                transmitted_word_equal=reference_metrics.transmitted_word_equal,
            )
            push!(trace_reference, row)
            push!(trace_treatment, row)
            break
        end

        all_strict_decrease &= accepted_loss < reference.loss
        x_reference, reference_trial = reference_trial, x_reference
        z, z_trial = z_trial, z
        accepted_steps += 1
        last_effective_update = update
        last_objective = accepted_loss
        collapse_tied!(x_treatment, z, problem; frame, update, trial=0)
        require_vector(frame, update, 0, "accepted_state",
                       x_reference, x_treatment)
        reference_metrics = BlockA.state_metrics(problem, code, x_reference)
        treatment_metrics = BlockA.state_metrics(problem, code, x_treatment)
        require_metrics(frame, update, reference_metrics, treatment_metrics)
        first_valid_update === nothing && reference_metrics.parity_valid &&
            (first_valid_update = update)
        first_exact_update === nothing && reference_metrics.transmitted_word_equal &&
            (first_exact_update = update)
        row = (
            update, accepted=true, parity_rule="product_only",
            projection_rule="unconstrained", loss_before=reference.loss,
            loss_after=accepted_loss, accepted_step, trial_count,
            finite_difference_checked=fd_checked,
            finite_difference_maximum_error=fd_reference.maximum_error,
            finite_difference_maximum_bit=fd_reference.maximum_bit,
            x_before_sha256=x_before_hash,
            x_after_sha256=vector_sha256(x_reference),
            delta_sha256=edge_sha256(delta_reference),
            coded_bit_errors=reference_metrics.coded_bit_errors,
            syndrome_weight=reference_metrics.syndrome_weight,
            parity_valid=reference_metrics.parity_valid,
            transmitted_word_equal=reference_metrics.transmitted_word_equal,
        )
        push!(trace_reference, row)
        push!(trace_treatment, row)
    end

    all_strict_decrease || error("accepted step did not strictly decrease objective")
    collapse_tied!(x_treatment, z, problem; frame,
                   update=last_effective_update, trial=0)
    terminal_reference = BlockA.state_metrics(problem, code, x_reference)
    terminal_treatment = BlockA.state_metrics(problem, code, x_treatment)
    require_metrics(frame, last_effective_update,
                    terminal_reference, terminal_treatment)
    (; x_reference=copy(x_reference), z=Legacy.copy_edge_rows(z),
       x_treatment=copy(x_treatment), trace_reference, trace_treatment,
       delta_reference, delta_treatment, evaluations, accepted_steps,
       last_effective_update, status,
       first_valid_update, first_exact_update, finite_difference_checks,
       maximum_finite_difference_error=maximum_fd_error,
       last_objective, terminal_reference, terminal_treatment)
end

parse_bool(value) = lowercase(String(value)) == "true"

function retained_oracle_rows()
    rows = Dict{Int,Any}()
    for row in Legacy.parse_simple_csv(ORACLE_FRAMES)
        row.rung_id == "assigned_frozen_product_unconstrained" || continue
        rows[parse(Int, row.frame)] = row
    end
    length(rows) == 24 || error("retained rung-5 oracle does not have 24 frames")
    rows
end

function compare_frame(context, config, oracle_rows, frame::Int)
    retained_input = Legacy.generate_input(
        context.split, context.native, context.code, frame)
    identities = Dict(String(key) => value
                      for (key, value) in pairs(retained_input.identities))
    problem = BlockA.V4.problem_for(
        context.split, context.code, retained_input.clipped_llr)
    initial = tanh.(retained_input.clipped_llr ./ 2.0)
    block_config = Composition.composition_block_a_config(context)
    block_config["solver"]["maximum_update_attempts"] =
        Int(config["solver"]["maximum_update_attempts"])
    block_config["solver"]["score_updates"] = [30]
    block_config["solver"]["initial_step"] = Float64(config["solver"]["initial_step"])
    block_config["solver"]["maximum_backtracks"] =
        Int(config["solver"]["maximum_backtracks"])
    block_config["validation"]["finite_difference_updates"] =
        Int.(config["validation"]["finite_difference_updates"])
    block_config["validation"]["finite_difference_step"] =
        Float64(config["validation"]["finite_difference_step"])
    block_config["validation"]["finite_difference_tolerance"] =
        Float64(config["validation"]["finite_difference_tolerance"])

    seed = BlockA.common_update_one(
        problem, context.code, initial, context.split, block_config)
    spec = only(arm for arm in BlockA.ARMS
                if arm.name == "product_only__unconstrained")
    canonical = BlockA.solve_arm(
        problem, context.code, initial, seed, spec, block_config)
    active = active_read_gate(problem, seed.x, seed.delta)
    Bool(active["passed"]) || error("active edge-read gate failed")
    dual = dual_solve(problem, context.code, initial, seed, config; frame)

    require_vector(frame, dual.last_effective_update, 0,
                   "canonical_terminal_scalar", canonical.x, dual.x_reference)
    require_edges(frame, dual.last_effective_update, 0,
                  "canonical_reference_frozen_offsets", canonical.delta,
                  dual.delta_reference)
    require_edges(frame, dual.last_effective_update, 0,
                  "canonical_treatment_frozen_offsets", canonical.delta,
                  dual.delta_treatment)
    canonical.accepted_steps == dual.accepted_steps || mismatch(
        frame, dual.last_effective_update, 0, "canonical_accepted_steps",
        string(canonical.accepted_steps), string(dual.accepted_steps))
    canonical.last_effective_update == dual.last_effective_update || mismatch(
        frame, dual.last_effective_update, 0, "canonical_effective_update",
        string(canonical.last_effective_update), string(dual.last_effective_update))
    canonical.status == dual.status || mismatch(
        frame, dual.last_effective_update, 0, "canonical_status",
        canonical.status, dual.status)
    canonical.first_valid_update == dual.first_valid_update || mismatch(
        frame, dual.last_effective_update, 0, "canonical_first_valid_update",
        string(canonical.first_valid_update), string(dual.first_valid_update))
    canonical.first_exact_update == dual.first_exact_update || mismatch(
        frame, dual.last_effective_update, 0, "canonical_first_exact_update",
        string(canonical.first_exact_update), string(dual.first_exact_update))
    canonical.finite_difference_checks == dual.finite_difference_checks ||
        mismatch(frame, dual.last_effective_update, 0,
                 "canonical_finite_difference_checks",
                 string(canonical.finite_difference_checks),
                 string(dual.finite_difference_checks))
    require_float(frame, dual.last_effective_update, 0,
                  "canonical_maximum_finite_difference_error",
                  canonical.maximum_finite_difference_error,
                  dual.maximum_finite_difference_error)
    require_metrics(frame, dual.last_effective_update,
                    canonical.terminal_metrics, dual.terminal_reference)
    scientific_sha256(canonical.traces) == scientific_sha256(dual.trace_reference) ||
        mismatch(frame, dual.last_effective_update, 0, "canonical_trace",
                 scientific_sha256(canonical.traces),
                 scientific_sha256(dual.trace_reference))
    scientific_sha256(dual.trace_reference) ==
        scientific_sha256(dual.trace_treatment) || mismatch(
            frame, dual.last_effective_update, 0, "treatment_trace",
            scientific_sha256(dual.trace_reference),
            scientific_sha256(dual.trace_treatment))

    rung = Composition.rung_from_block_a(
        "assigned_frozen_product_unconstrained", canonical)
    retained = oracle_rows[frame]
    retained_checks = Dict(
        "llr_sha256" => rung === nothing ? false :
            retained_input.identities.clipped_llr_sha256 == retained.llr_sha256,
        "received_sha256" => retained_input.identities.received_sha256 ==
            retained.received_sha256,
        "state_sha256" => rung.state_sha256 == retained.state_sha256,
        "hard_word_sha256" => rung.hard_word_sha256 == retained.hard_word_sha256,
        "updates" => rung.updates == parse(Int, retained.updates),
        "status" => rung.status == retained.status,
        "coded_bit_errors" => rung.coded_bit_errors ==
            parse(Int, retained.coded_bit_errors),
        "syndrome_weight" => rung.syndrome_weight ==
            parse(Int, retained.syndrome_weight),
        "parity_valid" => rung.parity_valid == parse_bool(retained.parity_valid),
        "transmitted_word_equal" => rung.transmitted_word_equal ==
            parse_bool(retained.transmitted_word_equal),
    )
    all(values(retained_checks)) || error(
        "retained rung-5 oracle gate failed for frame $frame")

    frame_row = (
        frame, channel="six_db", snr_db=6.0,
        noise_seed=retained_input.noise_seed,
        input_identity_sha256=scientific_sha256(identities),
        common_update1_scalar_sha256=vector_sha256(seed.x),
        frozen_offset_sha256=edge_sha256(seed.delta),
        reference_terminal_scalar_sha256=vector_sha256(canonical.x),
        treatment_terminal_scalar_sha256=vector_sha256(dual.x_treatment),
        treatment_edge_state_sha256=edge_sha256(dual.z),
        reference_trace_sha256=scientific_sha256(canonical.traces),
        treatment_trace_sha256=scientific_sha256(dual.trace_treatment),
        evaluation_trace_sha256=scientific_sha256(dual.evaluations),
        accepted_steps=dual.accepted_steps,
        effective_update=dual.last_effective_update,
        status=dual.status,
        coded_bit_errors=dual.terminal_reference.coded_bit_errors,
        syndrome_weight=dual.terminal_reference.syndrome_weight,
        parity_valid=dual.terminal_reference.parity_valid,
        transmitted_word_equal=dual.terminal_reference.transmitted_word_equal,
        hard_word_sha256=dual.terminal_reference.hard_word_sha256,
        finite_difference_checks=dual.finite_difference_checks,
        maximum_finite_difference_error=dual.maximum_finite_difference_error,
        retained_oracle_passed=all(values(retained_checks)),
        active_edge_read_passed=Bool(active["passed"]),
    )
    (; frame_row, evaluation_rows=dual.evaluations,
       retained_checks, identities, active)
end

function write_progress(path, pass_name, phase, completed, total;
                        previous_seconds=0.0, status="running")
    payload = Dict(
        "schema_version" => PROGRESS_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
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

function run_pass(config, oracle_rows, pass_name, progress_path, phase_log_path)
    frames = (Int(config["protocol"]["frame_first"]):
              Int(config["protocol"]["frame_last"]))
    started = time_ns()
    write_progress(progress_path, pass_name, "context", 0, length(frames))
    log_phase(phase_log_path, pass_name, "context", "start", 0.0)
    composition_config = Composition.load_config(COMPOSITION_CONFIG)
    context = Composition.backend_context(composition_config, COMPOSITION_CONFIG)
    context_seconds = (time_ns() - started) / 1.0e9
    log_phase(phase_log_path, pass_name, "context", "end", context_seconds)
    write_progress(progress_path, pass_name, "frames", 0, length(frames);
                   previous_seconds=context_seconds)
    log_phase(phase_log_path, pass_name, "frames", "start", 0.0)
    rows = NamedTuple[]
    evaluations = NamedTuple[]
    identities = Dict{String,Any}[]
    for (index, frame) in enumerate(frames)
        result = compare_frame(context, config, oracle_rows, frame)
        push!(rows, result.frame_row)
        append!(evaluations, result.evaluation_rows)
        push!(identities, Dict(
            "frame" => frame,
            "identities" => result.identities,
        ))
        write_progress(progress_path, pass_name, "frames", index, length(frames))
    end
    frame_seconds = (time_ns() - started) / 1.0e9 - context_seconds
    log_phase(phase_log_path, pass_name, "frames", "end", frame_seconds)
    science = Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "reference_rung" => "assigned_frozen_product_unconstrained",
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "frame_count" => length(frames),
        "frames" => rows,
        "evaluations" => evaluations,
        "input_identities" => identities,
        "all_exact_reproduction_gates_passed" => true,
        "performance_inference_allowed" => false,
    )
    (; science, rows, evaluations,
       seconds=(time_ns() - started) / 1.0e9)
end

function csv_write(path, rows)
    isempty(rows) && return open(path, "w") do io end
    Composition.write_csv(path, rows, collect(keys(first(rows))))
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

function write_manifest(output)
    files = String[]
    for (root, _, names) in walkdir(output)
        for name in names
            path = joinpath(root, name)
            relative = relpath(path, output)
            relative == "MANIFEST.sha256" && continue
            push!(files, relative)
        end
    end
    sort!(files)
    open(joinpath(output, "MANIFEST.sha256"), "w") do io
        for relative in files
            println(io, file_sha256(joinpath(output, relative)), "  ", relative)
        end
    end
end

function failure_payload(error)
    payload = Dict{String,Any}(
        "schema_version" => "rq2-tied-scalar-edge-repro-001/failure-v1",
        "experiment_id" => EXPERIMENT_ID,
        "status" => "failed",
        "error_type" => string(typeof(error)),
        "error" => sprint(showerror, error),
        "failed_utc" => string(now(UTC)),
    )
    if error isa GateMismatch
        payload["frame"] = error.frame
        payload["update"] = error.update
        payload["trial"] = error.trial
        payload["field"] = error.field
        payload["reference"] = error.reference
        payload["treatment"] = error.treatment
    end
    payload
end

function run_gate(; config_path::AbstractString=joinpath(HERE, "config.toml"),
                  output::AbstractString)
    ispath(output) && throw(ArgumentError("refusing to overwrite result $output"))
    mkpath(output)
    progress_path = joinpath(output, "progress.toml")
    phase_log_path = joinpath(output, "phase_log.tsv")
    total_started = time_ns()
    try
        config = load_config(config_path)
        sources = source_gate(config)
        oracle_rows = retained_oracle_rows()
        primary = run_pass(config, oracle_rows, "primary",
                           progress_path, phase_log_path)
        checkpoint = joinpath(output, "primary_checkpoint")
        mkpath(checkpoint)
        write_json(joinpath(checkpoint, "science.json"), primary.science)
        csv_write(joinpath(checkpoint, "frames.csv"), primary.rows)
        csv_write(joinpath(checkpoint, "evaluations.csv"), primary.evaluations)
        write_toml(joinpath(checkpoint, "checkpoint.toml"), Dict(
            "schema_version" =>
                "rq2-tied-scalar-edge-repro-001/primary-checkpoint-v1",
            "experiment_id" => EXPERIMENT_ID,
            "status" => "primary_complete",
            "science_sha256" => scientific_sha256(primary.science),
            "frame_count" => length(primary.rows),
        ))
        write_manifest(checkpoint)
        write_progress(progress_path, "primary", "primary_checkpoint", 24, 24)
        replay = run_pass(config, oracle_rows, "replay",
                          progress_path, phase_log_path)
        primary_hash = scientific_sha256(primary.science)
        replay_hash = scientific_sha256(replay.science)
        primary_hash == replay_hash || error("deterministic replay differs")

        write_json(joinpath(output, "science.json"), primary.science)
        csv_write(joinpath(output, "frames.csv"), primary.rows)
        csv_write(joinpath(output, "evaluations.csv"), primary.evaluations)
        gate = Dict(
            "schema_version" => GATE_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "status" => "pass",
            "correctness_passed" => true,
            "deterministic_replay_passed" => true,
            "retained_oracle_passed" => true,
            "active_edge_read_passed" => true,
            "frame_count" => length(primary.rows),
            "primary_science_sha256" => primary_hash,
            "replay_science_sha256" => replay_hash,
            "source_gate_sha256" => scientific_sha256(sources),
            "performance_inference_allowed" => false,
        )
        write_toml(joinpath(output, "job_gate.toml"), gate)
        completion = Dict(
            "schema_version" => COMPLETION_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "status" => "complete_valid",
            "science_sha256" => primary_hash,
            "config_sha256" => file_sha256(config_path),
            "primary_seconds" => primary.seconds,
            "replay_seconds" => replay.seconds,
            "total_seconds" => (time_ns() - total_started) / 1.0e9,
            "completed_utc" => string(now(UTC)),
        )
        write_toml(joinpath(output, "COMPLETED.toml"), completion)
        write_progress(progress_path, "replay", "write_result", 24, 24;
                       status="complete_valid")
        write_manifest(output)
        println("complete_valid science_sha256=$primary_hash")
        return (; completion, output=abspath(output))
    catch error
        write_toml(joinpath(output, "FAILURE.toml"), failure_payload(error))
        write_progress(progress_path, "unknown", "failed", 0, 24;
                       status="failed")
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
        "usage: rq2_tied_scalar_edge_repro_001.jl run --config PATH --output DIR"))
    arguments[1] == "run" || throw(ArgumentError("only the run command is supported"))
    options = parse_options(arguments[2:end])
    haskey(options, "config") || throw(ArgumentError("--config is required"))
    haskey(options, "output") || throw(ArgumentError("--output is required"))
    run_gate(config_path=options["config"], output=options["output"])
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
