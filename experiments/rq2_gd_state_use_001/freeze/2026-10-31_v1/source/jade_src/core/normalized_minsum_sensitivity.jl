# Piecewise-exact sensitivities of the deployed finite-sweep normalized
# min-sum calculation.  These routines refuse a derivative when a contributing
# branch lies on a sign, minimum, clipping, or hard-decision boundary.

function _minsum_selected_index(incoming, omitted::Int;
                                tolerance::Real=sqrt(eps(Float64)))
  selected = 0
  minimum_value = Inf
  tied = false
  for index in eachindex(incoming)
    index == omitted && continue
    magnitude = abs(incoming[index])
    scale = max(1.0, magnitude, minimum_value)
    if selected == 0 || magnitude < minimum_value-tolerance*scale
      selected = index
      minimum_value = magnitude
      tied = false
    elseif abs(magnitude-minimum_value) <= tolerance*scale
      tied = true
    end
  end
  (; selected, minimum_value, tied)
end

function _minsum_active_path(trace, physical_llrs, free_mask;
                             tolerance::Real=sqrt(eps(Float64)),audit=nothing)
  clip_state = Vector{Int8}(undef, length(physical_llrs))
  @inbounds for index in eachindex(physical_llrs)
    clip_state[index] = !free_mask[index] ? Int8(2) :
      physical_llrs[index] < -_LLR_CLIP ? Int8(-1) :
      physical_llrs[index] > _LLR_CLIP ? Int8(1) : Int8(0)
  end
  offsets = _minsum_message_offsets(first(trace.q_before))
  edge_count = offsets[end]-1
  signs = _PackedMinSumRows{Bool,BitVector}[]
  selected = _PackedMinSumRows{Int,Vector{Int}}[]
  sizehint!(signs, trace.iterations)
  sizehint!(selected, trace.iterations)
  for sweep in trace.q_before
    sign_values = falses(edge_count)
    selected_values = Vector{Int}(undef, edge_count)
    position = 0
    for check_row in sweep
      multiple = length(check_row) > 1
      audit isa _SolverDecoderAudit && multiple &&
        (audit.vjp_active_path_check_outputs += length(check_row))
      @inbounds for output in eachindex(check_row)
        position += 1
        sign_values[position] = signbit(check_row[output])
        selected_values[position] = multiple ?
          _minsum_selected_index(check_row, output; tolerance).selected : 0
      end
    end
    position == edge_count || error("min-sum active-path edge count changed")
    push!(signs, _PackedMinSumRows(sign_values, offsets))
    push!(selected, _PackedMinSumRows(selected_values, offsets))
  end
  (; iterations=trace.iterations, clip_state, signs, selected,
     bits=trace.bits_by_sweep, syndrome=trace.syndrome_by_sweep)
end

function _minsum_same_active_path(reference, candidate)
  reference == candidate
end

function _minsum_target_vjp(m::Modulation, code::_Code, physical_llrs,
                            target_bar;
                            trace=nothing,
                            free_mask=trues(code.n),
                            damping::Real=0.5,
                            temperature::Real=1.0,
                            nondiff_tolerance::Real=sqrt(eps(Float64)),
                            target=nothing)
  length(physical_llrs) == code.n == length(target_bar) == length(free_mask) ||
    throw(DimensionMismatch("min-sum sensitivity vectors must match the code length"))
  all(isfinite, physical_llrs) && all(isfinite, target_bar) ||
    throw(ArgumentError("finite min-sum sensitivity inputs required"))
  isfinite(damping) && 0 <= damping <= 1 ||
    throw(ArgumentError("damping must be finite and in [0,1]"))
  isfinite(temperature) && temperature > 0 ||
    throw(ArgumentError("temperature must be finite and positive"))
  isfinite(nondiff_tolerance) && nondiff_tolerance >= 0 ||
    throw(ArgumentError("nondifferentiability tolerance must be finite and nonnegative"))
  audit = m.decoder_audit isa _SolverDecoderAudit ? m.decoder_audit : nothing
  audit !== nothing && (audit.vjp_calls += 1)

  local_trace = trace === nothing ?
    _minsum_auxiliary_trace(m, code, physical_llrs) : trace
  certificate = _minsum_auxiliary_residuals(m, code, physical_llrs, local_trace)
  certificate.max_abs == 0.0 ||
    throw(ArgumentError("min-sum trace does not satisfy the deployed recurrence"))
  supplied_target = target !== nothing
  target = supplied_target ? target :
    _minsum_auxiliary_target(local_trace; damping, temperature)
  length(target) == code.n && all(isfinite, target) ||
    throw(ArgumentError("finite min-sum targets matching the code length required"))
  if supplied_target
    @inbounds for index in 1:code.n
      feedback = local_trace.applied[index] +
        damping*local_trace.extrinsic[index]
      expected_target = tanh(clamp(feedback, -_LLR_CLIP, _LLR_CLIP) /
        (2temperature))
      target[index] == expected_target ||
        throw(ArgumentError("cached min-sum target differs from the certified trace"))
    end
  end
  path = _minsum_active_path(local_trace, physical_llrs, free_mask;
    tolerance=nondiff_tolerance,audit)
  zero_gradient() = (; gradient=zeros(Float64, code.n), target,
    trace=local_trace, active_path=path, differentiable=true,
    reason=nothing, certificate)
  all(iszero, target_bar) && return zero_gradient()

  physical_mask = zeros(Float64, code.n)
  for index in eachindex(physical_llrs)
    free_mask[index] || continue
    value = Float64(physical_llrs[index])
    if abs(abs(value)-_LLR_CLIP) <=
       nondiff_tolerance*max(1.0, abs(value), _LLR_CLIP)
      return (; gradient=zeros(Float64, code.n), target, trace=local_trace,
        active_path=path, differentiable=false,
        reason=:physical_llr_clipping_boundary, certificate)
    end
    abs(value) < _LLR_CLIP && (physical_mask[index] = 1.0)
  end
  # If every free physical input is locally constant after clipping, every
  # downstream message and target is locally constant even when equal message
  # magnitudes occur in the recorded arithmetic.
  all(iszero, physical_mask) && return zero_gradient()

  total_bar = zeros(Float64, code.n)
  posterior_bar = zeros(Float64, code.n)
  for index in eachindex(local_trace.applied)
    upstream = Float64(target_bar[index])
    iszero(upstream) && continue
    feedback = local_trace.applied[index] +
      damping*local_trace.extrinsic[index]
    scale = max(1.0, abs(feedback), _LLR_CLIP)
    if abs(abs(feedback)-_LLR_CLIP) <= nondiff_tolerance*scale
      return (; gradient=zeros(Float64, code.n), target, trace=local_trace,
        active_path=path, differentiable=false,
        reason=:feedback_clipping_boundary, certificate)
    end
    abs(feedback) > _LLR_CLIP && continue
    pre_bar = upstream*(1-target[index]^2)/(2temperature)
    total_bar[index] += (1-damping)*pre_bar
    posterior_bar[index] += damping*pre_bar
  end

  # Hard decisions determine both the syndrome and the stopping sweep.
  for posterior in local_trace.posterior_by_sweep, value in posterior
    if abs(value) <= nondiff_tolerance*max(1.0, abs(value))
      return (; gradient=zeros(Float64, code.n), target, trace=local_trace,
        active_path=path, differentiable=false,
        reason=:hard_decision_boundary, certificate)
    end
  end

  q_after_bar = [zeros(Float64, length(row)) for row in code.check_vars]
  r_bar = [zeros(Float64, length(row)) for row in code.check_vars]
  q_before_bar = [zeros(Float64, length(row)) for row in code.check_vars]
  for sweep in local_trace.iterations:-1:1
    for check in eachindex(code.check_vars)
      fill!(r_bar[check], 0.0)
      for (edge, variable) in enumerate(code.check_vars[check])
        audit !== nothing && (audit.vjp_reverse_edge_propagations += 1)
        upstream = q_after_bar[check][edge]
        posterior_bar[variable] += upstream
        r_bar[check][edge] -= upstream
      end
    end
    for variable in 1:code.n
      upstream = posterior_bar[variable]
      total_bar[variable] += upstream
      for (check, edge) in code.var_edges[variable]
        audit !== nothing && (audit.vjp_reverse_edge_propagations += 1)
        r_bar[check][edge] += upstream
      end
    end

    for check in eachindex(code.check_vars)
      fill!(q_before_bar[check], 0.0)
      incoming = local_trace.q_before[sweep][check]
      length(incoming) <= 1 && continue
      for output in eachindex(incoming)
        upstream = r_bar[check][output]
        iszero(upstream) && continue
        audit !== nothing && (audit.vjp_reverse_check_derivatives += 1)
        choice = _minsum_selected_index(incoming, output;
          tolerance=nondiff_tolerance)
        if choice.tied
          return (; gradient=zeros(Float64, code.n), target,
            trace=local_trace, active_path=path, differentiable=false,
            reason=:contributing_minimum_tie, certificate)
        end
        selected = choice.selected
        value = incoming[selected]
        if abs(value) <= nondiff_tolerance*max(1.0, abs(value))
          return (; gradient=zeros(Float64, code.n), target,
            trace=local_trace, active_path=path, differentiable=false,
            reason=:contributing_zero_message, certificate)
        end
        sign_without_self = 1.0
        for index in eachindex(incoming)
          index == output && continue
          sign_without_self *= incoming[index] < 0.0 ? -1.0 : 1.0
        end
        absolute_derivative = value < 0.0 ? -1.0 : 1.0
        q_before_bar[check][selected] +=
          upstream*_BP_ALPHA*sign_without_self*absolute_derivative
      end
    end

    if sweep == 1
      for check in eachindex(code.check_vars)
        for (edge, variable) in enumerate(code.check_vars[check])
          audit !== nothing && (audit.vjp_reverse_edge_propagations += 1)
          total_bar[variable] += q_before_bar[check][edge]
        end
      end
    else
      for check in eachindex(code.check_vars), edge in eachindex(code.check_vars[check])
        audit !== nothing && (audit.vjp_reverse_edge_propagations += 1)
        q_after_bar[check][edge] = q_before_bar[check][edge]
      end
      fill!(posterior_bar, 0.0)
    end
  end

  total_bar .*= physical_mask
  gradient = total_bar
  (; gradient, target, trace=local_trace, active_path=path,
     differentiable=true, reason=nothing, certificate)
end
