module ParityADMMDecoder

using LinearAlgebra

export ParityPlan, prepare, project_even!, syndrome_weight,
       consensus_residuals, decode

struct ParityPlan
    nbits::Int
    checks::Vector{Vector{Int}}
    variable_edges::Vector{Vector{Tuple{Int,Int}}}
    edge_count::Int
end

function prepare(checks, nbits::Integer)
    n = Int(nbits)
    n > 0 || throw(ArgumentError("codeword length must be positive"))
    copied = Vector{Vector{Int}}(undef, length(checks))
    variable_edges = [Tuple{Int,Int}[] for _ in 1:n]
    edge_count = 0
    for (check_index, source) in enumerate(checks)
        check = Int.(source)
        isempty(check) && throw(ArgumentError("parity checks must not be empty"))
        length(unique(check)) == length(check) ||
            throw(ArgumentError("a parity check contains a repeated variable"))
        for (position, bit) in enumerate(check)
            1 <= bit <= n || throw(ArgumentError("parity variable lies outside the codeword"))
            push!(variable_edges[bit], (check_index, position))
            edge_count += 1
        end
        copied[check_index] = check
    end
    all(!isempty, variable_edges) ||
        throw(ArgumentError("every code bit must participate in a parity check"))
    ParityPlan(n, copied, variable_edges, edge_count)
end

function project_even!(out::Vector{Float64}, input::Vector{Float64},
                       signs::Vector{Int8})
    degree = length(input)
    degree == length(out) == length(signs) && degree > 0 ||
        throw(DimensionMismatch("projection workspace dimensions differ"))
    all(isfinite, input) || throw(ArgumentError("finite projection input required"))
    if degree == 1
        out[1] = 0.0
        return out
    end

    positive = 0
    closest = 1
    closest_distance = Inf
    @inbounds for bit in 1:degree
        value = clamp(input[bit], 0.0, 1.0)
        out[bit] = value
        signs[bit] = value > 0.5 ? Int8(1) : Int8(-1)
        positive += signs[bit] == 1
        distance = abs(value - 0.5)
        if distance < closest_distance
            closest_distance = distance
            closest = bit
        end
    end
    if iseven(positive)
        signs[closest] = -signs[closest]
        positive += signs[closest] == 1 ? 1 : -1
    end
    bound = positive - 1
    violation = -bound
    @inbounds for bit in 1:degree
        violation += signs[bit] * out[bit]
    end
    violation <= 0.0 && return out

    low = 0.0
    high = maximum(abs, input) + 1.0
    for _ in 1:52
        multiplier = (low + high) / 2
        residual = -bound
        @inbounds for bit in 1:degree
            residual += signs[bit] *
                clamp(input[bit] - multiplier * signs[bit], 0.0, 1.0)
        end
        if residual > 0.0
            low = multiplier
        else
            high = multiplier
        end
    end
    multiplier = (low + high) / 2
    @inbounds for bit in 1:degree
        out[bit] = clamp(input[bit] - multiplier * signs[bit], 0.0, 1.0)
    end
    out
end

function syndrome_weight(checks, word::AbstractVector{Bool})
    count(check -> isodd(count(bit -> word[bit], check)), checks)
end

"""Return the scaled primal and dual consensus residuals for one ADMM step."""
function consensus_residuals(plan::ParityPlan, x::AbstractVector{<:Real},
                             current, previous, rho::Real)
    length(x) == plan.nbits && all(isfinite, x) ||
        throw(ArgumentError("one finite shared coordinate is required per bit"))
    length(current) == length(plan.checks) == length(previous) ||
        throw(DimensionMismatch("local-copy rows differ from the parity plan"))
    isfinite(rho) && rho > 0 ||
        throw(ArgumentError("rho must be positive and finite"))
    dual_accumulator = zeros(Float64, plan.nbits)
    primal_squared = 0.0
    @inbounds for check_index in eachindex(plan.checks)
        members = plan.checks[check_index]
        local_current = current[check_index]
        local_previous = previous[check_index]
        length(local_current) == length(members) == length(local_previous) ||
            throw(DimensionMismatch("a local-copy row differs from its check"))
        all(isfinite, local_current) && all(isfinite, local_previous) ||
            throw(ArgumentError("local-copy coordinates must be finite"))
        for (position, bit) in enumerate(members)
            primal_squared += (Float64(x[bit]) - local_current[position])^2
            dual_accumulator[bit] +=
                local_current[position] - local_previous[position]
        end
    end
    (; primal_rms=sqrt(primal_squared / plan.edge_count),
       dual_rms=Float64(rho) *
           sqrt(sum(abs2, dual_accumulator) / plan.nbits))
end

function _candidate(plan::ParityPlan, hard, fixed_mask, fixed_bits,
                    channel, accept_word)
    syndrome = syndrome_weight(plan.checks, hard)
    fixed_bits_valid = all(hard[fixed_mask] .== fixed_bits[fixed_mask])
    codeword_valid = syndrome == 0 && fixed_bits_valid
    accepted = codeword_valid && Bool(accept_word(hard))
    objective = codeword_valid ? dot(channel, Float64.(hard)) : Inf
    (; syndrome, fixed_bits_valid, codeword_valid, accepted, objective)
end

function decode(checks, channel_llr_bit0::AbstractVector{<:Real}; kwargs...)
    decode(prepare(checks, length(channel_llr_bit0)), channel_llr_bit0; kwargs...)
end

function decode(plan::ParityPlan, channel_llr_bit0::AbstractVector{<:Real};
                rho::Real=3.0, alpha::Real=0.6, iterations::Integer=200,
                fixed_mask::AbstractVector{Bool}=falses(plan.nbits),
                fixed_bits::AbstractVector{Bool}=falses(plan.nbits),
                residual_tolerance::Real=1e-6,
                integrality_tolerance::Real=1e-8,
                initial_relaxed=nothing,
                early_stop_on_accepted::Bool=true,
                accept_word::Function=word -> true)
    n = plan.nbits
    length(channel_llr_bit0) == n && all(isfinite, channel_llr_bit0) ||
        throw(ArgumentError("one finite bit-zero log-likelihood ratio is required per code bit"))
    length(fixed_mask) == n && length(fixed_bits) == n ||
        throw(ArgumentError("fixed-bit vectors must match the codeword length"))
    isfinite(rho) && rho > 0 || throw(ArgumentError("rho must be positive and finite"))
    isfinite(alpha) && alpha >= 0 ||
        throw(ArgumentError("alpha must be nonnegative and finite"))
    iterations > 0 || throw(ArgumentError("iteration count must be positive"))
    isfinite(residual_tolerance) && residual_tolerance >= 0 ||
        throw(ArgumentError("residual tolerance must be finite and nonnegative"))
    isfinite(integrality_tolerance) && integrality_tolerance >= 0 ||
        throw(ArgumentError("integrality tolerance must be finite and nonnegative"))

    if initial_relaxed !== nothing
        length(initial_relaxed) == n && all(isfinite, initial_relaxed) ||
            throw(ArgumentError(
                "the initial relaxed state must contain one finite coordinate per bit"))
        all(value -> 0 <= value <= 1, initial_relaxed) ||
            throw(ArgumentError("the initial relaxed state must lie in [0,1]"))
    end

    channel = Float64.(channel_llr_bit0)
    @inbounds for bit in 1:n
        degree = length(plan.variable_edges[bit])
        rho * degree > 2alpha || throw(ArgumentError(
            "penalty makes the bit subproblem nonconvex at variable $bit"))
    end

    initialization = initial_relaxed === nothing ?
        :channel_hard_decision : :provided_relaxed_state
    x = initial_relaxed === nothing ? Float64.(channel .< 0) :
        Float64.(initial_relaxed)
    @inbounds for bit in 1:n
        fixed_mask[bit] && (x[bit] = Float64(fixed_bits[bit]))
    end
    z = [zeros(Float64, length(check)) for check in plan.checks]
    dual = [zeros(Float64, length(check)) for check in plan.checks]
    projection_input = [zeros(Float64, length(check)) for check in plan.checks]
    projection_output = [zeros(Float64, length(check)) for check in plan.checks]
    signs = [zeros(Int8, length(check)) for check in plan.checks]
    dual_accumulator = zeros(Float64, n)
    hard = BitVector(x .>= 0.5)
    hard[fixed_mask] .= fixed_bits[fixed_mask]

    @inbounds for check_index in eachindex(plan.checks)
        check = plan.checks[check_index]
        values = projection_input[check_index]
        for (position, bit) in enumerate(check)
            values[position] = x[bit]
        end
        project_even!(z[check_index], values, signs[check_index])
    end

    initial = _candidate(plan, hard, fixed_mask, fixed_bits, channel, accept_word)
    best_valid_word = initial.codeword_valid ? copy(hard) : nothing
    best_valid_objective = initial.objective
    best_accepted_word = initial.accepted ? copy(hard) : nothing
    best_accepted_objective = initial.accepted ? initial.objective : Inf
    first_valid_iteration = initial.codeword_valid ? 0 : nothing
    first_accepted_iteration = initial.accepted ? 0 : nothing

    primal_history = Float64[]
    dual_history = Float64[]
    integrality_history = Float64[]
    integrality_max_history = Float64[]
    syndrome_history = Int[]
    sizehint!(primal_history, Int(iterations))
    sizehint!(dual_history, Int(iterations))
    sizehint!(integrality_history, Int(iterations))
    sizehint!(integrality_max_history, Int(iterations))
    sizehint!(syndrome_history, Int(iterations))
    iterations_run = 0
    admm_converged = false

    if !(early_stop_on_accepted && initial.accepted)
        for iteration in 1:Int(iterations)
            iterations_run = iteration
            @inbounds for bit in 1:n
                if fixed_mask[bit]
                    x[bit] = Float64(fixed_bits[bit])
                    continue
                end
                consensus = 0.0
                edges = plan.variable_edges[bit]
                for (check_index, position) in edges
                    consensus += z[check_index][position] - dual[check_index][position]
                end
                degree = length(edges)
                x[bit] = clamp((rho * consensus - channel[bit] - alpha) /
                               (rho * degree - 2alpha), 0.0, 1.0)
            end

            fill!(dual_accumulator, 0.0)
            primal_squared = 0.0
            @inbounds for check_index in eachindex(plan.checks)
                check = plan.checks[check_index]
                values = projection_input[check_index]
                projected = projection_output[check_index]
                local_z = z[check_index]
                local_dual = dual[check_index]
                for (position, bit) in enumerate(check)
                    values[position] = x[bit] + local_dual[position]
                end
                project_even!(projected, values, signs[check_index])
                for (position, bit) in enumerate(check)
                    difference = projected[position] - local_z[position]
                    dual_accumulator[bit] += difference
                    local_z[position] = projected[position]
                    residual = x[bit] - projected[position]
                    local_dual[position] += residual
                    primal_squared += residual^2
                end
            end
            primal_rms = sqrt(primal_squared / plan.edge_count)
            dual_rms = rho * sqrt(sum(abs2, dual_accumulator) / n)
            integrality_rms = sqrt(sum(value -> min(value, 1 - value)^2, x) / n)
            integrality_max = maximum(value -> min(value, 1 - value), x)
            push!(primal_history, primal_rms)
            push!(dual_history, dual_rms)
            push!(integrality_history, integrality_rms)
            push!(integrality_max_history, integrality_max)

            @inbounds for bit in 1:n
                hard[bit] = x[bit] >= 0.5
                fixed_mask[bit] && (hard[bit] = fixed_bits[bit])
            end
            candidate = _candidate(plan, hard, fixed_mask, fixed_bits,
                                   channel, accept_word)
            push!(syndrome_history, candidate.syndrome)
            if candidate.codeword_valid
                first_valid_iteration === nothing &&
                    (first_valid_iteration = iteration)
                if candidate.objective < best_valid_objective
                    best_valid_word = copy(hard)
                    best_valid_objective = candidate.objective
                end
            end
            if candidate.accepted
                first_accepted_iteration === nothing &&
                    (first_accepted_iteration = iteration)
                if candidate.objective < best_accepted_objective
                    best_accepted_word = copy(hard)
                    best_accepted_objective = candidate.objective
                end
            end
            admm_converged = primal_rms <= residual_tolerance &&
                dual_rms <= residual_tolerance
            early_stop_on_accepted && candidate.accepted && break
        end
    end

    word = best_accepted_word !== nothing ? best_accepted_word :
        best_valid_word !== nothing ? best_valid_word : copy(hard)
    final = _candidate(plan, word, fixed_mask, fixed_bits, channel, accept_word)
    integrality_rms = isempty(integrality_history) ? 0.0 : last(integrality_history)
    integrality_max = isempty(integrality_max_history) ? 0.0 :
        last(integrality_max_history)
    integral = integrality_max <= integrality_tolerance
    (; word, relaxed=x, syndrome=final.syndrome,
       fixed_bits_valid=final.fixed_bits_valid,
       codeword_valid=final.codeword_valid, valid=final.codeword_valid,
       accepted=final.accepted, objective=final.objective,
       first_valid_iteration, first_accepted_iteration,
       iterations_requested=Int(iterations), iterations_run,
       primal_residual_rms=isempty(primal_history) ? 0.0 : last(primal_history),
       dual_residual_rms=isempty(dual_history) ? 0.0 : last(dual_history),
       integrality_rms, integrality_max, integral, admm_converged,
       primal_history, dual_history, integrality_history,
       integrality_max_history, syndrome_history,
       rho=Float64(rho), alpha=Float64(alpha),
       initialization,
       message_passing=:parity_polytope_admm_consensus,
       bp_calls=0, minsum_calls=0)
end

end # module
