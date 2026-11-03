module JadeJcade

include("Modulations.jl")
include("LDPC.jl")
include("ReceiverCore.jl")

using .Modulations: bitspersymbol, demodulate, frameblockcount,
                    framepayloadbits, modulate, payload_rate,
                    refinement_objective, signallength, init

export Jade, Jcade, DocumentedOptionB, bitspersymbol, compare_receivers, demodulate,
       frameblockcount, framepayloadbits, modulate, payload_rate,
       receiver_trace, refinement_objective, signallength, init

"""JADE joint-CZ projected-gradient receiver with belief-propagation feedback."""
module Jade
using ..ReceiverCore
export Modulation

function Modulation(; decoding_route::Symbol=:bp_feedback, kwargs...)
    decoding_route in (:bp_feedback, :persistent_edges) || throw(
        ArgumentError("JADE decoding_route must be :bp_feedback or :persistent_edges"))
    ReceiverCore.JointCZModulation(; (;
        kwargs...,
        baseline_likelihood=:pilot_variance,
        joint_cz_algorithm=:projected_gradient,
        projected_gradient_update_response=true,
        projected_gradient_update_bits=true,
        candidate_selection=:projected_gradient,
        decoder_feedback_adapter=nothing,
        terminal_bp_decode=false,
        decoding_route,
    )...)
end

end # module Jade

"""Jcade receiver with projected-gradient decoding and no BP or min-sum calls."""
module Jcade
using ..ReceiverCore
export Modulation

function Modulation(; kwargs...)
    ReceiverCore.JointCZModulation(; (;
        projected_gradient_steps=200,
        projected_gradient_step_size=0.2,
        parity_penalty_weight=8.0,
        binary_penalty_weight=0.2,
        kwargs...,
        baseline_likelihood=:pilot_variance,
        joint_cz_algorithm=:projected_gradient,
        projected_gradient_update_response=true,
        projected_gradient_update_bits=true,
        candidate_selection=:projected_gradient,
        decoder_feedback_adapter=nothing,
        terminal_bp_decode=false,
        decoding_route=:jcade,
    )...)
end

end # module Jcade

"""Documented Option B with finite normalized min-sum inside a soft Lagrangian."""
module DocumentedOptionB
using ..ReceiverCore
export Modulation

function Modulation(; kwargs...)
    ReceiverCore.JointCZModulation(; (;
        kwargs...,
        baseline_likelihood=:pilot_variance,
        joint_cz_algorithm=:projected_gradient,
        projected_gradient_update_response=true,
        projected_gradient_update_bits=true,
        candidate_selection=:projected_gradient,
        decoder_feedback_adapter=nothing,
        terminal_bp_decode=false,
        decoding_route=:lagrangian_soft,
    )...)
end

end # module DocumentedOptionB

receiver_trace(modem) = ReceiverCore.receiver_trace(modem)

function _condition_result(name, modem, payload, received, fc, fs)
    working = copy(received)
    metrics, cfo = demodulate(modem, length(payload), working, fc, fs)
    working == received || error("$name modified the shared received samples")
    length(metrics) == length(payload) || error("$name returned the wrong metric count")
    all(isfinite, metrics) || error("$name returned nonfinite metrics")
    decoded = metrics .> 0
    trace = only(receiver_trace(modem))
    (; name, metrics, cfo, decoded, errors=count(decoded .!= payload), trace)
end

"""
    compare_receivers(payload, received, fc, fs; kwargs...)

Run JADE and Jcade on independent copies of one received waveform. Both
receivers use the same modem geometry and LDPC code. The return value retains
the decoded metrics, error counts, carrier-offset estimates, and receiver
traces for both conditions.
"""
function compare_receivers(payload, received, fc, fs; kwargs...)
    jade = Jade.Modulation(; kwargs...)
    jcade = Jcade.Modulation(; kwargs...)
    isvalid(jade, fc, fs) || throw(ArgumentError("invalid JADE configuration"))
    isvalid(jcade, fc, fs) || throw(ArgumentError("invalid Jcade configuration"))
    bitspersymbol(jade) == bitspersymbol(jcade) == length(payload) ||
        throw(ArgumentError("payload length differs from the shared modem capacity"))
    transmitted = modulate(jade, payload, fc, fs)
    modulate(jcade, payload, fc, fs) == transmitted ||
        error("JADE and Jcade changed the shared transmitted waveform")
    code = ReceiverCore._code(jade)
    jcade.code = code
    jade_result = _condition_result("JADE", jade, payload, received, fc, fs)
    jcade_result = _condition_result("Jcade", jcade, payload, received, fc, fs)
    (; transmitted, received=copy(received), jade=jade_result, jcade=jcade_result)
end

end # module JadeJcade
