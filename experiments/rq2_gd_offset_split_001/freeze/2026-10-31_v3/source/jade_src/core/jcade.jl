# Jcade obtains BP-free hard decisions from the existing joint
# response-and-code projected-gradient state. The waveform, channel model,
# objective, solver, CFO screen, and candidate ordering remain unchanged.

function _jcade_objective_evaluations(trace, initial_step::Real)
  isfinite(initial_step) && initial_step > 0 ||
    throw(ArgumentError("Jcade step size must be finite and positive"))
  raw_refreshes = hasproperty(trace,:gradient_refreshes) ?
    trace.gradient_refreshes : 0
  raw_refreshes isa Integer && !(raw_refreshes isa Bool) ||
    throw(ArgumentError("Jcade trace contains an invalid gradient refresh count"))
  refreshes = Int(raw_refreshes)
  refreshes >= 0 ||
    throw(ArgumentError("Jcade trace contains negative gradient refreshes"))
  evaluations = 1+refreshes
  for step in trace.step_sizes
    isfinite(step) && step > 0 ||
      throw(ArgumentError("Jcade trace contains an invalid step"))
    backtrack = round(Int,log2(Float64(initial_step)/Float64(step)))
    0 <= backtrack <= 16 && step == initial_step*0.5^backtrack ||
      throw(ArgumentError("Jcade trace contains an unknown line-search step"))
    evaluations += backtrack+1
  end
  trace.status === :line_search_stalled && (evaluations += 17)
  evaluations
end

function _jcade_hard_result(problem, solved)
  hasproperty(solved,:state) && hasproperty(solved,:trace) ||
    throw(ArgumentError("Jcade solve result is incomplete"))
  state = solved.state
  hasproperty(state,:x) && length(state.x) == problem.code.n ||
    throw(DimensionMismatch("Jcade state differs from the code length"))
  length(problem.fixed) == length(state.x) == length(problem.fixed_bits) ||
    throw(DimensionMismatch("Jcade fixed-bit vectors differ"))
  all(isfinite,state.x) ||
    throw(ArgumentError("Jcade state contains non-finite bits"))
  bits = BitVector(undef,length(state.x))
  @inbounds for bit in eachindex(state.x)
    abs(state.x[bit]) <= 1+64eps(Float64) ||
      throw(ArgumentError("Jcade state lies outside the relaxed-bit box"))
    bits[bit] = state.x[bit] < 0.0
  end
  known_bits_valid = true
  @inbounds for bit in eachindex(problem.fixed)
    if problem.fixed[bit] && bits[bit] != problem.fixed_bits[bit]
      known_bits_valid = false
      break
    end
  end
  syndrome = _syndrome_weight(problem.code,bits)
  valid = syndrome == 0 && known_bits_valid
  lpost_metric = ifelse.(bits,1.0,-1.0)
  (;lpost_metric,bits,known_bits_valid,syndrome,valid)
end

function _jcade_candidate(m, code, layouts, observations;
    build_problem=m.mode === :joint_cwz ? _cwz_problem : _joint_cz_problem,
    acquire_candidates=nothing,
    initialize=m.mode === :joint_cwz ? _cwz_initial_state : _joint_cz_initial_state,
    solve_problem=m.mode === :joint_cwz ? _cwz_solve : _solve_joint_cz_projected_gradient,
    channel_llrs=m.mode === :joint_cwz ? _cwz_channel_llrs : _joint_cz_channel_llrs,
    payload_nbits=nothing)
  m.decoding_route === :jcade ||
    throw(ArgumentError("Jcade requires its dedicated solver strategy"))
  m.decoder_feedback_adapter === nothing ||
    throw(ArgumentError("Jcade cannot use a feedback adapter"))
  m.terminal_bp_decode &&
    throw(ArgumentError("Jcade cannot request terminal BP"))
  m.candidate_selection === :projected_gradient ||
    throw(ArgumentError("Jcade requires projected-gradient candidate selection"))
  if m.jcade_crc_early_exit
    payload_nbits isa Integer || throw(ArgumentError(
      "Jcade CRC early exit requires the payload bit count"))
    m.frame_crc_bits == 16 || throw(ArgumentError(
      "Jcade CRC early exit requires a 16-bit frame CRC"))
  end
  previous_audit = m.decoder_audit
  previous_audit === nothing ||
    throw(ArgumentError("nested receiver decoder audits are not supported"))
  strategy = m.decoding_route
  audit = _SolverDecoderAudit(;strategy)
  m.decoder_audit = audit

  function require_audit(label)
    m.decoder_audit === audit ||
      throw(ArgumentError("Jcade replaced decoder accounting during $label"))
    m.decoding_route === strategy ||
      throw(ArgumentError("Jcade strategy changed during $label"))
    audit.strategy === strategy ||
      throw(ArgumentError("Jcade changed decoder accounting strategy"))
    audit.bp_calls == 0 ||
      throw(ArgumentError("Jcade invoked an external BP decoder"))
    work = _joint_cz_decoder_message_work(audit)
    all(iszero,values(work)) ||
      throw(ArgumentError("Jcade invoked a min-sum message path"))
    nothing
  end

  function evaluate_acquisition(acquisition)
  zero_index = findfirst(candidate -> iszero(candidate.cfo),acquisition)
  zero_index === nothing &&
    throw(ArgumentError("Jcade requires a zero-CFO candidate"))
  order = sortperm(acquisition;by=candidate ->
    (candidate.pilot_score,abs(candidate.cfo),candidate.cfo))
  chosen = [zero_index;
    filter(!=(zero_index),order)[1:m.residual_cfo_keep_count-1]]
  _joint_cz_release_unretained_spectra!(acquisition,chosen)
  reference_pilot_score = acquisition[zero_index].pilot_score
  records = NamedTuple[]
  jcade_traces = NamedTuple[]
  optimized_indices = Int[]
  best = nothing

  early_exit_requested = false
  for index in chosen
    candidate = acquisition[index]
    if !_joint_cz_pilot_screen_passes(candidate.pilot_score,
        reference_pilot_score,reference_pilot_score)
      hasproperty(candidate,:full_ffts) && empty!(candidate.full_ffts)
      continue
    end
    problem = _joint_cz_materialize_candidate(
      m,code,layouts,observations,build_problem,candidate)
    problem.cfo == candidate.cfo && problem.pilot_score == candidate.pilot_score ||
      error("Jcade acquisition score differs from the retained problem")
    push!(optimized_indices,index)
    seed_state = initialize(problem,zeros(code.n))
    physical = channel_llrs(problem,seed_state)
    applied = clamp.(Float64.(physical),-_LLR_CLIP,_LLR_CLIP)
    _apply_inner_clamps!(m,code,applied)

    for temperature in m.relaxed_bit_initialization_temperatures
      temperature_value = Float64(temperature)
      initial = initialize(problem,
        tanh.(applied./(2temperature_value)))
      solved = solve_problem(problem,initial)
      require_audit("candidate solve")
      hard = _jcade_hard_result(problem,solved)
      candidate_crc_valid = m.jcade_crc_early_exit ?
        _frame_crc_valid_from_metrics(
          m,code,hard.lpost_metric,Int(payload_nbits)) : nothing
      early_exit_eligible = hard.valid && candidate_crc_valid === true
      score = _joint_cz_candidate_score(problem,hard.lpost_metric)
      response_change = sqrt(mean(abs2,solved.state.C-initial.C))
      bit_rms_change = sqrt(mean(abs2,solved.state.x-initial.x))
      objective_evaluations = _jcade_objective_evaluations(
        solved.trace,m.projected_gradient_step_size)
      candidate_index = length(records)+1
      record = (;candidate_index,cfo_subcarriers=problem.cfo,kind=:jcade,
        temperature=temperature_value,round=1,syndrome=hard.syndrome,
        known_bits_valid=hard.known_bits_valid,crc_valid=candidate_crc_valid,
        early_exit_eligible,score,
        pilot_score=problem.pilot_score,solver_status=solved.trace.status,
        solver_valid=hard.valid,response_change,bit_rms_change,
        accepted_steps=solved.trace.accepted_steps,
        steps_requested=solved.trace.steps_requested,
        objective_evaluations,admissible=true,satisfies_seed_guard=false)
      if m.mode === :joint_cwz
        record = merge(record,(;weight_phase_change=
          sqrt(mean(abs2,solved.state.theta-initial.theta))))
      end
      record = merge(record,(;admissible=
        _joint_cz_gradient_admissible(record,record)))
      push!(records,record)

      trace_record = (;candidate_index,cfo_subcarriers=problem.cfo,
        temperature=temperature_value,status=solved.trace.status,
        valid=hard.valid,syndrome=hard.syndrome,
        known_bits_valid=hard.known_bits_valid,
        crc_valid=candidate_crc_valid,early_exit_eligible,
        objective_evaluations,
        accepted_steps=solved.trace.accepted_steps,
        steps_requested=solved.trace.steps_requested,
        bit_rms_change=solved.trace.bit_rms_change,
        bit_sign_changes=solved.trace.bit_sign_changes,
        preconditioner=solved.trace.preconditioner,
        gradient_model=solved.trace.gradient_model,
        parity_gradient_initial_exponent=
          solved.trace.parity_gradient_initial_exponent,
        parity_gradient_terminal_exponent=
          solved.trace.parity_gradient_terminal_exponent,
        parity_gradient_warmup_steps=
          solved.trace.parity_gradient_warmup_steps,
        gradient_refreshes=solved.trace.gradient_refreshes,
        initial_objective=solved.trace.initial_objective,
        final_objective=solved.trace.final_objective,
        objective_history=copy(solved.trace.objective_history),
        step_sizes=copy(solved.trace.step_sizes),
        directional_derivatives=copy(solved.trace.directional_derivatives))
      push!(jcade_traces,trace_record)

      candidate = (;hard,problem,record,solved,index=candidate_index)
      if early_exit_eligible || best === nothing ||
          _joint_cz_gradient_prefer_candidate(record,best.record)
        best = candidate
      end
      if m.jcade_crc_early_exit && early_exit_eligible
        early_exit_requested = true
        break
      end
    end
    early_exit_requested && break
  end

  best === nothing && error("Jcade has no candidate passing its pilot screen")
  selected = best
  jcade_solver_calls = length(jcade_traces)
  jcade_solver_objective_evaluations =
    sum(trace -> trace.objective_evaluations,jcade_traces;init=0)
  jcade_solver_accepted_steps =
    sum(trace -> trace.accepted_steps,jcade_traces;init=0)
  valid_candidate_count = count(record -> record.solver_valid &&
    record.syndrome == 0 && record.known_bits_valid,records)
  jcade_solver_calls > 0 || error("Jcade performed no joint solve")
  jcade_solver_objective_evaluations >= jcade_solver_calls ||
    error("Jcade objective accounting differs")
  require_audit("trace emission")
  message_work = _joint_cz_decoder_message_work(audit)

  trace = (;mode=:joint_cz,joint_cz_algorithm=:projected_gradient,
    decoding_route=:jcade,
    ldpc_scope=m.ldpc_scope,ofdm_symbols=length(layouts),codewords=1,
    parameterization=:continuous_bipolar_bits,
    objective=m.parity_penalty_shape === :product ?
      :gaussian_residual_code_polynomial :
      m.parity_penalty_shape === :smoothed_signed_sqrt ?
      :gaussian_residual_smoothed_signed_sqrt_code :
      m.parity_penalty_shape === :violated_signed_sqrt ?
      :gaussian_residual_violated_signed_sqrt_code :
      :gaussian_residual_product_vertex_margin_code,
    likelihood=:pilot_variance,noise_model=:full_fft_diagonal,
    ici_half_width=m.joint_cz_ici_half_width,
    decoder_calls=0,decoder_iterations=0,
    feedback_calls=0,terminal_calls=0,
    feedback_method=:none,terminal_method=:none,
    feedback_bp_calls=0,terminal_bp_calls=0,total_bp_calls=audit.bp_calls,
    external_bp_calls=audit.bp_calls,feedback_minsum_calls=0,
    terminal_minsum_calls=0,total_minsum_calls=audit.minsum_calls,
    internal_normalized_minsum_calls=audit.minsum_calls,
    internal_normalized_minsum_sweeps=audit.minsum_sweeps,
    internal_forward_check_to_variable_message_updates=
      audit.check_to_variable_message_updates,
    internal_forward_variable_to_check_message_updates=
      audit.variable_to_check_message_updates,
    internal_forward_directed_message_updates=
      audit.check_to_variable_message_updates+
      audit.variable_to_check_message_updates,
    internal_message_work=message_work,
    message_work_accounting=:audited_decoder_entrypoints,
    decoder_audit_scope=:same_modem_receiver_core_decoder_entrypoints,
    adapter_source_review_required=false,
    legacy_bp_fallback_used=false,bp_free=true,message_passing=:none,
    output_source=:jcade_projected_gradient_word,
    output_metric_representation=:unit_hard_decision_bit1_positive,
    output_codeword_syndrome=selected.hard.syndrome,
    output_codeword_valid=selected.hard.valid,
    output_known_bits_valid=selected.hard.known_bits_valid,
    decoder_syndrome=selected.hard.syndrome,
    decoder_valid=selected.hard.valid,bp_iterations=nothing,
    bp_input=:none,feedback_input=:none,feedback=:none,
    selection=:pilot_screen_then_gradient_codeword,
    parameter_updates=m.projected_gradient_update_response && m.projected_gradient_update_bits ?
      :projected_gradient_descent : m.projected_gradient_update_response ?
      :response_only_gradient_descent : :bits_only_gradient_descent,
    initialization=:conditional_channel_likelihood,
    candidate_evaluation=m.jcade_crc_early_exit ?
      :crc_certified_early_exit : :all_configured_starts,
    jcade_crc_early_exit=m.jcade_crc_early_exit,
    configured_initialization_temperatures=
      collect(m.relaxed_bit_initialization_temperatures),
    evaluated_initialization_count=jcade_solver_calls,
    crc_early_exit_count=count(trace -> trace.early_exit_eligible,jcade_traces),
    reference_pilot_score,fallback_used=false,
    selected_candidate=selected.index,selected_kind=:jcade,
    selected_candidate_valid=selected.hard.valid,valid_candidate_count,
    selected_cfo_subcarriers=selected.problem.cfo,
    selected_temperature=selected.record.temperature,
    selected_solver_status=selected.record.solver_status,
    selected_response_change=selected.record.response_change,
    selected_bit_rms_change=selected.record.bit_rms_change,
    selected_accepted_steps=selected.record.accepted_steps,
    selected_objective_evaluations=selected.record.objective_evaluations,
    returned_cfo=:shared_acquisition_only,
    pilot_variance=selected.problem.variances .* selected.problem.scales.^2,
    acquisition_candidates=[(;cfo_subcarriers=candidate.cfo,
      pilot_score=candidate.pilot_score,retained=index in chosen,
      pilot_screen_passed=_joint_cz_pilot_screen_passes(candidate.pilot_score,
        reference_pilot_score,reference_pilot_score),
      optimized=index in optimized_indices)
      for (index,candidate) in enumerate(acquisition)],
    candidates=records,rounds=jcade_traces,
    accepted_steps=jcade_solver_accepted_steps,
    gradient_rounds=jcade_solver_calls,
    jcade_solver_calls,jcade_solver_objective_evaluations,
    jcade_solver_accepted_steps,
    jcade_solver_steps_requested=m.projected_gradient_steps,
    jcade_solver_step_size=m.projected_gradient_step_size,
    jcade_solver_parity_weight=m.parity_penalty_weight,
    jcade_solver_parity_shape=m.parity_penalty_shape,
    jcade_solver_parity_root_smoothing=m.parity_root_smoothing,
    jcade_solver_parity_preconditioner=m.parity_preconditioner,
    jcade_solver_parity_gradient=_joint_cz_parity_gradient_trace_model(m),
    jcade_solver_parity_gradient_exponent=m.parity_gradient_exponent,
    jcade_solver_parity_gradient_mix=m.parity_gradient_mix,
    jcade_solver_parity_gradient_scope=m.parity_gradient_scope,
    jcade_solver_parity_gradient_model=m.parity_gradient_model,
    jcade_solver_parity_gradient_regularization=
      m.parity_gradient_regularization,
    jcade_solver_parity_gradient_warmup_exponent=
      m.parity_gradient_warmup_exponent,
    jcade_solver_parity_gradient_warmup_steps=
      m.parity_gradient_warmup_steps,
    jcade_solver_parity_vertex_margin_mix=m.parity_vertex_margin_mix,
    jcade_solver_binary_weight=m.binary_penalty_weight,
    jcade_solver_trace=jcade_traces,
    parity_checks=length(code.check_vars))
  if m.mode === :joint_cwz
    trace = merge(trace,(;mode=:joint_cwz,
      objective=:gaussian_residual_code_polynomial_phase_anchor,
      noise_model=:unit_phase_full_fft_diagonal,
      combiner=:per_symbol_segment_phase,
      partial_fft_parts=m.partial_fft_parts,fixed_reference_segment=1,
      phase_anchor=m.cwz_phase_anchor,
      configured_update_weights=m.cwz_update_weights,
      update_weights=m.cwz_update_weights && m.partial_fft_parts > 1,
      selected_weight_phase_change=selected.record.weight_phase_change))
  end
  m.receiver_trace === nothing && (m.receiver_trace=NamedTuple[])
  push!(m.receiver_trace,trace)
  pilot_mse = mean(_pilot_mse(problem.layout,
    _residual_pilot_equalize(m,problem.layout,copy(problem.full_fft)))
    for problem in selected.problem.locals)
  (;lpost_metric=selected.hard.lpost_metric,valid=selected.hard.valid,
    syndrome=selected.hard.syndrome,pilot_mse)
  end

  try
    evaluate_acquisition(_joint_cz_candidate_acquisition(
      m,code,layouts,observations,build_problem,acquire_candidates))
  finally
    m.decoding_route = strategy
    m.decoder_audit = previous_audit
  end
end
