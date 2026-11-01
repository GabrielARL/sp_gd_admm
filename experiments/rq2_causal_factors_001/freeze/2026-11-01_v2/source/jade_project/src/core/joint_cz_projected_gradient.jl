# joint-CZ receiver uses the full FFT, whose noise is white for white noise at its
# time-sample input. Prior resampling can violate this approximation.
# Its banded response is independent of the redundant partial views.
# The continuous bipolar-bit and code-polynomial objective is a MAP
# relaxation, not a posterior likelihood or a globally optimal decoder.

function _joint_cz_product_parity(bipolar::AbstractVector{<:Real}, parity_sets)
  all(isfinite, bipolar) || throw(ArgumentError("parity values must be finite"))
  grad = zeros(Float64, length(bipolar))
  count = length(parity_sets)
  count == 0 && return (loss=0.0, gradient=grad)
  scale = 1.0 / count
  loss = 0.0
  prefix = Vector{Float64}(undef, maximum(length, parity_sets; init=0))
  for check in parity_sets
    product = 1.0
    for (position, bit) in enumerate(check)
      1 <= bit <= length(bipolar) ||
        throw(ArgumentError("parity index lies outside the codeword"))
      prefix[position] = product
      product *= bipolar[bit]
    end
    residual = 1.0 - product
    loss += scale * residual^2
    factor = -2.0 * scale * residual
    suffix = 1.0
    for position in length(check):-1:1
      bit = check[position]
      grad[bit] += factor * prefix[position] * suffix
      suffix *= bipolar[bit]
    end
  end
  (; loss, gradient=grad)
end

function _joint_cz_tempered_leave_one(value::Real, exponent::Real)
  isfinite(value) || throw(ArgumentError("leave-one parity product must be finite"))
  isfinite(exponent) && 0 < exponent <= 1 ||
    throw(ArgumentError("tempered parity exponent must lie in (0, 1]"))
  iszero(value) ? 0.0 : copysign(abs(Float64(value))^Float64(exponent),value)
end

@inline function _joint_cz_rational_softsign(value::Real,regularization::Real)
  Float64(value)*(1+Float64(regularization))/
    (abs(Float64(value))+Float64(regularization))
end

@inline function _joint_cz_regularized_power(
    value::Real,exponent::Real,regularization::Real)
  q = Float64(value)
  iszero(q) && return q
  epsilon = Float64(regularization)
  epsilon_squared = epsilon*epsilon
  q*((q*q+epsilon_squared)/(1+epsilon_squared))^
    ((Float64(exponent)-1)/2)
end

function _joint_cz_tempered_product_parity(
    bipolar::AbstractVector{<:Real}, parity_sets,
    exponent::Real, mix::Real, scope::Symbol=:all_checks,
    gradient_model::Symbol=:power, regularization::Real=0.02)
  all(isfinite,bipolar) || throw(ArgumentError("parity values must be finite"))
  isfinite(mix) && 0 < mix <= 1 ||
    throw(ArgumentError("tempered parity mix must lie in (0, 1]"))
  scope in (:all_checks,:violated_checks) ||
    throw(ArgumentError("unsupported tempered parity scope $scope"))
  gradient_model in (:power,:checkwise_normalized,:rational_softsign,
                     :regularized_power) ||
    throw(ArgumentError("unsupported parity-gradient model $gradient_model"))
  if gradient_model === :power
    isfinite(exponent) && 0 < exponent <= 1 ||
      throw(ArgumentError("tempered parity exponent must lie in (0, 1]"))
  elseif gradient_model === :regularized_power
    isfinite(exponent) && 0 < exponent < 1 || throw(ArgumentError(
      "regularized-power parity exponent must lie in (0, 1)"))
    scope === :violated_checks || throw(ArgumentError(
      "regularized-power parity requires violated-check scope"))
    isfinite(regularization) &&
      sqrt(floatmin(Float64)) <= regularization <= 1 ||
      throw(ArgumentError("parity-gradient regularization must lie in (0, 1]"))
  else
    exponent == 1 || throw(ArgumentError(
      "non-power parity gradient requires exponent one"))
    scope === :violated_checks || throw(ArgumentError(
      "non-power parity gradient requires violated-check scope"))
    isfinite(regularization) &&
      sqrt(floatmin(Float64)) <= regularization <= 1 ||
      throw(ArgumentError("parity-gradient regularization must lie in (0, 1]"))
  end
  grad = zeros(Float64,length(bipolar))
  count = length(parity_sets)
  count == 0 && return (loss=0.0,gradient=grad)
  scale = 1.0/count
  loss = 0.0
  prefix = Vector{Float64}(undef,maximum(length,parity_sets;init=0))
  for check in parity_sets
    product = 1.0
    for (position,bit) in enumerate(check)
      1 <= bit <= length(bipolar) ||
        throw(ArgumentError("parity index lies outside the codeword"))
      prefix[position] = product
      product *= bipolar[bit]
    end
    residual = 1.0-product
    loss += scale*residual^2
    coefficient = -2.0scale*residual
    temper_check = scope === :all_checks || product < 0
    if temper_check && gradient_model === :checkwise_normalized
      suffix = 1.0
      maximum_magnitude = 0.0
      for position in length(check):-1:1
        bit = check[position]
        leave_one_product = prefix[position]*suffix
        prefix[position] = leave_one_product
        maximum_magnitude = max(maximum_magnitude,abs(leave_one_product))
        suffix *= bipolar[bit]
      end
      gain = (1+Float64(regularization))/
        (maximum_magnitude+Float64(regularization))
      for (position,bit) in enumerate(check)
        leave_one_product = prefix[position]
        normalized = gain*leave_one_product
        blended = leave_one_product+mix*(normalized-leave_one_product)
        grad[bit] += coefficient*blended
      end
    else
      suffix = 1.0
      for position in length(check):-1:1
        bit = check[position]
        leave_one_product = prefix[position]*suffix
        blended = if temper_check
          tempered = if gradient_model === :power
            _joint_cz_tempered_leave_one(leave_one_product,exponent)
          elseif gradient_model === :rational_softsign
            _joint_cz_rational_softsign(leave_one_product,regularization)
          else
            _joint_cz_regularized_power(
              leave_one_product,exponent,regularization)
          end
          leave_one_product+mix*(tempered-leave_one_product)
        else
          leave_one_product
        end
        grad[bit] += coefficient*blended
        suffix *= bipolar[bit]
      end
    end
  end
  (;loss,gradient=grad)
end

@inline _joint_cz_nonnegative_sign(value::Real) = value < 0 ? -1.0 : 1.0

function _joint_cz_product_vertex_margin_parity(
    bipolar::AbstractVector{<:Real},parity_sets,mix::Real)
  all(isfinite,bipolar) || throw(ArgumentError("parity values must be finite"))
  isfinite(mix) && 0 < mix < 1 ||
    throw(ArgumentError("parity vertex-margin mix must lie in (0, 1)"))
  grad = zeros(Float64,length(bipolar))
  count = length(parity_sets)
  count == 0 && return (loss=0.0,gradient=grad)
  scale = 1.0/count
  product_scale = 1.0-Float64(mix)
  margin_scale = Float64(mix)
  loss = 0.0
  prefix = Vector{Float64}(undef,maximum(length,parity_sets;init=0))
  for check in parity_sets
    product = 1.0
    hard_product = 1.0
    weakest_bit = 0
    weakest_magnitude = Inf
    for (position,bit) in enumerate(check)
      1 <= bit <= length(bipolar) ||
        throw(ArgumentError("parity index lies outside the codeword"))
      value = Float64(bipolar[bit])
      prefix[position] = product
      product *= value
      hard_product *= _joint_cz_nonnegative_sign(value)
      magnitude = abs(value)
      if magnitude < weakest_magnitude
        weakest_magnitude = magnitude
        weakest_bit = bit
      end
    end
    residual = 1.0-product
    violated = hard_product < 0
    margin = violated ? 4weakest_magnitude : 0.0
    loss += scale*(product_scale*residual^2+margin_scale*margin)
    coefficient = -2.0scale*product_scale*residual
    suffix = 1.0
    for position in length(check):-1:1
      bit = check[position]
      grad[bit] += coefficient*prefix[position]*suffix
      suffix *= bipolar[bit]
    end
    if violated && weakest_bit > 0
      grad[weakest_bit] += 4.0scale*margin_scale*
        _joint_cz_nonnegative_sign(bipolar[weakest_bit])
    end
  end
  (;loss,gradient=grad)
end

function _joint_cz_signed_sqrt_value_derivative(product::Real, smoothing::Real)
  isfinite(product) || throw(ArgumentError("parity product must be finite"))
  isfinite(smoothing) && 0 < smoothing <= 1 ||
    throw(ArgumentError("parity-root smoothing must lie in (0, 1]"))
  radial = hypot(Float64(product),Float64(smoothing))
  normalization = sqrt(hypot(1.0,Float64(smoothing)))
  inverse_fourth_root = inv(sqrt(radial))
  normalized_product = Float64(product)/radial
  value = normalization*Float64(product)*inverse_fourth_root
  derivative = normalization*inverse_fourth_root*
    (1-0.5normalized_product^2)
  (; value, derivative)
end

function _joint_cz_violated_signed_sqrt_parameters(smoothing::Real)
  isfinite(smoothing) && 0 < smoothing <= 1 ||
    throw(ArgumentError("parity-root smoothing must lie in (0, 1]"))
  root_smoothing = sqrt(Float64(smoothing))
  normalization = sqrt(1.0+Float64(smoothing))+root_smoothing
  (; smoothing=Float64(smoothing),root_smoothing,normalization)
end

@inline function _joint_cz_violated_signed_sqrt_value_derivative(
    product::Real,parameters)
  isfinite(product) || throw(ArgumentError("parity product must be finite"))
  value = Float64(product)
  value >= 0 && return (value,derivative=1.0)
  radial = sqrt(parameters.smoothing-value)
  transformed = value*parameters.normalization/
    (radial+parameters.root_smoothing)
  derivative = parameters.normalization/(2radial)
  (;value=transformed,derivative)
end

function _joint_cz_violated_signed_sqrt_value_derivative(
    product::Real,smoothing::Real)
  _joint_cz_violated_signed_sqrt_value_derivative(product,
    _joint_cz_violated_signed_sqrt_parameters(smoothing))
end

function _joint_cz_signed_sqrt_parity(bipolar::AbstractVector{<:Real},
                                       parity_sets, smoothing::Real)
  all(isfinite,bipolar) || throw(ArgumentError("parity values must be finite"))
  grad = zeros(Float64,length(bipolar))
  curvature = zeros(Float64,length(bipolar))
  count = length(parity_sets)
  count == 0 && return (loss=0.0,gradient=grad,curvature)
  scale = 1.0/count
  loss = 0.0
  prefix = Vector{Float64}(undef,maximum(length,parity_sets;init=0))
  for check in parity_sets
    product = 1.0
    for (position,bit) in enumerate(check)
      1 <= bit <= length(bipolar) ||
        throw(ArgumentError("parity index lies outside the codeword"))
      prefix[position] = product
      product *= bipolar[bit]
    end
    transformed = _joint_cz_signed_sqrt_value_derivative(product,smoothing)
    residual = 1.0-transformed.value
    loss += scale*residual^2
    coefficient = -2.0*scale*residual*transformed.derivative
    suffix = 1.0
    for position in length(check):-1:1
      bit = check[position]
      leave_one_product = prefix[position]*suffix
      transformed_derivative = transformed.derivative*leave_one_product
      grad[bit] += coefficient*leave_one_product
      curvature[bit] += 2.0scale*transformed_derivative^2
      suffix *= bipolar[bit]
    end
  end
  (; loss,gradient=grad,curvature)
end

function _joint_cz_violated_signed_sqrt_parity(
    bipolar::AbstractVector{<:Real},parity_sets,smoothing::Real)
  all(isfinite,bipolar) || throw(ArgumentError("parity values must be finite"))
  parameters = _joint_cz_violated_signed_sqrt_parameters(smoothing)
  grad = zeros(Float64,length(bipolar))
  count = length(parity_sets)
  count == 0 && return (loss=0.0,gradient=grad)
  scale = 1.0/count
  loss = 0.0
  prefix = Vector{Float64}(undef,maximum(length,parity_sets;init=0))
  for check in parity_sets
    product = 1.0
    for (position,bit) in enumerate(check)
      1 <= bit <= length(bipolar) ||
        throw(ArgumentError("parity index lies outside the codeword"))
      prefix[position] = product
      product *= bipolar[bit]
    end
    transformed = _joint_cz_violated_signed_sqrt_value_derivative(
      product,parameters)
    residual = 1.0-transformed.value
    loss += scale*residual^2
    coefficient = -2.0scale*residual*transformed.derivative
    suffix = 1.0
    for position in length(check):-1:1
      bit = check[position]
      grad[bit] += coefficient*prefix[position]*suffix
      suffix *= bipolar[bit]
    end
  end
  (;loss,gradient=grad)
end

function _joint_cz_parity_product(bipolar::AbstractVector{<:Real}, parity_sets,
                                  shape::Symbol=:product,
                                  smoothing::Real=1e-6,
                                  gradient_exponent::Real=1.0,
                                  gradient_mix::Real=0.0,
                                  vertex_margin_mix::Real=0.0,
                                  gradient_scope::Symbol=:all_checks,
                                  gradient_model::Symbol=:power,
                                  gradient_regularization::Real=0.02)
  if shape === :product
    gradient_mix == 0 && gradient_exponent == 1 &&
      gradient_model === :power &&
      return _joint_cz_product_parity(bipolar,parity_sets)
    return _joint_cz_tempered_product_parity(
      bipolar,parity_sets,gradient_exponent,gradient_mix,gradient_scope,
      gradient_model,gradient_regularization)
  end
  shape === :product_vertex_margin && gradient_mix == 0 &&
    gradient_exponent == 1 && gradient_model === :power &&
    return _joint_cz_product_vertex_margin_parity(
      bipolar,parity_sets,vertex_margin_mix)
  shape === :smoothed_signed_sqrt && gradient_mix == 0 &&
    gradient_exponent == 1 && gradient_model === :power &&
    return _joint_cz_signed_sqrt_parity(bipolar,parity_sets,smoothing)
  shape === :violated_signed_sqrt && gradient_mix == 0 &&
    gradient_exponent == 1 && gradient_model === :power &&
    return _joint_cz_violated_signed_sqrt_parity(
      bipolar,parity_sets,smoothing)
  throw(ArgumentError("unsupported parity-penalty shape $shape"))
end

struct _JointCZParityPlan
  offsets::Vector{Int}
  variables::Vector{Int}
  fixed_product::Vector{Float64}
  fixed::BitVector
  fixed_values::Vector{Float64}
  nbits::Int
  max_degree::Int
end

struct _JointCZCodeWorkspace
  x::Vector{Float64}
  gradient::Vector{Float64}
  curvature::Union{Nothing,Vector{Float64}}
  prefix::Vector{Float64}
end

struct _JointCZObjectiveWorkspace
  code::_JointCZCodeWorkspace
  gradient_C::Array{ComplexF64,3}
  gradient_x::Vector{Float64}
  curvature_C::Array{Float64,3}
  curvature_x::Vector{Float64}
  symbols::Vector{ComplexF64}
  symbol_gradient::Vector{ComplexF64}
end

function _joint_cz_parity_plan(checks, fixed, fixed_bits)
  length(fixed) == length(fixed_bits) ||
    throw(DimensionMismatch("fixed-bit mask and values differ"))
  nbits = length(fixed)
  nbits > 0 || throw(ArgumentError("empty codeword"))
  offsets = Vector{Int}(undef,length(checks)+1)
  offsets[1] = 1
  variables = Int[]
  fixed_product = Vector{Float64}(undef,length(checks))
  fixed_values = zeros(Float64,nbits)
  for bit in eachindex(fixed)
    fixed[bit] && (fixed_values[bit] = _pm(fixed_bits[bit]))
  end
  max_degree = 0
  for (check_index,check) in enumerate(checks)
    product = 1.0
    degree = 0
    for bit in check
      1 <= bit <= nbits || throw(ArgumentError("parity index lies outside the codeword"))
      if fixed[bit]
        product *= fixed_values[bit]
      else
        push!(variables,bit)
        degree += 1
      end
    end
    fixed_product[check_index] = product
    offsets[check_index+1] = length(variables)+1
    max_degree = max(max_degree,degree)
  end
  _JointCZParityPlan(offsets,variables,fixed_product,BitVector(fixed),fixed_values,
    nbits,max_degree)
end

function _joint_cz_code_workspace(plan::_JointCZParityPlan,
                                  shape::Symbol=:product)
  shape in (:product,:smoothed_signed_sqrt,:violated_signed_sqrt,
            :product_vertex_margin) ||
    throw(ArgumentError("unsupported parity-penalty shape $shape"))
  curvature = shape === :smoothed_signed_sqrt ? zeros(plan.nbits) : nothing
  _JointCZCodeWorkspace(zeros(plan.nbits),zeros(plan.nbits),curvature,
    Vector{Float64}(undef,plan.max_degree))
end

function _joint_cz_objective_workspace(problem, state)
  size(state.C) == size(problem.C0) && length(state.x) == problem.nbits ||
    throw(DimensionMismatch("joint-CZ receiver parameter shape differs"))
  symbol_count = length(first(problem.locals).fixed_symbols)
  all(length(p.fixed_symbols) == symbol_count for p in problem.locals) ||
    throw(DimensionMismatch("joint-CZ receiver symbol workspaces differ"))
  _JointCZObjectiveWorkspace(
    _joint_cz_code_workspace(problem.parity_plan,
      problem.m.parity_penalty_shape),
    Array{ComplexF64}(undef,size(state.C)),
    Vector{Float64}(undef,length(state.x)),
    Array{Float64}(undef,size(state.C)),
    Vector{Float64}(undef,length(state.x)),
    Vector{ComplexF64}(undef,symbol_count),
    Vector{ComplexF64}(undef,symbol_count))
end

function _joint_cz_prepare_code_workspace!(workspace::_JointCZCodeWorkspace,x,
                                            plan::_JointCZParityPlan)
  length(x) == plan.nbits || throw(DimensionMismatch("relaxed codeword length differs"))
  length(workspace.x) == plan.nbits && length(workspace.gradient) == plan.nbits &&
    length(workspace.prefix) >= plan.max_degree ||
    throw(DimensionMismatch("code-gradient workspace shape differs"))
  all(isfinite,x) || throw(ArgumentError("finite relaxed bits required"))
  copyto!(workspace.x,x)
  @inbounds for bit in eachindex(plan.fixed)
    plan.fixed[bit] && (workspace.x[bit] = plan.fixed_values[bit])
  end
  fill!(workspace.gradient,0.0)
  workspace
end

function _joint_cz_add_binary_penalty!(workspace::_JointCZCodeWorkspace,
                                        plan::_JointCZParityPlan,
                                        binary_weight)
  binary = 0.0
  @inbounds for bit in eachindex(workspace.x)
    plan.fixed[bit] && continue
    value = workspace.x[bit]
    binary += binary_weight*(1-value^2)^2/plan.nbits
    workspace.gradient[bit] += 4binary_weight*value*(value^2-1)/plan.nbits
  end
  binary
end

function _joint_cz_product_code_gradient!(workspace::_JointCZCodeWorkspace,x,
                                           plan::_JointCZParityPlan,
                                           parity_weight,binary_weight)
  _joint_cz_prepare_code_workspace!(workspace,x,plan)
  count = length(plan.fixed_product)
  parity_loss = 0.0
  if count > 0
    scale = 1.0/count
    @inbounds for check_index in 1:count
      first_edge = plan.offsets[check_index]
      last_edge = plan.offsets[check_index+1]-1
      product = plan.fixed_product[check_index]
      position = 0
      for edge in first_edge:last_edge
        position += 1
        workspace.prefix[position] = product
        product *= workspace.x[plan.variables[edge]]
      end
      residual = 1.0-product
      parity_loss += scale*residual^2
      coefficient = -2.0*scale*residual
      suffix = 1.0
      for edge in last_edge:-1:first_edge
        bit = plan.variables[edge]
        workspace.gradient[bit] += coefficient*workspace.prefix[edge-first_edge+1]*suffix
        suffix *= workspace.x[bit]
      end
    end
  end
  factor = parity_weight*count/plan.nbits
  workspace.gradient .*= factor
  binary = _joint_cz_add_binary_penalty!(workspace,plan,binary_weight)
  (;loss=factor*parity_loss+binary,gradient=workspace.gradient,
    parity=factor*parity_loss,binary)
end

function _joint_cz_tempered_product_code_gradient!(
    workspace::_JointCZCodeWorkspace,x,plan::_JointCZParityPlan,
    parity_weight,binary_weight,gradient_exponent,gradient_mix,
    gradient_scope::Symbol=:all_checks,
    gradient_model::Symbol=:power,gradient_regularization::Real=0.02)
  isfinite(gradient_mix) && 0 < gradient_mix <= 1 ||
    throw(ArgumentError("tempered parity mix must lie in (0, 1]"))
  gradient_scope in (:all_checks,:violated_checks) ||
    throw(ArgumentError("unsupported tempered parity scope $gradient_scope"))
  gradient_model in (:power,:checkwise_normalized,:rational_softsign,
                     :regularized_power) ||
    throw(ArgumentError("unsupported parity-gradient model $gradient_model"))
  if gradient_model === :power
    isfinite(gradient_exponent) && 0 < gradient_exponent <= 1 ||
      throw(ArgumentError("tempered parity exponent must lie in (0, 1]"))
  elseif gradient_model === :regularized_power
    isfinite(gradient_exponent) && 0 < gradient_exponent < 1 ||
      throw(ArgumentError(
        "regularized-power parity exponent must lie in (0, 1)"))
    gradient_scope === :violated_checks || throw(ArgumentError(
      "regularized-power parity requires violated-check scope"))
    isfinite(gradient_regularization) &&
      sqrt(floatmin(Float64)) <= gradient_regularization <= 1 ||
      throw(ArgumentError(
        "parity-gradient regularization must lie in (0, 1]"))
  else
    gradient_exponent == 1 || throw(ArgumentError(
      "non-power parity gradient requires exponent one"))
    gradient_scope === :violated_checks || throw(ArgumentError(
      "non-power parity gradient requires violated-check scope"))
    isfinite(gradient_regularization) &&
      sqrt(floatmin(Float64)) <= gradient_regularization <= 1 ||
      throw(ArgumentError(
        "parity-gradient regularization must lie in (0, 1]"))
  end
  _joint_cz_prepare_code_workspace!(workspace,x,plan)
  count = length(plan.fixed_product)
  parity_loss = 0.0
  if count > 0
    scale = 1.0/count
    @inbounds for check_index in 1:count
      first_edge = plan.offsets[check_index]
      last_edge = plan.offsets[check_index+1]-1
      product = plan.fixed_product[check_index]
      position = 0
      for edge in first_edge:last_edge
        position += 1
        workspace.prefix[position] = product
        product *= workspace.x[plan.variables[edge]]
      end
      residual = 1.0-product
      parity_loss += scale*residual^2
      coefficient = -2.0scale*residual
      temper_check = gradient_scope === :all_checks || product < 0
      if temper_check && gradient_model === :checkwise_normalized
        suffix = 1.0
        maximum_magnitude = 0.0
        for edge in last_edge:-1:first_edge
          position = edge-first_edge+1
          bit = plan.variables[edge]
          leave_one_product = workspace.prefix[position]*suffix
          workspace.prefix[position] = leave_one_product
          maximum_magnitude = max(maximum_magnitude,abs(leave_one_product))
          suffix *= workspace.x[bit]
        end
        gain = (1+Float64(gradient_regularization))/
          (maximum_magnitude+Float64(gradient_regularization))
        for edge in first_edge:last_edge
          bit = plan.variables[edge]
          leave_one_product = workspace.prefix[edge-first_edge+1]
          normalized = gain*leave_one_product
          blended = leave_one_product+
            gradient_mix*(normalized-leave_one_product)
          workspace.gradient[bit] += coefficient*blended
        end
      else
        suffix = 1.0
        for edge in last_edge:-1:first_edge
          bit = plan.variables[edge]
          leave_one_product = workspace.prefix[edge-first_edge+1]*suffix
          blended = if temper_check
            tempered = if gradient_model === :power
              _joint_cz_tempered_leave_one(
                leave_one_product,gradient_exponent)
            elseif gradient_model === :rational_softsign
              _joint_cz_rational_softsign(
                leave_one_product,gradient_regularization)
            else
              _joint_cz_regularized_power(leave_one_product,
                gradient_exponent,gradient_regularization)
            end
            leave_one_product+gradient_mix*(tempered-leave_one_product)
          else
            leave_one_product
          end
          workspace.gradient[bit] += coefficient*blended
          suffix *= workspace.x[bit]
        end
      end
    end
  end
  factor = parity_weight*count/plan.nbits
  workspace.gradient .*= factor
  binary = _joint_cz_add_binary_penalty!(workspace,plan,binary_weight)
  (;loss=factor*parity_loss+binary,gradient=workspace.gradient,
    parity=factor*parity_loss,binary)
end

function _joint_cz_product_vertex_margin_code_gradient!(
    workspace::_JointCZCodeWorkspace,x,plan::_JointCZParityPlan,
    parity_weight,binary_weight,margin_mix)
  isfinite(margin_mix) && 0 < margin_mix < 1 ||
    throw(ArgumentError("parity vertex-margin mix must lie in (0, 1)"))
  _joint_cz_prepare_code_workspace!(workspace,x,plan)
  workspace.curvature === nothing ||
    throw(DimensionMismatch("vertex-margin workspace unexpectedly has curvature"))
  count = length(plan.fixed_product)
  parity_loss = 0.0
  product_scale = 1.0-Float64(margin_mix)
  margin_scale = Float64(margin_mix)
  if count > 0
    scale = 1.0/count
    @inbounds for check_index in 1:count
      first_edge = plan.offsets[check_index]
      last_edge = plan.offsets[check_index+1]-1
      product = plan.fixed_product[check_index]
      hard_product = plan.fixed_product[check_index]
      weakest_edge = 0
      weakest_magnitude = Inf
      position = 0
      for edge in first_edge:last_edge
        position += 1
        bit = plan.variables[edge]
        value = workspace.x[bit]
        workspace.prefix[position] = product
        product *= value
        hard_product *= _joint_cz_nonnegative_sign(value)
        magnitude = abs(value)
        if magnitude < weakest_magnitude
          weakest_magnitude = magnitude
          weakest_edge = edge
        end
      end
      residual = 1.0-product
      violated = hard_product < 0
      margin = if violated
        weakest_edge == 0 ? 4.0 : 4weakest_magnitude
      else
        0.0
      end
      parity_loss += scale*(product_scale*residual^2+margin_scale*margin)
      coefficient = -2.0scale*product_scale*residual
      suffix = 1.0
      for edge in last_edge:-1:first_edge
        bit = plan.variables[edge]
        workspace.gradient[bit] +=
          coefficient*workspace.prefix[edge-first_edge+1]*suffix
        suffix *= workspace.x[bit]
      end
      if violated && weakest_edge > 0
        bit = plan.variables[weakest_edge]
        workspace.gradient[bit] += 4.0scale*margin_scale*
          _joint_cz_nonnegative_sign(workspace.x[bit])
      end
    end
  end
  factor = parity_weight*count/plan.nbits
  workspace.gradient .*= factor
  binary = _joint_cz_add_binary_penalty!(workspace,plan,binary_weight)
  (;loss=factor*parity_loss+binary,gradient=workspace.gradient,
    parity=factor*parity_loss,binary)
end

function _joint_cz_signed_sqrt_code_gradient!(workspace::_JointCZCodeWorkspace,x,
                                               plan::_JointCZParityPlan,
                                               parity_weight,binary_weight,
                                               smoothing)
  _joint_cz_prepare_code_workspace!(workspace,x,plan)
  curvature = workspace.curvature
  curvature isa Vector{Float64} && length(curvature) == plan.nbits ||
    throw(DimensionMismatch("signed-root curvature workspace shape differs"))
  fill!(curvature,0.0)
  isfinite(smoothing) && 0 < smoothing <= 1 ||
    throw(ArgumentError("parity-root smoothing must lie in (0, 1]"))
  count = length(plan.fixed_product)
  parity_loss = 0.0
  if count > 0
    scale = 1.0/count
    @inbounds for check_index in 1:count
      first_edge = plan.offsets[check_index]
      last_edge = plan.offsets[check_index+1]-1
      product = plan.fixed_product[check_index]
      position = 0
      for edge in first_edge:last_edge
        position += 1
        workspace.prefix[position] = product
        product *= workspace.x[plan.variables[edge]]
      end
      transformed = _joint_cz_signed_sqrt_value_derivative(product,smoothing)
      residual = 1.0-transformed.value
      parity_loss += scale*residual^2
      coefficient = -2.0*scale*residual*transformed.derivative
      suffix = 1.0
      for edge in last_edge:-1:first_edge
        bit = plan.variables[edge]
        leave_one_product = workspace.prefix[edge-first_edge+1]*suffix
        transformed_derivative = transformed.derivative*leave_one_product
        workspace.gradient[bit] += coefficient*leave_one_product
        curvature[bit] += 2.0scale*transformed_derivative^2
        suffix *= workspace.x[bit]
      end
    end
  end
  factor = parity_weight*count/plan.nbits
  workspace.gradient .*= factor
  curvature .*= factor
  binary = _joint_cz_add_binary_penalty!(workspace,plan,binary_weight)
  @inbounds for bit in eachindex(curvature)
    plan.fixed[bit] || (curvature[bit] += 8binary_weight/plan.nbits)
  end
  (;loss=factor*parity_loss+binary,gradient=workspace.gradient,
    curvature,parity=factor*parity_loss,binary)
end

function _joint_cz_violated_signed_sqrt_code_gradient!(
    workspace::_JointCZCodeWorkspace,x,plan::_JointCZParityPlan,
    parity_weight,binary_weight,smoothing)
  _joint_cz_prepare_code_workspace!(workspace,x,plan)
  workspace.curvature === nothing ||
    throw(DimensionMismatch("violated-root workspace unexpectedly has curvature"))
  parameters = _joint_cz_violated_signed_sqrt_parameters(smoothing)
  count = length(plan.fixed_product)
  parity_loss = 0.0
  if count > 0
    scale = 1.0/count
    @inbounds for check_index in 1:count
      first_edge = plan.offsets[check_index]
      last_edge = plan.offsets[check_index+1]-1
      product = plan.fixed_product[check_index]
      position = 0
      for edge in first_edge:last_edge
        position += 1
        workspace.prefix[position] = product
        product *= workspace.x[plan.variables[edge]]
      end
      transformed = _joint_cz_violated_signed_sqrt_value_derivative(
        product,parameters)
      residual = 1.0-transformed.value
      parity_loss += scale*residual^2
      coefficient = -2.0scale*residual*transformed.derivative
      suffix = 1.0
      for edge in last_edge:-1:first_edge
        bit = plan.variables[edge]
        leave_one_product = workspace.prefix[edge-first_edge+1]*suffix
        workspace.gradient[bit] += coefficient*leave_one_product
        suffix *= workspace.x[bit]
      end
    end
  end
  factor = parity_weight*count/plan.nbits
  workspace.gradient .*= factor
  binary = _joint_cz_add_binary_penalty!(workspace,plan,binary_weight)
  (;loss=factor*parity_loss+binary,gradient=workspace.gradient,
    parity=factor*parity_loss,binary)
end

function _joint_cz_code_gradient!(workspace::_JointCZCodeWorkspace,x,
                                   plan::_JointCZParityPlan,
                                   parity_weight,binary_weight,
                                   shape::Symbol=:product,
                                   smoothing::Real=1e-6,
                                   gradient_exponent::Real=1.0,
                                   gradient_mix::Real=0.0,
                                   vertex_margin_mix::Real=0.0,
                                   gradient_scope::Symbol=:all_checks,
                                   gradient_model::Symbol=:power,
                                   gradient_regularization::Real=0.02)
  if shape === :product
    gradient_mix == 0 && gradient_exponent == 1 &&
      gradient_model === :power &&
      return _joint_cz_product_code_gradient!(
        workspace,x,plan,parity_weight,binary_weight)
    return _joint_cz_tempered_product_code_gradient!(workspace,x,plan,
      parity_weight,binary_weight,gradient_exponent,gradient_mix,
      gradient_scope,gradient_model,gradient_regularization)
  end
  shape === :smoothed_signed_sqrt && gradient_mix == 0 &&
    gradient_exponent == 1 && gradient_model === :power &&
    return _joint_cz_signed_sqrt_code_gradient!(
    workspace,x,plan,parity_weight,binary_weight,smoothing)
  shape === :violated_signed_sqrt && gradient_mix == 0 &&
    gradient_exponent == 1 && gradient_model === :power &&
    return _joint_cz_violated_signed_sqrt_code_gradient!(workspace,x,plan,
      parity_weight,binary_weight,smoothing)
  shape === :product_vertex_margin && gradient_mix == 0 &&
    gradient_exponent == 1 && gradient_model === :power &&
    return _joint_cz_product_vertex_margin_code_gradient!(workspace,x,plan,
      parity_weight,binary_weight,vertex_margin_mix)
  throw(ArgumentError("unsupported parity-penalty shape $shape"))
end

function _joint_cz_local_problem(m::Modulation, code::_Code, layout::_Layout,
                                  full_fft; ici_half_width::Integer=m.joint_cz_ici_half_width,
                                  frame_slice::Bool=false)
  N = Int(m.nc)
  length(full_fft) == N || throw(DimensionMismatch("joint-CZ receiver local observation must cover every carrier"))
  all(isfinite, full_fft) || throw(ArgumentError("joint-CZ receiver observations must be finite"))
  0 <= ici_half_width < N || throw(ArgumentError("ICI half-width must lie between zero and N-1"))
  nt = frame_slice ? length(layout.coded_idx) : _ndata_tones(m, code.n)
  nt <= length(layout.coded_idx) || throw(DimensionMismatch("the code does not fit the carrier layout"))

  active_slots = zeros(Int, N)
  symbol_slots = zeros(Int, N)
  fixed_symbols = zeros(ComplexF64, N)
  for (slot, k) in enumerate(layout.active)
    active_slots[k] = slot
    fixed_symbols[k] = m.pilot_placement === :before_encoding ? zero(ComplexF64) : one(ComplexF64)
  end
  for (slot, k) in enumerate(@view layout.coded_idx[1:nt])
    symbol_slots[k] = slot
    fixed_symbols[k] = zero(ComplexF64)
  end
  for (k, pilot) in zip(layout.pilot_idx, layout.pilot_syms)
    fixed_symbols[k] = pilot
  end

  inner_mask = falses(code.n)
  inner_bits = falses(code.n)
  for position in _message_pilot_positions(m, code.k)
    bit = code.invperm[code.n - code.k + position]
    inner_mask[bit] = true
    inner_bits[bit] = _known_inner_bit(m, position)
  end

  offsets = collect(-Int(ici_half_width):Int(ici_half_width))
  neighbors = zeros(Int, length(offsets), N)
  for k in layout.active, (d, offset) in enumerate(offsets)
    q = k + offset
    if 1 <= q <= N && active_slots[q] > 0
      neighbors[d, k] = q
    end
  end

  received = ComplexF64.(full_fft)
  pilot_response = received[layout.pilot_idx] ./ layout.pilot_syms
  pilot_positions = layout.active_rank[layout.pilot_idx]
  h0 = ComplexF64[
    _interp_response(pilot_positions, pilot_response, layout.active_rank[k])
    for k in layout.active
  ]

  smooth_edges = Tuple{Int,Int}[]
  for k in layout.active
    k < N && active_slots[k+1] > 0 &&
      push!(smooth_edges, (active_slots[k], active_slots[k+1]))
  end

  (; m, code, layout, active=copy(layout.active), active_slots, symbol_slots,
     fixed_symbols, pilot_idx=copy(layout.pilot_idx),
     data_idx=layout.coded_idx[1:nt], bit_indices=layout.bit_indices[:, 1:nt],
     inner_mask, inner_bits, fixed_mask=inner_mask, fixed_bits=inner_bits,
     ici_half_width=Int(ici_half_width), offsets, neighbor_idx=neighbors,
     full_fft=received, h0, smooth_edges)
end

function _joint_cz_code_gradient(x, checks, fixed, parity_weight, binary_weight,
                                 shape::Symbol=:product,
                                 smoothing::Real=1e-6,
                                 gradient_exponent::Real=1.0,
                                 gradient_mix::Real=0.0,
                                 vertex_margin_mix::Real=0.0,
                                 gradient_scope::Symbol=:all_checks,
                                 gradient_model::Symbol=:power,
                                 gradient_regularization::Real=0.02)
  length(x) == length(fixed) || throw(DimensionMismatch("fixed-bit mask differs"))
  all(isfinite, x) || throw(ArgumentError("finite relaxed bits required"))
  n = length(x)
  n > 0 || throw(ArgumentError("empty codeword"))
  if shape === :product_vertex_margin ||
      (shape === :product && gradient_model === :checkwise_normalized)
    fixed_bits = BitVector(value < 0 for value in x)
    plan = _joint_cz_parity_plan(checks,fixed,fixed_bits)
    workspace = _joint_cz_code_workspace(plan,shape)
    evaluated = _joint_cz_code_gradient!(workspace,x,plan,parity_weight,
      binary_weight,shape,smoothing,gradient_exponent,gradient_mix,
      vertex_margin_mix,gradient_scope,gradient_model,
      gradient_regularization)
    return merge(evaluated,(;gradient=copy(evaluated.gradient)))
  end
  parity = _joint_cz_parity_product(x,checks,shape,smoothing,
    gradient_exponent,gradient_mix,vertex_margin_mix,gradient_scope,
    gradient_model,gradient_regularization)
  factor = parity_weight * length(checks) / n
  gradient = factor .* parity.gradient
  curvature = shape === :smoothed_signed_sqrt ? factor .* parity.curvature : nothing
  binary = 0.0
  for i in eachindex(x)
    fixed[i] && continue
    binary += binary_weight * (1-x[i]^2)^2 / n
    gradient[i] += 4binary_weight * x[i] * (x[i]^2-1) / n
    curvature === nothing || (curvature[i] += 8binary_weight/n)
  end
  gradient[fixed] .= 0.0
  curvature === nothing || (curvature[fixed] .= 0.0)
  curvature === nothing ?
    (;loss=factor*parity.loss+binary,gradient,
      parity=factor*parity.loss,binary) :
    (;loss=factor*parity.loss+binary,gradient,curvature,
      parity=factor*parity.loss,binary)
end

function _joint_cz_validate_problem_inputs(m, layouts, observations)
  length(layouts) == length(observations) > 0 || throw(DimensionMismatch("one observation per symbol required"))
  all(length(l.pilot_idx) >= 3 for l in layouts) || throw(ArgumentError("joint-CZ receiver needs at least three pilots per symbol"))
  N = Int(m.nc)
  all(size(y) == (m.partial_fft_parts,N) && all(isfinite,y) for y in observations) ||
    throw(ArgumentError("finite partial FFT observations with the configured dimensions required"))
  N
end

function _joint_cz_full_fft(m, observation, symbol::Integer, cfo::Real)
  N = Int(m.nc)
  full = _sum_branches(observation)
  if !iszero(cfo)
    times = ((symbol-1)*_blocklen(m)+Int(m.np)) .+ (0:N-1)
    full = fft(ifft(full) .* cis.(-2pi*cfo .* times ./ N))
  end
  full
end

function _joint_cz_full_fft_from_time(m, base_time::Vector{ComplexF64},
                                      symbol::Integer, cfo::Real)
  N = Int(m.nc)
  times = ((symbol-1)*_blocklen(m)+Int(m.np)) .+ (0:N-1)
  fft(base_time .* cis.(-2pi*cfo .* times ./ N))
end

function _joint_cz_acquisition_candidates(m, layouts, observations)
  N = _joint_cz_validate_problem_inputs(m,layouts,observations)
  candidate_type = NamedTuple{
    (:cfo,:pilot_score,:full_ffts),
    Tuple{Float64,Float64,Vector{Vector{ComplexF64}}}}
  candidates = Vector{candidate_type}(undef,length(m.residual_cfo_candidates))
  pilot_scores = Vector{Float64}(undef,length(layouts))
  base_full_ffts = map(_sum_branches,observations)
  all(full -> all(isfinite,full),base_full_ffts) ||
    throw(ArgumentError("joint-CZ receiver observations must be finite"))
  base_times = map(ifft,base_full_ffts)
  unused_zero_full_fft = true
  for (candidate_index,cfo) in enumerate(m.residual_cfo_candidates)
    isfinite(cfo) && abs(cfo) < N/2 ||
      throw(ArgumentError("invalid residual carrier offset"))
    full_ffts = if iszero(cfo)
      spectra = unused_zero_full_fft ? collect(base_full_ffts) :
        map(copy,base_full_ffts)
      unused_zero_full_fft = false
      spectra
    else
      map(eachindex(layouts)) do symbol
        _joint_cz_full_fft_from_time(m,base_times[symbol],symbol,cfo)
      end
    end
    for symbol in eachindex(layouts)
      full = full_ffts[symbol]
      all(isfinite,full) ||
        throw(ArgumentError("joint-CZ receiver observations must be finite"))
      layout = layouts[symbol]
      variance = _baseline_pilot_variance(layout,full)
      pilot_scores[symbol] = variance/max(
        mean(abs2,full[layout.pilot_idx]),eps(Float64))
    end
    candidates[candidate_index] =
      (;cfo=Float64(cfo),pilot_score=mean(pilot_scores),full_ffts)
  end
  candidates
end

function _joint_cz_problem_from_full_ffts(m, code, layouts, full_ffts; cfo=0.0)
  length(layouts) == length(full_ffts) > 0 ||
    throw(DimensionMismatch("one full FFT per symbol required"))
  N = Int(m.nc)
  all(length(full) == N && all(isfinite,full) for full in full_ffts) ||
    throw(ArgumentError("finite full FFT observations with the configured length required"))
  S, K = length(layouts), m.joint_cz_ici_half_width
  isfinite(cfo) && abs(cfo) < N/2 || throw(ArgumentError("invalid residual carrier offset"))
  locals = map(eachindex(layouts)) do symbol
    _joint_cz_local_problem(m, code, layouts[symbol], full_ffts[symbol];
      ici_half_width=K, frame_slice=m.ldpc_scope === :frame)
  end
  y = zeros(ComplexF64,N,S)
  C0 = zeros(ComplexF64,2K+1,N,S)
  variances = Vector{Float64}(undef,S)
  scales = Vector{Float64}(undef,S)
  pilot_scores = Vector{Float64}(undef,S)
  for (symbol,p) in enumerate(locals)
    scale = sqrt(max(mean(abs2,p.h0),eps(Float64)))
    variance = _baseline_pilot_variance(p.layout,p.full_fft)
    scales[symbol] = scale
    variances[symbol] = variance/scale^2
    pilot_scores[symbol] = variance/max(
      mean(abs2,p.full_fft[p.pilot_idx]),eps(Float64))
    y[:,symbol] .= p.full_fft ./ scale
    C0[K+1,p.active,symbol] .= p.h0 ./ scale
  end
  p = first(locals)
  parity_plan = _joint_cz_parity_plan(code.check_vars,p.inner_mask,p.inner_bits)
  (; m, code, locals, y, C0, variances, scales, cfo=Float64(cfo),
     fixed=p.inner_mask, fixed_bits=p.inner_bits, nbits=code.n,
     parity_plan,pilot_score=mean(pilot_scores))
end

function _joint_cz_problem(m, code, layouts, observations; cfo=0.0)
  N = _joint_cz_validate_problem_inputs(m,layouts,observations)
  isfinite(cfo) && abs(cfo) < N/2 ||
    throw(ArgumentError("invalid residual carrier offset"))
  full_ffts = map(eachindex(layouts)) do symbol
    _joint_cz_full_fft(m,observations[symbol],symbol,cfo)
  end
  _joint_cz_problem_from_full_ffts(m,code,layouts,full_ffts;cfo)
end

function _joint_cz_candidate_acquisition(m, code, layouts, observations,
                                         ::typeof(_joint_cz_problem), ::Nothing)
  if length(m.residual_cfo_candidates) == 1
    cfo = Float64(only(m.residual_cfo_candidates))::Float64
    return [_joint_cz_problem(m,code,layouts,observations;cfo)]
  end
  _joint_cz_acquisition_candidates(m,layouts,observations)
end

function _joint_cz_candidate_acquisition(m, code, layouts, observations,
                                         build_problem, ::Nothing)
  [begin
     problem = build_problem(m,code,layouts,observations;cfo)
     (;cfo=problem.cfo,pilot_score=problem.pilot_score,problem)
   end for cfo in m.residual_cfo_candidates]
end

function _joint_cz_candidate_acquisition(m, code, layouts, observations,
                                         build_problem, acquire_candidates)
  acquire_candidates(m,layouts,observations)
end

function _joint_cz_materialize_candidate(m, code, layouts, observations,
                                         build_problem, candidate)
  hasproperty(candidate,:problem) && return candidate.problem
  hasproperty(candidate,:parity_plan) && hasproperty(candidate,:locals) &&
    return candidate
  if hasproperty(candidate,:full_ffts) && build_problem === _joint_cz_problem
    problem = _joint_cz_problem_from_full_ffts(
      m,code,layouts,candidate.full_ffts;cfo=candidate.cfo)
    empty!(candidate.full_ffts)
    return problem
  end
  build_problem(m,code,layouts,observations;cfo=candidate.cfo)
end

function _joint_cz_release_unretained_spectra!(acquisition, chosen)
  isempty(acquisition) && return acquisition
  hasproperty(first(acquisition),:full_ffts) || return acquisition
  retained = falses(length(acquisition))
  retained[chosen] .= true
  for (index,candidate) in enumerate(acquisition)
    !retained[index] && hasproperty(candidate,:full_ffts) &&
      empty!(candidate.full_ffts)
  end
  acquisition
end

function _joint_cz_symbols!(s, p, x)
  length(s) == length(p.fixed_symbols) ||
    throw(DimensionMismatch("joint-CZ receiver symbol workspace differs"))
  copyto!(s,p.fixed_symbols)
  for (tone,k) in enumerate(p.data_idx)
    i = p.bit_indices[1,tone]
    j = p.bit_indices[2,tone]
    a = p.inner_mask[i] ? _pm(p.inner_bits[i]) : x[i]
    b = j == 0 ? 1.0 : p.inner_mask[j] ? _pm(p.inner_bits[j]) : x[j]
    s[k] = complex(a,b)/sqrt(2.0)
  end
  s
end

function _joint_cz_symbols(p, x)
  _joint_cz_symbols!(similar(p.fixed_symbols),p,x)
end

_joint_cz_objective_gradient(problem, state) =
  _joint_cz_objective_gradient(problem,state,Val(false),nothing,
    problem.m.parity_gradient_exponent)

_joint_cz_objective_gradient_curvature(problem, state) =
  _joint_cz_objective_gradient(problem,state,Val(true),nothing,
    problem.m.parity_gradient_exponent)

_joint_cz_objective_gradient_curvature(problem, state, workspace) =
  _joint_cz_objective_gradient(problem,state,Val(true),workspace,
    problem.m.parity_gradient_exponent)

_joint_cz_objective_gradient(problem, state, with_curvature::Val) =
  _joint_cz_objective_gradient(problem,state,with_curvature,nothing,
    problem.m.parity_gradient_exponent)

function _joint_cz_objective_gradient(problem, state, ::Val{WITH_CURVATURE},
                                       workspace,gradient_exponent::Real) where WITH_CURVATURE
  (; m,locals,nbits) = problem
  size(state.C) == size(problem.C0) && length(state.x) == nbits ||
    throw(DimensionMismatch("joint-CZ receiver parameter shape differs"))
  all(isfinite,state.C) && all(isfinite,state.x) || throw(ArgumentError("finite parameters required"))
  objective_workspace = workspace isa _JointCZObjectiveWorkspace ? workspace : nothing
  if objective_workspace !== nothing
    size(objective_workspace.gradient_C) == size(state.C) &&
      length(objective_workspace.gradient_x) == nbits &&
      size(objective_workspace.curvature_C) == size(state.C) &&
      length(objective_workspace.curvature_x) == nbits ||
      throw(DimensionMismatch("joint-CZ receiver objective workspace differs"))
  end
  code_workspace = objective_workspace === nothing ? workspace : objective_workspace.code
  # Evaluate on the feasible set: known bits are constants even if a caller
  # perturbs their unused state coordinates during a gradient check.
  if code_workspace === nothing
    x = copy(state.x); x[problem.fixed] .= _pm.(problem.fixed_bits[problem.fixed])
    code = _joint_cz_code_gradient(x,problem.code.check_vars,problem.fixed,
      m.parity_penalty_weight,m.binary_penalty_weight,
      m.parity_penalty_shape,m.parity_root_smoothing,
      gradient_exponent,m.parity_gradient_mix,
      m.parity_vertex_margin_mix,m.parity_gradient_scope,
      m.parity_gradient_model,m.parity_gradient_regularization)
  else
    code = _joint_cz_code_gradient!(code_workspace,state.x,problem.parity_plan,
      m.parity_penalty_weight,m.binary_penalty_weight,
      m.parity_penalty_shape,m.parity_root_smoothing,
      gradient_exponent,m.parity_gradient_mix,
      m.parity_vertex_margin_mix,m.parity_gradient_scope,
      m.parity_gradient_model,m.parity_gradient_regularization)
    x = code_workspace.x
  end
  if objective_workspace === nothing
    gx, gC = copy(code.gradient), zero(state.C)
  else
    gx, gC = objective_workspace.gradient_x,objective_workspace.gradient_C
    copyto!(gx,code.gradient)
    fill!(gC,zero(eltype(gC)))
  end
  if WITH_CURVATURE
    if objective_workspace === nothing
      hC = zeros(Float64,size(state.C))
      hx = if m.parity_preconditioner === :gauss_newton
        copy(code.curvature)
      else
        [(2m.parity_penalty_weight*length(edges)+8m.binary_penalty_weight)/nbits
         for edges in problem.code.var_edges]
      end
    else
      hC,hx = objective_workspace.curvature_C,objective_workspace.curvature_x
      fill!(hC,0.0)
      if m.parity_preconditioner === :gauss_newton
        copyto!(hx,code.curvature)
      else
        for (bit,edges) in enumerate(problem.code.var_edges)
          hx[bit] = (2m.parity_penalty_weight*length(edges)+8m.binary_penalty_weight)/nbits
        end
      end
    end
  else
    hC,hx = nothing,nothing
  end
  physical, anchor, smoothness = 0.0,0.0,0.0
  response_count = size(state.C,1)
  response_plane = response_count*size(state.C,2)
  for (symbol,p) in enumerate(locals)
    if objective_workspace === nothing
      s = _joint_cz_symbols(p,x)
      gs = zeros(ComplexF64,length(s))
    else
      s = _joint_cz_symbols!(objective_workspace.symbols,p,x)
      gs = objective_workspace.symbol_gradient
      fill!(gs,zero(eltype(gs)))
    end
    a = 1/(nbits*problem.variances[symbol])
    b = a*m.channel_smoothness_weight
    symbol_offset = (symbol-1)*response_plane
    @inbounds for k in p.active
      column_offset = symbol_offset+(k-1)*response_count
      neighbor_offset = (k-1)*response_count
      prediction = zero(ComplexF64)
      for d in axes(state.C,1)
        q = p.neighbor_idx[neighbor_offset+d]
        q == 0 || (prediction += state.C[column_offset+d]*s[q])
      end
      residual = prediction-problem.y[k,symbol]
      physical += a*abs2(residual)
      for d in axes(state.C,1)
        q = p.neighbor_idx[neighbor_offset+d]
        q == 0 && continue
        response_index = column_offset+d
        response = state.C[response_index]
        symbol_value = s[q]
        delta = response-problem.C0[response_index]
        gC[response_index] += a*(residual*conj(symbol_value)+m.channel_anchor_weight*delta)
        gs[q] += a*conj(response)*residual
        anchor += a*m.channel_anchor_weight*abs2(delta)
        if WITH_CURVATURE
          hC[response_index] += a*(abs2(symbol_value)+m.channel_anchor_weight)
          tone = p.symbol_slots[q]
          if tone > 0
            response_power = abs2(response)
            for coordinate in 1:2
              bit = p.bit_indices[coordinate,tone]
              bit > 0 && (hx[bit] += a*response_power)
            end
          end
        end
      end
    end
    # Smooth corrections to the pilot response, preserving its resolved
    # frequency selectivity. Never connect across DC, inactive bins or wrap.
    @inbounds for (l,r) in p.smooth_edges
      left,right = p.active[l],p.active[r]
      left_neighbor_offset = (left-1)*response_count
      right_neighbor_offset = (right-1)*response_count
      for d in axes(state.C,1)
        p.neighbor_idx[left_neighbor_offset+d] > 0 &&
          p.neighbor_idx[right_neighbor_offset+d] > 0 || continue
        left_index = symbol_offset+left_neighbor_offset+d
        right_index = symbol_offset+right_neighbor_offset+d
        delta = (state.C[right_index]-problem.C0[right_index])-
                (state.C[left_index]-problem.C0[left_index])
        smoothness += b*abs2(delta)
        gC[right_index] += b*delta
        gC[left_index] -= b*delta
        if WITH_CURVATURE
          hC[left_index] += b
          hC[right_index] += b
        end
      end
    end
    @inbounds for (tone,k) in enumerate(p.data_idx)
      i = p.bit_indices[1,tone]
      j = p.bit_indices[2,tone]
      gx[i] += sqrt(2.0)*real(gs[k])
      j > 0 && (gx[j] += sqrt(2.0)*imag(gs[k]))
    end
  end
  @inbounds for bit in eachindex(problem.fixed)
    problem.fixed[bit] && (gx[bit] = 0.0)
  end
  terms = (; physical,anchor,smoothness,parity=code.parity,binary=code.binary)
  result = (; loss=sum(values(terms)), gradient=(C=gC,x=gx), terms)
  WITH_CURVATURE ? merge(result,(;curvature=(C=hC,x=hx))) : result
end

function _joint_cz_directions(problem, state, gradient)
  m,n = problem.m,problem.nbits
  hC = zeros(Float64,size(state.C))
  hx = [(2m.parity_penalty_weight*length(edges)+8m.binary_penalty_weight)/n
        for edges in problem.code.var_edges]
  for (symbol,p) in enumerate(problem.locals)
    s = _joint_cz_symbols(p,state.x)
    a = 1/(n*problem.variances[symbol])
    for k in p.active,d in axes(state.C,1)
      q = p.neighbor_idx[d,k]
      q == 0 && continue
      hC[d,k,symbol] += a*(abs2(s[q])+m.channel_anchor_weight)
      tone=p.symbol_slots[q]
      if tone > 0
        for coordinate in 1:2
          bit=p.bit_indices[coordinate,tone]
          bit > 0 && (hx[bit] += a*abs2(state.C[d,k,symbol]))
        end
      end
    end
    for (l,r) in p.smooth_edges,d in axes(state.C,1)
      left,right=p.active[l],p.active[r]
      p.neighbor_idx[d,left] > 0 && p.neighbor_idx[d,right] > 0 || continue
      hC[d,left,symbol] += a*m.channel_smoothness_weight
      hC[d,right,symbol] += a*m.channel_smoothness_weight
    end
  end
  # Positive diagonal curvature scaling preserves descent and avoids
  # amplifying a nearly zero channel gradient to a unit-size update.
  # hC is the Wirtinger diagonal; hx bounds the real bit-coordinate diagonal.
  _joint_cz_scaled_direction(gradient,hC,hx)
end

function _joint_cz_scaled_direction!(direction, gradient, hC, hx)
  size(direction.C) == size(gradient.C) == size(hC) &&
    length(direction.x) == length(gradient.x) == length(hx) ||
    throw(DimensionMismatch("joint-CZ receiver direction workspace differs"))
  @. direction.C = -gradient.C / max(hC,eps(Float64))
  @. direction.x = -gradient.x / max(hx,eps(Float64))
  direction
end

function _joint_cz_scaled_direction(gradient, hC, hx)
  direction = (C=similar(gradient.C),x=similar(gradient.x))
  _joint_cz_scaled_direction!(direction,gradient,hC,hx)
end

function _joint_cz_directional_derivative!(deltaC, deltax, gradient, trial, state)
  deltaC .= trial.C .- state.C
  deltax .= trial.x .- state.x
  2real(dot(gradient.C,deltaC)) + dot(gradient.x,deltax)
end

function _joint_cz_trial!(trial, state, direction, step)
  size(trial.C) == size(state.C) == size(direction.C) &&
    length(trial.x) == length(state.x) == length(direction.x) ||
    throw(DimensionMismatch("joint-CZ receiver trial workspace differs"))
  @. trial.C = state.C + step*direction.C
  @. trial.x = clamp(state.x + step*direction.x,-1.0,1.0)
  trial
end

function _joint_cz_trial(state, direction, step)
  trial = (C=similar(state.C),x=similar(state.x))
  _joint_cz_trial!(trial,state,direction,step)
end

@inline function _joint_cz_iteration_parity_exponent(m,iteration::Integer)
  m.parity_gradient_warmup_steps > 0 &&
    iteration <= m.parity_gradient_warmup_steps ?
    m.parity_gradient_warmup_exponent : m.parity_gradient_exponent
end

@inline function _joint_cz_parity_gradient_trace_model(m)
  m.parity_penalty_shape === :product_vertex_margin &&
    return :product_vertex_margin_objective_gradient
  m.parity_gradient_mix == 0 && return :objective_gradient
  m.parity_gradient_model === :checkwise_normalized &&
    return :violated_checkwise_normalized_pseudogradient
  m.parity_gradient_model === :rational_softsign &&
    return :violated_rational_softsign_pseudogradient
  m.parity_gradient_model === :regularized_power &&
    return :violated_regularized_power_pseudogradient
  m.parity_gradient_scope === :violated_checks ?
    :violated_check_tempered_leave_one_pseudogradient :
    :blended_tempered_leave_one_pseudogradient
end

function _solve_joint_cz_projected_gradient(problem, initial)
  m = problem.m
  state = (C=copy(initial.C),x=clamp.(initial.x,-1.0,1.0))
  length(problem.fixed) == length(state.x) == length(problem.fixed_bits) ||
    throw(DimensionMismatch("joint-CZ fixed-bit vectors differ"))
  @inbounds for bit in eachindex(problem.fixed)
    problem.fixed[bit] && (state.x[bit] = _pm(problem.fixed_bits[bit]))
  end
  feasible_initial = (C=copy(state.C),x=copy(state.x))
  trial_state = (C=similar(state.C),x=similar(state.x))
  current_workspace = _joint_cz_objective_workspace(problem,state)
  trial_workspace = _joint_cz_objective_workspace(problem,state)
  initial_exponent = _joint_cz_iteration_parity_exponent(m,1)
  current = _joint_cz_objective_gradient(problem,state,Val(true),
    current_workspace,initial_exponent)
  first_loss,first_terms = current.loss,current.terms
  history = [current.loss]
  step_sizes = Float64[]
  directional_derivatives = Float64[]
  sizehint!(history,m.projected_gradient_steps+1)
  sizehint!(step_sizes,m.projected_gradient_steps)
  sizehint!(directional_derivatives,m.projected_gradient_steps)
  deltaC, deltax = similar(state.C), similar(state.x)
  direction = (C=similar(state.C),x=similar(state.x))
  status = :steps_completed
  gradient_refreshes = 0
  for iteration in 1:m.projected_gradient_steps
    iteration_exponent = _joint_cz_iteration_parity_exponent(m,iteration)
    if iteration == m.parity_gradient_warmup_steps+1 &&
        m.parity_gradient_warmup_steps > 0
      previous_loss = current.loss
      current = _joint_cz_objective_gradient(problem,state,Val(true),
        current_workspace,iteration_exponent)
      current.loss == previous_loss ||
        error("parity-gradient continuation changed the objective")
      gradient_refreshes += 1
    end
    _joint_cz_scaled_direction!(direction,current.gradient,
      current.curvature.C,current.curvature.x)
    m.projected_gradient_update_response || fill!(direction.C,0)
    m.projected_gradient_update_bits || fill!(direction.x,0)
    accepted = false
    for backtrack in 0:16
      step = m.projected_gradient_step_size*0.5^backtrack
      _joint_cz_trial!(trial_state,state,direction,step)
      for bit in eachindex(problem.fixed)
        problem.fixed[bit] && (trial_state.x[bit] = state.x[bit])
      end
      evaluation = _joint_cz_objective_gradient(problem,trial_state,Val(true),
        trial_workspace,iteration_exponent)
      if isfinite(evaluation.loss) && evaluation.loss < current.loss
        push!(directional_derivatives,_joint_cz_directional_derivative!(
          deltaC,deltax,current.gradient,trial_state,state))
        push!(step_sizes,step)
        state,trial_state = trial_state,state
        current_workspace,trial_workspace = trial_workspace,current_workspace
        current = evaluation
        push!(history,current.loss)
        accepted = true
        break
      end
    end
    if !accepted
      status = :line_search_stalled
      break
    end
  end
  @. deltax = feasible_initial.x-initial.x
  initial_constraint_rms_change = sqrt(mean(abs2,deltax))
  @. deltax = state.x-feasible_initial.x
  bit_rms_change = sqrt(mean(abs2,deltax))
  bit_sign_changes = 0
  @inbounds for bit in eachindex(state.x)
    bit_sign_changes += signbit(state.x[bit]) != signbit(feasible_initial.x[bit])
  end
  @. deltaC = state.C-feasible_initial.C
  response_change = norm(deltaC)
  (; state, trace=(; initial_objective=first_loss,final_objective=current.loss,
    initial_terms=first_terms,final_terms=current.terms,objective_history=history,
    step_sizes,directional_derivatives,
    accepted_steps=length(history)-1,steps_requested=m.projected_gradient_steps,status,
    initial_constraint_rms_change,bit_rms_change,bit_sign_changes,response_change,
    preconditioner=m.parity_preconditioner === :gauss_newton ?
      :positive_diagonal_gauss_newton : :positive_diagonal_degree_bound,
    parity_gradient_initial_exponent=initial_exponent,
    parity_gradient_terminal_exponent=m.parity_gradient_exponent,
    parity_gradient_warmup_steps=m.parity_gradient_warmup_steps,
    gradient_refreshes,
    gradient_model=_joint_cz_parity_gradient_trace_model(m),
    update_response=m.projected_gradient_update_response,update_bits=m.projected_gradient_update_bits))
end

# Conditional Gaussian QPSK messages on a frozen fitted channel. The target
# symbol is excluded from both interference and its variance. Uncertainty of
# other relaxed symbols is approximated as independent proper complex noise.
# Correlations across rows sharing an uncertain symbol are also omitted.
function _joint_cz_channel_llrs(problem, state)
  llrs = zeros(Float64,problem.nbits)
  assigned = falses(problem.nbits)
  symbol_count = length(first(problem.locals).fixed_symbols)
  s = Vector{ComplexF64}(undef,symbol_count)
  sufficient = Vector{ComplexF64}(undef,symbol_count)
  for (symbol,p) in enumerate(problem.locals)
    _joint_cz_symbols!(s,p,state.x)
    fill!(sufficient,zero(eltype(sufficient)))
    @inbounds for k in p.active
      for target in axes(state.C,1)
        q = p.neighbor_idx[target,k]
        q == 0 && continue
        residual = problem.y[k,symbol]
        variance = problem.variances[symbol]
        for d in axes(state.C,1)
          neighbor = p.neighbor_idx[d,k]
          (neighbor == 0 || d == target) && continue
          response = state.C[d,k,symbol]
          residual -= response*s[neighbor]
          variance += abs2(response)*max(0.0,1-abs2(s[neighbor]))
        end
        sufficient[q] += conj(state.C[target,k,symbol])*residual/variance
      end
    end
    @inbounds for (tone,k) in enumerate(p.data_idx), coordinate in 1:2
      bit = p.bit_indices[coordinate,tone]
      bit == 0 && continue
      assigned[bit] && throw(ArgumentError("duplicate coded-bit mapping"))
      llrs[bit] = 2sqrt(2.0)*(coordinate == 1 ? real(sufficient[k]) : imag(sufficient[k]))
      assigned[bit] = true
    end
  end
  all(assigned) || throw(ArgumentError("incomplete coded-bit mapping"))
  all(isfinite,llrs) || throw(ArgumentError("non-finite channel likelihood"))
  llrs
end

function _joint_cz_decoder_pass(m, code, llrs)
  applied = clamp.(llrs,-_LLR_CLIP,_LLR_CLIP)
  _apply_inner_clamps!(m,code,applied)
  bp = _bp_decode(m,code,-applied)
  posterior = -bp.lpost_metric
  # Subtract exactly the clipped, pilot-clamped input, without accumulating
  # earlier posteriors. No parity term is passed to BP as channel evidence.
  extrinsic = posterior-applied
  (; bp,applied,posterior,extrinsic)
end

function _joint_cz_finite_adapter_vector(value, n::Integer, label::AbstractString)
  value isa AbstractVector || throw(ArgumentError("$label must be a real vector"))
  length(value) == n || throw(ArgumentError("$label must have length $n"))
  output = Vector{Float64}(undef,n)
  for index in eachindex(value)
    item = value[index]
    item isa Real && !(item isa Bool) ||
      throw(ArgumentError("$label must contain only real numbers"))
    converted = try
      Float64(item)
    catch
      throw(ArgumentError("$label contains a value outside Float64"))
    end
    isfinite(converted) || throw(ArgumentError("$label must contain only finite values"))
    output[index] = converted
  end
  output
end

function _joint_cz_adapter_parity(code)
  offsets = Vector{Int}(undef,length(code.check_vars)+1)
  variables = Vector{Int}(undef,sum(length,code.check_vars))
  position = 1
  for (check,vars) in enumerate(code.check_vars)
    offsets[check] = position
    copyto!(variables,position,vars,1,length(vars))
    position += length(vars)
  end
  offsets[end] = position
  (;offsets,variables)
end

function _joint_cz_adapter_pass(m, code, llrs, adapter, context=(;
    receiver_family=m.mode,phase=:unit,cfo_subcarriers=0.0,
    temperature=0.0,round=0,fixed_mask=falses(code.n),fixed_bits=falses(code.n),
    parity=_joint_cz_adapter_parity(code)))
  adapter isa Function || throw(ArgumentError("joint_cz feedback adapter must be a function"))
  length(llrs) == code.n || throw(ArgumentError("feedback likelihood length differs from the code"))
  applied = clamp.(Float64.(llrs),-_LLR_CLIP,_LLR_CLIP)
  all(isfinite,applied) || throw(ArgumentError("feedback likelihoods must be finite"))
  _apply_inner_clamps!(m,code,applied)
  # The provider receives only copied candidate evidence and code constraints.
  # Live modem, code, waveform, payload, ranking, and reference state stay private.
  request = (;intrinsic_llr_bit0=copy(applied),
    parity_check_offsets=copy(context.parity.offsets),
    parity_check_variables=copy(context.parity.variables),
    fixed_mask=copy(context.fixed_mask),fixed_bits=copy(context.fixed_bits),
    receiver_family=context.receiver_family,phase=context.phase,
    cfo_subcarriers=context.cfo_subcarriers,temperature=context.temperature,
    round=context.round)
  response = adapter(request)
  response isa NamedTuple || throw(ArgumentError("feedback adapter must return a named tuple"))
  required = (:posterior,:applied_extrinsic,:iterations,:method)
  optional = (:selected_codeword,:provider)
  all(key -> hasproperty(response,key),required) &&
    all(key -> key in (required...,optional...),keys(response)) &&
    (length(keys(response)) == length(required) ||
      all(key -> hasproperty(response,key),optional) &&
      length(keys(response)) == length(required)+length(optional)) ||
    throw(ArgumentError("feedback adapter returned missing or extra fields"))
  posterior = _joint_cz_finite_adapter_vector(response.posterior,code.n,"adapter posterior")
  # A bounded posterior may describe one-sided list support while applying no
  # correction there. Keep that support-gated correction distinct and visible.
  extrinsic = _joint_cz_finite_adapter_vector(response.applied_extrinsic,code.n,
    "adapter applied extrinsic")
  selected_codeword = nothing
  provider = nothing
  if hasproperty(response,:selected_codeword)
    word = response.selected_codeword
    word isa AbstractVector{Bool} && length(word) == code.n ||
      throw(ArgumentError("adapter selected codeword must contain one bit per code position"))
    selected_codeword = BitVector(word)
    _syndrome_weight(code,selected_codeword) == 0 ||
      throw(ArgumentError("adapter selected codeword violates LDPC parity"))
    all(selected_codeword[context.fixed_mask] .== context.fixed_bits[context.fixed_mask]) ||
      throw(ArgumentError("adapter selected codeword violates fixed pilot bits"))
    provider = response.provider
    provider isa NamedTuple &&
      keys(provider) == (:manifest_sha256,:request_sha256,
        :full_universe_sha256,:top16_sha256,
        :selected_word_sha256,:proposals,:distinct,:retained,
        :hard_word_selection,:physical_scorer_calls) ||
      throw(ArgumentError("adapter provider evidence fields differ"))
    all(key -> getproperty(provider,key) isa AbstractString &&
      occursin(r"^[0-9a-f]{64}$",getproperty(provider,key)),
      (:manifest_sha256,:request_sha256,:full_universe_sha256,
       :top16_sha256,:selected_word_sha256)) ||
      throw(ArgumentError("adapter provider hashes differ"))
    provider.proposals == 59 && provider.distinct == 59 && provider.retained == 16 ||
      throw(ArgumentError("adapter provider counts differ from finite-list profile"))
    provider.hard_word_selection === :conditional_unary_top1 &&
      provider.physical_scorer_calls === 0 ||
      throw(ArgumentError("adapter provider hard-word policy differs from finite-list profile"))
  end
  # Keep the truthful bounded-list posterior for feedback, while the selected
  # complete word determines the hard output and physical candidate score.
  lpost_metric = selected_codeword === nothing ? -posterior :
    ifelse.(selected_codeword,max.(abs.(posterior),1.0),-max.(abs.(posterior),1.0))
  response.iterations isa Integer && !(response.iterations isa Bool) &&
    0 <= response.iterations <= typemax(Int) ||
    throw(ArgumentError("adapter iterations must be a nonnegative integer"))
  response.method isa Symbol || throw(ArgumentError("adapter method must be a symbol"))
  syndrome = _syndrome_weight(code,lpost_metric .> 0)
  bp = (;lpost_metric,valid=syndrome == 0,syndrome,iterations=Int(response.iterations))
  (;bp,applied,posterior,extrinsic,method=response.method,selected_codeword,provider)
end

function _joint_cz_candidate_score(problem, metrics)
  x = ifelse.(metrics .> 0,-1.0,1.0)
  score = 0.0
  for (symbol,p) in enumerate(problem.locals)
    s = _joint_cz_symbols(p,x)
    variance = problem.variances[symbol]
    # The pilot-only response and variance stay frozen for every decoded
    # candidate, so a more flexible response cannot win by fitting itself.
    for k in eachindex(s)
      residual = problem.y[k,symbol]-problem.C0[p.ici_half_width+1,k,symbol]*s[k]
      score += abs2(residual)/variance + log(variance*problem.scales[symbol]^2)
    end
  end
  score/problem.nbits
end

function _joint_cz_pilot_screen_passes(pilot_score, reference_pilot_score,
                                        tolerance_scale)
  all(isfinite,(pilot_score,reference_pilot_score,tolerance_scale)) || return false
  tolerance = 64eps(Float64)*max(1.0,abs(tolerance_scale))
  pilot_score <= reference_pilot_score+tolerance
end

function _joint_cz_candidate_admissible(record, reference)
  all(isfinite,(record.score,record.pilot_score,reference.score,reference.pilot_score)) || return false
  tolerance = 64eps(Float64)*max(1.0,abs(reference.score))
  record.known_bits_valid &&
    _joint_cz_pilot_screen_passes(record.pilot_score,reference.pilot_score,reference.score) &&
    record.score <= reference.score+tolerance
end

function _joint_cz_prefer_candidate(candidate, current)
  # Keep the calibrated seed unless a candidate passes every guard, even
  # when BP gives the seed an incorrect hard decision on a known pilot bit.
  candidate.admissible || return false
  current.admissible || return true
  (candidate.syndrome != 0,candidate.syndrome,candidate.score) <
    (current.syndrome != 0,current.syndrome,current.score)
end

function _joint_cz_gradient_admissible(record, reference)
  all(isfinite,(record.score,record.pilot_score,reference.pilot_score)) || return false
  record.kind in (:projected_gradient,:gradient_disabled,:jcade) &&
    _joint_cz_pilot_screen_passes(record.pilot_score,reference.pilot_score,
      reference.pilot_score)
end

function _joint_cz_gradient_prefer_candidate(candidate, current)
  candidate.admissible || return false
  current.admissible || return true
  # A valid codeword may cost more received-data residual than an invalid
  # word. Compare projected-gradient candidates after screening CFO with the pilots.
  (!candidate.known_bits_valid,candidate.syndrome != 0,candidate.syndrome,candidate.score) <
    (!current.known_bits_valid,current.syndrome != 0,current.syndrome,current.score)
end

_joint_cz_initial_state(problem, x) = (C=copy(problem.C0),x)

function _joint_cz_candidate_bp_feedback(m, code, layouts, observations;
    build_problem=m.mode === :joint_cwz ? _cwz_problem : _joint_cz_problem,
    acquire_candidates=nothing,
    initialize=m.mode === :joint_cwz ? _cwz_initial_state : _joint_cz_initial_state,
    solve_problem=m.mode === :joint_cwz ? _cwz_solve : _solve_joint_cz_projected_gradient,
    channel_llrs=m.mode === :joint_cwz ? _cwz_channel_llrs : _joint_cz_channel_llrs)
  function evaluate_acquisition(acquisition)
  zero_index = findfirst(candidate -> iszero(candidate.cfo),acquisition)
  zero_index === nothing &&
    throw(ArgumentError("joint-CZ receiver requires a zero-CFO candidate"))
  order = sortperm(acquisition;
    by=candidate -> (candidate.pilot_score,abs(candidate.cfo),candidate.cfo))
  chosen = [zero_index; filter(!=(zero_index),order)[1:m.residual_cfo_keep_count-1]]
  _joint_cz_release_unretained_spectra!(acquisition,chosen)
  records = NamedTuple[]
  traces = NamedTuple[]
  decoder_calls = 0
  best = nothing
  reference = nothing
  optimized_indices = Int[]
  function retain(problem,pass;kind,temperature=0.0,round=0,solve=nothing,seed_applied=pass.applied)
    score = _joint_cz_candidate_score(problem,pass.bp.lpost_metric)
    known_ok = all((pass.bp.lpost_metric[problem.fixed] .> 0) .== problem.fixed_bits[problem.fixed])
    record = (; cfo_subcarriers=problem.cfo,kind,temperature,round,
      syndrome=pass.bp.syndrome,known_bits_valid=known_ok,score,pilot_score=problem.pilot_score,
      decoder_iterations=pass.bp.iterations,
      response_change=solve === nothing ? 0.0 : solve.trace.response_change,
      bit_rms_change=solve === nothing ? 0.0 : solve.trace.bit_rms_change,
      accepted_steps=solve === nothing ? 0 : solve.trace.accepted_steps,
      channel_llr_rms_change=sqrt(mean(abs2,pass.applied-seed_applied)))
    if m.mode === :joint_cwz
      record = merge(record,(;weight_phase_change=solve === nothing ? 0.0 : solve.trace.weight_phase_change))
    end
    reference === nothing && (reference = record)
    seed_guard = _joint_cz_candidate_admissible(record,reference)
    admissible = m.candidate_selection === :calibrated_seed_guard ? seed_guard :
      _joint_cz_gradient_admissible(record,reference)
    record = merge(record,(;admissible,satisfies_seed_guard=seed_guard))
    push!(records,record)
    if m.candidate_selection === :projected_gradient && !admissible
      return
    end
    preferred = best === nothing || (m.candidate_selection === :calibrated_seed_guard ?
      _joint_cz_prefer_candidate(record,best.record) :
      _joint_cz_gradient_prefer_candidate(record,best.record))
    if preferred
      best = (; pass,problem,record,index=length(records))
    end
  end
  for index in chosen
    candidate = acquisition[index]
    if reference !== nothing
      tolerance_scale = m.candidate_selection === :calibrated_seed_guard ? reference.score :
        reference.pilot_score
      if !_joint_cz_pilot_screen_passes(candidate.pilot_score,
          reference.pilot_score,tolerance_scale)
        hasproperty(candidate,:full_ffts) && empty!(candidate.full_ffts)
        continue
      end
    end
    problem = _joint_cz_materialize_candidate(
      m,code,layouts,observations,build_problem,candidate)
    problem.cfo == candidate.cfo && problem.pilot_score == candidate.pilot_score ||
      error("joint-CZ acquisition score differs from the retained problem")
    push!(optimized_indices,index)
    initial_state = initialize(problem,zeros(code.n))
    channel = channel_llrs(problem,initial_state)
    initial_pass = _joint_cz_decoder_pass(m,code,channel); decoder_calls += 1
    retain(problem,initial_pass;kind=:calibrated_seed)
    for temperature in m.relaxed_bit_initialization_temperatures
      # A softened start gives code-inconsistent coordinates room to move.
      feedback = initial_pass.applied + m.feedback_damping .* initial_pass.extrinsic
      state = initialize(problem,tanh.(clamp.(feedback,-_LLR_CLIP,_LLR_CLIP)./(2temperature)))
      for round in 1:m.iterative_refinement_rounds
        solved = solve_problem(problem,state)
        state = solved.state
        physical = channel_llrs(problem,state)
        pass = _joint_cz_decoder_pass(m,code,physical); decoder_calls += 1
        kind=m.projected_gradient_steps == 0 ? :gradient_disabled : :projected_gradient
        retain(problem,pass;kind,temperature,round,solve=solved,seed_applied=initial_pass.applied)
        push!(traces,merge(solved.trace,(; cfo_subcarriers=problem.cfo,temperature,round,
          decoder_syndrome=pass.bp.syndrome,extrinsic_rms=sqrt(mean(abs2,pass.extrinsic)),
          extrinsic_identity_error=maximum(abs,pass.posterior-pass.applied-pass.extrinsic))))
        # Feedback is an initialization for the next constrained solve, not
        # another term in its objective. We do not differentiate through BP.
        if round < m.iterative_refinement_rounds
          feedback = pass.applied + m.feedback_damping .* pass.extrinsic
          state = merge(state,(;x=tanh.(clamp.(feedback,-_LLR_CLIP,_LLR_CLIP)./(2temperature))))
        end
      end
    end
  end
  best === nothing && error("joint-CZ receiver has no finite projected-gradient candidate passing its pilot screen")
  selected = best
  # Restore BP scratch to the selected candidate, not the last tested one.
  final_pass = _joint_cz_decoder_pass(m,code,selected.pass.applied); decoder_calls += 1
  bp = final_pass.bp
  all(bp.lpost_metric .== selected.pass.bp.lpost_metric) || error("joint-CZ receiver decoder replay differs")
  trace = (; mode=:joint_cz,joint_cz_algorithm=:projected_gradient,
    ldpc_scope=m.ldpc_scope,ofdm_symbols=length(layouts),codewords=1,
    parameterization=:continuous_bipolar_bits,objective=:gaussian_residual_code_polynomial,
    likelihood=:pilot_variance,noise_model=:full_fft_diagonal,
    ici_half_width=m.joint_cz_ici_half_width,decoder_calls,
    decoder_syndrome=bp.syndrome,decoder_valid=bp.valid,
    bp_iterations=m.bp_iterations,decoder_iterations=bp.iterations,
    bp_input=:conditional_channel_llrs,feedback=:damped_extrinsic_initialization,
    selection=m.candidate_selection === :calibrated_seed_guard ? :pilot_likelihood_guard_then_syndrome : :pilot_screen_then_gradient_codeword,
    parameter_updates=m.projected_gradient_steps == 0 ? :disabled :
      m.projected_gradient_update_response && m.projected_gradient_update_bits ? :projected_gradient_descent :
      m.projected_gradient_update_response ? :response_only_gradient_descent : :bits_only_gradient_descent,
    initialization=:calibrated_channel_and_damped_bp_extrinsic,
    reference_score=reference.score,reference_pilot_score=reference.pilot_score,
    fallback_used=selected.record.kind === :calibrated_seed,
    selected_candidate=selected.index,selected_kind=selected.record.kind,
    selected_cfo_subcarriers=selected.problem.cfo,
    selected_response_change=selected.record.response_change,
    selected_bit_rms_change=selected.record.bit_rms_change,
    selected_accepted_steps=selected.record.accepted_steps,
    selected_channel_llr_rms_change=selected.record.channel_llr_rms_change,
    returned_cfo=:shared_acquisition_only,
    pilot_variance=selected.problem.variances .* selected.problem.scales.^2,
    acquisition_candidates=[(;cfo_subcarriers=candidate.cfo,
      pilot_score=candidate.pilot_score,
      retained=i in chosen,
      pilot_screen_passed=_joint_cz_pilot_screen_passes(candidate.pilot_score,
        reference.pilot_score,m.candidate_selection === :calibrated_seed_guard ? reference.score :
        reference.pilot_score),optimized=i in optimized_indices)
      for (i,candidate) in enumerate(acquisition)],
    candidates=records,rounds=traces,
    accepted_steps=sum(t.accepted_steps for t in traces),
    gradient_rounds=length(traces),parity_checks=length(code.check_vars))
  if m.mode === :joint_cwz
    trace = merge(trace,(;mode=:joint_cwz,objective=:gaussian_residual_code_polynomial_phase_anchor,
      noise_model=:unit_phase_full_fft_diagonal,combiner=:per_symbol_segment_phase,
      partial_fft_parts=m.partial_fft_parts,fixed_reference_segment=1,
      phase_anchor=m.cwz_phase_anchor,configured_update_weights=m.cwz_update_weights,
      update_weights=m.cwz_update_weights && m.partial_fft_parts > 1 && m.projected_gradient_steps > 0,
      parameter_updates=m.projected_gradient_steps == 0 ? :disabled :
        m.projected_gradient_update_response && m.projected_gradient_update_bits && m.cwz_update_weights && m.partial_fft_parts > 1 ?
        :joint_CWZ_gradient_descent : :controlled_gradient_descent,
      selected_weight_phase_change=selected.record.weight_phase_change))
  end
  m.receiver_trace === nothing && (m.receiver_trace = NamedTuple[])
  push!(m.receiver_trace,trace)
  pilot_mse = mean(_pilot_mse(p.layout,
    _residual_pilot_equalize(m,p.layout,copy(p.full_fft))) for p in selected.problem.locals)
  (; bp.lpost_metric,bp.valid,bp.syndrome,pilot_mse)
  end
  evaluate_acquisition(_joint_cz_candidate_acquisition(
    m,code,layouts,observations,build_problem,acquire_candidates))
end

function _joint_cz_candidate_adapted(m, code, layouts, observations;
    build_problem=m.mode === :joint_cwz ? _cwz_problem : _joint_cz_problem,
    initialize=m.mode === :joint_cwz ? _cwz_initial_state : _joint_cz_initial_state,
    solve_problem=m.mode === :joint_cwz ? _cwz_solve : _solve_joint_cz_projected_gradient,
    channel_llrs=m.mode === :joint_cwz ? _cwz_channel_llrs : _joint_cz_channel_llrs)
  adapter = m.decoder_feedback_adapter
  adapter isa Function || throw(ArgumentError("an adapted receiver requires a feedback function"))
  terminal_bp = m.terminal_bp_decode
  previous_audit = m.decoder_audit
  previous_audit === nothing || throw(ArgumentError("nested receiver decoder audits are not supported"))
  audit = _DecoderAudit(:inactive,terminal_bp,0,0,0,0)
  m.decoder_audit = audit
  try
    problems = [build_problem(m,code,layouts,observations;cfo) for cfo in m.residual_cfo_candidates]
    zero_index = findfirst(p -> iszero(p.cfo),problems)
    order = sortperm(problems;by=p -> (p.pilot_score,abs(p.cfo),p.cfo))
    chosen = [zero_index; filter(!=(zero_index),order)[1:m.residual_cfo_keep_count-1]]
    records = NamedTuple[]
    traces = NamedTuple[]
    feedback_calls = 0
    feedback_method = nothing
    feedback_provider_manifest_sha256 = nothing
    best = nothing
    reference = nothing
    optimized_indices = Int[]
    adapter_parity = _joint_cz_adapter_parity(code)

    function require_audit(label)
      m.decoder_audit === audit ||
        throw(ArgumentError("feedback adapter replaced the decoder audit during $label"))
      m.decoder_feedback_adapter === adapter ||
        throw(ArgumentError("feedback adapter changed during $label"))
      m.terminal_bp_decode === terminal_bp ||
        throw(ArgumentError("terminal BP policy changed during $label"))
      audit.terminal_bp === terminal_bp ||
        throw(ArgumentError("feedback adapter changed the decoder audit policy during $label"))
      audit.phase === :inactive ||
        throw(ArgumentError("decoder audit phase was not restored after $label"))
      nothing
    end

    function run_feedback(problem,llrs;phase,temperature=0.0,round=0)
      context = (;receiver_family=m.mode,phase,cfo_subcarriers=problem.cfo,
        temperature=Float64(temperature),round=Int(round),
        fixed_mask=copy(problem.fixed),fixed_bits=copy(problem.fixed_bits),
        parity=adapter_parity)
      audit.phase = :feedback
      pass = try
        _joint_cz_adapter_pass(m,code,llrs,adapter,context)
      finally
        audit.phase = :inactive
      end
      require_audit("feedback")
      audit.feedback_bp_calls == 0 && audit.feedback_minsum_calls == 0 ||
        throw(ArgumentError("feedback adapter attempted a BP or min-sum decoder call"))
      feedback_calls += 1
      if feedback_method === nothing
        feedback_method = pass.method
      elseif pass.method !== feedback_method
        throw(ArgumentError("feedback adapter changed method within one receiver call"))
      end
      if pass.provider !== nothing
        if feedback_provider_manifest_sha256 === nothing
          feedback_provider_manifest_sha256 = pass.provider.manifest_sha256
        elseif pass.provider.manifest_sha256 != feedback_provider_manifest_sha256
          throw(ArgumentError("feedback adapter changed provider manifest within one receiver call"))
        end
      elseif feedback_provider_manifest_sha256 !== nothing
        throw(ArgumentError("feedback adapter dropped provider evidence within one receiver call"))
      end
      pass
    end

    function retain(problem,pass;kind,temperature=0.0,round=0,solve=nothing,
                    seed_applied=pass.applied)
      score = _joint_cz_candidate_score(problem,pass.bp.lpost_metric)
      known_ok = all((pass.bp.lpost_metric[problem.fixed] .> 0) .== problem.fixed_bits[problem.fixed])
      record = (;cfo_subcarriers=problem.cfo,kind,temperature,round,
        syndrome=pass.bp.syndrome,known_bits_valid=known_ok,score,
        pilot_score=problem.pilot_score,feedback_iterations=pass.bp.iterations,
        feedback_method=pass.method,
        response_change=solve === nothing ? 0.0 : solve.trace.response_change,
        bit_rms_change=solve === nothing ? 0.0 : solve.trace.bit_rms_change,
        accepted_steps=solve === nothing ? 0 : solve.trace.accepted_steps,
        channel_llr_rms_change=sqrt(mean(abs2,pass.applied-seed_applied)))
      if m.mode === :joint_cwz
        record = merge(record,(;weight_phase_change=solve === nothing ? 0.0 : solve.trace.weight_phase_change))
      end
      pass.provider === nothing || (record = merge(record,(;provider=pass.provider)))
      reference === nothing && (reference = record)
      seed_guard = _joint_cz_candidate_admissible(record,reference)
      admissible = m.candidate_selection === :calibrated_seed_guard ? seed_guard :
        _joint_cz_gradient_admissible(record,reference)
      record = merge(record,(;admissible,satisfies_seed_guard=seed_guard))
      push!(records,record)
      if m.candidate_selection === :projected_gradient && !admissible
        return
      end
      preferred = best === nothing || (m.candidate_selection === :calibrated_seed_guard ?
        _joint_cz_prefer_candidate(record,best.record) :
        _joint_cz_gradient_prefer_candidate(record,best.record))
      if preferred
        best = (;pass,problem,record,index=length(records))
      end
    end

    for index in chosen
      problem = problems[index]
      if reference !== nothing
        tolerance_scale = m.candidate_selection === :calibrated_seed_guard ? reference.score :
          reference.pilot_score
        _joint_cz_pilot_screen_passes(problem.pilot_score,reference.pilot_score,
          tolerance_scale) || continue
      end
      push!(optimized_indices,index)
      initial_state = initialize(problem,zeros(code.n))
      channel = channel_llrs(problem,initial_state)
      initial_pass = run_feedback(problem,channel;phase=:initial)
      retain(problem,initial_pass;kind=:calibrated_seed)
      for temperature in m.relaxed_bit_initialization_temperatures
        feedback = initial_pass.applied + m.feedback_damping .* initial_pass.extrinsic
        state = initialize(problem,tanh.(clamp.(feedback,-_LLR_CLIP,_LLR_CLIP)./(2temperature)))
        for round in 1:m.iterative_refinement_rounds
          solved = solve_problem(problem,state)
          state = solved.state
          physical = channel_llrs(problem,state)
          pass = run_feedback(problem,physical;phase=:intermediate,temperature,round)
          kind = m.projected_gradient_steps == 0 ? :gradient_disabled : :projected_gradient
          retain(problem,pass;kind,temperature,round,solve=solved,
            seed_applied=initial_pass.applied)
          push!(traces,merge(solved.trace,(;cfo_subcarriers=problem.cfo,temperature,round,
            feedback_syndrome=pass.bp.syndrome,feedback_method=pass.method,
            extrinsic_rms=sqrt(mean(abs2,pass.extrinsic)),
            posterior_extrinsic_identity_error=
              maximum(abs,pass.posterior-pass.applied-pass.extrinsic))))
          if round < m.iterative_refinement_rounds
            feedback = pass.applied + m.feedback_damping .* pass.extrinsic
            state = merge(state,(;x=tanh.(clamp.(feedback,-_LLR_CLIP,_LLR_CLIP)./(2temperature))))
          end
        end
      end
    end

    best === nothing && error("joint-CZ receiver has no finite projected-gradient candidate passing its pilot screen")
    selected = best
    terminal_calls = 0
    output_pass = selected.pass
    terminal_method = :none
    if terminal_bp
      require_audit("selection")
      audit.phase = :terminal
      output_pass = try
        _joint_cz_decoder_pass(m,code,selected.pass.applied)
      finally
        audit.phase = :inactive
      end
      require_audit("terminal decoding")
      terminal_calls = 1
      terminal_method = :normalized_min_sum
      audit.terminal_bp_calls == 1 && audit.terminal_minsum_calls == 1 ||
        error("adapted receiver terminal BP accounting differs")
    end
    bp = output_pass.bp
    total_bp_calls = audit.feedback_bp_calls + audit.terminal_bp_calls
    total_minsum_calls = audit.feedback_minsum_calls + audit.terminal_minsum_calls
    trace = (;mode=:joint_cz,joint_cz_algorithm=:projected_gradient,
      ldpc_scope=m.ldpc_scope,ofdm_symbols=length(layouts),codewords=1,
      parameterization=:continuous_bipolar_bits,objective=:gaussian_residual_code_polynomial,
      likelihood=:pilot_variance,noise_model=:full_fft_diagonal,
      ici_half_width=m.joint_cz_ici_half_width,decoder_calls=total_bp_calls,
      feedback_calls,terminal_calls,feedback_method,terminal_method,
      feedback_provider_manifest_sha256,
      feedback_bp_calls=audit.feedback_bp_calls,terminal_bp_calls=audit.terminal_bp_calls,
      total_bp_calls,feedback_minsum_calls=audit.feedback_minsum_calls,
      terminal_minsum_calls=audit.terminal_minsum_calls,total_minsum_calls,
      decoder_audit_scope=:same_modem_junacore_bp_entrypoint,
      adapter_source_review_required=true,
      legacy_bp_fallback_used=false,
      terminal_changed_decisions=count((bp.lpost_metric .> 0) .!= (selected.pass.bp.lpost_metric .> 0)),
      selected_codeword_syndrome=selected.pass.bp.syndrome,
      selected_codeword_valid=selected.pass.bp.valid,
      selected_provider=selected.pass.provider,
      selected_feedback_iterations=selected.pass.bp.iterations,
      output_codeword_syndrome=bp.syndrome,output_codeword_valid=bp.valid,
      decoder_syndrome=terminal_bp ? bp.syndrome : nothing,
      decoder_valid=terminal_bp ? bp.valid : nothing,
      bp_iterations=terminal_bp ? m.bp_iterations : nothing,
      decoder_iterations=terminal_bp ? bp.iterations : nothing,
      bp_input=terminal_bp ? :selected_conditional_channel_llrs : :none,
      feedback_input=:conditional_channel_llrs,
      feedback=:adapted_damped_extrinsic_initialization,
      selection=m.candidate_selection === :calibrated_seed_guard ? :pilot_likelihood_guard_then_syndrome : :pilot_screen_then_gradient_codeword,
      parameter_updates=m.projected_gradient_steps == 0 ? :disabled :
        m.projected_gradient_update_response && m.projected_gradient_update_bits ? :projected_gradient_descent :
        m.projected_gradient_update_response ? :response_only_gradient_descent : :bits_only_gradient_descent,
      initialization=:calibrated_channel_and_adapted_extrinsic,
      reference_score=reference.score,reference_pilot_score=reference.pilot_score,
      fallback_used=selected.record.kind === :calibrated_seed,
      selected_candidate=selected.index,selected_kind=selected.record.kind,
      selected_cfo_subcarriers=selected.problem.cfo,
      selected_response_change=selected.record.response_change,
      selected_bit_rms_change=selected.record.bit_rms_change,
      selected_accepted_steps=selected.record.accepted_steps,
      selected_channel_llr_rms_change=selected.record.channel_llr_rms_change,
      returned_cfo=:shared_acquisition_only,
      pilot_variance=selected.problem.variances .* selected.problem.scales.^2,
      acquisition_candidates=[(;cfo_subcarriers=p.cfo,pilot_score=p.pilot_score,
        retained=i in chosen,
        pilot_screen_passed=_joint_cz_pilot_screen_passes(p.pilot_score,
          reference.pilot_score,m.candidate_selection === :calibrated_seed_guard ? reference.score :
          reference.pilot_score),optimized=i in optimized_indices)
        for (i,p) in enumerate(problems)],
      candidates=records,rounds=traces,
      accepted_steps=sum(t.accepted_steps for t in traces),
      gradient_rounds=length(traces),parity_checks=length(code.check_vars))
    if m.mode === :joint_cwz
      trace = merge(trace,(;mode=:joint_cwz,objective=:gaussian_residual_code_polynomial_phase_anchor,
        noise_model=:unit_phase_full_fft_diagonal,combiner=:per_symbol_segment_phase,
        partial_fft_parts=m.partial_fft_parts,fixed_reference_segment=1,
        phase_anchor=m.cwz_phase_anchor,configured_update_weights=m.cwz_update_weights,
        update_weights=m.cwz_update_weights && m.partial_fft_parts > 1 && m.projected_gradient_steps > 0,
        parameter_updates=m.projected_gradient_steps == 0 ? :disabled :
          m.projected_gradient_update_response && m.projected_gradient_update_bits && m.cwz_update_weights && m.partial_fft_parts > 1 ?
          :joint_CWZ_gradient_descent : :controlled_gradient_descent,
        selected_weight_phase_change=selected.record.weight_phase_change))
    end
    m.receiver_trace === nothing && (m.receiver_trace = NamedTuple[])
    push!(m.receiver_trace,trace)
    pilot_mse = mean(_pilot_mse(p.layout,
      _residual_pilot_equalize(m,p.layout,copy(p.full_fft))) for p in selected.problem.locals)
    (;bp.lpost_metric,bp.valid,bp.syndrome,pilot_mse)
  finally
    m.decoder_feedback_adapter = adapter
    m.terminal_bp_decode = terminal_bp
    m.decoder_audit = previous_audit
  end
end

function _joint_cz_lagrangian_bits(value, n::Integer, label::AbstractString)
  value isa AbstractVector || throw(ArgumentError("$label must be a bit vector"))
  length(value) == n || throw(DimensionMismatch("$label differs from the code length"))
  all(item -> item isa Bool, value) ||
    throw(ArgumentError("$label must contain only Boolean decisions"))
  BitVector(value)
end

function _joint_cz_lagrangian_output(problem, result, strategy::Symbol)
  result isa NamedTuple ||
    throw(ArgumentError("Lagrangian solver must return a named tuple"))
  for field in (:state,:trace,:status,:valid)
    hasproperty(result,field) ||
      throw(ArgumentError("Lagrangian solver response is missing $field"))
  end
  result.trace isa NamedTuple ||
    throw(ArgumentError("Lagrangian solver trace must be a named tuple"))
  result.status isa Symbol ||
    throw(ArgumentError("Lagrangian solver status must be a symbol"))
  result.valid isa Bool ||
    throw(ArgumentError("Lagrangian solver validity must be Boolean"))
  _soft_minsum_validate_state(problem,result.state)
  all(abs.(result.state.x) .<= 1+64eps(Float64)) ||
    throw(ArgumentError("Lagrangian solver returned relaxed bits outside [-1,1]"))

  bits = if strategy === :lagrangian_consensus
    hasproperty(result,:z) ||
      throw(ArgumentError("consensus solver response is missing its retained codeword"))
    word = _jade_consensus_codeword_record(problem,result.z)
    result.valid == word.valid ||
      throw(ArgumentError("consensus solver validity disagrees with its retained codeword"))
    BitVector(word.z .< 0)
  elseif strategy === :lagrangian_soft
    hasproperty(result,:decoder_bits) ||
      throw(ArgumentError("soft-Lagrangian solver response is missing its decoded word"))
    decoded = _joint_cz_lagrangian_bits(result.decoder_bits,problem.code.n,
      "soft-Lagrangian decoded word")
    syndrome = _syndrome_weight(problem.code,decoded)
    known_bits_valid = all(decoded[problem.fixed] .==
      problem.fixed_bits[problem.fixed])
    valid = syndrome == 0 && known_bits_valid
    result.valid == valid ||
      throw(ArgumentError("soft-Lagrangian validity disagrees with its decoded word"))
    if valid
      hasproperty(result,:z) && result.z !== nothing ||
        throw(ArgumentError("valid soft-Lagrangian response omitted its decoded codeword"))
      _joint_cz_lagrangian_bits(result.z,problem.code.n,
        "soft-Lagrangian valid codeword") == decoded ||
        throw(ArgumentError("soft-Lagrangian decoded words disagree"))
    elseif hasproperty(result,:z) && result.z !== nothing
      throw(ArgumentError("invalid soft-Lagrangian response exposed a valid-codeword field"))
    end
    decoded
  else
    throw(ArgumentError("unsupported Lagrangian solver strategy $strategy"))
  end
  syndrome = _syndrome_weight(problem.code,bits)
  known_bits_valid = all(bits[problem.fixed] .== problem.fixed_bits[problem.fixed])
  valid = syndrome == 0 && known_bits_valid
  result.valid == valid ||
    throw(ArgumentError("Lagrangian solver validity disagrees with receiver checks"))
  # Receiver metrics use positive values for bit one.  These unit-magnitude
  # values deliberately encode only the solver's selected hard word.
  lpost_metric = ifelse.(bits,1.0,-1.0)
  (;lpost_metric,valid,syndrome,known_bits_valid,bits,state=result.state,
    trace=result.trace,status=result.status)
end

function _joint_cz_run_lagrangian(strategy::Symbol, problem, initial,
                                   temperature::Real)
  m = problem.m
  if strategy === :lagrangian_consensus
    return _jade_consensus_solve(problem,initial;
      rho=m.lagrangian_penalty,
      outer_steps=m.iterative_refinement_rounds,
      inner_steps=m.projected_gradient_steps)
  elseif strategy === :lagrangian_soft
    return _soft_minsum_lagrangian_solve(problem,initial;
      rho=m.lagrangian_penalty,
      outer_steps=m.iterative_refinement_rounds,
      inner_steps=m.projected_gradient_steps,
      damping=m.feedback_damping,
      temperature)
  end
  throw(ArgumentError("unsupported Lagrangian solver strategy $strategy"))
end

function _joint_cz_lagrangian_accepted_steps(trace)
  hasproperty(trace,:accepted_steps) && return Int(trace.accepted_steps)
  hasproperty(trace,:outer) || return 0
  sum(entry -> hasproperty(entry,:physical_accepted_steps) ?
      Int(entry.physical_accepted_steps) : 0,trace.outer;init=0)
end

function _joint_cz_decoder_message_work(audit::_SolverDecoderAudit)
  (;forward_minsum_calls=audit.minsum_calls,
    forward_minsum_sweeps=audit.minsum_sweeps,
    forward_check_to_variable_message_updates=
      audit.check_to_variable_message_updates,
    forward_variable_to_check_message_updates=
      audit.variable_to_check_message_updates,
    certificate_calls=audit.certificate_calls,
    certificate_check_message_outputs=audit.certificate_check_message_outputs,
    certificate_consistency_edge_checks=audit.certificate_consistency_edge_checks,
    certificate_variable_edge_visits=audit.certificate_variable_edge_visits,
    vjp_calls=audit.vjp_calls,
    vjp_active_path_check_outputs=audit.vjp_active_path_check_outputs,
    vjp_reverse_check_derivatives=audit.vjp_reverse_check_derivatives,
    vjp_reverse_edge_propagations=audit.vjp_reverse_edge_propagations)
end

function _joint_cz_decoder_message_work_delta(before, after)
  keys(before) == keys(after) ||
    throw(ArgumentError("decoder message-work snapshots differ"))
  (; (name => getproperty(after,name)-getproperty(before,name)
      for name in keys(before))...)
end

function _joint_cz_candidate_lagrangian(m, code, layouts, observations;
    build_problem=m.mode === :joint_cwz ? _cwz_problem : _joint_cz_problem,
    initialize=m.mode === :joint_cwz ? _cwz_initial_state : _joint_cz_initial_state,
    channel_llrs=m.mode === :joint_cwz ? _cwz_channel_llrs : _joint_cz_channel_llrs,
    solve_strategy=_joint_cz_run_lagrangian)
  strategy = m.decoding_route
  strategy in (:lagrangian_consensus,:lagrangian_soft) ||
    throw(ArgumentError("an experimental Lagrangian solver strategy is required"))
  solve_strategy isa Function || throw(ArgumentError("Lagrangian solver must be callable"))
  m.decoder_feedback_adapter === nothing ||
    throw(ArgumentError("Lagrangian solver strategy cannot use a feedback adapter"))
  m.terminal_bp_decode &&
    throw(ArgumentError("Lagrangian solver strategy cannot request terminal BP"))
  m.candidate_selection === :projected_gradient ||
    throw(ArgumentError("Lagrangian solver strategy requires projected-gradient candidate selection"))
  previous_audit = m.decoder_audit
  previous_audit === nothing ||
    throw(ArgumentError("nested receiver decoder audits are not supported"))
  audit = _SolverDecoderAudit(;strategy)
  m.decoder_audit = audit
  rho = m.lagrangian_penalty
  try
    problems = [build_problem(m,code,layouts,observations;cfo)
      for cfo in m.residual_cfo_candidates]
    zero_index = findfirst(p -> iszero(p.cfo),problems)
    zero_index === nothing &&
      throw(ArgumentError("Lagrangian receiver requires a zero-CFO candidate"))
    order = sortperm(problems;by=p -> (p.pilot_score,abs(p.cfo),p.cfo))
    chosen = [zero_index;filter(!=(zero_index),order)[1:m.residual_cfo_keep_count-1]]
    reference_pilot_score = problems[zero_index].pilot_score
    records = NamedTuple[]
    solver_traces = NamedTuple[]
    optimized_indices = Int[]
    best = nothing

    function require_audit(label)
      m.decoder_audit === audit ||
        throw(ArgumentError("Lagrangian solver replaced decoder accounting during $label"))
      m.decoding_route === strategy ||
        throw(ArgumentError("Lagrangian solver strategy changed during $label"))
      m.lagrangian_penalty == rho ||
        throw(ArgumentError("Lagrangian penalty changed during $label"))
      audit.strategy === strategy ||
        throw(ArgumentError("Lagrangian solver changed decoder accounting strategy"))
      audit.bp_calls == 0 ||
        throw(ArgumentError("Lagrangian solver invoked an external BP decoder"))
      nothing
    end

    for index in chosen
      problem = problems[index]
      _joint_cz_pilot_screen_passes(problem.pilot_score,
        reference_pilot_score,reference_pilot_score) || continue
      push!(optimized_indices,index)
      seed_state = initialize(problem,zeros(code.n))
      physical = channel_llrs(problem,seed_state)
      applied = clamp.(Float64.(physical),-_LLR_CLIP,_LLR_CLIP)
      _apply_inner_clamps!(m,code,applied)
      for temperature in m.relaxed_bit_initialization_temperatures
        initial = initialize(problem,
          tanh.(applied./(2Float64(temperature))))
        before = _joint_cz_decoder_message_work(audit)
        result = solve_strategy(strategy,problem,initial,Float64(temperature))
        require_audit("solver execution")
        output = _joint_cz_lagrangian_output(problem,result,strategy)
        work = _joint_cz_decoder_message_work_delta(before,
          _joint_cz_decoder_message_work(audit))
        calls = work.forward_minsum_calls
        sweeps = work.forward_minsum_sweeps
        check_updates = work.forward_check_to_variable_message_updates
        variable_updates = work.forward_variable_to_check_message_updates
        calls > 0 ||
          throw(ArgumentError("Lagrangian solver performed no normalized-min-sum evaluation"))
        score = _joint_cz_candidate_score(problem,output.lpost_metric)
        response_change = sqrt(mean(abs2,output.state.C-initial.C))
        bit_rms_change = sqrt(mean(abs2,output.state.x-initial.x))
        record = (;cfo_subcarriers=problem.cfo,kind=strategy,temperature,
          round=0,syndrome=output.syndrome,
          known_bits_valid=output.known_bits_valid,score,
          pilot_score=problem.pilot_score,solver_status=output.status,
          solver_valid=output.valid,internal_minsum_calls=calls,
          internal_minsum_sweeps=sweeps,
          forward_check_to_variable_message_updates=check_updates,
          forward_variable_to_check_message_updates=variable_updates,
          forward_directed_message_updates=check_updates+variable_updates,
          message_work=work,
          response_change,bit_rms_change,accepted_steps=
            _joint_cz_lagrangian_accepted_steps(output.trace),
          channel_llr_rms_change=sqrt(mean(abs2,physical-applied)),
          admissible=true,satisfies_seed_guard=false)
        if m.mode === :joint_cwz
          record = merge(record,(;weight_phase_change=
            sqrt(mean(abs2,output.state.theta-initial.theta))))
        end
        push!(records,record)
        push!(solver_traces,(;cfo_subcarriers=problem.cfo,temperature,
          status=output.status,valid=output.valid,internal_minsum_calls=calls,
          internal_minsum_sweeps=sweeps,forward_directed_message_updates=
            check_updates+variable_updates,message_work=work,
          solver_trace=output.trace))
        preferred = best === nothing ||
          _joint_cz_gradient_prefer_candidate(record,best.record)
        preferred && (best=(;output,problem,record,index=length(records)))
      end
    end

    best === nothing && error(
      "joint-CZ receiver has no Lagrangian candidate passing its pilot screen")
    require_audit("candidate selection")
    selected = best
    output_source = strategy === :lagrangian_consensus ?
      :consensus_retained_codeword : :soft_lagrangian_decoded_word
    trace = (;mode=:joint_cz,joint_cz_algorithm=:projected_gradient,
      decoding_route=strategy,solver_origin_revision=
        "ac2ca59e5ff797a2db93d7ebe83f64365732f54a",
      ldpc_scope=m.ldpc_scope,ofdm_symbols=length(layouts),codewords=1,
      parameterization=:continuous_bipolar_bits,
      objective=strategy === :lagrangian_consensus ?
        :unnormalized_consensus_augmented_lagrangian :
        :unnormalized_soft_minsum_augmented_lagrangian,
      likelihood=:pilot_variance,noise_model=:full_fft_diagonal,
      ici_half_width=m.joint_cz_ici_half_width,
      decoder_calls=audit.minsum_calls,decoder_iterations=audit.minsum_sweeps,
      internal_normalized_minsum_calls=audit.minsum_calls,
      internal_normalized_minsum_sweeps=audit.minsum_sweeps,
      internal_forward_check_to_variable_message_updates=
        audit.check_to_variable_message_updates,
      internal_forward_variable_to_check_message_updates=
        audit.variable_to_check_message_updates,
      internal_forward_directed_message_updates=
        audit.check_to_variable_message_updates+
        audit.variable_to_check_message_updates,
      internal_message_work=_joint_cz_decoder_message_work(audit),
      message_work_accounting=:forward_certificate_and_reverse_vjp_separate,
      external_bp_calls=audit.bp_calls,total_bp_calls=audit.bp_calls,
      terminal_bp_calls=0,bp_free=false,
      message_passing=:finite_normalized_min_sum,
      output_source,output_metric_representation=:unit_hard_decision_bit1_positive,
      output_codeword_syndrome=selected.output.syndrome,
      output_codeword_valid=selected.output.valid,
      solver_status=selected.output.status,
      rho=Float64(rho),outer_steps=m.iterative_refinement_rounds,
      inner_steps=m.projected_gradient_steps,
      selection=:pilot_screen_then_gradient_codeword,
      parameter_updates=m.projected_gradient_update_response && m.projected_gradient_update_bits ?
        :projected_gradient_descent : m.projected_gradient_update_response ?
        :response_only_gradient_descent : :bits_only_gradient_descent,
      initialization=:conditional_channel_likelihood,
      reference_pilot_score,fallback_used=false,
      selected_candidate=selected.index,selected_kind=strategy,
      selected_cfo_subcarriers=selected.problem.cfo,
      selected_response_change=selected.record.response_change,
      selected_bit_rms_change=selected.record.bit_rms_change,
      selected_accepted_steps=selected.record.accepted_steps,
      returned_cfo=:shared_acquisition_only,
      pilot_variance=selected.problem.variances .* selected.problem.scales.^2,
      acquisition_candidates=[(;cfo_subcarriers=p.cfo,pilot_score=p.pilot_score,
        retained=i in chosen,pilot_screen_passed=
          _joint_cz_pilot_screen_passes(p.pilot_score,reference_pilot_score,
            reference_pilot_score),optimized=i in optimized_indices)
        for (i,p) in enumerate(problems)],
      candidates=records,rounds=solver_traces,
      accepted_steps=sum(r.accepted_steps for r in records),
      solver_candidates=length(records),parity_checks=length(code.check_vars))
    if m.mode === :joint_cwz
      trace = merge(trace,(;mode=:joint_cwz,
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
    pilot_mse = mean(_pilot_mse(p.layout,
      _residual_pilot_equalize(m,p.layout,copy(p.full_fft)))
      for p in selected.problem.locals)
    (;selected.output.lpost_metric,selected.output.valid,
      selected.output.syndrome,pilot_mse)
  finally
    m.decoding_route = strategy
    m.lagrangian_penalty = rho
    m.decoder_audit = previous_audit
  end
end

function _joint_cz_candidate(m, code, layouts, observations;
    build_problem=m.mode === :joint_cwz ? _cwz_problem : _joint_cz_problem,
    initialize=m.mode === :joint_cwz ? _cwz_initial_state : _joint_cz_initial_state,
    solve_problem=m.mode === :joint_cwz ? _cwz_solve : _solve_joint_cz_projected_gradient,
    channel_llrs=m.mode === :joint_cwz ? _cwz_channel_llrs : _joint_cz_channel_llrs,
    payload_nbits=nothing)
  if m.decoding_route === :persistent_edges
    m.mode === :joint_cz || throw(ArgumentError(
      "the persistent-edge decoding route supports joint CZ only"))
    return PersistentEdge.production_candidate(
      m,code,layouts,observations;payload_nbits)
  elseif m.decoding_route === :jcade
    return _jcade_candidate(m,code,layouts,observations;
      build_problem,initialize,solve_problem,channel_llrs,payload_nbits)
  elseif m.decoding_route !== :bp_feedback
    return _joint_cz_candidate_lagrangian(m,code,layouts,observations;
      build_problem,initialize,channel_llrs)
  end
  if m.decoder_feedback_adapter === nothing
    m.terminal_bp_decode && throw(ArgumentError("terminal BP requires a feedback adapter"))
    return _joint_cz_candidate_bp_feedback(m,code,layouts,observations;
      build_problem,initialize,solve_problem,channel_llrs)
  end
  _joint_cz_candidate_adapted(m,code,layouts,observations;
    build_problem,initialize,solve_problem,channel_llrs)
end
