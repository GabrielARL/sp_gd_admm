#!/usr/bin/env julia

module ParityADMMAWGN

using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA

include(joinpath(@__DIR__, "..", "jade_red12", "parity_admm_decoder.jl"))
using .ParityADMMDecoder

const ADMM = ParityADMMDecoder
const CORE = JadeJcade.ReceiverCore
const ATTEMPT_ID = "R3-PARITY-ADMM-AWGN-001"
const GRAPH_SEED = 169_616_412
const NOISE_SEED = 20_261_012
const VARIABLE_DEGREE = 3
const CHECK_DEGREE = 6
const N = 10_200
const K = 5_100
const FRAMES = 24
const ESN0_DB = 1.5
const LLR_CLIP = 20.0
const ADMM_ITERATIONS = 80
const ADMM_RHO = 3.0
const PENALIZED_ALPHA = 0.8
const RESIDUAL_TOLERANCE = 1e-5
const EXPECTED_GRAPH_SHA256 =
    "94d94376995c6eb9e21a5859dde6354d7233f61634b5dbdc91fd70653f5f6e2d"

export ADMM, ADMM_ITERATIONS, ADMM_RHO, ATTEMPT_ID, CHECK_DEGREE,
       ESN0_DB, EXPECTED_GRAPH_SHA256, FRAMES, GRAPH_SEED, K, LLR_CLIP,
       N, NOISE_SEED, PENALIZED_ALPHA, RESIDUAL_TOLERANCE,
       VARIABLE_DEGREE, code_and_graph, conditional_admm_decode,
       graph_sha256, paired_frame, parity_polytope_contains,
       qpsk_channel_statistics, qpsk_llrs, qpsk_symbols, sha256_values,
       write_csv

function code_and_graph(; n::Integer=N, k::Integer=K)
    n * VARIABLE_DEGREE == (n - k) * CHECK_DEGREE ||
        throw(ArgumentError("dimensions do not give a regular (3,6) graph"))
    modem = JadeJcade.Jade.Modulation(
        ldpc_k=Int(k), ldpc_n=Int(n), ldpc_npc=VARIABLE_DEGREE,
        ldpc_method=:evenboth, ldpc_seed=GRAPH_SEED,
        ldpc_no4cycle=false, inner_pilot_ratio=0.0, pilot_ratio=0.0,
        bp_iterations=80)
    code = CORE._code(modem)
    all(length(edges) == VARIABLE_DEGREE for edges in code.var_edges) ||
        error("variable degree differs from the protocol")
    all(length(members) == CHECK_DEGREE for members in code.check_vars) ||
        error("check degree differs from the protocol")
    modem, code
end

function graph_sha256(code)
    io = IOBuffer()
    for members in code.check_vars
        write(io, htol(Int32(length(members))))
        for variable in members
            write(io, htol(Int32(variable)))
        end
    end
    bytes2hex(sha256(take!(io)))
end

function sha256_values(values::AbstractVector)
    io = IOBuffer()
    if eltype(values) <: Bool
        write(io, UInt8.(values))
    else
        write(io, reinterpret(UInt8, collect(values)))
    end
    bytes2hex(sha256(take!(io)))
end

function qpsk_symbols(bits::AbstractVector{Bool})
    iseven(length(bits)) || throw(ArgumentError("QPSK requires an even bit count"))
    scale = inv(sqrt(2.0))
    symbols = Vector{ComplexF64}(undef, length(bits) ÷ 2)
    @inbounds for symbol in eachindex(symbols)
        inphase = bits[2symbol - 1] ? -1.0 : 1.0
        quadrature = bits[2symbol] ? -1.0 : 1.0
        symbols[symbol] = complex(inphase, quadrature) * scale
    end
    symbols
end

"""Matched-filter bit statistic with mean +1 for bit zero and -1 for bit one."""
function qpsk_channel_statistics(received::AbstractVector{<:Complex})
    statistic = Vector{Float64}(undef, 2length(received))
    scale = sqrt(2.0)
    @inbounds for symbol in eachindex(received)
        statistic[2symbol - 1] = scale * real(received[symbol])
        statistic[2symbol] = scale * imag(received[symbol])
    end
    statistic
end

function qpsk_llrs(received::AbstractVector{<:Complex}, noise_variance::Real)
    isfinite(noise_variance) && noise_variance > 0.0 ||
        throw(ArgumentError("positive finite complex-noise variance required"))
    scale = 2sqrt(2.0) / Float64(noise_variance)
    llr = Vector{Float64}(undef, 2length(received))
    @inbounds for symbol in eachindex(received)
        llr[2symbol - 1] = scale * real(received[symbol])
        llr[2symbol] = scale * imag(received[symbol])
    end
    llr
end

function paired_frame(code, frame::Integer; esn0_db::Real=ESN0_DB)
    frame > 0 || throw(ArgumentError("frame index must be positive"))
    isfinite(esn0_db) || throw(ArgumentError("Es/N0 must be finite"))
    word = falses(code.n)
    symbols = qpsk_symbols(word)
    noise_variance = 10.0^(-Float64(esn0_db) / 10.0)
    rng = MersenneTwister(NOISE_SEED + Int(frame))
    unit_noise = complex.(randn(rng, length(symbols)),
                          randn(rng, length(symbols))) ./ sqrt(2.0)
    received = symbols .+ sqrt(noise_variance) .* unit_noise
    channel = qpsk_channel_statistics(received)
    llr = clamp.(qpsk_llrs(received, noise_variance), -LLR_CLIP, LLR_CLIP)
    (; word, symbols, received, channel, llr, noise_variance,
       received_sha256=sha256_values(received),
       llr_sha256=sha256_values(llr),
       channel_sha256=sha256_values(channel))
end

function parity_polytope_contains(point; tolerance::Real=1e-10)
    all(value -> -tolerance <= value <= 1 + tolerance, point) || return false
    degree = length(point)
    for mask in 0:(1 << degree)-1
        isodd(count_ones(mask)) || continue
        lhs = 0.0
        members = 0
        @inbounds for bit in 1:degree
            inside = !iszero(mask & (1 << (bit - 1)))
            lhs += inside ? point[bit] : -point[bit]
            members += inside
        end
        lhs <= members - 1 + tolerance || return false
    end
    true
end

function conditional_admm_decode(plan::ADMM.ParityPlan,
                                 llr::AbstractVector{<:Real};
                                 iterations::Integer=ADMM_ITERATIONS,
                                 rho::Real=ADMM_RHO,
                                 penalized_alpha::Real=PENALIZED_ALPHA,
                                 residual_tolerance::Real=RESIDUAL_TOLERANCE)
    lp = ADMM.decode(plan, llr; rho, alpha=0.0, iterations,
        residual_tolerance, early_stop_on_accepted=false)
    penalized_used = !lp.integral
    penalized = if penalized_used
        ADMM.decode(plan, llr; rho, alpha=penalized_alpha, iterations,
            residual_tolerance, initial_relaxed=lp.relaxed,
            early_stop_on_accepted=false)
    else
        nothing
    end
    final = penalized_used ? penalized : lp
    (; lp, penalized, penalized_used, final,
       bp_calls=lp.bp_calls + (penalized_used ? penalized.bp_calls : 0),
       minsum_calls=lp.minsum_calls +
           (penalized_used ? penalized.minsum_calls : 0),
       iterations_run=lp.iterations_run +
           (penalized_used ? penalized.iterations_run : 0))
end

csv_value(value) = value isa AbstractFloat ? @sprintf("%.17g", value) : string(value)

function write_csv(path, rows)
    isempty(rows) && throw(ArgumentError("cannot write an empty CSV"))
    columns = propertynames(first(rows))
    open(path, "w") do io
        println(io, join(string.(columns), ','))
        for row in rows
            println(io, join((csv_value(getproperty(row, column))
                              for column in columns), ','))
        end
    end
end

end # module
