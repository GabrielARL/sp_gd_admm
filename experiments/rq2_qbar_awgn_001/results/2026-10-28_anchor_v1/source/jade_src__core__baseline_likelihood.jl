# Optional QPSK likelihoods for the two baseline receivers.

_baseline_pilots_sufficient(m::Modulation, layout::_Layout) =
  _effective_baseline_likelihood(m) === :legacy || length(layout.pilot_idx) >= 3

function _baseline_pilot_variance(layout::_Layout, carriers)
  count = length(layout.pilot_idx)
  count >= 3 || throw(ArgumentError("pilot-variance likelihoods require at least three pilots per symbol"))
  errors = Vector{Float64}(undef, count)
  for held in 1:count
    k = layout.pilot_idx[held]
    x = layout.active_rank[k]
    response = zero(ComplexF64)
    factor = 2.0
    if held == 1
      response = carriers[layout.pilot_idx[2]] / layout.pilot_syms[2]
    elseif held == count
      response = carriers[layout.pilot_idx[count-1]] / layout.pilot_syms[count-1]
    else
      left_row, right_row = held-1, held+1
      left = layout.active_rank[layout.pilot_idx[left_row]]
      right = layout.active_rank[layout.pilot_idx[right_row]]
      a = (x-left) / (right-left)
      left_response = carriers[layout.pilot_idx[left_row]] / layout.pilot_syms[left_row]
      right_response = carriers[layout.pilot_idx[right_row]] / layout.pilot_syms[right_row]
      response = (1-a)*left_response + a*right_response
      factor = 1 + (1-a)^2 + a^2
    end
    predicted = response * layout.pilot_syms[held]
    errors[held] = abs2(carriers[k] - predicted) / factor
  end
  # Fixed all-pilot weights passed the predeclared real-channel comparison.
  # This effective variance can include response curvature and adaptive-fit
  # dependence; it is not an unbiased thermal-noise estimate for every channel.
  floor = max(eps(Float64), 1e-8 * mean(abs2, carriers[layout.active]))
  max(mean(errors), floor)
end

function _baseline_likelihood_metrics(m::Modulation, code::_Code, layouts, observations,
                                       mode::Symbol; diagnostics=nothing)
  mode = _baseline_frontend(mode)
  mode in (_MODE_STANDARD, _MODE_PFFT) || throw(ArgumentError("expected a baseline receiver"))
  m.bpc == 2 || throw(ArgumentError("pilot-variance likelihoods currently require QPSK"))
  mode === _MODE_PFFT && !_anchored_combiner(m) &&
    throw(ArgumentError("pilot-variance likelihoods require the anchored PFFT combiner"))
  length(layouts) == length(observations) > 0 ||
    throw(DimensionMismatch("one observation is required per OFDM symbol"))
  all(length(layout.pilot_idx) >= 3 for layout in layouts) ||
    throw(ArgumentError("pilot-variance likelihoods require at least three pilots per symbol"))
  all(size(parts) == (m.partial_fft_parts, Int(m.nc)) for parts in observations) ||
    throw(DimensionMismatch("observations must cover every branch and FFT carrier"))
  carriers = if mode === _MODE_STANDARD
    [_sum_branches(parts) for parts in observations]
  else
    weights = _frame_anchored_weights(m, layouts, observations; diagnostics)
    [vec(transpose(w) * parts) for (w, parts) in zip(weights, observations)]
  end
  _baseline_metrics_from_carriers(m, code, layouts, carriers)
end

function _baseline_metrics_from_carriers(m::Modulation, code::_Code, layouts, carriers)
  metrics = zeros(Float64, code.n)
  assigned = falses(code.n)
  variances = Float64[]
  pilot_mses = Float64[]
  for (layout, received) in zip(layouts, carriers)
    variance = _baseline_pilot_variance(layout, received)
    isfinite(variance) && variance > 0 || throw(ArgumentError("pilot variance must be positive and finite"))
    push!(variances, variance)
    positions = layout.active_rank[layout.pilot_idx]
    response = received[layout.pilot_idx] ./ layout.pilot_syms
    # Preserve the original diagnostic's meaning: variance is a separate field.
    equalized = _residual_pilot_equalize(m, layout, copy(received))
    push!(pilot_mses, _pilot_mse(layout, equalized))
    for (tone, k) in enumerate(layout.coded_idx)
      h = _interp_response(positions, response, layout.active_rank[k])
      # Negative values favor bit zero at the existing BP channel boundary.
      value = -2sqrt(2.0) * conj(h) * received[k] / variance
      for coordinate in 1:2
        bit = layout.bit_indices[coordinate, tone]
        if bit == 0 && coordinate == 2 && m.ldpc_scope === :block &&
            isodd(code.n) && tone == length(layout.coded_idx)
          continue # final QPSK quadrature is padding, not a codeword bit
        end
        1 <= bit <= code.n && !assigned[bit] ||
          throw(ArgumentError("carrier mapping must assign each codeword bit exactly once"))
        metrics[bit] = clamp(coordinate == 1 ? real(value) : imag(value), -_LLR_CLIP, _LLR_CLIP)
        assigned[bit] = true
      end
    end
  end
  all(assigned) || throw(ArgumentError("carrier mapping omitted codeword bits"))
  all(isfinite, metrics) || throw(ArgumentError("channel metrics must be finite"))
  (; metrics, pilot_mse=mean(pilot_mses), pilot_variance=variances)
end

function _baseline_likelihood_candidate(m::Modulation, code::_Code, layout::_Layout,
                                        observations, mode::Symbol)
  likelihood = _baseline_likelihood_metrics(m, code, [layout], [observations], mode)
  bp = _bp_decode(m, code, likelihood.metrics)
  if m.mode in _CALIBRATED_MODES && _baseline_frontend(m.mode) === _baseline_frontend(mode)
    m.receiver_trace === nothing && (m.receiver_trace = NamedTuple[])
    push!(m.receiver_trace, (; mode=m.mode, frontend=_baseline_frontend(mode),
      ldpc_scope=:block, ofdm_symbols=1, codewords=1, decoder_calls=1,
      decoder_valid=bp.valid, decoder_syndrome=bp.syndrome,
      fallback_used=false, bp_input=:channel_metrics,
      bp_iterations=m.bp_iterations, decoder_iterations=bp.iterations,
      baseline_likelihood=_effective_baseline_likelihood(m),
      pilot_variance=likelihood.pilot_variance, variance_combiner=:fixed))
    m.mode === _MODE_JOINT_CZ && (m.receiver_trace[end] = merge(m.receiver_trace[end],
      (;joint_cz_algorithm=:calibrated_standard)))
  end
  (; bp.lpost_metric, bp.valid, bp.syndrome, likelihood.pilot_mse)
end
