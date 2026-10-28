module PersistentEdge

using LinearAlgebra: norm
using Statistics: mean

const Core = parentmodule(@__MODULE__)

export Options, MessageState, candidate, demodulate, expected_fit,
       initialize_messages, message_sweep!, rebase_messages!, solve

"""
Controls for the experimental single-loop channel-and-belief solver.

`check_rule=:sum_product` is the finite-temperature Bethe coordinate update.
`factor_counting_weight=1` gives ordinary Bethe counting; a value in `(0,1)`
gives the uniform fractional-Bethe variable update while leaving the hard-
parity sum-product check update unchanged.
The `:normalized_min_sum` option is retained only as a measured control; it is
not reported as an exact Bethe-free-energy update.
"""
Base.@kwdef struct Options
    iterations::Int = 40
    temperature::Float64 = 1.0
    channel_llr_scale::Float64 = 1.0
    normalized_minsum_alpha::Float64 = 0.8
    message_damping::Float64 = 0.5
    message_retention::Float64 = 1.0
    factor_counting_weight::Float64 = 1.0
    belief_damping::Float64 = 1.0
    channel_extrinsic_scale::Float64 = 1.0
    channel_step_size::Float64 = 0.2
    channel_update_interval::Int = 1
    max_backtracks::Int = 16
    include_variance::Bool = true
    variance_weight::Float64 = 1.0
    channel_mode::Symbol = :gradient
    check_rule::Symbol = :sum_product
    early_exit::Bool = true
    minimum_iterations::Int = 1
end

# Frozen settings from the retained Red-1 Route 2 run. Keep this profile
# internal: the public opt-in is the decoding route, not another receiver.
const _PERSISTENT_EDGE_R2_V1_PROFILE = Options(;
    iterations=80,
    temperature=1.0,
    channel_llr_scale=1.0,
    normalized_minsum_alpha=0.8,
    message_damping=1.0,
    message_retention=0.9,
    factor_counting_weight=1.0,
    belief_damping=1.0,
    channel_extrinsic_scale=0.5,
    channel_step_size=0.1,
    channel_update_interval=2,
    max_backtracks=16,
    include_variance=true,
    variance_weight=1.0,
    channel_mode=:gradient,
    check_rule=:normalized_min_sum,
    early_exit=true,
    minimum_iterations=1,
)

_r2_v1_trace_parameters(options::Options) = (;
    iterations=options.iterations,
    check_rule=options.check_rule,
    normalized_minsum_alpha=options.normalized_minsum_alpha,
    message_damping=options.message_damping,
    message_retention=options.message_retention,
    factor_counting_weight=options.factor_counting_weight,
    belief_damping=options.belief_damping,
    channel_extrinsic_scale=options.channel_extrinsic_scale,
    channel_step_size=options.channel_step_size,
    channel_update_interval=options.channel_update_interval,
    temperature=options.temperature,
    channel_llr_scale=options.channel_llr_scale,
    include_variance=options.include_variance,
    variance_weight=options.variance_weight,
    channel_mode=options.channel_mode,
    max_backtracks=options.max_backtracks,
    early_exit=options.early_exit,
    minimum_iterations=options.minimum_iterations,
)

const _EdgeView = SubArray{
    Float64,1,Vector{Float64},Tuple{UnitRange{Int}},true}

struct _EdgeRows <: AbstractVector{_EdgeView}
    data::Vector{Float64}
    offsets::Vector{Int}
end

Base.IndexStyle(::Type{_EdgeRows}) = IndexLinear()
Base.size(rows::_EdgeRows) = (length(rows.offsets) - 1,)

@inline function Base.getindex(rows::_EdgeRows, index::Int)
    @boundscheck checkbounds(rows, index)
    first_edge = rows.offsets[index]
    last_edge = rows.offsets[index + 1] - 1
    @view rows.data[first_edge:last_edge]
end

Base.copy(rows::_EdgeRows) = [rows[index] for index in eachindex(rows)]

"""Persistent directed-edge state for one codeword."""
mutable struct MessageState
    lch::Vector{Float64}
    posterior::Vector{Float64}
    bits::BitVector
    q::_EdgeRows
    r::_EdgeRows
    check_buffer::Vector{Float64}
    syndrome::Int
    sweeps::Int
    rebases::Int
end

mutable struct _Workspace{
        C<:AbstractArray{ComplexF64,3},
        R<:AbstractArray{Float64,3}}
    llrs::Vector{Float64}
    assigned::BitVector
    initial_applied::Vector{Float64}
    applied::Vector{Float64}
    llr_difference::Vector{Float64}
    channel_feedback::Vector{Float64}
    target_x::Vector{Float64}
    x::Vector{Float64}
    symbols::Vector{ComplexF64}
    sufficient::Vector{ComplexF64}
    gradient_C::C
    curvature_C::R
    direction_C::C
    trial_C_a::C
    trial_C_b::C
end

function _Workspace(problem, state)
    nbits = problem.nbits
    symbol_count = maximum(
        local_problem -> length(local_problem.fixed_symbols),
        problem.locals; init=0)
    _Workspace(
        zeros(Float64, nbits),
        falses(nbits),
        Vector{Float64}(undef, nbits),
        Vector{Float64}(undef, nbits),
        Vector{Float64}(undef, nbits),
        Vector{Float64}(undef, nbits),
        Vector{Float64}(undef, nbits),
        Vector{Float64}(undef, nbits),
        Vector{ComplexF64}(undef, symbol_count),
        Vector{ComplexF64}(undef, symbol_count),
        similar(state.C),
        similar(state.C, Float64),
        similar(state.C),
        similar(state.C),
        similar(state.C),
    )
end

function _validate_options(options::Options)
    options.iterations > 0 || throw(ArgumentError("iterations must be positive"))
    isfinite(options.temperature) && options.temperature > 0 ||
        throw(ArgumentError("temperature must be finite and positive"))
    isfinite(options.channel_llr_scale) && options.channel_llr_scale > 0 ||
        throw(ArgumentError("channel_llr_scale must be finite and positive"))
    isfinite(options.normalized_minsum_alpha) &&
        options.normalized_minsum_alpha > 0 || throw(ArgumentError(
        "normalized_minsum_alpha must be finite and positive"))
    isfinite(options.message_damping) && 0 < options.message_damping <= 1 ||
        throw(ArgumentError("message_damping must lie in (0,1]"))
    isfinite(options.message_retention) && 0 < options.message_retention <= 1 ||
        throw(ArgumentError("message_retention must lie in (0,1]"))
    isfinite(options.factor_counting_weight) &&
        0 < options.factor_counting_weight <= 1 ||
        throw(ArgumentError("factor_counting_weight must lie in (0,1]"))
    isfinite(options.belief_damping) && 0 < options.belief_damping <= 1 ||
        throw(ArgumentError("belief_damping must lie in (0,1]"))
    isfinite(options.channel_extrinsic_scale) &&
        0 <= options.channel_extrinsic_scale <= 1 ||
        throw(ArgumentError("channel_extrinsic_scale must lie in [0,1]"))
    isfinite(options.channel_step_size) && options.channel_step_size > 0 ||
        throw(ArgumentError("channel_step_size must be finite and positive"))
    options.channel_update_interval > 0 ||
        throw(ArgumentError("channel_update_interval must be positive"))
    0 <= options.max_backtracks <= 32 ||
        throw(ArgumentError("max_backtracks must lie in 0:32"))
    isfinite(options.variance_weight) && options.variance_weight >= 0 ||
        throw(ArgumentError("variance_weight must be finite and nonnegative"))
    options.channel_mode in (:gradient, :frozen_response, :frozen_likelihood) ||
        throw(ArgumentError(
            "channel_mode must be :gradient, :frozen_response, or :frozen_likelihood"))
    options.check_rule in (:sum_product, :normalized_min_sum) ||
        throw(ArgumentError("check_rule must be :sum_product or :normalized_min_sum"))
    1 <= options.minimum_iterations <= options.iterations ||
        throw(ArgumentError("minimum_iterations must lie in 1:iterations"))
    options
end

function _formulation_metadata(options::Options)
    sum_product = options.check_rule === :sum_product
    ordinary_counting = options.factor_counting_weight == 1
    full_channel_belief = options.channel_extrinsic_scale == 1
    persistent_duals = options.message_retention == 1
    calibrated_variance = options.include_variance &&
        options.variance_weight == 1
    default_temperature = options.temperature == 1
    gradient_channel = options.channel_mode === :gradient
    unified_free_energy_consistent =
        sum_product && full_channel_belief && persistent_duals &&
        calibrated_variance && default_temperature && gradient_channel

    formulation = if !sum_product
        :hybrid_mean_field_persistent_normalized_min_sum_control
    elseif !gradient_channel
        :hybrid_bethe_mean_field_frozen_channel_control
    elseif !default_temperature || !calibrated_variance
        :hybrid_bethe_mean_field_calibrated_likelihood_control
    elseif !persistent_duals
        :hybrid_bethe_mean_field_leaky_message_control
    elseif !full_channel_belief
        :hybrid_bethe_mean_field_channel_tempering_control
    elseif ordinary_counting
        :hybrid_bethe_mean_field_kkt_system
    else
        :hybrid_uniform_fractional_bethe_mean_field_kkt_system
    end
    check_rule_interpretation = if !sum_product
        :normalized_min_sum_control
    elseif ordinary_counting
        :ordinary_bethe_dual_coordinate_update
    else
        :uniform_fractional_bethe_dual_coordinate_update
    end
    message_passing = if !sum_product
        :persistent_normalized_min_sum
    elseif ordinary_counting
        :persistent_sum_product
    else
        :persistent_uniform_fractional_sum_product
    end

    bethe_counting = !sum_product ? :not_applicable_normalized_min_sum_control :
        ordinary_counting ? :ordinary : :uniform_fractional
    (; formulation, check_rule_interpretation, message_passing, bethe_counting,
       channel_belief_coupling=full_channel_belief ? :full : :tempered_control,
       message_memory=persistent_duals ? :persistent : :leaky_control,
       channel_mode=options.channel_mode,
       likelihood_calibration=options.channel_llr_scale,
       variance_calibration=options.variance_weight,
       unified_free_energy_consistent)
end

function _channel_feedback!(output, messages::MessageState,
                            extrinsic_scale::Real)
    isfinite(extrinsic_scale) && 0 <= extrinsic_scale <= 1 ||
        throw(ArgumentError("channel extrinsic scale must lie in [0,1]"))
    length(output) == length(messages.lch) ||
        throw(DimensionMismatch("channel-feedback workspace has the wrong length"))
    scale = Float64(extrinsic_scale)
    @. output = clamp(
        messages.lch + scale * (messages.posterior - messages.lch),
        -Core._LLR_CLIP, Core._LLR_CLIP)
    output
end

function _channel_feedback(messages::MessageState, extrinsic_scale::Real)
    _channel_feedback!(similar(messages.lch), messages, extrinsic_scale)
end

@inline _fixed_bipolar(problem, bit::Int) =
    problem.fixed_bits[bit] ? -1.0 : 1.0

function _applied_likelihoods!(applied, problem, llrs;
                               temperature::Real=1.0,
                               channel_llr_scale::Real=1.0)
    length(llrs) == problem.code.n ||
        throw(DimensionMismatch("channel likelihood length differs from the code"))
    length(applied) == length(llrs) || throw(DimensionMismatch(
        "applied-likelihood workspace has the wrong length"))
    isfinite(temperature) && temperature > 0 ||
        throw(ArgumentError("temperature must be finite and positive"))
    isfinite(channel_llr_scale) && channel_llr_scale > 0 ||
        throw(ArgumentError("channel LLR scale must be finite and positive"))
    # In the finite-temperature Bethe equations the channel energy, hence its
    # LLR, is divided by T.  The posterior-to-mean map below remains tanh(L/2);
    # dividing there as well would apply temperature twice.
    scale = Float64(channel_llr_scale)
    temperature_value = Float64(temperature)
    @. applied = clamp(
        scale * Float64(llrs) / temperature_value,
        -Core._LLR_CLIP, Core._LLR_CLIP)
    all(isfinite, applied) || throw(ArgumentError("channel likelihoods must be finite"))
    Core._apply_inner_clamps!(problem.m, problem.code, applied)
    applied
end

function _applied_likelihoods(problem, llrs; temperature::Real=1.0,
                              channel_llr_scale::Real=1.0)
    applied = Vector{Float64}(undef, length(llrs))
    _applied_likelihoods!(applied, problem, llrs;
        temperature, channel_llr_scale)
end

# Keep the established channel-likelihood implementation operation-for-
# operation identical at the default uncertainty weight.  The local path is
# used only by the opt-in calibration control, where `variance_weight` scales
# the soft-interference contribution to each conditional variance.
function _channel_llrs!(llrs, assigned, symbols, sufficient,
                        problem, state; variance_weight::Real=1.0)
    isfinite(variance_weight) && variance_weight >= 0 ||
        throw(ArgumentError("variance weight must be finite and nonnegative"))
    symbol_count = length(first(problem.locals).fixed_symbols)
    length(llrs) == problem.nbits && length(assigned) == problem.nbits ||
        throw(DimensionMismatch("channel-likelihood workspace has the wrong length"))
    length(symbols) >= symbol_count && length(sufficient) >= symbol_count ||
        throw(DimensionMismatch("QPSK-symbol workspace has the wrong length"))
    fill!(llrs, 0.0)
    fill!(assigned, false)
    gamma = Float64(variance_weight)
    for (symbol, local_problem) in enumerate(problem.locals)
        local_symbols = @view symbols[1:length(local_problem.fixed_symbols)]
        local_sufficient = @view sufficient[1:length(local_problem.fixed_symbols)]
        Core._joint_cz_symbols!(local_symbols, local_problem, state.x)
        fill!(local_sufficient, zero(eltype(local_sufficient)))
        @inbounds for carrier in local_problem.active
            for target in axes(state.C, 1)
                bit_symbol = local_problem.neighbor_idx[target, carrier]
                bit_symbol == 0 && continue
                residual = problem.y[carrier, symbol]
                variance = problem.variances[symbol]
                for response_index in axes(state.C, 1)
                    neighbor = local_problem.neighbor_idx[response_index, carrier]
                    (neighbor == 0 || response_index == target) && continue
                    response = state.C[response_index, carrier, symbol]
                    residual -= response * local_symbols[neighbor]
                    variance += gamma * abs2(response) *
                        max(0.0, 1 - abs2(local_symbols[neighbor]))
                end
                local_sufficient[bit_symbol] +=
                    conj(state.C[target, carrier, symbol]) * residual / variance
            end
        end
        @inbounds for (tone, carrier) in enumerate(local_problem.data_idx),
                      coordinate in 1:2
            bit = local_problem.bit_indices[coordinate, tone]
            bit == 0 && continue
            assigned[bit] && throw(ArgumentError("duplicate coded-bit mapping"))
            llrs[bit] = 2sqrt(2.0) * (coordinate == 1 ?
                real(local_sufficient[carrier]) : imag(local_sufficient[carrier]))
            assigned[bit] = true
        end
    end
    all(assigned) || throw(ArgumentError("incomplete coded-bit mapping"))
    all(isfinite, llrs) || throw(ArgumentError("non-finite channel likelihood"))
    llrs
end


function _channel_llrs(problem, state; variance_weight::Real=1.0)
    symbol_count = maximum(
        local_problem -> length(local_problem.fixed_symbols),
        problem.locals; init=0)
    _channel_llrs!(
        zeros(Float64, problem.nbits), falses(problem.nbits),
        Vector{ComplexF64}(undef, symbol_count),
        Vector{ComplexF64}(undef, symbol_count),
        problem, state; variance_weight)
end

"""
    initialize_messages(problem, llrs)

Create one persistent set of variable-to-check (`q`) and check-to-variable
(`r`) dual messages. This does not invoke the receiver decoder entry point.
"""
function initialize_messages(problem, llrs; temperature::Real=1.0,
                             channel_llr_scale::Real=1.0)
    applied = _applied_likelihoods(problem, llrs;
        temperature, channel_llr_scale)
    _initialize_messages_applied(problem, applied)
end

function _initialize_messages_applied(problem, applied)
    length(applied) == problem.code.n || throw(DimensionMismatch(
        "applied channel likelihood length differs from the code"))
    all(isfinite, applied) ||
        throw(ArgumentError("applied channel likelihoods must be finite"))
    lch = copy(applied)
    code = problem.code
    offsets = Vector{Int}(undef, length(code.check_vars) + 1)
    offsets[1] = 1
    @inbounds for check in eachindex(code.check_vars)
        offsets[check + 1] = offsets[check] + length(code.check_vars[check])
    end
    q = _EdgeRows(Vector{Float64}(undef, offsets[end] - 1), offsets)
    r = _EdgeRows(zeros(Float64, offsets[end] - 1), offsets)
    @inbounds for check in eachindex(code.check_vars)
        vars = code.check_vars[check]
        for edge in eachindex(vars)
            bit = vars[edge]
            q[check][edge] = problem.fixed[bit] ?
                _fixed_bipolar(problem, bit) * Core._LLR_CLIP : lch[bit]
        end
    end
    posterior = copy(lch)
    bits = BitVector(posterior .< 0)
    @inbounds for bit in eachindex(bits)
        if problem.fixed[bit]
            bits[bit] = problem.fixed_bits[bit]
            posterior[bit] = _fixed_bipolar(problem, bit) * Core._LLR_CLIP
        end
    end
    max_degree = maximum(length, code.check_vars; init=0)
    syndrome = Core._syndrome_weight(code, bits)
    MessageState(lch, posterior, bits, q, r, zeros(Float64, max_degree),
                 syndrome, 0, 0)
end

"""
    rebase_messages!(messages, problem, llrs)

Replace the channel evidence while retaining every check-to-variable message.
This is the key distinction from calling a fresh decoder after each channel
solve.
"""
function rebase_messages!(messages::MessageState, problem, llrs;
                          temperature::Real=1.0,
                          channel_llr_scale::Real=1.0,
                          retention::Real=1.0,
                          factor_counting_weight::Real=1.0)
    applied = _applied_likelihoods(problem, llrs;
        temperature, channel_llr_scale)
    _rebase_applied_messages!(messages, problem, applied;
        retention, factor_counting_weight)
end

function _rebase_applied_messages!(messages::MessageState, problem, applied;
                                   retention::Real=1.0,
                                   factor_counting_weight::Real=1.0)
    isfinite(retention) && 0 < retention <= 1 ||
        throw(ArgumentError("message retention must lie in (0,1]"))
    isfinite(factor_counting_weight) && 0 < factor_counting_weight <= 1 ||
        throw(ArgumentError("factor counting weight must lie in (0,1]"))
    length(messages.lch) == length(applied) ||
        throw(DimensionMismatch("persistent message state has the wrong code length"))
    all(isfinite, applied) ||
        throw(ArgumentError("applied channel likelihoods must be finite"))
    copyto!(messages.lch, applied)
    if retention != 1
        @inbounds for row in messages.r, edge in eachindex(row)
            row[edge] *= retention
        end
    end
    code = problem.code
    @inbounds for bit in eachindex(messages.lch)
        if problem.fixed[bit]
            total = _fixed_bipolar(problem, bit) * Core._LLR_CLIP
            messages.posterior[bit] = total
            messages.bits[bit] = problem.fixed_bits[bit]
            for (check, edge) in code.var_edges[bit]
                messages.q[check][edge] = total
            end
        else
            total = messages.lch[bit]
            if factor_counting_weight == 1
                # Keep the ordinary-Bethe path operation-for-operation
                # identical to the original persistent sum-product update.
                for (check, edge) in code.var_edges[bit]
                    total += messages.r[check][edge]
                end
            else
                for (check, edge) in code.var_edges[bit]
                    total += factor_counting_weight * messages.r[check][edge]
                end
            end
            messages.posterior[bit] = total
            messages.bits[bit] = total < 0
            for (check, edge) in code.var_edges[bit]
                # Uniform fractional BP subtracts the same-edge multiplier
                # without rho: q_i->c = B_i - r_c->i.
                messages.q[check][edge] = total - messages.r[check][edge]
            end
        end
    end
    messages.syndrome = Core._syndrome_weight(code, messages.bits)
    messages.rebases += 1
    messages
end

function _normalized_minsum_check!(out, incoming, alpha::Real)
    length(out) == length(incoming) ||
        throw(DimensionMismatch("check-message buffers must have equal length"))
    isfinite(alpha) && alpha > 0 || throw(ArgumentError(
        "normalized min-sum alpha must be finite and positive"))
    edge_count = length(incoming)
    edge_count == 0 && return out
    if edge_count == 1
        out[1] = Core._LLR_CLIP
        return out
    end

    sign_product = 1.0
    minimum_magnitude = Inf
    second_minimum_magnitude = Inf
    minimum_index = 0
    @inbounds for edge in 1:edge_count
        value = incoming[edge]
        sign_product *= ifelse(value < 0.0, -1.0, 1.0)
        magnitude = abs(value)
        if magnitude < minimum_magnitude
            second_minimum_magnitude = minimum_magnitude
            minimum_magnitude = magnitude
            minimum_index = edge
        elseif magnitude < second_minimum_magnitude
            second_minimum_magnitude = magnitude
        end
    end
    normalization = Float64(alpha)
    @inbounds for edge in 1:edge_count
        sign_without_recipient = sign_product *
            ifelse(incoming[edge] < 0.0, -1.0, 1.0)
        magnitude = edge == minimum_index ?
            second_minimum_magnitude : minimum_magnitude
        out[edge] = normalization * sign_without_recipient * magnitude
    end
    out
end

function _check_update!(out, incoming, check_rule::Symbol,
                        normalized_minsum_alpha::Real)
    if check_rule === :sum_product
        Core._bp_check_sum_product!(out, incoming)
    elseif check_rule === :normalized_min_sum
        _normalized_minsum_check!(out, incoming, normalized_minsum_alpha)
    else
        throw(ArgumentError("unsupported check rule $check_rule"))
    end
end

"""
    message_sweep!(messages, problem; check_rule=:sum_product, damping=0.5)

Perform exactly one damped, persistent check/variable sweep. The returned
diagnostics describe this sweep; no terminal decoder call or hidden extra sweep
is made.
"""
function message_sweep!(messages::MessageState, problem;
                        check_rule::Symbol=:sum_product, damping::Real=0.5,
                        normalized_minsum_alpha::Real=0.8,
                        factor_counting_weight::Real=1.0)
    check_rule in (:sum_product, :normalized_min_sum) ||
        throw(ArgumentError("unsupported check rule $check_rule"))
    isfinite(damping) && 0 < damping <= 1 ||
        throw(ArgumentError("damping must lie in (0,1]"))
    isfinite(normalized_minsum_alpha) && normalized_minsum_alpha > 0 ||
        throw(ArgumentError(
            "normalized_minsum_alpha must be finite and positive"))
    isfinite(factor_counting_weight) && 0 < factor_counting_weight <= 1 ||
        throw(ArgumentError("factor counting weight must lie in (0,1]"))
    code = problem.code
    length(messages.q) == length(code.check_vars) == length(messages.r) ||
        throw(DimensionMismatch("persistent edge state differs from the Tanner graph"))
    maximum(length, code.check_vars; init=0) <= length(messages.check_buffer) ||
        throw(DimensionMismatch("check-message workspace is too short"))

    max_message_change = 0.0
    @inbounds for check in eachindex(code.check_vars)
        q = messages.q[check]
        r = messages.r[check]
        trial = @view messages.check_buffer[1:length(q)]
        _check_update!(trial, q, check_rule, normalized_minsum_alpha)
        for edge in eachindex(r)
            old = r[edge]
            new = (1 - damping) * old + damping * trial[edge]
            r[edge] = clamp(new, -Core._LLR_CLIP, Core._LLR_CLIP)
            max_message_change = max(max_message_change, abs(r[edge] - old))
        end
    end

    posterior_square_change = 0.0
    edge_square_change = 0.0
    max_edge_change = 0.0
    edge_count = 0
    hard_flips = 0
    @inbounds for bit in eachindex(messages.lch)
        old_posterior = messages.posterior[bit]
        old_bit = messages.bits[bit]
        if problem.fixed[bit]
            total = _fixed_bipolar(problem, bit) * Core._LLR_CLIP
            messages.posterior[bit] = total
            messages.bits[bit] = problem.fixed_bits[bit]
            for (check, edge) in code.var_edges[bit]
                difference = total - messages.q[check][edge]
                messages.q[check][edge] = total
                edge_square_change += abs2(difference)
                max_edge_change = max(max_edge_change, abs(difference))
                edge_count += 1
            end
        else
            total = messages.lch[bit]
            if factor_counting_weight == 1
                for (check, edge) in code.var_edges[bit]
                    total += messages.r[check][edge]
                end
            else
                for (check, edge) in code.var_edges[bit]
                    total += factor_counting_weight * messages.r[check][edge]
                end
            end
            messages.posterior[bit] = total
            messages.bits[bit] = total < 0
            for (check, edge) in code.var_edges[bit]
                updated = total - messages.r[check][edge]
                difference = updated - messages.q[check][edge]
                messages.q[check][edge] = updated
                edge_square_change += abs2(difference)
                max_edge_change = max(max_edge_change, abs(difference))
                edge_count += 1
            end
        end
        posterior_square_change += abs2(messages.posterior[bit] - old_posterior)
        hard_flips += messages.bits[bit] != old_bit
    end
    messages.syndrome = Core._syndrome_weight(code, messages.bits)
    messages.sweeps += 1
    (; syndrome=messages.syndrome, hard_flips,
       posterior_rms_change=sqrt(posterior_square_change / length(messages.lch)),
       max_message_change,
       edge_fixed_point_rms=edge_count == 0 ? 0.0 :
           sqrt(edge_square_change / edge_count),
       edge_fixed_point_max=max_edge_change)
end

"""
    expected_fit(problem, state; include_variance=true, gradient=true)

Evaluate the channel-dependent part of the proposed joint objective. The
received-signal term uses independent QPSK symbol beliefs:

`E|y-Hs|^2 = |y-H*E[s]|^2 + sum |H_k|^2 Var(s_k)`.

Cross-symbol belief covariance is not available from the local Bethe beliefs
and is deliberately omitted. The code entropy/consistency term is handled by
the message sweep and is not folded into this reported scalar.
"""
function expected_fit(problem, state; include_variance::Bool=true,
                      channel_llr_scale::Real=1.0,
                      variance_weight::Real=1.0,
                      gradient::Bool=true,
                      workspace=nothing)
    size(state.C) == size(problem.C0) ||
        throw(DimensionMismatch("channel-response shape differs"))
    length(state.x) == problem.nbits ||
        throw(DimensionMismatch("belief-mean length differs"))
    all(isfinite, state.C) && all(isfinite, state.x) ||
        throw(ArgumentError("expected-fit inputs must be finite"))
    isfinite(channel_llr_scale) && channel_llr_scale > 0 ||
        throw(ArgumentError("channel LLR scale must be finite and positive"))
    isfinite(variance_weight) && variance_weight >= 0 ||
        throw(ArgumentError("variance weight must be finite and nonnegative"))

    workspace === nothing || workspace isa _Workspace ||
        throw(ArgumentError("unexpected persistent-edge workspace"))
    if workspace !== nothing
        size(workspace.gradient_C) == size(state.C) &&
            size(workspace.curvature_C) == size(state.C) ||
            throw(DimensionMismatch("expected-fit workspace shape differs"))
    end
    gC = if !gradient
        nothing
    elseif workspace === nothing
        zeros(ComplexF64, size(state.C))
    else
        fill!(workspace.gradient_C, zero(eltype(workspace.gradient_C)))
    end
    hC = if !gradient
        nothing
    elseif workspace === nothing
        zeros(Float64, size(state.C))
    else
        fill!(workspace.curvature_C, zero(eltype(workspace.curvature_C)))
    end
    physical = 0.0
    uncertainty = 0.0
    anchor = 0.0
    smoothness = 0.0
    m = problem.m
    response_count = size(state.C, 1)
    response_plane = response_count * size(state.C, 2)
    kappa = Float64(channel_llr_scale)
    gamma = include_variance ? Float64(variance_weight) : 0.0
    default_calibration = kappa == 1 && (gamma == 0 || gamma == 1)

    for (symbol, local_problem) in enumerate(problem.locals)
        symbols = if workspace === nothing
            Core._joint_cz_symbols(local_problem, state.x)
        else
            local_symbols = @view workspace.symbols[
                1:length(local_problem.fixed_symbols)]
            Core._joint_cz_symbols!(local_symbols, local_problem, state.x)
        end
        scale = 1 / (problem.nbits * problem.variances[symbol])
        data_scale = kappa * scale
        smooth_scale = scale * m.channel_smoothness_weight
        symbol_offset = (symbol - 1) * response_plane
        @inbounds for carrier in local_problem.active
            column_offset = symbol_offset + (carrier - 1) * response_count
            neighbor_offset = (carrier - 1) * response_count
            prediction = zero(ComplexF64)
            for response_index in axes(state.C, 1)
                neighbor = local_problem.neighbor_idx[neighbor_offset + response_index]
                neighbor == 0 ||
                    (prediction += state.C[column_offset + response_index] * symbols[neighbor])
            end
            residual = prediction - problem.y[carrier, symbol]
            physical += data_scale * abs2(residual)
            for response_index in axes(state.C, 1)
                neighbor = local_problem.neighbor_idx[neighbor_offset + response_index]
                neighbor == 0 && continue
                flat_index = column_offset + response_index
                response = state.C[flat_index]
                symbol_mean = symbols[neighbor]
                delta = response - problem.C0[flat_index]
                raw_symbol_variance = include_variance ?
                    max(0.0, 1 - abs2(symbol_mean)) : 0.0
                symbol_variance = gamma * raw_symbol_variance
                uncertainty += data_scale * abs2(response) * symbol_variance
                anchor += scale * m.channel_anchor_weight * abs2(delta)
                if gradient
                    if default_calibration
                        # Preserve the established path's floating-point
                        # operation order at kappa=gamma=1.
                        gC[flat_index] += scale *
                            (residual * conj(symbol_mean) +
                             (m.channel_anchor_weight + symbol_variance) * response -
                             m.channel_anchor_weight * problem.C0[flat_index])
                        hC[flat_index] += scale *
                            (abs2(symbol_mean) + m.channel_anchor_weight +
                             symbol_variance)
                    else
                        gC[flat_index] += data_scale *
                            (residual * conj(symbol_mean) +
                             symbol_variance * response) +
                            scale * m.channel_anchor_weight *
                            (response - problem.C0[flat_index])
                        hC[flat_index] += data_scale *
                            (abs2(symbol_mean) + symbol_variance) +
                            scale * m.channel_anchor_weight
                    end
                end
            end
        end

        @inbounds for (left_slot, right_slot) in local_problem.smooth_edges
            left = local_problem.active[left_slot]
            right = local_problem.active[right_slot]
            left_offset = (left - 1) * response_count
            right_offset = (right - 1) * response_count
            for response_index in axes(state.C, 1)
                local_problem.neighbor_idx[left_offset + response_index] > 0 &&
                    local_problem.neighbor_idx[right_offset + response_index] > 0 || continue
                left_index = symbol_offset + left_offset + response_index
                right_index = symbol_offset + right_offset + response_index
                delta = (state.C[right_index] - problem.C0[right_index]) -
                        (state.C[left_index] - problem.C0[left_index])
                smoothness += smooth_scale * abs2(delta)
                if gradient
                    gC[right_index] += smooth_scale * delta
                    gC[left_index] -= smooth_scale * delta
                    hC[left_index] += smooth_scale
                    hC[right_index] += smooth_scale
                end
            end
        end
    end

    terms = (; physical, uncertainty, anchor, smoothness)
    (; loss=sum(values(terms)), terms, gradient_C=gC, curvature_C=hC,
       channel_llr_scale=kappa, variance_weight=gamma,
       variance_model=include_variance ? :independent_qpsk_symbols : :disabled)
end

_trial_channel_buffer(workspace::_Workspace, current) =
    current === workspace.trial_C_a ? workspace.trial_C_b : workspace.trial_C_a

function _channel_step(state, problem, options::Options; workspace=nothing)
    current = expected_fit(problem, state;
        include_variance=options.include_variance,
        channel_llr_scale=options.channel_llr_scale,
        variance_weight=options.variance_weight, gradient=true,
        workspace)
    direction = workspace === nothing ? similar(state.C) : workspace.direction_C
    @. direction = -current.gradient_C / max(current.curvature_C, eps(Float64))
    directional_derivative = 2real(sum(conj(current.gradient_C) .* direction))
    if !isfinite(directional_derivative) || directional_derivative >= 0 ||
            iszero(norm(direction))
        return (; state, before=current, after=current, update_attempted=true,
                  accepted=false,
                  step_size=0.0, backtracks=0,
                  directional_derivative)
    end
    for backtrack in 0:options.max_backtracks
        step_size = options.channel_step_size * 0.5^backtrack
        trial_C = if workspace === nothing
            state.C .+ step_size .* direction
        else
            output = _trial_channel_buffer(workspace, state.C)
            @. output = state.C + step_size * direction
            output
        end
        trial = (; C=trial_C, x=state.x)
        evaluated = expected_fit(problem, trial;
            include_variance=options.include_variance,
            channel_llr_scale=options.channel_llr_scale,
            variance_weight=options.variance_weight, gradient=false,
            workspace)
        if isfinite(evaluated.loss) && evaluated.loss < current.loss
            return (; state=(; C=trial.C, x=state.x), before=current,
                      update_attempted=true,
                      after=evaluated, accepted=true, step_size, backtracks=backtrack,
                      directional_derivative)
        end
    end
    (; state, before=current, after=current, update_attempted=true,
       accepted=false,
       step_size=0.0, backtracks=options.max_backtracks + 1,
       directional_derivative)
end

function _skipped_channel_step(state, problem, options::Options;
                               workspace=nothing)
    current = expected_fit(problem, state;
        include_variance=options.include_variance,
        channel_llr_scale=options.channel_llr_scale,
        variance_weight=options.variance_weight, gradient=false,
        workspace)
    (; state, before=current, after=current, update_attempted=false,
       accepted=false, step_size=0.0, backtracks=0,
       directional_derivative=0.0)
end

_schedule_label(interval::Int) = interval == 1 ?
    :one_message_sweep_then_one_channel_gradient_step :
    Symbol("one_message_sweep_per_iteration_channel_gradient_every_",
           interval, "_iterations")

function _schedule_label(interval::Int, channel_mode::Symbol)
    channel_mode === :gradient && return _schedule_label(interval)
    channel_mode === :frozen_response &&
        return :message_sweeps_with_frozen_response_and_refreshed_likelihoods
    channel_mode === :frozen_likelihood &&
        return :message_sweeps_with_frozen_response_and_frozen_likelihoods
    throw(ArgumentError("unsupported channel mode $channel_mode"))
end

function _crc_gate(problem, posterior, payload_nbits)
    payload_nbits === nothing && return nothing
    Core._frame_crc_valid_from_metrics(
        problem.m, problem.code, -posterior, Int(payload_nbits))
end

"""
    solve(problem, initial; options=Options(), payload_nbits=nothing)

Run one persistent-message sweep per iteration and attempt one analytical,
line-searched channel gradient step at the configured interval. No decoder
entry point, decoder VJP, terminal message sweep, or polynomial parity/binary
gradient is used.
"""
function solve(problem, initial; options::Options=Options(), payload_nbits=nothing)
    _validate_options(options)
    problem.m.mode === :joint_cz ||
        throw(ArgumentError("the experimental solver currently supports joint CZ only"))
    state = (; C=copy(initial.C), x=clamp.(copy(initial.x), -1.0, 1.0))
    @inbounds for bit in eachindex(problem.fixed)
        problem.fixed[bit] && (state.x[bit] = _fixed_bipolar(problem, bit))
    end

    workspace = _Workspace(problem, state)
    _channel_llrs!(
        workspace.llrs, workspace.assigned, workspace.symbols,
        workspace.sufficient, problem, state;
        variance_weight=options.variance_weight)
    initial_applied = _applied_likelihoods!(
        workspace.initial_applied, problem, workspace.llrs;
        temperature=options.temperature,
        channel_llr_scale=options.channel_llr_scale)
    messages = _initialize_messages_applied(problem, initial_applied)
    initial_state = (; C=copy(state.C), x=copy(state.x))
    initial_objective = expected_fit(problem, state;
        include_variance=options.include_variance,
        channel_llr_scale=options.channel_llr_scale,
        variance_weight=options.variance_weight, gradient=false,
        workspace)

    syndrome_history = sizehint!(Int[], options.iterations)
    known_bits_history = sizehint!(Bool[], options.iterations)
    crc_history = sizehint!(Union{Nothing,Bool}[], options.iterations)
    objective_before_channel = sizehint!(Float64[], options.iterations)
    objective_after_channel = sizehint!(Float64[], options.iterations)
    physical_history = sizehint!(Float64[], options.iterations)
    uncertainty_history = sizehint!(Float64[], options.iterations)
    channel_step_sizes = sizehint!(Float64[], options.iterations)
    channel_backtracks = sizehint!(Int[], options.iterations)
    channel_directional_derivatives = sizehint!(Float64[], options.iterations)
    channel_likelihood_refresh_history = sizehint!(Bool[], options.iterations)
    channel_update_attempted_history = sizehint!(Bool[], options.iterations)
    channel_steps_accepted = sizehint!(Bool[], options.iterations)
    llr_rms_changes = sizehint!(Float64[], options.iterations)
    posterior_rms_changes = sizehint!(Float64[], options.iterations)
    max_message_changes = sizehint!(Float64[], options.iterations)
    edge_fixed_point_rms_history = sizehint!(Float64[], options.iterations)
    edge_fixed_point_max_history = sizehint!(Float64[], options.iterations)
    hard_flips = sizehint!(Int[], options.iterations)

    status = :iteration_limit
    final_crc = nothing
    for iteration in 1:options.iterations
        refresh_likelihood = options.channel_mode !== :frozen_likelihood
        applied = if refresh_likelihood
            _channel_llrs!(
                workspace.llrs, workspace.assigned, workspace.symbols,
                workspace.sufficient, problem, state;
                variance_weight=options.variance_weight)
            _applied_likelihoods!(workspace.applied, problem, workspace.llrs;
                temperature=options.temperature,
                channel_llr_scale=options.channel_llr_scale)
        else
            initial_applied
        end
        push!(channel_likelihood_refresh_history, refresh_likelihood)
        @. workspace.llr_difference = applied - messages.lch
        push!(llr_rms_changes,
            sqrt(mean(abs2, workspace.llr_difference)))
        _rebase_applied_messages!(messages, problem, applied;
            retention=options.message_retention,
            factor_counting_weight=options.factor_counting_weight)
        sweep = message_sweep!(messages, problem;
            check_rule=options.check_rule, damping=options.message_damping,
            normalized_minsum_alpha=options.normalized_minsum_alpha,
            factor_counting_weight=options.factor_counting_weight)

        # Temper only the beliefs shown to the channel block. The persistent
        # edge state, hard decisions, syndrome, CRC, and returned posterior
        # continue to use the full decoder posterior.
        channel_feedback = _channel_feedback!(
            workspace.channel_feedback, messages,
            options.channel_extrinsic_scale)
        target_x = workspace.target_x
        @. target_x = tanh(channel_feedback / 2)
        x = workspace.x
        @. x = state.x + options.belief_damping * (target_x - state.x)
        @inbounds for bit in eachindex(problem.fixed)
            problem.fixed[bit] && (x[bit] = _fixed_bipolar(problem, bit))
        end
        state = (; C=state.C, x)
        update_channel = options.channel_mode === :gradient &&
            iteration % options.channel_update_interval == 0
        channel = update_channel ?
            _channel_step(state, problem, options; workspace) :
            _skipped_channel_step(state, problem, options; workspace)
        state = channel.state

        known_bits_valid = all(messages.bits[problem.fixed] .==
                               problem.fixed_bits[problem.fixed])
        final_crc = _crc_gate(problem, messages.posterior, payload_nbits)
        gate_valid = messages.syndrome == 0 && known_bits_valid && final_crc !== false

        push!(syndrome_history, messages.syndrome)
        push!(known_bits_history, known_bits_valid)
        push!(crc_history, final_crc)
        push!(objective_before_channel, channel.before.loss)
        push!(objective_after_channel, channel.after.loss)
        push!(physical_history, channel.after.terms.physical)
        push!(uncertainty_history, channel.after.terms.uncertainty)
        push!(channel_step_sizes, channel.step_size)
        push!(channel_backtracks, channel.backtracks)
        push!(channel_directional_derivatives, channel.directional_derivative)
        push!(channel_update_attempted_history, channel.update_attempted)
        push!(channel_steps_accepted, channel.accepted)
        push!(posterior_rms_changes, sweep.posterior_rms_change)
        push!(max_message_changes, sweep.max_message_change)
        push!(edge_fixed_point_rms_history, sweep.edge_fixed_point_rms)
        push!(edge_fixed_point_max_history, sweep.edge_fixed_point_max)
        push!(hard_flips, sweep.hard_flips)

        if options.early_exit && iteration >= options.minimum_iterations && gate_valid
            status = :certified_exit
            break
        end
    end

    decoder_bits = copy(messages.bits)
    syndrome = Core._syndrome_weight(problem.code, decoder_bits)
    known_bits_valid = all(decoder_bits[problem.fixed] .==
                           problem.fixed_bits[problem.fixed])
    final_crc = _crc_gate(problem, messages.posterior, payload_nbits)
    valid = syndrome == 0 && known_bits_valid && final_crc !== false
    status === :iteration_limit && valid && (status = :iteration_limit_valid)
    final_objective = expected_fit(problem, state;
        include_variance=options.include_variance,
        channel_llr_scale=options.channel_llr_scale,
        variance_weight=options.variance_weight, gradient=false,
        workspace)
    edge_count = sum(length, problem.code.check_vars; init=0)
    formulation = _formulation_metadata(options)

    trace = (;
        formulation=formulation.formulation,
        unified_free_energy_consistent=
            formulation.unified_free_energy_consistent,
        bethe_counting=formulation.bethe_counting,
        channel_belief_coupling=formulation.channel_belief_coupling,
        message_memory=formulation.message_memory,
        reported_scalar_objective=:independent_symbol_expected_fit_and_channel_regularizers,
        reported_scalar_excludes=:bethe_entropy_and_consistency_lagrangian,
        expected_fit_approximation=:independent_qpsk_symbol_covariance,
        check_rule=options.check_rule,
        check_rule_interpretation=formulation.check_rule_interpretation,
        no_decoder_entrypoint=true,
        no_decoder_vjp=true,
        no_terminal_sweeps=true,
        no_polynomial_bit_gradient=true,
        persistent_messages=true,
        message_state_initializations=1,
        message_state_resets=0,
        terminal_message_sweeps=0,
        schedule=_schedule_label(options.channel_update_interval,
                                 options.channel_mode),
        requested_iterations=options.iterations,
        completed_iterations=length(syndrome_history),
        message_sweeps=messages.sweeps,
        likelihood_rebases=messages.rebases,
        message_damping=options.message_damping,
        message_retention=options.message_retention,
        normalized_minsum_alpha=options.normalized_minsum_alpha,
        factor_counting_weight=options.factor_counting_weight,
        belief_damping=options.belief_damping,
        channel_extrinsic_scale=options.channel_extrinsic_scale,
        channel_step_size=options.channel_step_size,
        channel_update_interval=options.channel_update_interval,
        channel_mode=options.channel_mode,
        channel_llr_scale=options.channel_llr_scale,
        temperature=options.temperature,
        include_variance=options.include_variance,
        variance_weight=options.variance_weight,
        directed_edges=edge_count,
        check_to_variable_updates=edge_count * messages.sweeps,
        variable_to_check_updates=edge_count * messages.sweeps,
        status,
        initial_objective=initial_objective.loss,
        final_objective=final_objective.loss,
        initial_terms=initial_objective.terms,
        final_terms=final_objective.terms,
        objective_before_channel,
        objective_after_channel,
        physical_history,
        uncertainty_history,
        channel_step_sizes,
        channel_backtracks,
        channel_directional_derivatives,
        channel_likelihood_refresh_history,
        channel_update_attempted_history,
        channel_response_update_history=copy(
            channel_update_attempted_history),
        channel_updates_attempted=count(identity,
                                        channel_update_attempted_history),
        channel_steps_accepted,
        accepted_channel_steps=count(identity, channel_steps_accepted),
        llr_rms_changes,
        posterior_rms_changes,
        max_message_changes,
        edge_fixed_point_rms_history,
        edge_fixed_point_max_history,
        hard_flips,
        syndrome_history,
        known_bits_history,
        crc_history,
        final_syndrome=syndrome,
        final_known_bits_valid=known_bits_valid,
        final_crc_valid=final_crc,
        response_rms_change=sqrt(mean(abs2, state.C .- initial_state.C)),
        bit_rms_change=sqrt(mean(abs2, state.x .- initial_state.x)))

    (; state, posterior=copy(messages.posterior), decoder_bits, valid, status, trace,
       messages)
end

function _prefer(candidate_record, current_record)
    candidate_key = (!candidate_record.known_bits_valid,
                     candidate_record.syndrome != 0,
                     candidate_record.syndrome,
                     candidate_record.crc_valid === false,
                     candidate_record.score)
    current_key = (!current_record.known_bits_valid,
                   current_record.syndrome != 0,
                   current_record.syndrome,
                   current_record.crc_valid === false,
                   current_record.score)
    candidate_key < current_key
end

"""
    candidate(modem, code, layouts, observations; options=Options(), payload_nbits=nothing)

Build and rank residual-CFO candidates with the experimental single-loop
solver. This function is intentionally independent of `decoding_route`, so it
can be compared with JADE without adding a public receiver route.
"""
function candidate(modem, code, layouts, observations;
                   options::Options=Options(), payload_nbits=nothing)
    _validate_options(options)
    modem.mode === :joint_cz ||
        throw(ArgumentError("the experimental candidate supports joint CZ only"))
    previous_audit = modem.decoder_audit
    previous_audit === nothing ||
        throw(ArgumentError("nested receiver decoder audits are not supported"))
    audit = Core._SolverDecoderAudit(; strategy=:joint_persistent_bethe)
    modem.decoder_audit = audit

    try
    acquisition = Core._joint_cz_candidate_acquisition(
        modem, code, layouts, observations, Core._joint_cz_problem, nothing)
    zero_index = findfirst(item -> iszero(item.cfo), acquisition)
    zero_index === nothing &&
        throw(ArgumentError("the candidate set must include zero residual CFO"))
    order = sortperm(acquisition; by=item ->
        (item.pilot_score, abs(item.cfo), item.cfo))
    other = filter(!=(zero_index), order)
    retain_count = min(length(acquisition), max(1, modem.residual_cfo_keep_count))
    chosen = [zero_index; other[1:max(0, retain_count - 1)]]
    Core._joint_cz_release_unretained_spectra!(acquisition, chosen)
    reference_pilot_score = acquisition[zero_index].pilot_score

    records = sizehint!(NamedTuple[], retain_count)
    solver_traces = sizehint!(NamedTuple[], retain_count)
    best = nothing
    optimized = sizehint!(Int[], retain_count)
    for index in chosen
        acquisition_record = acquisition[index]
        Core._joint_cz_pilot_screen_passes(acquisition_record.pilot_score,
            reference_pilot_score, reference_pilot_score) || continue
        push!(optimized, index)
        problem = Core._joint_cz_materialize_candidate(
            modem, code, layouts, observations, Core._joint_cz_problem,
            acquisition_record)
        seed = Core._joint_cz_initial_state(problem, zeros(code.n))
        llrs = _channel_llrs(problem, seed;
            variance_weight=options.variance_weight)
        applied = _applied_likelihoods(problem, llrs;
            temperature=options.temperature,
            channel_llr_scale=options.channel_llr_scale)
        initial_x = tanh.(applied ./ 2)
        @inbounds for bit in eachindex(problem.fixed)
            problem.fixed[bit] && (initial_x[bit] = _fixed_bipolar(problem, bit))
        end
        initial = Core._joint_cz_initial_state(problem, initial_x)
        result = solve(problem, initial; options, payload_nbits)
        metrics = -result.posterior
        syndrome = Core._syndrome_weight(code, metrics .> 0)
        known_bits_valid = all((metrics[problem.fixed] .> 0) .==
                               problem.fixed_bits[problem.fixed])
        crc_valid = payload_nbits === nothing ? nothing :
            Core._frame_crc_valid_from_metrics(modem, code, metrics,
                                                Int(payload_nbits))
        score = Core._joint_cz_candidate_score(problem, metrics)
        record = (;
            cfo_subcarriers=problem.cfo,
            kind=:joint_persistent_messages,
            check_rule=options.check_rule,
            syndrome,
            known_bits_valid,
            crc_valid,
            score,
            pilot_score=problem.pilot_score,
            valid=syndrome == 0 && known_bits_valid && crc_valid !== false,
            solver_status=result.status,
            message_sweeps=result.trace.message_sweeps,
            channel_steps=result.trace.accepted_channel_steps,
            response_rms_change=result.trace.response_rms_change,
            bit_rms_change=result.trace.bit_rms_change,
            admissible=true)
        push!(records, record)
        push!(solver_traces, (;
            cfo_subcarriers=problem.cfo,
            status=result.status,
            valid=record.valid,
            solver_trace=result.trace))
        if best === nothing || _prefer(record, best.record)
            best = (; result, problem, record, metrics, record_index=length(records))
        end
    end
    best === nothing && error(
        "no persistent-message candidate passed the pilot screen")

    pilot_mse = mean(Core._pilot_mse(local_problem.layout,
        Core._residual_pilot_equalize(modem, local_problem.layout,
                                      copy(local_problem.full_fft)))
        for local_problem in best.problem.locals)
    selected = best.record
    formulation = _formulation_metadata(options)
    trace = (;
        mode=:joint_cz,
        joint_cz_algorithm=:single_loop_persistent_messages,
        formulation=formulation.formulation,
        unified_free_energy_consistent=
            formulation.unified_free_energy_consistent,
        bethe_counting=formulation.bethe_counting,
        factor_counting_weight=options.factor_counting_weight,
        normalized_minsum_alpha=options.normalized_minsum_alpha,
        channel_belief_coupling=formulation.channel_belief_coupling,
        message_memory=formulation.message_memory,
        channel_mode=options.channel_mode,
        channel_llr_scale=options.channel_llr_scale,
        decoding_route=:experimental_custom_candidate,
        check_rule=options.check_rule,
        message_passing=formulation.message_passing,
        bp_free=false,
        external_bp_calls=audit.bp_calls,
        terminal_bp_calls=0,
        decoder_vjp_calls=audit.vjp_calls,
        polynomial_bit_gradient_calls=0,
        output_source=:persistent_belief_posterior,
        ldpc_scope=modem.ldpc_scope,
        ofdm_symbols=length(layouts),
        codewords=1,
        likelihood=:pilot_variance,
        noise_model=:full_fft_diagonal,
        expected_fit_variance=options.include_variance ?
            :independent_qpsk_symbols : :disabled,
        variance_weight=options.variance_weight,
        schedule=_schedule_label(options.channel_update_interval,
                                 options.channel_mode),
        channel_update_interval=options.channel_update_interval,
        reference_pilot_score,
        selected_candidate=best.record_index,
        selected_kind=selected.kind,
        selected_cfo_subcarriers=best.problem.cfo,
        selected_syndrome=selected.syndrome,
        selected_known_bits_valid=selected.known_bits_valid,
        selected_crc_valid=selected.crc_valid,
        output_codeword_valid=selected.valid,
        fallback_used=false,
        returned_cfo=:shared_acquisition_only,
        acquisition_candidates=[(;
            cfo_subcarriers=item.cfo,
            pilot_score=item.pilot_score,
            retained=index in chosen,
            optimized=index in optimized)
            for (index, item) in enumerate(acquisition)],
        candidates=records,
        rounds=solver_traces,
        selected_solver_trace=best.result.trace)

    audit.bp_calls == 0 ||
        error("persistent-message solver invoked an external BP decoder")
    audit.minsum_calls == 0 ||
        error("persistent-message solver invoked the audited min-sum decoder path")
    audit.vjp_calls == 0 ||
        error("persistent-message solver invoked a decoder reverse pass")
    (; lpost_metric=best.metrics,
       valid=selected.valid,
       syndrome=selected.syndrome,
       pilot_mse,
       trace,
       state=best.result.state,
       posterior=best.result.posterior,
       decoder_bits=best.result.decoder_bits,
       cfo_subcarriers=best.problem.cfo)
    finally
        modem.decoder_audit = previous_audit
    end
end

"""Run the frozen R2-V1 profile through the package decoding route."""
function production_candidate(modem, code, layouts, observations;
                              payload_nbits=nothing)
    modem.mode === :joint_cz || throw(ArgumentError(
        "the persistent-edge decoding route supports joint CZ only"))
    options = _PERSISTENT_EDGE_R2_V1_PROFILE
    selected = candidate(
        modem, code, layouts, observations; options, payload_nbits)
    trace = merge(selected.trace, (;
        decoding_route=:persistent_edges,
        profile=:r2_v1,
        profile_parameters=_r2_v1_trace_parameters(options),
    ))
    modem.receiver_trace === nothing && (modem.receiver_trace = NamedTuple[])
    push!(modem.receiver_trace, trace)
    merge(selected, (; trace))
end

function _frame_demodulate(modem, nbits, waveform, fc, fs, options)
    nbits = Core._require_frame_payload(modem, Core._positive_nbits(nbits))
    length(waveform) >= Core._frame_sample_count(modem, fs) ||
        throw(ArgumentError("received waveform is shorter than the configured frame"))
    code = Core._code(modem)
    layouts = Core._frame_layouts(modem, fs)
    cfo = 0.0
    if modem.sync
        if modem.sync_profile === Core._SYNC_PROFILE_LFM
            waveform, cfo = Core._coarse_doppler(
                modem, waveform, fc, fs, length(layouts))
        else
            acquired = Core._rpchan_acquire(
                modem, waveform, fc, fs, length(layouts))
            waveform, cfo = acquired.payload, acquired.cfo
        end
    end
    observations = Core._frame_observations(modem, waveform, length(layouts))
    selected = candidate(modem, code, layouts, observations;
                         options, payload_nbits=nbits)
    metrics = Vector{Float64}(undef, nbits)
    next_position = Core._write_payload_metrics!(
        metrics, 1, modem, code, selected.lpost_metric, nbits)
    next_position == nbits + 1 ||
        throw(DimensionMismatch("codeword does not contain the requested payload"))
    crc_valid = Core._frame_crc_valid_from_metrics(
        modem, code, selected.lpost_metric, nbits)
    trace = merge(selected.trace, (;
        frame_crc_bits=modem.frame_crc_bits,
        crc_valid))
    selected = merge(selected, (; trace))
    modem.receiver_trace = [trace]
    (; metrics, cfo, trace, candidate=selected)
end

function _block_demodulate(modem, nbits, waveform, fc, fs, options)
    nbits, waveform, code, layout, block_count =
        Core._prepare_demodulation(modem, nbits, waveform, fc, fs)
    cfo = 0.0
    if modem.sync
        if modem.sync_profile === Core._SYNC_PROFILE_LFM
            waveform, cfo = Core._coarse_doppler(
                modem, waveform, fc, fs, block_count)
        else
            acquired = Core._rpchan_acquire(
                modem, waveform, fc, fs, block_count)
            waveform, cfo = acquired.payload, acquired.cfo
        end
    end
    Core._require_block_samples(modem, waveform, block_count)
    metrics = Vector{Float64}(undef, nbits)
    selected_candidates = NamedTuple[]
    traces = NamedTuple[]
    position = 1
    for block in 1:block_count
        first_sample = 1 + (block - 1) * Core._blocklen(modem)
        last_sample = block * Core._blocklen(modem)
        observations = [Core._branch_observations(
            modem, @view waveform[first_sample:last_sample])]
        selected = candidate(modem, code, [layout], observations; options)
        position = Core._write_payload_metrics!(
            metrics, position, modem, code, selected.lpost_metric, nbits)
        push!(selected_candidates, selected)
        push!(traces, merge(selected.trace, (; block)))
    end
    modem.receiver_trace = traces
    (; metrics, cfo, trace=traces, candidate=selected_candidates)
end

"""
    demodulate(modem, nbits, waveform, fc, fs; options=Options())

Run the experimental receiver without changing the modem's public decoding
route. The result is `(metrics, cfo, trace, candidate)` so paired experiment
runners can compare it directly with `JadeJcade.demodulate`.
"""
function demodulate(modem, nbits, waveform, fc, fs;
                    options::Options=Options())
    _validate_options(options)
    isvalid(modem, fc, fs) ||
        throw(ArgumentError("invalid JUNA modulation settings"))
    received = Core._require_finite_waveform(Core._complex_waveform(waveform))
    modem.receiver_trace = NamedTuple[]
    modem.ldpc_scope === :frame ?
        _frame_demodulate(modem, nbits, received, fc, fs, options) :
        _block_demodulate(modem, nbits, received, fc, fs, options)
end

end # module PersistentEdge
