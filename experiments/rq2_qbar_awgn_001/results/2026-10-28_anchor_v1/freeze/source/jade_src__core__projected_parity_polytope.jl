const _PROJECTED_PARITY_DEFAULTS = (
  iterations=40,
  step_size=0.05,
  parity_weight=4.0,
  softness=8.0,
  initial_temperature=4.0,
  output_scale=12.0,
)

@inline function _projected_parity_sigmoid(value::Float64)
  isfinite(value) || throw(ArgumentError("soft-projection input must be finite"))
  if value >= 0.0
    tail = exp(-value)
    return inv(1.0+tail)
  end
  head = exp(value)
  head/(1.0+head)
end

@inline function _projected_parity_active_facet(x, variables,
                                                 first_edge::Int,
                                                 last_edge::Int)
  selected_count = 0
  closest_edge = first_edge
  closest_distance = Inf
  @inbounds for edge in first_edge:last_edge
    value = x[variables[edge]]
    0.0 <= value <= 1.0 && isfinite(value) ||
      throw(ArgumentError("projected decoder coordinates must be finite and inside the bit box"))
    selected_count += value > 0.5
    distance = abs(value-0.5)
    if distance < closest_distance
      closest_distance = distance
      closest_edge = edge
    end
  end
  flip_closest = iseven(selected_count)
  if flip_closest
    selected_count += x[variables[closest_edge]] > 0.5 ? -1 : 1
  end
  violation = 1.0-selected_count
  @inbounds for edge in first_edge:last_edge
    selected = x[variables[edge]] > 0.5
    edge == closest_edge && flip_closest && (selected = !selected)
    violation += selected ? x[variables[edge]] : -x[variables[edge]]
  end
  (;closest_edge,flip_closest,violation)
end

@inline function _projected_parity_facet_sign(x, variables, edge::Int,
                                               closest_edge::Int,
                                               flip_closest::Bool)
  selected = x[variables[edge]] > 0.5
  edge == closest_edge && flip_closest && (selected = !selected)
  selected ? 1.0 : -1.0
end

function _projected_parity_validate_graph(offsets, variables, n::Integer)
  offsets isa AbstractVector && variables isa AbstractVector ||
    throw(ArgumentError("parity graph must use offset and variable vectors"))
  length(offsets) >= 2 || throw(ArgumentError("parity graph must contain a check"))
  all(value -> value isa Integer && !(value isa Bool),offsets) ||
    throw(ArgumentError("parity offsets must be integers"))
  all(value -> value isa Integer && !(value isa Bool),variables) ||
    throw(ArgumentError("parity variables must be integers"))
  offsets[1] == 1 && offsets[end] == length(variables)+1 ||
    throw(ArgumentError("parity offsets do not span the variable vector"))
  all(offset -> 1 <= offset <= length(variables)+1,offsets) ||
    throw(ArgumentError("parity offset lies outside the variable vector"))
  for check in 1:length(offsets)-1
    offsets[check] < offsets[check+1] ||
      throw(ArgumentError("parity checks must not be empty"))
  end
  for check in 1:length(offsets)-1
    for edge in offsets[check]:offsets[check+1]-1
      variable = variables[edge]
      1 <= variable <= n || throw(ArgumentError("parity variable lies outside the code"))
      for prior in offsets[check]:edge-1
        variables[prior] == variable &&
          throw(ArgumentError("parity check repeats a variable"))
      end
    end
  end
  nothing
end

"""
Accumulate the exact squared-hinge penalty gradient for the odd-set
inequalities of every even-parity check. Inside the unit box, at most one
odd-set inequality per check can have positive violation. The threshold set
and one closest-coordinate parity correction identify that inequality in
linear time in the Tanner-graph edges.
"""
function _projected_parity_penalty_gradient!(gradient::AbstractVector{Float64},
                                              x::AbstractVector{Float64},
                                              offsets::AbstractVector,
                                              variables::AbstractVector)
  length(gradient) == length(x) || throw(DimensionMismatch("gradient length differs"))
  fill!(gradient,0.0)
  penalty = 0.0
  active_checks = 0
  @inbounds for check in 1:length(offsets)-1
    first_edge = offsets[check]
    last_edge = offsets[check+1]-1
    facet = _projected_parity_active_facet(
      x,variables,first_edge,last_edge)
    violation = facet.violation
    if violation > 0.0
      active_checks += 1
      penalty += 0.5*violation^2
      for edge in first_edge:last_edge
        sign = _projected_parity_facet_sign(
          x,variables,edge,facet.closest_edge,facet.flip_closest)
        gradient[variables[edge]] += sign*violation
      end
    end
  end
  (;penalty,active_checks)
end

"""
Apply the Hessian of the squared odd-set penalty to `direction`. This is the
piecewise Hessian away from a zero violation or an active-facet tie. Each
strictly active check contributes `a*(a' * direction)`, where `a` is the
signed normal of its active odd-set inequality.
"""
function _projected_parity_penalty_hvp!(output::AbstractVector{Float64},
                                         x::AbstractVector{Float64},
                                         direction::AbstractVector{Float64},
                                         offsets::AbstractVector,
                                         variables::AbstractVector)
  length(output) == length(x) == length(direction) ||
    throw(DimensionMismatch("penalty Hessian-vector lengths differ"))
  fill!(output,0.0)
  active_checks = 0
  @inbounds for check in 1:length(offsets)-1
    first_edge = offsets[check]
    last_edge = offsets[check+1]-1
    facet = _projected_parity_active_facet(
      x,variables,first_edge,last_edge)
    facet.violation > 0.0 || continue
    active_checks += 1
    projection = 0.0
    for edge in first_edge:last_edge
      sign = _projected_parity_facet_sign(
        x,variables,edge,facet.closest_edge,facet.flip_closest)
      projection += sign*direction[variables[edge]]
    end
    for edge in first_edge:last_edge
      sign = _projected_parity_facet_sign(
        x,variables,edge,facet.closest_edge,facet.flip_closest)
      output[variables[edge]] += sign*projection
    end
  end
  (;active_checks)
end

function _projected_parity_syndrome!(hard::BitVector, x::Vector{Float64},
                                     offsets, variables)
  length(hard) == length(x) || throw(DimensionMismatch("hard decision length differs"))
  @inbounds for bit in eachindex(x)
    hard[bit] = x[bit] > 0.5
  end
  syndrome = 0
  @inbounds for check in 1:length(offsets)-1
    parity = false
    for edge in offsets[check]:offsets[check+1]-1
      parity = xor(parity,hard[variables[edge]])
    end
    syndrome += parity
  end
  syndrome
end

@inline function _projected_parity_retain_valid!(best_x, x, hard, channel,
                                                  syndrome, valid_found,
                                                  best_cost)
  syndrome == 0 || return valid_found,best_cost
  cost = 0.0
  @inbounds for bit in eachindex(hard)
    hard[bit] && (cost += channel[bit])
  end
  if !valid_found || cost < best_cost
    copyto!(best_x,x)
    return true,cost
  end
  valid_found,best_cost
end

function _projected_parity_request_vectors(request)
  required = (:intrinsic_llr_bit0,:parity_check_offsets,
    :parity_check_variables,:fixed_mask,:fixed_bits)
  all(field -> hasproperty(request,field),required) ||
    throw(ArgumentError("projected parity decoder request is incomplete"))
  likelihoods = request.intrinsic_llr_bit0
  likelihoods isa AbstractVector || throw(ArgumentError("intrinsic likelihoods must be a vector"))
  n = length(likelihoods)
  n > 0 || throw(ArgumentError("intrinsic likelihoods must not be empty"))
  channel = Vector{Float64}(undef,n)
  @inbounds for bit in eachindex(likelihoods)
    value = likelihoods[bit]
    value isa Real && !(value isa Bool) ||
      throw(ArgumentError("intrinsic likelihoods must be real numbers"))
    converted = try
      Float64(value)
    catch
      throw(ArgumentError("intrinsic likelihood lies outside Float64"))
    end
    isfinite(converted) || throw(ArgumentError("intrinsic likelihoods must be finite"))
    channel[bit] = converted
  end
  fixed_mask = request.fixed_mask
  fixed_bits = request.fixed_bits
  fixed_mask isa AbstractVector{Bool} && fixed_bits isa AbstractVector{Bool} &&
    length(fixed_mask) == n == length(fixed_bits) ||
    throw(ArgumentError("fixed-bit vectors differ from the code length"))
  offsets = request.parity_check_offsets
  variables = request.parity_check_variables
  _projected_parity_validate_graph(offsets,variables,n)
  @inbounds for check in 1:length(offsets)-1
    has_free = false
    parity = false
    for edge in offsets[check]:offsets[check+1]-1
      variable = variables[edge]
      has_free |= !fixed_mask[variable]
      fixed_mask[variable] && (parity = xor(parity,fixed_bits[variable]))
    end
    !has_free && parity &&
      throw(ArgumentError("fixed bits violate a parity check"))
  end
  (;channel,offsets,variables,fixed_mask,fixed_bits)
end

function _projected_parity_response(request, configuration)
  (;channel,offsets,variables,fixed_mask,fixed_bits) =
    _projected_parity_request_vectors(request)
  n = length(channel)
  x = Vector{Float64}(undef,n)
  gradient = zeros(Float64,n)
  parity_gradient = similar(gradient)
  hard = falses(n)
  best_x = similar(x)
  @inbounds for bit in 1:n
    x[bit] = _projected_parity_sigmoid(-channel[bit]/configuration.initial_temperature)
    fixed_mask[bit] && (x[bit] = fixed_bits[bit] ? 1.0 : 0.0)
  end

  best_cost = Inf
  valid_found = false
  syndrome = _projected_parity_syndrome!(hard,x,offsets,variables)
  valid_found,best_cost = _projected_parity_retain_valid!(
    best_x,x,hard,channel,syndrome,valid_found,best_cost)
  for _ in 1:configuration.iterations
    _projected_parity_penalty_gradient!(parity_gradient,x,offsets,variables)
    @inbounds for bit in 1:n
      if fixed_mask[bit]
        gradient[bit] = 0.0
      else
        gradient[bit] = channel[bit]+configuration.parity_weight*parity_gradient[bit]
      end
    end
    @inbounds for bit in 1:n
      if fixed_mask[bit]
        x[bit] = fixed_bits[bit] ? 1.0 : 0.0
      else
        proposal = x[bit]-configuration.step_size*gradient[bit]
        x[bit] = _projected_parity_sigmoid(
          configuration.softness*(proposal-0.5))
      end
    end
    syndrome = _projected_parity_syndrome!(hard,x,offsets,variables)
    valid_found,best_cost = _projected_parity_retain_valid!(
      best_x,x,hard,channel,syndrome,valid_found,best_cost)
  end
  valid_found && copyto!(x,best_x)

  posterior = Vector{Float64}(undef,n)
  correction = Vector{Float64}(undef,n)
  @inbounds for bit in 1:n
    posterior[bit] = clamp(configuration.output_scale*(1.0-2.0x[bit]),
      -_LLR_CLIP,_LLR_CLIP)
    correction[bit] = posterior[bit]-channel[bit]
  end
  metadata = (;iterations_requested=configuration.iterations,
    step_size=configuration.step_size,parity_weight=configuration.parity_weight,
    softness=configuration.softness,
    initial_temperature=configuration.initial_temperature,
    output_scale=configuration.output_scale,
    objective=:channel_linear_plus_squared_odd_set_violation,
    projection=:shifted_sigmoid_soft_projection,
    output=:scaled_bipolar_coordinate,
    deterministic=true,fixed_depth=true)
  (;posterior,applied_extrinsic=correction,iterations=configuration.iterations,
    method=:projected_parity_polytope,metadata)
end

function _projected_parity_adapter(;iterations=_PROJECTED_PARITY_DEFAULTS.iterations,
                                    step_size=_PROJECTED_PARITY_DEFAULTS.step_size,
                                    parity_weight=_PROJECTED_PARITY_DEFAULTS.parity_weight,
                                    softness=_PROJECTED_PARITY_DEFAULTS.softness,
                                    initial_temperature=_PROJECTED_PARITY_DEFAULTS.initial_temperature,
                                    output_scale=_PROJECTED_PARITY_DEFAULTS.output_scale)
  iterations isa Integer && !(iterations isa Bool) && 1 <= iterations <= 1000 ||
    throw(ArgumentError("projected parity iterations must be in 1:1000"))
  supplied = (step_size=step_size,parity_weight=parity_weight,
    softness=softness,initial_temperature=initial_temperature,
    output_scale=output_scale)
  all(value -> value isa Real && !(value isa Bool),values(supplied)) ||
    throw(ArgumentError("projected parity controls must be real numbers"))
  parameters = try
    (;(name => Float64(value) for (name,value) in pairs(supplied))...)
  catch
    throw(ArgumentError("projected parity control lies outside Float64"))
  end
  all(value -> isfinite(value) && value > 0,values(parameters)) ||
    throw(ArgumentError("projected parity controls must be finite and positive"))
  parameters.output_scale <= _LLR_CLIP ||
    throw(ArgumentError("projected parity output scale exceeds the likelihood limit"))
  configuration = (;iterations=Int(iterations),
    parameters...)
  request -> _projected_parity_response(request,configuration)
end

function _trainable_projected_parity_schedule(step_sizes, parity_weights,
                                               softness)
  step_sizes isa AbstractVector && parity_weights isa AbstractVector ||
    throw(ArgumentError("trainable projected-gradient coefficients must be vectors"))
  length(step_sizes) == length(parity_weights) > 0 ||
    throw(ArgumentError("trainable projected-gradient coefficient lengths differ or are empty"))
  converted_steps = try
    Float64.(step_sizes)
  catch
    throw(ArgumentError("projected-gradient step size lies outside Float64"))
  end
  converted_weights = try
    Float64.(parity_weights)
  catch
    throw(ArgumentError("projected-gradient parity coefficient lies outside Float64"))
  end
  softness isa Real && !(softness isa Bool) ||
    throw(ArgumentError("projected-gradient softness must be real"))
  converted_softness = try
    Float64(softness)
  catch
    throw(ArgumentError("projected-gradient softness lies outside Float64"))
  end
  all(value -> isfinite(value) && value > 0.0,converted_steps) ||
    throw(ArgumentError("projected-gradient step sizes must be finite and positive"))
  all(value -> isfinite(value) && value > 0.0,converted_weights) ||
    throw(ArgumentError("projected-gradient parity coefficients must be finite and positive"))
  isfinite(converted_softness) && converted_softness > 0.0 ||
    throw(ArgumentError("projected-gradient softness must be finite and positive"))
  (;step_sizes=converted_steps,parity_weights=converted_weights,
    softness=converted_softness)
end

function _trainable_projected_parity_schedule_from_logs(log_step_sizes,
                                                         log_parity_weights,
                                                         log_softness)
  all(isfinite,log_step_sizes) && all(isfinite,log_parity_weights) &&
    isfinite(log_softness) ||
    throw(ArgumentError("log projected-gradient coefficients must be finite"))
  _trainable_projected_parity_schedule(
    exp.(log_step_sizes),exp.(log_parity_weights),exp(log_softness))
end

function _trainable_projected_parity_validate_inputs(channel, initial,
                                                      offsets, variables)
  channel isa AbstractVector && initial isa AbstractVector ||
    throw(ArgumentError("channel statistic and initial point must be vectors"))
  length(channel) == length(initial) > 0 ||
    throw(DimensionMismatch("channel statistic and initial-point lengths differ or are empty"))
  converted_channel = try
    Float64.(channel)
  catch
    throw(ArgumentError("channel statistic lies outside Float64"))
  end
  converted_initial = try
    Float64.(initial)
  catch
    throw(ArgumentError("initial point lies outside Float64"))
  end
  all(isfinite,converted_channel) ||
    throw(ArgumentError("channel statistic must be finite"))
  all(value -> isfinite(value) && 0.0 <= value <= 1.0,converted_initial) ||
    throw(ArgumentError("initial point must be finite and inside the bit box"))
  _projected_parity_validate_graph(offsets,variables,length(converted_channel))
  (;channel=converted_channel,initial=converted_initial)
end

function _trainable_projected_parity_soft_state(channel, initial,
                                                 offsets, variables, schedule;
                                                 depth=length(schedule.step_sizes))
  vectors = _trainable_projected_parity_validate_inputs(
    channel,initial,offsets,variables)
  validated = _trainable_projected_parity_schedule(
    schedule.step_sizes,schedule.parity_weights,schedule.softness)
  depth isa Integer && !(depth isa Bool) && 1 <= depth <= length(validated.step_sizes) ||
    throw(ArgumentError("projected-gradient depth lies outside the schedule"))
  x = vectors.initial
  next_x = similar(x)
  parity_gradient = zeros(Float64,length(x))
  @inbounds for update in 1:Int(depth)
    _projected_parity_penalty_gradient!(
      parity_gradient,x,offsets,variables)
    step_size = validated.step_sizes[update]
    parity_weight = validated.parity_weights[update]
    softness = validated.softness
    for bit in eachindex(x)
      proposal = x[bit]-step_size*(
        vectors.channel[bit]+parity_weight*parity_gradient[bit])
      next_x[bit] = _projected_parity_sigmoid(
        softness*(proposal-0.5))
    end
    x,next_x = next_x,x
  end
  x
end

"""
Return the terminal squared loss and its analytical derivatives with respect
to the log step sizes, log parity coefficients, and shared log softness. The
hard parity test is deliberately absent from the differentiable training path.
"""
function _trainable_projected_parity_loss_gradient(channel, target, initial,
                                                    offsets, variables,
                                                    log_step_sizes,
                                                    log_parity_weights,
                                                    log_softness;
                                                    depth=length(log_step_sizes))
  vectors = _trainable_projected_parity_validate_inputs(
    channel,initial,offsets,variables)
  length(log_step_sizes) == length(log_parity_weights) > 0 ||
    throw(ArgumentError("log projected-gradient coefficient lengths differ or are empty"))
  depth isa Integer && !(depth isa Bool) && 1 <= depth <= length(log_step_sizes) ||
    throw(ArgumentError("projected-gradient depth lies outside the log schedule"))
  target isa AbstractVector && length(target) == length(vectors.channel) ||
    throw(DimensionMismatch("training target length differs from the channel statistic"))
  converted_target = try
    Float64.(target)
  catch
    throw(ArgumentError("training target lies outside Float64"))
  end
  all(value -> isfinite(value) && 0.0 <= value <= 1.0,converted_target) ||
    throw(ArgumentError("training target must be finite and inside the bit box"))
  schedule = _trainable_projected_parity_schedule_from_logs(
    log_step_sizes,log_parity_weights,log_softness)
  used_depth = Int(depth)
  n = length(vectors.channel)
  states = Matrix{Float64}(undef,n,used_depth+1)
  proposals = Matrix{Float64}(undef,n,used_depth)
  copyto!(@view(states[:,1]),vectors.initial)
  parity_gradient = zeros(Float64,n)
  @inbounds for update in 1:used_depth
    current = @view states[:,update]
    proposal = @view proposals[:,update]
    following = @view states[:,update+1]
    _projected_parity_penalty_gradient!(
      parity_gradient,current,offsets,variables)
    step_size = schedule.step_sizes[update]
    parity_weight = schedule.parity_weights[update]
    for bit in 1:n
      proposal[bit] = current[bit]-step_size*(
        vectors.channel[bit]+parity_weight*parity_gradient[bit])
      following[bit] = _projected_parity_sigmoid(
        schedule.softness*(proposal[bit]-0.5))
    end
  end

  terminal = @view states[:,used_depth+1]
  loss = 0.0
  adjoint = Vector{Float64}(undef,n)
  @inbounds for bit in 1:n
    residual = terminal[bit]-converted_target[bit]
    loss += residual^2
    adjoint[bit] = 2.0residual
  end
  log_step_gradient = zeros(Float64,length(log_step_sizes))
  log_weight_gradient = zeros(Float64,length(log_parity_weights))
  log_softness_gradient = 0.0
  sigmoid_adjoint = similar(adjoint)
  proposal_adjoint = similar(adjoint)
  penalty_hvp = similar(adjoint)
  @inbounds for update in used_depth:-1:1
    current = @view states[:,update]
    proposal = @view proposals[:,update]
    following = @view states[:,update+1]
    _projected_parity_penalty_gradient!(
      parity_gradient,current,offsets,variables)
    step_size = schedule.step_sizes[update]
    parity_weight = schedule.parity_weights[update]
    for bit in 1:n
      sigmoid_adjoint[bit] = adjoint[bit]*following[bit]*(1.0-following[bit])
      proposal_adjoint[bit] = schedule.softness*sigmoid_adjoint[bit]
    end
    softness_gradient = 0.0
    step_gradient = 0.0
    weight_gradient = 0.0
    for bit in 1:n
      softness_gradient += sigmoid_adjoint[bit]*(proposal[bit]-0.5)
      objective_gradient = vectors.channel[bit]+parity_weight*parity_gradient[bit]
      step_gradient -= proposal_adjoint[bit]*objective_gradient
      weight_gradient -= step_size*proposal_adjoint[bit]*parity_gradient[bit]
    end
    log_softness_gradient += schedule.softness*softness_gradient
    log_step_gradient[update] = step_size*step_gradient
    log_weight_gradient[update] = parity_weight*weight_gradient
    _projected_parity_penalty_hvp!(
      penalty_hvp,current,proposal_adjoint,offsets,variables)
    for bit in 1:n
      adjoint[bit] = proposal_adjoint[bit]-
        step_size*parity_weight*penalty_hvp[bit]
    end
  end
  (;loss,log_step_sizes=log_step_gradient,
    log_parity_weights=log_weight_gradient,
    log_softness=log_softness_gradient,
    initial=adjoint,terminal=copy(terminal))
end

@inline function _trainable_projected_parity_channel_cost(channel, hard)
  cost = 0.0
  @inbounds for bit in eachindex(hard)
    hard[bit] && (cost += channel[bit])
  end
  cost
end

"""
Decode from independent uniform random initial points with no directed-edge
likelihood state. The first syndrome-zero word is returned. When all starts
fail, return the visited hard word with the smallest syndrome, breaking ties
by the linear AWGN channel cost.
"""
function _trainable_projected_parity_decode(channel, offsets, variables,
                                            schedule;
                                            restarts::Integer=10,
                                            rng::AbstractRNG=Xoshiro(0))
  channel isa AbstractVector && !isempty(channel) ||
    throw(ArgumentError("channel statistic must be a nonempty vector"))
  converted_channel = try
    Float64.(channel)
  catch
    throw(ArgumentError("channel statistic lies outside Float64"))
  end
  all(isfinite,converted_channel) ||
    throw(ArgumentError("channel statistic must be finite"))
  _projected_parity_validate_graph(offsets,variables,length(converted_channel))
  validated = _trainable_projected_parity_schedule(
    schedule.step_sizes,schedule.parity_weights,schedule.softness)
  restarts isa Integer && !(restarts isa Bool) && restarts > 0 ||
    throw(ArgumentError("projected-gradient restart count must be positive"))

  n = length(converted_channel)
  x = Vector{Float64}(undef,n)
  next_x = similar(x)
  parity_gradient = zeros(Float64,n)
  hard = falses(n)
  best_hard = falses(n)
  best_x = zeros(Float64,n)
  best_syndrome = typemax(Int)
  best_cost = Inf
  total_updates = 0
  for restart in 1:Int(restarts)
    rand!(rng,x)
    for update in eachindex(validated.step_sizes)
      _projected_parity_penalty_gradient!(
        parity_gradient,x,offsets,variables)
      step_size = validated.step_sizes[update]
      parity_weight = validated.parity_weights[update]
      @inbounds for bit in 1:n
        proposal = x[bit]-step_size*(
          converted_channel[bit]+parity_weight*parity_gradient[bit])
        next_x[bit] = _projected_parity_sigmoid(
          validated.softness*(proposal-0.5))
      end
      x,next_x = next_x,x
      total_updates += 1
      syndrome = _projected_parity_syndrome!(hard,x,offsets,variables)
      cost = _trainable_projected_parity_channel_cost(converted_channel,hard)
      if syndrome < best_syndrome ||
          (syndrome == best_syndrome && cost < best_cost)
        best_syndrome = syndrome
        best_cost = cost
        copyto!(best_hard,hard)
        copyto!(best_x,x)
      end
      if syndrome == 0
        return (;hard=copy(hard),state=copy(x),valid=true,syndrome=0,
          channel_cost=cost,restarts_requested=Int(restarts),
          restarts_used=restart,updates=total_updates,
          termination=:first_valid)
      end
    end
  end
  (;hard=best_hard,state=best_x,valid=false,syndrome=best_syndrome,
    channel_cost=best_cost,restarts_requested=Int(restarts),
    restarts_used=Int(restarts),updates=total_updates,
    termination=:restart_budget_exhausted)
end
