#!/usr/bin/env julia

module RQ2GDStateUse001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using Statistics
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__
const TEST_PATH = joinpath(HERE, "test_rq2_gd_state_use_001.jl")
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const PREFLIGHT_PATH = joinpath(HERE, "preflight_validation.md")

export load_config, source_gate, load_native, generate_input,
       bounded_mean_projection, independent_bounded_mean_projection,
       BridgeProblem, bridge_evaluate!, solve_variant, native_trace,
       preflight_gate, freeze_inputs, run_stage, replay_result, main

# ---------------------------------------------------------------------------
# Stable serialization and file helpers
# ---------------------------------------------------------------------------

function json_escape(value::AbstractString)
    io = IOBuffer()
    for character in value
        if character == '"'
            print(io, "\\\"")
        elseif character == '\\'
            print(io, "\\\\")
        elseif character == '\b'
            print(io, "\\b")
        elseif character == '\f'
            print(io, "\\f")
        elseif character == '\n'
            print(io, "\\n")
        elseif character == '\r'
            print(io, "\\r")
        elseif character == '\t'
            print(io, "\\t")
        elseif Int(character) < 0x20
            @printf(io, "\\u%04x", Int(character))
        else
            print(io, character)
        end
    end
    String(take!(io))
end

"""Return deterministic JSON for scientific replay hashes."""
function canonical_json(value)
    if value === nothing || value === missing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Integer
        return string(value)
    elseif value isa AbstractFloat
        isfinite(value) || throw(ArgumentError(
            "canonical scientific JSON requires finite floats"))
        return repr(Float64(value))
    elseif value isa AbstractString
        return "\"" * json_escape(value) * "\""
    elseif value isa Symbol
        return canonical_json(String(value))
    elseif value isa NamedTuple
        return canonical_json(Dict(String(key) => getfield(value, key)
                                   for key in keys(value)))
    elseif value isa AbstractDict
        ordered = sort!(collect(value); by=pair -> String(first(pair)))
        return "{" * join((canonical_json(String(first(pair))) * ":" *
                            canonical_json(last(pair)) for pair in ordered), ",") * "}"
    elseif value isa AbstractMatrix
        return canonical_json([[value[row, column] for column in axes(value, 2)]
                               for row in axes(value, 1)])
    elseif value isa AbstractVector || value isa Tuple
        return "[" * join((canonical_json(item) for item in value), ",") * "]"
    end
    throw(ArgumentError("unsupported canonical JSON value of type $(typeof(value))"))
end

scientific_sha256(value) = bytes2hex(sha256(codeunits(canonical_json(value))))
file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))

function vector_sha256(values::AbstractVector)
    io = IOBuffer()
    if eltype(values) <: Bool
        write(io, UInt8.(values))
    else
        contiguous = collect(values)
        write(io, reinterpret(UInt8, contiguous))
    end
    bytes2hex(sha256(take!(io)))
end

function edge_sha256(rows)
    io = IOBuffer()
    for row in rows
        write(io, reinterpret(UInt8, Float64.(row)))
    end
    bytes2hex(sha256(take!(io)))
end

float64_hex(value::Real) = @sprintf("0x%016x", reinterpret(UInt64, Float64(value)))

function git_output(root::AbstractString, arguments...)
    try
        strip(read(`git -C $root $arguments`, String))
    catch
        "unavailable"
    end
end

function write_new_file(path::AbstractString, content::AbstractString)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    open(path, "w") do io
        write(io, content)
    end
    path
end

function csv_value(value)
    value === missing && return ""
    value isa Bool && return lowercase(string(value))
    value isa AbstractFloat && return @sprintf("%.17g", value)
    text = string(value)
    occursin(r"[,\"\n\r]", text) || return text
    "\"" * replace(text, "\"" => "\"\"") * "\""
end

function write_csv(path::AbstractString, rows, columns)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    open(path, "w") do io
        println(io, join(string.(columns), ','))
        for row in rows
            println(io, join((csv_value(getproperty(row, column))
                              for column in columns), ','))
        end
    end
end

function parse_simple_csv(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && throw(ArgumentError("empty CSV: $path"))
    headers = Symbol.(split(first(lines), ','))
    rows = NamedTuple[]
    for line in Iterators.drop(lines, 1)
        isempty(line) && continue
        values = split(line, ','; keepempty=true)
        length(values) == length(headers) || throw(ArgumentError(
            "quoted or malformed CSV row is outside the registered parser: $path"))
        push!(rows, NamedTuple{Tuple(headers)}(Tuple(values)))
    end
    rows
end

function checksum_manifest(root::AbstractString; exclude=Set{String}())
    entries = Pair{String,String}[]
    for (directory, _, files) in walkdir(root)
        for name in files
            path = joinpath(directory, name)
            relative = relpath(path, root)
            relative in exclude && continue
            push!(entries, relative => file_sha256(path))
        end
    end
    sort!(entries; by=first)
end

function write_checksum_manifest(root::AbstractString)
    path = joinpath(root, "MANIFEST.sha256")
    entries = checksum_manifest(root; exclude=Set(["MANIFEST.sha256"]))
    text = join(("$(last(entry))  $(first(entry))" for entry in entries), "\n") * "\n"
    write_new_file(path, text)
    (; path, entries)
end

function verify_checksum_manifest(root::AbstractString)
    manifest = joinpath(root, "MANIFEST.sha256")
    isfile(manifest) || return Dict("passed" => false, "reason" => "missing_manifest")
    failures = String[]
    count = 0
    listed = Set{String}()
    for line in readlines(manifest)
        isempty(line) && continue
        fields = split(line, "  "; limit=2)
        length(fields) == 2 || (push!(failures, "malformed:$line"); continue)
        expected, relative = fields
        push!(listed, relative)
        path = joinpath(root, relative)
        count += 1
        if !isfile(path)
            push!(failures, "missing:$relative")
        elseif file_sha256(path) != expected
            push!(failures, "hash:$relative")
        end
    end
    actual = Set(first(entry) for entry in
        checksum_manifest(root; exclude=Set(["MANIFEST.sha256"])))
    for relative in sort!(collect(setdiff(actual, listed)))
        push!(failures, "extra:$relative")
    end
    for relative in sort!(collect(setdiff(listed, actual)))
        any(==("missing:$relative"), failures) ||
            push!(failures, "missing:$relative")
    end
    Dict("passed" => isempty(failures), "entries" => count, "failures" => failures)
end

# ---------------------------------------------------------------------------
# Configuration, provenance, and retained-source gates
# ---------------------------------------------------------------------------

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq2-gd-state-use-001/v1" ||
        throw(ArgumentError("unsupported RQ2 GD state-use schema"))
    config["experiment_id"] == "RQ2-GD-STATE-USE-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["research_question"] == "RQ2" ||
        throw(ArgumentError("experiment is not registered as RQ2"))
    config["scope"]["admm_included"] == false ||
        throw(ArgumentError("ADMM is outside this experiment"))
    config["scope"]["bp_arm_included"] == false ||
        throw(ArgumentError("a BP arm is outside this causal contrast"))
    config["anchor"]["frame_first"] == 2 &&
        config["anchor"]["frame_last"] == 25 ||
        throw(ArgumentError("anchor frame set changed"))
    config["heldout"]["frame_first"] == 10001 &&
        config["heldout"]["frame_last"] == 10200 ||
        throw(ArgumentError("held-out frame set changed"))
    config["timing"]["warmup_llr_rule"] ==
        "ell_i = 2 sin(0.013 i) + 0.4 cos(0.031 i)" ||
        throw(ArgumentError("synthetic warm-up rule changed"))
    config
end

function static_source_specs(config)
    sources = config["sources"]
    pairs = Pair{String,Tuple{String,String}}[]
    for key in sort!(collect(keys(sources)))
        endswith(key, "_sha256") || continue
        path_key = key[1:end-length("_sha256")]
        haskey(sources, path_key) || continue
        push!(pairs, path_key => (String(sources[path_key]), String(sources[key])))
    end
    pairs
end

function source_gate(config)
    records = Dict{String,Any}[]
    passed = true
    for (label, (path, expected)) in static_source_specs(config)
        exists = isfile(path)
        actual = exists ? file_sha256(path) : "missing"
        equal = exists && actual == expected
        passed &= equal
        push!(records, Dict(
            "label" => label,
            "path" => path,
            "expected_sha256" => expected,
            "actual_sha256" => actual,
            "passed" => equal,
        ))
    end
    jade_root = String(config["sources"]["jade_project_repo"])
    expected_head = String(config["sources"]["jade_project_expected_head"])
    actual_head = git_output(jade_root, "rev-parse", "HEAD")
    head_ok = actual_head == expected_head
    jade_status = git_output(jade_root, "status", "--porcelain=v1", "--untracked-files=all")
    clean_ok = isempty(jade_status)
    passed &= head_ok && clean_ok
    Dict(
        "passed" => passed,
        "records" => records,
        "jade_project_head_expected" => expected_head,
        "jade_project_head_actual" => actual_head,
        "jade_project_head_passed" => head_ok,
        "jade_project_status" => jade_status,
        "jade_project_clean_passed" => clean_ok,
    )
end

function preflight_gate(config_path::AbstractString=DEFAULT_CONFIG)
    isfile(PREFLIGHT_PATH) || return Dict(
        "passed" => false, "reason" => "missing_preflight_record")
    fields = Dict{String,String}()
    for line in eachline(PREFLIGHT_PATH)
        matched = match(r"^([a-z][a-z0-9_]*)[ ]*:[ ]*`?([^` ]+)`?[ ]*$", line)
        matched === nothing && continue
        fields[String(matched.captures[1])] = String(matched.captures[2])
    end
    expected = Dict(
        "validation_status" => "pass",
        "test_exit_code" => "0",
        "config_sha256" => file_sha256(config_path),
        "card_sha256" => file_sha256(CARD_PATH),
        "runner_sha256" => file_sha256(RUNNER_PATH),
        "test_sha256" => isfile(TEST_PATH) ? file_sha256(TEST_PATH) : "missing",
    )
    checks = Dict(key => get(fields, key, "missing") == value
                  for (key, value) in expected)
    Dict("passed" => all(values(checks)), "checks" => checks,
         "recorded" => fields, "expected" => expected)
end

function enforce_thread_environment(config)
    Threads.nthreads() == Int(config["timing"]["julia_threads"]) ||
        throw(ArgumentError("execution requires the registered Julia thread count"))
    get(ENV, "OMP_NUM_THREADS", "") == string(config["timing"]["omp_threads"]) ||
        throw(ArgumentError("OMP_NUM_THREADS must equal the registered value"))
    BLAS.set_num_threads(Int(config["timing"]["blas_threads"]))
    BLAS.get_num_threads() == Int(config["timing"]["blas_threads"]) ||
        throw(ArgumentError("BLAS thread count did not take effect"))
    true
end

function load_native(config)
    if !isdefined(@__MODULE__, :AWGNThreeReceivers)
        Base.include(@__MODULE__, String(config["sources"]["archived_native_runner"]))
    end
    native = Base.invokelatest(() ->
        getfield(@__MODULE__, :AWGNThreeReceivers))
    expected_root = realpath(String(config["sources"]["jade_project_repo"]))
    loaded_root = realpath(dirname(dirname(pathof(JadeJcade))))
    loaded_root == expected_root || throw(ArgumentError(
        "loaded JadeJcade from $loaded_root rather than $expected_root"))
    native
end

native_binding(native::Module, name::Symbol) =
    Base.invokelatest(getfield, native, name)

function native_call(native::Module, name::Symbol, arguments...; keywords...)
    callable = native_binding(native, name)
    Base.invokelatest(callable, arguments...; keywords...)
end

function graph_sha256(checks)
    io = IOBuffer()
    for variables in checks
        write(io, htol(Int32(length(variables))))
        for variable in variables
            write(io, htol(Int32(variable)))
        end
    end
    bytes2hex(sha256(take!(io)))
end

function make_code(config, native)
    n = Int(config["code"]["n"])
    k = Int(config["code"]["k"])
    degree = Int(config["code"]["variable_degree"])
    modem, code = native_call(native, :_modem_and_code;
        k=k, n=n, variable_degree=degree)
    actual = graph_sha256(code.check_vars)
    actual == config["code"]["graph_sha256"] || throw(ArgumentError(
        "graph hash changed: $actual"))
    (; modem, code)
end

function reference_rows(config)
    path = String(config["sources"]["archived_native_frames"])
    selected = Dict{Int,Any}()
    for row in parse_simple_csv(path)
        parse(Float64, row.snr_db) == 6.0 || continue
        row.receiver == "coral_exact_gradient" || continue
        frame = parse(Int, row.frame)
        selected[frame] = row
    end
    length(selected) == 200 || throw(ArgumentError(
        "retained 6 dB native table has $(length(selected)) rows, expected 200"))
    selected
end

function generate_input(config, native, code, frame::Integer)
    n = Int(config["code"]["n"])
    k = Int(config["code"]["k"])
    variance = Float64(config["channel"]["noise_variance"])
    seed = Int(config["channel"]["noise_seed_base"]) + Int(frame)
    transmitted_bits = falses(n)
    transmitted_symbols = native_call(native, :qpsk_symbols, ones(Float64, n))
    rng = MersenneTwister(seed)
    unit_noise = complex.(randn(rng, length(transmitted_symbols)),
                          randn(rng, length(transmitted_symbols))) ./ sqrt(2.0)
    received = transmitted_symbols .+ sqrt(variance) .* unit_noise
    raw_llr = native_call(native, :awgn_llrs, received, variance)
    clip = Float64(config["channel"]["llr_clip"])
    clipped_llr = clamp.(raw_llr, -clip, clip)
    (; frame=Int(frame), noise_seed=seed, variance,
       transmitted_bits, transmitted_symbols, unit_noise, received,
       raw_llr, clipped_llr,
       identities=(;
           transmitted_word_sha256=vector_sha256(transmitted_bits),
           transmitted_symbols_sha256=vector_sha256(transmitted_symbols),
           unit_noise_sha256=vector_sha256(unit_noise),
           received_sha256=vector_sha256(received),
           raw_llr_sha256=vector_sha256(raw_llr),
           clipped_llr_sha256=vector_sha256(clipped_llr),
           graph_sha256=graph_sha256(code.check_vars),
       ))
end

# ---------------------------------------------------------------------------
# Controlled projected-gradient kernel
# ---------------------------------------------------------------------------

struct BridgeProblem
    check_vars::Vector{Vector{Int}}
    var_edges::Vector{Vector{Tuple{Int,Int}}}
    llr::Vector{Float64}
    parity_weight::Float64
    binary_weight::Float64
    curvature_bound::Vector{Float64}
end

function variable_edges(checks, n::Integer)
    edges = [Tuple{Int,Int}[] for _ in 1:n]
    for (check_index, check) in enumerate(checks), (slot, bit) in enumerate(check)
        1 <= bit <= n || throw(ArgumentError("bit index outside 1:$n"))
        push!(edges[bit], (check_index, slot))
    end
    edges
end

function BridgeProblem(code, llr::AbstractVector{<:Real};
                       parity_weight::Real=2.0, binary_weight::Real=0.2)
    n = code.n
    length(llr) == n || throw(DimensionMismatch("LLR vector length changed"))
    checks = [Int.(check) for check in code.check_vars]
    edges = variable_edges(checks, n)
    curvature = [
        (2Float64(parity_weight) * length(incident) +
         8Float64(binary_weight)) / n
        for incident in edges
    ]
    BridgeProblem(checks, edges, Float64.(llr), Float64(parity_weight),
        Float64(binary_weight), curvature)
end

zero_edge_rows(checks) = [zeros(Float64, length(check)) for check in checks]
copy_edge_rows(rows) = [Float64.(row) for row in rows]
flatten_edge_rows(rows) = Float64[value for row in rows for value in row]

mutable struct EvalWorkspace
    gradient::Vector{Float64}
    h::Vector{Float64}
    g_rows::Vector{Vector{Float64}}
    prefix::Vector{Float64}
end

function EvalWorkspace(problem::BridgeProblem)
    EvalWorkspace(zeros(length(problem.llr)), zeros(length(problem.llr)),
        zero_edge_rows(problem.check_vars),
        zeros(maximum(length, problem.check_vars)))
end

"""Evaluate F_delta and its partial derivatives in native operation order."""
function bridge_evaluate!(workspace::EvalWorkspace, problem::BridgeProblem,
                          x::AbstractVector{<:Real}, delta_rows;
                          consume_offsets::Bool)
    n = length(problem.llr)
    length(x) == n || throw(DimensionMismatch("scalar state length changed"))
    fill!(workspace.gradient, 0.0)
    fill!(workspace.h, 0.0)
    for row in workspace.g_rows
        fill!(row, 0.0)
    end

    count = length(problem.check_vars)
    scale = 1.0 / count
    parity_loss = 0.0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        product = 1.0
        for (slot, bit) in enumerate(check)
            workspace.prefix[slot] = product
            reading = Float64(x[bit]) +
                (consume_offsets ? Float64(delta_rows[check_index][slot]) : 0.0)
            product *= reading
        end
        residual = 1.0 - product
        parity_loss += scale * residual^2
        coefficient = -2.0 * scale * residual
        suffix = 1.0
        for slot in length(check):-1:1
            bit = check[slot]
            contribution = coefficient * workspace.prefix[slot] * suffix
            workspace.gradient[bit] += contribution
            workspace.g_rows[check_index][slot] = contribution
            reading = Float64(x[bit]) +
                (consume_offsets ? Float64(delta_rows[check_index][slot]) : 0.0)
            suffix *= reading
        end
    end
    factor = problem.parity_weight * count / n
    workspace.gradient .*= factor
    for row in workspace.g_rows
        row .*= factor
    end
    parity = factor * parity_loss

    binary = 0.0
    @inbounds for bit in eachindex(x)
        value = Float64(x[bit])
        binary_contribution =
            4problem.binary_weight * value * (value^2 - 1.0) / n
        binary += problem.binary_weight * (1.0 - value^2)^2 / n
        workspace.gradient[bit] += binary_contribution
        workspace.h[bit] = -problem.llr[bit] / (2n) + binary_contribution
    end
    channel = -dot(problem.llr, x) / (2n)
    @inbounds for bit in eachindex(x)
        workspace.gradient[bit] -= problem.llr[bit] / (2n)
    end
    (; loss=channel + (parity + binary),
       terms=(; channel, parity, binary),
       gradient=workspace.gradient,
       h=workspace.h,
       g_rows=workspace.g_rows)
end

function readings_in_box(problem::BridgeProblem, x, delta_rows;
                         consume_offsets::Bool, tolerance::Float64=0.0)
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        for (slot, bit) in enumerate(check)
            reading = Float64(x[bit]) +
                (consume_offsets ? Float64(delta_rows[check_index][slot]) : 0.0)
            -1.0 - tolerance <= reading <= 1.0 + tolerance || return false
        end
    end
    true
end

function scalar_intervals!(lower, upper, problem::BridgeProblem, delta_rows;
                           consume_offsets::Bool)
    fill!(lower, -1.0)
    fill!(upper, 1.0)
    consume_offsets || return lower, upper
    for bit in eachindex(problem.var_edges)
        for (check_index, slot) in problem.var_edges[bit]
            delta = delta_rows[check_index][slot]
            lower[bit] = max(lower[bit], -1.0 - delta)
            upper[bit] = min(upper[bit], 1.0 - delta)
        end
        lower[bit] <= upper[bit] || throw(ArgumentError(
            "retained offsets create an empty scalar interval at bit $bit"))
    end
    lower, upper
end

"""Euclidean projection onto a box with a fixed arithmetic mean.

The KKT solution is `z_i = clamp(q_i - lambda, lower, upper)`.  The sum is
monotone in `lambda`, so a fixed-count bisection gives a deterministic
water-filling implementation.  A final roundoff repair changes only available
box slack and enforces the registered sum tolerance.
"""
function bounded_mean_projection(q::AbstractVector{<:Real}, target::Real;
                                 lower::Float64=-1.0, upper::Float64=1.0,
                                 tolerance::Float64=2.0e-12)
    d = length(q)
    d > 0 || throw(ArgumentError("bounded mean projection requires values"))
    lower <= target <= upper || throw(ArgumentError("target mean is outside box"))
    qf = Float64.(q)
    target_sum = d * Float64(target)
    if all(lower .<= qf .<= upper) &&
            abs(sum(qf) - target_sum) <= tolerance
        return qf
    end
    target == lower && return fill(lower, d)
    target == upper && return fill(upper, d)

    lo = minimum(qf .- upper)
    hi = maximum(qf .- lower)
    for _ in 1:160
        shift = (lo + hi) / 2
        total = sum(clamp(value - shift, lower, upper) for value in qf)
        if total > target_sum
            lo = shift
        else
            hi = shift
        end
    end
    shift = (lo + hi) / 2
    z = clamp.(qf .- shift, lower, upper)
    residual = target_sum - sum(z)
    if residual > 0.0
        for index in eachindex(z)
            addition = min(residual, upper - z[index])
            z[index] += addition
            residual -= addition
            residual <= tolerance && break
        end
    elseif residual < 0.0
        for index in eachindex(z)
            subtraction = min(-residual, z[index] - lower)
            z[index] -= subtraction
            residual += subtraction
            -residual <= tolerance && break
        end
    end
    abs(sum(z) - target_sum) <= tolerance || throw(ArgumentError(
        "bounded mean projection failed its sum constraint"))
    all(lower - tolerance .<= z .<= upper + tolerance) || throw(ArgumentError(
        "bounded mean projection left its box"))
    z
end

"""Independent exhaustive KKT oracle for bounded_mean_projection.

This deliberately does not share the production bisection.  The registered
graph has variable degree three, so enumerating lower/free/upper assignments
is small and suitable as a validation oracle.
"""
function independent_bounded_mean_projection(q::AbstractVector{<:Real},
                                             target::Real;
                                             lower::Float64=-1.0,
                                             upper::Float64=1.0,
                                             tolerance::Float64=2.0e-12)
    qf = Float64.(q)
    d = length(qf)
    d > 0 || throw(ArgumentError("bounded mean projection requires values"))
    d <= 12 || throw(ArgumentError("exhaustive projection oracle is validation-only"))
    lower <= target <= upper || throw(ArgumentError("target mean is outside box"))
    target_sum = d * Float64(target)
    best = nothing
    best_objective = Inf
    assignments = 3^d
    for encoded in 0:assignments-1
        state = encoded
        status = Vector{Int8}(undef, d)
        for index in 1:d
            status[index] = Int8(state % 3) - 1
            state ÷= 3
        end
        free = findall(==(0), status)
        z = Vector{Float64}(undef, d)
        fixed_sum = 0.0
        for index in eachindex(status)
            if status[index] == -1
                z[index] = lower
                fixed_sum += lower
            elseif status[index] == 1
                z[index] = upper
                fixed_sum += upper
            end
        end
        if isempty(free)
            abs(fixed_sum - target_sum) <= tolerance || continue
            lambda_lower = maximum((qf[index] - lower
                                    for index in eachindex(status)
                                    if status[index] == -1); init=-Inf)
            lambda_upper = minimum((qf[index] - upper
                                    for index in eachindex(status)
                                    if status[index] == 1); init=Inf)
            lambda_lower <= lambda_upper + tolerance || continue
        else
            lambda = (sum(qf[index] for index in free) + fixed_sum - target_sum) /
                length(free)
            for index in free
                z[index] = qf[index] - lambda
            end
            all(lower - tolerance <= z[index] <= upper + tolerance
                for index in free) || continue
            all(qf[index] - lambda <= lower + tolerance
                for index in eachindex(status) if status[index] == -1) || continue
            all(qf[index] - lambda >= upper - tolerance
                for index in eachindex(status) if status[index] == 1) || continue
        end
        abs(sum(z) - target_sum) <= tolerance || continue
        objective = sum(abs2, z .- qf)
        if objective < best_objective
            best = z
            best_objective = objective
        end
    end
    best === nothing && error("independent projection oracle found no KKT point")
    best
end

function construct_offsets!(delta_next, q_rows, problem::BridgeProblem,
                            x_before, x_after, step, evaluation;
                            tolerance::Float64=2.0e-12,
                            collect_diagnostics::Bool=true)
    maximum_mean_error = 0.0
    nonzero_edges = 0
    zero_bits = 0
    projection_changed_edges = 0
    projection_changed_bits = 0
    maximum_projection_adjustment = 0.0
    offset_squared_norm = 0.0
    boundary_local_values = 0
    for bit in eachindex(problem.var_edges)
        incident = problem.var_edges[bit]
        degree = length(incident)
        degree > 0 || throw(ArgumentError("isolated bit $bit is outside the intervention"))
        total_g = sum(evaluation.g_rows[check_index][slot]
                      for (check_index, slot) in incident; init=0.0)
        q = Vector{Float64}(undef, degree)
        for (position, (check_index, slot)) in enumerate(incident)
            g_tilde = if degree == 1
                evaluation.gradient[bit]
            else
                evaluation.h[bit] + degree / (degree - 1) *
                    (total_g - evaluation.g_rows[check_index][slot])
            end
            value = Float64(x_before[bit]) - step * g_tilde /
                problem.curvature_bound[bit]
            q[position] = value
            q_rows[check_index][slot] = value
        end
        z = bounded_mean_projection(q, Float64(x_after[bit]); tolerance=tolerance)
        bit_nonzero = false
        bit_projection_changed = false
        offset_sum = 0.0
        for (position, (check_index, slot)) in enumerate(incident)
            offset = z[position] - Float64(x_after[bit])
            delta_next[check_index][slot] = offset
            collect_diagnostics || continue
            changed = abs(z[position] - q[position]) > tolerance
            projection_changed_edges += changed
            bit_projection_changed |= changed
            maximum_projection_adjustment = max(maximum_projection_adjustment,
                abs(z[position] - q[position]))
            nonzero = !iszero(offset)
            nonzero_edges += nonzero
            bit_nonzero |= nonzero
            offset_sum += offset
            offset_squared_norm += offset^2
            boundary_local_values += z[position] == -1.0 || z[position] == 1.0
        end
        collect_diagnostics || continue
        maximum_mean_error = max(maximum_mean_error, abs(offset_sum))
        zero_bits += !bit_nonzero
        projection_changed_bits += bit_projection_changed
    end
    (; maximum_mean_error, nonzero_edges, zero_bits,
       maximum_absolute_offset=collect_diagnostics ?
           maximum(abs, flatten_edge_rows(delta_next)) : 0.0,
       offset_l2_norm=sqrt(offset_squared_norm),
       projection_changed_edges, projection_changed_bits,
       maximum_projection_adjustment, boundary_local_values)
end

function independent_local_objective(problem::BridgeProblem, x, delta_rows,
                                     bit::Int, replacement::Float64;
                                     consume_offsets::Bool)
    n = length(x)
    value = -problem.llr[bit] * replacement / (2n) +
        problem.binary_weight * (1.0 - replacement^2)^2 / n
    for (check_index, _) in problem.var_edges[bit]
        product = 1.0
        check = problem.check_vars[check_index]
        for (slot, other_bit) in enumerate(check)
            scalar = other_bit == bit ? replacement : Float64(x[other_bit])
            product *= scalar +
                (consume_offsets ? Float64(delta_rows[check_index][slot]) : 0.0)
        end
        value += problem.parity_weight * (1.0 - product)^2 / n
    end
    value
end

function finite_difference_maximum(problem::BridgeProblem, x, delta_rows,
                                   analytic_gradient;
                                   consume_offsets::Bool,
                                   step::Float64=1.0e-6)
    maximum_error = 0.0
    maximum_bit = 0
    all_probes_in_box = true
    delta_sha256_before = edge_sha256(delta_rows)
    for bit in eachindex(x)
        value = Float64(x[bit])
        objective(replacement) = independent_local_objective(
            problem, x, delta_rows, bit, replacement; consume_offsets)
        numerical = (objective(value - 2step) - 8objective(value - step) +
                     8objective(value + step) - objective(value + 2step)) /
                    (12step)
        if consume_offsets
            for replacement in (value - 2step, value - step,
                                value + step, value + 2step)
                for (check_index, slot) in problem.var_edges[bit]
                    reading = replacement + delta_rows[check_index][slot]
                    all_probes_in_box &= -1.0 <= reading <= 1.0
                end
            end
        end
        absolute_error = abs(numerical - Float64(analytic_gradient[bit]))
        if absolute_error > maximum_error
            maximum_error = absolute_error
            maximum_bit = bit
        end
    end
    (; maximum_error, maximum_bit,
       all_probes_in_box,
       delta_sha256_before,
       delta_sha256_after=edge_sha256(delta_rows))
end

function syndrome_vector(checks, bits)
    Int[foldl(xor, (Bool(bits[bit]) for bit in check); init=false)
        for check in checks]
end

function hard_decision_independent(x)
    result = BitVector(undef, length(x))
    for bit in eachindex(x)
        result[bit] = Float64(x[bit]) < 0.0
    end
    result
end

function operation_counts(problem::BridgeProblem, trace_rows)
    edges = sum(length, problem.check_vars)
    checks = length(problem.check_vars)
    n = length(problem.llr)
    evaluations = sum(Int(row["objective_evaluations"]) for row in trace_rows; init=0)
    accepted = count(row -> Bool(row["accepted"]), trace_rows)
    Dict(
        "objective_and_partial_derivative_evaluations" => evaluations,
        "check_products" => evaluations * checks,
        "leave_one_products" => evaluations * edges,
        "parity_contribution_accumulations" => evaluations * edges,
        "channel_contributions" => evaluations * n,
        "binary_contributions" => evaluations * n,
        "preconditioner_divisions" => length(trace_rows) * n,
        "scalar_projection_comparisons" =>
            sum((Int(row["trial_count"]) for row in trace_rows); init=0) * 2n,
        "offset_refreshes" => accepted,
        "bounded_mean_projection_bits" => accepted * n,
        "offset_values_constructed" => accepted * edges,
        "diagnostic_hashing_included" => false,
        "finite_difference_work_included" => false,
    )
end

function solve_variant(problem::BridgeProblem, code, initial::AbstractVector{<:Real};
                       consume_offsets::Bool,
                       maximum_updates::Int=30,
                       initial_step::Float64=0.2,
                       maximum_backtracks::Int=16,
                       collect_trace::Bool=true,
                       collect_diagnostics::Bool=true,
                       validate_derivatives::Bool=false,
                       finite_difference_step::Float64=1.0e-6,
                       finite_difference_tolerance::Float64=3.0e-8,
                       mean_tolerance::Float64=2.0e-12,
                       box_tolerance::Float64=2.0e-14,
                       snapshot_updates=Set{Int}())
    validate_derivatives && !collect_diagnostics && throw(ArgumentError(
        "finite-difference validation requires diagnostic collection"))
    n = length(problem.llr)
    x = clamp.(Float64.(initial), -1.0, 1.0)
    trial = similar(x)
    direction = similar(x)
    lower = similar(x)
    upper = similar(x)
    delta = zero_edge_rows(problem.check_vars)
    delta_next = zero_edge_rows(problem.check_vars)
    q_rows = zero_edge_rows(problem.check_vars)
    before_workspace = EvalWorkspace(problem)
    trial_workspace = EvalWorkspace(problem)
    trace_rows = Dict{String,Any}[]
    snapshots = Dict{Int,Any}()
    0 in snapshot_updates && (snapshots[0] = (x=copy(x), delta=copy_edge_rows(delta)))
    accepted_steps = 0
    status = "steps_completed"
    all_readings_valid = true
    all_mean_constraints = true
    all_finite_differences = true
    all_offsets_fixed = true
    first_consumed_nonzero_update = nothing
    initial_loss = NaN
    last_accepted_loss = NaN

    for update in 1:maximum_updates
        before = bridge_evaluate!(before_workspace, problem, x, delta;
            consume_offsets)
        if update == 1
            initial_loss = before.loss
            last_accepted_loss = before.loss
        end
        need_hashes = collect_trace || validate_derivatives
        delta_hash_before = need_hashes ? edge_sha256(delta) : "not_collected"
        x_hash_before = need_hashes ? vector_sha256(x) : "not_collected"
        nonzero_before = collect_diagnostics ?
            count(value -> !iszero(value), flatten_edge_rows(delta)) : 0
        if collect_diagnostics && consume_offsets && nonzero_before > 0 &&
                first_consumed_nonzero_update === nothing
            first_consumed_nonzero_update = update
        end
        fd = if validate_derivatives
            finite_difference_maximum(problem, x, delta, before.gradient;
                consume_offsets, step=finite_difference_step)
        else
            (; maximum_error=0.0, maximum_bit=0,
               all_probes_in_box=true,
               delta_sha256_before=delta_hash_before,
               delta_sha256_after=delta_hash_before)
        end
        fd_ok = !validate_derivatives ||
            (fd.maximum_error <= finite_difference_tolerance &&
             fd.delta_sha256_before == fd.delta_sha256_after)
        all_finite_differences &= fd_ok

        @inbounds for bit in eachindex(x)
            direction[bit] = -before.gradient[bit] / problem.curvature_bound[bit]
        end
        scalar_intervals!(lower, upper, problem, delta; consume_offsets)
        for bit in eachindex(x)
            if x[bit] < lower[bit]
                lower[bit] - x[bit] <= box_tolerance || throw(ArgumentError(
                    "current scalar state is below its retained-offset interval"))
                lower[bit] = x[bit]
            elseif x[bit] > upper[bit]
                x[bit] - upper[bit] <= box_tolerance || throw(ArgumentError(
                    "current scalar state is above its retained-offset interval"))
                upper[bit] = x[bit]
            end
        end

        accepted = false
        accepted_step = 0.0
        accepted_loss = before.loss
        trial_count = 0
        all_trial_readings = true
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                trial[bit] = clamp(x[bit] + step * direction[bit],
                                   lower[bit], upper[bit])
            end
            trial_count += 1
            trial_evaluation = bridge_evaluate!(trial_workspace, problem,
                trial, delta; consume_offsets)
            trial_readings = !collect_diagnostics || readings_in_box(
                problem, trial, delta; consume_offsets, tolerance=box_tolerance)
            all_trial_readings &= trial_readings
            if trial_readings && isfinite(trial_evaluation.loss) &&
                    trial_evaluation.loss < before.loss
                accepted = true
                accepted_step = step
                accepted_loss = trial_evaluation.loss
                break
            end
        end
        all_readings_valid &= all_trial_readings
        delta_hash_after_line_search = need_hashes ? edge_sha256(delta) : "not_collected"
        offsets_fixed = !need_hashes || delta_hash_after_line_search == delta_hash_before
        all_offsets_fixed &= offsets_fixed
        if !accepted
            status = "line_search_stalled"
            collect_trace && push!(trace_rows, Dict(
                "update" => update,
                "accepted" => false,
                "trial_count" => trial_count,
                "objective_evaluations" => 1 + trial_count,
                "loss_before" => before.loss,
                "accepted_fixed_offset_loss" => before.loss,
                "accepted_step" => 0.0,
                "x_before_sha256" => x_hash_before,
                "x_after_sha256" => x_hash_before,
                "delta_before_sha256" => delta_hash_before,
                "delta_after_sha256" => delta_hash_before,
                "gradient_sha256" => vector_sha256(before.gradient),
                "direction_sha256" => vector_sha256(direction),
                "delta_after_line_search_sha256" => delta_hash_after_line_search,
                "offsets_fixed_during_calculation" => offsets_fixed,
                "nonzero_offsets_before" => nonzero_before,
                "nonzero_offsets_after" => nonzero_before,
                "maximum_absolute_offset_after" => maximum(abs, flatten_edge_rows(delta)),
                "offset_l2_norm_after" => norm(flatten_edge_rows(delta)),
                "maximum_offset_sum_error" => 0.0,
                "projection_changed_edges" => 0,
                "projection_changed_bits" => 0,
                "maximum_projection_adjustment" => 0.0,
                "boundary_local_values" => 0,
                "finite_difference_maximum_error" => fd.maximum_error,
                "finite_difference_maximum_bit" => fd.maximum_bit,
                "finite_difference_probes_in_box" => fd.all_probes_in_box,
                "finite_difference_passed" => fd_ok,
                "all_trial_readings_in_box" => all_trial_readings,
            ))
            break
        end

        construction = construct_offsets!(delta_next, q_rows, problem,
            x, trial, accepted_step, before;
            tolerance=mean_tolerance, collect_diagnostics)
        all_mean_constraints &= !collect_diagnostics ||
            construction.maximum_mean_error <= mean_tolerance
        readings_after = !collect_diagnostics || readings_in_box(
            problem, trial, delta_next;
            consume_offsets=true, tolerance=box_tolerance)
        all_readings_valid &= readings_after
        delta_hash_after = need_hashes ? edge_sha256(delta_next) : "not_collected"
        x_hash_after = need_hashes ? vector_sha256(trial) : "not_collected"
        accepted_steps += 1
        last_accepted_loss = accepted_loss
        collect_trace && push!(trace_rows, Dict(
            "update" => update,
            "accepted" => true,
            "trial_count" => trial_count,
            "objective_evaluations" => 1 + trial_count,
            "loss_before" => before.loss,
            "accepted_fixed_offset_loss" => accepted_loss,
            "accepted_step" => accepted_step,
            "x_before_sha256" => x_hash_before,
            "x_after_sha256" => x_hash_after,
            "delta_before_sha256" => delta_hash_before,
            "delta_after_sha256" => delta_hash_after,
            "gradient_sha256" => vector_sha256(before.gradient),
            "direction_sha256" => vector_sha256(direction),
            "delta_after_line_search_sha256" => delta_hash_after_line_search,
            "offsets_fixed_during_calculation" => offsets_fixed,
            "nonzero_offsets_before" => nonzero_before,
            "nonzero_offsets_after" => construction.nonzero_edges,
            "zero_offset_bits_after" => construction.zero_bits,
            "maximum_absolute_offset_after" => construction.maximum_absolute_offset,
            "offset_l2_norm_after" => construction.offset_l2_norm,
            "maximum_offset_sum_error" => construction.maximum_mean_error,
            "projection_changed_edges" => construction.projection_changed_edges,
            "projection_changed_bits" => construction.projection_changed_bits,
            "maximum_projection_adjustment" => construction.maximum_projection_adjustment,
            "boundary_local_values" => construction.boundary_local_values,
            "finite_difference_maximum_error" => fd.maximum_error,
            "finite_difference_maximum_bit" => fd.maximum_bit,
            "finite_difference_probes_in_box" => fd.all_probes_in_box,
            "finite_difference_passed" => fd_ok,
            "all_trial_readings_in_box" => all_trial_readings,
            "refreshed_readings_in_box" => readings_after,
        ))
        x, trial = trial, x
        delta, delta_next = delta_next, delta
        update in snapshot_updates &&
            (snapshots[update] = (x=copy(x), delta=copy_edge_rows(delta)))
    end

    terminal_workspace = EvalWorkspace(problem)
    terminal = bridge_evaluate!(terminal_workspace, problem, x, delta;
        consume_offsets)
    hard = BitVector(x .< 0.0)
    if collect_diagnostics
        independent_hard = hard_decision_independent(x)
        hard == independent_hard || error("independent hard decision disagrees")
    end
    independent_syndrome = syndrome_vector(problem.check_vars, hard)
    syndrome_weight = sum(independent_syndrome)
    if collect_diagnostics
        package_syndrome = JadeJcade.ReceiverCore._syndrome_weight(code, hard)
        syndrome_weight == package_syndrome ||
            error("independent syndrome disagrees")
    end
    maximum_updates in snapshot_updates && !haskey(snapshots, maximum_updates) &&
        (snapshots[maximum_updates] = (x=copy(x), delta=copy_edge_rows(delta)))

    persistent_scalar_values = n
    persistent_edge_values = sum(length, delta)
    physical_persistent_state_values = persistent_scalar_values + persistent_edge_values
    (; x=copy(x), delta=copy_edge_rows(delta), hard,
       syndrome=independent_syndrome, syndrome_weight,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=count(hard) == 0,
       coded_bit_errors=count(hard),
       accepted_steps, requested_steps=maximum_updates, status,
       initial_loss, last_accepted_fixed_offset_loss=last_accepted_loss,
       terminal_refreshed_loss=terminal.loss,
       terminal_terms=terminal.terms,
       fractional_bits=count(value -> abs(value) < 0.999, x),
       trace=trace_rows, snapshots,
       first_consumed_nonzero_update,
       all_readings_in_box=all_readings_valid,
       all_mean_constraints_passed=all_mean_constraints,
       all_finite_differences_passed=all_finite_differences,
       all_offsets_fixed_during_calculation=all_offsets_fixed,
       terminal_offset_l2_norm=collect_diagnostics ?
           norm(flatten_edge_rows(delta)) : 0.0,
       operation_counts=operation_counts(problem, trace_rows),
       decoder_calls=0, normalized_minsum_calls=0,
       pseudogradient_calls=0, list_calls=0, oracle_calls=0,
       logical_persistent_scalar_values=persistent_scalar_values,
       # Both arms calculate and retain the edge-shaped state.  The treatment
       # changes only whether the next parity calculation reads it.
       logical_persistent_edge_values=persistent_edge_values,
       physical_scalar_length=length(x),
       physical_edge_row_count=length(delta),
       physical_edge_slot_count=sum(length, delta),
       physical_edge_row_lengths_sha256=collect_diagnostics ?
           vector_sha256(Int64.(length.(delta))) : "not_collected",
       physical_persistent_state_values,
       physical_persistent_state_bytes=8physical_persistent_state_values)
end

function native_trace(native, native_problem, initial;
                      maximum_updates::Int=30,
                      initial_step::Float64=0.2,
                      maximum_backtracks::Int=16)
    x = clamp.(Float64.(initial), -1.0, 1.0)
    trial = similar(x)
    current = native_call(native, :objective_gradient, native_problem, x)
    history = Float64[current.loss]
    state_hashes = String[vector_sha256(x)]
    accepted_steps = 0
    status = "steps_completed"
    for _ in 1:maximum_updates
        direction = -current.gradient ./ native_problem.curvature_bound
        accepted = false
        for backtrack in 0:maximum_backtracks
            step = initial_step * 0.5^backtrack
            @inbounds for bit in eachindex(x)
                trial[bit] = clamp(x[bit] + step * direction[bit], -1.0, 1.0)
            end
            evaluated = native_call(native, :objective_gradient,
                native_problem, trial)
            if isfinite(evaluated.loss) && evaluated.loss < current.loss
                x, trial = trial, x
                current = evaluated
                push!(history, current.loss)
                push!(state_hashes, vector_sha256(x))
                accepted_steps += 1
                accepted = true
                break
            end
        end
        if !accepted
            status = "line_search_stalled"
            break
        end
    end
    (; x=copy(x), history, state_hashes, accepted_steps, status,
       final_loss=current.loss)
end

# ---------------------------------------------------------------------------
# Input freeze
# ---------------------------------------------------------------------------

function authored_source_paths(config_path::AbstractString)
    Dict(
        "config.toml" => abspath(config_path),
        "experiment_card.md" => CARD_PATH,
        "rq2_gd_state_use_001.jl" => RUNNER_PATH,
        "test_rq2_gd_state_use_001.jl" => TEST_PATH,
        "preflight_validation.md" => PREFLIGHT_PATH,
    )
end

function freeze_source_paths(config, config_path::AbstractString)
    paths = authored_source_paths(config_path)
    sources = config["sources"]
    for label in (
        "archived_native_runner", "archived_native_test",
        "archived_native_frames", "archived_native_manifest",
        "archived_native_completion", "rq1_config", "rq1_card",
        "rq1_runner", "rq1_test", "rq1_trace", "rq1_manifest",
        "rq1_checksum_manifest", "jade_project_toml", "jade_manifest_toml",
    )
        paths["retained/$label" * splitext(String(sources[label]))[2]] =
            String(sources[label])
    end
    jade_root = String(sources["jade_project_repo"])
    jade_src = joinpath(jade_root, "src")
    for (directory, _, files) in walkdir(jade_src)
        for name in sort(files)
            endswith(name, ".jl") || continue
            path = joinpath(directory, name)
            paths["jade_src/" * relpath(path, jade_src)] = path
        end
    end
    paths
end

function archive_sources(destination::AbstractString, paths)
    records = Dict{String,Any}[]
    for label in sort!(collect(keys(paths)))
        source = paths[label]
        isfile(source) || throw(ArgumentError("source required for freeze is missing: $source"))
        target = joinpath(destination, label)
        mkpath(dirname(target))
        cp(source, target; force=false)
        push!(records, Dict(
            "label" => label,
            "original_path" => abspath(source),
            "sha256" => file_sha256(source),
            "archived_relative_path" => relpath(target, dirname(destination)),
        ))
    end
    records
end

function input_freeze_rows(config, native, code)
    reference = reference_rows(config)
    anchor_first = Int(config["anchor"]["frame_first"])
    anchor_last = Int(config["anchor"]["frame_last"])
    heldout_first = Int(config["heldout"]["frame_first"])
    heldout_last = Int(config["heldout"]["frame_last"])
    rows = NamedTuple[]
    anchor_reference_passed = true
    for (set_name, frames) in (
        ("anchor", anchor_first:anchor_last),
        ("heldout", heldout_first:heldout_last),
    )
        for frame in frames
            input = generate_input(config, native, code, frame)
            retained_received = ""
            retained_clipped_llr = ""
            retained_match = true
            if set_name == "anchor"
                retained = reference[frame]
                retained_received = retained.received_sha256
                retained_clipped_llr = retained.llr_sha256
                retained_match = input.identities.received_sha256 == retained_received &&
                    input.identities.clipped_llr_sha256 == retained_clipped_llr
                anchor_reference_passed &= retained_match
            end
            push!(rows, (;
                set=set_name,
                frame,
                noise_seed=input.noise_seed,
                physical_esn0_db=Float64(config["channel"]["physical_esn0_db"]),
                noise_variance=input.variance,
                noise_variance_float64_hex=float64_hex(input.variance),
                graph_sha256=input.identities.graph_sha256,
                transmitted_word_sha256=input.identities.transmitted_word_sha256,
                transmitted_symbols_sha256=input.identities.transmitted_symbols_sha256,
                unit_noise_sha256=input.identities.unit_noise_sha256,
                received_sha256=input.identities.received_sha256,
                raw_llr_sha256=input.identities.raw_llr_sha256,
                clipped_llr_sha256=input.identities.clipped_llr_sha256,
                retained_received_sha256=retained_received,
                retained_clipped_llr_sha256=retained_clipped_llr,
                retained_anchor_identity_match=retained_match,
            ))
        end
    end
    (; rows, anchor_reference_passed)
end

function freeze_inputs(output::AbstractString;
                       config_path::AbstractString=DEFAULT_CONFIG,
                       command::AbstractString="freeze")
    output = abspath(output)
    ispath(output) && throw(ArgumentError("freeze output already exists: $output"))
    config = load_config(config_path)
    preflight = preflight_gate(config_path)
    preflight["passed"] || throw(ArgumentError(
        "locked preflight record does not match the authored sources"))
    gate = source_gate(config)
    gate["passed"] || throw(ArgumentError("retained-source gate failed before freeze"))
    enforce_thread_environment(config)
    native = load_native(config)
    generated = make_code(config, native)
    frozen = input_freeze_rows(config, native, generated.code)
    frozen.anchor_reference_passed || throw(ArgumentError(
        "anchor input identities do not reproduce the retained 6 dB table"))

    mkpath(dirname(output))
    mkdir(output)
    input_path = joinpath(output, "input_freeze.csv")
    columns = propertynames(first(frozen.rows))
    write_csv(input_path, frozen.rows, columns)
    source_directory = joinpath(output, "source")
    mkdir(source_directory)
    source_records = archive_sources(source_directory,
        freeze_source_paths(config, config_path))

    manifest = Dict(
        "schema_version" => String(config["provenance"]["freeze_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "created_utc" => string(now(UTC)),
        "command" => command,
        "configuration_sha256" => file_sha256(config_path),
        "input_freeze_sha256" => file_sha256(input_path),
        "input_row_count" => length(frozen.rows),
        "anchor_row_count" => count(row -> row.set == "anchor", frozen.rows),
        "heldout_row_count" => count(row -> row.set == "heldout", frozen.rows),
        "anchor_reference_identity_gate" => frozen.anchor_reference_passed,
        "graph_sha256" => graph_sha256(generated.code.check_vars),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_threads" => Threads.nthreads(),
            "blas_threads" => BLAS.get_num_threads(),
            "cpu" => Sys.CPU_NAME,
            "gzip_version" => strip(first(split(read(`gzip --version`, String), '\n'))),
        ),
        "sp_repository" => Dict(
            "root" => git_output(HERE, "rev-parse", "--show-toplevel"),
            "head" => git_output(HERE, "rev-parse", "HEAD"),
            "branch" => git_output(HERE, "branch", "--show-current"),
            "status" => git_output(HERE, "status", "--porcelain=v1", "--untracked-files=all"),
        ),
        "jade_project" => Dict(
            "root" => String(config["sources"]["jade_project_repo"]),
            "head" => git_output(String(config["sources"]["jade_project_repo"]),
                                 "rev-parse", "HEAD"),
            "status" => git_output(String(config["sources"]["jade_project_repo"]),
                                   "status", "--porcelain=v1", "--untracked-files=all"),
        ),
        "source_gate" => gate,
        "preflight_gate" => preflight,
        "sources" => source_records,
    )
    manifest_path = joinpath(output, "freeze_manifest.toml")
    ispath(manifest_path) && throw(ArgumentError("refusing to overwrite $manifest_path"))
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    written = write_checksum_manifest(output)
    Dict(
        "output" => output,
        "input_rows" => length(frozen.rows),
        "input_freeze_sha256" => file_sha256(input_path),
        "freeze_manifest_sha256" => file_sha256(manifest_path),
        "checksum_entries" => length(written.entries),
    )
end

function validate_freeze(config, freeze::AbstractString;
                         config_path::AbstractString=DEFAULT_CONFIG,
                         regenerate::Bool=true)
    freeze = abspath(freeze)
    checksum = verify_checksum_manifest(freeze)
    manifest_path = joinpath(freeze, "freeze_manifest.toml")
    table_path = joinpath(freeze, "input_freeze.csv")
    isfile(manifest_path) || throw(ArgumentError("freeze manifest is missing"))
    isfile(table_path) || throw(ArgumentError("freeze input table is missing"))
    manifest = TOML.parsefile(manifest_path)
    schema_ok = manifest["schema_version"] == config["provenance"]["freeze_schema"]
    experiment_ok = manifest["experiment_id"] == config["experiment_id"]
    config_ok = manifest["configuration_sha256"] == file_sha256(config_path)
    table_ok = manifest["input_freeze_sha256"] == file_sha256(table_path)
    row_count_ok = length(parse_simple_csv(table_path)) ==
        Int(config["anchor"]["expected_count"]) + Int(config["heldout"]["expected_count"])
    source_ok = source_gate(config)["passed"]
    current_preflight = preflight_gate(config_path)
    frozen_preflight_ok = haskey(manifest, "preflight_gate") &&
        manifest["preflight_gate"]["passed"] == true
    frozen_sources = Dict(String(record["label"]) => record
                          for record in manifest["sources"])
    authored_source_ok = true
    authored_source_failures = String[]
    for (label, current_path) in authored_source_paths(config_path)
        if !haskey(frozen_sources, label)
            authored_source_ok = false
            push!(authored_source_failures, "missing_record:$label")
            continue
        end
        record = frozen_sources[label]
        archived_path = joinpath(freeze, String(record["archived_relative_path"]))
        expected = String(record["sha256"])
        current_ok = isfile(current_path) && file_sha256(current_path) == expected
        archived_ok = isfile(archived_path) && file_sha256(archived_path) == expected
        if !(current_ok && archived_ok)
            authored_source_ok = false
            push!(authored_source_failures, label)
        end
    end
    regenerated_ok = true
    if regenerate
        native = load_native(config)
        generated = make_code(config, native)
        regenerated = input_freeze_rows(config, native, generated.code)
        temporary = tempname() * ".csv"
        write_csv(temporary, regenerated.rows, propertynames(first(regenerated.rows)))
        regenerated_ok = file_sha256(temporary) == file_sha256(table_path)
        rm(temporary)
    end
    checks = Dict(
        "checksum_manifest" => checksum["passed"],
        "schema" => schema_ok,
        "experiment" => experiment_ok,
        "configuration" => config_ok,
        "input_table_hash" => table_ok,
        "input_row_count" => row_count_ok,
        "current_source_gate" => source_ok,
        "current_preflight_record" => current_preflight["passed"],
        "frozen_preflight_record" => frozen_preflight_ok,
        "current_authored_sources_equal_freeze" => authored_source_ok,
        "regenerated_input_table" => regenerated_ok,
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "manifest" => manifest,
        "checksum" => checksum,
        "authored_source_failures" => authored_source_failures,
        "freeze_sha256" => file_sha256(joinpath(freeze, "MANIFEST.sha256")),
    )
end

# ---------------------------------------------------------------------------
# Scientific execution, paired endpoints, and retained artifacts
# ---------------------------------------------------------------------------

parse_bool(value::AbstractString) = lowercase(value) == "true"

function reference_comparison(reference, result, information_errors)
    checks = Dict(
        "coded_bit_errors" => result.coded_bit_errors == parse(Int, reference.coded_bit_errors),
        "information_bit_errors" => information_errors == parse(Int, reference.information_bit_errors),
        "frame_error" => (information_errors > 0) == parse_bool(reference.frame_error),
        "parity_valid" => result.parity_valid == parse_bool(reference.parity_valid),
        "syndrome_weight" => result.syndrome_weight == parse(Int, reference.syndrome_weight),
        "decoder_iterations" => parse(Int, reference.decoder_iterations) == 0,
        "decoder_calls" => result.decoder_calls == parse(Int, reference.decoder_calls),
        "pseudogradient_calls" => result.pseudogradient_calls ==
            parse(Int, reference.pseudogradient_calls),
        "accepted_steps" => result.accepted_steps == parse(Int, reference.accepted_gradient_steps),
        "requested_steps" => result.requested_steps == parse(Int, reference.requested_gradient_steps),
        "initial_objective" => result.initial_loss == parse(Float64, reference.initial_objective),
        "final_objective" => result.terminal_refreshed_loss == parse(Float64, reference.final_objective),
        "objective_descended" => (result.terminal_refreshed_loss < result.initial_loss) ==
            parse_bool(reference.objective_descended),
        "box_feasible" => all(-1.0 .<= result.x .<= 1.0) ==
            parse_bool(reference.box_feasible),
        "fractional_bits" => result.fractional_bits == parse(Int, reference.fractional_bits),
        "hard_word_sha256" => vector_sha256(result.hard) == reference.hard_word_sha256,
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function control_oracle_comparison(control, oracle)
    control_history = Float64[control.initial_loss]
    append!(control_history,
        Float64(row["accepted_fixed_offset_loss"])
        for row in control.trace if Bool(row["accepted"]))
    control_hashes = String[control.trace[1]["x_before_sha256"]]
    append!(control_hashes,
        String(row["x_after_sha256"])
        for row in control.trace if Bool(row["accepted"]))
    checks = Dict(
        "terminal_x_bitwise" => reinterpret(UInt64, control.x) ==
            reinterpret(UInt64, oracle.x),
        "objective_history_bitwise" => reinterpret(UInt64, control_history) ==
            reinterpret(UInt64, oracle.history),
        "state_hash_path" => control_hashes == oracle.state_hashes,
        "accepted_steps" => control.accepted_steps == oracle.accepted_steps,
        "status" => control.status == oracle.status,
        "terminal_loss_bitwise" => reinterpret(UInt64, [control.terminal_refreshed_loss]) ==
            reinterpret(UInt64, [oracle.final_loss]),
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function stage_frames(config, stage::Symbol)
    if stage === :anchor
        return Int(config["anchor"]["frame_first"]):Int(config["anchor"]["frame_last"])
    elseif stage === :heldout
        return Int(config["heldout"]["frame_first"]):Int(config["heldout"]["frame_last"])
    end
    throw(ArgumentError("unsupported stage $stage"))
end

function result_frame_row(frame, arm, input, result, information_positions)
    information_errors = count(@view result.hard[information_positions])
    (;
        frame,
        arm,
        physical_esn0_db=6.0,
        noise_seed=input.noise_seed,
        coded_bit_errors=result.coded_bit_errors,
        information_bit_errors=information_errors,
        transmitted_word_equal=result.transmitted_word_equal,
        information_word_equal=information_errors == 0,
        parity_valid=result.parity_valid,
        wrong_valid_word=result.parity_valid && !result.transmitted_word_equal,
        syndrome_weight=result.syndrome_weight,
        accepted_steps=result.accepted_steps,
        requested_steps=result.requested_steps,
        status=result.status,
        fractional_bits=result.fractional_bits,
        initial_objective=result.initial_loss,
        last_accepted_fixed_offset_objective=result.last_accepted_fixed_offset_loss,
        terminal_refreshed_objective=result.terminal_refreshed_loss,
        first_consumed_nonzero_update=something(result.first_consumed_nonzero_update, 0),
        all_readings_in_box=result.all_readings_in_box,
        all_mean_constraints_passed=result.all_mean_constraints_passed,
        all_finite_differences_passed=result.all_finite_differences_passed,
        hard_word_sha256=vector_sha256(result.hard),
        terminal_scalar_sha256=vector_sha256(result.x),
        terminal_offset_sha256=edge_sha256(result.delta),
        received_sha256=input.identities.received_sha256,
        clipped_llr_sha256=input.identities.clipped_llr_sha256,
        decoder_calls=result.decoder_calls,
        normalized_minsum_calls=result.normalized_minsum_calls,
        pseudogradient_calls=result.pseudogradient_calls,
        list_calls=result.list_calls,
        oracle_calls=result.oracle_calls,
        logical_persistent_scalar_values=result.logical_persistent_scalar_values,
        logical_persistent_edge_values=result.logical_persistent_edge_values,
        physical_scalar_length=result.physical_scalar_length,
        physical_edge_row_count=result.physical_edge_row_count,
        physical_edge_slot_count=result.physical_edge_slot_count,
        physical_edge_row_lengths_sha256=result.physical_edge_row_lengths_sha256,
        physical_persistent_state_values=result.physical_persistent_state_values,
        physical_persistent_state_bytes=result.physical_persistent_state_bytes,
        terminal_offset_l2_norm=result.terminal_offset_l2_norm,
        objective_and_partial_derivative_evaluations=result.operation_counts[
            "objective_and_partial_derivative_evaluations"],
        check_products=result.operation_counts["check_products"],
        leave_one_products=result.operation_counts["leave_one_products"],
        parity_contribution_accumulations=result.operation_counts[
            "parity_contribution_accumulations"],
        bounded_mean_projection_bits=result.operation_counts[
            "bounded_mean_projection_bits"],
        offset_values_constructed=result.operation_counts[
            "offset_values_constructed"],
    )
end

function result_iteration_rows(frame, arm, result)
    rows = NamedTuple[]
    for record in result.trace
        push!(rows, (;
            frame,
            arm,
            update=Int(record["update"]),
            accepted=Bool(record["accepted"]),
            trial_count=Int(record["trial_count"]),
            objective_evaluations=Int(record["objective_evaluations"]),
            loss_before=Float64(record["loss_before"]),
            accepted_fixed_offset_loss=Float64(record["accepted_fixed_offset_loss"]),
            accepted_step=Float64(record["accepted_step"]),
            nonzero_offsets_before=Int(record["nonzero_offsets_before"]),
            nonzero_offsets_after=Int(record["nonzero_offsets_after"]),
            maximum_absolute_offset_after=Float64(record["maximum_absolute_offset_after"]),
            offset_l2_norm_after=Float64(record["offset_l2_norm_after"]),
            maximum_offset_sum_error=Float64(record["maximum_offset_sum_error"]),
            projection_changed_edges=Int(record["projection_changed_edges"]),
            projection_changed_bits=Int(record["projection_changed_bits"]),
            maximum_projection_adjustment=Float64(record["maximum_projection_adjustment"]),
            boundary_local_values=Int(record["boundary_local_values"]),
            finite_difference_maximum_error=Float64(record["finite_difference_maximum_error"]),
            finite_difference_maximum_bit=Int(record["finite_difference_maximum_bit"]),
            finite_difference_probes_in_box=Bool(record[
                "finite_difference_probes_in_box"]),
            finite_difference_passed=Bool(record["finite_difference_passed"]),
            all_trial_readings_in_box=Bool(record["all_trial_readings_in_box"]),
            x_before_sha256=String(record["x_before_sha256"]),
            x_after_sha256=String(record["x_after_sha256"]),
            delta_before_sha256=String(record["delta_before_sha256"]),
            delta_after_line_search_sha256=String(record[
                "delta_after_line_search_sha256"]),
            delta_after_sha256=String(record["delta_after_sha256"]),
            offsets_fixed_during_calculation=Bool(record[
                "offsets_fixed_during_calculation"]),
            gradient_sha256=String(record["gradient_sha256"]),
            direction_sha256=String(record["direction_sha256"]),
        ))
    end
    rows
end

function endpoint_counts(frame_rows, field::Symbol)
    by_frame = Dict{Int,Dict{String,Bool}}()
    for row in frame_rows
        get!(by_frame, row.frame, Dict{String,Bool}())[row.arm] = Bool(getproperty(row, field))
    end
    n11 = n10 = n01 = n00 = 0
    for frame in sort!(collect(keys(by_frame)))
        values = by_frame[frame]
        control = values["control"]
        active = values["active"]
        if active && control
            n11 += 1
        elseif active && !control
            n10 += 1
        elseif !active && control
            n01 += 1
        else
            n00 += 1
        end
    end
    Dict{String,Any}(
        "both_success" => n11,
        "active_only_success" => n10,
        "control_only_success" => n01,
        "both_failure" => n00,
        "pairs" => n11 + n10 + n01 + n00,
        "active_successes" => n11 + n10,
        "control_successes" => n11 + n01,
        "risk_difference_active_minus_control" => (n10 - n01) / (n11 + n10 + n01 + n00),
    )
end

function add_heldout_inference!(endpoint_results, confidence_level::Float64)
    for name in ("transmitted_word_equal", "parity_valid")
        result = endpoint_results[name]
        result["mcnemar_exact_two_sided_pvalue"] = mcnemar_exact_pvalue(result)
        result["newcombe_interval"] = newcombe_paired_interval(result;
            confidence_level)
    end
    adjusted = holm_adjust(Dict(
        name => Float64(endpoint_results[name]["mcnemar_exact_two_sided_pvalue"])
        for name in ("transmitted_word_equal", "parity_valid")
    ))
    for (name, value) in adjusted
        endpoint_results[name]["holm_adjusted_pvalue"] = value
    end
    endpoint_results
end

function mcnemar_exact_pvalue(counts)
    b = Int(counts["active_only_success"])
    c = Int(counts["control_only_success"])
    discordant = b + c
    discordant == 0 && return 1.0
    tail = min(b, c)
    probability = 0.0
    for k in 0:tail
        probability += Float64(binomial(big(discordant), k)) * 0.5^discordant
    end
    min(1.0, 2.0 * probability)
end

function normal_quantile(p::Float64)
    0.0 < p < 1.0 || throw(ArgumentError("normal quantile requires p in (0,1)"))
    # Acklam's rational approximation.
    a = (-39.69683028665376, 220.9460984245205, -275.9285104469687,
         138.3577518672690, -30.66479806614716, 2.506628277459239)
    b = (-54.47609879822406, 161.5858368580409, -155.6989798598866,
         66.80131188771972, -13.28068155288572)
    c = (-0.007784894002430293, -0.3223964580411365, -2.400758277161838,
         -2.549732539343734, 4.374664141464968, 2.938163982698783)
    d = (0.007784695709041462, 0.3224671290700398, 2.445134137142996,
         3.754408661907416)
    plow = 0.02425
    phigh = 1.0 - plow
    if p < plow
        q = sqrt(-2log(p))
        return (((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6]) /
               ((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1)
    elseif p > phigh
        q = sqrt(-2log(1-p))
        return -(((((c[1]*q+c[2])*q+c[3])*q+c[4])*q+c[5])*q+c[6]) /
                ((((d[1]*q+d[2])*q+d[3])*q+d[4])*q+1)
    end
    q = p - 0.5
    r = q*q
    (((((a[1]*r+a[2])*r+a[3])*r+a[4])*r+a[5])*r+a[6])*q /
        (((((b[1]*r+b[2])*r+b[3])*r+b[4])*r+b[5])*r+1)
end

function wilson_interval(successes::Int, total::Int, z::Float64)
    p = successes / total
    denominator = 1 + z^2 / total
    center = (p + z^2 / (2total)) / denominator
    radius = z / denominator * sqrt(p * (1-p) / total + z^2 / (4total^2))
    (max(0.0, center-radius), min(1.0, center+radius))
end

function newcombe_paired_interval(counts; confidence_level::Float64=0.975)
    n11 = Int(counts["both_success"])
    n10 = Int(counts["active_only_success"])
    n01 = Int(counts["control_only_success"])
    n00 = Int(counts["both_failure"])
    n = n11 + n10 + n01 + n00
    alpha = 1.0 - confidence_level
    z = normal_quantile(1.0 - alpha / 2.0)
    p1 = (n11 + n10) / n
    p2 = (n11 + n01) / n
    l1, u1 = wilson_interval(n11+n10, n, z)
    l2, u2 = wilson_interval(n11+n01, n, z)
    denominator = sqrt(p1*(1-p1)*p2*(1-p2))
    raw_cross_product = n11*n00 - n10*n01
    corrected_cross_product = raw_cross_product > 0 ?
        max(raw_cross_product - n/2.0, 0.0) : raw_cross_product
    rho = denominator == 0.0 ? 0.0 :
        clamp((corrected_cross_product/n^2)/denominator, -1.0, 1.0)
    difference = p1 - p2
    lower_radius = sqrt(max(0.0, (p1-l1)^2 + (u2-p2)^2 -
        2rho*(p1-l1)*(u2-p2)))
    upper_radius = sqrt(max(0.0, (u1-p1)^2 + (p2-l2)^2 -
        2rho*(u1-p1)*(p2-l2)))
    Dict(
        "confidence_level" => confidence_level,
        "estimate" => difference,
        "lower" => max(-1.0, difference-lower_radius),
        "upper" => min(1.0, difference+upper_radius),
        "z" => z,
        "phi_correlation" => rho,
        "raw_cross_product" => raw_cross_product,
        "continuity_corrected_cross_product" => corrected_cross_product,
        "method" => "Newcombe 1998 score/Wilson method 10 for paired proportions with continuity-corrected correlation",
    )
end

function holm_adjust(pvalues::Dict{String,Float64})
    ordered = sort!(collect(pvalues); by=last)
    total = length(ordered)
    adjusted = Dict{String,Float64}()
    running = 0.0
    for (rank, (name, value)) in enumerate(ordered)
        running = max(running, min(1.0, (total-rank+1)*value))
        adjusted[name] = running
    end
    adjusted
end

function snapshot_rows(frame, results)
    rows = NamedTuple[]
    for arm in ("control", "active")
        result = results[arm]
        states = copy(result.snapshots)
        states[-1] = (x=result.x, delta=result.delta)
        for update in sort!(collect(keys(states)))
            label = update == -1 ? "terminal" : string(update)
            state = states[update]
            for bit in eachindex(state.x)
                value = Float64(state.x[bit])
                push!(rows, (;
                    frame, arm, update=label, kind="scalar", check=0,
                    slot=0, bit, value, float64_hex=float64_hex(value)))
            end
            for (check_index, row) in enumerate(state.delta), slot in eachindex(row)
                bit = results["problem"].check_vars[check_index][slot]
                value = Float64(row[slot])
                push!(rows, (;
                    frame, arm, update=label, kind="offset", check=check_index,
                    slot, bit, value, float64_hex=float64_hex(value)))
            end
        end
    end
    rows
end

function calculate_science(config, freeze::AbstractString, stage::Symbol;
                           collect_runtime::Bool,
                           config_path::AbstractString=DEFAULT_CONFIG)
    freeze_validation = validate_freeze(config, freeze;
        config_path, regenerate=true)
    freeze_validation["passed"] || throw(ArgumentError("frozen input gate failed"))
    enforce_thread_environment(config)
    native = load_native(config)
    generated = make_code(config, native)
    code = generated.code
    information_positions = native_call(native, :_message_positions, code)
    reference = reference_rows(config)
    frames = stage_frames(config, stage)
    update_limit = Int(config["projected_gradient"]["maximum_update_attempts"])
    initial_step = Float64(config["projected_gradient"]["initial_step"])
    backtracks = Int(config["projected_gradient"]["maximum_backtracks"])
    fd_step = Float64(config["validation"]["finite_difference_step"])
    fd_tolerance = Float64(config["validation"]["finite_difference_tolerance"])
    mean_tolerance = Float64(config["validation"]["mean_offset_tolerance"])
    box_tolerance = Float64(config["validation"]["box_tolerance"])

    if collect_runtime
        config["timing"]["warmup_has_frame_identity"] == false ||
            throw(ArgumentError("timing warm-up must not have a frame identity"))
        config["timing"]["warmup_included_in_outcomes"] == false ||
            throw(ArgumentError("timing warm-up must be excluded from outcomes"))
        warm_llr = [2sin(0.013bit) + 0.4cos(0.031bit)
                    for bit in 1:code.n]
        warm_problem = BridgeProblem(code, warm_llr;
            parity_weight=Float64(config["projected_gradient"]["parity_weight"]),
            binary_weight=Float64(config["projected_gradient"]["binary_weight"]))
        warm_initial = tanh.(warm_llr ./ 2)
        for consume in (false, true)
            for _ in 1:Int(config["timing"]["warmup_repetitions_per_arm"])
                solve_variant(warm_problem, code, warm_initial;
                    consume_offsets=consume, maximum_updates=update_limit,
                    initial_step, maximum_backtracks=backtracks,
                    collect_trace=false, collect_diagnostics=false,
                    validate_derivatives=false, mean_tolerance, box_tolerance)
            end
        end
    end

    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    runtime_rows = NamedTuple[]
    snapshot_payload = nothing
    all_control_oracle = true
    all_control_reference = true
    all_update1_equal = true
    all_consumed_at_update2 = true
    all_fd = true
    all_offsets_fixed = true
    all_box = true
    all_mean = true
    all_equal_physical_shapes = true
    all_zero_calls = true
    all_timed_trace_equal = true
    frame_gate_records = Dict{String,Any}[]

    for frame in frames
        input = generate_input(config, native, code, frame)
        problem = BridgeProblem(code, input.clipped_llr;
            parity_weight=Float64(config["projected_gradient"]["parity_weight"]),
            binary_weight=Float64(config["projected_gradient"]["binary_weight"]))
        initial = tanh.(input.clipped_llr ./ 2)
        snapshot_set = frame == first(frames) ? Set([0, 1, 2]) : Set{Int}()
        timed_results = Dict{String,Any}()
        if collect_runtime
            order = isodd(frame) ? (("control", false), ("active", true)) :
                                   (("active", true), ("control", false))
            for (arm, consume) in order
                timed = @timed solve_variant(problem, code, initial;
                    consume_offsets=consume, maximum_updates=update_limit,
                    initial_step, maximum_backtracks=backtracks,
                    collect_trace=false, collect_diagnostics=false,
                    validate_derivatives=false, mean_tolerance, box_tolerance)
                timed_results[arm] = timed.value
                push!(runtime_rows, (;
                    frame, arm, order_position=findfirst(==(arm), first.(order)),
                    seconds=Float64(timed.time),
                    allocated_bytes=Int(timed.bytes),
                    garbage_collection_seconds=Float64(timed.gctime),
                ))
            end
        end

        control = solve_variant(problem, code, initial;
            consume_offsets=false, maximum_updates=update_limit,
            initial_step, maximum_backtracks=backtracks,
            collect_trace=true, validate_derivatives=false,
            mean_tolerance, box_tolerance,
            snapshot_updates=snapshot_set)
        active = solve_variant(problem, code, initial;
            consume_offsets=true, maximum_updates=update_limit,
            initial_step, maximum_backtracks=backtracks,
            collect_trace=true, validate_derivatives=true,
            finite_difference_step=fd_step,
            finite_difference_tolerance=fd_tolerance,
            mean_tolerance, box_tolerance,
            snapshot_updates=snapshot_set)
        results = Dict("control" => control, "active" => active,
                       "problem" => problem)

        native_problem = native_call(native, :ScalarProblem, code,
            input.clipped_llr;
            parity_weight=Float64(config["projected_gradient"]["parity_weight"]),
            binary_weight=Float64(config["projected_gradient"]["binary_weight"]))
        oracle = native_trace(native, native_problem, initial;
            maximum_updates=update_limit, initial_step,
            maximum_backtracks=backtracks)
        oracle_gate = control_oracle_comparison(control, oracle)
        information_errors = count(@view control.hard[information_positions])
        reference_gate = stage === :anchor ?
            reference_comparison(reference[frame], control, information_errors) :
            Dict("passed" => true, "checks" => Dict{String,Bool}())
        update1_equal = !isempty(control.trace) && !isempty(active.trace) &&
            control.trace[1]["x_after_sha256"] == active.trace[1]["x_after_sha256"] &&
            control.trace[1]["delta_after_sha256"] == active.trace[1]["delta_after_sha256"] &&
            control.trace[1]["accepted_step"] == active.trace[1]["accepted_step"]
        consumed_at_update2 = active.first_consumed_nonzero_update == 2
        physical_shapes_equal =
            control.physical_scalar_length == active.physical_scalar_length &&
            control.physical_edge_row_count == active.physical_edge_row_count &&
            control.physical_edge_slot_count == active.physical_edge_slot_count &&
            control.physical_edge_row_lengths_sha256 ==
                active.physical_edge_row_lengths_sha256 &&
            control.physical_persistent_state_values ==
                active.physical_persistent_state_values &&
            control.physical_persistent_state_bytes ==
                active.physical_persistent_state_bytes
        zero_calls = all(value == 0 for value in (
            control.decoder_calls, control.normalized_minsum_calls,
            control.pseudogradient_calls, control.list_calls, control.oracle_calls,
            active.decoder_calls, active.normalized_minsum_calls,
            active.pseudogradient_calls, active.list_calls, active.oracle_calls,
        ))
        timed_equal = true
        if collect_runtime
            for arm in ("control", "active")
                timed_equal &= vector_sha256(timed_results[arm].x) ==
                    vector_sha256(results[arm].x)
                timed_equal &= edge_sha256(timed_results[arm].delta) ==
                    edge_sha256(results[arm].delta)
            end
        end

        all_control_oracle &= oracle_gate["passed"]
        all_control_reference &= reference_gate["passed"]
        all_update1_equal &= update1_equal
        all_consumed_at_update2 &= consumed_at_update2
        all_fd &= active.all_finite_differences_passed
        all_offsets_fixed &= control.all_offsets_fixed_during_calculation &&
            active.all_offsets_fixed_during_calculation
        all_box &= control.all_readings_in_box && active.all_readings_in_box
        all_mean &= control.all_mean_constraints_passed &&
            active.all_mean_constraints_passed
        all_equal_physical_shapes &= physical_shapes_equal
        all_zero_calls &= zero_calls
        all_timed_trace_equal &= timed_equal
        push!(frame_gate_records, Dict(
            "frame" => frame,
            "control_oracle" => oracle_gate,
            "control_retained_reference" => reference_gate,
            "update_1_equal" => update1_equal,
            "nonzero_offset_first_consumed_at_update_2" => consumed_at_update2,
            "active_finite_differences" => active.all_finite_differences_passed,
            "offsets_fixed_during_calculation" =>
                control.all_offsets_fixed_during_calculation &&
                active.all_offsets_fixed_during_calculation,
            "all_readings_in_box" => control.all_readings_in_box && active.all_readings_in_box,
            "all_mean_constraints" => control.all_mean_constraints_passed &&
                active.all_mean_constraints_passed,
            "equal_physical_array_shapes" => physical_shapes_equal,
            "zero_prohibited_calls" => zero_calls,
            "timed_and_trace_terminal_equal" => timed_equal,
        ))

        for arm in ("control", "active")
            result = results[arm]
            push!(frame_rows, result_frame_row(frame, arm, input, result,
                                               information_positions))
            append!(iteration_rows, result_iteration_rows(frame, arm, result))
        end
        frame == first(frames) && (snapshot_payload = results)
    end

    transmitted = endpoint_counts(frame_rows, :transmitted_word_equal)
    parity = endpoint_counts(frame_rows, :parity_valid)
    information = endpoint_counts(frame_rows, :information_word_equal)
    endpoint_results = Dict(
        "transmitted_word_equal" => transmitted,
        "parity_valid" => parity,
        "information_word_equal" => information,
    )
    if stage === :heldout
        add_heldout_inference!(endpoint_results,
            Float64(config["heldout"]["newcombe_confidence_level"]))
    end

    base_gates = Dict(
        "freeze" => freeze_validation["passed"],
        "locked_preflight_validation" =>
            freeze_validation["checks"]["current_preflight_record"] &&
            freeze_validation["checks"]["frozen_preflight_record"],
        "control_matches_native_path" => all_control_oracle,
        "control_matches_retained_anchor" => all_control_reference,
        "arms_equal_through_update_1" => all_update1_equal,
        "nonzero_offset_consumed_at_update_2" => all_consumed_at_update2,
        "active_partial_derivatives_pass_finite_differences" => all_fd,
        "offsets_fixed_during_partial_derivatives_and_line_search" => all_offsets_fixed,
        "all_check_readings_in_box" => all_box,
        "mean_offset_constraints" => all_mean,
        "equal_physical_array_shapes" => all_equal_physical_shapes,
        "structural_decoder_minsum_pseudogradient_list_or_oracle_call_fields_zero" => all_zero_calls,
        "timed_and_trace_terminal_states_equal" => all_timed_trace_equal,
        "frame_count" => length(frames) == (stage === :anchor ?
            Int(config["anchor"]["expected_count"]) : Int(config["heldout"]["expected_count"])),
    )
    correctness_passed = all(values(base_gates))
    expansion_authorized = stage === :anchor && correctness_passed &&
        transmitted["active_only_success"] > transmitted["control_only_success"] &&
        parity["active_successes"] >= parity["control_successes"]
    science = Dict(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "frame_count" => length(frames),
        "endpoint_results" => endpoint_results,
        "correctness_gates" => base_gates,
        "correctness_passed" => correctness_passed,
        "anchor_expansion_authorized" => expansion_authorized,
        "frame_gates" => frame_gate_records,
        "frames" => [Dict(String(name) => getproperty(row, name)
                          for name in propertynames(row)) for row in frame_rows],
        "iterations" => [Dict(String(name) => getproperty(row, name)
                              for name in propertynames(row)) for row in iteration_rows],
        "claim_boundary" => "tests a constructed retained-and-used check-specific distinction on the projected-gradient backbone; does not establish BP equivalence or a unique native BP-versus-GD cause",
    )
    (; science, frame_rows, iteration_rows, runtime_rows, snapshot_payload,
       expansion_authorized, correctness_passed)
end

function aggregate_rows(science)
    rows = NamedTuple[]
    for endpoint in sort!(collect(keys(science["endpoint_results"])))
        result = science["endpoint_results"][endpoint]
        push!(rows, (;
            endpoint,
            pairs=Int(result["pairs"]),
            both_success=Int(result["both_success"]),
            active_only_success=Int(result["active_only_success"]),
            control_only_success=Int(result["control_only_success"]),
            both_failure=Int(result["both_failure"]),
            active_successes=Int(result["active_successes"]),
            control_successes=Int(result["control_successes"]),
            risk_difference_active_minus_control=Float64(result["risk_difference_active_minus_control"]),
        ))
    end
    rows
end

function write_snapshot_archive(output, frame::Int, payload)
    payload === nothing && return nothing
    rows = snapshot_rows(frame, payload)
    csv_path = joinpath(output, "frame_first_state_snapshots.csv")
    write_csv(csv_path, rows, propertynames(first(rows)))
    run(`gzip -n $csv_path`)
    csv_path * ".gz"
end

function write_result(output::AbstractString, config, config_path, freeze,
                      stage::Symbol, calculated, replay_hash::String,
                      replay_passed::Bool, command::String;
                      anchor_result::Union{Nothing,String}=nothing)
    output = abspath(output)
    ispath(output) && throw(ArgumentError("result output already exists: $output"))
    mkpath(dirname(output))
    mkdir(output)
    science = calculated.science
    base_scientific_sha256 = scientific_sha256(science)
    science["deterministic_replay"] = Dict(
        "first_sha256" => base_scientific_sha256,
        "second_sha256" => replay_hash,
        "passed" => replay_passed,
    )
    science["correctness_gates"]["deterministic_replay"] = replay_passed
    science["correctness_passed"] &= replay_passed
    if stage === :anchor
        transmitted = science["endpoint_results"]["transmitted_word_equal"]
        parity = science["endpoint_results"]["parity_valid"]
        science["anchor_expansion_authorized"] = science["correctness_passed"] &&
            transmitted["active_only_success"] > transmitted["control_only_success"] &&
            parity["active_successes"] >= parity["control_successes"]
    end
    science_path = joinpath(output, "science.json")
    write_new_file(science_path, canonical_json(science) * "\n")
    write_csv(joinpath(output, "frames.csv"), calculated.frame_rows,
              propertynames(first(calculated.frame_rows)))
    write_csv(joinpath(output, "iterations.csv"), calculated.iteration_rows,
              propertynames(first(calculated.iteration_rows)))
    write_csv(joinpath(output, "runtime.csv"), calculated.runtime_rows,
              propertynames(first(calculated.runtime_rows)))
    aggregates = aggregate_rows(science)
    write_csv(joinpath(output, "aggregate.csv"), aggregates,
              propertynames(first(aggregates)))
    snapshot_path = write_snapshot_archive(output,
        Int(science["frame_first"]), calculated.snapshot_payload)

    source_directory = joinpath(output, "source")
    mkdir(source_directory)
    source_records = archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "created_utc" => string(now(UTC)),
        "command" => command,
        "freeze" => abspath(freeze),
        "freeze_manifest_sha256" => file_sha256(joinpath(freeze, "freeze_manifest.toml")),
        "freeze_checksum_manifest_sha256" => file_sha256(joinpath(freeze, "MANIFEST.sha256")),
        "anchor_result" => anchor_result === nothing ? "" : abspath(anchor_result),
        "anchor_completion_sha256" => anchor_result === nothing ? "" :
            file_sha256(joinpath(anchor_result, "COMPLETED.toml")),
        "base_scientific_sha256" => base_scientific_sha256,
        "stored_scientific_sha256" => scientific_sha256(science),
        "environment" => Dict(
            "julia_version" => string(VERSION),
            "julia_threads" => Threads.nthreads(),
            "blas_threads" => BLAS.get_num_threads(),
            "cpu" => Sys.CPU_NAME,
        ),
        "source" => Dict(
            "sp_head" => git_output(HERE, "rev-parse", "HEAD"),
            "sp_branch" => git_output(HERE, "branch", "--show-current"),
            "sp_status" => git_output(HERE, "status", "--porcelain=v1", "--untracked-files=all"),
            "jade_head" => git_output(String(config["sources"]["jade_project_repo"]),
                                      "rev-parse", "HEAD"),
            "sources" => source_records,
        ),
        "snapshot" => snapshot_path === nothing ? "" : basename(snapshot_path),
    )
    manifest_path = joinpath(output, "manifest.toml")
    ispath(manifest_path) && throw(ArgumentError("refusing to overwrite $manifest_path"))
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    status = science["correctness_passed"] ? "complete_valid" : "complete_invalid"
    completion = Dict(
        "schema_version" => "rq2-gd-state-use-001/completion-v1",
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "completed_utc" => string(now(UTC)),
        "status" => status,
        "correctness_passed" => Bool(science["correctness_passed"]),
        "deterministic_replay_passed" => replay_passed,
        "anchor_expansion_authorized" => Bool(science["anchor_expansion_authorized"]),
        "science_sha256" => file_sha256(science_path),
        "manifest_sha256" => file_sha256(manifest_path),
    )
    completion_path = joinpath(output, "COMPLETED.toml")
    ispath(completion_path) && throw(ArgumentError("refusing to overwrite $completion_path"))
    open(completion_path, "w") do io
        TOML.print(io, completion; sorted=true)
    end
    checksums = write_checksum_manifest(output)
    (; output, science, completion,
       checksum_entries=length(checksums.entries))
end

function validate_anchor_handoff(config, anchor_result::AbstractString,
                                 freeze::AbstractString)
    completion_path = joinpath(anchor_result, "COMPLETED.toml")
    manifest_path = joinpath(anchor_result, "manifest.toml")
    isfile(completion_path) || throw(ArgumentError("anchor completion is missing"))
    isfile(manifest_path) || throw(ArgumentError("anchor manifest is missing"))
    checksum = verify_checksum_manifest(anchor_result)
    completion = TOML.parsefile(completion_path)
    manifest = TOML.parsefile(manifest_path)
    checks = Dict(
        "checksums" => checksum["passed"],
        "experiment" => completion["experiment_id"] == config["experiment_id"],
        "stage" => completion["stage"] == "anchor",
        "status" => completion["status"] == "complete_valid",
        "correctness" => completion["correctness_passed"] == true,
        "replay" => completion["deterministic_replay_passed"] == true,
        "expansion" => completion["anchor_expansion_authorized"] == true,
        "freeze" => manifest["freeze_manifest_sha256"] ==
            file_sha256(joinpath(freeze, "freeze_manifest.toml")),
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function run_stage(stage::Symbol, output::AbstractString,
                   freeze::AbstractString;
                   config_path::AbstractString=DEFAULT_CONFIG,
                   anchor_result::Union{Nothing,String}=nothing,
                   command::AbstractString=String(stage))
    config = load_config(config_path)
    if stage === :heldout
        anchor_result === nothing && throw(ArgumentError(
            "held-out execution requires --anchor-result"))
        handoff = validate_anchor_handoff(config, anchor_result, freeze)
        handoff["passed"] || throw(ArgumentError(
            "anchor did not authorize held-out execution: $(handoff["checks"])"))
    end
    calculated = calculate_science(config, freeze, stage;
        collect_runtime=true, config_path)
    replay = calculate_science(config, freeze, stage;
        collect_runtime=false, config_path)
    first_hash = scientific_sha256(calculated.science)
    replay_hash = scientific_sha256(replay.science)
    replay_passed = first_hash == replay_hash
    write_result(output, config, config_path, freeze, stage, calculated,
        replay_hash, replay_passed, String(command); anchor_result)
end

function replay_result(result::AbstractString;
                       config_path::AbstractString=DEFAULT_CONFIG)
    result = abspath(result)
    checksum = verify_checksum_manifest(result)
    checksum["passed"] || throw(ArgumentError(
        "result checksum verification failed: $(checksum["failures"])"))
    manifest = TOML.parsefile(joinpath(result, "manifest.toml"))
    config = load_config(config_path)
    stage = Symbol(manifest["stage"])
    freeze = String(manifest["freeze"])
    recalculated = calculate_science(config, freeze, stage;
        collect_runtime=false, config_path)
    science_path = joinpath(result, "science.json")
    existing = chomp(read(science_path, String))
    # The stored object adds only the deterministic-replay record after the
    # first/replay comparison. Compare against the pre-recorded first hash.
    stored_manifest_hash = String(manifest["base_scientific_sha256"])
    recalculated_hash = scientific_sha256(recalculated.science)
    passed = recalculated_hash == stored_manifest_hash
    Dict(
        "passed" => passed,
        "checksum_passed" => checksum["passed"],
        "expected_scientific_sha256" => stored_manifest_hash,
        "recalculated_scientific_sha256" => recalculated_hash,
        "stored_science_file_sha256" => file_sha256(science_path),
        "stored_science_bytes" => sizeof(existing),
    )
end

function usage()
    "usage:\n" *
    "  rq2_gd_state_use_001.jl preflight-probe [--config FILE]\n" *
    "  rq2_gd_state_use_001.jl freeze --output DIR [--config FILE]\n" *
    "  rq2_gd_state_use_001.jl anchor --freeze DIR --output DIR [--config FILE]\n" *
    "  rq2_gd_state_use_001.jl heldout --freeze DIR --anchor-result DIR --output DIR [--config FILE]\n" *
    "  rq2_gd_state_use_001.jl replay --result DIR [--config FILE]"
end

function parse_cli(arguments)
    isempty(arguments) && throw(ArgumentError(usage()))
    mode = Symbol(arguments[1])
    options = Dict{String,String}()
    index = 2
    while index <= length(arguments)
        argument = arguments[index]
        argument in ("-h", "--help") && return (; help=true, mode, options)
        startswith(argument, "--") || throw(ArgumentError("unknown argument $argument"))
        index < length(arguments) || throw(ArgumentError("$argument requires a path"))
        options[argument[3:end]] = arguments[index + 1]
        index += 2
    end
    (; help=false, mode, options)
end

function main(arguments=ARGS)
    parsed = parse_cli(arguments)
    if parsed.help
        println(usage())
        return 0
    end
    config_path = get(parsed.options, "config", DEFAULT_CONFIG)
    command = join(["julia", "--project=" * Base.active_project(),
                    abspath(RUNNER_PATH), arguments...], " ")
    if parsed.mode === Symbol("preflight-probe")
        config = load_config(config_path)
        gate = source_gate(config)
        gate["passed"] || throw(ArgumentError("retained-source gate failed"))
        enforce_thread_environment(config)
        native = load_native(config)
        generated = make_code(config, native)
        println("native graph SHA-256: ", graph_sha256(generated.code.check_vars))
        return 0
    elseif parsed.mode === :freeze
        output = get(parsed.options, "output", nothing)
        output === nothing && throw(ArgumentError("freeze requires --output"))
        result = freeze_inputs(output; config_path, command)
        println("freeze complete: ", result["output"])
        println("input rows: ", result["input_rows"])
        return 0
    elseif parsed.mode in (:anchor, :heldout)
        freeze = get(parsed.options, "freeze", nothing)
        output = get(parsed.options, "output", nothing)
        freeze === nothing && throw(ArgumentError("$(parsed.mode) requires --freeze"))
        output === nothing && throw(ArgumentError("$(parsed.mode) requires --output"))
        anchor_result = get(parsed.options, "anchor-result", nothing)
        written = run_stage(parsed.mode, output, freeze;
            config_path, anchor_result, command)
        println("$(parsed.mode) status: ", written.completion["status"])
        println("correctness passed: ", written.completion["correctness_passed"])
        println("expansion authorized: ", written.completion["anchor_expansion_authorized"])
        return written.completion["correctness_passed"] ? 0 : 2
    elseif parsed.mode === :replay
        result_path = get(parsed.options, "result", nothing)
        result_path === nothing && throw(ArgumentError("replay requires --result"))
        replay = replay_result(result_path; config_path)
        println("replay passed: ", replay["passed"])
        println("scientific SHA-256: ", replay["recalculated_scientific_sha256"])
        return replay["passed"] ? 0 : 2
    end
    throw(ArgumentError("unsupported mode $(parsed.mode)\n$(usage())"))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    # The archived native module is included lazily.  Enter the newest world
    # before CLI execution so Julia 1.12 can see all of its top-level bindings.
    exit(Base.invokelatest(main))
end

end # module

