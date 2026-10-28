# Augmented-Lagrangian coupling between the joint-CZ continuous state and the
# exact finite-sweep normalized-min-sum feedback target.

function _soft_minsum_validate_state(problem, state)
  hasproperty(problem, :m) && hasproperty(problem, :C0) &&
    hasproperty(problem, :nbits) ||
    throw(ArgumentError("a joint-CZ problem is required"))
  problem.m.mode === _MODE_JOINT_CZ ||
    throw(ArgumentError("Documented Option B requires a joint-CZ problem"))
  hasproperty(problem, :views) &&
    throw(ArgumentError("Documented Option B does not support joint-CWZ observations"))
  hasproperty(state, :C) && hasproperty(state, :x) ||
    throw(ArgumentError("initial state must contain C and x"))
  hasproperty(state, :theta) &&
    throw(ArgumentError("joint-CZ state must not contain theta"))
  size(state.C) == size(problem.C0) ||
    throw(DimensionMismatch("joint receiver response shape differs"))
  length(state.x) == problem.nbits ||
    throw(DimensionMismatch("joint receiver bit-state length differs"))
  all(isfinite, state.C) && all(isfinite, state.x) ||
    throw(ArgumentError("finite response and bit parameters required"))
  nothing
end
function _soft_minsum_zero_gradient(state)
  (C=zero(state.C), x=zeros(Float64, length(state.x)))
end

function _joint_cz_symbol_is_variable(problem, p, carrier)
  tone = p.symbol_slots[carrier]
  tone == 0 && return false
  first_bit = p.bit_indices[1, tone]
  second_bit = p.bit_indices[2, tone]
  (first_bit > 0 && !problem.fixed[first_bit]) ||
    (second_bit > 0 && !problem.fixed[second_bit])
end

function _joint_cz_channel_llrs_vjp(problem, state, llr_bar;
                                     nondiff_tolerance::Real=sqrt(eps(Float64)))
  _soft_minsum_validate_state(problem, state)
  length(llr_bar) == problem.nbits ||
    throw(DimensionMismatch("one likelihood cotangent is required per coded bit"))
  all(isfinite, llr_bar) || throw(ArgumentError("finite likelihood cotangents required"))
  isfinite(nondiff_tolerance) && nondiff_tolerance >= 0 ||
    throw(ArgumentError("nondifferentiability tolerance must be finite and nonnegative"))
  y = problem.y
  gC = zero(state.C)
  gx = zeros(Float64, problem.nbits)
  first_local = first(problem.locals)
  symbols = similar(first_local.fixed_symbols)
  symbol_bar = zeros(ComplexF64, length(symbols))
  sufficient_bar = zeros(ComplexF64, length(symbols))

  for (symbol, p) in enumerate(problem.locals)
    _joint_cz_symbols!(symbols, p, state.x)
    fill!(symbol_bar, 0)
    fill!(sufficient_bar, 0)
    for (tone, carrier) in enumerate(p.data_idx)
      first_bit = p.bit_indices[1, tone]
      second_bit = p.bit_indices[2, tone]
      real_bar = first_bit == 0 ? 0.0 : Float64(llr_bar[first_bit])
      imag_bar = second_bit == 0 ? 0.0 : Float64(llr_bar[second_bit])
      sufficient_bar[carrier] = sqrt(2.0)*complex(real_bar, imag_bar)
    end

    for carrier in p.active
      for target in axes(state.C, 1)
        transmitted = p.neighbor_idx[target, carrier]
        transmitted == 0 && continue
        output_bar = sufficient_bar[transmitted]
        iszero(output_bar) && continue
        residual = y[carrier, symbol]
        variance = problem.variances[symbol]
        for band in axes(state.C, 1)
          neighbor = p.neighbor_idx[band, carrier]
          (neighbor == 0 || band == target) && continue
          response = state.C[band, carrier, symbol]
          residual -= response*symbols[neighbor]
          variance += abs2(response)*max(0.0, 1-abs2(symbols[neighbor]))
        end
        response = state.C[target, carrier, symbol]
        response_bar = conj(output_bar)*residual/variance
        residual_bar = output_bar*response/variance
        variance_bar = -2real(conj(output_bar)*conj(response)*residual)/variance^2
        gC[target, carrier, symbol] += response_bar

        for band in axes(state.C, 1)
          neighbor = p.neighbor_idx[band, carrier]
          (neighbor == 0 || band == target) && continue
          interfering_response = state.C[band, carrier, symbol]
          interfering_symbol = symbols[neighbor]
          uncertainty = max(0.0, 1-abs2(interfering_symbol))
          gC[band, carrier, symbol] +=
            -residual_bar*conj(interfering_symbol) +
            variance_bar*interfering_response*uncertainty
          symbol_bar[neighbor] += -residual_bar*conj(interfering_response)
          if _joint_cz_symbol_is_variable(problem, p, neighbor)
            boundary_scale = max(1.0, abs2(interfering_symbol))
            if abs(1-abs2(interfering_symbol)) <=
               nondiff_tolerance*boundary_scale &&
               !iszero(variance_bar) && !iszero(interfering_response)
              return (; gradient=_soft_minsum_zero_gradient(state),
                differentiable=false, reason=:likelihood_variance_boundary)
            end
            abs2(interfering_symbol) < 1 &&
              (symbol_bar[neighbor] -=
                variance_bar*abs2(interfering_response)*interfering_symbol)
          end
        end
      end
    end

    for (tone, carrier) in enumerate(p.data_idx)
      first_bit = p.bit_indices[1, tone]
      second_bit = p.bit_indices[2, tone]
      first_bit > 0 && !problem.fixed[first_bit] &&
        (gx[first_bit] += sqrt(2.0)*real(symbol_bar[carrier]))
      second_bit > 0 && !problem.fixed[second_bit] &&
        (gx[second_bit] += sqrt(2.0)*imag(symbol_bar[carrier]))
    end
  end
  gx[problem.fixed] .= 0.0

  gradient = (; C=gC, x=gx)
  (; gradient, differentiable=true, reason=nothing)
end

function _soft_minsum_lagrangian_evaluate(problem, state, lambda;
                                        rho::Real,
                                        damping::Real=0.5,
                                        temperature::Real=1.0,
                                        nondiff_tolerance::Real=sqrt(eps(Float64)))
  _soft_minsum_validate_state(problem, state)
  length(lambda) == problem.nbits ||
    throw(DimensionMismatch("one terminal multiplier is required per coded bit"))
  all(isfinite, lambda) || throw(ArgumentError("finite terminal multipliers required"))
  isfinite(rho) && rho >= 0 || throw(ArgumentError("rho must be finite and nonnegative"))
  isfinite(damping) && 0 <= damping <= 1 ||
    throw(ArgumentError("damping must be finite and in [0,1]"))
  isfinite(temperature) && temperature > 0 ||
    throw(ArgumentError("temperature must be finite and positive"))
  isfinite(nondiff_tolerance) && nondiff_tolerance >= 0 ||
    throw(ArgumentError("nondifferentiability tolerance must be finite and nonnegative"))
  base = _joint_cz_objective_gradient(problem, state)
  physical_llrs = _joint_cz_channel_llrs(problem, state)
  decoder = _minsum_auxiliary_trace(problem.m, problem.code, physical_llrs)
  target = _minsum_auxiliary_target(decoder; damping, temperature)
  free = .!problem.fixed
  consistency = zeros(Float64, problem.nbits)
  terminal_bar = zeros(Float64, problem.nbits)
  @inbounds for bit in eachindex(free)
    free[bit] || continue
    consistency[bit] = state.x[bit]-target[bit]
    terminal_bar[bit] = lambda[bit]+rho*consistency[bit]
  end
  free_lambda = lambda[free]
  free_consistency = consistency[free]
  linear = dot(free_lambda, free_consistency)
  quadratic = rho/2*sum(abs2, free_consistency)
  loss = base.loss+linear+quadratic

  message = _minsum_target_vjp(problem.m, problem.code, physical_llrs,
    -terminal_bar; trace=decoder, free_mask=free, damping, temperature,
    nondiff_tolerance, target)
  likelihood = message.differentiable ?
    _joint_cz_channel_llrs_vjp(problem, state, message.gradient;
      nondiff_tolerance) :
    (; gradient=_soft_minsum_zero_gradient(state), differentiable=false,
       reason=message.reason)
  differentiable = message.differentiable && likelihood.differentiable
  reason = !message.differentiable ? message.reason : likelihood.reason

  gx = base.gradient.x
  gx .+= likelihood.gradient.x
  @inbounds for bit in eachindex(free)
    if free[bit]
      gx[bit] += terminal_bar[bit]
    else
      gx[bit] = 0.0
    end
  end
  gC = base.gradient.C
  gC .+= likelihood.gradient.C
  gradient = (; C=gC, x=gx)
  terms = merge(base.terms, (; consistency_linear=linear,
    consistency_quadratic=quadratic,
    consistency_norm=norm(free_consistency)))
  (; loss, gradient, terms, consistency, target, physical_llrs, decoder,
     active_path=message.active_path, differentiable, reason,
     recurrence=message.certificate)
end

function _soft_minsum_direction(problem, state, gradient)
  base = _joint_cz_directions(problem, state, gradient)
  problem.m.projected_gradient_update_response || fill!(base.C, 0)
  problem.m.projected_gradient_update_bits || fill!(base.x, 0)
  base
end

function _soft_minsum_project(problem, state, direction, step)
  x = clamp.(state.x+step*direction.x, -1.0, 1.0)
  x[problem.fixed] .= _pm.(problem.fixed_bits[problem.fixed])
  (C=state.C+step*direction.C, x)
end

_soft_minsum_directional_derivative(gradient, direction) =
  2real(dot(gradient.C, direction.C))+dot(gradient.x, direction.x)

function _soft_minsum_trial_acceptable(current, trial)
  trial.differentiable && isfinite(trial.loss) && trial.loss < current.loss
end

function _soft_minsum_final_decoder(problem, state)
  _soft_minsum_validate_state(problem, state)
  physical = _joint_cz_channel_llrs(problem, state)
  decoder = _minsum_auxiliary_trace(problem.m, problem.code, physical)
  certificate = _minsum_auxiliary_residuals(problem.m, problem.code, physical, decoder)
  (; physical, decoder, certificate)
end

function _soft_minsum_decoder_result(problem, decoder)
  decoder_bits = copy(decoder.bits_by_sweep[end])
  decoder_valid = decoder.valid
  known_bits_valid = all(decoder_bits[problem.fixed] .==
    problem.fixed_bits[problem.fixed])
  valid = decoder_valid && known_bits_valid
  z = valid ? copy(decoder_bits) : nothing
  (; decoder_bits, decoder_valid, known_bits_valid, valid, z)
end

function _soft_minsum_lagrangian_solve(problem, initial;
                                     rho::Real,
                                     outer_steps::Integer,
                                     inner_steps::Integer,
                                     damping::Real=0.5,
                                     temperature::Real=1.0,
                                     initial_step::Real=problem.m.projected_gradient_step_size,
                                     max_backtracks::Integer=16,
                                     constraint_tolerance::Real=1e-6,
                                     nondiff_tolerance::Real=sqrt(eps(Float64)))
  isfinite(rho) && rho >= 0 || throw(ArgumentError("rho must be finite and nonnegative"))
  isfinite(damping) && 0 <= damping <= 1 ||
    throw(ArgumentError("damping must be finite and in [0,1]"))
  isfinite(temperature) && temperature > 0 ||
    throw(ArgumentError("temperature must be finite and positive"))
  isfinite(nondiff_tolerance) && nondiff_tolerance >= 0 ||
    throw(ArgumentError("nondifferentiability tolerance must be finite and nonnegative"))
  outer_steps >= 1 || throw(ArgumentError("outer_steps must be positive"))
  inner_steps >= 1 || throw(ArgumentError("inner_steps must be positive"))
  isfinite(initial_step) && initial_step > 0 ||
    throw(ArgumentError("initial_step must be finite and positive"))
  max_backtracks >= 0 || throw(ArgumentError("max_backtracks must be nonnegative"))
  isfinite(constraint_tolerance) && constraint_tolerance >= 0 ||
    throw(ArgumentError("constraint_tolerance must be finite and nonnegative"))

  _soft_minsum_validate_state(problem, initial)
  state = (C=copy(initial.C), x=clamp.(initial.x, -1.0, 1.0))
  state.x[problem.fixed] .= _pm.(problem.fixed_bits[problem.fixed])

  # Rho zero is the exact legacy control and incurs no additional decoder call
  # inside the continuous solver.
  if iszero(rho)
    solved = _solve_joint_cz_projected_gradient(problem, state)
    final = _soft_minsum_final_decoder(problem, solved.state)
    decoded = _soft_minsum_decoder_result(problem, final.decoder)
    trace = (; legacy=solved.trace, rho=0.0, outer_steps_requested=outer_steps,
      inner_steps_requested=inner_steps, dual_updates=0, converged=false,
      consistency_norm=NaN, recurrence=final.certificate,
      decoder_iterations=final.decoder.iterations,
      decoder_syndrome=final.decoder.syndrome,
      decoder_valid=decoded.decoder_valid,
      known_bits_valid=decoded.known_bits_valid,
      differentiability=:not_evaluated_on_legacy_path)
    return (; state=solved.state, trace, status=:legacy_delegated,
      valid=decoded.valid, z=decoded.z, decoder_bits=decoded.decoder_bits)
  end

  lambda = zeros(Float64, problem.nbits)
  first = _soft_minsum_lagrangian_evaluate(problem, state, lambda; rho,
    damping, temperature, nondiff_tolerance)
  current = first
  objective_history = [current.loss]
  consistency_history = [current.terms.consistency_norm]
  dual_norm_history = [0.0]
  step_sizes = Float64[]
  directional_derivatives = Float64[]
  active_path_changes = 0
  nondifferentiable_rejections = 0
  inner_stalls = 0
  inner_stationary_events = 0
  accepted_steps = 0
  dual_updates = 0
  status = :outer_steps_completed
  reason = nothing
  converged = false

  for outer in 1:outer_steps
    # A new multiplier defines a new inner objective.  Do not carry a prior
    # inner termination reason into the next outer step.
    status = :outer_steps_completed
    reason = nothing
    current = _soft_minsum_lagrangian_evaluate(problem, state, lambda; rho,
      damping, temperature, nondiff_tolerance)
    if !current.differentiable
      status = :nondifferentiable
      reason = current.reason
      break
    end
    accepted_this_outer = 0
    for _ in 1:inner_steps
      direction = _soft_minsum_direction(problem, state, current.gradient)
      directional = _soft_minsum_directional_derivative(current.gradient, direction)
      if !(isfinite(directional) && directional < 0)
        status = :no_descent
        reason = :nonnegative_directional_derivative
        inner_stationary_events += 1
        break
      end
      accepted = false
      for backtrack in 0:max_backtracks
        step = initial_step*0.5^backtrack
        trial_state = _soft_minsum_project(problem, state, direction, step)
        trial = _soft_minsum_lagrangian_evaluate(problem, trial_state, lambda; rho,
          damping, temperature, nondiff_tolerance)
        if !trial.differentiable
          nondifferentiable_rejections += 1
          continue
        end
        !_minsum_same_active_path(current.active_path, trial.active_path) &&
          (active_path_changes += 1)
        if _soft_minsum_trial_acceptable(current, trial)
          state, current = trial_state, trial
          push!(objective_history, current.loss)
          push!(step_sizes, step)
          push!(directional_derivatives, directional)
          accepted_steps += 1
          accepted_this_outer += 1
          accepted = true
          break
        end
      end
      if !accepted
        status = :inner_line_search_stalled
        reason = :line_search_stalled
        inner_stalls += 1
        break
      end
    end
    status === :nondifferentiable && break
    if status in (:no_descent, :inner_line_search_stalled) &&
       accepted_this_outer == 0
      break
    end
    lambda .+= rho .* current.consistency
    lambda[problem.fixed] .= 0.0
    dual_updates += 1
    push!(consistency_history, current.terms.consistency_norm)
    push!(dual_norm_history, norm(lambda[.!problem.fixed]))
    if current.terms.consistency_norm <= constraint_tolerance
      status = :agreement_satisfied
      reason = nothing
      break
    end
    status === :inner_line_search_stalled && break
    if status === :no_descent
      status = :outer_step_completed
      reason = nothing
    end
  end

  final = _soft_minsum_final_decoder(problem, state)
  reported = _soft_minsum_lagrangian_evaluate(problem, state, lambda; rho,
    damping, temperature, nondiff_tolerance)
  decoded = _soft_minsum_decoder_result(problem, final.decoder)
  trace = (; rho=Float64(rho), damping=Float64(damping),
    temperature=Float64(temperature), initial_objective=first.loss,
    final_objective=reported.loss, initial_terms=first.terms,
    final_terms=reported.terms, objective_history, consistency_history,
    dual_norm_history, final_lambda=copy(lambda), step_sizes,
    directional_derivatives, accepted_steps, dual_updates,
    outer_steps_requested=Int(outer_steps), inner_steps_requested=Int(inner_steps),
    active_path_changes, nondifferentiable_rejections, inner_stalls,
    inner_stationary_events,
    converged, agreement_satisfied=status === :agreement_satisfied,
    status_reason=reason,
    constraint_tolerance=Float64(constraint_tolerance),
    differentiable=reported.differentiable,
    nondifferentiable_reason=reported.reason,
    recurrence=final.certificate,
    decoder_iterations=final.decoder.iterations,
    decoder_syndrome=final.decoder.syndrome,
    decoder_valid=decoded.decoder_valid,
    known_bits_valid=decoded.known_bits_valid,
    unnormalized_terminal_terms=true)
  (; state, trace, status, valid=decoded.valid, z=decoded.z,
     decoder_bits=decoded.decoder_bits)
end
