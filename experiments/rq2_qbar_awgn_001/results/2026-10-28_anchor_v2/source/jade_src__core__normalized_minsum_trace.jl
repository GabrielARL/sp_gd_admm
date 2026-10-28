# Diagnostic representation of the deployed finite-sweep normalized min-sum
# equations. It does not change the receiver's decoder or its candidate rule.

struct _PackedMinSumRows{T,V<:AbstractVector{T}} <:
       AbstractVector{SubArray{T,1,V,Tuple{UnitRange{Int}},true}}
  values::V
  offsets::Vector{Int}
end

const _PackedMinSumMessages = _PackedMinSumRows{Float64,Vector{Float64}}

Base.IndexStyle(::Type{<:_PackedMinSumRows}) = IndexLinear()
Base.size(messages::_PackedMinSumRows) = (length(messages.offsets)-1,)
@inline function Base.getindex(messages::_PackedMinSumRows, check::Int)
  @boundscheck check in eachindex(messages) || throw(BoundsError(messages, check))
  @inbounds start = messages.offsets[check]
  @inbounds stop = messages.offsets[check+1]-1
  @view messages.values[start:stop]
end

function _minsum_message_offsets(check_vars)
  offsets = Vector{Int}(undef, length(check_vars)+1)
  offsets[1] = 1
  @inbounds for check in eachindex(check_vars)
    offsets[check+1] = offsets[check]+length(check_vars[check])
  end
  offsets
end

@inline _minsum_message_offsets(messages::_PackedMinSumRows) = messages.offsets

function _minsum_message_snapshot(messages, offsets)
  length(messages)+1 == length(offsets) ||
    throw(DimensionMismatch("min-sum message offsets differ from the graph"))
  values = Vector{Float64}(undef, offsets[end]-1)
  @inbounds for check in eachindex(messages)
    row = messages[check]
    length(row) == offsets[check+1]-offsets[check] ||
      throw(DimensionMismatch("min-sum message row differs from the graph"))
    copyto!(values, offsets[check], row, firstindex(row), length(row))
  end
  _PackedMinSumMessages(values, offsets)
end

function _minsum_message_snapshot(messages::_PackedMinSumMessages, offsets)
  messages.offsets == offsets ||
    throw(DimensionMismatch("min-sum message offsets differ from the graph"))
  _PackedMinSumMessages(copy(messages.values), offsets)
end

function _minsum_auxiliary_trace(m::Modulation, code::_Code, physical_llrs;
                                 message_block_k::Int=code.k)
  length(physical_llrs) == code.n ||
    throw(DimensionMismatch("one physical LLR is required per coded bit"))
  1 <= m.bp_iterations <= 1000 ||
    throw(ArgumentError("bp_iterations must be in 1:1000"))
  all(isfinite, physical_llrs) ||
    throw(ArgumentError("finite physical LLRs required"))

  # Joint-estimation receivers clip physical evidence before applying finite
  # inner-pilot clamps. Messages and posterior LLRs themselves are not clipped.
  applied = clamp.(Float64.(physical_llrs), -_LLR_CLIP, _LLR_CLIP)
  _apply_inner_clamps!(m, code, applied, message_block_k)

  message_offsets = _minsum_message_offsets(code.check_vars)
  edge_count = message_offsets[end]-1
  q_values = Vector{Float64}(undef, edge_count)
  @inbounds for check in eachindex(code.check_vars)
    start = message_offsets[check]-1
    for (edge, variable) in enumerate(code.check_vars[check])
      q_values[start+edge] = applied[variable]
    end
  end
  q = _PackedMinSumMessages(q_values, message_offsets)
  r = _PackedMinSumMessages(zeros(Float64, edge_count), message_offsets)
  posterior = copy(applied)
  bits = falses(code.n)
  q_before = _PackedMinSumMessages[]
  r_after = _PackedMinSumMessages[]
  q_after = _PackedMinSumMessages[]
  posterior_by_sweep = Vector{Vector{Float64}}()
  bits_by_sweep = BitVector[]
  syndrome_by_sweep = Int[]
  sizehint!(q_before, m.bp_iterations)
  sizehint!(r_after, m.bp_iterations)
  sizehint!(q_after, m.bp_iterations)
  sizehint!(posterior_by_sweep, m.bp_iterations)
  sizehint!(bits_by_sweep, m.bp_iterations)
  sizehint!(syndrome_by_sweep, m.bp_iterations)

  for _ in 1:m.bp_iterations
    push!(q_before, _minsum_message_snapshot(q, message_offsets))
    @inbounds for c in eachindex(code.check_vars)
      _bp_check_normalized_min_sum!(r[c], q[c])
    end
    push!(r_after, _minsum_message_snapshot(r, message_offsets))

    @inbounds for i in 1:code.n
      total = applied[i]
      for (c, a) in code.var_edges[i]
        position = message_offsets[c]+a-1
        total += r.values[position]
      end
      posterior[i] = total
      bits[i] = total < 0.0
      for (c, a) in code.var_edges[i]
        position = message_offsets[c]+a-1
        q.values[position] = total-r.values[position]
      end
    end
    push!(posterior_by_sweep, copy(posterior))
    push!(bits_by_sweep, copy(bits))
    push!(q_after, _minsum_message_snapshot(q, message_offsets))
    syndrome = _syndrome_weight(code, bits)
    push!(syndrome_by_sweep, syndrome)
    syndrome == 0 && break
  end

  iterations = length(syndrome_by_sweep)
  syndrome = last(syndrome_by_sweep)
  audit = m.decoder_audit
  if audit isa _SolverDecoderAudit
    edge_messages = edge_count*iterations
    audit.minsum_calls += 1
    audit.minsum_sweeps += iterations
    audit.check_to_variable_message_updates += edge_messages
    audit.variable_to_check_message_updates += edge_messages
  end
  (; applied, q_before, r_after, q_after, posterior_by_sweep,
     bits_by_sweep, syndrome_by_sweep, posterior=copy(posterior),
     extrinsic=posterior-applied, iterations, limit=m.bp_iterations,
     syndrome, valid=syndrome==0)
end

function _minsum_auxiliary_residuals(code::_Code, trace; audit=nothing)
  T = trace.iterations
  T == length(trace.q_before) == length(trace.r_after) ==
       length(trace.q_after) == length(trace.posterior_by_sweep) ==
       length(trace.bits_by_sweep) == length(trace.syndrome_by_sweep) ||
    throw(DimensionMismatch("auxiliary sweep arrays must have equal lengths"))
  length(trace.applied) == code.n ||
    throw(DimensionMismatch("auxiliary input differs from code length"))
  raw_audit = audit
  solver_audit = raw_audit isa _SolverDecoderAudit ? raw_audit : nothing
  solver_audit !== nothing && (solver_audit.certificate_calls += 1)

  initial = checks = posterior = variable = continuity = 0.0
  check_message_outputs = 0
  consistency_edge_checks = 0
  variable_edge_visits = 0
  extrinsic_ok = length(trace.posterior) == code.n == length(trace.extrinsic)
  if extrinsic_ok
    @inbounds for i in 1:code.n
      extrinsic_ok &= trace.extrinsic[i] == trace.posterior[i]-trace.applied[i]
    end
  end
  discrete_ok = 1 <= T <= trace.limit &&
    (trace.syndrome == 0 || T == trace.limit) &&
    trace.syndrome == last(trace.syndrome_by_sweep) &&
    trace.valid == (trace.syndrome == 0) &&
    trace.posterior == last(trace.posterior_by_sweep) &&
    extrinsic_ok &&
    all(trace.syndrome_by_sweep[t] != 0 for t in 1:T-1)
  expected_row = Float64[]
  sizehint!(expected_row, maximum(length, code.check_vars; init=0))

  for t in 1:T
    length(trace.q_before[t]) == length(code.check_vars) ==
      length(trace.r_after[t]) == length(trace.q_after[t]) ||
      throw(DimensionMismatch("auxiliary check arrays differ from graph"))
    length(trace.posterior_by_sweep[t]) == code.n ==
      length(trace.bits_by_sweep[t]) ||
      throw(DimensionMismatch("auxiliary variable arrays differ from graph"))
    for c in eachindex(code.check_vars)
      row = code.check_vars[c]
      length(trace.q_before[t][c]) == length(row) ==
        length(trace.r_after[t][c]) == length(trace.q_after[t][c]) ||
        throw(DimensionMismatch("auxiliary edge arrays differ from graph"))
      resize!(expected_row, length(row))
      _bp_check_normalized_min_sum!(expected_row, trace.q_before[t][c])
      check_message_outputs += length(row)
      for (a, i) in enumerate(row)
        consistency_edge_checks += 1
        checks = max(checks, abs(trace.r_after[t][c][a]-expected_row[a]))
        if t == 1
          initial = max(initial, abs(trace.q_before[t][c][a]-trace.applied[i]))
        else
          continuity = max(continuity,
            abs(trace.q_before[t][c][a]-trace.q_after[t-1][c][a]))
        end
      end
    end
    for i in 1:code.n
      total = trace.applied[i]
      for (c, a) in code.var_edges[i]
        variable_edge_visits += 1
        total += trace.r_after[t][c][a]
      end
      posterior = max(posterior,
        abs(trace.posterior_by_sweep[t][i]-total))
      discrete_ok &= trace.bits_by_sweep[t][i] ==
        (trace.posterior_by_sweep[t][i] < 0.0)
      for (c, a) in code.var_edges[i]
        variable_edge_visits += 1
        expected_message = trace.posterior_by_sweep[t][i]-trace.r_after[t][c][a]
        variable = max(variable,
          abs(trace.q_after[t][c][a]-expected_message))
      end
    end
    discrete_ok &= trace.syndrome_by_sweep[t] ==
      _syndrome_weight(code, trace.bits_by_sweep[t])
  end
  if solver_audit !== nothing
    solver_audit.certificate_check_message_outputs += check_message_outputs
    solver_audit.certificate_consistency_edge_checks += consistency_edge_checks
    solver_audit.certificate_variable_edge_visits += variable_edge_visits
  end
  fields = (initial, checks, posterior, variable, continuity)
  max_abs = all(isfinite, fields) && discrete_ok ? maximum(fields) : Inf
  (; max_abs, initial, checks, posterior, variable, continuity, discrete_ok)
end

# The two-argument check certifies only the message recurrence given its
# applied input. This overload also certifies the receiver's input preparation
# and configured sweep cap. The caller supplies the physical LLRs; this does
# not certify the channel calculation that produced them.
function _minsum_auxiliary_residuals(m::Modulation, code::_Code,
                                     physical_llrs, trace;
                                     message_block_k::Int=code.k)
  length(physical_llrs) == code.n ||
    throw(DimensionMismatch("one physical LLR is required per coded bit"))
  1 <= m.bp_iterations <= 1000 ||
    throw(ArgumentError("bp_iterations must be in 1:1000"))
  all(isfinite, physical_llrs) ||
    throw(ArgumentError("finite physical LLRs required"))

  expected = clamp.(Float64.(physical_llrs), -_LLR_CLIP, _LLR_CLIP)
  _apply_inner_clamps!(m, code, expected, message_block_k)
  raw_audit = m.decoder_audit
  audit = raw_audit isa _SolverDecoderAudit ? raw_audit : nothing
  recurrence = _minsum_auxiliary_residuals(code, trace; audit)
  input = 0.0
  @inbounds for i in eachindex(expected)
    input = max(input, abs(trace.applied[i]-expected[i]))
  end
  configured_limit_ok = trace.limit == m.bp_iterations
  max_abs = configured_limit_ok && isfinite(input) ?
    max(recurrence.max_abs, input) : Inf
  merge(recurrence, (; input, configured_limit_ok, max_abs))
end

function _minsum_auxiliary_target(trace; damping::Real=0.5,
                                  temperature::Real=1.0)
  isfinite(damping) && 0 <= damping <= 1 ||
    throw(ArgumentError("damping must be finite and in [0,1]"))
  isfinite(temperature) && temperature > 0 ||
    throw(ArgumentError("temperature must be finite and positive"))
  tanh.(clamp.(trace.applied .+ damping .* trace.extrinsic,
               -_LLR_CLIP, _LLR_CLIP) ./ (2temperature))
end
