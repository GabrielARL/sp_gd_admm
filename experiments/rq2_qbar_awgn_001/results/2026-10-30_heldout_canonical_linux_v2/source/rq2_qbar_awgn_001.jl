#!/usr/bin/env julia

module RQ2QbarAWGN001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using SHA
using Statistics
using TOML

const CORE = JadeJcade.ReceiverCore
const HERE = @__DIR__
const RUNNER_PATH = @__FILE__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const TEST_PATH = joinpath(HERE, "test_rq2_qbar_awgn_001.jl")
const PREFLIGHT_RECORD_PATH = joinpath(HERE, "preflight_validation.md")

include("/home/gabiel/Documents/GitHub/JadeJcade/experiments/jade_awgn/parity_admm_awgn.jl")
const AWGN = ParityADMMAWGN

export load_config, source_gate, GraphView, graph_view, instrumented_decode,
       native_decode, freeze_inputs, verify_freeze, prerun_gates,
       calculate_phase, run_freeze, run_phase, replay_result, main,
       canonical_json, scientific_sha256, paired_endpoint_counts,
       mcnemar_exact_pvalue, newcombe_paired_interval

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
text_sha256(value::AbstractString) = bytes2hex(sha256(codeunits(value)))

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

function canonical_json(value)
    if value === nothing
        "null"
    elseif value isa Bool
        value ? "true" : "false"
    elseif value isa Integer
        string(value)
    elseif value isa AbstractFloat
        isfinite(value) || throw(ArgumentError("canonical JSON requires finite floats"))
        repr(Float64(value))
    elseif value isa AbstractString
        "\"" * json_escape(value) * "\""
    elseif value isa Symbol
        canonical_json(String(value))
    elseif value isa NamedTuple
        canonical_json(Dict(String(key) => getfield(value, key) for key in keys(value)))
    elseif value isa AbstractDict
        keyed = [(canonical_object_key(first(pair)), last(pair)) for pair in value]
        canonical_keys = first.(keyed)
        length(unique(canonical_keys)) == length(canonical_keys) ||
            throw(ArgumentError("canonical JSON object keys collide after conversion"))
        ordered = sort!(keyed; by=first)
        "{" * join((canonical_json(first(pair)) * ":" *
                     canonical_json(last(pair)) for pair in ordered), ",") * "}"
    elseif value isa AbstractMatrix
        canonical_json([[value[row, column] for column in axes(value, 2)]
                        for row in axes(value, 1)])
    elseif value isa AbstractVector || value isa Tuple
        "[" * join((canonical_json(item) for item in value), ",") * "]"
    else
        throw(ArgumentError("unsupported canonical JSON value $(typeof(value))"))
    end
end

scientific_sha256(value) = text_sha256(canonical_json(value))

function canonical_object_key(value)
    if value isa AbstractString
        String(value)
    elseif value isa Symbol || value isa Integer
        string(value)
    else
        throw(ArgumentError("unsupported canonical JSON object key $(typeof(value))"))
    end
end

function write_new_file(path::AbstractString, content::AbstractString)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    open(path, "w") do io
        write(io, content)
    end
    path
end

function write_toml(path::AbstractString, value)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    open(path, "w") do io
        TOML.print(io, value; sorted=true)
    end
    path
end

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "bpgd-rq2-qbar-awgn-001/v1" ||
        throw(ArgumentError("unsupported configuration schema"))
    config["experiment_id"] == "BPGD-RQ2-QBAR-AWGN-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    Int(config["anchor"]["frame_last"]) - Int(config["anchor"]["frame_first"]) + 1 ==
        Int(config["anchor"]["expected_count"]) ||
        throw(ArgumentError("anchor frame count differs from the frozen configuration"))
    Int(config["heldout"]["frame_last"]) - Int(config["heldout"]["frame_first"]) + 1 ==
        Int(config["heldout"]["expected_count"]) ||
        throw(ArgumentError("held-out frame count differs from the frozen configuration"))
    config
end

function require_registered_config(path::AbstractString)
    isfile(path) || throw(ArgumentError("configuration file does not exist: $path"))
    realpath(path) == realpath(DEFAULT_CONFIG) ||
        throw(ArgumentError("alternate configuration files are forbidden for this attempt"))
    true
end

function git_output(repo, arguments...)
    try
        readchomp(Cmd(String["git", "-C", String(repo), String.(arguments)...]))
    catch error
        "ERROR: " * sprint(showerror, error)
    end
end

capture_ok(value::AbstractString) = !startswith(value, "ERROR: ")

function gzip_version_line()
    try
        first(split(readchomp(`gzip --version`), '\n'))
    catch error
        "ERROR: " * sprint(showerror, error)
    end
end

function source_paths(config)
    jade = config["jade"]
    paths = Dict(
        "config.toml" => DEFAULT_CONFIG,
        "experiment_card.md" => CARD_PATH,
        "rq2_qbar_awgn_001.jl" => RUNNER_PATH,
        "test_rq2_qbar_awgn_001.jl" => TEST_PATH,
        "preflight_validation.md" => PREFLIGHT_RECORD_PATH,
        "jade_core_common.jl" => String(jade["core_common"]),
        "jade_parity_admm_awgn.jl" => String(jade["awgn_generator"]),
        "jade_parity_admm_decoder.jl" => String(jade["generator_dependency"]),
        "jade_Project.toml" => String(jade["project_toml"]),
        "jade_Manifest.toml" => String(jade["manifest_toml"]),
    )
    source_root = joinpath(String(jade["repo"]), "src")
    for (directory, _, files) in walkdir(source_root), file in files
        endswith(file, ".jl") || continue
        path = joinpath(directory, file)
        relative = replace(relpath(path, source_root), '/' => "__")
        paths["jade_src__" * relative] = path
    end
    paths
end

function source_hashes(config)
    Dict(name => (isfile(path) ? file_sha256(path) : "missing")
         for (name, path) in source_paths(config))
end

function source_gate(config)
    jade = config["jade"]
    repo = String(jade["repo"])
    loaded_root = try
        realpath(dirname(dirname(pathof(JadeJcade))))
    catch
        "ERROR"
    end
    expected = Dict(
        "jade_core_common.jl" => String(jade["core_common_sha256"]),
        "jade_parity_admm_awgn.jl" => String(jade["awgn_generator_sha256"]),
        "jade_parity_admm_decoder.jl" => String(jade["generator_dependency_sha256"]),
        "jade_Project.toml" => String(jade["project_toml_sha256"]),
        "jade_Manifest.toml" => String(jade["manifest_toml_sha256"]),
    )
    observed = source_hashes(config)
    head = git_output(repo, "rev-parse", "HEAD")
    status = git_output(repo, "status", "--porcelain=v1", "--untracked-files=all")
    checks = Dict(
        "loaded_jade_path" => loaded_root == realpath(repo),
        "active_project" => realpath(Base.active_project()) ==
                            realpath(String(jade["project_toml"])),
        "jade_head" => head == String(jade["expected_head"]),
        "jade_status_capture" => capture_ok(status),
        "julia_version" => string(VERSION) == String(config["validation"]["expected_julia_version"]),
        "julia_threads" => Threads.nthreads() == Int(config["validation"]["julia_threads"]),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads() == Int(config["validation"]["blas_threads"]),
    )
    for (name, value) in expected
        checks["source_hash_" * name] = get(observed, name, "missing") == value
    end
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "expected_hashes" => expected,
        "observed_hashes" => observed,
        "loaded_jade_root" => loaded_root,
        "jade_head" => head,
        "jade_status_porcelain_v1" => status,
        "jade_status_sha256" => text_sha256(status),
    )
end

struct GraphView
    n::Int
    checks::Vector{Vector{Int}}
    variable_edges::Vector{Vector{Tuple{Int,Int}}}
end

function GraphView(checks::Vector{Vector{Int}}, n::Integer)
    edges = [Tuple{Int,Int}[] for _ in 1:Int(n)]
    for (check_index, members) in enumerate(checks)
        isempty(members) && throw(ArgumentError("empty parity check"))
        for (slot, variable) in enumerate(members)
            1 <= variable <= n || throw(ArgumentError("variable outside 1:$n"))
            push!(edges[variable], (check_index, slot))
        end
    end
    GraphView(Int(n), deepcopy(checks), edges)
end

graph_view(code) = GraphView([Int.(members) for members in code.check_vars], code.n)

function update_hash!(context, values::AbstractVector{Float64})
    count = Int64(length(values))
    SHA.update!(context, reinterpret(UInt8, [count]))
    SHA.update!(context, reinterpret(UInt8, values))
end

function rows_sha256(rows::Vector{Vector{Float64}})
    context = SHA.SHA2_256_CTX()
    SHA.update!(context, reinterpret(UInt8, [Int64(length(rows))]))
    for row in rows
        update_hash!(context, row)
    end
    bytes2hex(SHA.digest!(context))
end

function vector_sha256(values::AbstractVector{Float64})
    context = SHA.SHA2_256_CTX()
    update_hash!(context, collect(values))
    bytes2hex(SHA.digest!(context))
end

function bits_sha256(values::AbstractVector{Bool})
    context = SHA.SHA2_256_CTX()
    SHA.update!(context, reinterpret(UInt8, [Int64(length(values))]))
    SHA.update!(context, UInt8.(values))
    bytes2hex(SHA.digest!(context))
end

function syndrome_vector(graph::GraphView, bits::AbstractVector{Bool})
    result = falses(length(graph.checks))
    for (check_index, members) in enumerate(graph.checks)
        parity = false
        for variable in members
            parity = xor(parity, bits[variable])
        end
        result[check_index] = parity
    end
    result
end

syndrome_weight(graph::GraphView, bits::AbstractVector{Bool}) =
    count(syndrome_vector(graph, bits))

function state_summary_size(q, u, qstar, qbar, delta, lch, lpost, bits, parity)
    Base.summarysize((q=q, u=u, qstar=qstar, qbar=qbar, delta=delta,
                      lch=lch, lpost=lpost, bits=bits, parity=parity))
end

function copy_snapshot(iteration, graph, q, u, qstar, qbar, delta, lpost, bits, syndrome)
    (;
        iteration=Int(iteration),
        checks=deepcopy(graph.checks),
        q=deepcopy(q),
        u=deepcopy(u),
        qstar=deepcopy(qstar),
        qbar=copy(qbar),
        delta=deepcopy(delta),
        lpost=copy(lpost),
        bits=copy(bits),
        syndrome=Int(syndrome),
    )
end

function operation_counts(graph::GraphView, iterations::Integer,
                          incremental_syndrome_toggles::Integer)
    edge_count = sum(length, graph.checks)
    check_inner = sum(length(members) > 1 ? length(members) * (length(members) - 1) : 0
                      for members in graph.checks)
    nonlinear_outputs = sum(length(members) > 1 ? length(members) : 0
                            for members in graph.checks)
    nontrivial_checks = count(members -> length(members) > 1, graph.checks)
    nonisolated_variables = count(edges -> !isempty(edges), graph.variable_edges)
    Dict(
        "message_passing_iterations" => Int(iterations),
        "check_updates" => Int(iterations) * length(graph.checks),
        "outgoing_check_messages" => Int(iterations) * edge_count,
        "check_limit_tanh_evaluations" => Int(iterations) * nontrivial_checks,
        "check_limit_half_scale_multiplications" => Int(iterations) * nontrivial_checks,
        "check_half_input_scale_multiplications" => Int(iterations) * check_inner,
        "tanh_evaluations" => Int(iterations) * check_inner,
        "check_product_multiplications" => Int(iterations) * check_inner,
        "atanh_evaluations" => Int(iterations) * nonlinear_outputs,
        "check_input_clamps" => Int(iterations) * check_inner,
        "check_product_clamps" => Int(iterations) * nonlinear_outputs,
        "check_output_scale_multiplications" => Int(iterations) * nonlinear_outputs,
        "check_output_clamps" => Int(iterations) * nonlinear_outputs,
        "variable_edge_additions" => Int(iterations) * edge_count,
        "qstar_subtractions" => Int(iterations) * edge_count,
        "qbar_accumulations" => Int(iterations) * edge_count,
        "qbar_divisions" => Int(iterations) * nonisolated_variables,
        "delta_subtractions" => Int(iterations) * edge_count,
        "delta_zero_sum_accumulations" => Int(iterations) * edge_count,
        "reconstruction_additions" => Int(iterations) * edge_count,
        "reconstruction_error_subtractions" => Int(iterations) * edge_count,
        "retained_spread_minmax_comparisons" => Int(iterations) * 2edge_count,
        "retained_spread_subtractions" => Int(iterations) * nonisolated_variables,
        "retained_q_assignments" => Int(iterations) * edge_count,
        "hard_decision_comparisons" => Int(iterations) * graph.n,
        "initial_syndrome_xors" => Int(iterations > 0 ? edge_count : 0),
        "incremental_syndrome_parity_toggles" => Int(incremental_syndrome_toggles),
        "independent_syndrome_xors" => Int(iterations) * edge_count,
    )
end

function instrumented_decode(graph::GraphView, channel_llr::AbstractVector{<:Real};
                             mode::Symbol=:full, maximum_iterations::Integer=80,
                             stop_on_valid::Bool=true,
                             capture_snapshots::Bool=false,
                             record_trace::Bool=true)
    mode in (:full, :tied, :shadow, :reconstruct) ||
        throw(ArgumentError("unknown state mode: $mode"))
    length(channel_llr) == graph.n || throw(DimensionMismatch("LLR length differs from graph"))
    all(isfinite, channel_llr) || throw(ArgumentError("finite LLRs required"))
    maximum_iterations > 0 || throw(ArgumentError("positive iteration limit required"))

    lch = Float64.(channel_llr)
    lpost = copy(lch)
    bits = falses(graph.n)
    parity = falses(length(graph.checks))
    q = [zeros(Float64, length(members)) for members in graph.checks]
    u = [zeros(Float64, length(members)) for members in graph.checks]
    qstar = [zeros(Float64, length(members)) for members in graph.checks]
    delta = [zeros(Float64, length(members)) for members in graph.checks]
    qbar = zeros(Float64, graph.n)
    for (check_index, members) in enumerate(graph.checks), slot in eachindex(members)
        q[check_index][slot] = lch[members[slot]]
    end

    physical_state_bytes = state_summary_size(q, u, qstar, qbar, delta,
                                               lch, lpost, bits, parity)
    trace = Dict{String,Any}[]
    snapshots = Dict{Int,Any}()
    maximum_delta_zero_sum_error = 0.0
    maximum_reconstruction_error = 0.0
    maximum_retained_spread = 0.0
    delta_nonzero = false
    intervention_activated = false
    terminal_syndrome = length(graph.checks)
    iterations = 0
    syndrome_consistency = true
    incremental_syndrome_toggles = 0

    for iteration in 1:Int(maximum_iterations)
        iterations = iteration
        q_input_sha256 = record_trace ? rows_sha256(q) : "not_recorded"
        for check_index in eachindex(graph.checks)
            CORE._bp_check_sum_product!(u[check_index], q[check_index])
        end

        for variable in 1:graph.n
            incident = graph.variable_edges[variable]
            total = lch[variable]
            for (check_index, slot) in incident
                total += u[check_index][slot]
            end
            lpost[variable] = total
            decision = total < 0.0
            if iteration > 1 && decision != bits[variable]
                for (check_index, _) in incident
                    parity[check_index] = !parity[check_index]
                    incremental_syndrome_toggles += 1
                end
            end
            bits[variable] = decision
            sum_qstar = 0.0
            for (check_index, slot) in incident
                value = total - u[check_index][slot]
                qstar[check_index][slot] = value
                sum_qstar += value
            end
            qbar[variable] = isempty(incident) ? lch[variable] : sum_qstar / length(incident)
            delta_sum = 0.0
            for (check_index, slot) in incident
                difference = qstar[check_index][slot] - qbar[variable]
                delta[check_index][slot] = difference
                delta_sum += difference
                reconstructed = qbar[variable] + difference
                maximum_reconstruction_error = max(maximum_reconstruction_error,
                    abs(reconstructed - qstar[check_index][slot]))
                retained = if mode in (:full, :shadow)
                    qstar[check_index][slot]
                elseif mode === :tied
                    qbar[variable]
                else
                    reconstructed
                end
                q[check_index][slot] = retained
                delta_nonzero |= difference != 0.0
            end
            maximum_delta_zero_sum_error = max(maximum_delta_zero_sum_error, abs(delta_sum))
            if !isempty(incident)
                minimum_value = Inf
                maximum_value = -Inf
                for (check_index, slot) in incident
                    minimum_value = min(minimum_value, q[check_index][slot])
                    maximum_value = max(maximum_value, q[check_index][slot])
                end
                spread = maximum_value - minimum_value
                maximum_retained_spread = max(maximum_retained_spread, abs(spread))
            end
        end

        if iteration == 1
            parity .= syndrome_vector(graph, bits)
        end
        terminal_syndrome = count(parity)
        independent_parity = syndrome_vector(graph, bits)
        independent_syndrome = count(independent_parity)
        syndrome_consistency &= parity == independent_parity &&
                                terminal_syndrome == independent_syndrome
        if record_trace
            record = Dict(
                "iteration" => iteration,
                "q_input_sha256" => q_input_sha256,
                "q_sha256" => rows_sha256(q),
                "u_sha256" => rows_sha256(u),
                "qstar_sha256" => rows_sha256(qstar),
                "qbar_sha256" => vector_sha256(qbar),
                "delta_sha256" => rows_sha256(delta),
                "lpost_sha256" => vector_sha256(lpost),
                "hard_sha256" => bits_sha256(bits),
                "syndrome_weight" => terminal_syndrome,
                "independent_syndrome_weight" => independent_syndrome,
                "syndrome_consistent" => parity == independent_parity &&
                                         terminal_syndrome == independent_syndrome,
                "coded_bit_errors" => count(bits),
                "maximum_absolute_delta" => maximum((abs(value) for row in delta for value in row); init=0.0),
                "rms_delta" => sqrt(sum(value * value for row in delta for value in row) /
                                    max(1, sum(length, delta))),
                "delta_zero_sum_error" => maximum_delta_zero_sum_error,
                "reconstruction_error" => maximum_reconstruction_error,
            )
            push!(trace, record)
        end
        if capture_snapshots && iteration in (1, 2)
            snapshots[iteration] = copy_snapshot(iteration, graph, q, u, qstar,
                                                 qbar, delta, lpost, bits,
                                                 terminal_syndrome)
        end
        stop_on_valid && terminal_syndrome == 0 && break
    end

    if capture_snapshots && !haskey(snapshots, iterations)
        snapshots[iterations] = copy_snapshot(iterations, graph, q, u, qstar,
                                              qbar, delta, lpost, bits,
                                              terminal_syndrome)
    end
    edge_count = sum(length, graph.checks)
    logical_q_values = mode === :tied ?
        count(edges -> !isempty(edges), graph.variable_edges) : edge_count
    result = (;
        mode,
        lpost_metric=-copy(lpost),
        hard=copy(bits),
        syndrome=terminal_syndrome,
        valid=terminal_syndrome == 0,
        iterations,
        trace,
        snapshots,
        q,
        u,
        qstar,
        qbar,
        delta,
        lch,
        lpost,
        parity=copy(parity),
        physical_state_bytes,
        logical_state=Dict(
            "variable_to_check_independent_values" => logical_q_values,
            "check_to_variable_independent_values" => edge_count,
            "qstar_edge_values" => edge_count,
            "delta_edge_values" => edge_count,
            "qbar_bit_values" => graph.n,
            "channel_values" => graph.n,
            "posterior_values" => graph.n,
            "hard_decision_bits" => graph.n,
            "check_parity_bits" => length(graph.checks),
            "physical_variable_to_check_slots" => edge_count,
            "physical_check_to_variable_slots" => edge_count,
            "physical_qstar_slots" => edge_count,
            "physical_delta_slots" => edge_count,
        ),
        operation_counts=operation_counts(graph, iterations, incremental_syndrome_toggles),
        maximum_delta_zero_sum_error,
        maximum_reconstruction_error,
        maximum_tied_spread=maximum_retained_spread,
        intervention_activated=mode === :tied && delta_nonzero,
        delta_nonzero,
        syndrome_consistency,
    )
    result
end

function native_decode(modem, code, channel_llr)
    timed = @timed CORE._bp_decode_sum_product(modem, code, -Float64.(channel_llr))
    value = timed.value
    scratch = CORE._bp_scratch(modem, code)
    hard = copy(scratch.bits)
    (;
        lpost_metric=copy(value.lpost_metric),
        hard,
        syndrome=Int(value.syndrome),
        valid=Bool(value.valid),
        iterations=Int(value.iterations),
        lch=copy(scratch.lch),
        lpost=copy(scratch.lpost),
        parity=copy(scratch.check_parity),
        q=deepcopy(scratch.q),
        u=deepcopy(scratch.r),
        seconds=Float64(timed.time),
        allocated_bytes=Int(timed.bytes),
    )
end

float_bits_equal(left::AbstractVector{Float64}, right::AbstractVector{Float64}) =
    length(left) == length(right) &&
    reinterpret(UInt64, left) == reinterpret(UInt64, right)

rows_bits_equal(left::Vector{Vector{Float64}}, right::Vector{Vector{Float64}}) =
    length(left) == length(right) &&
    all(float_bits_equal(left[index], right[index]) for index in eachindex(left))

function endpoint_equivalence(local_result, native_result)
    checks = Dict(
        "posterior_bitwise" => float_bits_equal(local_result.lpost_metric, native_result.lpost_metric),
        "hard_decision" => local_result.hard == native_result.hard,
        "syndrome" => local_result.syndrome == native_result.syndrome,
        "validity" => local_result.valid == native_result.valid,
        "stopping_iteration" => local_result.iterations == native_result.iterations,
        "channel_bitwise" => float_bits_equal(local_result.lch, native_result.lch),
        "posterior_internal_bitwise" => float_bits_equal(local_result.lpost, native_result.lpost),
        "native_bits" => local_result.hard == native_result.hard,
        "check_parity" => local_result.parity == native_result.parity,
        "variable_to_check_bitwise" => rows_bits_equal(local_result.q, native_result.q),
        "check_to_variable_bitwise" => rows_bits_equal(local_result.u, native_result.u),
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "maximum_posterior_difference" => maximum(abs,
             local_result.lpost_metric - native_result.lpost_metric; init=0.0))
end

function logsumexp(values::Vector{Float64})
    isempty(values) && return -Inf
    maximum_value = maximum(values)
    maximum_value + log(sum(exp(value - maximum_value) for value in values))
end

"""Enumerate even-parity local configurations for a bit-zero-positive message."""
function enumerated_check_message(incoming::Vector{Float64}, target::Integer)
    degree = length(incoming)
    1 <= target <= degree || throw(BoundsError(incoming, target))
    scores = (Float64[], Float64[])
    others = [index for index in 1:degree if index != target]
    for mask in 0:(1 << length(others)) - 1
        parity = false
        score = 0.0
        for (position, index) in enumerate(others)
            bit = ((mask >> (position - 1)) & 1) == 1
            parity = xor(parity, bit)
            clipped = clamp(incoming[index], -20.0, 20.0)
            score += 0.5 * clipped * (bit ? -1.0 : 1.0)
        end
        target_bit = parity
        push!(scores[Int(target_bit) + 1], score)
    end
    logsumexp(scores[1]) - logsumexp(scores[2])
end

function check_enumeration_gate(config)
    maximum_error = 0.0
    maximum_regular_error = 0.0
    maximum_extreme_error = 0.0
    records = Dict{String,Any}[]
    for degree in 2:6
        inputs = (
            [0.17 * index - 0.43 + (-1.0)^index * 0.11
             for index in 1:degree],
            [index == 1 ? 0.0 : (-1.0)^index * 0.37 * index
             for index in 1:degree],
            [(-1.0)^index * (19.5 + 0.07 * index) for index in 1:degree],
            [(-1.0)^index * (24.0 + 3.0 * index) for index in 1:degree],
        )
        for (case_index, incoming) in enumerate(inputs)
            native_values = zeros(Float64, degree)
            CORE._bp_check_sum_product!(native_values, incoming)
            enumerated = [enumerated_check_message(incoming, target)
                          for target in 1:degree]
            error = maximum(abs, native_values - enumerated)
            maximum_error = max(maximum_error, error)
            case_index <= 2 ?
                (maximum_regular_error = max(maximum_regular_error, error)) :
                (maximum_extreme_error = max(maximum_extreme_error, error))
            push!(records, Dict("degree" => degree, "case" => case_index,
                                "maximum_error" => error,
                                "native" => native_values,
                                "enumerated" => enumerated))
        end
    end
    degree_one = zeros(Float64, 1)
    CORE._bp_check_sum_product!(degree_one, [-31.0])
    tolerance = Float64(config["validation"]["enumeration_tolerance"])
    extreme_tolerance = Float64(config["validation"]["enumeration_near_clip_tolerance"])
    Dict("passed" => maximum_regular_error <= tolerance &&
                     maximum_extreme_error <= extreme_tolerance &&
                     degree_one == [20.0],
         "maximum_error" => maximum_error,
         "maximum_regular_error" => maximum_regular_error,
         "maximum_extreme_error" => maximum_extreme_error,
         "tolerance" => tolerance,
         "near_clip_tolerance" => extreme_tolerance,
         "degree_one_output" => degree_one,
         "records" => records)
end

function compare_decodes(left, right; tolerance=0.0)
    posterior_difference = maximum(abs,
        left.lpost_metric - right.lpost_metric; init=0.0)
    checks = Dict(
        "hard_decision" => left.hard == right.hard,
        "syndrome" => left.syndrome == right.syndrome,
        "validity" => left.valid == right.valid,
        "stopping_iteration" => left.iterations == right.iterations,
        "posterior" => posterior_difference <= tolerance,
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "maximum_posterior_difference" => posterior_difference)
end

function first_iteration_gate(full, tied)
    isempty(full.trace) && return Dict("passed" => false, "reason" => "empty full trace")
    isempty(tied.trace) && return Dict("passed" => false, "reason" => "empty tied trace")
    left = full.trace[1]
    right = tied.trace[1]
    unchanged = Dict(
        "check_input" => left["q_input_sha256"] == right["q_input_sha256"],
        "check_to_variable" => left["u_sha256"] == right["u_sha256"],
        "qstar" => left["qstar_sha256"] == right["qstar_sha256"],
        "qbar" => left["qbar_sha256"] == right["qbar_sha256"],
        "delta" => left["delta_sha256"] == right["delta_sha256"],
        "posterior" => left["lpost_sha256"] == right["lpost_sha256"],
        "hard_decision" => left["hard_sha256"] == right["hard_sha256"],
        "syndrome" => left["syndrome_weight"] == right["syndrome_weight"],
    )
    q_changed = left["q_sha256"] != right["q_sha256"]
    delta_nonzero = left["maximum_absolute_delta"] > 0.0
    consumed_at_iteration_two = length(full.trace) >= 2 && length(tied.trace) >= 2 &&
        full.trace[2]["q_input_sha256"] != tied.trace[2]["q_input_sha256"] &&
        full.trace[2]["u_sha256"] != tied.trace[2]["u_sha256"]
    Dict(
        "passed" => all(values(unchanged)) && q_changed && delta_nonzero &&
                    consumed_at_iteration_two,
        "unchanged_before_next_check" => unchanged,
        "retained_q_changed_after_iteration_one" => q_changed,
        "delta_nonzero" => delta_nonzero,
        "check_iteration_two_consumed_different_q" => consumed_at_iteration_two,
    )
end

function degree_one_gate(config)
    graph = GraphView([[1, 2, 3], [4, 5, 6]], 6)
    llr = [-2.1, 0.4, 1.3, -0.7, 2.2, -1.1]
    full = instrumented_decode(graph, llr; mode=:full, maximum_iterations=4,
                               stop_on_valid=false)
    tied = instrumented_decode(graph, llr; mode=:tied, maximum_iterations=4,
                               stop_on_valid=false)
    exact_trace = canonical_json(full.trace) == canonical_json(tied.trace)
    maximum_delta = maximum((entry["maximum_absolute_delta"] for entry in full.trace); init=0.0)
    Dict(
        "passed" => exact_trace && maximum_delta == 0.0 &&
                    float_bits_equal(full.lpost_metric, tied.lpost_metric),
        "trace_exact" => exact_trace,
        "maximum_absolute_delta" => maximum_delta,
        "posterior_bitwise" => float_bits_equal(full.lpost_metric, tied.lpost_metric),
    )
end

function relabel_gate(config)
    checks = [[1, 2, 3], [2, 3, 4], [1, 4]]
    relabeled = [reverse(checks[3]), reverse(checks[1]), reverse(checks[2])]
    graph = GraphView(checks, 4)
    graph_relabel = GraphView(relabeled, 4)
    llr = [-1.7, 0.2, 1.1, -0.4]
    tolerance = Float64(config["validation"]["relabel_tolerance"])
    mode_results = Dict{String,Any}()
    passed = true
    for mode in (:full, :tied)
        original = instrumented_decode(graph, llr; mode, maximum_iterations=5,
                                       stop_on_valid=false)
        changed = instrumented_decode(graph_relabel, llr; mode, maximum_iterations=5,
                                      stop_on_valid=false)
        posterior_error = maximum(abs,
            original.lpost_metric - changed.lpost_metric; init=0.0)
        checks_gate = Dict(
            "hard_decision" => original.hard == changed.hard,
            "syndrome_weight" => original.syndrome == changed.syndrome,
            "posterior" => posterior_error <= tolerance,
        )
        mode_results[String(mode)] = Dict(
            "passed" => all(values(checks_gate)),
            "checks" => checks_gate,
            "maximum_posterior_difference" => posterior_error,
        )
        passed &= mode_results[String(mode)]["passed"]
    end
    Dict("passed" => passed, "modes" => mode_results, "tolerance" => tolerance)
end

function prerun_gates(config, modem, code, input)
    graph = graph_view(code)
    native_result = native_decode(modem, code, input.llr)
    full = instrumented_decode(graph, input.llr; mode=:full,
                               maximum_iterations=Int(config["decoder"]["maximum_message_passing_iterations"]),
                               stop_on_valid=true, capture_snapshots=true)
    tied = instrumented_decode(graph, input.llr; mode=:tied,
                               maximum_iterations=Int(config["decoder"]["maximum_message_passing_iterations"]),
                               stop_on_valid=true, capture_snapshots=true)
    shadow = instrumented_decode(graph, input.llr; mode=:shadow,
                                 maximum_iterations=Int(config["decoder"]["maximum_message_passing_iterations"]),
                                 stop_on_valid=true)
    reconstruct = instrumented_decode(graph, input.llr; mode=:reconstruct,
                                      maximum_iterations=Int(config["decoder"]["maximum_message_passing_iterations"]),
                                      stop_on_valid=true)
    endpoint = endpoint_equivalence(full, native_result)
    shadow_gate = Dict(
        "passed" => compare_decodes(full, shadow; tolerance=0.0)["passed"] &&
                    canonical_json(full.trace) == canonical_json(shadow.trace),
        "decode" => compare_decodes(full, shadow; tolerance=0.0),
        "trace_exact" => canonical_json(full.trace) == canonical_json(shadow.trace),
    )
    reconstruction_tolerance = Float64(config["validation"]["reconstruction_tolerance"])
    reconstruct_gate = compare_decodes(full, reconstruct;
        tolerance=reconstruction_tolerance)
    reconstruct_gate["maximum_local_reconstruction_error"] =
        reconstruct.maximum_reconstruction_error
    reconstruct_gate["local_error_within_tolerance"] =
        reconstruct.maximum_reconstruction_error <= reconstruction_tolerance
    reconstruct_gate["passed"] &= reconstruct_gate["local_error_within_tolerance"]
    first_iteration = first_iteration_gate(full, tied)
    enumeration = check_enumeration_gate(config)
    degree_one = degree_one_gate(config)
    relabel = relabel_gate(config)
    delta_gate = Dict(
        "passed" => full.maximum_delta_zero_sum_error <=
                    Float64(config["validation"]["delta_zero_sum_tolerance"]) &&
                    tied.maximum_delta_zero_sum_error <=
                    Float64(config["validation"]["delta_zero_sum_tolerance"]) &&
                    tied.maximum_tied_spread == 0.0,
        "full_delta_zero_sum_error" => full.maximum_delta_zero_sum_error,
        "tied_delta_zero_sum_error" => tied.maximum_delta_zero_sum_error,
        "tied_maximum_spread" => tied.maximum_tied_spread,
    )
    syndrome_gate = Dict(
        "passed" => full.syndrome_consistency && tied.syndrome_consistency &&
                    syndrome_weight(graph, full.hard) == full.syndrome &&
                    syndrome_weight(graph, tied.hard) == tied.syndrome,
        "full" => syndrome_weight(graph, full.hard) == full.syndrome,
        "tied" => syndrome_weight(graph, tied.hard) == tied.syndrome,
    )
    checks = Dict(
        "check_enumeration" => enumeration["passed"],
        "native_full_equivalence" => endpoint["passed"],
        "shadow_control" => shadow_gate["passed"],
        "reconstruction_control" => reconstruct_gate["passed"],
        "iteration_one_control" => first_iteration["passed"],
        "degree_one_control" => degree_one["passed"],
        "relabel_control" => relabel["passed"],
        "delta_and_tied_state" => delta_gate["passed"],
        "independent_syndrome" => syndrome_gate["passed"],
        "physical_state_storage_equal" =>
            full.physical_state_bytes == tied.physical_state_bytes,
    )
    (;
        summary=Dict(
            "passed" => all(values(checks)),
            "checks" => checks,
            "check_enumeration" => enumeration,
            "native_full_equivalence" => endpoint,
            "shadow_control" => shadow_gate,
            "reconstruction_control" => reconstruct_gate,
            "iteration_one_control" => first_iteration,
            "degree_one_control" => degree_one,
            "relabel_control" => relabel,
            "delta_and_tied_state" => delta_gate,
            "independent_syndrome" => syndrome_gate,
            "physical_state_bytes" => full.physical_state_bytes,
        ),
        full,
        tied,
    )
end

csv_value(value::Bool) = value ? "true" : "false"
csv_value(value::Integer) = string(value)
csv_value(value::AbstractFloat) = @sprintf("%.17g", Float64(value))
csv_value(value) = string(value)

function csv_text(rows)
    isempty(rows) && throw(ArgumentError("cannot serialize an empty CSV"))
    columns = propertynames(first(rows))
    io = IOBuffer()
        println(io, join(String.(columns), ','))
        for row in rows
            println(io, join((csv_value(getproperty(row, column)) for column in columns), ','))
        end
    String(take!(io))
end

function write_csv(path::AbstractString, rows)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    write_new_file(path, csv_text(rows))
    path
end

float_hex(value::Float64) = @sprintf("0x%016x", reinterpret(UInt64, value))

function parse_simple_csv(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && throw(ArgumentError("empty CSV: $path"))
    columns = split(first(lines), ',')
    [Dict(columns[index] => fields[index] for index in eachindex(columns))
     for line in Iterators.drop(lines, 1)
     for fields in (split(line, ','),)]
end

function retained_anchor_hashes(config)
    reference = String(config["anchor"]["reference_frames_csv"])
    file_sha256(reference) == String(config["anchor"]["reference_frames_sha256"]) ||
        throw(ArgumentError("retained anchor-reference hash differs"))
    expected_columns = [
        "frame", "esn0_db", "receiver", "coded_bit_errors",
        "information_bit_errors", "syndrome_weight", "parity_valid",
        "exact_word", "iterations", "decoder_calls",
        "persistent_directed_edge_state", "ran_first", "seconds",
        "allocated_bytes", "received_sha256", "llr_sha256",
        "hard_word_sha256",
    ]
    observed_columns = split(first(readlines(reference)), ',')
    observed_columns == expected_columns ||
        throw(ArgumentError("retained reference columns differ from the registered schema"))
    rows = parse_simple_csv(reference)
    length(rows) == 2Int(config["anchor"]["expected_count"]) ||
        throw(ArgumentError("retained reference must contain exactly 48 rows"))
    result = Dict{Int,Tuple{String,String}}()
    counts = Dict{Int,Int}()
    receivers = Dict{Int,Set{String}}()
    for row in rows
        frame = parse(Int, row["frame"])
        value = (row["received_sha256"], row["llr_sha256"])
        if haskey(result, frame)
            result[frame] == value ||
                throw(ArgumentError("retained receiver rows disagree for frame $frame"))
        else
            result[frame] = value
        end
        counts[frame] = get(counts, frame, 0) + 1
        push!(get!(receivers, frame, Set{String}()), row["receiver"])
    end
    all(count == 2 for count in values(counts)) ||
        throw(ArgumentError("retained reference must contain two agreeing rows per frame"))
    Set(keys(result)) == Set(Int(config["anchor"]["frame_first"]):
                             Int(config["anchor"]["frame_last"])) ||
        throw(ArgumentError("retained reference frame keys differ from the anchor"))
    expected_receivers = Set(["nms80", "projected_parity_5b095c6"])
    all(labels == expected_receivers for labels in values(receivers)) ||
        throw(ArgumentError("retained reference receiver labels differ"))
    result
end

function input_record(config, code, frame::Integer, split_name::AbstractString)
    esn0 = Float64(config["channel"]["physical_esn0_db"])
    input = AWGN.paired_frame(code, Int(frame); esn0_db=esn0)
    raw_llr = AWGN.qpsk_llrs(input.received, input.noise_variance)
    unit_noise = (input.received .- input.symbols) ./ sqrt(input.noise_variance)
    (;
        split=String(split_name),
        frame=Int(frame),
        noise_seed=Int(config["channel"]["noise_seed_base"]) + Int(frame),
        esn0_db=esn0,
        noise_variance=Float64(input.noise_variance),
        noise_variance_hex=float_hex(Float64(input.noise_variance)),
        transmitted_word_sha256=AWGN.sha256_values(input.word),
        symbols_sha256=AWGN.sha256_values(input.symbols),
        unit_noise_sha256=AWGN.sha256_values(unit_noise),
        received_sha256=input.received_sha256,
        channel_statistic_sha256=input.channel_sha256,
        raw_llr_sha256=AWGN.sha256_values(raw_llr),
        clipped_llr_sha256=input.llr_sha256,
    )
end

function generate_input_records(config, code)
    records = NamedTuple[]
    for frame in Int(config["anchor"]["frame_first"]):Int(config["anchor"]["frame_last"])
        push!(records, input_record(config, code, frame, "anchor"))
    end
    for frame in Int(config["heldout"]["frame_first"]):Int(config["heldout"]["frame_last"])
        push!(records, input_record(config, code, frame, "heldout"))
    end
    records
end

function input_reference_gate(config, records)
    reference = retained_anchor_hashes(config)
    anchor_rows = [row for row in records if row.split == "anchor"]
    checks = Dict{String,Bool}()
    for row in anchor_rows
        expected = get(reference, row.frame, ("missing", "missing"))
        checks[@sprintf("frame_%05d_received", row.frame)] = row.received_sha256 == expected[1]
        checks[@sprintf("frame_%05d_llr", row.frame)] = row.clipped_llr_sha256 == expected[2]
    end
    Dict(
        "passed" => length(anchor_rows) == Int(config["anchor"]["expected_count"]) &&
                    all(values(checks)),
        "checks" => checks,
        "reference_path" => String(config["anchor"]["reference_frames_csv"]),
        "reference_sha256" => file_sha256(String(config["anchor"]["reference_frames_csv"])),
    )
end

function archive_sources(directory::AbstractString, config)
    ispath(directory) && throw(ArgumentError("source archive exists: $directory"))
    mkdir(directory)
    hashes = Dict{String,String}()
    for (name, source) in sort!(collect(source_paths(config)); by=first)
        destination = joinpath(directory, name)
        write_new_file(destination, read(source, String))
        hashes[name] = file_sha256(destination)
    end
    hashes
end

function directory_checksums(root::AbstractString; exclude=Set(["MANIFEST.sha256"]))
    entries = Dict{String,String}()
    for (directory, _, files) in walkdir(root)
        for file in files
            relative = relpath(joinpath(directory, file), root)
            relative in exclude && continue
            entries[relative] = file_sha256(joinpath(root, relative))
        end
    end
    entries
end

function write_checksum_manifest(root::AbstractString)
    entries = directory_checksums(root)
    text = join(("$(entries[name])  $name" for name in sort!(collect(keys(entries)))), "\n") * "\n"
    write_new_file(joinpath(root, "MANIFEST.sha256"), text)
    entries
end

function verify_checksum_manifest(root::AbstractString)
    path = joinpath(root, "MANIFEST.sha256")
    isfile(path) || return Dict("passed" => false, "reason" => "missing checksum manifest")
    checks = Dict{String,Bool}()
    listed = Set{String}()
    root_real = realpath(root)
    for line in readlines(path)
        isempty(strip(line)) && continue
        fields = split(line; limit=2)
        length(fields) == 2 || return Dict("passed" => false, "reason" => "malformed checksum line")
        expected = fields[1]
        relative = strip(fields[2])
        target = joinpath(root, relative)
        safe = !isempty(relative) && !isabspath(relative) &&
               normpath(relative) == relative &&
               all(part -> part != "..", splitpath(relative)) &&
               !(relative in listed) && isfile(target) && !islink(target) &&
               startswith(realpath(target), root_real * "/")
        safe || return Dict("passed" => false,
                            "reason" => "unsafe or duplicate checksum path")
        push!(listed, relative)
        checks[relative] = file_sha256(target) == expected
    end
    symlink_free = all(!islink(joinpath(directory, name))
        for (directory, subdirectories, files) in walkdir(root)
        for name in vcat(subdirectories, files))
    actual = Set(keys(directory_checksums(root)))
    exact_file_set = listed == actual
    Dict("passed" => !isempty(checks) && all(values(checks)) && exact_file_set &&
                     symlink_free,
         "checks" => checks, "exact_file_set" => exact_file_set,
         "symlink_free" => symlink_free,
         "listed_files" => sort!(collect(listed)),
         "actual_files" => sort!(collect(actual)))
end

function provenance_record(config, exact_command)
    jade_repo = String(config["jade"]["repo"])
    sp_repo = normpath(joinpath(HERE, "..", ".."))
    jade_status = git_output(jade_repo, "status", "--porcelain=v1", "--untracked-files=all")
    sp_status = git_output(sp_repo, "status", "--porcelain=v1", "--untracked-files=all")
    thread_environment = Dict(name => get(ENV, name, "unset") for name in
        ("JULIA_NUM_THREADS", "OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS",
         "MKL_NUM_THREADS", "BLIS_NUM_THREADS"))
    gzip_version = gzip_version_line()
    Dict(
        "created_utc" => string(now(UTC)),
        "exact_command" => exact_command,
        "registered_config_path" => realpath(DEFAULT_CONFIG),
        "registered_config_sha256" => file_sha256(DEFAULT_CONFIG),
        "experiment_card_sha256" => file_sha256(CARD_PATH),
        "runner_sha256" => file_sha256(RUNNER_PATH),
        "test_sha256" => file_sha256(TEST_PATH),
        "julia_version" => string(VERSION),
        "active_project" => Base.active_project(),
        "argv" => copy(ARGS),
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "cpu_name" => Sys.CPU_NAME,
        "endianness" => Base.ENDIAN_BOM == 0x04030201 ? "little" : "big",
        "float_hash_encoding" => "native-endian IEEE-754 bytes with explicit vector lengths",
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "blas_vendor" => string(LinearAlgebra.BLAS.vendor()),
        "thread_environment" => thread_environment,
        "gzip_version" => gzip_version,
        "jade_repo" => jade_repo,
        "jade_head" => git_output(jade_repo, "rev-parse", "HEAD"),
        "jade_status_porcelain_v1" => jade_status,
        "jade_status_sha256" => text_sha256(jade_status),
        "sp_repo" => sp_repo,
        "sp_head" => git_output(sp_repo, "rev-parse", "HEAD"),
        "sp_status_porcelain_v1" => sp_status,
        "sp_status_sha256" => text_sha256(sp_status),
    )
end

function freeze_inputs(; config_path::AbstractString=DEFAULT_CONFIG,
                       output::AbstractString,
                       exact_command::AbstractString="freeze")
    ispath(output) && throw(ArgumentError("output directory already exists: $output"))
    require_registered_config(config_path)
    config = load_config(config_path)
    LinearAlgebra.BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))
    source_validation = source_gate(config)
    source_validation["passed"] ||
        throw(ArgumentError("source gate failed before input freeze"))
    modem, code = AWGN.code_and_graph()
    graph_hash = AWGN.graph_sha256(code)
    graph_hash == String(config["code"]["graph_sha256"]) ||
        throw(ArgumentError("graph hash differs before input freeze"))
    records = generate_input_records(config, code)
    reference_gate = input_reference_gate(config, records)
    reference_gate["passed"] || throw(ArgumentError("anchor input hashes differ from retained reference"))

    parent = dirname(output)
    isdir(parent) || mkpath(parent)
    mkdir(output)
    input_path = joinpath(output, "input_freeze.csv")
    write_csv(input_path, records)
    archived_hashes = archive_sources(joinpath(output, "source"), config)
    source_current = source_hashes(config)
    archive_matches = all(get(archived_hashes, name, "missing") == hash
                          for (name, hash) in source_current)
    manifest = Dict(
        "schema_version" => String(config["provenance"]["freeze_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "status" => "frozen",
        "input_table_sha256" => file_sha256(input_path),
        "input_count" => length(records),
        "anchor_count" => count(row -> row.split == "anchor", records),
        "heldout_count" => count(row -> row.split == "heldout", records),
        "heldout_decoders_executed" => false,
        "graph_sha256" => graph_hash,
        "source_hashes" => source_current,
        "archived_source_hashes" => archived_hashes,
        "archive_matches_current" => archive_matches,
        "source_gate" => source_validation,
        "anchor_reference_gate" => reference_gate,
        "provenance" => provenance_record(config, exact_command),
    )
    archive_matches || throw(ArgumentError("source archive differs from frozen sources"))
    write_toml(joinpath(output, "freeze_manifest.toml"), manifest)
    checksums = write_checksum_manifest(output)
    (;
        manifest,
        checksums,
        input_table_sha256=file_sha256(input_path),
        freeze_manifest_sha256=file_sha256(joinpath(output, "freeze_manifest.toml")),
    )
end

function records_by_key(rows)
    Dict((row["split"], parse(Int, row["frame"])) => row for row in rows)
end

function verify_freeze(config, freeze_directory::AbstractString)
    checksum_gate = verify_checksum_manifest(freeze_directory)
    manifest_path = joinpath(freeze_directory, "freeze_manifest.toml")
    input_path = joinpath(freeze_directory, "input_freeze.csv")
    if !isfile(manifest_path) || !isfile(input_path)
        return Dict("passed" => false, "reason" => "freeze artifacts missing",
                    "checksum_gate" => checksum_gate)
    end
    manifest = TOML.parsefile(manifest_path)
    current_hashes = source_hashes(config)
    frozen_hashes = Dict(String(key) => String(value)
                         for (key, value) in manifest["source_hashes"])
    source_checks = Dict(name => get(current_hashes, name, "missing") == hash
                         for (name, hash) in frozen_hashes)
    source_key_set_matches = Set(keys(current_hashes)) == Set(keys(frozen_hashes))
    archived_hashes = Dict(String(key) => String(value)
                           for (key, value) in manifest["archived_source_hashes"])
    archived_checks = Dict(name => begin
        path = joinpath(freeze_directory, "source", name)
        isfile(path) && !islink(path) && file_sha256(path) == hash
    end for (name, hash) in archived_hashes)
    archive_key_set_matches = Set(keys(archived_hashes)) == Set(keys(frozen_hashes))
    table_hash_matches = file_sha256(input_path) == String(manifest["input_table_sha256"])
    modem, code = AWGN.code_and_graph()
    regenerated = generate_input_records(config, code)
    temporary = tempname()
    write_csv(temporary, regenerated)
    regenerated_hash = file_sha256(temporary)
    rm(temporary)
    regeneration_matches = regenerated_hash == String(manifest["input_table_sha256"])
    graph_matches = AWGN.graph_sha256(code) == String(manifest["graph_sha256"])
    input_rows = parse_simple_csv(input_path)
    anchor_keys = Set(parse(Int, row["frame"]) for row in input_rows
                      if row["split"] == "anchor")
    heldout_keys = Set(parse(Int, row["frame"]) for row in input_rows
                       if row["split"] == "heldout")
    input_schema_checks = Dict(
        "row_count" => length(input_rows) ==
            Int(config["anchor"]["expected_count"]) +
            Int(config["heldout"]["expected_count"]),
        "anchor_keys" => anchor_keys == Set(Int(config["anchor"]["frame_first"]):
                                            Int(config["anchor"]["frame_last"])),
        "heldout_keys" => heldout_keys == Set(Int(config["heldout"]["frame_first"]):
                                              Int(config["heldout"]["frame_last"])),
    )
    manifest_checks = Dict(
        "schema" => manifest["schema_version"] ==
            String(config["provenance"]["freeze_schema"]),
        "experiment_id" => manifest["experiment_id"] == String(config["experiment_id"]),
        "status" => manifest["status"] == "frozen",
        "input_count" => Int(manifest["input_count"]) == length(input_rows),
        "anchor_count" => Int(manifest["anchor_count"]) ==
                          Int(config["anchor"]["expected_count"]),
        "heldout_count" => Int(manifest["heldout_count"]) ==
                           Int(config["heldout"]["expected_count"]),
        "archive_matches_current" => Bool(manifest["archive_matches_current"]),
        "source_gate_at_freeze" => Bool(manifest["source_gate"]["passed"]),
        "anchor_reference_at_freeze" => Bool(manifest["anchor_reference_gate"]["passed"]),
    )
    passed = checksum_gate["passed"] && all(values(source_checks)) &&
             source_key_set_matches && all(values(archived_checks)) &&
             archive_key_set_matches && all(values(input_schema_checks)) &&
             all(values(manifest_checks)) &&
             table_hash_matches && regeneration_matches && graph_matches &&
             manifest["heldout_decoders_executed"] == false
    Dict(
        "passed" => passed,
        "checksum_gate" => checksum_gate,
        "source_checks" => source_checks,
        "source_key_set_matches" => source_key_set_matches,
        "archived_source_checks" => archived_checks,
        "archive_key_set_matches" => archive_key_set_matches,
        "input_schema_checks" => input_schema_checks,
        "manifest_checks" => manifest_checks,
        "table_hash_matches" => table_hash_matches,
        "regeneration_matches" => regeneration_matches,
        "regenerated_table_sha256" => regenerated_hash,
        "graph_matches" => graph_matches,
        "heldout_decoders_executed" => manifest["heldout_decoders_executed"],
        "freeze_manifest_sha256" => file_sha256(manifest_path),
        "input_table_sha256" => file_sha256(input_path),
    )
end

function timed_kernel(graph, llr, mode, maximum_iterations)
    timed = @timed instrumented_decode(graph, llr; mode,
        maximum_iterations, stop_on_valid=true, capture_snapshots=false,
        record_trace=false)
    (result=timed.value, seconds=Float64(timed.time),
     allocated_bytes=Int(timed.bytes), gc_seconds=Float64(timed.gctime))
end

function timed_matches_trace(timed, traced)
    compare = compare_decodes(timed, traced; tolerance=0.0)
    compare["passed"] && timed.operation_counts == traced.operation_counts &&
        timed.logical_state == traced.logical_state &&
        timed.physical_state_bytes == traced.physical_state_bytes
end

function input_freeze_map(freeze_directory)
    rows = parse_simple_csv(joinpath(freeze_directory, "input_freeze.csv"))
    Dict((row["split"], parse(Int, row["frame"])) => row for row in rows)
end

function paired_endpoint_counts(frame_rows, field::Symbol)
    by_frame = Dict{Int,Dict{String,Bool}}()
    for row in frame_rows
        get!(by_frame, Int(row.frame), Dict{String,Bool}())[String(row.arm)] =
            Bool(getproperty(row, field))
    end
    n11 = n10 = n01 = n00 = 0
    for frame in sort!(collect(keys(by_frame)))
        pair = by_frame[frame]
        haskey(pair, "full") && haskey(pair, "tied") ||
            throw(ArgumentError("incomplete pair at frame $frame"))
        full = pair["full"]
        tied = pair["tied"]
        if full && tied
            n11 += 1
        elseif full && !tied
            n10 += 1
        elseif !full && tied
            n01 += 1
        else
            n00 += 1
        end
    end
    total = n11 + n10 + n01 + n00
    Dict(
        "n11_both_success" => n11,
        "n10_full_only_success" => n10,
        "n01_tied_only_success" => n01,
        "n00_both_failure" => n00,
        "pairs" => total,
        "full_successes" => n11 + n10,
        "tied_successes" => n11 + n01,
        "risk_difference_full_minus_tied" => total == 0 ? 0.0 : (n10 - n01) / total,
    )
end

function mcnemar_exact_pvalue(counts)
    b = Int(counts["n10_full_only_success"])
    c = Int(counts["n01_tied_only_success"])
    discordant = b + c
    discordant == 0 && return 1.0
    tail = min(b, c)
    probability = 0.0
    for k in 0:tail
        probability += Float64(binomial(big(discordant), k)) * 0.5^discordant
    end
    min(1.0, 2.0 * probability)
end

function inverse_normal_cdf(probability::Float64)
    0.0 < probability < 1.0 || throw(ArgumentError("probability must lie in (0,1)"))
    # Acklam's rational approximation.
    a = (-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2,
         1.383577518672690e2, -3.066479806614716e1, 2.506628277459239)
    b = (-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2,
         6.680131188771972e1, -1.328068155288572e1)
    c = (-7.784894002430293e-3, -3.223964580411365e-1,
         -2.400758277161838, -2.549732539343734,
          4.374664141464968, 2.938163982698783)
    d = (7.784695709041462e-3, 3.224671290700398e-1,
         2.445134137142996, 3.754408661907416)
    low = 0.02425
    high = 1.0 - low
    if probability < low
        q = sqrt(-2.0 * log(probability))
        return (((((c[1] * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) * q + c[6]) /
               ((((d[1] * q + d[2]) * q + d[3]) * q + d[4]) * q + 1.0)
    elseif probability <= high
        q = probability - 0.5
        r = q * q
        return (((((a[1] * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * r + a[6]) * q /
               (((((b[1] * r + b[2]) * r + b[3]) * r + b[4]) * r + b[5]) * r + 1.0)
    else
        q = sqrt(-2.0 * log(1.0 - probability))
        return -(((((c[1] * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) * q + c[6]) /
                ((((d[1] * q + d[2]) * q + d[3]) * q + d[4]) * q + 1.0)
    end
end

function wilson_interval(successes::Integer, total::Integer, z::Float64)
    total > 0 || return (0.0, 1.0)
    p = successes / total
    denominator = 1.0 + z^2 / total
    center = (p + z^2 / (2total)) / denominator
    radius = z / denominator * sqrt(p * (1.0 - p) / total + z^2 / (4total^2))
    (max(0.0, center - radius), min(1.0, center + radius))
end

"""Newcombe 1998 method 10 interval for the paired risk difference."""
function newcombe_paired_interval(counts; confidence_level::Float64=0.975)
    n11 = Int(counts["n11_both_success"])
    n10 = Int(counts["n10_full_only_success"])
    n01 = Int(counts["n01_tied_only_success"])
    n00 = Int(counts["n00_both_failure"])
    n = n11 + n10 + n01 + n00
    n > 0 || throw(ArgumentError("paired interval requires observations"))
    alpha = 1.0 - confidence_level
    z = inverse_normal_cdf(1.0 - alpha / 2.0)
    p1 = (n11 + n10) / n
    p2 = (n11 + n01) / n
    l1, u1 = wilson_interval(n11 + n10, n, z)
    l2, u2 = wilson_interval(n11 + n01, n, z)
    denominator = sqrt(p1 * (1.0 - p1) * p2 * (1.0 - p2))
    raw_cross_product = n11 * n00 - n10 * n01
    corrected_cross_product = raw_cross_product > 0 ?
        max(raw_cross_product - n / 2.0, 0.0) : raw_cross_product
    rho = denominator == 0.0 ? 0.0 :
        clamp((corrected_cross_product / n^2) / denominator, -1.0, 1.0)
    difference = p1 - p2
    lower_radius = sqrt(max(0.0, (p1 - l1)^2 + (u2 - p2)^2 -
                                      2rho * (p1 - l1) * (u2 - p2)))
    upper_radius = sqrt(max(0.0, (u1 - p1)^2 + (p2 - l2)^2 -
                                      2rho * (u1 - p1) * (p2 - l2)))
    Dict(
        "method" => "Newcombe 1998 score/Wilson method 10 for paired proportions with continuity-corrected correlation",
        "confidence_level" => confidence_level,
        "estimate" => difference,
        "lower" => max(-1.0, difference - lower_radius),
        "upper" => min(1.0, difference + upper_radius),
        "z" => z,
        "phi_correlation" => rho,
        "raw_cross_product" => raw_cross_product,
        "continuity_corrected_cross_product" => corrected_cross_product,
    )
end

function holm_adjust(pvalues::Dict{String,Float64})
    ordered = sort!(collect(pvalues); by=last)
    adjusted = Dict{String,Float64}()
    running = 0.0
    total = length(ordered)
    for (index, (name, value)) in enumerate(ordered)
        candidate = min(1.0, (total - index + 1) * value)
        running = max(running, candidate)
        adjusted[name] = running
    end
    adjusted
end

function phase_frames(config, phase::Symbol)
    section = phase === :anchor ? config["anchor"] :
              phase === :heldout ? config["heldout"] :
              throw(ArgumentError("phase must be anchor or heldout"))
    collect(Int(section["frame_first"]):Int(section["frame_last"]))
end

function arm_summary(frame, arm, result, word, order, input_record)
    hard_hash = AWGN.sha256_values(result.hard)
    q_hash = rows_sha256(result.q)
    u_hash = rows_sha256(result.u)
    qstar_hash = rows_sha256(result.qstar)
    qbar_hash = vector_sha256(result.qbar)
    delta_hash = rows_sha256(result.delta)
    coded_errors = count(result.hard .!= word)
    (;
        split=String(input_record.split),
        frame=Int(frame),
        arm=String(arm),
        execution_order=Int(order),
        noise_seed=Int(input_record.noise_seed),
        received_sha256=String(input_record.received_sha256),
        raw_llr_sha256=String(input_record.raw_llr_sha256),
        clipped_llr_sha256=String(input_record.clipped_llr_sha256),
        parity_valid=Bool(result.valid),
        transmitted_equal=Bool(result.hard == word),
        wrong_valid_word=Bool(result.valid && result.hard != word),
        coded_bit_errors=Int(coded_errors),
        syndrome_weight=Int(result.syndrome),
        stopping_iteration=Int(result.iterations),
        posterior_sha256=vector_sha256(result.lpost_metric),
        hard_word_sha256=hard_hash,
        terminal_q_sha256=q_hash,
        terminal_u_sha256=u_hash,
        terminal_qstar_sha256=qstar_hash,
        terminal_qbar_sha256=qbar_hash,
        terminal_delta_sha256=delta_hash,
        delta_nonzero=Bool(result.delta_nonzero),
        intervention_activated=Bool(result.intervention_activated),
        maximum_delta_zero_sum_error=Float64(result.maximum_delta_zero_sum_error),
        maximum_reconstruction_error=Float64(result.maximum_reconstruction_error),
        maximum_tied_spread=Float64(result.maximum_tied_spread),
        physical_state_bytes=Int(result.physical_state_bytes),
        logical_q_values=Int(result.logical_state["variable_to_check_independent_values"]),
        logical_u_values=Int(result.logical_state["check_to_variable_independent_values"]),
        check_updates=Int(result.operation_counts["check_updates"]),
        outgoing_check_messages=Int(result.operation_counts["outgoing_check_messages"]),
        check_limit_tanh_evaluations=Int(result.operation_counts["check_limit_tanh_evaluations"]),
        check_limit_half_scale_multiplications=Int(result.operation_counts["check_limit_half_scale_multiplications"]),
        check_half_input_scale_multiplications=Int(result.operation_counts["check_half_input_scale_multiplications"]),
        tanh_evaluations=Int(result.operation_counts["tanh_evaluations"]),
        check_product_multiplications=Int(result.operation_counts["check_product_multiplications"]),
        atanh_evaluations=Int(result.operation_counts["atanh_evaluations"]),
        check_input_clamps=Int(result.operation_counts["check_input_clamps"]),
        check_product_clamps=Int(result.operation_counts["check_product_clamps"]),
        check_output_scale_multiplications=Int(result.operation_counts["check_output_scale_multiplications"]),
        check_output_clamps=Int(result.operation_counts["check_output_clamps"]),
        variable_edge_additions=Int(result.operation_counts["variable_edge_additions"]),
        qstar_subtractions=Int(result.operation_counts["qstar_subtractions"]),
        qbar_accumulations=Int(result.operation_counts["qbar_accumulations"]),
        qbar_divisions=Int(result.operation_counts["qbar_divisions"]),
        delta_subtractions=Int(result.operation_counts["delta_subtractions"]),
        delta_zero_sum_accumulations=Int(result.operation_counts["delta_zero_sum_accumulations"]),
        reconstruction_additions=Int(result.operation_counts["reconstruction_additions"]),
        reconstruction_error_subtractions=Int(result.operation_counts["reconstruction_error_subtractions"]),
        retained_spread_minmax_comparisons=Int(result.operation_counts["retained_spread_minmax_comparisons"]),
        retained_spread_subtractions=Int(result.operation_counts["retained_spread_subtractions"]),
        retained_q_assignments=Int(result.operation_counts["retained_q_assignments"]),
        hard_decision_comparisons=Int(result.operation_counts["hard_decision_comparisons"]),
        initial_syndrome_xors=Int(result.operation_counts["initial_syndrome_xors"]),
        incremental_syndrome_parity_toggles=Int(result.operation_counts["incremental_syndrome_parity_toggles"]),
        independent_syndrome_xors=Int(result.operation_counts["independent_syndrome_xors"]),
    )
end

function iteration_rows(frame, arm, trace)
    [(;
        frame=Int(frame),
        arm=String(arm),
        iteration=Int(record["iteration"]),
        q_input_sha256=String(record["q_input_sha256"]),
        q_sha256=String(record["q_sha256"]),
        u_sha256=String(record["u_sha256"]),
        qstar_sha256=String(record["qstar_sha256"]),
        qbar_sha256=String(record["qbar_sha256"]),
        delta_sha256=String(record["delta_sha256"]),
        posterior_sha256=String(record["lpost_sha256"]),
        hard_word_sha256=String(record["hard_sha256"]),
        syndrome_weight=Int(record["syndrome_weight"]),
        independent_syndrome_weight=Int(record["independent_syndrome_weight"]),
        syndrome_consistent=Bool(record["syndrome_consistent"]),
        coded_bit_errors=Int(record["coded_bit_errors"]),
        maximum_absolute_delta=Float64(record["maximum_absolute_delta"]),
        rms_delta=Float64(record["rms_delta"]),
        delta_zero_sum_error=Float64(record["delta_zero_sum_error"]),
        reconstruction_error=Float64(record["reconstruction_error"]),
    ) for record in trace]
end

function frozen_input_gate(record, frozen_row)
    checks = Dict{String,Bool}()
    for property in propertynames(record)
        name = String(property)
        checks[name] = haskey(frozen_row, name) &&
                       frozen_row[name] == csv_value(getproperty(record, property))
    end
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function endpoint_statistics(frame_rows, field::Symbol, confidence_level::Float64)
    counts = paired_endpoint_counts(frame_rows, field)
    Dict(
        "counts" => counts,
        "mcnemar_exact_two_sided_pvalue" => mcnemar_exact_pvalue(counts),
        "newcombe_interval" => newcombe_paired_interval(
            counts; confidence_level=confidence_level),
    )
end

const WORK_FIELDS = (
    :check_updates,
    :outgoing_check_messages,
    :check_limit_tanh_evaluations,
    :check_limit_half_scale_multiplications,
    :check_half_input_scale_multiplications,
    :tanh_evaluations,
    :check_product_multiplications,
    :atanh_evaluations,
    :check_input_clamps,
    :check_product_clamps,
    :check_output_scale_multiplications,
    :check_output_clamps,
    :variable_edge_additions,
    :qstar_subtractions,
    :qbar_accumulations,
    :qbar_divisions,
    :delta_subtractions,
    :delta_zero_sum_accumulations,
    :reconstruction_additions,
    :reconstruction_error_subtractions,
    :retained_spread_minmax_comparisons,
    :retained_spread_subtractions,
    :retained_q_assignments,
    :hard_decision_comparisons,
    :initial_syndrome_xors,
    :incremental_syndrome_parity_toggles,
    :independent_syndrome_xors,
)

function categorical_work_totals(frame_rows, arm::AbstractString)
    rows = [row for row in frame_rows if row.arm == arm]
    Dict(String(field) => sum(Int(getproperty(row, field)) for row in rows)
         for field in WORK_FIELDS)
end

function invalid_phase_bundle(config, phase, reason; gates=Dict{String,Any}())
    science = Dict(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "phase" => String(phase),
        "status" => "invalid",
        "validation_passed" => false,
        "reason" => String(reason),
        "gates" => gates,
        "claim_boundary" =>
            "This is an exact-sum-product state ablation, not native BP-versus-projected-GD attribution.",
    )
    (; science, frame_rows=NamedTuple[], iteration_rows=NamedTuple[],
       runtime_rows=NamedTuple[], aggregate_rows=NamedTuple[],
       snapshots=Dict{String,Any}())
end

function graph_invariant_gate(config, modem, code)
    expected_n = Int(config["code"]["n"])
    expected_k = Int(config["code"]["k"])
    expected_variable_degree = Int(config["code"]["variable_degree"])
    expected_check_degree = Int(config["code"]["check_degree"])
    expected_checks = expected_n - expected_k
    expected_edges = expected_n * expected_variable_degree
    reconstructed = graph_view(code)
    inverse_matches = length(code.var_edges) == length(reconstructed.variable_edges) &&
        all(sort!(collect(code.var_edges[variable])) ==
            sort!(collect(reconstructed.variable_edges[variable]))
            for variable in 1:code.n)
    checks = Dict(
        "n" => code.n == expected_n,
        "k" => code.k == expected_k,
        "check_count" => length(code.check_vars) == expected_checks,
        "edge_count" => sum(length, code.check_vars) == expected_edges,
        "variable_degree" => all(length(edges) == expected_variable_degree
                                 for edges in code.var_edges),
        "check_degree" => all(length(members) == expected_check_degree
                              for members in code.check_vars),
        "no_duplicate_check_members" => all(length(unique(members)) == length(members)
                                            for members in code.check_vars),
        "no_isolated_variables" => all(edges -> !isempty(edges), code.var_edges),
        "inverse_edge_mapping" => inverse_matches,
        "graph_sha256" => AWGN.graph_sha256(code) ==
                          String(config["code"]["graph_sha256"]),
        "inner_pilot_ratio_zero" => modem.inner_pilot_ratio == 0.0,
        "native_iteration_cap" => modem.bp_iterations ==
                                  Int(config["decoder"]["maximum_message_passing_iterations"]),
        "generator_graph_seed" => AWGN.GRAPH_SEED == Int(config["code"]["graph_seed"]),
        "generator_noise_seed" => AWGN.NOISE_SEED ==
                                  Int(config["channel"]["noise_seed_base"]),
        "generator_n" => AWGN.N == expected_n,
        "generator_k" => AWGN.K == expected_k,
        "generator_degrees" => AWGN.VARIABLE_DEGREE == expected_variable_degree &&
                               AWGN.CHECK_DEGREE == expected_check_degree,
        "generator_esn0" => AWGN.ESN0_DB ==
                            Float64(config["channel"]["physical_esn0_db"]),
        "generator_llr_clip" => AWGN.LLR_CLIP ==
                                Float64(config["channel"]["llr_clip"]),
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "observed_sha256" => AWGN.graph_sha256(code),
        "expected_sha256" => String(config["code"]["graph_sha256"]),
        "n" => code.n,
        "k" => code.k,
        "checks_count" => length(code.check_vars),
        "edges" => sum(length, code.check_vars),
    )
end

function native_phase_preflight(config, modem, code, phase::Symbol)
    graph = graph_view(code)
    maximum_iterations = Int(config["decoder"]["maximum_message_passing_iterations"])
    frame_checks = Dict{String,Any}()
    passed = true
    for frame in phase_frames(config, phase)
        input = AWGN.paired_frame(code, frame;
            esn0_db=Float64(config["channel"]["physical_esn0_db"]))
        full = instrumented_decode(graph, input.llr; mode=:full,
            maximum_iterations, stop_on_valid=true,
            capture_snapshots=false, record_trace=false)
        native_result = native_decode(modem, code, input.llr)
        equivalence = endpoint_equivalence(full, native_result)
        frame_checks[@sprintf("frame_%05d", frame)] = equivalence
        passed &= equivalence["passed"]
    end
    Dict(
        "passed" => passed,
        "phase" => String(phase),
        "frame_count" => length(frame_checks),
        "required_state" => ["lch", "lpost", "bits", "check_parity", "Q", "U"],
        "bitwise_required" => true,
        "frames" => frame_checks,
    )
end

function calculate_phase(config, phase::Symbol;
                         freeze_directory::AbstractString)
    phase in (:anchor, :heldout) ||
        throw(ArgumentError("phase must be anchor or heldout"))
    source_validation = source_gate(config)
    freeze_validation = verify_freeze(config, freeze_directory)
    base_gates = Dict{String,Any}(
        "source" => source_validation,
        "freeze" => freeze_validation,
    )
    source_validation["passed"] ||
        return invalid_phase_bundle(config, phase, "source gate failed"; gates=base_gates)
    freeze_validation["passed"] ||
        return invalid_phase_bundle(config, phase, "input-freeze gate failed"; gates=base_gates)
    snapshot_environment = Dict(
        "passed" => gzip_version_line() ==
                    String(config["snapshots"]["gzip_version_line"]),
        "observed_gzip_version_line" => gzip_version_line(),
        "expected_gzip_version_line" =>
            String(config["snapshots"]["gzip_version_line"]),
        "format" => String(config["snapshots"]["format"]),
    )
    base_gates["snapshot_environment"] = snapshot_environment
    snapshot_environment["passed"] ||
        return invalid_phase_bundle(config, phase, "snapshot compressor gate failed";
                                    gates=base_gates)

    modem, code = AWGN.code_and_graph()
    graph = graph_view(code)
    graph_hash = AWGN.graph_sha256(code)
    graph_gate = graph_invariant_gate(config, modem, code)
    base_gates["graph"] = graph_gate
    graph_gate["passed"] ||
        return invalid_phase_bundle(config, phase, "graph gate failed"; gates=base_gates)

    warmup_frame = Int(config["timing"]["warmup_frame"])
    gate_input = AWGN.paired_frame(code, warmup_frame;
        esn0_db=Float64(config["channel"]["physical_esn0_db"]))
    clamped_channel = copy(gate_input.llr)
    CORE._apply_inner_clamps!(modem, code, clamped_channel, code.k)
    inner_clamp_gate = Dict(
        "passed" => float_bits_equal(clamped_channel, gate_input.llr),
        "inner_pilot_ratio" => modem.inner_pilot_ratio,
        "channel_llr_unchanged_bitwise" =>
            float_bits_equal(clamped_channel, gate_input.llr),
    )
    base_gates["inner_pilot_clamp_noop"] = inner_clamp_gate
    inner_clamp_gate["passed"] ||
        return invalid_phase_bundle(config, phase, "inner-pilot clamp gate failed";
                                    gates=base_gates)
    pre = prerun_gates(config, modem, code, gate_input)
    base_gates["pre_run"] = pre.summary
    pre.summary["passed"] ||
        return invalid_phase_bundle(config, phase, "pre-run correctness gate failed";
                                    gates=base_gates)

    native_preflight = native_phase_preflight(config, modem, code, phase)
    base_gates["native_full_state_preflight"] = native_preflight
    native_preflight["passed"] ||
        return invalid_phase_bundle(config, phase,
            "native/full state preflight failed before the paired intervention";
            gates=base_gates)

    maximum_iterations = Int(config["decoder"]["maximum_message_passing_iterations"])
    for mode in (:full, :tied)
        for _ in 1:Int(config["timing"]["warmup_repetitions_per_arm"])
            instrumented_decode(graph, gate_input.llr; mode,
                maximum_iterations, stop_on_valid=true,
                capture_snapshots=false, record_trace=false)
        end
    end

    frozen = input_freeze_map(freeze_directory)
    frame_rows = NamedTuple[]
    all_iteration_rows = NamedTuple[]
    runtime_rows = NamedTuple[]
    snapshots = Dict{String,Any}()
    per_frame_gates = Dict{String,Any}()
    native_equivalence_count = 0
    all_input_frozen = true
    all_iteration_one = true
    all_syndrome = true
    all_timing_matches = true
    all_physical_equal = true
    all_diagnostic_invariants = true

    frames = phase_frames(config, phase)
    split_name = String(phase)
    for frame in frames
        input = AWGN.paired_frame(code, frame;
            esn0_db=Float64(config["channel"]["physical_esn0_db"]))
        record = input_record(config, code, frame, split_name)
        frozen_key = (split_name, frame)
        input_gate = haskey(frozen, frozen_key) ?
            frozen_input_gate(record, frozen[frozen_key]) :
            Dict("passed" => false, "reason" => "frozen input key missing")

        capture = frame == first(frames)
        full = instrumented_decode(graph, input.llr; mode=:full,
            maximum_iterations, stop_on_valid=true,
            capture_snapshots=capture, record_trace=true)
        tied = instrumented_decode(graph, input.llr; mode=:tied,
            maximum_iterations, stop_on_valid=true,
            capture_snapshots=capture, record_trace=true)
        native_result = native_decode(modem, code, input.llr)
        native_gate = endpoint_equivalence(full, native_result)
        iteration_one = first_iteration_gate(full, tied)
        syndrome_gate = Dict(
            "passed" => full.syndrome_consistency && tied.syndrome_consistency &&
                        all(Bool(row["syndrome_consistent"]) for row in full.trace) &&
                        all(Bool(row["syndrome_consistent"]) for row in tied.trace),
            "full" => full.syndrome_consistency,
            "tied" => tied.syndrome_consistency,
        )
        physical_gate = Dict(
            "passed" => full.physical_state_bytes == tied.physical_state_bytes,
            "full_bytes" => full.physical_state_bytes,
            "tied_bytes" => tied.physical_state_bytes,
        )
        diagnostic_gate = Dict(
            "passed" => !full.intervention_activated && tied.intervention_activated &&
                        full.delta_nonzero && tied.delta_nonzero &&
                        tied.maximum_tied_spread == 0.0 &&
                        full.maximum_delta_zero_sum_error <=
                            Float64(config["validation"]["delta_zero_sum_tolerance"]) &&
                        tied.maximum_delta_zero_sum_error <=
                            Float64(config["validation"]["delta_zero_sum_tolerance"]),
            "full_intervention_activated" => full.intervention_activated,
            "tied_intervention_activated" => tied.intervention_activated,
            "full_delta_nonzero" => full.delta_nonzero,
            "tied_delta_nonzero" => tied.delta_nonzero,
            "tied_maximum_spread" => tied.maximum_tied_spread,
            "full_delta_zero_sum_error" => full.maximum_delta_zero_sum_error,
            "tied_delta_zero_sum_error" => tied.maximum_delta_zero_sum_error,
        )

        timed = Dict{Symbol,Any}()
        order = isodd(frame) ? (:full, :tied) : (:tied, :full)
        for mode in order
            timed[mode] = timed_kernel(graph, input.llr, mode, maximum_iterations)
        end
        timing_gate = Dict(
            "passed" => timed_matches_trace(timed[:full].result, full) &&
                        timed_matches_trace(timed[:tied].result, tied),
            "full_matches_trace" => timed_matches_trace(timed[:full].result, full),
            "tied_matches_trace" => timed_matches_trace(timed[:tied].result, tied),
        )

        append!(frame_rows, (
            arm_summary(frame, "full", full, input.word,
                        findfirst(==(:full), order), record),
            arm_summary(frame, "tied", tied, input.word,
                        findfirst(==(:tied), order), record),
        ))
        append!(all_iteration_rows, iteration_rows(frame, "full", full.trace))
        append!(all_iteration_rows, iteration_rows(frame, "tied", tied.trace))
        for (position, mode) in enumerate(order)
            measured = timed[mode]
            push!(runtime_rows, (;
                split=split_name,
                frame,
                arm=String(mode),
                execution_order=position,
                seconds=measured.seconds,
                allocated_bytes=measured.allocated_bytes,
                gc_seconds=measured.gc_seconds,
                native_validation_seconds=mode === :full ? native_result.seconds : 0.0,
                native_validation_allocated_bytes=
                    mode === :full ? native_result.allocated_bytes : 0,
            ))
        end
        if capture
            snapshots["full"] = full.snapshots
            snapshots["tied"] = tied.snapshots
        end

        native_equivalence_count += native_gate["passed"] ? 1 : 0
        all_input_frozen &= input_gate["passed"]
        all_iteration_one &= iteration_one["passed"]
        all_syndrome &= syndrome_gate["passed"]
        all_timing_matches &= timing_gate["passed"]
        all_physical_equal &= physical_gate["passed"]
        all_diagnostic_invariants &= diagnostic_gate["passed"]
        per_frame_gates[@sprintf("frame_%05d", frame)] = Dict(
            "input_freeze" => input_gate,
            "native_full_state_equivalence" => native_gate,
            "iteration_one" => iteration_one,
            "independent_syndrome" => syndrome_gate,
            "physical_state_storage" => physical_gate,
            "diagnostic_invariants" => diagnostic_gate,
            "timed_kernel_matches_trace" => timing_gate,
        )
    end

    confidence_level = Float64(config["heldout"]["newcombe_confidence_level"])
    endpoint_results = Dict(
        "parity_valid" => endpoint_statistics(frame_rows, :parity_valid,
                                                confidence_level),
        "transmitted_equal" => endpoint_statistics(frame_rows, :transmitted_equal,
                                                     confidence_level),
    )
    raw_pvalues = Dict(name => Float64(result["mcnemar_exact_two_sided_pvalue"])
                       for (name, result) in endpoint_results)
    adjusted = holm_adjust(raw_pvalues)
    for (name, value) in adjusted
        endpoint_results[name]["holm_adjusted_pvalue"] = value
        interval = endpoint_results[name]["newcombe_interval"]
        endpoint_results[name]["directional_claim_passed"] =
            phase === :heldout && interval["estimate"] > 0.0 &&
            interval["lower"] > 0.0 &&
            value < Float64(config["heldout"]["familywise_alpha"])
    end

    aggregate_rows = NamedTuple[]
    for endpoint in ("parity_valid", "transmitted_equal")
        result = endpoint_results[endpoint]
        counts = result["counts"]
        interval = result["newcombe_interval"]
        push!(aggregate_rows, (;
            split=split_name,
            endpoint,
            pairs=Int(counts["pairs"]),
            both_success=Int(counts["n11_both_success"]),
            full_only_success=Int(counts["n10_full_only_success"]),
            tied_only_success=Int(counts["n01_tied_only_success"]),
            both_failure=Int(counts["n00_both_failure"]),
            risk_difference_full_minus_tied=Float64(counts["risk_difference_full_minus_tied"]),
            interval_confidence_level=Float64(interval["confidence_level"]),
            interval_lower=Float64(interval["lower"]),
            interval_upper=Float64(interval["upper"]),
            mcnemar_exact_two_sided_pvalue=
                Float64(result["mcnemar_exact_two_sided_pvalue"]),
            holm_adjusted_pvalue=Float64(result["holm_adjusted_pvalue"]),
        ))
    end

    full_rows = [row for row in frame_rows if row.arm == "full"]
    tied_rows = [row for row in frame_rows if row.arm == "tied"]
    correctness_checks = Dict(
        "source" => source_validation["passed"],
        "freeze" => freeze_validation["passed"],
        "graph" => graph_gate["passed"],
        "pre_run" => pre.summary["passed"],
        "all_input_identities_frozen" => all_input_frozen,
        "native_full_state_equivalence_all_frames" =>
            native_equivalence_count == length(frames),
        "iteration_one_control_all_frames" => all_iteration_one,
        "independent_syndrome_all_iterations" => all_syndrome,
        "trace_free_kernel_matches_traced_kernel" => all_timing_matches,
        "physical_state_storage_equal_all_frames" => all_physical_equal,
        "diagnostic_invariants_all_frames" => all_diagnostic_invariants,
    )
    validation_passed = all(values(correctness_checks))

    parity_counts = endpoint_results["parity_valid"]["counts"]
    transmitted_counts = endpoint_results["transmitted_equal"]["counts"]
    discordant_and_full_favored = any(
        Int(counts["n10_full_only_success"]) >
        Int(counts["n01_tied_only_success"])
        for counts in (parity_counts, transmitted_counts))
    anchor_checks = Dict(
        "all_correctness_and_provenance" => validation_passed,
        "native_full_exact_count" => native_equivalence_count ==
            Int(config["anchor"]["require_full_exact_count"]),
        "full_parity_valid_count" => count(row -> row.parity_valid, full_rows) ==
            Int(config["anchor"]["require_full_valid_count"]),
        "full_transmitted_equal_count" => count(row -> row.transmitted_equal, full_rows) ==
            Int(config["anchor"]["require_full_valid_count"]),
        "at_least_one_endpoint_discordant_and_net_favors_full" =>
            discordant_and_full_favored,
    )
    anchor_gate = Dict(
        "applicable" => phase === :anchor,
        "passed" => phase === :anchor ? all(values(anchor_checks)) : false,
        "checks" => anchor_checks,
    )

    science = Dict(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "phase" => split_name,
        "status" => validation_passed ? "valid" : "invalid",
        "validation_passed" => validation_passed,
        "claim_boundary" =>
            "This exact-sum-product state ablation does not by itself attribute the native BP-versus-projected-GD performance difference.",
        "intervention" => Dict(
            "full" => "retain recipient-specific Qstar on each variable-to-check edge",
            "tied" => "retain qbar in every variable-to-check edge slot",
            "activation" => "first post-check variable update; first check effect at message-passing iteration 2",
            "check_to_variable_state" => "recipient-specific in both arms",
        ),
        "graph_sha256" => graph_hash,
        "frame_count" => length(frames),
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "gates" => merge(base_gates, Dict(
            "correctness_checks" => correctness_checks,
            "per_frame" => per_frame_gates,
        )),
        "endpoints" => endpoint_results,
        "anchor_expansion_gate" => anchor_gate,
        "categorical_work" => Dict(
            "full" => categorical_work_totals(frame_rows, "full"),
            "tied" => categorical_work_totals(frame_rows, "tied"),
            "rule" => "categories are not collapsed into one scalar",
            "groups" => Dict(
                "native_exact_check_kernel" => [
                    "check_updates", "outgoing_check_messages",
                    "check_limit_tanh_evaluations",
                    "check_limit_half_scale_multiplications",
                    "check_half_input_scale_multiplications",
                    "check_input_clamps", "tanh_evaluations",
                    "check_product_multiplications", "check_product_clamps",
                    "atanh_evaluations", "check_output_scale_multiplications",
                    "check_output_clamps",
                ],
                "native_variable_and_stopping" => [
                    "variable_edge_additions", "qstar_subtractions",
                    "retained_q_assignments", "hard_decision_comparisons",
                    "initial_syndrome_xors",
                    "incremental_syndrome_parity_toggles",
                ],
                "ablation_diagnostics" => [
                    "qbar_accumulations", "qbar_divisions",
                    "delta_subtractions", "delta_zero_sum_accumulations",
                    "reconstruction_additions",
                    "reconstruction_error_subtractions",
                    "retained_spread_minmax_comparisons",
                    "retained_spread_subtractions",
                    "independent_syndrome_xors",
                ],
                "excluded" => ["trace hashing", "serialization", "input generation"],
            ),
        ),
        "memory" => Dict(
            "physical_measure_definition" =>
                "Base.summarysize heap-reachability estimate; not peak memory or measured allocation",
            "full_physical_state_bytes" => unique(row.physical_state_bytes for row in full_rows),
            "tied_physical_state_bytes" => unique(row.physical_state_bytes for row in tied_rows),
            "full_logical_q_values" => unique(row.logical_q_values for row in full_rows),
            "tied_logical_q_values" => unique(row.logical_q_values for row in tied_rows),
            "full_logical_state_definition" => pre.full.logical_state,
            "tied_logical_state_definition" => pre.tied.logical_state,
            "physical_edge_slots_equal" => all_physical_equal,
        ),
        "frame_table_sha256" => scientific_sha256(frame_rows),
        "iteration_table_sha256" => scientific_sha256(all_iteration_rows),
        "aggregate_table_sha256" => scientific_sha256(aggregate_rows),
        "snapshot_scientific_sha256" => scientific_sha256(snapshots),
        "runtime_scope" => String(config["timing"]["replay_scope"]),
        "inference_status" => phase === :heldout ?
            "registered held-out inference" : "descriptive anchor only; not pooled with held-out inference",
    )
    (; science, frame_rows, iteration_rows=all_iteration_rows,
       runtime_rows, aggregate_rows, snapshots)
end

function write_snapshot_archive(path::AbstractString, snapshots, graph::GraphView)
    endswith(path, ".gz") || throw(ArgumentError("snapshot archive must end in .gz"))
    ispath(path) && throw(ArgumentError("refusing to overwrite snapshot archive: $path"))
    gzip_version_line() == "gzip 1.10" ||
        throw(ArgumentError("snapshot compressor version differs from the frozen format"))
    raw = path[1:end-3]
    ispath(raw) && throw(ArgumentError("refusing to overwrite snapshot table: $raw"))
    columns = (
        "arm", "iteration", "check", "slot", "variable",
        "q", "q_hex", "u", "u_hex", "qstar", "qstar_hex",
        "qbar", "qbar_hex", "delta", "delta_hex", "lpost",
        "lpost_hex", "hard_bit", "syndrome_weight",
    )
    open(raw, "w") do io
        println(io, join(columns, ','))
        for arm in sort!(collect(keys(snapshots)))
            arm_snapshots = snapshots[arm]
            for iteration in sort!(collect(keys(arm_snapshots)))
                snapshot = arm_snapshots[iteration]
                for (check_index, members) in enumerate(snapshot.checks)
                    for (slot, variable) in enumerate(members)
                        q = snapshot.q[check_index][slot]
                        u = snapshot.u[check_index][slot]
                        qstar = snapshot.qstar[check_index][slot]
                        qbar = snapshot.qbar[variable]
                        delta = snapshot.delta[check_index][slot]
                        lpost = snapshot.lpost[variable]
                        values = (
                            arm, iteration, check_index, slot, variable,
                            csv_value(q), float_hex(q),
                            csv_value(u), float_hex(u),
                            csv_value(qstar), float_hex(qstar),
                            csv_value(qbar), float_hex(qbar),
                            csv_value(delta), float_hex(delta),
                            csv_value(lpost), float_hex(lpost),
                            csv_value(snapshot.bits[variable]), snapshot.syndrome,
                        )
                        println(io, join(values, ','))
                    end
                end
            end
        end
    end
    try
        run(Cmd(["gzip", "-n", raw]))
    catch
        isfile(raw) || rethrow()
        rethrow()
    end
    isfile(path) || throw(ArgumentError("gzip did not create the snapshot archive"))
    path
end

function copy_tree_new(source::AbstractString, destination::AbstractString)
    isdir(source) || throw(ArgumentError("source tree does not exist: $source"))
    ispath(destination) && throw(ArgumentError("destination tree exists: $destination"))
    mkdir(destination)
    for (directory, subdirectories, files) in walkdir(source)
        relative_directory = relpath(directory, source)
        target_directory = relative_directory == "." ? destination :
                           joinpath(destination, relative_directory)
        for subdirectory in subdirectories
            source_path = joinpath(directory, subdirectory)
            islink(source_path) && throw(ArgumentError("symlink forbidden in retained tree"))
            mkdir(joinpath(target_directory, subdirectory))
        end
        for file in files
            source_path = joinpath(directory, file)
            islink(source_path) && throw(ArgumentError("symlink forbidden in retained tree"))
            write_new_file(joinpath(target_directory, file), read(source_path, String))
        end
    end
    destination
end

function write_phase_result(output::AbstractString, bundle, config,
                            freeze_directory::AbstractString,
                            exact_command::AbstractString,
                            deterministic_replay::Dict{String,Any})
    isdir(output) || throw(ArgumentError("result directory must already exist"))
    isempty(readdir(output)) || throw(ArgumentError("result directory is not empty"))
    science = bundle.science
    science["deterministic_replay"] = deterministic_replay
    science_path = joinpath(output, "science.json")
    write_new_file(science_path, canonical_json(science) * "\n")
    if !isempty(bundle.frame_rows)
        write_csv(joinpath(output, "frames.csv"), bundle.frame_rows)
        write_csv(joinpath(output, "iterations.csv"), bundle.iteration_rows)
        write_csv(joinpath(output, "aggregate.csv"), bundle.aggregate_rows)
        write_csv(joinpath(output, "runtime.csv"), bundle.runtime_rows)
        modem, code = AWGN.code_and_graph()
        write_snapshot_archive(joinpath(output, "frame_first_state_snapshots.csv.gz"),
                               bundle.snapshots, graph_view(code))
    end
    archived_source_hashes = archive_sources(joinpath(output, "source"), config)
    copy_tree_new(freeze_directory, joinpath(output, "freeze"))

    provenance = provenance_record(config, exact_command)
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "phase" => String(science["phase"]),
        "status" => String(science["status"]),
        "validation_passed" => Bool(science["validation_passed"]),
        "anchor_expansion_passed" =>
            get(get(science, "anchor_expansion_gate", Dict{String,Any}()),
                "passed", false),
        "science_file_sha256" => file_sha256(science_path),
        "base_scientific_sha256" => String(deterministic_replay["first_sha256"]),
        "deterministic_replay_passed" => Bool(deterministic_replay["passed"]),
        "runtime_in_scientific_replay" => false,
        "snapshot_format" => String(config["snapshots"]["format"]),
        "snapshot_compressor" => String(config["snapshots"]["compressor"]),
        "archived_source_hashes" => archived_source_hashes,
        "freeze_manifest_sha256" =>
            file_sha256(joinpath(output, "freeze", "freeze_manifest.toml")),
        "input_freeze_sha256" =>
            file_sha256(joinpath(output, "freeze", "input_freeze.csv")),
        "provenance" => provenance,
    )
    haskey(science, "anchor_handoff") &&
        (manifest["anchor_handoff"] = science["anchor_handoff"])
    manifest_path = joinpath(output, "manifest.toml")
    write_toml(manifest_path, manifest)
    completion = Dict(
        "schema_version" => "bpgd-rq2-qbar-awgn-001/completion-v1",
        "experiment_id" => String(config["experiment_id"]),
        "phase" => String(science["phase"]),
        "status" => String(science["status"]),
        "validation_passed" => Bool(science["validation_passed"]),
        "anchor_expansion_passed" => Bool(manifest["anchor_expansion_passed"]),
        "manifest_sha256" => file_sha256(manifest_path),
        "science_file_sha256" => file_sha256(science_path),
        "base_scientific_sha256" => String(deterministic_replay["first_sha256"]),
        "freeze_manifest_sha256" => String(manifest["freeze_manifest_sha256"]),
        "input_freeze_sha256" => String(manifest["input_freeze_sha256"]),
    )
    completion_path = joinpath(output, "COMPLETED.toml")
    write_toml(completion_path, completion)
    checksums = write_checksum_manifest(output)
    (; manifest, completion, checksums,
       completion_sha256=file_sha256(completion_path))
end

function validate_anchor_handoff(anchor_result::AbstractString,
                                 freeze_directory::AbstractString)
    checksum = verify_checksum_manifest(anchor_result)
    manifest_path = joinpath(anchor_result, "manifest.toml")
    completion_path = joinpath(anchor_result, "COMPLETED.toml")
    science_path = joinpath(anchor_result, "science.json")
    if !checksum["passed"] || !isfile(manifest_path) ||
       !isfile(completion_path) || !isfile(science_path)
        return Dict("passed" => false, "reason" => "anchor artifacts missing or corrupt",
                    "checksum_gate" => checksum)
    end
    manifest = TOML.parsefile(manifest_path)
    completion = TOML.parsefile(completion_path)
    freeze_manifest_hash = file_sha256(joinpath(freeze_directory, "freeze_manifest.toml"))
    input_freeze_hash = file_sha256(joinpath(freeze_directory, "input_freeze.csv"))
    checks = Dict(
        "manifest_schema" => manifest["schema_version"] ==
            "bpgd-rq2-qbar-awgn-001/manifest-v1",
        "completion_schema" => completion["schema_version"] ==
            "bpgd-rq2-qbar-awgn-001/completion-v1",
        "experiment_id" => manifest["experiment_id"] ==
            "BPGD-RQ2-QBAR-AWGN-001" && completion["experiment_id"] ==
            "BPGD-RQ2-QBAR-AWGN-001",
        "anchor_phase" => manifest["phase"] == "anchor" && completion["phase"] == "anchor",
        "status_valid" => manifest["status"] == "valid" && completion["status"] == "valid",
        "validation_passed" => manifest["validation_passed"] &&
                               completion["validation_passed"],
        "expansion_passed" => manifest["anchor_expansion_passed"] &&
                              completion["anchor_expansion_passed"],
        "deterministic_replay_passed" => manifest["deterministic_replay_passed"],
        "manifest_bound" => completion["manifest_sha256"] == file_sha256(manifest_path),
        "science_bound" => completion["science_file_sha256"] == file_sha256(science_path),
        "same_freeze_manifest" => completion["freeze_manifest_sha256"] == freeze_manifest_hash,
        "same_input_freeze" => completion["input_freeze_sha256"] == input_freeze_hash,
    )
    independent_replay = all(values(checks)) ? replay_result(anchor_result) :
        Dict("passed" => false, "reason" => "anchor metadata gate failed before replay")
    checks["independent_anchor_replay"] = independent_replay["passed"]
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "checksum_gate" => checksum,
        "independent_replay" => independent_replay,
        "completion_sha256" => file_sha256(completion_path),
    )
end

function run_phase(phase::Symbol; config_path::AbstractString=DEFAULT_CONFIG,
                   freeze_directory::AbstractString,
                   output::AbstractString,
                   anchor_result::Union{Nothing,AbstractString}=nothing,
                   exact_command::AbstractString="run phase")
    ispath(output) && throw(ArgumentError("output directory already exists: $output"))
    require_registered_config(config_path)
    config = load_config(config_path)
    LinearAlgebra.BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))
    parent = dirname(output)
    isdir(parent) || mkpath(parent)
    mkdir(output)

    handoff = nothing
    if phase === :heldout
        anchor_result === nothing &&
            return begin
                invalid = invalid_phase_bundle(config, phase,
                    "held-out execution requires a cryptographically valid anchor handoff")
                replay = Dict{String,Any}(
                    "first_sha256" => scientific_sha256(invalid.science),
                    "second_sha256" => "not_run",
                    "passed" => false,
                )
                written = write_phase_result(output, invalid, config, freeze_directory,
                                             exact_command, replay)
                (; bundle=invalid, written)
            end
        handoff = validate_anchor_handoff(anchor_result, freeze_directory)
        if !handoff["passed"]
            invalid = invalid_phase_bundle(config, phase,
                "anchor handoff validation failed"; gates=Dict("anchor_handoff" => handoff))
            replay = Dict{String,Any}(
                "first_sha256" => scientific_sha256(invalid.science),
                "second_sha256" => "not_run",
                "passed" => false,
            )
            written = write_phase_result(output, invalid, config, freeze_directory,
                                         exact_command, replay)
            return (; bundle=invalid, written)
        end
    elseif phase !== :anchor
        throw(ArgumentError("phase must be anchor or heldout"))
    end

    first_bundle = try
        calculate_phase(config, phase; freeze_directory)
    catch error
        invalid_phase_bundle(config, phase,
            "phase execution error: " * sprint(showerror, error))
    end
    phase === :heldout && (first_bundle.science["anchor_handoff"] = handoff)
    first_hash = scientific_sha256(first_bundle.science)
    second_bundle = if first_bundle.science["validation_passed"]
        try
            calculate_phase(config, phase; freeze_directory)
        catch error
            invalid_phase_bundle(config, phase,
                "independent replay error: " * sprint(showerror, error))
        end
    else
        invalid_phase_bundle(config, phase, "independent replay not run after invalid first pass")
    end
    phase === :heldout && (second_bundle.science["anchor_handoff"] = handoff)
    second_hash = scientific_sha256(second_bundle.science)
    replay_passed = first_bundle.science["validation_passed"] &&
                    first_hash == second_hash
    replay = Dict{String,Any}(
        "first_sha256" => first_hash,
        "second_sha256" => second_hash,
        "passed" => replay_passed,
        "scope" => String(config["timing"]["replay_scope"]),
    )
    replay_passed || begin
        first_bundle.science["validation_passed"] = false
        first_bundle.science["status"] = "invalid"
        if haskey(first_bundle.science, "anchor_expansion_gate")
            first_bundle.science["anchor_expansion_gate"]["passed"] = false
        end
    end
    written = write_phase_result(output, first_bundle, config, freeze_directory,
                                 exact_command, replay)
    (; bundle=first_bundle, written)
end

function replay_result(result_directory::AbstractString)
    checksum = verify_checksum_manifest(result_directory)
    checksum["passed"] || return Dict("passed" => false, "checksum_gate" => checksum)
    manifest = TOML.parsefile(joinpath(result_directory, "manifest.toml"))
    completion = TOML.parsefile(joinpath(result_directory, "COMPLETED.toml"))
    config = load_config(DEFAULT_CONFIG)
    LinearAlgebra.BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))
    phase = Symbol(manifest["phase"])
    calculated = calculate_phase(config, phase;
        freeze_directory=joinpath(result_directory, "freeze"))
    phase === :heldout && haskey(manifest, "anchor_handoff") &&
        (calculated.science["anchor_handoff"] = manifest["anchor_handoff"])
    calculated_hash = scientific_sha256(calculated.science)
    expected_hash = String(manifest["base_scientific_sha256"])
    science_file = read(joinpath(result_directory, "science.json"), String)
    table_checks = Dict{String,Bool}()
    if !isempty(calculated.frame_rows)
        table_checks["frames.csv"] = file_sha256(joinpath(result_directory, "frames.csv")) ==
            text_sha256(csv_text(calculated.frame_rows))
        table_checks["iterations.csv"] = file_sha256(joinpath(result_directory, "iterations.csv")) ==
            text_sha256(csv_text(calculated.iteration_rows))
        table_checks["aggregate.csv"] = file_sha256(joinpath(result_directory, "aggregate.csv")) ==
            text_sha256(csv_text(calculated.aggregate_rows))
    end
    checks = Dict(
        "scientific_hash" => calculated_hash == expected_hash,
        "completion_manifest_binding" => completion["manifest_sha256"] ==
            file_sha256(joinpath(result_directory, "manifest.toml")),
        "completion_science_binding" => completion["science_file_sha256"] ==
            file_sha256(joinpath(result_directory, "science.json")),
        "completion_base_hash" => completion["base_scientific_sha256"] == expected_hash,
        "retained_science_nonempty" => !isempty(strip(science_file)),
        "tables" => all(values(table_checks)),
        "current_source_gate" => source_gate(config)["passed"],
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "table_checks" => table_checks,
        "checksum_gate" => checksum,
        "calculated_base_scientific_sha256" => calculated_hash,
        "expected_base_scientific_sha256" => expected_hash,
    )
end

function run_freeze(; config_path::AbstractString=DEFAULT_CONFIG,
                    output::AbstractString,
                    exact_command::AbstractString="freeze")
    freeze_inputs(; config_path, output, exact_command)
end

function parse_cli(arguments)
    isempty(arguments) && return (; help=true)
    command = Symbol(first(arguments))
    command in (:freeze, :anchor, :heldout, :replay) ||
        throw(ArgumentError("unknown command: $(first(arguments))"))
    values = Dict{String,String}()
    index = 2
    while index <= length(arguments)
        argument = arguments[index]
        argument in ("--config", "--output", "--freeze", "--anchor-result", "--result") ||
            throw(ArgumentError("unknown argument: $argument"))
        index += 1
        index <= length(arguments) || throw(ArgumentError("$argument requires a value"))
        values[argument] = arguments[index]
        index += 1
    end
    (; help=false, command, values)
end

function main(arguments=ARGS)
    parsed = parse_cli(arguments)
    if parsed.help
        println("usage:")
        println("  julia --project=/home/gabiel/Documents/GitHub/JadeJcade rq2_qbar_awgn_001.jl freeze --output DIR")
        println("  julia --project=/home/gabiel/Documents/GitHub/JadeJcade rq2_qbar_awgn_001.jl anchor --freeze DIR --output DIR")
        println("  julia --project=/home/gabiel/Documents/GitHub/JadeJcade rq2_qbar_awgn_001.jl heldout --freeze DIR --anchor-result DIR --output DIR")
        println("  julia --project=/home/gabiel/Documents/GitHub/JadeJcade rq2_qbar_awgn_001.jl replay --result DIR")
        return 0
    end
    values = parsed.values
    config_path = get(values, "--config", DEFAULT_CONFIG)
    exact_command = join(["julia", "--project=/home/gabiel/Documents/GitHub/JadeJcade",
                          abspath(RUNNER_PATH), arguments...], " ")
    if parsed.command === :freeze
        haskey(values, "--output") || throw(ArgumentError("--output is required"))
        frozen = run_freeze(; config_path, output=values["--output"], exact_command)
        println("input freeze valid: ", frozen.manifest["status"] == "frozen")
        println("input table SHA-256: ", frozen.input_table_sha256)
        return 0
    elseif parsed.command in (:anchor, :heldout)
        haskey(values, "--freeze") || throw(ArgumentError("--freeze is required"))
        haskey(values, "--output") || throw(ArgumentError("--output is required"))
        result = run_phase(parsed.command; config_path,
            freeze_directory=values["--freeze"], output=values["--output"],
            anchor_result=get(values, "--anchor-result", nothing), exact_command)
        science = result.bundle.science
        println("phase status: ", science["status"])
        println("validation passed: ", science["validation_passed"])
        println("completion SHA-256: ", result.written.completion_sha256)
        if parsed.command === :anchor
            expansion = get(get(science, "anchor_expansion_gate", Dict()), "passed", false)
            println("anchor expansion passed: ", expansion)
            return science["validation_passed"] ? (expansion ? 0 : 2) : 1
        end
        return science["validation_passed"] ? 0 : 1
    else
        haskey(values, "--result") || throw(ArgumentError("--result is required"))
        replay = replay_result(values["--result"])
        println("replay passed: ", replay["passed"])
        return replay["passed"] ? 0 : 1
    end
end

end # module RQ2QbarAWGN001

if abspath(PROGRAM_FILE) == @__FILE__
    exit(RQ2QbarAWGN001.main())
end




