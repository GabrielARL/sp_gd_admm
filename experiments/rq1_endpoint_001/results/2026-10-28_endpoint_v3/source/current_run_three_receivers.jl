#!/usr/bin/env julia

module AWGNThreeReceivers

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using Statistics
using TOML

const CORE = JadeJcade.ReceiverCore

const ATTEMPT_ID = "R5-AWGN-ISOLATION-001"
const DEFAULT_SNR_DB = collect(0.0:1.0:5.0)
const DEFAULT_FRAMES = 200
const DEFAULT_K = 2_550
const DEFAULT_N = 10_200
const DEFAULT_VARIABLE_DEGREE = 3
const DEFAULT_CODED_PILOT_FRACTION = 0.0
const GRAPH_SEED = 169_616_412
const NOISE_SEED = 20_261_012
const BP_ITERATIONS = 80
const SCALAR_STEPS = 30
const PARITY_WEIGHT = 2.0
const BINARY_WEIGHT = 0.2
const INITIAL_STEP = 0.2
const MAX_BACKTRACKS = 16
const LLR_CLIP = 20.0
const FRACTIONAL_THRESHOLD = 0.999
const RECEIVERS = ("ofdm_fec_bp", "coral_exact_gradient", "jade_gradient_then_bp")

export ScalarProblem, qpsk_symbols, awgn_llrs, noise_variance_from_ebn0,
       noise_variance_from_esn0,
       jade_awgn_llrs, objective, objective_gradient, solve_scalar,
       run_experiment, main

function _check_degree(n::Integer, k::Integer, variable_degree::Integer)
    0 < k < n || throw(ArgumentError("LDPC dimensions must satisfy 0 < k < n"))
    variable_degree > 0 || throw(ArgumentError("positive variable degree required"))
    checks = n - k
    edges = n * variable_degree
    edges % checks == 0 || throw(ArgumentError(
        "n=$n, k=$k, and variable degree $variable_degree do not form a regular check degree"))
    edges ÷ checks
end

function _attempt_id(n::Integer, k::Integer,
                     coded_pilot_fraction::Real=DEFAULT_CODED_PILOT_FRACTION)
    rate_percent = round(Int, 100k / n)
    base = k == DEFAULT_K && n == DEFAULT_N ?
        "R5-AWGN-ISOLATION-R050-001" :
        @sprintf("R5-AWGN-ISOLATION-R%03d-001", rate_percent)
    iszero(coded_pilot_fraction) && return base
    pilot_percent = round(Int, 100Float64(coded_pilot_fraction))
    @sprintf("R5-AWGN-ISOLATION-R%03d-P%03d-001", rate_percent, pilot_percent)
end

function _information_length(code_rate::Real, n::Integer)
    isfinite(code_rate) && 0 < code_rate < 1 ||
        throw(ArgumentError("code rate must lie in (0,1)"))
    raw = Float64(code_rate) * n
    k = round(Int, raw)
    isapprox(raw, k; atol=1.0e-10, rtol=0) || throw(ArgumentError(
        "code rate $code_rate does not give an integer information length for n=$n"))
    k
end

function _snr_grid(start::Real, step::Real, stop::Real)
    all(isfinite, (start, step, stop)) ||
        throw(ArgumentError("finite Eb/N0 range required"))
    step > 0 || throw(ArgumentError("positive Eb/N0 step required"))
    stop >= start || throw(ArgumentError("Eb/N0 stop must not precede start"))
    values = collect(Float64(start):Float64(step):Float64(stop))
    isapprox(last(values), stop; atol=1.0e-10, rtol=0) || throw(ArgumentError(
        "Eb/N0 step does not land on the requested stop"))
    values[end] = Float64(stop)
    values
end

"""The scalar-bit AWGN objective and its cached exact parity representation."""
struct ScalarProblem{P}
    check_vars::Vector{Vector{Int}}
    var_edges::Vector{Vector{Tuple{Int,Int}}}
    llr::Vector{Float64}
    parity_weight::Float64
    binary_weight::Float64
    plan::P
    curvature_bound::Vector{Float64}
end

function build_var_edges(checks::Vector{Vector{Int}}, n::Integer)
    edges = [Tuple{Int,Int}[] for _ in 1:n]
    for (check_index, variables) in enumerate(checks)
        for (local_index, variable) in enumerate(variables)
            1 <= variable <= n || throw(ArgumentError("parity index lies outside 1:$n"))
            push!(edges[variable], (check_index, local_index))
        end
    end
    edges
end

function ScalarProblem(checks::Vector{Vector{Int}}, n::Integer,
                       llr::AbstractVector{<:Real};
                       parity_weight::Real=PARITY_WEIGHT,
                       binary_weight::Real=BINARY_WEIGHT,
                       fixed::AbstractVector{Bool}=falses(n),
                       fixed_bits::AbstractVector{Bool}=falses(n))
    length(llr) == n || throw(DimensionMismatch("LLR vector must have length $n"))
    length(fixed) == n || throw(DimensionMismatch("fixed-bit mask must have length $n"))
    length(fixed_bits) == n ||
        throw(DimensionMismatch("fixed-bit values must have length $n"))
    all(isfinite, llr) || throw(ArgumentError("finite LLRs are required"))
    parity_weight >= 0 && binary_weight >= 0 ||
        throw(ArgumentError("penalty weights must be nonnegative"))
    copied_checks = [Int.(variables) for variables in checks]
    edges = build_var_edges(copied_checks, n)
    fixed_mask = BitVector(fixed)
    values = BitVector(fixed_bits)
    plan = CORE._joint_cz_parity_plan(copied_checks, fixed_mask, values)
    curvature = [
        fixed_mask[bit] ? 1.0 :
        (2Float64(parity_weight) * length(edges[bit]) +
         8Float64(binary_weight)) / n
        for bit in eachindex(edges)
    ]
    all(value -> isfinite(value) && value > 0, curvature) ||
        throw(ArgumentError("positive finite degree preconditioner required"))
    ScalarProblem(copied_checks, edges, Float64.(llr),
        Float64(parity_weight), Float64(binary_weight), plan, curvature)
end

ScalarProblem(code, llr::AbstractVector{<:Real}; kwargs...) =
    ScalarProblem(code.check_vars, code.n, llr; kwargs...)

"""Map bipolar I/Q coordinates to unit-energy QPSK symbols."""
function qpsk_symbols(x::AbstractVector{<:Real})
    iseven(length(x)) || throw(ArgumentError("QPSK requires an even bit count"))
    symbols = Vector{ComplexF64}(undef, length(x) ÷ 2)
    scale = inv(sqrt(2.0))
    @inbounds for q in eachindex(symbols)
        symbols[q] = complex(x[2q - 1], x[2q]) * scale
    end
    symbols
end

"""Return bipolar-bit LLRs, positive toward bit zero / xi=+1."""
function awgn_llrs(y::AbstractVector{<:Complex}, noise_variance::Real)
    isfinite(noise_variance) && noise_variance > 0 ||
        throw(ArgumentError("positive finite AWGN variance required"))
    llr = Vector{Float64}(undef, 2length(y))
    scale = 2sqrt(2.0) / Float64(noise_variance)
    @inbounds for q in eachindex(y)
        llr[2q - 1] = scale * real(y[q])
        llr[2q] = scale * imag(y[q])
    end
    llr
end

"""JADE's physical LLR after its scalar block when the fixed channel is H=I.

The scalar estimate is accepted deliberately but cannot enter this conditional
likelihood: there is no channel parameter to refit and no ICI neighbour to
cancel. Keeping this reduction explicit prevents the AWGN experiment from
silently feeding a new, non-JADE scalar-derived likelihood to BP.
"""
function jade_awgn_llrs(y::AbstractVector{<:Complex}, noise_variance::Real,
                        scalar_state::AbstractVector{<:Real})
    length(scalar_state) == 2length(y) ||
        throw(DimensionMismatch("scalar state and QPSK observation differ"))
    all(isfinite, scalar_state) || throw(ArgumentError("finite scalar state required"))
    awgn_llrs(y, noise_variance)
end

"""Complex-noise variance for unit-energy QPSK at information-bit Eb/N0."""
function noise_variance_from_ebn0(ebn0_db::Real, code_rate::Real)
    isfinite(ebn0_db) || throw(ArgumentError("finite Eb/N0 required"))
    isfinite(code_rate) && 0 < code_rate <= 1 ||
        throw(ArgumentError("code rate must lie in (0,1]"))
    1 / (2Float64(code_rate) * 10.0^(Float64(ebn0_db) / 10))
end

"""Complex-noise variance for unit-energy QPSK at symbol Es/N0."""
function noise_variance_from_esn0(esn0_db::Real)
    isfinite(esn0_db) || throw(ArgumentError("finite Es/N0 required"))
    10.0^(-Float64(esn0_db) / 10)
end

function _objective_gradient(problem::ScalarProblem, x::AbstractVector{<:Real}, workspace)
    length(x) == length(problem.llr) || throw(DimensionMismatch("scalar state differs"))
    all(isfinite, x) || throw(ArgumentError("finite scalar state required"))
    code = CORE._joint_cz_code_gradient!(workspace, x, problem.plan,
        problem.parity_weight, problem.binary_weight,
        :product, 1.0e-6, 1.0, 0.0, 0.0, :all_checks, :power, 0.02)
    n = length(x)
    effective_x = workspace.x
    channel = -dot(problem.llr, effective_x) / (2n)
    @inbounds for bit in eachindex(x)
        problem.plan.fixed[bit] ||
            (code.gradient[bit] -= problem.llr[bit] / (2n))
    end
    (; loss=channel + code.loss,
       gradient=code.gradient,
       terms=(; channel, parity=code.parity, binary=code.binary),
       gradient_kind=:exact_analytic_product)
end

function objective_gradient(problem::ScalarProblem, x::AbstractVector{<:Real})
    workspace = CORE._joint_cz_code_workspace(problem.plan, :product)
    result = _objective_gradient(problem, x, workspace)
    merge(result, (; gradient=copy(result.gradient)))
end

objective(problem::ScalarProblem, x::AbstractVector{<:Real}) =
    objective_gradient(problem, x).loss

"""Exact projected-gradient solve with the production strict-decrease line search."""
function solve_scalar(problem::ScalarProblem, initial::AbstractVector{<:Real};
                      steps::Integer=SCALAR_STEPS,
                      initial_step::Real=INITIAL_STEP)
    steps >= 0 || throw(ArgumentError("nonnegative step count required"))
    isfinite(initial_step) && initial_step > 0 ||
        throw(ArgumentError("positive finite initial step required"))
    length(initial) == length(problem.llr) ||
        throw(DimensionMismatch("initial scalar state differs"))

    x = clamp.(Float64.(initial), -1.0, 1.0)
    x[problem.plan.fixed] .= problem.plan.fixed_values[problem.plan.fixed]
    trial = similar(x)
    direction = similar(x)
    current_workspace = CORE._joint_cz_code_workspace(problem.plan, :product)
    trial_workspace = CORE._joint_cz_code_workspace(problem.plan, :product)
    current = _objective_gradient(problem, x, current_workspace)
    initial_objective = current.loss
    initial_terms = current.terms
    history = Float64[current.loss]
    accepted_steps = 0
    objective_evaluations = 1
    status = :steps_completed

    for _ in 1:Int(steps)
        @inbounds for bit in eachindex(x)
            direction[bit] = -current.gradient[bit] / problem.curvature_bound[bit]
        end
        accepted = false
        for backtrack in 0:MAX_BACKTRACKS
            step = Float64(initial_step) * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                trial[bit] = clamp(x[bit] + step * direction[bit], -1.0, 1.0)
            end
            trial[problem.plan.fixed] .=
                problem.plan.fixed_values[problem.plan.fixed]
            evaluated = _objective_gradient(problem, trial, trial_workspace)
            objective_evaluations += 1
            if isfinite(evaluated.loss) && evaluated.loss < current.loss
                x, trial = trial, x
                current_workspace, trial_workspace = trial_workspace, current_workspace
                current = evaluated
                push!(history, current.loss)
                accepted_steps += 1
                accepted = true
                break
            end
        end
        if !accepted
            status = :line_search_stalled
            break
        end
    end

    all(-1 .<= x .<= 1) || error("projected scalar state left its box")
    x[problem.plan.fixed] == problem.plan.fixed_values[problem.plan.fixed] ||
        error("projected scalar state changed a fixed coordinate")
    all(diff(history) .< 0) || error("accepted scalar step did not strictly lower J_exp")
    (; x, initial_objective,
       final_objective=current.loss,
       initial_terms,
       final_terms=current.terms,
       objective_history=history,
       accepted_steps,
       steps_requested=Int(steps),
       objective_evaluations,
       status,
       gradient_kind=:exact_analytic_product,
       pseudogradient_calls=0,
       decoder_calls=0)
end

function _coded_pilot_count(fraction::Real, n::Integer, k::Integer)
    isfinite(fraction) && 0 <= fraction < k / n || throw(ArgumentError(
        "coded pilot fraction must lie in [0, code rate)"))
    raw = Float64(fraction) * n
    count = round(Int, raw)
    isapprox(raw, count; atol=1.0e-10, rtol=0) || throw(ArgumentError(
        "coded pilot fraction must give an integer pilot-bit count"))
    iseven(count) || throw(ArgumentError(
        "QPSK requires an even pilot-bit count"))
    count
end

function _modem_and_code(; k::Integer=DEFAULT_K, n::Integer=DEFAULT_N,
                         variable_degree::Integer=DEFAULT_VARIABLE_DEGREE,
                         coded_pilot_fraction::Real=DEFAULT_CODED_PILOT_FRACTION)
    check_degree = _check_degree(n, k, variable_degree)
    pilot_count = _coded_pilot_count(coded_pilot_fraction, n, k)
    inner_pilot_ratio = pilot_count / k
    pilot_placement = pilot_count == 0 ? :outer_comb : :before_encoding
    modem = JadeJcade.Jade.Modulation(
        ldpc_k=Int(k),
        ldpc_n=Int(n),
        ldpc_npc=Int(variable_degree),
        ldpc_method=:evenboth,
        ldpc_seed=GRAPH_SEED,
        ldpc_no4cycle=false,
        inner_pilot_ratio=inner_pilot_ratio,
        pilot_ratio=0.0,
        pilot_placement=pilot_placement,
        bp_iterations=BP_ITERATIONS,
    )
    code = CORE._code(modem)
    all(length(edges) == variable_degree for edges in code.var_edges) ||
        error("LDPC variable degree changed")
    all(length(variables) == check_degree for variables in code.check_vars) ||
        error("LDPC check degree changed")
    modem, code
end

function _message_positions(code)
    parity = code.n - code.k
    [code.invperm[parity + position] for position in 1:code.k]
end

function _pilot_spec(modem, code, coded_pilot_fraction::Real)
    fixed_count = _coded_pilot_count(coded_pilot_fraction, code.n, code.k)
    message_pilot_positions = CORE._message_pilot_positions(modem, code.k)
    length(message_pilot_positions) == fixed_count || error(
        "modem pilot count differs from requested coded pilot fraction")
    message_pilot_positions == collect(1:fixed_count) || error(
        "before-encoding pilot positions changed")

    parity_count = code.n - code.k
    fixed_positions = [
        code.invperm[parity_count + position]
        for position in message_pilot_positions
    ]
    payload_message_positions = setdiff(collect(1:code.k), message_pilot_positions)
    payload_positions = [
        code.invperm[parity_count + position]
        for position in payload_message_positions
    ]
    parity_positions = setdiff(collect(1:code.n), _message_positions(code))

    payload = falses(length(payload_message_positions))
    message = CORE._build_message(modem, code, payload)
    transmitted_bits = CORE._encode(code, message)
    fixed = falses(code.n)
    fixed[fixed_positions] .= true
    fixed_bits = falses(code.n)
    fixed_bits[fixed_positions] .= transmitted_bits[fixed_positions]

    count(fixed) == fixed_count || error("fixed pilot mask count changed")
    length(payload_positions) == code.k - fixed_count || error(
        "payload position count changed")
    isempty(intersect(fixed_positions, payload_positions)) || error(
        "pilot and payload positions overlap")
    _syndrome_weight(code, transmitted_bits) == 0 || error(
        "transmitted pilot-bearing word is not a codeword")
    all(fixed_bits[fixed] .== transmitted_bits[fixed]) || error(
        "fixed pilot values differ from transmitted word")

    (; coded_pilot_fraction=Float64(coded_pilot_fraction),
       inner_pilot_ratio=fixed_count / code.k,
       fixed_count,
       pilot_symbols=fixed_count ÷ 2,
       payload_count=length(payload_positions),
       message_pilot_positions,
       fixed_positions,
       payload_positions,
       parity_positions,
       fixed,
       fixed_bits,
       transmitted_bits)
end

function _pilot_clamped_llr(llr::AbstractVector{<:Real},
                            fixed::AbstractVector{Bool},
                            fixed_bits::AbstractVector{Bool})
    length(llr) == length(fixed) == length(fixed_bits) ||
        throw(DimensionMismatch("LLR and fixed-bit vectors differ"))
    applied = clamp.(Float64.(llr), -LLR_CLIP, LLR_CLIP)
    @inbounds for bit in eachindex(applied)
        fixed[bit] && (applied[bit] = fixed_bits[bit] ? -LLR_CLIP : LLR_CLIP)
    end
    applied
end

function _decode_bp(modem, code, llr)
    applied = clamp.(llr, -LLR_CLIP, LLR_CLIP)
    timed = @timed CORE._bp_decode(modem, code, -applied)
    bp = timed.value
    hard = BitVector(bp.lpost_metric .> 0)
    (; hard, posterior=copy(bp.lpost_metric),
       syndrome=Int(bp.syndrome), valid=Bool(bp.valid),
       iterations=Int(bp.iterations), seconds=timed.time,
       bytes=timed.bytes, applied)
end

function _syndrome_weight(code, hard::AbstractVector{Bool})
    CORE._syndrome_weight(code, hard)
end

function _sha_vector(values::AbstractVector)
    io = IOBuffer()
    if eltype(values) <: Bool
        write(io, UInt8.(values))
    else
        write(io, reinterpret(UInt8, collect(values)))
    end
    bytes2hex(sha256(take!(io)))
end

function _sha_graph(code)
    io = IOBuffer()
    for variables in code.check_vars
        write(io, htol(Int32(length(variables))))
        for variable in variables
            write(io, htol(Int32(variable)))
        end
    end
    bytes2hex(sha256(take!(io)))
end

function _git_output(root, args...)
    try
        strip(read(`git -C $root $args`, String))
    catch
        "unavailable"
    end
end

function _file_sha(path)
    open(path) do io
        bytes2hex(sha256(io))
    end
end

function _csv_value(value)
    value === missing && return ""
    value isa Bool && return lowercase(string(value))
    value isa AbstractFloat && return @sprintf("%.17g", value)
    text = string(value)
    occursin(r"[,\"\n\r]", text) || return text
    "\"" * replace(text, "\"" => "\"\"") * "\""
end

function _write_csv(path, rows, columns)
    open(path, "w") do io
        println(io, join(string.(columns), ','))
        for row in rows
            println(io, join((_csv_value(getproperty(row, column)) for column in columns), ','))
        end
    end
end

function _aggregate(rows, frames::Integer, snr_db_values,
                    payload_count::Integer, n::Integer)
    aggregates = NamedTuple[]
    for snr_db in snr_db_values, receiver in RECEIVERS
        group = [row for row in rows if row.snr_db == snr_db && row.receiver == receiver]
        length(group) == frames || error("incomplete aggregate for $receiver at $snr_db dB")
        coded_errors = sum(row.coded_bit_errors for row in group)
        information_errors = sum(row.information_bit_errors for row in group)
        coded_bits = frames * n
        information_bits = frames * payload_count
        push!(aggregates, (;
            snr_db,
            ebn0_db=snr_db,
            esn0_db=snr_db,
            receiver,
            frames,
            coded_bits,
            coded_bit_errors=coded_errors,
            coded_ber=coded_errors / coded_bits,
            information_bits,
            information_bit_errors=information_errors,
            information_ber=information_errors / information_bits,
            frame_errors=count(row -> row.frame_error, group),
            frame_error_rate=mean(row.frame_error for row in group),
            parity_valid_frames=count(row -> row.parity_valid, group),
            parity_valid_rate=mean(row.parity_valid for row in group),
            mean_syndrome=mean(row.syndrome_weight for row in group),
            mean_decoder_iterations=mean(row.decoder_iterations for row in group),
            mean_accepted_gradient_steps=mean(row.accepted_gradient_steps for row in group),
            mean_initial_objective=mean(row.initial_objective for row in group),
            mean_final_objective=mean(row.final_objective for row in group),
            mean_fractional_bits=mean(row.fractional_bits for row in group),
            mean_seconds=mean(row.seconds for row in group),
            total_allocated_bytes=sum(row.allocated_bytes for row in group),
        ))
    end
    aggregates
end

function _write_manifest(path, repository_root, code, frames,
                         snr_db_values, variable_degree, check_degree,
                         attempt_id, pilot)
    runner = abspath(@__FILE__)
    plotter = joinpath(@__DIR__, "plot_three_receivers.py")
    tests = joinpath(@__DIR__, "test_three_receivers.jl")
    project = joinpath(repository_root, "Project.toml")
    manifest = joinpath(repository_root, "Manifest.toml")
    data = Dict(
        "schema_version" => 1,
        "attempt_id" => attempt_id,
        "classification" => "explicit Route-5 AWGN isolation; not a new receiver route",
        "created_utc" => string(now(UTC)),
        "source" => Dict(
            "repository" => repository_root,
            "head" => _git_output(repository_root, "rev-parse", "HEAD"),
            "branch" => _git_output(repository_root, "branch", "--show-current"),
            "status" => _git_output(repository_root, "status", "--porcelain=v1", "--untracked-files=all"),
            "runner_sha256" => _file_sha(runner),
            "plotter_sha256" => _file_sha(plotter),
            "test_sha256" => _file_sha(tests),
            "project_sha256" => _file_sha(project),
            "manifest_sha256" => _file_sha(manifest),
        ),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_threads" => Threads.nthreads(),
            "blas_threads" => BLAS.get_num_threads(),
            "cpu" => Sys.CPU_NAME,
        ),
        "channel" => Dict(
            "model" => "post-FFT unit-gain complex AWGN",
            "H" => "identity",
            "ici" => false,
            "cfo" => false,
            "pilots" => pilot.pilot_symbols,
            "coded_pilot_bits" => pilot.fixed_count,
            "coded_pilot_fraction" => pilot.coded_pilot_fraction,
            "pilot_fraction_reference" => "coded_bits",
            "pilot_role" => "known LDPC message coordinates; no channel estimation",
            "qpsk_symbol_energy" => 1.0,
            "snr_definition" => "unit-QPSK Es/N0; common physical noise across pilot fractions",
            "snr_db" => snr_db_values,
            "noise_variance" => [noise_variance_from_esn0(snr)
                                 for snr in snr_db_values],
            "shared_unit_noise_across_snr" => true,
        ),
        "code" => Dict(
            "k" => code.k,
            "n" => code.n,
            "rate" => code.k / code.n,
            "payload_bits" => pilot.payload_count,
            "payload_rate" => pilot.payload_count / code.n,
            "inner_pilot_ratio" => pilot.inner_pilot_ratio,
            "variable_degree" => variable_degree,
            "check_degree" => check_degree,
            "method" => code.method,
            "seed" => code.seed,
            "no4cycle" => code.no4cycle,
            "graph_sha256" => _sha_graph(code),
            "fixed_mask_sha256" => _sha_vector(pilot.fixed),
            "fixed_values_sha256" => _sha_vector(pilot.fixed_bits),
            "payload_positions_sha256" => _sha_vector(pilot.payload_positions),
            "transmitted_word_sha256" => _sha_vector(pilot.transmitted_bits),
            "transmitted_word" => "zero payload with deterministic known message bits before encoding",
        ),
        "protocol" => Dict(
            "frames_per_snr" => frames,
            "noise_seed_base" => NOISE_SEED,
            "paired_inputs" => true,
            "receivers" => collect(RECEIVERS),
            "bp_rule" => "normalized min-sum",
            "bp_normalization" => 0.8,
            "bp_iteration_limit" => BP_ITERATIONS,
            "llr_clip" => LLR_CLIP,
            "pilot_constraints" => "exact fixed coordinates for CORAL; clipped known-bit LLRs for normalized min-sum",
        ),
        "scalar_block" => Dict(
            "objective" => "J_exp: uncertainty-aware additive AWGN likelihood plus exact product parity and binary penalties",
            "equation" => "-L'x/(2n) + mu_p/n sum_c(1-prod_i x_i)^2 + mu_b/n sum_i(1-x_i^2)^2",
            "parity_weight" => PARITY_WEIGHT,
            "binary_weight" => BINARY_WEIGHT,
            "steps" => SCALAR_STEPS,
            "initial_step" => INITIAL_STEP,
            "maximum_backtracks" => MAX_BACKTRACKS,
            "initialization" => "tanh(clipped physical LLR / 2), then exact fixed-pilot projection",
            "gradient" => "exact analytical product gradient",
            "pseudogradient_calls" => 0,
            "shared_by_coral_and_pre_bp_jade" => true,
        ),
    )
    open(path, "w") do io
        TOML.print(io, data; sorted=true)
    end
end

function _archive_source(output)
    source = joinpath(output, "source")
    mkpath(source)
    for name in ("run_three_receivers.jl", "test_three_receivers.jl",
                 "plot_three_receivers.py", "p20_experiment_card.md")
        cp(joinpath(@__DIR__, name), joinpath(source, name); force=true)
    end
end

function _write_completion(output, checks, attempt_id)
    files = Dict{String,String}()
    for name in ("manifest.toml", "frames.csv", "aggregate.csv",
                 "ber_vs_snr.pdf", "ber_vs_snr.png",
                 "parity_valid_rate.pdf", "parity_valid_rate.png")
        path = joinpath(output, name)
        isfile(path) && (files[name] = _file_sha(path))
    end
    data = Dict(
        "schema_version" => 1,
        "attempt_id" => attempt_id,
        "completed_utc" => string(now(UTC)),
        "status" => "complete",
        "checks" => checks,
        "output_sha256" => files,
    )
    open(joinpath(output, "completion.toml"), "w") do io
        TOML.print(io, data; sorted=true)
    end
end

function run_experiment(output::AbstractString; frames::Integer=DEFAULT_FRAMES,
                        make_plot::Bool=true, k::Integer=DEFAULT_K,
                        n::Integer=DEFAULT_N,
                        variable_degree::Integer=DEFAULT_VARIABLE_DEGREE,
                        coded_pilot_fraction::Real=DEFAULT_CODED_PILOT_FRACTION,
                        snr_db_values=DEFAULT_SNR_DB)
    frames > 0 || throw(ArgumentError("positive frame count required"))
    iseven(n) || throw(ArgumentError("QPSK requires an even coded block length"))
    snr_db_values = Float64.(collect(snr_db_values))
    isempty(snr_db_values) && throw(ArgumentError("nonempty Es/N0 grid required"))
    all(isfinite, snr_db_values) || throw(ArgumentError("finite Es/N0 grid required"))
    all(diff(snr_db_values) .> 0) ||
        throw(ArgumentError("strictly increasing Es/N0 grid required"))
    check_degree = _check_degree(n, k, variable_degree)
    attempt_id = _attempt_id(n, k, coded_pilot_fraction)
    output = abspath(output)
    ispath(output) && !isempty(readdir(output)) &&
        throw(ArgumentError("output directory must be absent or empty: $output"))
    mkpath(output)
    repository_root = realpath(joinpath(@__DIR__, "..", ".."))
    realpath(dirname(dirname(pathof(JadeJcade)))) == repository_root ||
        error("loaded JadeJcade from a different checkout")
    Threads.nthreads() == 1 || error("experiment requires one Julia thread")
    BLAS.set_num_threads(1)

    bp_modem, code = _modem_and_code(
        ; k, n, variable_degree, coded_pilot_fraction)
    jade_modem, jade_code = _modem_and_code(
        ; k, n, variable_degree, coded_pilot_fraction)
    _sha_graph(jade_code) == _sha_graph(code) || error("paired decoder graphs differ")
    jade_code.invperm == code.invperm || error("paired decoder permutations differ")
    jade_code.H == code.H || error("paired decoder parity-check matrices differ")
    jade_code.gen == code.gen || error("paired decoder generators differ")
    pilot = _pilot_spec(bp_modem, code, coded_pilot_fraction)
    jade_pilot = _pilot_spec(jade_modem, jade_code, coded_pilot_fraction)
    pilot.fixed == jade_pilot.fixed || error("paired pilot masks differ")
    pilot.fixed_bits == jade_pilot.fixed_bits || error("paired pilot values differ")
    pilot.payload_positions == jade_pilot.payload_positions ||
        error("paired payload positions differ")
    pilot.transmitted_bits == jade_pilot.transmitted_bits ||
        error("paired transmitted words differ")
    transmitted_bits = pilot.transmitted_bits
    transmitted_symbols = qpsk_symbols(1.0 .- 2.0 .* Float64.(transmitted_bits))
    codeword_hash = _sha_vector(transmitted_bits)
    rows = NamedTuple[]
    sizehint!(rows, length(snr_db_values) * frames * length(RECEIVERS))
    all_bp_jade_equal = true
    all_objective_descended = true
    all_scalar_box_feasible = true
    all_scalar_fixed_exact = true
    all_known_bits_valid = true

    for snr_db in snr_db_values
        noise_variance = noise_variance_from_esn0(snr_db)
        for frame in 1:frames
            rng = MersenneTwister(NOISE_SEED + frame)
            unit_noise = complex.(randn(rng, length(transmitted_symbols)),
                                  randn(rng, length(transmitted_symbols))) ./ sqrt(2.0)
            received = transmitted_symbols .+ sqrt(noise_variance) .* unit_noise
            llr = awgn_llrs(received, noise_variance)
            physical_llr = clamp.(llr, -LLR_CLIP, LLR_CLIP)
            decoder_llr = _pilot_clamped_llr(llr, pilot.fixed, pilot.fixed_bits)
            noise_hash = _sha_vector(unit_noise)
            received_hash = _sha_vector(received)
            llr_hash = _sha_vector(physical_llr)
            decoder_llr_hash = _sha_vector(decoder_llr)

            scalar_problem = ScalarProblem(code, physical_llr;
                parity_weight=PARITY_WEIGHT, binary_weight=BINARY_WEIGHT,
                fixed=pilot.fixed, fixed_bits=pilot.fixed_bits)
            initial = tanh.(physical_llr ./ 2)
            scalar_timed = @timed solve_scalar(
                scalar_problem, initial; steps=SCALAR_STEPS)
            scalar = scalar_timed.value
            hard_scalar = BitVector(scalar.x .< 0)
            scalar_syndrome = _syndrome_weight(code, hard_scalar)
            scalar_information_errors = count(
                hard_scalar[pilot.payload_positions] .!=
                transmitted_bits[pilot.payload_positions])
            scalar_coded_errors = count(hard_scalar .!= transmitted_bits)
            fractional = count(value -> abs(value) < FRACTIONAL_THRESHOLD, scalar.x)
            objective_descended = scalar.accepted_steps > 0 &&
                scalar.final_objective < scalar.initial_objective &&
                all(diff(scalar.objective_history) .< 0)
            box_feasible = all(-1 .<= scalar.x .<= 1)
            scalar_fixed_exact = scalar.x[pilot.fixed] ==
                scalar_problem.plan.fixed_values[pilot.fixed]
            all_objective_descended &= objective_descended
            all_scalar_box_feasible &= box_feasible
            all_scalar_fixed_exact &= scalar_fixed_exact

            jade_llr = jade_awgn_llrs(received, noise_variance, scalar.x)
            jade_llr == llr || error("fixed-channel JADE likelihood changed after scalar solve")
            jade_decoder_llr = _pilot_clamped_llr(
                jade_llr, jade_pilot.fixed, jade_pilot.fixed_bits)
            jade_decoder_llr == decoder_llr || error(
                "paired pilot-constrained likelihoods differ")
            baseline = _decode_bp(bp_modem, code, decoder_llr)
            jade = _decode_bp(jade_modem, jade_code, jade_decoder_llr)
            equal = baseline.hard == jade.hard &&
                baseline.posterior == jade.posterior &&
                baseline.syndrome == jade.syndrome &&
                baseline.valid == jade.valid &&
                baseline.iterations == jade.iterations &&
                baseline.applied == jade.applied
            equal || error("JADE and OFDM+FEC differ at frame $frame, Es/N0=$snr_db dB")
            all_bp_jade_equal &= equal

            for (receiver, hard, syndrome, valid, decoder_iterations,
                 decoder_calls, seconds, bytes) in (
                (RECEIVERS[1], baseline.hard, baseline.syndrome, baseline.valid,
                 baseline.iterations, 1, baseline.seconds, baseline.bytes),
                (RECEIVERS[2], hard_scalar, scalar_syndrome, scalar_syndrome == 0,
                 0, 0, scalar_timed.time, scalar_timed.bytes),
                (RECEIVERS[3], jade.hard, jade.syndrome, jade.valid,
                 jade.iterations, 1, scalar_timed.time + jade.seconds,
                 scalar_timed.bytes + jade.bytes),
            )
                coded_errors = receiver == RECEIVERS[2] ? scalar_coded_errors :
                    count(hard .!= transmitted_bits)
                information_errors = receiver == RECEIVERS[2] ? scalar_information_errors :
                    count(hard[pilot.payload_positions] .!=
                          transmitted_bits[pilot.payload_positions])
                known_bits_valid = all(
                    hard[pilot.fixed] .== transmitted_bits[pilot.fixed])
                all_known_bits_valid &= known_bits_valid
                has_scalar = receiver != RECEIVERS[1]
                push!(rows, (;
                    snr_db,
                    ebn0_db=snr_db,
                    esn0_db=snr_db,
                    frame,
                    receiver,
                    coded_pilot_fraction=pilot.coded_pilot_fraction,
                    coded_pilot_bits=pilot.fixed_count,
                    payload_bits=pilot.payload_count,
                    noise_variance,
                    coded_bit_errors=coded_errors,
                    information_bit_errors=information_errors,
                    frame_error=information_errors > 0,
                    parity_valid=Bool(valid),
                    known_bits_valid,
                    known_bit_errors=count(
                        hard[pilot.fixed] .!= transmitted_bits[pilot.fixed]),
                    syndrome_weight=Int(syndrome),
                    decoder_iterations=Int(decoder_iterations),
                    decoder_calls=Int(decoder_calls),
                    pseudogradient_calls=0,
                    accepted_gradient_steps=has_scalar ? scalar.accepted_steps : 0,
                    requested_gradient_steps=has_scalar ? scalar.steps_requested : 0,
                    initial_objective=has_scalar ? scalar.initial_objective : 0.0,
                    final_objective=has_scalar ? scalar.final_objective : 0.0,
                    fractional_bits=has_scalar ? fractional : 0,
                    objective_descended=has_scalar ? objective_descended : true,
                    box_feasible=has_scalar ? box_feasible : true,
                    fixed_coordinates_exact=has_scalar ? scalar_fixed_exact : true,
                    seconds=Float64(seconds),
                    allocated_bytes=Int(bytes),
                    codeword_sha256=codeword_hash,
                    noise_sha256=noise_hash,
                    received_sha256=received_hash,
                    llr_sha256=llr_hash,
                    decoder_llr_sha256=decoder_llr_hash,
                    hard_word_sha256=_sha_vector(hard),
                ))
            end
        end
        @info "AWGN point complete" esn0_db=snr_db frames coded_pilot_fraction
    end

    frame_columns = (
        :snr_db, :ebn0_db, :esn0_db, :frame, :receiver, :noise_variance,
        :coded_pilot_fraction, :coded_pilot_bits, :payload_bits,
        :coded_bit_errors, :information_bit_errors, :frame_error,
        :parity_valid, :known_bits_valid, :known_bit_errors,
        :syndrome_weight, :decoder_iterations, :decoder_calls,
        :pseudogradient_calls, :accepted_gradient_steps,
        :requested_gradient_steps, :initial_objective, :final_objective,
        :fractional_bits, :objective_descended, :box_feasible,
        :fixed_coordinates_exact, :seconds,
        :allocated_bytes, :codeword_sha256, :noise_sha256, :received_sha256,
        :llr_sha256, :decoder_llr_sha256, :hard_word_sha256,
    )
    _write_csv(joinpath(output, "frames.csv"), rows, frame_columns)
    aggregates = _aggregate(rows, frames, snr_db_values, pilot.payload_count, n)
    aggregate_columns = propertynames(first(aggregates))
    _write_csv(joinpath(output, "aggregate.csv"), aggregates, aggregate_columns)
    _write_manifest(joinpath(output, "manifest.toml"), repository_root, code,
        frames, snr_db_values, variable_degree, check_degree, attempt_id, pilot)
    _archive_source(output)

    checks = Dict(
        "bp_and_jade_exactly_equal_every_frame" => all_bp_jade_equal,
        "coral_decoder_calls" => sum(row.decoder_calls for row in rows if row.receiver == RECEIVERS[2]),
        "coral_pseudogradient_calls" => sum(row.pseudogradient_calls for row in rows if row.receiver == RECEIVERS[2]),
        "scalar_objective_strictly_descended" => all_objective_descended,
        "scalar_state_box_feasible" => all_scalar_box_feasible,
        "scalar_fixed_coordinates_exact" => all_scalar_fixed_exact,
        "known_bits_valid_every_output" => all_known_bits_valid,
        "paired_llr_hashes" => all(length(unique(row.llr_sha256 for row in rows
            if row.snr_db == snr && row.frame == frame)) == 1
            for snr in snr_db_values for frame in 1:frames),
        "paired_decoder_llr_hashes" => all(length(unique(
            row.decoder_llr_sha256 for row in rows
            if row.snr_db == snr && row.frame == frame)) == 1
            for snr in snr_db_values for frame in 1:frames),
        "row_count" => length(rows),
        "expected_row_count" => length(snr_db_values) * frames * length(RECEIVERS),
    )
    checks["bp_and_jade_exactly_equal_every_frame"] || error("BP/JADE identity gate failed")
    checks["coral_decoder_calls"] == 0 || error("CORAL invoked a decoder")
    checks["coral_pseudogradient_calls"] == 0 || error("CORAL invoked a pseudogradient")
    checks["scalar_objective_strictly_descended"] || error("scalar descent gate failed")
    checks["scalar_state_box_feasible"] || error("scalar box gate failed")
    checks["scalar_fixed_coordinates_exact"] || error("fixed-coordinate gate failed")
    checks["known_bits_valid_every_output"] || error("known-bit gate failed")
    checks["paired_llr_hashes"] || error("paired LLR gate failed")
    checks["paired_decoder_llr_hashes"] || error("paired decoder-LLR gate failed")
    checks["row_count"] == checks["expected_row_count"] || error("row-count gate failed")

    if make_plot
        plotter = joinpath(@__DIR__, "plot_three_receivers.py")
        run(`python3 $plotter $(joinpath(output, "aggregate.csv")) $output`)
    end
    _write_completion(output, checks, attempt_id)
    (; rows, aggregates, checks, output)
end

function _usage()
    "usage: run_three_receivers.jl OUTPUT [--frames N] [--code-rate R] " *
    "[--coded-pilot-fraction P] " *
    "[--snr-start DB --snr-step DB --snr-stop DB] [--no-plot]"
end

function main(args=ARGS)
    isempty(args) && error(_usage())
    output = args[1]
    frames = DEFAULT_FRAMES
    make_plot = true
    code_rate = DEFAULT_K / DEFAULT_N
    coded_pilot_fraction = DEFAULT_CODED_PILOT_FRACTION
    snr_start = first(DEFAULT_SNR_DB)
    snr_step = DEFAULT_SNR_DB[2] - DEFAULT_SNR_DB[1]
    snr_stop = last(DEFAULT_SNR_DB)
    index = 2
    while index <= length(args)
        argument = args[index]
        if argument == "--frames"
            index < length(args) || error("--frames requires an integer")
            frames = parse(Int, args[index + 1])
            index += 2
        elseif argument == "--code-rate"
            index < length(args) || error("--code-rate requires a number")
            code_rate = parse(Float64, args[index + 1])
            index += 2
        elseif argument == "--coded-pilot-fraction"
            index < length(args) || error("--coded-pilot-fraction requires a number")
            coded_pilot_fraction = parse(Float64, args[index + 1])
            index += 2
        elseif argument == "--snr-start"
            index < length(args) || error("--snr-start requires a number")
            snr_start = parse(Float64, args[index + 1])
            index += 2
        elseif argument == "--snr-step"
            index < length(args) || error("--snr-step requires a number")
            snr_step = parse(Float64, args[index + 1])
            index += 2
        elseif argument == "--snr-stop"
            index < length(args) || error("--snr-stop requires a number")
            snr_stop = parse(Float64, args[index + 1])
            index += 2
        elseif argument == "--no-plot"
            make_plot = false
            index += 1
        else
            error("unknown argument $argument\n$(_usage())")
        end
    end
    k = _information_length(code_rate, DEFAULT_N)
    snr_db_values = _snr_grid(snr_start, snr_step, snr_stop)
    run_experiment(output; frames, make_plot, k, n=DEFAULT_N,
        variable_degree=DEFAULT_VARIABLE_DEGREE, coded_pilot_fraction,
        snr_db_values)
    nothing
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    AWGNThreeReceivers.main()
end

