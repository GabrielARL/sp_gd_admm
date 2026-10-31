# JUNA modulation. Defaults reproduce the JOE paper red_1 controlled config
# n1024_cp256_sym1_p3_r0p25_dc4_sig1_ip2: QPSK, pilot every 3 active tones,
# LDPC rate 0.25, inner pilots every 2 message positions.
Base.@kwdef mutable struct Modulation <: Modulations.Modulation
  nc::UInt16 = 1024
  np::UInt16 = 256
  bw::Float64 = 1.0                    # occupied bandwidth as a fraction of the 24 kHz reference width
  dc0::Int16 = 0                       # RF-centre offset from the 24 kHz reference, in kHz
  bpc::Int = 2                       # bits per data carrier: 1=BPSK, 2=QPSK
  pilot_ratio::Float64 = 1/3         # :outer_comb fraction of active tones, snapped to 1/k; must be 0 for :before_encoding
  inner_pilot_ratio::Float64 = 1/2   # fraction of message bits: nearest 1/k for :outer_comb, exact count for :before_encoding
  pilot_placement::Symbol = :outer_comb # :before_encoding uses only exact-count known message bits, mapped as complete pilot symbols
  sync::Bool = false                 # enable the selected sync/acquisition profile
  sync_profile::Symbol = :lfm        # :lfm legacy pre/postamble; :rpchan measured-replay preamble and acquisition
  compatibility_profile::Symbol = :juna # :juna native framing/layout; :rpchan paper-compatible framing/layout
  rpchan_preamble_seed::Int = 10_001 # ReplayCh uses frame_seed + 10_000; set this from an exported frame
  rpchan_guard_s::Float64 = 0.02
  frame_duration_s::Float64 = 1.0     # frame budget including sync/guard; :frame pads to this exact duration
  ldpc_scope::Symbol = :block        # :block preserves one codeword per OFDM symbol; :frame spans one fixed-duration frame
  frame_ofdm_symbols::Int = 0        # :frame only; 0 fills the budget, positive selects a fitting symbol count
  frame_crc_bits::Int = 0            # :frame only; 0 or CRC-16/CCITT (poly 0x1021, init 0xffff, MSB first)
  rpchan_doppler_ppm::Float64 = 5_000.0
  rpchan_doppler_steps::Int = 81
  rpchan_sync_max_lag::Int = 400
  ldpc_k::Int = 340
  ldpc_n::Int = 1360
  ldpc_npc::Int = 3                  # native: all-column degree; :frame_sparse: message-column degree (parity columns have degree 1)
  ldpc_method::Symbol = :auto        # :auto preserves profile default; :evencol/:evenboth or explicit :frame_sparse
  ldpc_seed::Int = 51_001            # seed for explicit construction methods and the Rpchan-compatible systematic code
  ldpc_no4cycle::Bool = true         # requests make-ldpc cycle removal; sparse systematic builders do not enforce this flag
  bp_iterations::Int = 20            # normalized min-sum iteration limit, in 1:1000
  baseline_likelihood::Symbol = :legacy # :pilot_variance uses carrier gain and excluded-pilot residual variance for QPSK Standard/anchored PFFT
  partial_fft_parts::Int = 4
  partial_fft_nbands::Int = 16
  partial_fft_combiner::Symbol = :anchored # :rls computes the same anchored pilot fit recursively; :raw retains the archived per-band fit
  partial_fft_decision_directed::Bool = false # optional decoded-tone feedback for :rls
  partial_fft_dd_passes::Int = 2
  partial_fft_dd_weight::Float64 = 0.1
  partial_fft_dd_min_metric::Float64 = 4.0
  partial_fft_dd_max_weight::Float64 = 0.5 # total decoded-row weight / pilot-row weight
  mode::Symbol = :standard           # :standard, :pfft, :joint_cz, or :joint_cwz
  joint_cz_ici_half_width::Int = 1   # K neighboring carriers on each side of the joint-CZ response
  joint_cz_algorithm::Symbol = :projected_gradient # :calibrated_standard retains the calibrated Standard baseline
  candidate_selection::Symbol = :projected_gradient # :calibrated_seed_guard retains the calibrated-seed safeguard
  projected_gradient_update_response::Bool = true # controls for matched gradient ablations
  projected_gradient_update_bits::Bool = true
  projected_gradient_steps::Int = 30
  projected_gradient_step_size::Float64 = 0.2
  iterative_refinement_rounds::Int = 3
  parity_penalty_weight::Float64 = 2.0
  parity_penalty_shape::Symbol = :product
  parity_root_smoothing::Float64 = 1e-6
  parity_preconditioner::Symbol = :degree_bound
  parity_gradient_exponent::Float64 = 1.0
  parity_gradient_mix::Float64 = 0.0
  parity_gradient_scope::Symbol = :all_checks
  parity_gradient_model::Symbol = :power
  parity_gradient_regularization::Float64 = 0.02
  parity_gradient_warmup_exponent::Float64 = 1.0
  parity_gradient_warmup_steps::Int = 0
  parity_vertex_margin_mix::Float64 = 0.0
  binary_penalty_weight::Float64 = 0.2
  channel_anchor_weight::Float64 = 4.0
  channel_smoothness_weight::Float64 = 0.2
  feedback_damping::Float64 = 0.5
  residual_cfo_candidates::Tuple = (-4.0,-3.0,-2.0,-1.0,-0.5,0.0,0.5,1.0,2.0,3.0,4.0) # subcarrier spacings, residual to shared acquisition
  residual_cfo_keep_count::Int = 2
  relaxed_bit_initialization_temperatures::Tuple = (1.0,4.0)
  jcade_crc_early_exit::Bool = false # stop later Jcade starts after syndrome, known-bit, and frame-CRC checks pass
  decoder_feedback_adapter::Any = nothing # opt-in replacement for estimation/selection feedback
  terminal_bp_decode::Bool = false       # one normalized-min-sum decode after adapted selection
  decoding_route::Symbol = :bp_feedback # route from joint-CZ estimation to codeword decisions
  lagrangian_penalty::Float64 = 1.0
  cwz_update_weights::Bool = true    # false fixes W at unity for a matched CZ comparison
  cwz_phase_anchor::Float64 = 0.2    # mean squared free segment phase; first segment fixes global phase
  receiver_trace::Any = nothing
  code::Any = nothing
  layout::Any = nothing
  bp_scratch::Any = nothing
  decoder_audit::Any = nothing
end

const _MODE_STANDARD = :standard
const _MODE_PFFT = :pfft
const _MODE_JOINT_CZ = :joint_cz
const _MODE_JOINT_CWZ = :joint_cwz
const _CALIBRATED_MODES = (_MODE_JOINT_CZ, _MODE_JOINT_CWZ)
const _REFERENCE_CENTER_HZ = 24_000.0
const _REFERENCE_BANDWIDTH_HZ = 24_000.0
const _RECEIVER_PROFILES = (_MODE_STANDARD, _MODE_PFFT, _CALIBRATED_MODES...)

function receiver_profile(mode::Symbol)
  mode in _RECEIVER_PROFILES || throw(ArgumentError(
    "unsupported receiver mode $mode; expected :standard, :pfft, :joint_cz, or :joint_cwz"))
  mode
end
receiver_profile(m::Modulation) = receiver_profile(m.mode)

# Keep the public receiver identity separate from its shared baseline front end.
_baseline_frontend(mode::Symbol) =
  mode in (_MODE_JOINT_CZ,_MODE_JOINT_CWZ) ? _MODE_STANDARD : mode
_effective_baseline_likelihood(m::Modulation) =
  m.mode in _CALIBRATED_MODES ? :pilot_variance : m.baseline_likelihood
_uses_joint_cz_projected_gradient(m::Modulation) =
  m.mode in (_MODE_JOINT_CZ,_MODE_JOINT_CWZ) && m.joint_cz_algorithm === :projected_gradient

function Modulations.refinement_objective(m::Modulation)
  profile = receiver_profile(m)
  profile === _MODE_JOINT_CWZ && return :joint_response_combiner_code_bits
  _uses_joint_cz_projected_gradient(m) && return :joint_calibrated_response_code_bits
  if _baseline_frontend(profile) === _MODE_PFFT && m.partial_fft_combiner === :rls
    return m.partial_fft_decision_directed ? :decision_directed_rls : :pilot_rls
  end
  _baseline_frontend(profile) === _MODE_PFFT ? :pilot_band_ls : :none
end

StandardModulation(; kwargs...) =
  Modulation(; (; kwargs..., mode = _MODE_STANDARD)...)
PartialFFTModulation(; kwargs...) =
  Modulation(; (; kwargs..., mode = _MODE_PFFT)...)
JointCZModulation(; kwargs...) =
  Modulation(; (; baseline_likelihood=:pilot_variance, kwargs..., mode=_MODE_JOINT_CZ)...)
JointCWZModulation(; kwargs...) =
  Modulation(; (; baseline_likelihood=:pilot_variance, kwargs..., mode=_MODE_JOINT_CWZ)...)

receiver_trace(m::Modulation) = m.receiver_trace === nothing ? NamedTuple[] : m.receiver_trace

# Fixed numerical defaults for equalization and belief propagation.
const _RIDGE = 1e-3                            # Tikhonov ridge on the RLS normal equations
const _LLR_CLIP = 20.0                         # channel-LLR clip magnitude
const _LLR_IP = 20.0                           # inner-pilot clamp magnitude
const _BP_ALPHA = 0.8                          # normalized min-sum scaling
const _SYNC_LEN = 2048                         # LFM sync samples front+back when sync=true (best estimation in a len×bw×SNR sweep)
const _SYNC_BW = 0.9                           # chirp sweep as a fraction of the baseband band (sharp delay-Doppler peak, small guard)
const _SYNC_PROFILE_LFM = :lfm
const _SYNC_PROFILE_RPCHAN = :rpchan
const _SYNC_PROFILES = (_SYNC_PROFILE_LFM, _SYNC_PROFILE_RPCHAN)

const _COMPATIBILITY_JUNA = :juna
const _COMPATIBILITY_RPCHAN = :rpchan
const _COMPATIBILITY_PROFILES = (_COMPATIBILITY_JUNA, _COMPATIBILITY_RPCHAN)
const _RPCHAN_PREAMBLE_DURATION_S = 0.2
const _RPCHAN_PREAMBLE_GUARD_S = 0.02
const _RPCHAN_PREAMBLE_SEED = 10_001
const _RPCHAN_SYNC_MAX_LAG = 400
const _RPCHAN_DOPPLER_PPM = 5_000.0
const _RPCHAN_DOPPLER_STEPS = 81
const _RPCHAN_RESAMPLE_PHASES = 64
const _RPCHAN_RESAMPLE_HALF_SUPPORT = 8
const _LDPC_METHOD = "evencol"                 # make-ldpc construction
const _PARTIAL_FFT_NBANDS = 16                 # frequency bands for the bandwise RLS combiner
const _PFFT_COMBINER_ANCHORED = :anchored
const _PFFT_COMBINER_RAW = :raw
const _PFFT_COMBINER_RLS = :rls
const _PFFT_COMBINERS = (_PFFT_COMBINER_ANCHORED, _PFFT_COMBINER_RAW, _PFFT_COMBINER_RLS)
_anchored_combiner(m::Modulation) = m.partial_fft_combiner in (_PFFT_COMBINER_ANCHORED, _PFFT_COMBINER_RLS)
const _PFFT_ANCHOR = 0.3                       # unity-anchor weight relative to the mean per-view pilot energy
const _PFFT_ANCHOR_ITERATIONS = 2              # alternations of the leave-one-out response and the combiner
const _MAX_PARTIAL_FFT_PARTS = 16              # public complexity cap; band solves scale cubically in this count
const _BETA_FLOOR = 0.02                       # floor on the LLR-scale estimate from pilot residuals

struct _Code
  k::Int
  n::Int
  npc::Int
  method::String
  seed::Int
  no4cycle::Bool
  icols::Vector{Int}
  gen::BitMatrix
  H::BitMatrix
  check_vars::Vector{Vector{Int}}              # check_vars[c] = variable indices in check c
  var_edges::Vector{Vector{Tuple{Int,Int}}}    # var_edges[v] = (check, local-index) edges
  invperm::Vector{Int}                         # undoes the systematic column permutation
end

struct _Layout
  signature::Tuple
  active::Vector{Int}
  pilot_idx::Vector{Int}
  data_idx::Vector{Int}
  pilot_syms::Vector{ComplexF64}
  bands::Vector{Vector{Int}}
  band_ids::Vector{Int}
  active_rank::Vector{Int}
  coded_idx::Vector{Int}                      # all carriers occupied by codeword bits, including before-encoding pilots
  bit_indices::Matrix{Int}                    # [I/Q coordinate, coded tone] -> original codeword bit; zero denotes an odd final Q pad
end

struct _BPScratch
  signature::Tuple{Int,Int,Int,String,Int,Bool}
  lch::Vector{Float64}
  lpost::Vector{Float64}
  bits::Vector{Bool}
  check_parity::Vector{Bool}
  q::Vector{Vector{Float64}}
  r::Vector{Vector{Float64}}
end

mutable struct _DecoderAudit
  phase::Symbol
  terminal_bp::Bool
  feedback_bp_calls::Int
  feedback_minsum_calls::Int
  terminal_bp_calls::Int
  terminal_minsum_calls::Int
end

Base.@kwdef mutable struct _SolverDecoderAudit
  strategy::Symbol
  bp_calls::Int = 0
  minsum_calls::Int = 0
  minsum_sweeps::Int = 0
  check_to_variable_message_updates::Int = 0
  variable_to_check_message_updates::Int = 0
  certificate_calls::Int = 0
  certificate_check_message_outputs::Int = 0
  certificate_consistency_edge_checks::Int = 0
  certificate_variable_edge_visits::Int = 0
  vjp_calls::Int = 0
  vjp_active_path_check_outputs::Int = 0
  vjp_reverse_check_derivatives::Int = 0
  vjp_reverse_edge_propagations::Int = 0
end

function Modulations.init(m::Modulation, fc, fs)
  receiver_profile(m)
  m.nc = 1024
  m.np = 256
  fs_value = try
    Float64(fs)
  catch
    NaN
  end
  m.bw = isfinite(fs_value) && fs_value > 0 ?
    min(fs_value / _REFERENCE_BANDWIDTH_HZ, 1.0) : 1.0
  m.dc0 = something(_dc0_for_fc(fc), Int16(0))
  m.bpc = 2
  m.pilot_ratio = 1/3
  m.inner_pilot_ratio = 1/2
  m.pilot_placement = :outer_comb
  m.ldpc_scope = :block
  m.ldpc_k = 340
  m.ldpc_n = 1360
  m.ldpc_npc = 3
  m.partial_fft_parts = 4
  m.partial_fft_nbands = _PARTIAL_FFT_NBANDS
  # Other acquisition choices remain untouched so constructor-selected profiles survive init().
  m.code = nothing
  m.layout = nothing
  m.bp_scratch = nothing
  m.decoder_audit = nothing
  m.receiver_trace = nothing
  nothing
end

_bpc(m::Modulation) = Int(m.bpc)
_dc0_hz(m::Modulation) = 1_000.0 * Int(m.dc0)
_rf_center_hz(m::Modulation) = _REFERENCE_CENTER_HZ + _dc0_hz(m)
_occupied_bandwidth_hz(m::Modulation) = Float64(m.bw) * _REFERENCE_BANDWIDTH_HZ

function _rf_band_edges(m::Modulation)
  half_width = _occupied_bandwidth_hz(m) / 2
  centre = _rf_center_hz(m)
  (centre - half_width, centre + half_width)
end

function _dc0_for_fc(fc)
  centre = try
    Float64(fc)
  catch
    return nothing
  end
  isfinite(centre) || return nothing
  offset = (centre - _REFERENCE_CENTER_HZ) / 1_000.0
  rounded = round(Int, offset)
  typemin(Int16) <= rounded <= typemax(Int16) || return nothing
  isapprox(offset, rounded; rtol=0, atol=32eps(max(abs(offset), 1.0))) ||
    return nothing
  Int16(rounded)
end

_baseband_occupancy(m::Modulation, fs::Real) =
  _occupied_bandwidth_hz(m) / Float64(fs)
_pm(b::Bool) = b ? -1.0 : 1.0    # bipolar map 1-2b: bit 0 -> +1, bit 1 -> -1

# Snap a pilot DENSITY ratio (fraction of positions that are pilots, e.g. 0.3) to the nearest
# achievable 1/k spacing ("every k-th position"), k >= kmin. ratio <= 0 means "off" (0).
function _ratio_spacing(ratio::Real, kmin::Int)
  ratio <= 0 && return 0
  inv = 1 / ratio
  klo = max(kmin, floor(Int, inv)); khi = klo + 1
  pick = abs(ratio - 1 / klo) <= abs(ratio - 1 / khi) ? klo : khi   # nearest unit fraction 1/k to the ratio
  max(kmin, pick)
end
_pilot_spacing(m::Modulation) = _ratio_spacing(m.pilot_ratio, 2)              # outer comb pilot every k-th active tone (k >= 2)
_inner_pilot_spacing(m::Modulation) = _ratio_spacing(m.inner_pilot_ratio, 1)  # inner pilot every k-th message bit (0 = off)

# Payload capacity per LDPC codeword: one OFDM block for :block, one frame for :frame.
function Modulations.bitspersymbol(m::Modulation)
  k = Int(m.ldpc_k)
  ninner = _n_inner(m, k)
  k - ninner - (m.ldpc_scope === :frame ? m.frame_crc_bits : 0)
end

function _n_inner(m::Modulation, k::Integer)
  if m.pilot_placement === :before_encoding
    count = Float64(k) * m.inner_pilot_ratio
    isfinite(count) && 0 <= count <= k && isapprox(count, round(count); atol=1e-10, rtol=0) ||
      throw(ArgumentError("before-encoding pilot count must be an exact integer fraction of message bits"))
    return round(Int, count)
  end
  (isp = _inner_pilot_spacing(m)) < 1 ? 0 : cld(Int(k), isp)
end

function _message_pilot_positions(m::Modulation, k::Integer=m.ldpc_k)
  m.pilot_placement === :before_encoding && return collect(1:_n_inner(m, k))
  spacing = _inner_pilot_spacing(m)
  spacing < 1 ? Int[] : collect(1:spacing:Int(k))
end

_message_is_pilot(m::Modulation, position::Integer, k::Integer=m.ldpc_k) =
  m.pilot_placement === :before_encoding ? position <= _n_inner(m, k) :
  ((spacing = _inner_pilot_spacing(m)) >= 1 && (position - 1) % spacing == 0)

function Modulations.signallength(m::Modulation, nbits, fc, fs)
  isvalid(m, fc, fs) || throw(ArgumentError("invalid JUNA modulation settings"))
  nbits = _positive_nbits(nbits)
  if m.ldpc_scope === :frame
    _require_frame_payload(m, nbits)
    return _frame_sample_count(m, fs)
  end
  _nblocks(m, nbits) * _blocklen(m) + _sync_overhead(m, fs)
end

function Base.isvalid(m::Modulation, fc, fs)
  fc isa Real && fs isa Real || return false
  isfinite(fc) && isfinite(fs) && fc > 0 && fs > 0 || return false
  try
    isfinite(Float64(fc)) && isfinite(Float64(fs)) || return false
  catch
    return false
  end
  N = Int(m.nc)
  L = Int(m.np)
  N > 2 && iseven(N) || return false
  0 <= L < N || return false
  _bpc(m) in (1, 2) || return false
  0 < m.bw <= 1 && isfinite(m.bw) || return false
  isapprox(Float64(fc), _rf_center_hz(m); rtol=0,
           atol=32eps(max(abs(Float64(fc)), _REFERENCE_CENTER_HZ))) || return false
  occupancy = _baseband_occupancy(m, Float64(fs))
  0 < occupancy <= 1 + 64eps(1.0) || return false
  0 < m.ldpc_k < m.ldpc_n || return false
  0 < m.ldpc_npc <= m.ldpc_n - m.ldpc_k || return false
  1 <= m.bp_iterations <= 1000 || return false
  0 < m.partial_fft_parts <= min(N, _MAX_PARTIAL_FFT_PARTS) || return false
  0 < m.partial_fft_nbands <= N || return false
  m.partial_fft_combiner in _PFFT_COMBINERS || return false
  if m.partial_fft_decision_directed
    m.mode === _MODE_PFFT && m.partial_fft_combiner === _PFFT_COMBINER_RLS || return false
    m.bpc == 2 || return false
    1 <= m.partial_fft_dd_passes <= 10 || return false
    isfinite(m.partial_fft_dd_weight) && 0 < m.partial_fft_dd_weight < 1 || return false
    isfinite(m.partial_fft_dd_min_metric) && m.partial_fft_dd_min_metric > 0 || return false
    isfinite(m.partial_fft_dd_max_weight) && 0 < m.partial_fft_dd_max_weight <= 1 || return false
  end
  m.mode in _RECEIVER_PROFILES || return false
  m.baseline_likelihood in (:legacy, :pilot_variance) || return false
  m.joint_cz_algorithm in (:projected_gradient, :calibrated_standard) || return false
  if m.mode === _MODE_JOINT_CWZ
    m.joint_cz_algorithm === :projected_gradient || return false
    isfinite(m.cwz_phase_anchor) && m.cwz_phase_anchor > 0 || return false
  end
  if _uses_joint_cz_projected_gradient(m)
    m.bpc == 2 || return false
    m.candidate_selection in (:projected_gradient, :calibrated_seed_guard) || return false
    (m.projected_gradient_steps == 0 || m.projected_gradient_update_response || m.projected_gradient_update_bits ||
      (m.mode === _MODE_JOINT_CWZ && m.cwz_update_weights && m.partial_fft_parts > 1)) || return false
    0 <= m.joint_cz_ici_half_width < N || return false
    0 <= m.projected_gradient_steps <= 1000 || return false
    1 <= m.iterative_refinement_rounds <= 20 || return false
    isfinite(m.projected_gradient_step_size) && m.projected_gradient_step_size > 0 || return false
    all(v -> isfinite(v) && v >= 0, (m.parity_penalty_weight,
      m.binary_penalty_weight, m.channel_smoothness_weight)) || return false
    m.parity_penalty_shape in
      (:product,:smoothed_signed_sqrt,:violated_signed_sqrt,
       :product_vertex_margin) || return false
    isfinite(m.parity_root_smoothing) && 0 < m.parity_root_smoothing <= 1 || return false
    m.parity_preconditioner in (:degree_bound,:gauss_newton) || return false
    isfinite(m.parity_gradient_exponent) &&
      0 < m.parity_gradient_exponent <= 1 || return false
    isfinite(m.parity_gradient_mix) && 0 <= m.parity_gradient_mix <= 1 || return false
    m.parity_gradient_scope in (:all_checks,:violated_checks) || return false
    m.parity_gradient_model in
      (:power,:checkwise_normalized,:rational_softsign,
       :regularized_power) || return false
    isfinite(m.parity_gradient_regularization) &&
      sqrt(floatmin(Float64)) <= m.parity_gradient_regularization <= 1 ||
      return false
    isfinite(m.parity_gradient_warmup_exponent) &&
      0 < m.parity_gradient_warmup_exponent <= 1 || return false
    0 <= m.parity_gradient_warmup_steps < max(1,m.projected_gradient_steps) ||
      return false
    isfinite(m.parity_vertex_margin_mix) &&
      0 <= m.parity_vertex_margin_mix < 1 || return false
    isfinite(m.channel_anchor_weight) && m.channel_anchor_weight > 0 || return false
    0 <= m.feedback_damping <= 1 || return false
    !isempty(m.residual_cfo_candidates) && length(m.residual_cfo_candidates) <= 65 || return false
    all(v -> v isa Real && isfinite(v) && abs(v) < N/2, m.residual_cfo_candidates) || return false
    0 in m.residual_cfo_candidates || return false
    length(unique(m.residual_cfo_candidates)) == length(m.residual_cfo_candidates) || return false
    1 <= m.residual_cfo_keep_count <= length(m.residual_cfo_candidates) || return false
    1 <= length(m.relaxed_bit_initialization_temperatures) <= 8 || return false
    all(v -> v isa Real && isfinite(v) && v >= 1, m.relaxed_bit_initialization_temperatures) || return false
    (m.decoder_feedback_adapter === nothing ||
      m.decoder_feedback_adapter isa Function) || return false
    m.terminal_bp_decode && m.decoder_feedback_adapter === nothing && return false
    m.decoding_route in
      (:bp_feedback,:persistent_edges,:jcade,
       :lagrangian_consensus,:lagrangian_soft) || return false
    isfinite(m.lagrangian_penalty) && m.lagrangian_penalty > 0 || return false
    if m.decoding_route !== :bp_feedback
      m.decoder_feedback_adapter === nothing || return false
      m.terminal_bp_decode && return false
      m.candidate_selection === :projected_gradient || return false
      m.projected_gradient_steps >= 1 || return false
    end
    m.decoding_route === :persistent_edges &&
      m.mode !== _MODE_JOINT_CZ && return false
    if m.jcade_crc_early_exit
      m.decoding_route === :jcade || return false
      m.ldpc_scope === :frame || return false
      m.frame_crc_bits == 16 || return false
    end
    m.parity_penalty_shape !== :product &&
      m.decoding_route !== :jcade && return false
    m.parity_preconditioner === :gauss_newton &&
      (m.decoding_route !== :jcade ||
       m.parity_penalty_shape !== :smoothed_signed_sqrt) && return false
    if m.parity_gradient_mix == 0
      m.parity_gradient_exponent == 1 || return false
      m.parity_gradient_scope === :all_checks || return false
      m.parity_gradient_model === :power || return false
    else
      m.decoding_route === :jcade || return false
      m.parity_penalty_shape === :product || return false
      m.parity_preconditioner === :degree_bound || return false
      if m.parity_gradient_model === :power
        (m.parity_gradient_exponent < 1 ||
         m.parity_gradient_warmup_steps > 0) || return false
      elseif m.parity_gradient_model === :regularized_power
        m.parity_gradient_exponent < 1 || return false
        m.parity_gradient_scope === :violated_checks || return false
        m.parity_gradient_warmup_steps == 0 || return false
      else
        m.parity_gradient_exponent == 1 || return false
        m.parity_gradient_scope === :violated_checks || return false
        m.parity_gradient_warmup_steps == 0 || return false
      end
    end
    if m.parity_gradient_warmup_steps == 0
      m.parity_gradient_warmup_exponent == 1 || return false
    else
      m.parity_gradient_mix > 0 || return false
      m.parity_gradient_model === :power || return false
      m.parity_gradient_scope === :violated_checks || return false
      m.parity_gradient_warmup_exponent != m.parity_gradient_exponent ||
        return false
    end
    if m.parity_penalty_shape === :product_vertex_margin
      m.decoding_route === :jcade || return false
      m.parity_preconditioner === :degree_bound || return false
      m.parity_gradient_mix == 0 || return false
      m.parity_vertex_margin_mix > 0 || return false
    else
      m.parity_vertex_margin_mix == 0 || return false
    end
  elseif m.decoder_feedback_adapter !== nothing || m.terminal_bp_decode ||
         m.decoding_route !== :bp_feedback || m.jcade_crc_early_exit
    return false
  end
  if _effective_baseline_likelihood(m) === :pilot_variance
    m.bpc == 2 || return false
    _baseline_frontend(m.mode) === _MODE_PFFT && !_anchored_combiner(m) && return false
  end
  m.sync_profile in _SYNC_PROFILES || return false
  m.compatibility_profile in _COMPATIBILITY_PROFILES || return false
  m.compatibility_profile === _COMPATIBILITY_RPCHAN &&
    !isapprox(occupancy, 1.0; rtol=0, atol=64eps(1.0)) && return false
  m.ldpc_seed >= 0 || return false
  m.rpchan_preamble_seed >= 0 || return false
  isfinite(m.rpchan_guard_s) && m.rpchan_guard_s >= 0 || return false
  isfinite(m.frame_duration_s) && m.frame_duration_s > 0 || return false
  isfinite(m.rpchan_doppler_ppm) && m.rpchan_doppler_ppm >= 0 || return false
  m.rpchan_doppler_steps > 0 || return false
  m.rpchan_sync_max_lag >= 0 || return false
  m.pilot_placement in (:outer_comb, :before_encoding) || return false
  m.ldpc_scope in (:block, :frame) || return false
  m.frame_ofdm_symbols >= 0 && m.frame_crc_bits in (0, 16) || return false
  m.ldpc_scope === :block && (m.frame_ofdm_symbols != 0 || m.frame_crc_bits != 0) && return false
  0 <= m.inner_pilot_ratio <= 1 || return false
  if m.pilot_placement === :before_encoding
    m.pilot_ratio == 0 || return false
    iszero(mod(m.ldpc_n, _bpc(m))) || return false
    count = Float64(m.ldpc_k) * m.inner_pilot_ratio
    isfinite(count) && isapprox(count, round(count); atol=1e-10, rtol=0) || return false
    0 < count < m.ldpc_k && iszero(mod(round(Int, count), _bpc(m))) || return false
    symbols = if m.ldpc_scope === :frame
      try
        _frame_sample_count(m, fs)
        Modulations.frameblockcount(m, fs)
      catch
        return false
      end
    else
      1
    end
    iszero(mod(m.ldpc_n, symbols * _bpc(m))) || return false
    iszero(mod(round(Int, count), symbols * _bpc(m))) || return false
    m.ldpc_n <= symbols * _bpc(m) * length(_available_carriers(m, fs)) || return false
  else
    0 < m.pilot_ratio <= 1 || return false
    _pilot_spacing(m) > 1 || return false
  end
  Modulations.bitspersymbol(m) > 0 || return false
  if m.ldpc_scope === :frame
    layouts = try
      _frame_layouts(m, fs)
    catch error
      error isa ArgumentError || rethrow()
      return false
    end
    return all(layout -> _pilot_training_sufficient(m, layout) &&
      _baseline_pilots_sufficient(m, layout), layouts)
  end
  layout = _layout(m, fs)
  m.ldpc_n <= _bpc(m) * length(layout.coded_idx) || return false
  _pilot_training_sufficient(m, layout) || return false
  _baseline_pilots_sufficient(m, layout) || return false
  true
end

function _pilot_training_sufficient(m::Modulation, layout::_Layout)
  counts = zeros(Int, length(layout.bands))
  @inbounds for k in layout.pilot_idx
    band = layout.band_ids[k]
    band > 0 && (counts[band] += 1)
  end
  !isempty(counts) && minimum(counts) >= m.partial_fft_parts
end

# Transmit pipeline:
# 1. Pad and split payload bits into bitspersymbol-sized blocks.
# 2. Insert deterministic inner pilots into each k-bit LDPC message.
# 3. LDPC-encode each message from k information bits to n coded bits.
# 4. Map coded bits and outer pilots into the OFDM carrier layout.
# 5. IFFT, cyclic prefix, and normalization produce one complex baseband block.
# 6. Optional LFM sync wrapping produces [sync][blocks...][sync].
#    The Rpchan profile instead produces [preamble][guard][blocks...].
# With ldpc_scope=:frame, steps 1--3 instead build one message/codeword for
# every complete OFDM symbol fitting the frame; remaining frame samples are zeros.
#
# How fc, fs, bw, and dc0 affect modulation: the modem reference centre and
# width are both 24 kHz. `bw * 24 kHz` is the occupied RF width, while integer
# `dc0` records the tuned centre as `24 kHz + dc0 kHz`; that centre must equal
# `fc`. `fs` is the complex-baseband grid width, so the active FFT fraction is
# `(bw * 24 kHz) / fs`. Thus fc=25 kHz, fs=9.6 kHz, bw=0.4, dc0=1 occupies
# 20.2--29.8 kHz and fills the baseband grid. RF tuning does not shift the
# generated complex-baseband bins. `fs` also sets the optional sync time scale.
function Modulations.modulate(m::Modulation, bits, fc, fs)
  isvalid(m, fc, fs) || throw(ArgumentError("invalid JUNA modulation settings"))
  payload = Bool.(bits)
  isempty(payload) && throw(ArgumentError("JUNA modulation requires at least one payload bit"))
  m.ldpc_scope === :frame && return _modulate_frame(m, payload, fs)
  code = _code(m)
  layout = _layout(m, fs)
  bps = Modulations.bitspersymbol(m)
  pad = mod(length(payload), bps)
  pad != 0 && append!(payload, falses(bps - pad))

  nblocks = div(length(payload), bps)
  out = Vector{ComplexF64}(undef, nblocks * _blocklen(m))
  for block in 1:nblocks
    blo = 1 + (block - 1) * bps
    bhi = block * bps
    message = _build_message(m, code, @view payload[blo:bhi])
    samples = _modulate_block(m, layout, _encode(code, message))
    copyto!(out, 1 + (block - 1) * _blocklen(m), samples, 1, _blocklen(m))
  end
  m.sync || return out
  if m.sync_profile === _SYNC_PROFILE_LFM
    sync = _sync_waveform(m, fs)
    return vcat(sync, out, sync)
  end
  preamble = _rpchan_preamble(m, fs)
  vcat(preamble, zeros(ComplexF64, _rpchan_guard_length(m, fs)), out)
end

function _prepare_demodulation(m::Modulation, nbits, x, fc, fs)
  isvalid(m, fc, fs) || throw(ArgumentError("invalid JUNA modulation settings"))
  nbits2 = _positive_nbits(nbits)
  waveform = _complex_waveform(x)
  _require_finite_waveform(waveform)
  code = _code(m)
  layout = _layout(m, fs)
  nblocks = _nblocks(m, nbits2)
  nbits2, waveform, code, layout, nblocks
end

function _require_block_samples(m::Modulation, waveform, nblocks::Integer)
  required = Int(nblocks) * _blocklen(m)
  length(waveform) >= required ||
    throw(ArgumentError("received $(length(waveform)) samples, need at least $required"))
  waveform
end

function Modulations.demodulate(m::Modulation, nbits, x, fc, fs)
  m.receiver_trace = NamedTuple[]
  m.ldpc_scope === :frame && return _demodulate_frame(m, nbits, x, fc, fs)
  nbits, waveform, code, layout, nblocks =
    _prepare_demodulation(m, nbits, x, fc, fs)
  cfo = 0.0
  if m.sync
    if m.sync_profile === _SYNC_PROFILE_LFM
      waveform, cfo = _coarse_doppler(m, waveform, fc, fs, nblocks)
    else
      acquired = _rpchan_acquire(m, waveform, fc, fs, nblocks)
      waveform, cfo = acquired.payload, acquired.cfo
    end
  end
  _require_block_samples(m, waveform, nblocks)

  metrics = Vector{Float64}(undef, Int(nbits))
  pos = 1
  for block in 1:nblocks
    lo = 1 + (block - 1) * _blocklen(m)
    hi = block * _blocklen(m)
    candidate = _demodulate_block_candidate(m, code, layout, @view waveform[lo:hi])
    pos = _write_payload_metrics!(metrics, pos, m, code, candidate.lpost_metric, Int(nbits))
  end

  metrics, cfo
end

"""
    demodulate_methods(m, nbits, x, fc, fs)

Compare both receivers on already aligned OFDM blocks (without sync wrapping).
Return `(standard, partial, provenance)` with soft metrics for each receiver
and the input modulation's receiver profile. No acquisition is performed here.
"""
function demodulate_methods(m::Modulation, nbits, x, fc, fs)
  m.receiver_trace = NamedTuple[]
  m.ldpc_scope === :frame && return _demodulate_frame_methods(m, nbits, x, fc, fs)
  nbits, waveform, code, layout, nblocks =
    _prepare_demodulation(m, nbits, x, fc, fs)
  _require_block_samples(m, waveform, nblocks)

  standard = Vector{Float64}(undef, Int(nbits))
  partial = Vector{Float64}(undef, Int(nbits))
  spos = ppos = 1
  for block in 1:nblocks
    lo = 1 + (block - 1) * _blocklen(m)
    hi = block * _blocklen(m)
    yparts = _branch_observations(m, @view waveform[lo:hi])
    standard_candidate = _standard_candidate(m, code, layout, yparts)
    partial_candidate = _seed_candidate(m, code, layout, yparts)
    spos = _write_payload_metrics!(standard, spos, m, code, standard_candidate.lpost_metric, Int(nbits))
    ppos = _write_payload_metrics!(partial, ppos, m, code, partial_candidate.lpost_metric, Int(nbits))
  end

  (standard=standard, partial=partial, provenance=receiver_profile(m))
end

_blocklen(m::Modulation) = Int(m.nc) + Int(m.np)
function _positive_nbits(nbits)
  nbits isa Integer && !(nbits isa Bool) ||
    throw(ArgumentError("nbits must be a positive integer"))
  0 < nbits <= typemax(Int) || throw(ArgumentError("nbits must be a positive integer"))
  Int(nbits)
end

_nblocks(m::Modulation, nbits::Integer) =
  cld(_positive_nbits(nbits), Modulations.bitspersymbol(m))
_ndata_tones(m::Modulation, ncoded::Integer) = cld(Int(ncoded), _bpc(m))
_complex_waveform(x::AbstractVector{ComplexF64}) = x
_complex_waveform(x) = ComplexF64.(x)

# A frame-scoped codeword spans the selected complete OFDM symbols in this budget.
# Samples left after synchronization and those symbols are transmitted zeros.
function _frame_sample_count(m::Modulation, fs::Real)
  samples = m.frame_duration_s * Float64(fs)
  isfinite(samples) && 0 < samples < typemax(Int) ||
    throw(ArgumentError("frame duration must define a positive finite sample count"))
  isapprox(samples, round(samples); atol=1e-8, rtol=0) ||
    throw(ArgumentError("frame duration must contain an integer number of samples"))
  round(Int, samples)
end

function _require_frame_payload(m::Modulation, nbits::Integer)
  capacity = Modulations.bitspersymbol(m)
  0 < nbits <= capacity || throw(ArgumentError(
    "one frame holds $capacity payload bits, got $nbits"))
  Int(nbits)
end

# CRC matches the original Juna frame implementation. It is transmitted after
# the actual payload, before any zero padding or known-message insertion.
function _frame_crc16_ccitt(bits::AbstractVector{Bool})
  crc = UInt16(0xffff)
  @inbounds for bit in bits
    feedback = xor(((crc >> 15) & 0x0001) == 0x0001, bit)
    crc <<= 1
    feedback && (crc ⊻= UInt16(0x1021))
  end
  crc
end

function _frame_crc_append(payload::AbstractVector{Bool}, crc_bits::Integer)
  crc_bits == 0 && return copy(payload)
  crc_bits == 16 || throw(ArgumentError("frame CRC width must be 0 or 16 bits"))
  checksum = _frame_crc16_ccitt(payload)
  vcat(payload, Bool[((checksum >> shift) & 0x0001) == 0x0001 for shift in 15:-1:0])
end

function _frame_crc_valid(framed::AbstractVector{Bool}, crc_bits::Integer)
  crc_bits == 0 && return true
  crc_bits == 16 || throw(ArgumentError("frame CRC width must be 0 or 16 bits"))
  length(framed) >= 16 || return false
  expected = _frame_crc_append(@view(framed[1:end-16]), 16)
  framed == expected
end

function _frame_crc_valid_from_metrics(m::Modulation, code::_Code,
                                       metrics::AbstractVector{<:Real},
                                       payload_nbits::Integer)
  m.frame_crc_bits == 0 && return nothing
  payload_nbits >= 0 || throw(ArgumentError("payload bit count must be nonnegative"))
  framed_nbits = Int(payload_nbits) + m.frame_crc_bits
  framed_metrics = Vector{Float64}(undef, framed_nbits)
  next_position = _write_payload_metrics!(
    framed_metrics, 1, m, code, metrics, framed_nbits)
  next_position == framed_nbits + 1 || throw(DimensionMismatch(
    "codeword does not contain the requested framed payload"))
  _frame_crc_valid(framed_metrics .> 0, m.frame_crc_bits)
end

function _modulate_frame(m::Modulation, payload::AbstractVector{Bool}, fs)
  _require_frame_payload(m, length(payload))
  code = _code(m)
  layouts = _frame_layouts(m, fs)
  framed = _frame_crc_append(payload, m.frame_crc_bits)
  codeword = _encode(code, _build_message(m, code, framed))
  output = zeros(ComplexF64, _frame_sample_count(m, fs))
  position = 1
  if m.sync
    preamble = m.sync_profile === _SYNC_PROFILE_LFM ? _sync_waveform(m, fs) :
      _rpchan_preamble(m, fs)
    copyto!(output, position, preamble, 1, length(preamble))
    position += length(preamble)
    m.sync_profile === _SYNC_PROFILE_RPCHAN && (position += _rpchan_guard_length(m, fs))
  end
  for layout in layouts
    samples = _modulate_block(m, layout, codeword)
    copyto!(output, position, samples, 1, length(samples))
    position += length(samples)
  end
  if m.sync && m.sync_profile === _SYNC_PROFILE_LFM
    postamble = _sync_waveform(m, fs)
    copyto!(output, position, postamble, 1, length(postamble))
  end
  output
end

function _frame_observations(m::Modulation, waveform, count::Integer)
  _require_block_samples(m, waveform, count)
  [_branch_observations(m, @view waveform[1+(symbol-1)*_blocklen(m):symbol*_blocklen(m)])
   for symbol in 1:count]
end

function _frame_baseline_candidate(m::Modulation, code::_Code, layouts, observations,
                                    mode::Symbol; record_trace::Bool=true, payload_nbits=nothing)
  profile = mode
  mode = _baseline_frontend(mode)
  mode in (_MODE_STANDARD, _MODE_PFFT) || throw(ArgumentError("expected a baseline receiver"))
  mode === _MODE_PFFT && m.partial_fft_combiner === _PFFT_COMBINER_RLS &&
    return _pfft_rls_candidate(m, code, layouts, observations; record_trace, profile, payload_nbits)
  predictions = NamedTuple[]
  likelihood = _effective_baseline_likelihood(m) === :pilot_variance ?
    _baseline_likelihood_metrics(m, code, layouts, observations, mode;
      diagnostics=record_trace ? predictions : nothing) : nothing
  equalized = if likelihood !== nothing
    nothing
  elseif mode === _MODE_PFFT && m.partial_fft_combiner === _PFFT_COMBINER_ANCHORED
    weights = _frame_anchored_weights(m, layouts, observations;
      diagnostics=record_trace ? predictions : nothing)
    [_residual_pilot_equalize(m, layout, vec(transpose(w) * parts))
     for (layout, parts, w) in zip(layouts, observations, weights)]
  else
    [mode === _MODE_STANDARD ?
      _residual_pilot_equalize(m, layout, _sum_branches(parts)) :
      _equalize_from_targets(m, parts, layout, layout.pilot_idx, layout.pilot_syms)
      for (layout, parts) in zip(layouts, observations)]
  end
  metrics, pilot_mse = likelihood === nothing ?
    _frame_channel_metrics_from_equalized(m, code, layouts, equalized) :
    (likelihood.metrics, likelihood.pilot_mse)
  bp = _bp_decode(m, code, metrics)
  if record_trace
    m.receiver_trace === nothing && (m.receiver_trace = NamedTuple[])
    entry = (; mode=profile, ldpc_scope=:frame, ofdm_symbols=length(layouts),
      codewords=1, decoder_syndrome=bp.syndrome, decoder_valid=bp.valid,
      fallback_used=false, bp_input=:channel_metrics, decoder_calls=1,
      bp_iterations=m.bp_iterations, decoder_iterations=bp.iterations)
    isempty(predictions) || (entry = merge(entry, (; combiner_predictions=predictions)))
    likelihood === nothing || (entry = merge(entry, (; baseline_likelihood=_effective_baseline_likelihood(m),
      pilot_variance=likelihood.pilot_variance, variance_combiner=:fixed)))
    profile in _CALIBRATED_MODES && (entry = merge(entry, (; frontend=mode)))
    profile === _MODE_JOINT_CZ && (entry = merge(entry, (;joint_cz_algorithm=:calibrated_standard)))
    push!(m.receiver_trace, entry)
  end
  (; bp.lpost_metric, bp.valid, bp.syndrome, pilot_mse)
end

function _demodulate_frame(m::Modulation, nbits, x, fc, fs)
  isvalid(m, fc, fs) || throw(ArgumentError("invalid JUNA modulation settings"))
  nbits = _require_frame_payload(m, _positive_nbits(nbits))
  waveform = _require_finite_waveform(_complex_waveform(x))
  length(waveform) >= _frame_sample_count(m, fs) ||
    throw(ArgumentError("received waveform is shorter than the configured frame"))
  code, layouts = _code(m), _frame_layouts(m, fs)
  cfo = 0.0
  if m.sync
    if m.sync_profile === _SYNC_PROFILE_LFM
      waveform, cfo = _coarse_doppler(m, waveform, fc, fs, length(layouts))
    else
      acquired = _rpchan_acquire(m, waveform, fc, fs, length(layouts))
      waveform, cfo = acquired.payload, acquired.cfo
    end
  end
  observations = _frame_observations(m, waveform, length(layouts))
  profile = receiver_profile(m)
  candidate = _uses_joint_cz_projected_gradient(m) ?
    _joint_cz_candidate(m, code, layouts, observations; payload_nbits=nbits) :
    _frame_baseline_candidate(m, code, layouts, observations, profile; payload_nbits=nbits)
  metrics = Vector{Float64}(undef, nbits)
  _write_payload_metrics!(metrics, 1, m, code, candidate.lpost_metric, nbits)
  crc_valid = _frame_crc_valid_from_metrics(
    m, code, candidate.lpost_metric, nbits)
  # Other receivers retain diagnostic CRC reporting. The optional RLS feedback
  # path also uses the configured CRC to guard its own candidate selection.
  m.receiver_trace[end] = merge(m.receiver_trace[end], (; frame_crc_bits=m.frame_crc_bits, crc_valid))
  metrics, cfo
end

function _demodulate_frame_methods(m::Modulation, nbits, x, fc, fs)
  isvalid(m, fc, fs) || throw(ArgumentError("invalid JUNA modulation settings"))
  nbits = _require_frame_payload(m, _positive_nbits(nbits))
  waveform = _require_finite_waveform(_complex_waveform(x))
  code, layouts = _code(m), _frame_layouts(m, fs)
  observations = _frame_observations(m, waveform, length(layouts))
  outputs = map((_MODE_STANDARD, _MODE_PFFT)) do mode
    candidate = _frame_baseline_candidate(m, code, layouts, observations, mode;
      record_trace=false, payload_nbits=nbits)
    metrics = Vector{Float64}(undef, nbits)
    _write_payload_metrics!(metrics, 1, m, code, candidate.lpost_metric, nbits)
    metrics
  end
  (standard=outputs[1], partial=outputs[2], provenance=receiver_profile(m))
end

function _require_finite_waveform(waveform)
  all(isfinite, waveform) ||
    throw(ArgumentError("received waveform must contain only finite samples"))
  waveform
end

# ---- coarse Doppler via a per-frame sync (LFM) pre/postamble ----------------
_synclen(m::Modulation) =
  m.sync && m.sync_profile === _SYNC_PROFILE_LFM ? _SYNC_LEN : 0

function _sync_overhead(m::Modulation, fs)
  m.sync || return 0
  m.sync_profile === _SYNC_PROFILE_LFM && return 2 * _SYNC_LEN
  length(_rpchan_preamble(m, fs)) + _rpchan_guard_length(m, fs)
end

"""
    frameblockcount(m, fs)

Number of complete OFDM blocks in the frame. The default fills the available
sample budget. A positive `frame_ofdm_symbols` selects that many blocks in
`:frame` mode, provided they and the synchronization overhead fit.
"""
function Modulations.frameblockcount(m::Modulation, fs::Real)
  rate = Float64(fs)
  isfinite(rate) && rate > 0 ||
    throw(ArgumentError("sample rate must be finite and positive"))
  isfinite(m.frame_duration_s) && m.frame_duration_s > 0 ||
    throw(ArgumentError("frame duration must be finite and positive"))
  budget = m.ldpc_scope === :frame ? _frame_sample_count(m, rate) :
    floor(Int, m.frame_duration_s * rate)
  overhead = _sync_overhead(m, rate)
  available = budget - overhead
  blocks = fld(available, _blocklen(m))
  blocks >= 1 || throw(ArgumentError(
    "frame duration $(m.frame_duration_s) s cannot hold one complete OFDM block after $overhead overhead samples"))
  requested = m.frame_ofdm_symbols
  requested >= 0 || throw(ArgumentError("frame_ofdm_symbols must be nonnegative"))
  if requested > 0
    m.ldpc_scope === :frame || throw(ArgumentError("frame_ofdm_symbols requires frame-wide LDPC"))
    requested <= blocks || throw(ArgumentError("requested OFDM symbols exceed the frame sample budget"))
    return requested
  end
  blocks
end

"""
    framepayloadbits(m, fs)

Maximum user-payload bits carried by `frameblockcount(m, fs)` complete OFDM
blocks, after inner-pilot insertion and any frame CRC overhead.
For `ldpc_scope=:frame`, return the single frame-wide codeword capacity instead.
"""
function Modulations.framepayloadbits(m::Modulation, fs::Real)
  blocks = Modulations.frameblockcount(m, fs)
  capacity = (m.ldpc_scope === :frame ? 1 : blocks) * Modulations.bitspersymbol(m)
  capacity > 0 || throw(ArgumentError(
    "time-budgeted frame has no user-payload capacity"))
  capacity
end

# Deterministic baseband LFM (linear chirp) used as the per-frame sync pre/postamble.
function _sync_waveform(m::Modulation, fs)
  S = _synclen(m); S == 0 && return ComplexF64[]
  T = S / fs
  k = clamp(_SYNC_BW, 0.05, 1.0) * fs / T         # sweep rate (Hz/s): sweeps _SYNC_BW·fs over T
  ComplexF64[cispi(k * (n / fs - T / 2)^2) for n in 0:S-1]
end

# |matched filter| of rx against the known sync, over every lag.
function _matched_corr(rx::AbstractVector{<:Complex}, sync::AbstractVector{<:Complex})
  S = length(sync); M = length(rx); L = M - S + 1
  L <= 0 && return Float64[]
  sconj = conj.(sync)
  c = Vector{Float64}(undef, L)
  @inbounds for lag in 1:L
    acc = zero(ComplexF64)
    for i in 1:S
      acc += rx[lag + i - 1] * sconj[i]
    end
    c[lag] = abs(acc)
  end
  c
end

# Linear-interpolation resample of x to exactly `target` samples (coarse timing fix; the CP absorbs residual).
function _resample_to(x::AbstractVector{<:Complex}, target::Int)
  n = length(x)
  (target <= 0 || n == 0) && return ComplexF64[]
  n == target && return ComplexF64.(x)
  out = Vector{ComplexF64}(undef, target)
  @inbounds for i in 1:target
    pos = target == 1 ? 1.0 : 1 + (i - 1) * (n - 1) / (target - 1)
    lo = clamp(floor(Int, pos), 1, n); hi = min(lo + 1, n); frac = pos - lo
    out[i] = (1 - frac) * x[lo] + frac * x[hi]
  end
  out
end

# Coarse Doppler from two sync peaks. `fs` defines sample time and the sync
# waveform; the dimensionless observed/nominal spacing sets the resampling;
# `fc` converts that spacing error to the reported CFO in hertz.
function _coarse_doppler(m::Modulation, waveform::AbstractVector{<:Complex}, fc, fs, nblocks)
  S = _synclen(m); blocklen = _blocklen(m)
  nominal_blocks = nblocks * blocklen
  sync = _sync_waveform(m, fs)
  corr = _matched_corr(waveform, sync)
  length(corr) < 2 && return ComplexF64.(waveform), 0.0
  half = max(1, div(length(corr), 2))
  p1 = argmax(@view corr[1:half])                  # front sync start (1-based lag)
  p2 = half + argmax(@view corr[half + 1:end])     # back  sync start
  D0 = S + nominal_blocks                           # nominal start-to-start spacing
  D  = p2 - p1
  duration_scale = (D > 0 && D0 > 0) ? D / D0 : 1.0 # observed / nominal sync spacing
  bstart = p1 + round(Int, duration_scale * S)       # block region sits between the (dilated) syncs
  bstop  = p2 - 1
  (bstart < 1 || bstop > length(waveform) || bstop <= bstart) && return ComplexF64.(waveform), 0.0
  corrected = _resample_to(@view(waveform[bstart:bstop]), nominal_blocks)   # undo the dilation
  corrected, (duration_scale - 1) * fc
end

# ---- Rpchan-compatible preamble acquisition ---------------------------------

struct _RpchanResamplingFilterBank
  phases::Int
  offsets::UnitRange{Int}
  coefficients::Matrix{Float64}
end

const _RPCHAN_RESAMPLING_FILTER_BANKS =
  Dict{Tuple{Int,Int},_RpchanResamplingFilterBank}()

function _rpchan_preamble(m::Modulation, fs)
  m.sync && m.sync_profile === _SYNC_PROFILE_RPCHAN || return ComplexF64[]
  rate = Float64(fs)
  isfinite(rate) && rate > 0 || throw(ArgumentError("sample rate must be positive"))
  count = round(Int, _RPCHAN_PREAMBLE_DURATION_S * rate)
  count > 0 || throw(ArgumentError("sample rate produces an empty Rpchan preamble"))
  rng = MersenneTwister(m.rpchan_preamble_seed)
  alphabet = ComplexF64[
    (1 + 1im) / sqrt(2),
    (1 - 1im) / sqrt(2),
    (-1 + 1im) / sqrt(2),
    (-1 - 1im) / sqrt(2),
  ]
  ComplexF64[alphabet[rand(rng, eachindex(alphabet))] for _ in 1:count]
end

function _rpchan_guard_length(m::Modulation, fs)
  m.sync && m.sync_profile === _SYNC_PROFILE_RPCHAN || return 0
  rate = Float64(fs)
  isfinite(rate) && rate > 0 || throw(ArgumentError("sample rate must be positive"))
  round(Int, m.rpchan_guard_s * rate)
end

function _rpchan_doppler_grid(ppm::Real=_RPCHAN_DOPPLER_PPM,
                              steps::Integer=_RPCHAN_DOPPLER_STEPS)
  isfinite(ppm) && ppm >= 0 || throw(ArgumentError("Doppler range must be nonnegative"))
  steps > 0 || throw(ArgumentError("Doppler step count must be positive"))
  steps == 1 && return [1.0]
  collect(range(1 - Float64(ppm) * 1e-6, 1 + Float64(ppm) * 1e-6; length=Int(steps)))
end

_rpchan_doppler_grid(m::Modulation) =
  _rpchan_doppler_grid(m.rpchan_doppler_ppm, m.rpchan_doppler_steps)

@inline _rpchan_sinc(x::Float64) = abs(x) < 1e-14 ? 1.0 : sinpi(x) / (pi * x)
@inline function _rpchan_hann_sinc(x::Float64, half_support::Int)
  abs(x) >= half_support && return 0.0
  0.5 + 0.5 * cospi(abs(x) / half_support)
end

function _rpchan_filter_bank(phases::Int=_RPCHAN_RESAMPLE_PHASES,
                             half_support::Int=_RPCHAN_RESAMPLE_HALF_SUPPORT)
  phases > 0 || throw(ArgumentError("resampling phase count must be positive"))
  half_support > 0 || throw(ArgumentError("resampling support must be positive"))
  key = (phases, half_support)
  get!(_RPCHAN_RESAMPLING_FILTER_BANKS, key) do
    offsets = (-half_support + 1):half_support
    coefficients = Matrix{Float64}(undef, length(offsets), phases)
    for phase in 1:phases
      frac = (phase - 1) / phases
      total = 0.0
      for tap in eachindex(offsets)
        distance = frac - offsets[tap]
        weight = _rpchan_sinc(distance) * _rpchan_hann_sinc(distance, half_support)
        coefficients[tap, phase] = weight
        total += weight
      end
      abs(total) > 1e-15 && (@views coefficients[:, phase] ./= total)
    end
    _RpchanResamplingFilterBank(phases, offsets, coefficients)
  end
end

function _rpchan_resample(x::AbstractVector{<:Number}, scale::Real;
                           max_output_length=nothing,
                           filter_bank=_rpchan_filter_bank())
  isfinite(scale) && scale > 0 || throw(ArgumentError("time scale must be positive"))
  isempty(x) && throw(ArgumentError("cannot resample an empty sequence"))
  natural_length = floor(Int, (length(x) - 1) / Float64(scale)) + 1
  output_length = max_output_length === nothing ? natural_length :
                  min(natural_length, Int(max_output_length))
  output_length > 0 || throw(ArgumentError("resampled sequence would be empty"))
  scale == 1 && output_length == length(x) && return ComplexF64.(x)

  output = Vector{ComplexF64}(undef, output_length)
  offsets = filter_bank.offsets
  coefficients = filter_bank.coefficients
  phase_count = filter_bank.phases
  first_offset, last_offset = first(offsets), last(offsets)
  nx = length(x)
  for n in eachindex(output)
    position = 1 + (n - 1) * Float64(scale)
    center = floor(Int, position)
    fraction = position - center
    phase0 = round(Int, fraction * phase_count)
    phase = phase0 + 1
    if phase0 == phase_count
      center += 1
      phase = 1
    end

    accumulator = 0.0 + 0.0im
    weight_sum = 0.0
    if center + first_offset >= 1 && center + last_offset <= nx
      @inbounds for tap in axes(coefficients, 1)
        accumulator += x[center + offsets[tap]] * coefficients[tap, phase]
      end
      output[n] = accumulator
    else
      @inbounds for tap in axes(coefficients, 1)
        index = center + offsets[tap]
        if 1 <= index <= nx
          weight = coefficients[tap, phase]
          accumulator += x[index] * weight
          weight_sum += weight
        end
      end
      output[n] = abs(weight_sum) > 1e-15 ? accumulator / weight_sum :
                  ComplexF64(x[clamp(center, 1, nx)])
    end
  end
  output
end

function _rpchan_derotate!(waveform, correction_scale::Real, fc, fs)
  carrier_offset_hz = Float64(fc) * (1 - Float64(correction_scale))
  abs(carrier_offset_hz) < 1e-12 && return waveform
  rate = Float64(fs)
  @inbounds for n in eachindex(waveform)
    waveform[n] *= cispi(-2 * carrier_offset_hz * (n - 1) / rate)
  end
  waveform
end

function _rpchan_correlation_scores(received, reference; max_lag::Integer)
  nreference = length(reference)
  nreference > 0 || throw(ArgumentError("alignment reference must not be empty"))
  limit = min(Int(max_lag), length(received) - nreference)
  limit >= 0 || throw(ArgumentError("received sequence is shorter than its reference"))
  reference_power = sum(abs2, reference)
  reference_power > 0 || throw(ArgumentError("alignment reference must have nonzero power"))
  scores = Vector{Float64}(undef, limit + 1)
  window_power = sum(abs2, @view received[1:nreference])
  scores[1] = window_power
  @inbounds for lag in 1:limit
    window_power += abs2(received[lag + nreference]) - abs2(received[lag])
    scores[lag + 1] = window_power
  end
  Threads.@threads for lag in 0:limit
    accumulator = 0.0 + 0.0im
    @inbounds for index in 1:nreference
      accumulator += conj(reference[index]) * received[lag + index]
    end
    @inbounds begin
      power = scores[lag + 1]
      scores[lag + 1] = power == 0 ? 0.0 :
                        abs(accumulator) / sqrt(reference_power * power)
    end
  end
  scores
end

function _rpchan_align(received, reference; max_lag::Integer=_RPCHAN_SYNC_MAX_LAG)
  scores = _rpchan_correlation_scores(received, reference; max_lag=max_lag)
  lag = argmax(scores) - 1
  (lag=lag, score=scores[lag + 1], scores=scores)
end

function _rpchan_estimate_doppler(m::Modulation, received, preamble, fc, fs)
  max_output_length = length(preamble) + m.rpchan_sync_max_lag
  best = nothing
  for scale in _rpchan_doppler_grid(m)
    corrected = _rpchan_resample(
      received, scale; max_output_length=max_output_length,
    )
    _rpchan_derotate!(corrected, scale, fc, fs)
    aligned = _rpchan_align(
      corrected, preamble; max_lag=m.rpchan_sync_max_lag,
    )
    if best === nothing || aligned.score > best.score
      best = (
        scale=scale,
        ppm=(scale - 1) * 1e6,
        lag=aligned.lag,
        score=aligned.score,
      )
    end
  end
  best
end


function _rpchan_estimate_doppler(received, preamble, fc, fs)
  _rpchan_estimate_doppler(
    StandardModulation(sync=true, sync_profile=_SYNC_PROFILE_RPCHAN),
    received, preamble, fc, fs,
  )
end

function _rpchan_acquire(m::Modulation, waveform, fc, fs, nblocks::Integer)
  preamble = _rpchan_preamble(m, fs)
  estimate = _rpchan_estimate_doppler(m, waveform, preamble, fc, fs)
  corrected = _rpchan_resample(waveform, estimate.scale)
  _rpchan_derotate!(corrected, estimate.scale, fc, fs)
  aligned = _rpchan_align(corrected, preamble; max_lag=m.rpchan_sync_max_lag)
  payload_start = aligned.lag + length(preamble) + _rpchan_guard_length(m, fs) + 1
  payload_length = Int(nblocks) * _blocklen(m)
  payload_stop = payload_start + payload_length - 1
  payload_stop <= length(corrected) || throw(ArgumentError(
    "received sequence is too short after Rpchan preamble alignment"))
  (
    payload=copy(@view corrected[payload_start:payload_stop]),
    cfo=(estimate.scale - 1) * Float64(fc),
    scale=estimate.scale,
    ppm=estimate.ppm,
    lag=aligned.lag,
    score=aligned.score,
  )
end

function _write_metrics!(out::Vector{Float64}, pos::Int, payload, nbits::Int)
  @inbounds for bit in payload
    pos > nbits && break
    out[pos] = bit ? 1.0 : -1.0
    pos += 1
  end
  pos
end

function _write_payload_metrics!(out::Vector{Float64}, pos::Int, m::Modulation,
                                 code::_Code, metrics::AbstractVector{<:Real}, nbits::Int)
  mparity = code.n - code.k
  @inbounds for p in 1:code.k
    _message_is_pilot(m, p, code.k) && continue
    pos > nbits && break
    out[pos] = metrics[code.invperm[mparity + p]] > 0 ? 1.0 : -1.0
    pos += 1
  end
  pos
end

function _available_carriers(m::Modulation, fs)
  N = Int(m.nc)
  if m.compatibility_profile === _COMPATIBILITY_RPCHAN
    half = N ÷ 2
    [mod(k, N) + 1 for k in vcat(collect((-half + 1):-1), collect(1:(half - 1)))]
  else
    occupied_fraction = min(1.0, m.bw * _REFERENCE_BANDWIDTH_HZ / Float64(fs))
    nactive = clamp(floor(Int, (N - 1) * occupied_fraction), 2, N - 1)
    npos = nactive ÷ 2
    nneg = nactive - npos
    bins = vcat(collect(2:1+npos), collect(N-nneg+1:N))        # nactive carriers centred on DC
    bins
  end
end

function _layout(m::Modulation, fs)
  m.ldpc_scope === :frame && return first(_frame_layouts(m, fs))
  sig = (Int(m.nc), Float64(m.bw), _pilot_spacing(m), Int(m.partial_fft_nbands),
         Int(m.dc0), Float64(fs), m.compatibility_profile, m.pilot_placement,
         m.inner_pilot_ratio, m.ldpc_k, m.ldpc_n, m.ldpc_npc, m.ldpc_method,
         m.ldpc_seed, m.ldpc_no4cycle, _bpc(m))
  m.layout isa _Layout && m.layout.signature == sig && return m.layout::_Layout
  N, nbands, bpc = Int(m.nc), Int(m.partial_fft_nbands), _bpc(m)
  active = _available_carriers(m, fs)
  nt = _ndata_tones(m, m.ldpc_n)
  if m.pilot_placement === :before_encoding
    nt <= length(active) || throw(ArgumentError("before-encoding code does not fit the active grid"))
    # Keep the carriers nearest DC on each side. Spare bins become guard bins
    # at the occupied-band edges, rather than unbudgeted known filler symbols.
    positive = sort(filter(k -> 2 <= k <= N ÷ 2, active))
    negative = sort(filter(k -> k > N ÷ 2, active); rev=true)
    npositive = min(cld(nt, 2), length(positive))
    nnegative = nt - npositive
    if nnegative > length(negative)
      nnegative = length(negative)
      npositive = nt - nnegative
    end
    selected = Set(vcat(positive[1:npositive], negative[1:nnegative]))
    active = [k for k in active if k in selected]
    coded_idx = copy(active)
    code = _code(m)
    positions = _message_pilot_positions(m, code.k)
    known_bits = [code.invperm[code.n - code.k + p] for p in positions]
    known_set = Set(known_bits)
    other_bits = [i for i in 1:code.n if !(i in known_set)]
    npilots = length(known_bits) ÷ bpc
    pilot_slots = [fld(i * nt, npilots) + 1 for i in 0:npilots-1]
    pilot_slot_set = Set(pilot_slots)
    bit_indices = Matrix{Int}(undef, bpc, nt)
    known_cursor = other_cursor = 1
    for tone in 1:nt
      if tone in pilot_slot_set
        bit_indices[:, tone] .= @view known_bits[known_cursor:known_cursor+bpc-1]
        known_cursor += bpc
      else
        bit_indices[:, tone] .= @view other_bits[other_cursor:other_cursor+bpc-1]
        other_cursor += bpc
      end
    end
    pilot_idx = active[pilot_slots]
    pilot_set = Set(pilot_idx)
    data_idx = [k for k in active if !(k in pilot_set)]
    pilot_syms = ComplexF64[]
    for index in 1:npilots
      first_bit = _known_inner_bit(m, positions[bpc * (index - 1) + 1])
      symbol = bpc == 1 ? ComplexF64(_pm(first_bit)) :
        ComplexF64(_pm(first_bit), _pm(_known_inner_bit(m, positions[bpc * index]))) / sqrt(2)
      push!(pilot_syms, symbol)
    end
  else
    pilot_spacing = _pilot_spacing(m)
    pilot_idx = m.compatibility_profile === _COMPATIBILITY_RPCHAN ?
      active[1:pilot_spacing:end] : [k for k in active if (k - 2) % pilot_spacing == 0]
    pilot_set = Set(pilot_idx)
    data_idx = [k for k in active if !(k in pilot_set)]
    pilot_syms = m.compatibility_profile === _COMPATIBILITY_RPCHAN ?
      fill(ComplexF64(1, 1) / sqrt(2), length(pilot_idx)) :
      ComplexF64[isodd((1103515245 * k + 12345) & 0x7fffffff) ? -1.0 + 0.0im : 1.0 + 0.0im
                 for k in pilot_idx]
    coded_idx = copy(data_idx[1:min(nt, length(data_idx))])
    bit_indices = zeros(Int, bpc, length(coded_idx))
    for slot in eachindex(bit_indices)
      slot <= m.ldpc_n && (bit_indices[slot] = slot)
    end
  end
  bands = Vector{Vector{Int}}(undef, nbands)
  for b in 1:nbands
    lo, hi = _part_bounds(length(active), nbands, b)
    bands[b] = collect(@view active[lo:hi])
  end
  band_ids = zeros(Int, N)
  active_rank = zeros(Int, N)
  for (rank, k) in enumerate(active)
    active_rank[k] = rank
  end
  for (band_id, band) in enumerate(bands)
    band_ids[band] .= band_id
  end

  m.layout = _Layout(sig, active, pilot_idx, data_idx, pilot_syms, bands,
                     band_ids, active_rank, coded_idx, bit_indices)
  m.layout::_Layout
end

# Each slice uses physical FFT-bin indices and global LDPC variable indices.
# The parity-check graph is never split or rebuilt at OFDM boundaries.
function _frame_layouts(m::Modulation, fs)
  m.ldpc_scope === :frame || return [_layout(m, fs)]
  m.pilot_placement === :outer_comb && return _frame_outer_layouts(m, fs)
  m.pilot_placement === :before_encoding ||
    throw(ArgumentError("frame-wide LDPC requires pilots inserted before encoding"))
  symbols = Modulations.frameblockcount(m, fs)
  bpc = _bpc(m)
  known_count = _n_inner(m, m.ldpc_k)
  divisor = symbols * bpc
  iszero(mod(m.ldpc_n, divisor)) && iszero(mod(known_count, divisor)) ||
    throw(ArgumentError("coded bits and known bits must divide evenly into complete symbols in every OFDM block"))
  0 < known_count < m.ldpc_k || throw(ArgumentError("frame must contain known bits and payload bits"))
  signature = (Int(m.nc), Float64(m.bw), Int(m.partial_fft_nbands), Int(m.dc0),
    Float64(fs), m.compatibility_profile, m.pilot_placement, m.inner_pilot_ratio,
    m.ldpc_k, m.ldpc_n, m.ldpc_npc, m.ldpc_method, m.ldpc_seed, m.ldpc_no4cycle,
    bpc, :frame, symbols, Int(m.np), m.frame_duration_s)
  if m.layout isa Vector{_Layout} && length(m.layout) == symbols &&
      first(m.layout).signature == signature
    return m.layout::Vector{_Layout}
  end
  N, nbands = Int(m.nc), Int(m.partial_fft_nbands)
  nt = m.ldpc_n ÷ divisor
  active = _available_carriers(m, fs)
  nt <= length(active) || throw(ArgumentError("frame code does not fit the OFDM carrier grids"))
  positive = sort(filter(k -> 2 <= k <= N ÷ 2, active))
  negative = sort(filter(k -> k > N ÷ 2, active); rev=true)
  npositive = min(cld(nt, 2), length(positive))
  nnegative = nt - npositive
  if nnegative > length(negative)
    nnegative = length(negative)
    npositive = nt - nnegative
  end
  selected = Set(vcat(positive[1:npositive], negative[1:nnegative]))
  active = [k for k in active if k in selected]
  code = _code(m)
  positions = _message_pilot_positions(m, code.k)
  known = [code.invperm[code.n-code.k+p] for p in positions]
  known_set = Set(known)
  others = [bit for bit in 1:code.n if !(bit in known_set)]
  known_per_symbol = known_count ÷ symbols
  other_per_symbol = (code.n-known_count) ÷ symbols
  npilots = known_per_symbol ÷ bpc
  pilot_slots = [fld(i*nt, npilots)+1 for i in 0:npilots-1]
  pilot_slot_set = Set(pilot_slots)
  pilot_idx = active[pilot_slots]
  pilot_set = Set(pilot_idx)
  data_idx = [k for k in active if !(k in pilot_set)]
  bands = Vector{Vector{Int}}(undef, nbands)
  band_ids, active_rank = zeros(Int, N), zeros(Int, N)
  for (rank, k) in enumerate(active)
    active_rank[k] = rank
  end
  for band in 1:nbands
    lo, hi = _part_bounds(length(active), nbands, band)
    bands[band] = collect(@view active[lo:hi])
    band_ids[bands[band]] .= band
  end
  layouts = _Layout[]
  for symbol in 1:symbols
    bit_indices = Matrix{Int}(undef, bpc, nt)
    known_cursor = (symbol-1)*known_per_symbol+1
    other_cursor = (symbol-1)*other_per_symbol+1
    for tone in 1:nt
      if tone in pilot_slot_set
        bit_indices[:, tone] .= @view known[known_cursor:known_cursor+bpc-1]
        known_cursor += bpc
      else
        bit_indices[:, tone] .= @view others[other_cursor:other_cursor+bpc-1]
        other_cursor += bpc
      end
    end
    pilot_syms = ComplexF64[]
    for pilot in 1:npilots
      p = (symbol-1)*known_per_symbol+bpc*(pilot-1)+1
      i = _pm(_known_inner_bit(m, positions[p]))
      q = bpc == 1 ? 0 : _pm(_known_inner_bit(m, positions[p+1]))
      push!(pilot_syms, bpc == 1 ? ComplexF64(i) : ComplexF64(i, q)/sqrt(2))
    end
    push!(layouts, _Layout(signature, copy(active), copy(pilot_idx), copy(data_idx),
      pilot_syms, deepcopy(bands), copy(band_ids), copy(active_rank), copy(active), bit_indices))
  end
  m.layout = layouts
  layouts
end

# Keep the native outer pilot/filler symbols and contiguous transmitted code
# order. Inner known bits stay at their systematic-code positions, including
# partially known QPSK symbols; they are not moved onto the outer pilot grid.
function _frame_outer_layouts(m::Modulation, fs)
  symbols = Modulations.frameblockcount(m, fs)
  N, bpc, nbands = Int(m.nc), _bpc(m), Int(m.partial_fft_nbands)
  spacing = _pilot_spacing(m)
  spacing > 1 || throw(ArgumentError("outer pilots require spacing greater than one"))
  iszero(mod(m.ldpc_n, symbols*bpc)) ||
    throw(ArgumentError("frame code must divide into complete coded symbols per OFDM block"))
  signature = (N, Float64(m.bw), spacing, nbands, Int(m.dc0), Float64(fs),
    m.compatibility_profile, :outer_comb, m.inner_pilot_ratio, m.ldpc_k, m.ldpc_n,
    m.ldpc_npc, m.ldpc_method, m.ldpc_seed, m.ldpc_no4cycle, bpc, :frame, symbols,
    Int(m.np), m.frame_duration_s)
  if m.layout isa Vector{_Layout} && length(m.layout) == symbols &&
      first(m.layout).signature == signature
    return m.layout::Vector{_Layout}
  end
  active = _available_carriers(m, fs)
  pilot_idx = m.compatibility_profile === _COMPATIBILITY_RPCHAN ?
    active[1:spacing:end] : [k for k in active if (k-2) % spacing == 0]
  pilot_set = Set(pilot_idx)
  data_idx = [k for k in active if !(k in pilot_set)]
  nt = m.ldpc_n ÷ (symbols*bpc)
  nt <= length(data_idx) || throw(ArgumentError("frame code does not fit between outer pilots"))
  coded_idx = data_idx[1:nt]
  pilot_syms = m.compatibility_profile === _COMPATIBILITY_RPCHAN ?
    fill(ComplexF64(1, 1)/sqrt(2), length(pilot_idx)) :
    ComplexF64[isodd((1103515245*k+12345) & 0x7fffffff) ? -1.0+0.0im : 1.0+0.0im for k in pilot_idx]
  bands = Vector{Vector{Int}}(undef, nbands)
  band_ids, active_rank = zeros(Int, N), zeros(Int, N)
  for (rank, k) in enumerate(active)
    active_rank[k] = rank
  end
  for band in 1:nbands
    lo, hi = _part_bounds(length(active), nbands, band)
    bands[band] = collect(@view active[lo:hi])
    band_ids[bands[band]] .= band
  end
  layouts = _Layout[]
  for symbol in 1:symbols
    first_bit = (symbol-1)*bpc*nt+1
    bits = reshape(collect(first_bit:first_bit+bpc*nt-1), bpc, nt)
    push!(layouts, _Layout(signature, copy(active), copy(pilot_idx), copy(data_idx),
      copy(pilot_syms), deepcopy(bands), copy(band_ids), copy(active_rank), copy(coded_idx), bits))
  end
  m.layout = layouts
  layouts
end

function _code(m::Modulation)::_Code
  method = _code_method(m)
  seed = _code_seed(m, m.ldpc_k, m.ldpc_n, m.ldpc_npc)
  if m.code === nothing ||
      m.code.k != m.ldpc_k ||
      m.code.n != m.ldpc_n ||
      m.code.npc != m.ldpc_npc ||
      m.code.method != method ||
      m.code.seed != seed ||
      m.code.no4cycle != m.ldpc_no4cycle
    m.code = _create_code(
      m.ldpc_k, m.ldpc_n, m.ldpc_npc, method, seed, m.ldpc_no4cycle)
    m.bp_scratch = nothing
  end
  m.code
end

# Build the LDPC code through the shared LDPC.jl builder. `ldpc_npc` (the per-column
# check count dc) is the configurable knob; the make-ldpc construction is fixed to the
# _LDPC_METHOD constant ("evencol") and threaded in here as the `method` argument.
function _code_method(m::Modulation)
  if m.ldpc_method === :auto
    return m.compatibility_profile === _COMPATIBILITY_RPCHAN ?
      "rpchan" : _LDPC_METHOD
  end
  m.ldpc_method in (:evencol, :evenboth, :frame_sparse) || throw(ArgumentError(
    "LDPC method must be :auto, :evencol, :evenboth, or :frame_sparse"))
  String(m.ldpc_method)
end

_code_seed(m::Modulation, k::Integer, n::Integer, npc::Integer) =
  (m.ldpc_method !== :auto ||
   m.compatibility_profile === _COMPATIBILITY_RPCHAN) ? m.ldpc_seed :
  _ldpc_seed(k, n, npc)

function _create_code(k::Int, n::Int, npc::Int, method::AbstractString,
                      seed::Int=_ldpc_seed(k, n, npc), no4cycle::Bool=true)
  0 < k < n || throw(ArgumentError("LDPC dimensions must satisfy 0 < k < n"))
  0 < npc <= n - k ||
    throw(ArgumentError("LDPC column degree must satisfy 0 < npc <= n-k"))
  method in ("rpchan", "frame_sparse") &&
    return _create_sparse_systematic_code(k, n, npc, seed, method, no4cycle)
  r = try
    LDPC.build(k, n; method=method, dc=npc, no4cycle, seed=seed)
  catch err
    err isa InterruptException && rethrow()
    detail = sprint(showerror, err)
    throw(ArgumentError("failed to construct LDPC ($k, $n, npc=$npc): $detail"))
  end
  check_vars, var_edges = _build_graph(r.H)
  _Code(k, n, npc, String(method), seed, no4cycle,
        r.icols, BitMatrix(r.gen), BitMatrix(r.H),
        check_vars, var_edges, invperm(r.icols))
end

function _create_sparse_systematic_code(k::Int, n::Int, dc::Int, seed::Int,
                                        method::AbstractString,
                                        no4cycle::Bool=true)
  m = n - k
  # Identity parity columns make encoding proportional to Tanner-graph edges.
  # Selected by the Rpchan profile or explicitly by :frame_sparse. Only
  # message columns have degree dc; parity columns have degree one. This
  # builder records no4cycle but does not remove or certify four-cycles.
  column_degree = min(m, dc)
  rng = MersenneTwister(seed)
  generator = falses(m, k)
  H = falses(m, n)
  check_vars = [Int[] for _ in 1:m]
  chosen = Vector{Int}(undef, column_degree)
  @inbounds for column in 1:k
    used = 0
    while used < column_degree
      row = rand(rng, 1:m)
      any(i -> chosen[i] == row, 1:used) && continue
      used += 1
      chosen[used] = row
      generator[row, column] = true
      H[row, column] = true
      push!(check_vars[row], column)
    end
  end
  @inbounds for row in 1:m
    parity_variable = k + row
    H[row, parity_variable] = true
    push!(check_vars[row], parity_variable)
  end
  icols = vcat(collect(m+1:n), collect(1:m))
  var_edges = _build_var_edges(check_vars, n)
  _Code(k, n, dc, String(method), seed, no4cycle,
        icols, generator, H, check_vars,
        var_edges, invperm(icols))
end

function _ldpc_seed(k, n, npc)
  # Keep the reviewed paper-default graph stable while deriving distinct,
  # range-safe helper seeds for other code geometries.
  mixed = Int128(10_001) +
          (Int128(k) - 340) * 1_000_003 +
          (Int128(n) - 1360) * 1_009 +
          (Int128(npc) - 3)
  Int(mod(mixed, Int128(LDPC._MAX_TOOL_SEED) + 1))
end

function _build_graph(H)
  mrows, n = size(H)
  check_vars = [findall(@view H[c, :]) for c in 1:mrows]
  check_vars, _build_var_edges(check_vars, n)
end

function _build_var_edges(check_vars, n::Integer)
  var_edges = [Tuple{Int,Int}[] for _ in 1:n]
  for c in eachindex(check_vars)
    for (a, v) in enumerate(check_vars[c])
      push!(var_edges[v], (c, a))
    end
  end
  var_edges
end

# Systematic LDPC encoding: generator rows form the parity prefix while the
# original k message bits occupy the permuted systematic positions.
function _encode(code::_Code, bits::AbstractVector{Bool})
  length(bits) == code.k ||
    throw(ArgumentError("LDPC encoder expects $(code.k) bits, got $(length(bits))"))
  if code.method in ("rpchan", "frame_sparse")
    # For H=[G I], the transmitted order is [message; parity].
    codeword = falses(code.n)
    copyto!(codeword, 1, bits, 1, code.k)
    @inbounds for check in eachindex(code.check_vars)
      parity = false
      for variable in code.check_vars[check]
        variable <= code.k && (parity ⊻= bits[variable])
      end
      codeword[code.k + check] = parity
    end
    return codeword
  end
  nparity = code.n - code.k
  codeword = Vector{Bool}(undef, code.n)
  @inbounds for outpos in 1:code.n
    src = code.icols[outpos]
    if src <= nparity
      s = false
      for j in 1:code.k
        code.gen[src, j] && (s ⊻= bits[j])
      end
      codeword[outpos] = s
    else
      codeword[outpos] = bits[src - nparity]
    end
  end
  codeword
end

# ----- message <-> payload (inner pilots are known message bits) ---------------

_inner_bit(p::Integer) = isodd((1103515245 * p + 12345) & 0x7fffffff)

function _known_inner_bit(m::Modulation, message_position::Integer)
  if m.compatibility_profile === _COMPATIBILITY_RPCHAN
    pilot_number = m.pilot_placement === :before_encoding ? Int(message_position) :
      div(Int(message_position) - 1, _inner_pilot_spacing(m)) + 1
    return iseven(pilot_number)
  end
  _inner_bit(message_position)
end

# Expand one payload block into the k-bit LDPC message. Known inner-pilot bits
# occupy every isp-th message position; payload fills the positions between them.
function _build_message(m::Modulation, code::_Code, payload::AbstractVector{Bool})
  message = falses(code.k)
  max_payload = code.k - _n_inner(m, code.k)
  length(payload) <= max_payload ||
    throw(ArgumentError("block holds $(max_payload) payload bits, got $(length(payload))"))
  i = 1
  for p in 1:code.k
    if _message_is_pilot(m, p, code.k)
      message[p] = _known_inner_bit(m, p)
    elseif i <= length(payload)
      message[p] = payload[i]
      i += 1
    end
  end
  message
end

function _payload_from_metrics(m::Modulation, code::_Code, metrics::AbstractVector{<:Real})
  payload = Vector{Bool}(undef, code.k - _n_inner(m, code.k))
  mparity = code.n - code.k
  i = 1
  @inbounds for p in 1:code.k
    _message_is_pilot(m, p, code.k) && continue
    payload[i] = metrics[code.invperm[mparity + p]] > 0
    i += 1
  end
  payload
end

# Inner-pilot clamps are written directly into the BP channel LLR buffer.
function _apply_inner_clamps!(m::Modulation, code::_Code, lch::Vector{Float64},
                              message_block_k::Int=code.k)
  _n_inner(m, code.k) < 1 && return lch
  valid_block = 0 < message_block_k <= code.k && code.k % message_block_k == 0
  valid_block ||
    throw(ArgumentError("message block size must divide the LDPC message length"))
  mparity = code.n - code.k
  Lip = min(_LLR_CLIP, _LLR_IP)
  @inbounds for p in 1:code.k
    local_p = (p - 1) % message_block_k + 1
    _message_is_pilot(m, local_p, message_block_k) || continue
    lch[code.invperm[mparity + p]] = _known_inner_bit(m, local_p) ? -Lip : Lip
  end
  lch
end

# ----- modulation -------------------------------------------------------------

# BPSK consumes one coded bit per data tone. QPSK consumes an I/Q pair using
# bit 0 -> +1 and bit 1 -> -1, then divides by sqrt(2) for unit symbol power.
function _carrier_symbol(m::Modulation, codeword::AbstractVector{Bool}, tone::Int)
  if _bpc(m) == 1
    _bpsk_symbol(codeword[tone])
  else
    j = 2 * (tone - 1) + 1
    bI = codeword[j]
    bQ = j + 1 <= length(codeword) ? codeword[j + 1] : false
    ComplexF64(_pm(bI), _pm(bQ)) / sqrt(2)
  end
end

# Render one LDPC codeword as one CP-OFDM block: deterministic outer pilots and
# coded data fill frequency bins, IFFT creates N time samples, the final L samples
# become the cyclic prefix, and standard-deviation normalization fixes block scale.
function _modulate_block(m::Modulation, layout::_Layout, codeword::AbstractVector{Bool})
  carriers = zeros(ComplexF64, Int(m.nc))

  for (k, s) in zip(layout.pilot_idx, layout.pilot_syms)
    carriers[k] = s
  end

  if m.pilot_placement === :before_encoding || m.ldpc_scope === :frame
    for (tone, k) in enumerate(layout.coded_idx)
      bI = codeword[layout.bit_indices[1, tone]]
      carriers[k] = _bpc(m) == 1 ? ComplexF64(_pm(bI)) :
        ComplexF64(_pm(bI), _pm(codeword[layout.bit_indices[2, tone]])) / sqrt(2)
    end
    if m.pilot_placement === :outer_comb
      carriers[layout.data_idx[length(layout.coded_idx)+1:end]] .= one(ComplexF64)
    end
  else
    ntones = _ndata_tones(m, length(codeword))
    for (i, k) in enumerate(layout.data_idx)
      carriers[k] = i <= ntones ? _carrier_symbol(m, codeword, i) : one(ComplexF64)
    end
  end

  rpchan_compatible = m.compatibility_profile === _COMPATIBILITY_RPCHAN
  sym = ifft(carriers)
  rpchan_compatible && (sym .*= sqrt(Int(m.nc)))
  L = Int(m.np)
  N = Int(m.nc)
  block = Vector{ComplexF64}(undef, L + N)
  @inbounds for i in 1:L
    block[i] = sym[N - L + i]
  end
  @inbounds for i in 1:N
    block[L + i] = sym[i]
  end
  if !rpchan_compatible
    scale = std(block)
    @inbounds for i in eachindex(block)
      block[i] /= scale
    end
  end
  block
end

# ----- demodulation branches --------------------------------------------------

function _demodulate_block(m::Modulation, code::_Code, layout::_Layout, waveform)
  _payload_from_metrics(m, code, _demodulate_block_candidate(m, code, layout, waveform).lpost_metric)
end

function _demodulate_block_candidate(m::Modulation, code::_Code, layout::_Layout, waveform)
  yparts = _branch_observations(m, waveform)
  profile = receiver_profile(m)
  _uses_joint_cz_projected_gradient(m) && return _joint_cz_candidate(m, code, [layout], [yparts])
  # Benchmark baselines stop at their own front end: :standard never pays for
  # the partial-FFT seed, and :pfft is the pure partial column of
  # demodulate_methods (no standard fallback, no refinement).
  _baseline_frontend(profile) === _MODE_STANDARD && return _standard_candidate(m, code, layout, yparts)
  _baseline_frontend(profile) === _MODE_PFFT && return _seed_candidate(m, code, layout, yparts)
  throw(ArgumentError("unsupported receiver mode $(m.mode)"))
end

function _demodulate_block_standard(m::Modulation, code::_Code, layout::_Layout, yparts)
  _payload_from_metrics(m, code, _standard_candidate(m, code, layout, yparts).lpost_metric)
end

function _demodulate_block_partial(m::Modulation, code::_Code, layout::_Layout, yparts)
  _payload_from_metrics(m, code, _seed_candidate(m, code, layout, yparts).lpost_metric)
end

function _standard_candidate(m::Modulation, code::_Code, layout::_Layout, yparts)
  _effective_baseline_likelihood(m) === :pilot_variance &&
    return _baseline_likelihood_candidate(m, code, layout, yparts, _MODE_STANDARD)
  equalized = _residual_pilot_equalize(m, layout, _sum_branches(yparts))
  _candidate_from_equalized(m, code, layout, equalized)
end

function _candidate_from_equalized(m::Modulation, code::_Code, layout::_Layout, equalized, metrics=nothing)
  if metrics === nothing
    metrics, pilot_mse = _channel_metrics_from_equalized(m, code.n, layout, equalized)
  else
    pilot_mse = _pilot_mse(layout, equalized)
  end
  _decode_candidate(m, code, layout, equalized, metrics, pilot_mse)
end

function _pilot_mse(layout::_Layout, equalized)
  pilot_sum = 0.0
  @inbounds for i in eachindex(layout.pilot_idx)
    pilot_sum += abs2(equalized[layout.pilot_idx[i]] - layout.pilot_syms[i])
  end
  pilot_sum / max(length(layout.pilot_idx), 1)
end

function _channel_metrics_from_equalized(m::Modulation, ncoded::Integer,
                                         layout::_Layout, equalized)
  n = Int(ncoded)
  ntones = _ndata_tones(m, n)
  pilot_mse = _pilot_mse(layout, equalized)
  beta = max(pilot_mse, _BETA_FLOOR)
  metrics = Vector{Float64}(undef, n)
  if _bpc(m) == 1
    for t in 1:n
      s = equalized[layout.coded_idx[t]]
      metrics[layout.bit_indices[1, t]] = clamp((-2.0 * real(s)) / beta, -_LLR_CLIP, _LLR_CLIP)
    end
  else
    for t in 1:ntones
      s = equalized[layout.coded_idx[t]]
      metrics[layout.bit_indices[1, t]] = clamp((-2.0 * real(s)) / beta, -_LLR_CLIP, _LLR_CLIP)
      q = layout.bit_indices[2, t]
      0 < q <= n && (metrics[q] = clamp((-2.0 * imag(s)) / beta, -_LLR_CLIP, _LLR_CLIP))
    end
  end
  metrics, pilot_mse
end

# Restore global codeword order before the sole frame-wide BP invocation.
function _frame_channel_metrics_from_equalized(m::Modulation, code::_Code,
                                                layouts, equalizeds)
  length(layouts) == length(equalizeds) > 0 ||
    throw(DimensionMismatch("one equalized observation is required per frame OFDM symbol"))
  metrics = zeros(Float64, code.n)
  assigned = falses(code.n)
  pilot_mses = Float64[]
  for (layout, equalized) in zip(layouts, equalizeds)
    length(equalized) == Int(m.nc) ||
      throw(DimensionMismatch("equalized observations must cover the FFT grid"))
    pilot_mse = _pilot_mse(layout, equalized)
    push!(pilot_mses, pilot_mse)
    beta = max(pilot_mse, _BETA_FLOOR)
    for (tone, k) in enumerate(layout.coded_idx), coordinate in 1:_bpc(m)
      bit = layout.bit_indices[coordinate, tone]
      1 <= bit <= code.n && !assigned[bit] ||
        throw(ArgumentError("frame carrier mapping must assign each codeword bit exactly once"))
      value = coordinate == 1 ? real(equalized[k]) : imag(equalized[k])
      metrics[bit] = clamp(-2.0 * value / beta, -_LLR_CLIP, _LLR_CLIP)
      assigned[bit] = true
    end
  end
  all(assigned) || throw(ArgumentError("frame carrier mapping omitted codeword bits"))
  metrics, mean(pilot_mses)
end

function _seed_candidate(m::Modulation, code::_Code, layout::_Layout, yparts)
  m.partial_fft_combiner === _PFFT_COMBINER_RLS &&
    return _pfft_rls_candidate(m, code, [layout], [yparts])
  _effective_baseline_likelihood(m) === :pilot_variance &&
    return _baseline_likelihood_candidate(m, code, layout, yparts, _MODE_PFFT)
  equalized = _equalize_from_targets(m, yparts, layout, layout.pilot_idx, layout.pilot_syms)
  _candidate_from_equalized(m, code, layout, equalized)
end

function _decode_candidate(m::Modulation, code::_Code, layout::_Layout, equalized, metrics, pilot_mse)
  bp = _bp_decode(m, code, metrics)
  (; bp.lpost_metric, bp.valid, bp.syndrome, pilot_mse)
end

function _bp_check_normalized_min_sum!(out, incoming)
  length(out) == length(incoming) ||
    throw(DimensionMismatch("check-message buffers must have equal length"))
  L = length(incoming)
  L == 0 && return out
  if L == 1
    out[1] = _LLR_CLIP
    return out
  end

  signtot = 1.0
  min1 = Inf
  min2 = Inf
  argmin1 = 0
  @inbounds for a in 1:L
    value = incoming[a]
    signtot *= ifelse(value < 0.0, -1.0, 1.0)
    magnitude = abs(value)
    if magnitude < min1
      min2 = min1
      min1 = magnitude
      argmin1 = a
    elseif magnitude < min2
      min2 = magnitude
    end
  end
  @inbounds for a in 1:L
    sign_without_self = signtot * ifelse(incoming[a] < 0.0, -1.0, 1.0)
    magnitude = a == argmin1 ? min2 : min1
    out[a] = _BP_ALPHA * sign_without_self * magnitude
  end
  out
end

function _bp_check_sum_product!(out, incoming)
  length(out) == length(incoming) ||
    throw(DimensionMismatch("check-message buffers must have equal length"))
  L = length(incoming)
  L == 0 && return out
  if L == 1
    out[1] = _LLR_CLIP
    return out
  end
  limit = tanh(0.5 * _LLR_CLIP)
  @inbounds for a in 1:L
    product = 1.0
    for b in 1:L
      b == a && continue
      product *= tanh(0.5 * clamp(Float64(incoming[b]), -_LLR_CLIP, _LLR_CLIP))
    end
    out[a] = clamp(2atanh(clamp(product, -limit, limit)), -_LLR_CLIP, _LLR_CLIP)
  end
  out
end

function _bp_initialize_syndrome!(check_parity, code::_Code, bits)
  length(check_parity) == length(code.check_vars) ||
    throw(DimensionMismatch("check-parity workspace shape differs"))
  length(bits) == code.n || throw(DimensionMismatch("hard-decision length differs"))
  syndrome = 0
  @inbounds for check in eachindex(code.check_vars)
    parity = false
    for variable in code.check_vars[check]
      parity = xor(parity,bits[variable])
    end
    check_parity[check] = parity
    parity && (syndrome += 1)
  end
  syndrome
end

function _bp_toggle_syndrome!(check_parity, syndrome::Int, edges)
  @inbounds for (check,_) in edges
    old_parity = check_parity[check]
    check_parity[check] = !old_parity
    syndrome += old_parity ? -1 : 1
  end
  syndrome
end

# BP over the cached Tanner graph (array-based, no Dicts). The measured receiver
# uses normalized min-sum; the exact sum-product path is retained as a paper
# reference and executable cross-check.
function _audit_decoder_call!(m::Modulation, check_update!)
  audit = m.decoder_audit
  audit === nothing && return
  normalized_minsum = check_update! === _bp_check_normalized_min_sum!
  if audit isa _SolverDecoderAudit
    audit.bp_calls += 1
    throw(ArgumentError("solver strategy $(audit.strategy) invoked an external BP decoder"))
  end
  if audit.phase === :feedback
    audit.feedback_bp_calls += 1
    normalized_minsum && (audit.feedback_minsum_calls += 1)
    throw(ArgumentError("feedback adapter invoked a BP decoder during estimation or selection"))
  elseif audit.phase === :terminal
    audit.terminal_bp_calls += 1
    normalized_minsum && (audit.terminal_minsum_calls += 1)
    audit.terminal_bp || throw(ArgumentError("terminal BP is disabled for this feedback adapter"))
    normalized_minsum || throw(ArgumentError("terminal decoding must use normalized min-sum"))
    audit.terminal_bp_calls == 1 || throw(ArgumentError("feedback adapter invoked more than one terminal BP decode"))
    return
  end
  throw(ArgumentError("feedback adapter invoked a BP decoder outside an audited phase"))
end

function _bp_decode_impl(m::Modulation, code::_Code, metrics, check_update!;
                         message_block_k::Int=code.k)
  _audit_decoder_call!(m,check_update!)
  1 <= m.bp_iterations <= 1000 || throw(ArgumentError("bp_iterations must be in 1:1000"))
  cv = code.check_vars
  ve = code.var_edges
  n = code.n
  bp = _bp_scratch(m, code)
  lch = bp.lch
  lpost = bp.lpost
  bits = bp.bits
  check_parity = bp.check_parity
  q = bp.q
  r = bp.r

  @inbounds for v in 1:n
    lch[v] = -Float64(metrics[v])               # channel LLR, positive = bit 0
    lpost[v] = lch[v]
    bits[v] = false
  end
  fill!(check_parity,false)
  _apply_inner_clamps!(m, code, lch, message_block_k)

  @inbounds for c in eachindex(cv)
    qc = q[c]
    for a in eachindex(qc)
      qc[a] = lch[cv[c][a]]
    end
  end

  syndrome = typemax(Int)
  iterations = 0
  for iteration in 1:m.bp_iterations
    iterations = iteration
    for c in eachindex(cv)
      qc = q[c]
      rc = r[c]
      check_update!(rc, qc)
    end

    for v in 1:n
      total = lch[v]
      for (c, a) in ve[v]
        total += r[c][a]
      end
      lpost[v] = total
      decision = total < 0.0
      if iteration > 1 && decision != bits[v]
        syndrome = _bp_toggle_syndrome!(check_parity,syndrome,ve[v])
      end
      bits[v] = decision
      for (c, a) in ve[v]
        q[c][a] = total - r[c][a]
      end
    end

    iteration == 1 && (syndrome = _bp_initialize_syndrome!(check_parity,code,bits))
    syndrome == 0 && break
  end

  lpost_metric = Vector{Float64}(undef, n)
  @inbounds for v in 1:n
    lpost_metric[v] = -lpost[v]
  end
  (lpost_metric=lpost_metric, valid=syndrome == 0, syndrome=syndrome, iterations=iterations)
end

_bp_decode(m::Modulation, code::_Code, metrics) =
  _bp_decode_impl(m, code, metrics, _bp_check_normalized_min_sum!)

_bp_decode_sum_product(m::Modulation, code::_Code, metrics) =
  _bp_decode_impl(m, code, metrics, _bp_check_sum_product!)

function _bp_scratch(m::Modulation, code::_Code)::_BPScratch
  sig = (code.k, code.n, code.npc, code.method, code.seed, code.no4cycle)
  m.bp_scratch isa _BPScratch &&
    (m.bp_scratch::_BPScratch).signature == sig &&
    return m.bp_scratch::_BPScratch

  q = [Vector{Float64}(undef, length(vars)) for vars in code.check_vars]
  r = [Vector{Float64}(undef, length(vars)) for vars in code.check_vars]
  m.bp_scratch = _BPScratch(sig, zeros(Float64, code.n), zeros(Float64, code.n),
                            falses(code.n), zeros(Bool,length(code.check_vars)), q, r)
  m.bp_scratch::_BPScratch
end

function _syndrome_weight(code::_Code, bits::AbstractVector{Bool})
  cnt = 0
  for vars in code.check_vars
    s = false
    for v in vars
      s ⊻= bits[v]
    end
    s && (cnt += 1)
  end
  cnt
end

# ----- carrier / pilot geometry -----------------------------------------------

_bpsk_symbol(bit::Bool) = bit ? ComplexF64(-1.0, 0.0) : ComplexF64(1.0, 0.0)

function _branch_observations(m::Modulation, waveform)
  N = Int(m.nc)
  L = Int(m.np)
  yparts = Matrix{ComplexF64}(undef, m.partial_fft_parts, N)
  chunk = zeros(ComplexF64, N)

  for p in 1:m.partial_fft_parts
    lo, hi = _part_bounds(N, m.partial_fft_parts, p)
    fill!(chunk, 0.0 + 0.0im)
    @views chunk[lo:hi] .= waveform[L+lo:L+hi]
    fft!(chunk)
    @views yparts[p, :] .= chunk
  end

  yparts
end

# One phase-only combiner per OFDM symbol, fitted to predicted received pilot
# targets and anchored to unity. Frame fitting supplies predictions selected
# from temporal and frequency neighbours using their initial pilot errors.
# Without those predictions, the block estimator retains its interpolation
# between neighbouring frequency pilots; sparse pilots can then confuse
# frequency selectivity with within-symbol phase progression. The anchor
# regularizes the fit, while _residual_pilot_equalize handles magnitudes.
# Fitting transmitted targets directly (the :raw combiner) instead asks one
# weight vector per band to invert the frequency-selective channel itself.
function _anchored_symbol_weights(m::Modulation, yparts, layout::_Layout, target_idx, targets;
                                  target_weights = nothing, predicted_response = nothing,
                                  iterations::Int = _PFFT_ANCHOR_ITERATIONS)
  P = m.partial_fft_parts
  count = length(target_idx)
  count >= max(P, 2) || throw(ArgumentError("the anchored combiner needs at least max(P,2) targets"))
  predicted_response === nothing || length(predicted_response) == count ||
    throw(DimensionMismatch("one predicted response is required per combiner target"))
  positions = [layout.active_rank[k] for k in target_idx]
  issorted(positions) || throw(ArgumentError("combiner targets must be in active-carrier order"))
  _validate_target_weights(target_idx, target_weights)
  recursive = m.partial_fft_combiner === _PFFT_COMBINER_RLS
  gram = zeros(ComplexF64, P, P)
  energy = 0.0
  @inbounds for (row, k) in enumerate(target_idx)
    weight = target_weights === nothing ? 1.0 : Float64(target_weights[row])
    for p in 1:P
      yp = yparts[p, k]
      energy += weight * abs2(yp)
      cyp = conj(yp)
      if !recursive
        for q in 1:P
          gram[p, q] += weight * cyp * yparts[q, k]
        end
      end
    end
  end
  lambda = _PFFT_ANCHOR * energy / P
  A = Matrix{ComplexF64}(undef, P, P)
  b = Vector{ComplexF64}(undef, P)
  weights = ones(ComplexF64, P)
  combined = Vector{ComplexF64}(undef, count)
  response = Vector{ComplexF64}(undef, count)
  loo = Vector{ComplexF64}(undef, count)
  @inbounds for (row, k) in enumerate(target_idx)
    acc = 0.0 + 0.0im
    for p in 1:P
      acc += yparts[p, k]
    end
    combined[row] = acc
  end
  for _ in 1:iterations
    @inbounds for row in 1:count
      response[row] = combined[row] / ComplexF64(targets[row])
    end
    @inbounds for row in 1:count
      loo[row] = predicted_response === nothing ?
        (row == 1 ? response[2] : row == count ? response[count-1] :
         (response[row-1] + response[row+1]) / 2) : predicted_response[row]
    end
    copyto!(A, gram)
    fill!(b, lambda)
    @inbounds for (row, k) in enumerate(target_idx)
      weight = target_weights === nothing ? 1.0 : Float64(target_weights[row])
      target = loo[row] * ComplexF64(targets[row])
      for p in 1:P
        b[p] += weight * conj(yparts[p, k]) * target
      end
    end
    @inbounds for p in 1:P
      A[p, p] += lambda
    end
    if recursive
      weights .= _pfft_rls_weights(yparts, target_idx, loo .* targets, lambda; target_weights)
    else
      _solve_small!(weights, A, b)
    end
    @inbounds for p in 1:P
      magnitude = abs(weights[p])
      weights[p] = magnitude > eps(Float64) ? weights[p] / magnitude : 1.0 + 0.0im
    end
    @inbounds for (row, k) in enumerate(target_idx)
      acc = 0.0 + 0.0im
      for p in 1:P
        acc += yparts[p, k] * weights[p]
      end
      combined[row] = acc
    end
  end
  weights
end

# Frame-wide pilots revisit the same carrier in successive OFDM symbols.
# Compare temporal and frequency-neighbour prediction errors at the original
# full-FFT pilots. Select the smaller-error model per symbol before fitting,
# then retain that model for both iterations. Temporal predictions preserve
# the measured frequency response. Align each neighbour's common complex
# gain with that pilot excluded from the alignment. The two iterations still
# share fitted weights; this exclusion is not statistical independence.
# In a noiseless static channel the temporal prediction error is zero. Dense
# frequency pilots can instead predict better when the channel changes across
# symbols, so useful within-symbol phase corrections remain available.
# Divide squared prediction error by observed plus predicted energy: a model
# that predicts zero has score one rather than winning through attenuation.
# A single symbol has no temporal reference and retains the block estimator.
function _frame_anchored_weights(m::Modulation, layouts, observations; diagnostics=nothing)
  symbols = length(layouts)
  symbols == length(observations) || throw(DimensionMismatch("one observation per OFDM symbol"))
  symbols > 0 || throw(ArgumentError("at least one OFDM symbol is required"))
  shared = all(layout.pilot_idx == layouts[1].pilot_idx for layout in layouts)
  if symbols == 1 || !shared
    return [_anchored_symbol_weights(m, parts, layout, layout.pilot_idx, layout.pilot_syms)
            for (layout, parts) in zip(layouts, observations)]
  end
  count = length(layouts[1].pilot_idx)
  response = Matrix{ComplexF64}(undef, count, symbols)
  for symbol in 1:symbols
    layout = layouts[symbol]
    carriers = _sum_branches(observations[symbol])
    response[:, symbol] .= carriers[layout.pilot_idx] ./ layout.pilot_syms
  end
  weights = [ones(ComplexF64, m.partial_fft_parts) for _ in 1:symbols]
  predicted = Vector{ComplexF64}(undef, count)
  frequency_predicted = similar(predicted)
  temporal = trues(symbols)
  next_response = similar(response)
  for iteration in 1:_PFFT_ANCHOR_ITERATIONS
    for symbol in 1:symbols
      fill!(predicted, 0)
      neighbours = symbol == 1 ? (2:2) : symbol == symbols ? (symbols-1:symbols-1) :
        (symbol-1:2:symbol+1)
      for neighbour in neighbours
        cross = zero(ComplexF64)
        energy = 0.0
        for row in 1:count
          cross += conj(response[row, neighbour]) * response[row, symbol]
          energy += abs2(response[row, neighbour])
        end
        for row in 1:count
          held_energy = energy - abs2(response[row, neighbour])
          gain = energy > 0 && held_energy > eps(Float64) * energy ?
            (cross - conj(response[row, neighbour]) * response[row, symbol]) / held_energy :
            one(ComplexF64)
          predicted[row] += gain * response[row, neighbour] / length(neighbours)
        end
      end
      for row in 1:count
        frequency_predicted[row] = row == 1 ? response[2, symbol] :
          row == count ? response[count-1, symbol] :
          (response[row-1, symbol] + response[row+1, symbol]) / 2
      end
      if iteration == 1
        energy = sum(abs2, @view response[:, symbol])
        temporal_energy = sum(abs2, predicted)
        frequency_energy = sum(abs2, frequency_predicted)
        temporal_error = energy + temporal_energy > 0 ?
          sum(abs2(predicted[row] - response[row, symbol]) for row in 1:count) /
            (energy + temporal_energy) : 0.0
        frequency_error = energy + frequency_energy > 0 ?
          sum(abs2(frequency_predicted[row] - response[row, symbol]) for row in 1:count) /
            (energy + frequency_energy) : 0.0
        temporal[symbol] = temporal_error <= frequency_error
        if diagnostics !== nothing
          push!(diagnostics, (; symbol, target_prediction=temporal[symbol] ? :temporal : :frequency,
            temporal_error, frequency_error,
            temporal_power_ratio=energy > 0 ? temporal_energy / energy : 0.0,
            frequency_power_ratio=energy > 0 ? frequency_energy / energy : 0.0))
        end
      end
      temporal[symbol] || copyto!(predicted, frequency_predicted)
      layout = layouts[symbol]
      weights[symbol] = _anchored_symbol_weights(m, observations[symbol], layout,
        layout.pilot_idx, layout.pilot_syms; predicted_response=predicted, iterations=1)
      carriers = vec(transpose(weights[symbol]) * observations[symbol])
      next_response[:, symbol] .= carriers[layout.pilot_idx] ./ layout.pilot_syms
    end
    response, next_response = next_response, response
  end
  weights
end

function _equalize_from_targets(m::Modulation, yparts, layout::_Layout, target_idx, targets;
                                target_weights = nothing)
  _validate_target_weights(target_idx, target_weights)
  m.partial_fft_combiner in _PFFT_COMBINERS ||
    throw(ArgumentError("unsupported partial-FFT combiner $(m.partial_fft_combiner)"))
  if _anchored_combiner(m)
    weights = _anchored_symbol_weights(m, yparts, layout, target_idx, targets; target_weights)
    equalized = zeros(ComplexF64, Int(m.nc))
    @inbounds for k in layout.active
      acc = 0.0 + 0.0im
      for p in 1:m.partial_fft_parts
        acc += yparts[p, k] * weights[p]
      end
      equalized[k] = acc
    end
    return _residual_pilot_equalize(m, layout, equalized)
  end
  equalized = zeros(ComplexF64, Int(m.nc))
  P = m.partial_fft_parts
  A = Matrix{ComplexF64}(undef, P, P)
  b = Vector{ComplexF64}(undef, P)
  weights = Vector{ComplexF64}(undef, P)
  target_pos = zeros(Int, Int(m.nc))
  @inbounds for i in eachindex(target_idx)
    target_pos[target_idx[i]] = i
  end
  local_targets = Int[]
  sizehint!(local_targets, length(target_idx))

  for band in layout.bands
    empty!(local_targets)
    @inbounds for k in band
      pos = target_pos[k]
      pos == 0 || push!(local_targets, pos)
    end
    if length(local_targets) < m.partial_fft_parts
      resize!(local_targets, length(target_idx))
      @inbounds for i in eachindex(target_idx)
        local_targets[i] = i
      end
    end
    _fit_branch_weights!(
      weights, A, b, m, yparts, target_idx, targets, local_targets;
      target_weights = target_weights,
    )
    for k in band
      acc = 0.0 + 0.0im
      @inbounds for p in 1:m.partial_fft_parts
        acc += yparts[p, k] * weights[p]
      end
      equalized[k] = acc
    end
  end

  _residual_pilot_equalize(m, layout, equalized)
end

function _fit_branch_weights!(weights::Vector{ComplexF64}, A::Matrix{ComplexF64},
                              b::Vector{ComplexF64}, m::Modulation, yparts,
                              target_idx, targets, positions;
                              target_weights = nothing)
  _validate_target_weights(target_idx, target_weights)
  P = m.partial_fft_parts
  fill!(A, 0.0 + 0.0im)
  fill!(b, 0.0 + 0.0im)
  @inbounds for row in positions
    k = target_idx[row]
    target = ComplexF64(targets[row])
    row_weight = target_weights === nothing ? 1.0 : Float64(target_weights[row])
    for p in 1:P
      yp = yparts[p, k]
      cyp = conj(yp)
      b[p] += row_weight * cyp * target
      for q in 1:P
        A[p, q] += row_weight * cyp * yparts[q, k]
      end
    end
  end
  @inbounds for p in 1:P
    A[p, p] += _RIDGE
  end
  _solve_small!(weights, A, b)
end

function _validate_target_weights(target_idx, target_weights)
  target_weights === nothing && return nothing
  length(target_weights) == length(target_idx) ||
    throw(DimensionMismatch("target weights must match target indices"))
  all(weight -> isfinite(weight) && weight >= 0, target_weights) ||
    throw(ArgumentError("target weights must be finite and nonnegative"))
  nothing
end

function _solve_small!(x::Vector{ComplexF64}, A::Matrix{ComplexF64}, b::Vector{ComplexF64})
  n = length(x)
  copyto!(x, b)
  @inbounds for k in 1:n
    pivot = k
    pivot_abs = abs(A[k, k])
    for i in k+1:n
      cand = abs(A[i, k])
      if cand > pivot_abs
        pivot = i
        pivot_abs = cand
      end
    end
    if pivot != k
      for j in k:n
        A[k, j], A[pivot, j] = A[pivot, j], A[k, j]
      end
      x[k], x[pivot] = x[pivot], x[k]
    end
    akk = A[k, k]
    for i in k+1:n
      factor = A[i, k] / akk
      A[i, k] = 0.0 + 0.0im
      for j in k+1:n
        A[i, j] -= factor * A[k, j]
      end
      x[i] -= factor * x[k]
    end
  end
  @inbounds for i in n:-1:1
    acc = x[i]
    for j in i+1:n
      acc -= A[i, j] * x[j]
    end
    x[i] = acc / A[i, i]
  end
  x
end

function _residual_pilot_equalize(m::Modulation, layout::_Layout, carriers)
  equalized = carriers isa Vector{ComplexF64} ? carriers : ComplexF64.(carriers)
  response = Vector{ComplexF64}(undef, length(layout.pilot_idx))
  @inbounds for i in eachindex(layout.pilot_idx)
    response[i] = equalized[layout.pilot_idx[i]] / layout.pilot_syms[i]
  end
  pilot_positions = [layout.active_rank[k] for k in layout.pilot_idx]
  for k in layout.active
    h = _interp_response(pilot_positions, response, layout.active_rank[k])
    abs(h) > eps(Float64) && (equalized[k] /= h)
  end
  equalized
end

function _sum_branches(yparts)
  P, N = size(yparts)
  carriers = Vector{ComplexF64}(undef, N)
  @inbounds for k in 1:N
    acc = 0.0 + 0.0im
    for p in 1:P
      acc += yparts[p, k]
    end
    carriers[k] = acc
  end
  carriers
end

function _interp_response(pidx, response, k)
  pos = searchsortedlast(pidx, k)
  pos <= 0 && return response[1]
  pos >= length(pidx) && return response[end]
  t = (k - pidx[pos]) / (pidx[pos + 1] - pidx[pos])
  (1 - t) * response[pos] + t * response[pos + 1]
end

function _part_bounds(n::Int, nparts::Int, p::Int)
  base = div(n, nparts)
  extra = rem(n, nparts)
  lo = 1 + (p - 1) * base + min(p - 1, extra)
  hi = lo + base - 1 + (p <= extra ? 1 : 0)
  lo, hi
end
