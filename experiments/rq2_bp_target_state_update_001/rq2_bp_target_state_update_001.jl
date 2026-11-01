#!/usr/bin/env julia

module RQ2BPTargetStateUpdate001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using TOML

const CORE = JadeJcade.ReceiverCore
const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const TEST_PATH = joinpath(HERE, "test_rq2_bp_target_state_update_001.jl")

const ARMS = (
    "full__direct",
    "qbar_tied__direct",
    "full__residual_gradient",
    "qbar_tied__residual_gradient",
)
const STATE_MAPS = (:full, :qbar_tied)
const OPERATORS = (:direct, :residual_gradient)
const LLR_CLIP = 20.0
const CAMPAIGN_EXPERIMENT_ID = "RQ2-CAUSAL-FACTORS-001"
const CAMPAIGN_COMPLETION_SCHEMA =
    "rq2-causal-factors-001/result-completion-v1"
const CAMPAIGN_ENDPOINT_SCHEMA = "rq2-causal-factors-001/endpoint-gate-v1"
const CAMPAIGN_TIMING_SCHEMA = "rq2-causal-factors-001/stage-timing-v1"

export GraphView, graph_view, load_config, source_gate, load_native, make_code,
       generate_input, evaluate_map, map_vjp, residual_objective,
       residual_objective_gradient, finite_difference_gradient,
       toy_derivative_gate, long_directional_gate, run_arm, native_decode,
       endpoint_gate, endpoint_sentinels, correctness_gates, calculate_stage,
       run_stage, main,
       canonical_json, scientific_sha256

# ---------------------------------------------------------------------------
# Stable configuration, serialization, and files
# ---------------------------------------------------------------------------

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
text_sha256(value::AbstractString) =
    bytes2hex(sha256(Vector{UInt8}(codeunits(value))))

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
    if value === nothing || value === missing
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
        pairs = [(String(first(pair)), last(pair)) for pair in value]
        length(unique(first.(pairs))) == length(pairs) ||
            throw(ArgumentError("canonical object keys collide"))
        sort!(pairs; by=first)
        "{" * join((canonical_json(key) * ":" * canonical_json(item)
                    for (key, item) in pairs), ",") * "}"
    elseif value isa AbstractMatrix
        canonical_json([[value[row, column] for column in axes(value, 2)]
                        for row in axes(value, 1)])
    elseif value isa AbstractVector || value isa Tuple
        "[" * join((canonical_json(item) for item in value), ",") * "]"
    else
        throw(ArgumentError("unsupported canonical JSON type $(typeof(value))"))
    end
end

scientific_sha256(value) = text_sha256(canonical_json(value))

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq2-bp-target-state-update-001/v1" ||
        throw(ArgumentError("unsupported configuration schema"))
    config["experiment_id"] == "RQ2-BP-TARGET-STATE-UPDATE-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    String.(config["factorial"]["arm_order"]) == collect(ARMS) ||
        throw(ArgumentError("registered arm order changed"))
    Int(config["budget"]["update_attempts_per_arm"]) == 30 ||
        throw(ArgumentError("all cells require exactly 30 attempted updates"))
    Bool(config["budget"]["outcome_altering_early_stop"]) == false ||
        throw(ArgumentError("outcome-altering early stopping is forbidden"))
    provenance = config["provenance"]
    String(provenance["completion_schema"]) == CAMPAIGN_COMPLETION_SCHEMA ||
        throw(ArgumentError("campaign completion schema changed"))
    String(provenance["endpoint_schema"]) == CAMPAIGN_ENDPOINT_SCHEMA ||
        throw(ArgumentError("campaign endpoint schema changed"))
    String(provenance["timing_schema"]) == CAMPAIGN_TIMING_SCHEMA ||
        throw(ArgumentError("campaign timing schema changed"))
    for name in ("calibration", "anchor", "transfer", "attribution")
        stage = config["stages"][name]
        Int(stage["frame_last"]) - Int(stage["frame_first"]) + 1 ==
            Int(stage["expected_count"]) ||
            throw(ArgumentError("$name frame count changed"))
    end
    config
end

function stage_frames(config, stage::Symbol)
    name = String(stage)
    haskey(config["stages"], name) || throw(ArgumentError("unknown stage $stage"))
    section = config["stages"][name]
    Int(section["frame_first"]):Int(section["frame_last"])
end

function git_output(repo::AbstractString, arguments...)
    try
        readchomp(Cmd(String["git", "-C", String(repo), String.(arguments)...]))
    catch error
        "ERROR: " * sprint(showerror, error)
    end
end

function source_gate(config)
    source = config["sources"]
    loaded_root = realpath(dirname(dirname(pathof(JadeJcade))))
    expected_root = realpath(String(source["jade_project_repo"]))
    checks = Dict{String,Bool}(
        "loaded_jade_root" => loaded_root == expected_root,
        "jade_head" => git_output(expected_root, "rev-parse", "HEAD") ==
            String(source["jade_project_expected_head"]),
        "jade_status_clean" => isempty(git_output(expected_root, "status", "--porcelain=v1")),
        "project_toml" => file_sha256(String(source["jade_project_toml"])) ==
            String(source["jade_project_toml_sha256"]),
        "manifest_toml" => file_sha256(String(source["jade_manifest_toml"])) ==
            String(source["jade_manifest_toml_sha256"]),
        "core_common" => file_sha256(String(source["jade_core_common"])) ==
            String(source["jade_core_common_sha256"]),
        "native_runner" => file_sha256(String(source["archived_native_runner"])) ==
            String(source["archived_native_runner_sha256"]),
    )
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function enforce_thread_environment(config)
    Threads.nthreads() == Int(config["validation"]["julia_threads"]) ||
        throw(ArgumentError("registered Julia thread count required"))
    get(ENV, "OMP_NUM_THREADS", "") == string(config["validation"]["omp_threads"]) ||
        throw(ArgumentError("OMP_NUM_THREADS must equal the registered value"))
    BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))
    BLAS.get_num_threads() == Int(config["validation"]["blas_threads"]) ||
        throw(ArgumentError("registered BLAS thread count did not take effect"))
    true
end

function write_new(path::AbstractString, content::AbstractString)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    open(path, "w") do io
        write(io, content)
    end
    path
end

function csv_value(value)
    value === nothing && return ""
    value isa Bool && return lowercase(string(value))
    value isa AbstractFloat && return @sprintf("%.17g", value)
    text = string(value)
    occursin(r"[,\"\n\r]", text) || return text
    "\"" * replace(text, "\"" => "\"\"") * "\""
end

function write_csv(path::AbstractString, rows, columns)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    open(path, "w") do io
        println(io, join(String.(columns), ","))
        for row in rows
            println(io, join((csv_value(getproperty(row, column)) for column in columns), ","))
        end
    end
    path
end

# ---------------------------------------------------------------------------
# Frozen graph and AWGN input
# ---------------------------------------------------------------------------

struct GraphView
    n::Int
    checks::Vector{Vector{Int}}
    check_edges::Vector{UnitRange{Int}}
    variable_edges::Vector{Vector{Int}}
    edge_variable::Vector{Int}
end

function GraphView(checks::Vector{Vector{Int}}, n::Integer)
    check_edges = UnitRange{Int}[]
    variable_edges = [Int[] for _ in 1:Int(n)]
    edge_variable = Int[]
    next_edge = 1
    for members in checks
        isempty(members) && throw(ArgumentError("empty parity check"))
        first_edge = next_edge
        for variable in members
            1 <= variable <= n || throw(ArgumentError("variable outside 1:$n"))
            push!(edge_variable, variable)
            push!(variable_edges[variable], next_edge)
            next_edge += 1
        end
        push!(check_edges, first_edge:(next_edge - 1))
    end
    GraphView(Int(n), deepcopy(checks), check_edges, variable_edges, edge_variable)
end

graph_view(code) = GraphView([Int.(members) for members in code.check_vars], code.n)
edge_count(graph::GraphView) = length(graph.edge_variable)

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

function vector_sha256(values::AbstractVector)
    io = IOBuffer()
    if eltype(values) <: Bool
        write(io, UInt8.(values))
    elseif eltype(values) <: Complex
        contiguous = ComplexF64.(values)
        write(io, reinterpret(UInt8, contiguous))
    else
        contiguous = Float64.(values)
        write(io, reinterpret(UInt8, contiguous))
    end
    bytes2hex(sha256(take!(io)))
end

function load_native(config)
    if !isdefined(@__MODULE__, :AWGNThreeReceivers)
        Base.include(@__MODULE__, String(config["sources"]["archived_native_runner"]))
    end
    Base.invokelatest(() -> getfield(@__MODULE__, :AWGNThreeReceivers))
end

native_binding(native::Module, name::Symbol) =
    Base.invokelatest(getfield, native, name)

function native_call(native::Module, name::Symbol, args...; kwargs...)
    callable = native_binding(native, name)
    Base.invokelatest(callable, args...; kwargs...)
end

function make_code(config, native)
    modem, code = native_call(native, :_modem_and_code;
        k=Int(config["code"]["k"]), n=Int(config["code"]["n"]),
        variable_degree=Int(config["code"]["variable_degree"]))
    graph_sha256(code.check_vars) == String(config["code"]["graph_sha256"]) ||
        throw(ArgumentError("LDPC graph hash changed"))
    all(length(check) == Int(config["code"]["check_degree"]) for check in code.check_vars) ||
        throw(ArgumentError("LDPC check degree changed"))
    (; modem, code)
end

function generate_input(config, native, code, frame::Integer)
    n = Int(config["code"]["n"])
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
    llr = clamp.(Float64.(raw_llr), -clip, clip)
    (; frame=Int(frame), noise_seed=seed, llr,
       received_sha256=vector_sha256(received),
       unit_noise_sha256=vector_sha256(unit_noise),
       llr_sha256=vector_sha256(llr),
       transmitted_bits)
end

# ---------------------------------------------------------------------------
# Exact sum-product target maps and analytic reverse derivative
# ---------------------------------------------------------------------------

function normalize_state_map(value)
    state_map = value isa Symbol ? value : Symbol(value)
    state_map in STATE_MAPS || throw(ArgumentError("unknown state map $state_map"))
    state_map
end

function variable_values(graph::GraphView, llr::AbstractVector{<:Real},
                         u::AbstractVector{<:Real}, state_map)
    state_map = normalize_state_map(state_map)
    length(llr) == graph.n || throw(DimensionMismatch("LLR length differs from graph"))
    length(u) == edge_count(graph) || throw(DimensionMismatch("edge-state length differs"))
    lpost = Float64.(llr)
    qstar = zeros(Float64, edge_count(graph))
    qbar = Float64.(llr)
    for variable in 1:graph.n
        total = Float64(llr[variable])
        incident = graph.variable_edges[variable]
        @inbounds for edge in incident
            total += Float64(u[edge])
        end
        lpost[variable] = total
        sum_qstar = 0.0
        @inbounds for edge in incident
            value = total - Float64(u[edge])
            qstar[edge] = value
            sum_qstar += value
        end
        !isempty(incident) && (qbar[variable] = sum_qstar / length(incident))
    end
    q_used = if state_map === :full
        copy(qstar)
    else
        [qbar[graph.edge_variable[edge]] for edge in 1:edge_count(graph)]
    end
    (; qstar, qbar, q_used, lpost)
end

function evaluate_map(graph::GraphView, llr::AbstractVector{<:Real},
                      u::AbstractVector{<:Real}, state_map)
    values = variable_values(graph, llr, u, state_map)
    output = zeros(Float64, edge_count(graph))
    for range in graph.check_edges
        CORE._bp_check_sum_product!(view(output, range), view(values.q_used, range))
    end
    (; output, values.qstar, values.qbar, values.q_used, values.lpost)
end

function row_dot(left::AbstractVector{<:Real}, right::AbstractVector{<:Real})
    length(left) == length(right) || throw(DimensionMismatch("dot lengths differ"))
    total = 0.0
    @inbounds @simd for index in eachindex(left, right)
        total += Float64(left[index]) * Float64(right[index])
    end
    total
end

"""Apply the transpose Jacobian of the exact check calculation.

The derivative follows the same input, product, and output clamps as the
JadeJcade primal kernel. At a clamp kink the registered derivative is zero;
finite-difference gates choose states separated from those kinks.
"""
function check_vjp(graph::GraphView, q::AbstractVector{<:Real},
                   output_adjoint::AbstractVector{<:Real})
    length(q) == edge_count(graph) || throw(DimensionMismatch("check input length changed"))
    length(output_adjoint) == edge_count(graph) ||
        throw(DimensionMismatch("check adjoint length changed"))
    input_adjoint = zeros(Float64, edge_count(graph))
    max_degree = maximum(length, graph.check_edges)
    tanh_values = zeros(Float64, max_degree)
    limit = tanh(0.5 * LLR_CLIP)
    for range in graph.check_edges
        degree = length(range)
        degree == 1 && continue
        first_edge = first(range)
        @inbounds for slot in 1:degree
            edge = first_edge + slot - 1
            tanh_values[slot] = tanh(0.5 * clamp(Float64(q[edge]), -LLR_CLIP, LLR_CLIP))
        end
        @inbounds for target in 1:degree
            product = 1.0
            for slot in 1:degree
                slot == target && continue
                product *= tanh_values[slot]
            end
            abs(product) < limit || continue
            denominator = 1.0 - product * product
            output_edge = first_edge + target - 1
            adjoint = Float64(output_adjoint[output_edge])
            adjoint == 0.0 && continue
            for source in 1:degree
                source == target && continue
                source_edge = first_edge + source - 1
                source_value = Float64(q[source_edge])
                abs(source_value) < LLR_CLIP || continue
                product_without = 1.0
                for slot in 1:degree
                    (slot == target || slot == source) && continue
                    product_without *= tanh_values[slot]
                end
                derivative = product_without *
                    (1.0 - tanh_values[source]^2) / denominator
                input_adjoint[source_edge] += adjoint * derivative
            end
        end
    end
    input_adjoint
end

function map_vjp(graph::GraphView, llr::AbstractVector{<:Real},
                 u::AbstractVector{<:Real}, state_map,
                 output_adjoint::AbstractVector{<:Real}; evaluation=nothing)
    state_map = normalize_state_map(state_map)
    evaluated = evaluation === nothing ? evaluate_map(graph, llr, u, state_map) : evaluation
    q_adjoint = check_vjp(graph, evaluated.q_used, output_adjoint)
    u_adjoint = zeros(Float64, edge_count(graph))
    for variable in 1:graph.n
        incident = graph.variable_edges[variable]
        isempty(incident) && continue
        total = 0.0
        @inbounds for edge in incident
            total += q_adjoint[edge]
        end
        if state_map === :full
            @inbounds for edge in incident
                u_adjoint[edge] = total - q_adjoint[edge]
            end
        else
            value = (length(incident) - 1) / length(incident) * total
            @inbounds for edge in incident
                u_adjoint[edge] = value
            end
        end
    end
    u_adjoint
end

function residual_objective(graph::GraphView, llr, u, state_map)
    evaluated = evaluate_map(graph, llr, u, state_map)
    residual = Float64.(u) .- evaluated.output
    0.5 * row_dot(residual, residual)
end

function residual_objective_gradient(graph::GraphView, llr, u, state_map)
    evaluated = evaluate_map(graph, llr, u, state_map)
    residual = Float64.(u) .- evaluated.output
    jtr = map_vjp(graph, llr, u, state_map, residual; evaluation=evaluated)
    gradient = residual .- jtr
    objective = 0.5 * row_dot(residual, residual)
    (; objective, gradient, residual, evaluation=evaluated)
end

function finite_difference_gradient(graph::GraphView, llr, u, state_map, step::Real)
    gradient = zeros(Float64, length(u))
    plus = Float64.(u)
    minus = Float64.(u)
    for coordinate in eachindex(gradient)
        plus[coordinate] += step
        minus[coordinate] -= step
        gradient[coordinate] =
            (residual_objective(graph, llr, plus, state_map) -
             residual_objective(graph, llr, minus, state_map)) / (2Float64(step))
        plus[coordinate] = Float64(u[coordinate])
        minus[coordinate] = Float64(u[coordinate])
    end
    gradient
end

function deterministic_direction(length_value::Integer, phase::Real)
    direction = [sin(Float64(phase) * index) + cos((Float64(phase) + 0.17) * index)
                 for index in 1:Int(length_value)]
    direction ./= norm(direction)
    direction
end

function relative_error(observed::Real, expected::Real)
    abs(Float64(observed) - Float64(expected)) /
        max(1.0, abs(Float64(observed)), abs(Float64(expected)))
end

function toy_derivative_gate(config)
    graph = GraphView([[1, 2, 3], [1, 3, 4], [1, 2, 4]], 4)
    llr = [1.3, -0.7, 0.45, -1.1]
    u = [0.07 * sin(index) - 0.03 * cos(0.4index)
         for index in 1:edge_count(graph)]
    step = Float64(config["validation"]["finite_difference_step"])
    gradient_tolerance = Float64(config["validation"]["toy_gradient_absolute_tolerance"])
    vjp_tolerance = Float64(config["validation"]["toy_vjp_absolute_tolerance"])
    records = Dict{String,Any}()
    passed = true
    for state_map in STATE_MAPS
        analytic = residual_objective_gradient(graph, llr, u, state_map)
        finite = finite_difference_gradient(graph, llr, u, state_map, step)
        gradient_error = maximum(abs, analytic.gradient - finite; init=0.0)
        direction = deterministic_direction(length(u), state_map === :full ? 0.31 : 0.47)
        adjoint = deterministic_direction(length(u), state_map === :full ? 0.59 : 0.71)
        vjp = map_vjp(graph, llr, u, state_map, adjoint)
        plus = u .+ step .* direction
        minus = u .- step .* direction
        phi_plus = row_dot(adjoint, evaluate_map(graph, llr, plus, state_map).output)
        phi_minus = row_dot(adjoint, evaluate_map(graph, llr, minus, state_map).output)
        finite_vjp = (phi_plus - phi_minus) / (2step)
        analytic_vjp = row_dot(vjp, direction)
        vjp_error = abs(finite_vjp - analytic_vjp)
        cell_passed = gradient_error <= gradient_tolerance && vjp_error <= vjp_tolerance
        records[String(state_map)] = Dict(
            "passed" => cell_passed,
            "gradient_maximum_absolute_error" => gradient_error,
            "vjp_directional_absolute_error" => vjp_error,
        )
        passed &= cell_passed
    end
    Dict("passed" => passed, "records" => records, "step" => step,
         "gradient_tolerance" => gradient_tolerance,
         "vjp_tolerance" => vjp_tolerance)
end

function kink_margin(values)
    minimum((abs(abs(value) - LLR_CLIP) for value in values); init=Inf)
end

function long_directional_gate(config, graph::GraphView, llr)
    validation = config["validation"]
    minimum_margin = Float64(validation["minimum_check_input_kink_margin"])
    candidates = Float64.(validation["long_state_base_candidates"])
    selected = nothing
    selected_margin = -Inf
    for base in candidates
        u = [base + 1.0e-3 * sin(0.13edge) for edge in 1:edge_count(graph)]
        margins = [kink_margin(evaluate_map(graph, llr, u, state_map).q_used)
                   for state_map in STATE_MAPS]
        margin = minimum(margins)
        if margin > minimum_margin
            selected = (base=base, u=u)
            selected_margin = margin
            break
        end
    end
    selected === nothing && return Dict(
        "passed" => false, "reason" => "no registered smooth validation state",
        "maximum_candidate_margin" => selected_margin)

    step = Float64(validation["long_finite_difference_step"])
    gradient_tolerance = Float64(validation["long_directional_relative_tolerance"])
    vjp_tolerance = Float64(validation["long_vjp_relative_tolerance"])
    u = selected.u
    records = Dict{String,Any}()
    passed = true
    for state_map in STATE_MAPS
        direction = deterministic_direction(length(u), state_map === :full ? 0.013 : 0.017)
        analytic = residual_objective_gradient(graph, llr, u, state_map)
        finite_directional =
            (residual_objective(graph, llr, u .+ step .* direction, state_map) -
             residual_objective(graph, llr, u .- step .* direction, state_map)) /
            (2step)
        analytic_directional = row_dot(analytic.gradient, direction)
        gradient_error = relative_error(finite_directional, analytic_directional)

        output_adjoint = deterministic_direction(length(u),
            state_map === :full ? 0.019 : 0.023)
        vjp = map_vjp(graph, llr, u, state_map, output_adjoint;
                      evaluation=analytic.evaluation)
        phi_plus = row_dot(output_adjoint,
            evaluate_map(graph, llr, u .+ step .* direction, state_map).output)
        phi_minus = row_dot(output_adjoint,
            evaluate_map(graph, llr, u .- step .* direction, state_map).output)
        finite_vjp = (phi_plus - phi_minus) / (2step)
        analytic_vjp = row_dot(vjp, direction)
        vjp_error = relative_error(finite_vjp, analytic_vjp)
        cell_passed = gradient_error <= gradient_tolerance && vjp_error <= vjp_tolerance
        records[String(state_map)] = Dict(
            "passed" => cell_passed,
            "gradient_directional_relative_error" => gradient_error,
            "vjp_directional_relative_error" => vjp_error,
            "finite_gradient_directional" => finite_directional,
            "analytic_gradient_directional" => analytic_directional,
            "finite_vjp_directional" => finite_vjp,
            "analytic_vjp_directional" => analytic_vjp,
        )
        passed &= cell_passed
    end
    Dict("passed" => passed, "selected_state_base" => selected.base,
         "minimum_check_input_kink_margin" => selected_margin,
         "records" => records, "step" => step)
end

# ---------------------------------------------------------------------------
# Four-cell fixed-budget execution and native endpoint gate
# ---------------------------------------------------------------------------

function arm_spec(arm::AbstractString)
    arm in ARMS || throw(ArgumentError("unknown arm $arm"))
    state_map = startswith(arm, "full__") ? :full : :qbar_tied
    operator = endswith(arm, "__direct") ? :direct : :residual_gradient
    (; arm=String(arm), state_map, operator)
end

function syndrome_vector(graph::GraphView, hard::AbstractVector{Bool})
    result = falses(length(graph.checks))
    for (check_index, members) in enumerate(graph.checks)
        parity = false
        @inbounds for variable in members
            parity = xor(parity, hard[variable])
        end
        result[check_index] = parity
    end
    result
end

function decision_state(graph::GraphView, llr, u, state_map)
    values = variable_values(graph, llr, u, state_map)
    hard = BitVector(values.lpost .< 0.0)
    syndrome = syndrome_vector(graph, hard)
    (; hard, syndrome_weight=count(syndrome), parity_valid=!any(syndrome),
       exact_word=!any(hard), coded_bit_errors=count(hard),
       lpost=values.lpost, lpost_metric=-values.lpost,
       q=values.q_used, qstar=values.qstar, qbar=values.qbar)
end

function rows_from_edge_vector(graph::GraphView, values::AbstractVector{<:Real})
    [Float64.(view(values, range)) for range in graph.check_edges]
end

function flatten_rows(rows)
    Float64[value for row in rows for value in row]
end

float_bits_equal(left::AbstractVector{Float64}, right::AbstractVector{Float64}) =
    length(left) == length(right) && reinterpret(UInt64, left) == reinterpret(UInt64, right)

function run_arm(config, graph::GraphView, llr, arm::AbstractString;
                 frame::Integer=0, stage::AbstractString="unit")
    spec = arm_spec(arm)
    attempts = Int(config["budget"]["update_attempts_per_arm"])
    gradient_config = config["gradient"]
    u = zeros(Float64, edge_count(graph))
    iteration_rows = NamedTuple[]
    accepted_updates = 0
    stalls = 0
    objective_evaluations = 0
    first_valid_update = 0
    first_exact_update = 0
    first_valid_snapshot = nothing
    first_valid_hard_sha256 = "none"
    first_exact_hard_sha256 = "none"

    for update in 1:attempts
        current = if spec.operator === :direct
            evaluation = evaluate_map(graph, llr, u, spec.state_map)
            residual = u .- evaluation.output
            (objective=0.5 * row_dot(residual, residual),
             gradient=Float64[], residual, evaluation)
        else
            residual_objective_gradient(graph, llr, u, spec.state_map)
        end
        objective_evaluations += 1
        objective_before = current.objective
        gradient_norm = spec.operator === :direct ? 0.0 : norm(current.gradient)
        accepted = false
        step_size = 0.0
        backtracks = 0
        objective_after = objective_before

        if spec.operator === :direct
            u = copy(current.evaluation.output)
            accepted = true
            accepted_updates += 1
            step_size = 1.0
            objective_after = residual_objective(graph, llr, u, spec.state_map)
            objective_evaluations += 1
        else
            alpha = Float64(gradient_config["initial_step"])
            factor = Float64(gradient_config["backtrack_factor"])
            armijo_c = Float64(gradient_config["armijo_c"])
            maximum_backtracks = Int(gradient_config["maximum_backtracks"])
            gradient_norm_squared = row_dot(current.gradient, current.gradient)
            for backtrack in 0:maximum_backtracks
                trial = u .- alpha .* current.gradient
                trial_objective = residual_objective(graph, llr, trial, spec.state_map)
                objective_evaluations += 1
                if isfinite(trial_objective) && trial_objective < objective_before &&
                   trial_objective <= objective_before -
                                      armijo_c * alpha * gradient_norm_squared
                    u = trial
                    objective_after = trial_objective
                    accepted = true
                    accepted_updates += 1
                    step_size = alpha
                    backtracks = backtrack
                    break
                end
                alpha *= factor
                backtracks = backtrack + 1
            end
            if !accepted
                stalls += 1
                step_size = 0.0
                objective_after = objective_before
            end
        end

        state = decision_state(graph, llr, u, spec.state_map)
        hard_hash = vector_sha256(state.hard)
        if state.parity_valid && first_valid_update == 0
            first_valid_update = update
            first_valid_hard_sha256 = hard_hash
            first_valid_snapshot = (;
                update,
                hard=copy(state.hard),
                lpost_metric=copy(state.lpost_metric),
                q=copy(state.q),
                u=copy(u),
                syndrome_weight=state.syndrome_weight,
            )
        end
        if state.exact_word && first_exact_update == 0
            first_exact_update = update
            first_exact_hard_sha256 = hard_hash
        end
        push!(iteration_rows, (;
            stage=String(stage), frame=Int(frame), arm=spec.arm,
            state_map=String(spec.state_map), update_operator=String(spec.operator),
            update, objective_before, objective_after, gradient_norm,
            step_size, backtracks, accepted,
            parity_valid=state.parity_valid, exact_word=state.exact_word,
            coded_bit_errors=state.coded_bit_errors,
            syndrome_weight=state.syndrome_weight, hard_word_sha256=hard_hash,
        ))
    end

    terminal = decision_state(graph, llr, u, spec.state_map)
    terminal_objective = residual_objective(graph, llr, u, spec.state_map)
    objective_evaluations += 1
    (; spec, u, terminal, terminal_objective, iteration_rows,
       updates_attempted=attempts, accepted_updates, stalls, objective_evaluations,
       first_valid_update, first_exact_update, first_valid_snapshot,
       first_valid_hard_sha256, first_exact_hard_sha256)
end

function native_decode(modem, code, llr::AbstractVector{Float64})
    value = CORE._bp_decode_sum_product(modem, code, -llr)
    scratch = CORE._bp_scratch(modem, code)
    hard = BitVector(copy(scratch.bits))
    syndrome_weight = CORE._syndrome_weight(code, hard)
    (; hard, lpost_metric=copy(value.lpost_metric),
       q=deepcopy(scratch.q), u=deepcopy(scratch.r),
       valid=Bool(value.valid), syndrome_weight,
       iterations=Int(value.iterations), exact_word=!any(hard),
       coded_bit_errors=count(hard))
end

function endpoint_gate(graph::GraphView, full_direct, native)
    snapshot = full_direct.first_valid_snapshot
    if native.valid && snapshot !== nothing
        native_q = flatten_rows(native.q)
        native_u = flatten_rows(native.u)
        checks = Dict(
            "first_valid_exists" => true,
            "stopping_iteration" => full_direct.first_valid_update == native.iterations,
            "hard_word" => snapshot.hard == native.hard,
            "posterior_float_bits" =>
                float_bits_equal(snapshot.lpost_metric, native.lpost_metric),
            "variable_to_check_float_bits" => float_bits_equal(snapshot.q, native_q),
            "check_to_variable_float_bits" => float_bits_equal(snapshot.u, native_u),
            "syndrome_weight" => snapshot.syndrome_weight == native.syndrome_weight,
        )
        return Dict("passed" => all(values(checks)), "checks" => checks,
                    "native_iteration" => native.iterations,
                    "full_direct_first_valid_update" => full_direct.first_valid_update)
    end
    checks = Dict(
        "native_and_full_direct_both_have_no_valid_endpoint" =>
            !native.valid && snapshot === nothing,
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "native_iteration" => native.iterations,
         "full_direct_first_valid_update" => full_direct.first_valid_update)
end

function mean_preservation_gate(graph::GraphView, llr)
    u = [0.19sin(0.11edge) - 0.07cos(0.23edge) for edge in 1:edge_count(graph)]
    full = variable_values(graph, llr, u, :full)
    tied = variable_values(graph, llr, u, :qbar_tied)
    maximum_error = 0.0
    maximum_tied_spread = 0.0
    for variable in 1:graph.n
        incident = graph.variable_edges[variable]
        isempty(incident) && continue
        full_mean = sum(full.qstar[edge] for edge in incident) / length(incident)
        tied_values = [tied.q_used[edge] for edge in incident]
        maximum_error = max(maximum_error, abs(full_mean - tied.qbar[variable]))
        maximum_tied_spread = max(maximum_tied_spread,
            maximum(tied_values) - minimum(tied_values))
    end
    Dict("passed" => maximum_error <= 1.0e-12 && maximum_tied_spread == 0.0,
         "maximum_mean_error" => maximum_error,
         "maximum_tied_spread" => maximum_tied_spread)
end

function correctness_gates(config, native, modem, code)
    source = source_gate(config)
    graph = graph_view(code)
    calibration_frame = Int(config["stages"]["calibration"]["frame_first"])
    input = generate_input(config, native, code, calibration_frame)
    toy = toy_derivative_gate(config)
    long = long_directional_gate(config, graph, input.llr)
    mean_gate = mean_preservation_gate(graph, input.llr)
    checks = Dict(
        "source" => Bool(source["passed"]),
        "graph_hash" => graph_sha256(code.check_vars) == String(config["code"]["graph_sha256"]),
        "toy_derivatives" => Bool(toy["passed"]),
        "long_directional_derivatives" => Bool(long["passed"]),
        "qbar_mean_preservation" => Bool(mean_gate["passed"]),
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "source" => source, "toy_derivatives" => toy,
         "long_directional_derivatives" => long,
         "qbar_mean_preservation" => mean_gate,
         "calibration_frame" => calibration_frame)
end

function arm_frame_row(stage, frame, input, result, native, native_gate)
    terminal = result.terminal
    (;
        stage=String(stage), frame=Int(frame), arm=result.spec.arm,
        state_map=String(result.spec.state_map),
        update_operator=String(result.spec.operator),
        noise_seed=input.noise_seed, llr_sha256=input.llr_sha256,
        updates_attempted=result.updates_attempted,
        accepted_updates=result.accepted_updates,
        line_search_stalls=result.stalls,
        objective_evaluations=result.objective_evaluations,
        first_valid_update=result.first_valid_update,
        first_exact_word_update=result.first_exact_update,
        terminal_parity_valid=terminal.parity_valid,
        terminal_exact_word=terminal.exact_word,
        terminal_coded_bit_errors=terminal.coded_bit_errors,
        terminal_syndrome_weight=terminal.syndrome_weight,
        terminal_hard_word_sha256=vector_sha256(terminal.hard),
        terminal_objective=result.terminal_objective,
        first_valid_hard_word_sha256=result.first_valid_hard_sha256,
        first_exact_hard_word_sha256=result.first_exact_hard_sha256,
        native_valid=native.valid, native_exact_word=native.exact_word,
        native_iterations=native.iterations,
        native_coded_bit_errors=native.coded_bit_errors,
        native_hard_word_sha256=vector_sha256(native.hard),
        native_endpoint_gate_passed=Bool(native_gate["passed"]),
    )
end

function arm_science(row)
    Dict(
        "arm" => row.arm,
        "accepted_updates" => row.accepted_updates,
        "line_search_stalls" => row.line_search_stalls,
        "objective_evaluations" => row.objective_evaluations,
        "first_valid_update" => row.first_valid_update,
        "first_exact_word_update" => row.first_exact_word_update,
        "terminal_parity_valid" => row.terminal_parity_valid,
        "terminal_exact_word" => row.terminal_exact_word,
        "terminal_coded_bit_errors" => row.terminal_coded_bit_errors,
        "terminal_syndrome_weight" => row.terminal_syndrome_weight,
        "terminal_hard_word_sha256" => row.terminal_hard_word_sha256,
        "terminal_objective" => row.terminal_objective,
        "first_valid_hard_word_sha256" => row.first_valid_hard_word_sha256,
        "first_exact_hard_word_sha256" => row.first_exact_hard_word_sha256,
    )
end

function calculate_stage(config, stage::Symbol, native, modem, code, correctness)
    Bool(correctness["passed"]) || throw(ArgumentError("correctness gates failed"))
    graph = graph_view(code)
    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    frame_science = Dict{String,Any}[]
    all_native_gates = true

    for frame in stage_frames(config, stage)
        input = generate_input(config, native, code, frame)
        native_result = native_decode(modem, code, input.llr)
        arm_results = Dict{String,Any}()
        for arm in ARMS
            arm_results[arm] = run_arm(config, graph, input.llr, arm;
                                       frame, stage=String(stage))
        end
        gate = endpoint_gate(graph, arm_results["full__direct"], native_result)
        all_native_gates &= Bool(gate["passed"])
        rows = NamedTuple[]
        for arm in ARMS
            result = arm_results[arm]
            row = arm_frame_row(stage, frame, input, result, native_result, gate)
            push!(rows, row)
            push!(frame_rows, row)
            append!(iteration_rows, result.iteration_rows)
        end
        push!(frame_science, Dict(
            "frame" => frame,
            "noise_seed" => input.noise_seed,
            "llr_sha256" => input.llr_sha256,
            "native" => Dict(
                "valid" => native_result.valid,
                "exact_word" => native_result.exact_word,
                "iterations" => native_result.iterations,
                "coded_bit_errors" => native_result.coded_bit_errors,
                "hard_word_sha256" => vector_sha256(native_result.hard),
            ),
            "native_endpoint_gate" => gate,
            "arms" => Dict(row.arm => arm_science(row) for row in rows),
        ))
    end

    aggregates = Dict{String,Any}()
    for arm in ARMS
        selected = [row for row in frame_rows if row.arm == arm]
        aggregates[arm] = Dict(
            "cases" => length(selected),
            "terminal_exact_word_count" => count(row -> row.terminal_exact_word, selected),
            "terminal_parity_valid_count" => count(row -> row.terminal_parity_valid, selected),
            "ever_exact_word_count" => count(row -> row.first_exact_word_update > 0, selected),
            "ever_parity_valid_count" => count(row -> row.first_valid_update > 0, selected),
            "accepted_updates_total" => sum(row.accepted_updates for row in selected),
            "line_search_stalls_total" => sum(row.line_search_stalls for row in selected),
        )
    end
    science = Dict(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage),
        "frame_first" => first(stage_frames(config, stage)),
        "frame_last" => last(stage_frames(config, stage)),
        "frame_count" => length(stage_frames(config, stage)),
        "updates_per_arm" => Int(config["budget"]["update_attempts_per_arm"]),
        "outcome_altering_early_stop" => false,
        "correctness_gates" => correctness,
        "native_endpoint_gates_passed" => all_native_gates,
        "frames" => frame_science,
        "aggregates" => aggregates,
        "complete_valid" => all_native_gates && Bool(correctness["passed"]),
    )
    (; science, frame_rows, iteration_rows)
end

function result_columns()
    (
        :stage, :frame, :arm, :state_map, :update_operator, :noise_seed,
        :llr_sha256, :updates_attempted, :accepted_updates,
        :line_search_stalls, :objective_evaluations, :first_valid_update,
        :first_exact_word_update, :terminal_parity_valid, :terminal_exact_word,
        :terminal_coded_bit_errors, :terminal_syndrome_weight,
        :terminal_hard_word_sha256, :terminal_objective,
        :first_valid_hard_word_sha256, :first_exact_hard_word_sha256,
        :native_valid, :native_exact_word, :native_iterations,
        :native_coded_bit_errors, :native_hard_word_sha256,
        :native_endpoint_gate_passed,
    )
end

function iteration_columns()
    (
        :stage, :frame, :arm, :state_map, :update_operator, :update,
        :objective_before, :objective_after, :gradient_norm, :step_size,
        :backtracks, :accepted, :parity_valid, :exact_word,
        :coded_bit_errors, :syndrome_weight, :hard_word_sha256,
    )
end

"""Build the Block-B identity fields consumed by the campaign controller.

The collection hashes deliberately use the same canonical structures as
Block A: sorted frame integers and sorted `(frame, digest)` pairs. The
full-direct digest uses the first valid endpoint, which is the snapshot gated
against native exact sum-product. If no valid endpoint exists, its terminal
hard decision is retained so the equality gate fails closed when the two
endpoints differ.
"""
function endpoint_sentinels(science)
    frames = sort(collect(science["frames"]); by=frame -> Int(frame["frame"]))
    frame_ids = Int[Int(frame["frame"]) for frame in frames]
    length(unique(frame_ids)) == length(frame_ids) ||
        throw(ArgumentError("duplicate frame identifiers in Block B science"))
    isempty(frame_ids) && throw(ArgumentError("Block B endpoint set is empty"))

    llr_pairs = [(Int(frame["frame"]), String(frame["llr_sha256"]))
                 for frame in frames]
    native_pairs = [(Int(frame["frame"]),
                     String(frame["native"]["hard_word_sha256"]))
                    for frame in frames]
    full_direct_pairs = Tuple{Int,String}[]
    native_successes = 0
    full_direct_successes = 0
    endpoint_gates_passed = true
    for frame in frames
        native = frame["native"]
        direct = frame["arms"]["full__direct"]
        native_successes += Bool(native["exact_word"])
        first_valid_update = Int(direct["first_valid_update"])
        full_direct_successes += Int(direct["first_exact_word_update"]) > 0
        direct_hash = if first_valid_update > 0
            String(direct["first_valid_hard_word_sha256"])
        else
            String(direct["terminal_hard_word_sha256"])
        end
        push!(full_direct_pairs, (Int(frame["frame"]), direct_hash))
        endpoint_gates_passed &= Bool(frame["native_endpoint_gate"]["passed"])
    end

    native_digest = scientific_sha256(native_pairs)
    full_direct_digest = scientific_sha256(full_direct_pairs)
    endpoints_equal = endpoint_gates_passed &&
        native_successes == full_direct_successes &&
        native_digest == full_direct_digest
    Dict(
        "frame_first" => first(frame_ids),
        "frame_last" => last(frame_ids),
        "frame_count" => length(frame_ids),
        "frame_ids_sha256" => scientific_sha256(frame_ids),
        "channel_llrs_sha256" => scientific_sha256(llr_pairs),
        "native_bp_successes" => native_successes,
        "native_bp_hard_words_sha256" => native_digest,
        "full_direct_successes" => full_direct_successes,
        "full_direct_hard_words_sha256" => full_direct_digest,
        "native_bp_full_direct_equal" => endpoints_equal,
    )
end

function write_result(output::AbstractString, config_path::AbstractString, stage::Symbol,
                      primary, replay;
                      scientific_frame_loop_seconds::Real=0.0,
                      pass_count::Integer=2)
    ispath(output) && throw(ArgumentError("refusing to overwrite $output"))
    post_loop_started = time_ns()
    mkpath(output)
    science_path = joinpath(output, "science.json")
    frames_path = joinpath(output, "frames.csv")
    iterations_path = joinpath(output, "iterations.csv")
    write_new(science_path, canonical_json(primary.science) * "\n")
    write_csv(frames_path, primary.frame_rows, result_columns())
    write_csv(iterations_path, primary.iteration_rows, iteration_columns())
    primary_sha256 = scientific_sha256(primary.science)
    replay_sha256 = scientific_sha256(replay.science)
    primary_sentinels = endpoint_sentinels(primary.science)
    replay_sentinels = endpoint_sentinels(replay.science)
    primary_sentinel_sha256 = scientific_sha256(primary_sentinels)
    replay_sentinel_sha256 = scientific_sha256(replay_sentinels)
    sentinel_self_consistency_passed =
        primary_sentinels == replay_sentinels &&
        primary_sentinel_sha256 == replay_sentinel_sha256 &&
        Bool(primary_sentinels["native_bp_full_direct_equal"])
    endpoint_gate = Dict{String,Any}(
        "schema_version" => CAMPAIGN_ENDPOINT_SCHEMA,
        "experiment_id" => CAMPAIGN_EXPERIMENT_ID,
        "block" => "B",
        "stage" => String(stage),
        "gate_mode" => "cross_block_bp",
        "sentinel_self_consistency_passed" => sentinel_self_consistency_passed,
        "primary_sentinel_sha256" => primary_sentinel_sha256,
        "replay_sentinel_sha256" => replay_sentinel_sha256,
    )
    merge!(endpoint_gate, primary_sentinels)
    endpoint_gate_path = joinpath(output, "endpoint_gate.toml")
    open(endpoint_gate_path, "w") do io
        TOML.print(io, endpoint_gate; sorted=true)
    end
    correctness_passed = Bool(primary.science["complete_valid"]) &&
        Bool(replay.science["complete_valid"]) && sentinel_self_consistency_passed
    deterministic_replay_passed = primary_sha256 == replay_sha256
    completion = Dict(
        "schema_version" => CAMPAIGN_COMPLETION_SCHEMA,
        "experiment_id" => CAMPAIGN_EXPERIMENT_ID,
        "block" => "B",
        "stage" => String(stage),
        "status" => correctness_passed && deterministic_replay_passed ?
            "complete_valid" : "invalid",
        "correctness_passed" => correctness_passed,
        "deterministic_replay_passed" => deterministic_replay_passed,
        "science_sha256" => file_sha256(science_path),
        "endpoint_gate_sha256" => file_sha256(endpoint_gate_path),
        "primary_science_sha256" => primary_sha256,
        "replay_science_sha256" => replay_sha256,
    )
    completion_path = joinpath(output, "COMPLETED.toml")
    open(completion_path, "w") do io
        TOML.print(io, completion; sorted=true)
    end
    post_loop_seconds = (time_ns() - post_loop_started) / 1.0e9
    timing = Dict(
        "schema_version" => CAMPAIGN_TIMING_SCHEMA,
        "experiment_id" => CAMPAIGN_EXPERIMENT_ID,
        "block" => "B",
        "stage" => String(stage),
        "frame_count" => Int(primary.science["frame_count"]),
        "pass_count" => Int(pass_count),
        "scientific_frame_loop_seconds" => Float64(scientific_frame_loop_seconds),
        "post_loop_seconds" => Float64(post_loop_seconds),
    )
    timing_path = joinpath(output, "timing.toml")
    open(timing_path, "w") do io
        TOML.print(io, timing; sorted=true)
    end
    manifest_entries = Pair{String,String}[]
    for name in ("science.json", "frames.csv", "iterations.csv",
                 "endpoint_gate.toml", "COMPLETED.toml", "timing.toml")
        push!(manifest_entries, file_sha256(joinpath(output, name)) => name)
    end
    write_new(joinpath(output, "MANIFEST.sha256"),
              join((hash * "  " * name for (hash, name) in manifest_entries), "\n") * "\n")
    completion
end

function run_stage(; config_path::AbstractString=DEFAULT_CONFIG,
                   stage::Symbol=:anchor, output::AbstractString)
    config = load_config(config_path)
    enforce_thread_environment(config)
    source = source_gate(config)
    Bool(source["passed"]) || throw(ArgumentError("source gate failed"))
    native = load_native(config)
    built = make_code(config, native)
    correctness = correctness_gates(config, native, built.modem, built.code)
    Bool(correctness["passed"]) || throw(ArgumentError(
        "derivative, graph, source, or mean-preservation correctness gate failed"))
    frame_loop_started = time_ns()
    primary = calculate_stage(config, stage, native, built.modem, built.code, correctness)
    replay = calculate_stage(config, stage, native, built.modem, built.code, correctness)
    scientific_frame_loop_seconds = (time_ns() - frame_loop_started) / 1.0e9
    primary_sha256 = scientific_sha256(primary.science)
    replay_sha256 = scientific_sha256(replay.science)
    primary_sha256 == replay_sha256 || throw(ArgumentError(
        "deterministic replay differs: $primary_sha256 versus $replay_sha256"))
    completion = write_result(output, config_path, stage, primary, replay;
        scientific_frame_loop_seconds,
        pass_count=Int(config["budget"]["scientific_passes"]))
    (; primary_sha256, replay_sha256, completion, output=abspath(output))
end

function parse_options(arguments)
    options = Dict{String,String}()
    index = 1
    while index <= length(arguments)
        startswith(arguments[index], "--") ||
            throw(ArgumentError("expected option, got $(arguments[index])"))
        index < length(arguments) || throw(ArgumentError("missing value for $(arguments[index])"))
        options[arguments[index][3:end]] = arguments[index + 1]
        index += 2
    end
    options
end

function main(arguments=ARGS)
    isempty(arguments) && throw(ArgumentError(
        "usage: rq2_bp_target_state_update_001.jl stage --stage NAME --config PATH --output DIR"))
    command = arguments[1]
    command == "stage" || throw(ArgumentError("only the stage command is supported"))
    options = parse_options(arguments[2:end])
    haskey(options, "output") || throw(ArgumentError("--output is required"))
    stage = Symbol(get(options, "stage", "anchor"))
    config_path = get(options, "config", DEFAULT_CONFIG)
    result = run_stage(; config_path, stage, output=options["output"])
    println("complete_valid stage=$(stage) science_sha256=$(result.primary_sha256)")
    result
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
