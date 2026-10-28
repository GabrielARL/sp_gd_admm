module Modulations

export Modulation, modulate, demodulate, bitspersymbol, signallength, payload_rate,
       refinement_objective, frameblockcount, framepayloadbits

### parent type for all modulation types

abstract type Modulation end

### interface functions

"""
    init(m::Modulation, fc, fs)

Initialize modulation processor. If a processor does not require initialization,
it may choose not to implement this function. This function is typically used to
initialize a modulation to reasonable default values based on `fc` and `fs`.
"""
function init(::Modulation, fc, fs) end

"""
    modulate(m::Modulation, bits, fc, fs)

Convert a non-empty `bits` collection into a complex baseband signal. `fc` is
the finite carrier frequency and `fs` the finite, positive sampling rate.
"""
function modulate end

"""
    demodulate(m::Modulation, nbits, x, fc, fs)

Convert complex baseband signal `x` into soft metrics denoting bit estimates.
The metric for a bit is positive if the bit is likely `1` and negative if it
is likely `0`. Nominal metric values should be centered around ±1.

`nbits` is a positive integer number of expected bits, `fc` is the finite
carrier frequency, and `fs` is the finite, positive sampling rate. Received
samples must all be finite.

During demodulations, some receivers may have an estimate of carrier frequency
offset (cfo). In such cases, this may be returned. If no cfo is available, a
zero should be returned as cfo.

Return a tuple of metrics and cfo.
"""
function demodulate end

"""
    isvalid(m::Modulation, fc, fs)

Check if a modulation `m` is valid. Modulations may be considered invalid if
the parameters of the modulation are incorrectly set. `fc` is the carrier frequency
and `fs` the sampling rate.
"""
Base.isvalid

"""
    bitspersymbol(m::Modulation)

Get the length in bits of a modulation symbol or block. For OFDM systems, this is
the number of information bits that are carried in a single OFDM block. For a single
carrier QPSK system, bitspersymbol is 2, as every QPSK symbol carries 2 bits.

JUNA with `ldpc_scope=:frame` returns the user-payload capacity of its single
frame-wide LDPC codeword. That codeword spans `frameblockcount(m, fs)` OFDM
symbols; the returned capacity must not be multiplied by that symbol count.
"""
function bitspersymbol end

"""
    signallength(m::Modulation, nbits, fc, fs)

Get the number of samples in a complex baseband signal containing at least the
positive integer `nbits` bits of information. `fc` is the finite carrier
frequency and `fs` the finite, positive sampling rate.

Note this returns a sample *count* (an `Int`), not the signal itself.
"""
function signallength end

"""
    frameblockcount(m::Modulation, fs)

Number of complete modulation blocks selected within the configured frame
duration, including synchronization overhead. JUNA defaults to the largest
fitting count; a positive `frame_ofdm_symbols` selects an explicit fitting count
when `ldpc_scope=:frame`.
"""
function frameblockcount end

"""
    framepayloadbits(m::Modulation, fs)

Maximum user-payload bits carried by `frameblockcount(m, fs)` blocks.
For JUNA frame-wide LDPC this is the capacity of one codeword, excluding known
input bits and any frame CRC. Its waveform occupies the entire configured frame
duration; unused samples following the complete OFDM symbols are zeros.
"""
function framepayloadbits end

"""
    refinement_objective(m::Modulation) -> Symbol

Declare the receiver-refinement objective implemented by `m`. The shared modem
interface does not require refinement, so the default is `:none`. Implementations
may return a more specific capability such as `:pilot_band_ls`;
every non-`:none` declaration must have an
executable contract test for the corresponding objective.
"""
refinement_objective(::Modulation) = :none

"""
    payload_rate(m::Modulation, nbits, fc, fs)

Effective payload bit rate in bits/second for transmitting `nbits` information bits:
`nbits * fs / signallength(m, nbits, fc, fs)`. Since `signallength` already includes
every overhead (cyclic prefix, pilots, FEC parity, and any sync preamble/postamble),
this is the *useful* throughput at baseband rate `fs` — always ≤ `fs`.
"""
payload_rate(m::Modulation, nbits, fc, fs) = nbits * fs / signallength(m, nbits, fc, fs)

end # Modulations
