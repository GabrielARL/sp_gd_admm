#!/usr/bin/env julia

module RQ2NativeComposition001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using TOML

const HERE = @__DIR__
const EXPERIMENT_ID = "RQ2-NATIVE-COMPOSITION-001"
const CONFIG_SCHEMA = "rq2-native-composition-001/config-v1"
const REGISTRY_SCHEMA = "rq2-native-composition-001/rung-registry-v1"
const SCIENCE_SCHEMA = "rq2-native-composition-001/science-v1"
const JOB_GATE_SCHEMA = "rq2-native-composition-001/job-gate-v1"
const ENDPOINT_GATE_SCHEMA = "rq2-native-composition-001/endpoint-gate-v1"
const COMPLETION_SCHEMA = "rq2-native-composition-001/job-completion-v1"
const TIMING_SCHEMA = "rq2-native-composition-001/timing-v1"

const BLOCK_A_RUNNER = normpath(joinpath(
    HERE, "..", "rq2_gd_residual_projection_budget_001",
    "rq2_gd_residual_projection_budget_001.jl"))
const BLOCK_B_RUNNER = normpath(joinpath(
    HERE, "..", "rq2_bp_target_state_update_001",
    "rq2_bp_target_state_update_001.jl"))

# These are retained scientific implementations.  This composition runner
# calls their public and module-qualified numerical primitives; it does not
# modify either retained experiment.
include(BLOCK_A_RUNNER)
include(BLOCK_B_RUNNER)
const BlockA = RQ2GDResidualProjectionBudget001
const BlockB = RQ2BPTargetStateUpdate001

const FORWARD_ORDER = (
    "native_projected_gd",
    "shadow_edge_state",
    "assigned_frozen_compound_box",
    "assigned_frozen_product_box",
    "assigned_frozen_product_unconstrained",
    "edge_product_residual_gradient_tied",
    "exact_sp_residual_gradient_tied",
    "exact_sp_residual_gradient_full",
    "exact_sp_direct_full_fixed30",
    "exact_sp_direct_full_stop30",
    "native_exact_sum_product",
)

const EXPECTED_BACKENDS = Dict(
    "native_projected_gd" => "native_gd",
    "shadow_edge_state" => "shadow",
    "assigned_frozen_compound_box" => "block_a",
    "assigned_frozen_product_box" => "block_a",
    "assigned_frozen_product_unconstrained" => "block_a",
    "edge_product_residual_gradient_tied" => "product_edge",
    "exact_sp_residual_gradient_tied" => "block_b",
    "exact_sp_residual_gradient_full" => "block_b",
    "exact_sp_direct_full_fixed30" => "block_b",
    "exact_sp_direct_full_stop30" => "block_b",
    "native_exact_sum_product" => "native_bp",
)

const FINGERPRINT_FIELDS = (
    "state_family",
    "target_family",
    "update_family",
    "projection_family",
    "protocol_family",
)

const JOINT_FROM = "assigned_frozen_product_unconstrained"
const JOINT_TO = "edge_product_residual_gradient_tied"

const JOB_IDS = (
    "01_switch_registry_gate",
    "02_common_harness_gate",
    "03_native_endpoint_and_rung_gate",
    "04_fresh_dual_snr_anchor",
    "05_six_db_forward_transfer",
    "06_six_db_order_controls_and_attribution",
    "07_second_snr_confirmation",
)

const SCIENCE_JOBS = Set(JOB_IDS[4:end])
const VALIDATION_JOBS = Set(JOB_IDS[1:3])

export FORWARD_ORDER, JOB_IDS, load_config, load_registry, registry_gate,
       shadow_state_null_gate, product_map, edge_residual_gradient,
       finite_difference_gradient, common_harness_gate, run_job, main,
       canonical_json, scientific_sha256

# ---------------------------------------------------------------------------
# Stable serialization and file helpers
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
    elseif value isa AbstractVector || value isa Tuple || value isa Set
        items = value isa Set ? sort!(collect(value); by=string) : value
        "[" * join((canonical_json(item) for item in items), ",") * "]"
    else
        throw(ArgumentError("unsupported canonical JSON type $(typeof(value))"))
    end
end

scientific_sha256(value) = text_sha256(canonical_json(value))

function csv_value(value)
    value === nothing && return ""
    value isa Bool && return lowercase(string(value))
    value isa AbstractFloat && return @sprintf("%.17g", value)
    text = string(value)
    occursin(r"[,\"\n\r]", text) || return text
    "\"" * replace(text, "\"" => "\"\"") * "\""
end

function write_csv(path::AbstractString, rows, columns)
    open(path, "w") do io
        println(io, join(String.(columns), ","))
        for row in rows
            println(io, join((csv_value(getproperty(row, column)) for column in columns), ","))
        end
    end
end

resolve_from(base::AbstractString, path::AbstractString) =
    isabspath(path) ? normpath(path) : normpath(joinpath(base, path))

# ---------------------------------------------------------------------------
# Configuration and immutable rung registry
# ---------------------------------------------------------------------------

function load_config(path::AbstractString)
    config = TOML.parsefile(path)
    get(config, "schema_version", "") == CONFIG_SCHEMA ||
        throw(ArgumentError("unsupported native-composition configuration schema"))
    get(config, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("unexpected experiment identifier"))
    get(config, "research_question", "RQ2") == "RQ2" ||
        throw(ArgumentError("native composition must remain an RQ2 experiment"))

    sources = config["sources"]
    for key in ("block_a_runner", "block_a_config", "block_b_runner", "block_b_config")
        haskey(sources, key) || throw(ArgumentError("missing sources.$key"))
    end
    base = dirname(abspath(path))
    resolve_from(base, String(sources["block_a_runner"])) == BLOCK_A_RUNNER ||
        throw(ArgumentError("composition must reuse the registered Block A runner"))
    resolve_from(base, String(sources["block_b_runner"])) == BLOCK_B_RUNNER ||
        throw(ArgumentError("composition must reuse the registered Block B runner"))

    frames = config["frames"]
    expected_ranges = Dict(
        "endpoint_gate" => (20001, 20024),
        "anchor" => (60001, 60024),
        "six_db" => (60025, 60224),
        "locked" => (30001, 30200),
        "second_snr" => (60225, 60424),
    )
    for (name, (first_expected, last_expected)) in expected_ranges
        Int(frames[name * "_first"]) == first_expected ||
            throw(ArgumentError("$name first frame changed"))
        Int(frames[name * "_last"]) == last_expected ||
            throw(ArgumentError("$name last frame changed"))
    end
    Int(config["budget"]["scientific_passes"]) == 2 ||
        throw(ArgumentError("primary and deterministic replay passes are required"))
    locked = config["job6"]["locked_expected"]
    expected_locked = Dict(
        "case_count" => 200,
        "native_projected_gd_successes" => 107,
        "native_exact_sum_product_successes" => 200,
        "native_net_gap" => 93,
    )
    all(Int(locked[key]) == value for (key, value) in expected_locked) ||
        throw(ArgumentError("registered locked endpoint counts changed"))
    inference = config["inference"]
    Int(inference["atomic_transition_count"]) == length(FORWARD_ORDER) - 2 ||
        throw(ArgumentError("Holm family must contain every atomic transition"))
    Bool(inference["non_atomic_handoff_included"]) == false ||
        throw(ArgumentError("the joint handoff cannot enter single-factor inference"))
    alpha = Float64(inference["familywise_alpha"])
    alpha == 0.05 || throw(ArgumentError(
        "registered familywise alpha changed"))
    !isempty(String(inference["holm_family"])) || throw(ArgumentError(
        "Holm family description is required"))
    registered_confidence = 1.0 - alpha /
        Int(inference["atomic_transition_count"])
    Float64(inference["simultaneous_interval_confidence_level"]) ==
        registered_confidence || throw(ArgumentError(
            "simultaneous interval confidence level changed"))
    config
end

function load_registry(path::AbstractString)
    registry = TOML.parsefile(path)
    get(registry, "schema_version", "") == REGISTRY_SCHEMA ||
        throw(ArgumentError("unsupported rung registry schema"))
    get(registry, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("rung registry experiment identifier changed"))
    String.(registry["forward_order"]) == collect(FORWARD_ORDER) ||
        throw(ArgumentError("forward rung order changed"))
    registry
end

function registry_gate(registry)
    records = get(registry, "rungs", Any[])
    transitions = get(registry, "transitions", Any[])
    checks = Dict{String,Bool}()
    checks["registered_rung_count"] = length(records) == length(FORWARD_ORDER)
    checks["registered_transition_count"] =
        length(transitions) == length(FORWARD_ORDER) - 1

    if checks["registered_rung_count"]
        by_position = sort(records; by=row -> Int(row["position"]))
        checks["positions"] = Int.(getindex.(by_position, "position")) ==
            collect(1:length(FORWARD_ORDER))
        checks["rung_ids"] = String.(getindex.(by_position, "id")) ==
            collect(FORWARD_ORDER)
        checks["backends"] = all(
            get(record, "backend", "") == EXPECTED_BACKENDS[String(record["id"])]
            for record in by_position)
        checks["fingerprints_complete"] = all(
            all(haskey(record, key) && !isempty(String(record[key]))
                for key in FINGERPRINT_FIELDS)
            for record in by_position)
    else
        checks["positions"] = false
        checks["rung_ids"] = false
        checks["backends"] = false
        checks["fingerprints_complete"] = false
    end

    joint_count = 0
    transitions_valid = checks["registered_transition_count"]
    fingerprint_differences_valid = checks["registered_rung_count"] &&
        checks["fingerprints_complete"]
    if transitions_valid
        by_id = Dict(String(record["id"]) => record for record in records)
        for (index, transition) in enumerate(transitions)
            from = String(transition["from"])
            to = String(transition["to"])
            transitions_valid &= from == FORWARD_ORDER[index]
            transitions_valid &= to == FORWARD_ORDER[index + 1]
            transitions_valid &= haskey(transition, "changed_operation") &&
                !isempty(String(transition["changed_operation"]))
            registered_fields = haskey(transition, "changed_fingerprint_fields") ?
                String.(transition["changed_fingerprint_fields"]) : String[]
            fingerprint_differences_valid &= !isempty(registered_fields)
            fingerprint_differences_valid &=
                length(unique(registered_fields)) == length(registered_fields)
            fingerprint_differences_valid &=
                all(field in FINGERPRINT_FIELDS for field in registered_fields)
            actual_fields = sort!([field for field in FINGERPRINT_FIELDS
                if String(by_id[from][field]) != String(by_id[to][field])])
            fingerprint_differences_valid &=
                sort!(copy(registered_fields)) == actual_fields
            joint = from == JOINT_FROM && to == JOINT_TO
            joint_count += joint
            if joint
                transitions_valid &= !Bool(transition["atomic"])
                transitions_valid &= !Bool(transition["attributable"])
            else
                transitions_valid &= Bool(transition["atomic"])
                transitions_valid &= Bool(transition["attributable"])
            end
        end
    end
    checks["adjacent_transition_contract"] = transitions_valid
    checks["adjacent_fingerprint_differences"] = fingerprint_differences_valid
    checks["one_registered_joint_handoff"] = joint_count == 1
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "forward_order_sha256" => scientific_sha256(collect(FORWARD_ORDER)),
        "joint_handoff" => Dict(
            "from" => JOINT_FROM,
            "to" => JOINT_TO,
            "atomic" => false,
            "attributable" => false,
        ),
    )
end

# ---------------------------------------------------------------------------
# Product-edge target and derivative gates
# ---------------------------------------------------------------------------

function product_map(graph::BlockB.GraphView, llr::AbstractVector{<:Real},
                     u::AbstractVector{<:Real}, state_map)
    values = BlockB.variable_values(graph, llr, u, state_map)
    output = zeros(Float64, BlockB.edge_count(graph))
    for range in graph.check_edges
        for target in range
            product = 1.0
            for source in range
                source == target && continue
                product *= tanh(0.5 * clamp(Float64(values.q_used[source]),
                                             -BlockB.LLR_CLIP, BlockB.LLR_CLIP))
            end
            output[target] = product
        end
    end
    (; output, values.qstar, values.qbar, values.q_used, values.lpost)
end

function product_check_vjp(graph::BlockB.GraphView,
                           q::AbstractVector{<:Real},
                           output_adjoint::AbstractVector{<:Real})
    input_adjoint = zeros(Float64, BlockB.edge_count(graph))
    for range in graph.check_edges
        for target in range
            adjoint = Float64(output_adjoint[target])
            adjoint == 0.0 && continue
            for source in range
                source == target && continue
                source_value = Float64(q[source])
                abs(source_value) < BlockB.LLR_CLIP || continue
                product_without = 1.0
                for other in range
                    (other == target || other == source) && continue
                    product_without *= tanh(0.5 * clamp(Float64(q[other]),
                        -BlockB.LLR_CLIP, BlockB.LLR_CLIP))
                end
                derivative = 0.5 * (1.0 - tanh(0.5source_value)^2) *
                    product_without
                input_adjoint[source] += adjoint * derivative
            end
        end
    end
    input_adjoint
end

function variable_vjp(graph::BlockB.GraphView, q_adjoint, state_map)
    normalized = BlockB.normalize_state_map(state_map)
    u_adjoint = zeros(Float64, BlockB.edge_count(graph))
    for variable in 1:graph.n
        incident = graph.variable_edges[variable]
        isempty(incident) && continue
        total = sum(q_adjoint[edge] for edge in incident)
        if normalized === :full
            for edge in incident
                u_adjoint[edge] = total - q_adjoint[edge]
            end
        else
            value = (length(incident) - 1) / length(incident) * total
            for edge in incident
                u_adjoint[edge] = value
            end
        end
    end
    u_adjoint
end

function evaluate_target(graph, llr, u, state_map, target::Symbol)
    target === :product && return product_map(graph, llr, u, state_map)
    target === :exact_sum_product &&
        return BlockB.evaluate_map(graph, llr, u, state_map)
    throw(ArgumentError("unknown edge target $target"))
end

function edge_residual_objective(graph, llr, u, state_map, target::Symbol)
    evaluated = evaluate_target(graph, llr, u, state_map, target)
    residual = Float64.(u) .- evaluated.output
    0.5 * dot(residual, residual)
end

function edge_residual_gradient(graph, llr, u, state_map, target::Symbol)
    evaluated = evaluate_target(graph, llr, u, state_map, target)
    residual = Float64.(u) .- evaluated.output
    q_adjoint = target === :product ?
        product_check_vjp(graph, evaluated.q_used, residual) :
        BlockB.check_vjp(graph, evaluated.q_used, residual)
    jtr = variable_vjp(graph, q_adjoint, state_map)
    gradient = residual .- jtr
    (; objective=0.5 * dot(residual, residual), gradient, residual, evaluation=evaluated)
end

function finite_difference_gradient(graph, llr, u, state_map, target::Symbol;
                                    step::Float64=1.0e-6)
    numerical = zeros(Float64, length(u))
    plus = Float64.(u)
    minus = Float64.(u)
    for coordinate in eachindex(u)
        plus[coordinate] += step
        minus[coordinate] -= step
        numerical[coordinate] = (
            edge_residual_objective(graph, llr, plus, state_map, target) -
            edge_residual_objective(graph, llr, minus, state_map, target)) /
            (2step)
        plus[coordinate] = Float64(u[coordinate])
        minus[coordinate] = Float64(u[coordinate])
    end
    numerical
end

function shadow_state_null_gate(x::AbstractVector{Float64}, checks)
    before = copy(x)
    shadow = [zeros(Float64, length(check)) for check in checks]
    # The shadow is deliberately allocated and hashed but never read by the
    # projected-GD calculation.
    shadow_sha256 = scientific_sha256(shadow)
    after = copy(x)
    checks_out = Dict(
        "scalar_float_bits" => reinterpret(UInt64, before) == reinterpret(UInt64, after),
        "hard_decision" => BitVector(before .< 0.0) == BitVector(after .< 0.0),
        "shadow_allocated" => sum(length, shadow) > 0,
        "shadow_is_zero" => all(iszero, (value for row in shadow for value in row)),
    )
    Dict("passed" => all(values(checks_out)), "checks" => checks_out,
         "shadow_sha256" => shadow_sha256)
end

function independent_box_projection(values; lower::Float64=-1.0,
                                    upper::Float64=1.0)
    projected = Vector{Float64}(undef, length(values))
    for index in eachindex(values)
        value = Float64(values[index])
        projected[index] = value < lower ? lower : (value > upper ? upper : value)
    end
    projected
end

function enumerated_check_output(q::AbstractVector{<:Real}, target::Int)
    degree = length(q)
    1 <= target <= degree || throw(BoundsError(q, target))
    others = [index for index in 1:degree if index != target]
    even_weight = 0.0
    odd_weight = 0.0
    for pattern in 0:(1 << length(others))-1
        parity = false
        weight = 1.0
        for (position, index) in enumerate(others)
            bit = ((pattern >> (position - 1)) & 1) == 1
            probability_zero = inv(1.0 + exp(-Float64(q[index])))
            weight *= bit ? 1.0 - probability_zero : probability_zero
            parity = xor(parity, bit)
        end
        if parity
            odd_weight += weight
        else
            even_weight += weight
        end
    end
    log(even_weight / odd_weight)
end

function common_harness_gate(config)
    validation = config["validation"]
    step = Float64(get(validation, "finite_difference_step", 1.0e-6))
    tolerance = Float64(get(validation, "finite_difference_tolerance", 3.0e-6))
    graph = BlockB.GraphView([[1, 2, 3], [1, 3, 4], [1, 2, 4]], 4)
    llr = [1.3, -0.7, 0.45, -1.1]
    u = [0.07sin(edge) - 0.03cos(0.4edge)
         for edge in 1:BlockB.edge_count(graph)]
    records = Dict{String,Any}()
    derivative_passed = true
    for target in (:product, :exact_sum_product), state_map in (:qbar_tied, :full)
        analytic = edge_residual_gradient(graph, llr, u, state_map, target).gradient
        numerical = finite_difference_gradient(
            graph, llr, u, state_map, target; step)
        error = maximum(abs.(analytic .- numerical))
        key = "$(target)__$(state_map)"
        records[key] = Dict("maximum_absolute_error" => error,
                            "analytic_sha256" => BlockB.vector_sha256(analytic),
                            "numerical_sha256" => BlockB.vector_sha256(numerical))
        derivative_passed &= error <= tolerance
    end
    shadow = shadow_state_null_gate([0.2, -0.3, 0.7, -0.1], graph.checks)
    raw_trial = [-1.4, -1.0, -0.23, 0.0, 0.91, 1.0, 1.7]
    production_projection = clamp.(raw_trial, -1.0, 1.0)
    oracle_projection = independent_box_projection(raw_trial)
    projection_equal = reinterpret(UInt64, production_projection) ==
        reinterpret(UInt64, oracle_projection)

    check_q = [0.83, -0.51, 1.17, -0.29]
    check_graph = BlockB.GraphView([collect(1:4)], 4)
    exact_output = BlockB.evaluate_map(
        check_graph, check_q, zeros(4), :full).output
    enumerated_output = [enumerated_check_output(check_q, target)
                         for target in eachindex(check_q)]
    enumeration_error = maximum(abs.(exact_output .- enumerated_output))
    checks = Dict(
        "product_and_exact_derivatives" => derivative_passed,
        "shadow_state_null" => Bool(shadow["passed"]),
        "independent_box_projection" => projection_equal,
        "exact_local_check_enumeration" => enumeration_error <= 2.0e-12,
        "product_target_is_not_exact_target" =>
            product_map(graph, llr, u, :qbar_tied).output !=
            BlockB.evaluate_map(graph, llr, u, :qbar_tied).output,
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "derivative_records" => records, "shadow_gate" => shadow,
         "projection" => Dict(
             "production_sha256" => BlockB.vector_sha256(production_projection),
             "oracle_sha256" => BlockB.vector_sha256(oracle_projection)),
         "exact_check_enumeration" => Dict(
             "maximum_absolute_error" => enumeration_error,
             "exact_sha256" => BlockB.vector_sha256(exact_output),
             "enumerated_sha256" => BlockB.vector_sha256(enumerated_output)))
end

# ---------------------------------------------------------------------------
# Retained backend composition
# ---------------------------------------------------------------------------

struct BackendContext
    composition_config::Dict{String,Any}
    block_a_config::Dict{String,Any}
    block_b_config::Dict{String,Any}
    split::Dict{String,Any}
    native::Module
    modem
    code
    bp_modem
    bp_code
    graph::BlockB.GraphView
end

function source_paths(config, config_path)
    base = dirname(abspath(config_path))
    sources = config["sources"]
    Dict(
        "block_a_runner" => resolve_from(base, String(sources["block_a_runner"])),
        "block_a_config" => resolve_from(base, String(sources["block_a_config"])),
        "block_b_runner" => resolve_from(base, String(sources["block_b_runner"])),
        "block_b_config" => resolve_from(base, String(sources["block_b_config"])),
    )
end

function backend_context(config, config_path)
    paths = source_paths(config, config_path)
    aconfig = BlockA.load_config(paths["block_a_config"])
    bconfig = BlockB.load_config(paths["block_b_config"])
    # The retained source gates pin the package root to their historical live
    # worktree.  A frozen composition job must instead run from its archived
    # Jade project.  Validate that project here and retain the numerical source
    # hashes through the composition freeze rather than invoking a live-path
    # identity check.
    sources = config["sources"]
    if haskey(sources, "jade_project_repo")
        expected_root = resolve_from(dirname(abspath(config_path)),
            String(sources["jade_project_repo"]))
        loaded_root = realpath(dirname(dirname(pathof(JadeJcade))))
        realpath(expected_root) == loaded_root || throw(ArgumentError(
            "loaded JadeJcade root differs from the frozen composition project"))
    end
    for (key, path) in (("block_a_runner_sha256", BLOCK_A_RUNNER),
                        ("block_b_runner_sha256", BLOCK_B_RUNNER))
        haskey(sources, key) || continue
        file_sha256(path) == String(sources[key]) ||
            throw(ArgumentError("retained source hash changed for $key"))
    end
    v4_config = BlockA.V4.load_config(BlockA.v4_config_path(aconfig))
    split = BlockA.V4.load_split_config(v4_config)
    BlockA.Legacy.enforce_thread_environment(split)
    native_path = if haskey(sources, "archived_native_runner")
        resolve_from(dirname(abspath(config_path)),
            String(sources["archived_native_runner"]))
    else
        String(bconfig["sources"]["archived_native_runner"])
    end
    if haskey(sources, "archived_native_runner_sha256")
        file_sha256(native_path) == String(sources["archived_native_runner_sha256"]) ||
            throw(ArgumentError("archived native runner hash changed"))
    end
    if !isdefined(@__MODULE__, :AWGNThreeReceivers)
        Base.include(@__MODULE__, native_path)
    end
    native = Base.invokelatest(() -> getfield(@__MODULE__, :AWGNThreeReceivers))
    generated = BlockA.Split.make_code(split, native)
    bp = BlockA.make_bp_code(split, Int(bconfig["native_endpoint_gate"][
        "maximum_message_passing_iterations"]))
    graph = BlockB.graph_view(generated.code)
    BlockB.graph_sha256(generated.code.check_vars) ==
        String(bconfig["code"]["graph_sha256"]) ||
        throw(ArgumentError("Block A and Block B graph identities differ"))
    BackendContext(config, aconfig, bconfig, split, native,
                   generated.modem, generated.code, bp.modem, bp.code, graph)
end

function channel_section(config, label::AbstractString)
    channels = config["channels"]
    haskey(channels, label) || throw(ArgumentError("missing channel $label"))
    channels[label]
end

function generate_input(context::BackendContext, frame::Int, channel_label::String)
    section = channel_section(context.composition_config, channel_label)
    variance = Float64(section["noise_variance"])
    seed_base = Int(get(section, "noise_seed_base",
                        context.split["channel"]["noise_seed_base"]))
    seed = seed_base + frame
    n = Int(context.split["code"]["n"])
    symbols = BlockA.Legacy.native_call(
        context.native, :qpsk_symbols, ones(Float64, n))
    rng = MersenneTwister(seed)
    unit_noise = complex.(randn(rng, length(symbols)),
                          randn(rng, length(symbols))) ./ sqrt(2.0)
    received = symbols .+ sqrt(variance) .* unit_noise
    raw_llr = BlockA.Legacy.native_call(
        context.native, :awgn_llrs, received, variance)
    clip = Float64(get(section, "llr_clip", 20.0))
    llr = clamp.(Float64.(raw_llr), -clip, clip)
    (; frame, channel_label, snr_db=Float64(section["snr_db"]), variance,
       seed, llr, llr_sha256=BlockB.vector_sha256(llr),
       received_sha256=BlockB.vector_sha256(received),
       unit_noise_sha256=BlockB.vector_sha256(unit_noise))
end

function composition_block_a_config(context::BackendContext)
    config = deepcopy(context.block_a_config)
    config["solver"]["maximum_update_attempts"] = 30
    config["solver"]["score_updates"] = [30]
    config["validation"]["finite_difference_updates"] = [2, 30]
    config
end

function shadow_trajectory_gate(primary, shadow, primary_oracle_gate,
                                shadow_oracle_gate, inactive_shadow)
    float_bits_equal(left, right) =
        reinterpret(UInt64, [Float64(left)]) ==
        reinterpret(UInt64, [Float64(right)])
    primary_x_sha256 = BlockB.vector_sha256(primary.x)
    shadow_x_sha256 = BlockB.vector_sha256(shadow.x)
    primary_delta_sha256 = BlockA.Legacy.edge_sha256(primary.delta)
    shadow_delta_sha256 = BlockA.Legacy.edge_sha256(shadow.delta)
    primary_trace_sha256 = scientific_sha256(primary.trace)
    shadow_trace_sha256 = scientific_sha256(shadow.trace)
    primary_terms_sha256 = scientific_sha256(primary.terminal_terms)
    shadow_terms_sha256 = scientific_sha256(shadow.terminal_terms)
    inactive_shadow_sha256 = BlockA.Legacy.edge_sha256(inactive_shadow)
    checks = Dict(
        "inactive_shadow_allocated" => sum(length, inactive_shadow) > 0,
        "inactive_shadow_zero" => all(iszero,
            (value for row in inactive_shadow for value in row)),
        "terminal_scalar_float_bits" =>
            reinterpret(UInt64, primary.x) == reinterpret(UInt64, shadow.x),
        "terminal_offsets" => primary_delta_sha256 == shadow_delta_sha256,
        "hard_word" => primary.hard == shadow.hard,
        "syndrome" => primary.syndrome == shadow.syndrome,
        "accepted_steps" => primary.accepted_steps == shadow.accepted_steps,
        "requested_steps" => primary.requested_steps == shadow.requested_steps,
        "stop_status" => primary.status == shadow.status,
        "objective_trace" => primary_trace_sha256 == shadow_trace_sha256,
        "initial_loss_float_bits" =>
            float_bits_equal(primary.initial_loss, shadow.initial_loss),
        "last_accepted_loss_float_bits" => float_bits_equal(
            primary.last_accepted_fixed_offset_loss,
            shadow.last_accepted_fixed_offset_loss),
        "terminal_refreshed_loss_float_bits" => float_bits_equal(
            primary.terminal_refreshed_loss, shadow.terminal_refreshed_loss),
        "terminal_terms" => primary_terms_sha256 == shadow_terms_sha256,
        "primary_native_oracle" => Bool(primary_oracle_gate["passed"]),
        "shadow_native_oracle" => Bool(shadow_oracle_gate["passed"]),
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "inactive_shadow_sha256" => inactive_shadow_sha256,
        "primary_terminal_scalar_sha256" => primary_x_sha256,
        "shadow_terminal_scalar_sha256" => shadow_x_sha256,
        "primary_terminal_offsets_sha256" => primary_delta_sha256,
        "shadow_terminal_offsets_sha256" => shadow_delta_sha256,
        "primary_trace_sha256" => primary_trace_sha256,
        "shadow_trace_sha256" => shadow_trace_sha256,
        "primary_terminal_terms_sha256" => primary_terms_sha256,
        "shadow_terminal_terms_sha256" => shadow_terms_sha256,
    )
end

function native_gd_and_oracle(context::BackendContext, llr)
    split = context.split
    problem = BlockA.BridgeProblem(context.code, llr;
        parity_weight=Float64(split["projected_gradient"]["parity_weight"]),
        binary_weight=Float64(split["projected_gradient"]["binary_weight"]))
    initial = tanh.(llr ./ 2.0)
    result = BlockA.Split.solve_variant(
        problem, context.code, initial, BlockA.Split.REQUIRED_ARMS[1];
        maximum_updates=30,
        initial_step=Float64(split["projected_gradient"]["initial_step"]),
        maximum_backtracks=Int(split["projected_gradient"]["maximum_backtracks"]),
        collect_trace=true, collect_diagnostics=true,
        validate_derivatives=false,
        mean_tolerance=Float64(split["validation"]["mean_offset_tolerance"]),
        box_tolerance=Float64(split["validation"]["box_tolerance"]))
    native_problem = BlockA.Legacy.native_call(
        context.native, :ScalarProblem, context.code, llr;
        parity_weight=Float64(split["projected_gradient"]["parity_weight"]),
        binary_weight=Float64(split["projected_gradient"]["binary_weight"]))
    oracle = BlockA.Legacy.native_trace(
        context.native, native_problem, initial;
        maximum_updates=30,
        initial_step=Float64(split["projected_gradient"]["initial_step"]),
        maximum_backtracks=Int(split["projected_gradient"]["maximum_backtracks"]))
    gate = BlockA.Legacy.control_oracle_comparison(result, oracle)
    inactive_shadow = [zeros(Float64, length(check))
                       for check in context.code.check_vars]
    shadow_result = BlockA.Split.solve_variant(
        problem, context.code, initial, BlockA.Split.REQUIRED_ARMS[1];
        maximum_updates=30,
        initial_step=Float64(split["projected_gradient"]["initial_step"]),
        maximum_backtracks=Int(split["projected_gradient"]["maximum_backtracks"]),
        collect_trace=true, collect_diagnostics=true,
        validate_derivatives=false,
        mean_tolerance=Float64(split["validation"]["mean_offset_tolerance"]),
        box_tolerance=Float64(split["validation"]["box_tolerance"]))
    shadow_oracle_gate = BlockA.Legacy.control_oracle_comparison(
        shadow_result, oracle)
    shadow_gate = shadow_trajectory_gate(
        result, shadow_result, gate, shadow_oracle_gate, inactive_shadow)
    (; result, shadow_result, oracle, gate, shadow_oracle_gate, shadow_gate,
       initial)
end

function run_block_a_rungs(context::BackendContext, llr; include_extra::Bool=false)
    config = composition_block_a_config(context)
    problem = BlockA.V4.problem_for(context.split, context.code, llr)
    initial = tanh.(llr ./ 2.0)
    seed = BlockA.common_update_one(
        problem, context.code, initial, context.split, config)
    wanted = include_extra ? Set(("compound__box", "product_only__box",
        "compound__unconstrained", "product_only__unconstrained")) :
        Set(("compound__box", "product_only__box", "product_only__unconstrained"))
    results = Dict{String,Any}()
    for spec in BlockA.ARMS
        spec.name in wanted || continue
        results[spec.name] = BlockA.solve_arm(
            problem, context.code, initial, seed, spec, config)
    end
    (; results, seed)
end

function run_product_edge(context::BackendContext, llr;
                          state_map::Symbol=:qbar_tied,
                          operator::Symbol=:residual_gradient)
    graph = context.graph
    config = context.block_b_config
    attempts = Int(config["budget"]["update_attempts_per_arm"])
    gradient_config = config["gradient"]
    u = zeros(Float64, BlockB.edge_count(graph))
    rows = NamedTuple[]
    first_valid = 0
    first_exact = 0
    accepted_updates = 0
    for update in 1:attempts
        current = edge_residual_gradient(graph, llr, u, state_map, :product)
        objective_before = current.objective
        accepted = false
        step_size = 0.0
        backtracks = 0
        objective_after = objective_before
        if operator === :direct
            u = copy(current.evaluation.output)
            accepted = true
            step_size = 1.0
            objective_after = edge_residual_objective(
                graph, llr, u, state_map, :product)
        elseif operator === :residual_gradient
            alpha = Float64(gradient_config["initial_step"])
            factor = Float64(gradient_config["backtrack_factor"])
            armijo = Float64(gradient_config["armijo_c"])
            maximum = Int(gradient_config["maximum_backtracks"])
            norm_squared = dot(current.gradient, current.gradient)
            for backtrack in 0:maximum
                trial = u .- alpha .* current.gradient
                trial_objective = edge_residual_objective(
                    graph, llr, trial, state_map, :product)
                if isfinite(trial_objective) &&
                   trial_objective < objective_before &&
                   trial_objective <= objective_before - armijo * alpha * norm_squared
                    u = trial
                    accepted = true
                    step_size = alpha
                    backtracks = backtrack
                    objective_after = trial_objective
                    break
                end
                alpha *= factor
                backtracks = backtrack + 1
            end
        else
            throw(ArgumentError("unknown product-edge operator $operator"))
        end
        accepted_updates += accepted
        state = BlockB.decision_state(graph, llr, u, state_map)
        first_valid == 0 && state.parity_valid && (first_valid = update)
        first_exact == 0 && state.exact_word && (first_exact = update)
        push!(rows, (; update, accepted, objective_before, objective_after,
            gradient_norm=norm(current.gradient), step_size, backtracks,
            state_sha256=BlockB.vector_sha256(u),
            hard_word_sha256=BlockB.vector_sha256(state.hard),
            syndrome_weight=state.syndrome_weight,
            parity_valid=state.parity_valid,
            transmitted_word_equal=state.exact_word))
    end
    terminal = BlockB.decision_state(graph, llr, u, state_map)
    (; u, terminal, rows, first_valid_update=first_valid,
       first_exact_update=first_exact, accepted_updates,
       status="fixed_30_attempts")
end

function run_exact_direct_endpoint_oracle(
        graph::BlockB.GraphView, llr;
        fixed_attempts::Int=30, endpoint_attempts::Int=80,
        frame::Int=0, stage::String="unit")
    0 < fixed_attempts <= endpoint_attempts || throw(ArgumentError(
        "fixed-attempt rung must not exceed endpoint-oracle budget"))
    u = zeros(Float64, BlockB.edge_count(graph))
    rows = NamedTuple[]
    first_valid_update = 0
    first_exact_update = 0
    first_valid_snapshot = nothing
    fixed_u = nothing
    fixed_terminal = nothing
    fixed_first_valid = 0
    fixed_first_exact = 0
    terminal_snapshot = nothing
    for update in 1:endpoint_attempts
        evaluation = BlockB.evaluate_map(graph, llr, u, :full)
        residual = u .- evaluation.output
        objective_before = 0.5 * dot(residual, residual)
        u = copy(evaluation.output)
        objective_after = BlockB.residual_objective(graph, llr, u, :full)
        state = BlockB.decision_state(graph, llr, u, :full)
        terminal_snapshot = (;
            hard=copy(state.hard),
            lpost_metric=copy(state.lpost_metric),
            q=copy(state.q), u=copy(u),
            syndrome_weight=state.syndrome_weight)
        if state.parity_valid && first_valid_update == 0
            first_valid_update = update
            first_valid_snapshot = (;
                update, hard=copy(state.hard),
                lpost_metric=copy(state.lpost_metric),
                q=copy(state.q), u=copy(u),
                syndrome_weight=state.syndrome_weight)
        end
        state.exact_word && first_exact_update == 0 &&
            (first_exact_update = update)
        push!(rows, (;
            stage, frame, arm="full__direct_endpoint_oracle",
            state_map="full", update_operator="direct",
            update, objective_before, objective_after,
            gradient_norm=0.0, step_size=1.0, backtracks=0,
            accepted=true, parity_valid=state.parity_valid,
            exact_word=state.exact_word,
            coded_bit_errors=state.coded_bit_errors,
            syndrome_weight=state.syndrome_weight,
            hard_word_sha256=BlockB.vector_sha256(state.hard)))
        if update == fixed_attempts
            fixed_u = copy(u)
            fixed_terminal = state
            fixed_first_valid = first_valid_update
            fixed_first_exact = first_exact_update
        end
    end
    rung = (;
        u=fixed_u, terminal=fixed_terminal,
        iteration_rows=rows[1:fixed_attempts],
        first_valid_update=fixed_first_valid,
        first_exact_update=fixed_first_exact,
        accepted_updates=fixed_attempts,
        status="fixed_$(fixed_attempts)_attempts")
    endpoint = (;
        first_valid_snapshot, first_valid_update,
        first_exact_update, endpoint_attempts,
        terminal_snapshot,
        iteration_rows=rows)
    (; rung, endpoint)
end

function native_bp_endpoint_gate(graph::BlockB.GraphView, endpoint, native)
    if native.valid
        gate = BlockB.endpoint_gate(graph, endpoint, native)
        gate["mode"] = "first_valid_stopping_endpoint"
        return gate
    end
    terminal = endpoint.terminal_snapshot
    native_q = BlockB.flatten_rows(native.q)
    native_u = BlockB.flatten_rows(native.u)
    checks = Dict(
        "both_invalid" => endpoint.first_valid_snapshot === nothing && !native.valid,
        "iteration_cap" => endpoint.endpoint_attempts == native.iterations,
        "hard_word" => terminal.hard == native.hard,
        "posterior_float_bits" =>
            BlockB.float_bits_equal(terminal.lpost_metric, native.lpost_metric),
        "variable_to_check_float_bits" =>
            BlockB.float_bits_equal(terminal.q, native_q),
        "check_to_variable_float_bits" =>
            BlockB.float_bits_equal(terminal.u, native_u),
        "syndrome_weight" =>
            terminal.syndrome_weight == native.syndrome_weight,
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "mode" => "invalid_iteration_cap_terminal_endpoint",
        "native_iteration" => native.iterations,
        "direct_endpoint_attempts" => endpoint.endpoint_attempts,
    )
end

function rung_from_scalar(id, result; backend::String)
    state_hash = scientific_sha256(Dict(
        "x" => BlockB.vector_sha256(result.x),
        "delta" => BlockA.Legacy.edge_sha256(result.delta)))
    (; id, backend, hard=copy(result.hard),
       parity_valid=Bool(result.parity_valid),
       transmitted_word_equal=Bool(result.transmitted_word_equal),
       coded_bit_errors=Int(result.coded_bit_errors),
       syndrome_weight=Int(result.syndrome_weight),
       state_sha256=state_hash, hard_word_sha256=BlockB.vector_sha256(result.hard),
       updates=Int(result.accepted_steps), status=String(result.status),
       first_valid_update=-1, first_exact_update=-1)
end

function rung_from_block_a(id, result)
    checkpoint = result.checkpoints[30]
    (; id, backend="block_a", hard=copy(result.terminal_metrics.hard),
       parity_valid=Bool(checkpoint.parity_valid),
       transmitted_word_equal=Bool(checkpoint.transmitted_word_equal),
       coded_bit_errors=Int(checkpoint.coded_bit_errors),
       syndrome_weight=Int(checkpoint.syndrome_weight),
       state_sha256=scientific_sha256(Dict(
           "x" => checkpoint.terminal_scalar_sha256,
           "delta" => checkpoint.terminal_offset_sha256)),
       hard_word_sha256=String(checkpoint.hard_word_sha256),
       updates=Int(checkpoint.effective_update), status=String(result.status),
       first_valid_update=result.first_valid_update === nothing ? -1 :
           Int(result.first_valid_update),
       first_exact_update=result.first_exact_update === nothing ? -1 :
           Int(result.first_exact_update))
end

function rung_from_edge(id, result; backend::String)
    terminal = result.terminal
    (; id, backend, hard=copy(terminal.hard),
       parity_valid=Bool(terminal.parity_valid),
       transmitted_word_equal=Bool(terminal.exact_word),
       coded_bit_errors=Int(terminal.coded_bit_errors),
       syndrome_weight=Int(terminal.syndrome_weight),
       state_sha256=BlockB.vector_sha256(result.u),
       hard_word_sha256=BlockB.vector_sha256(terminal.hard),
       updates=30, status="fixed_30_attempts",
       first_valid_update=Int(result.first_valid_update),
       first_exact_update=Int(result.first_exact_update))
end

function rung_from_native_bp(native)
    (; id="native_exact_sum_product", backend="native_bp",
       hard=copy(native.hard), parity_valid=Bool(native.valid),
       transmitted_word_equal=Bool(native.exact_word),
       coded_bit_errors=Int(native.coded_bit_errors),
       syndrome_weight=Int(native.syndrome_weight),
       state_sha256=scientific_sha256(Dict(
           "q" => BlockA.Legacy.edge_sha256(native.q),
           "u" => BlockA.Legacy.edge_sha256(native.u))),
       hard_word_sha256=BlockB.vector_sha256(native.hard),
       updates=Int(native.iterations), status="zero_syndrome_or_limit",
       first_valid_update=Bool(native.valid) ? Int(native.iterations) : 0,
       first_exact_update=Bool(native.exact_word) ? Int(native.iterations) : 0)
end

function rung_from_stop30(direct_runs; cap::Int=30)
    endpoint = direct_runs.endpoint
    fixed = direct_runs.rung
    snapshot = endpoint.first_valid_snapshot
    stopped_valid = snapshot !== nothing && Int(snapshot.update) <= cap
    if stopped_valid
        hard = copy(snapshot.hard)
        q = copy(snapshot.q)
        u = copy(snapshot.u)
        syndrome_weight = Int(snapshot.syndrome_weight)
        updates = Int(snapshot.update)
        lpost_metric = copy(snapshot.lpost_metric)
    else
        terminal = fixed.terminal
        hard = copy(terminal.hard)
        q = copy(terminal.q)
        u = copy(fixed.u)
        syndrome_weight = Int(terminal.syndrome_weight)
        updates = cap
        lpost_metric = copy(terminal.lpost_metric)
    end
    (; id="exact_sp_direct_full_stop30", backend="block_b", hard,
       parity_valid=syndrome_weight == 0,
       transmitted_word_equal=!any(hard),
       coded_bit_errors=count(hard), syndrome_weight,
       state_sha256=scientific_sha256(Dict(
           "q" => BlockB.vector_sha256(q),
           "u" => BlockB.vector_sha256(u),
           "posterior" => BlockB.vector_sha256(lpost_metric))),
       hard_word_sha256=BlockB.vector_sha256(hard), updates,
       status=stopped_valid ? "first_zero_syndrome" : "iteration_cap_30",
       first_valid_update=stopped_valid ? updates : 0,
       first_exact_update=!any(hard) ? updates : 0)
end

function runtime_rung_identity_gate(rungs)
    checks = Dict{String,Bool}()
    checks["complete_id_set"] = Set(keys(rungs)) == Set(FORWARD_ORDER)
    for id in FORWARD_ORDER
        present = haskey(rungs, id)
        checks["$(id)__present"] = present
        checks["$(id)__embedded_id"] = present && String(rungs[id].id) == id
        checks["$(id)__backend"] = present &&
            String(rungs[id].backend) == EXPECTED_BACKENDS[id]
    end
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function iteration_rows_for(frame, label, id, result)
    rows = NamedTuple[]
    if hasproperty(result, :rows)
        for row in result.rows
            push!(rows, (; channel=label, frame, rung_id=id,
                update=Int(row.update), accepted=Bool(row.accepted),
                objective_before=Float64(row.objective_before),
                objective_after=Float64(row.objective_after),
                state_sha256=String(row.state_sha256),
                hard_word_sha256=String(row.hard_word_sha256),
                syndrome_weight=Int(row.syndrome_weight),
                parity_valid=Bool(row.parity_valid),
                transmitted_word_equal=Bool(row.transmitted_word_equal)))
        end
    elseif hasproperty(result, :iteration_rows)
        for row in result.iteration_rows
            push!(rows, (; channel=label, frame, rung_id=id,
                update=Int(row.update), accepted=Bool(row.accepted),
                objective_before=Float64(row.objective_before),
                objective_after=Float64(row.objective_after),
                state_sha256=nothing,
                hard_word_sha256=String(row.hard_word_sha256),
                syndrome_weight=Int(row.syndrome_weight),
                parity_valid=Bool(row.parity_valid),
                transmitted_word_equal=Bool(row.exact_word)))
        end
    elseif hasproperty(result, :traces)
        for row in result.traces
            push!(rows, (; channel=label, frame, rung_id=id,
                update=Int(row.update), accepted=Bool(row.accepted),
                objective_before=Float64(row.loss_before),
                objective_after=Float64(row.loss_after),
                state_sha256=String(row.x_after_sha256),
                hard_word_sha256=nothing,
                syndrome_weight=Int(row.syndrome_weight),
                parity_valid=Bool(row.parity_valid),
                transmitted_word_equal=Bool(row.transmitted_word_equal)))
        end
    elseif hasproperty(result, :trace)
        for row in result.trace
            push!(rows, (; channel=label, frame, rung_id=id,
                update=Int(row["update"]), accepted=Bool(row["accepted"]),
                objective_before=Float64(row["loss_before"]),
                objective_after=Float64(row["accepted_fixed_offset_loss"]),
                state_sha256=String(row["x_after_sha256"]),
                hard_word_sha256=nothing, syndrome_weight=nothing,
                parity_valid=nothing, transmitted_word_equal=nothing))
        end
    end
    rows
end

function compute_frame(context::BackendContext, input; include_controls::Bool=false)
    gd = native_gd_and_oracle(context, input.llr)
    Bool(gd.gate["passed"]) || error("native projected-GD endpoint gate failed")
    shadow_gate = gd.shadow_gate
    Bool(shadow_gate["passed"]) || error("shadow-state null gate failed")
    a = run_block_a_rungs(context, input.llr; include_extra=include_controls)
    product = run_product_edge(context, input.llr)
    tied_residual = BlockB.run_arm(context.block_b_config, context.graph,
        input.llr, "qbar_tied__residual_gradient";
        frame=input.frame, stage=input.channel_label)
    full_residual = BlockB.run_arm(context.block_b_config, context.graph,
        input.llr, "full__residual_gradient";
        frame=input.frame, stage=input.channel_label)
    direct_runs = run_exact_direct_endpoint_oracle(
        context.graph, input.llr;
        fixed_attempts=Int(context.block_b_config["budget"][
            "update_attempts_per_arm"]),
        endpoint_attempts=Int(context.block_b_config["native_endpoint_gate"][
            "maximum_message_passing_iterations"]),
        frame=input.frame, stage=input.channel_label)
    full_direct = direct_runs.rung
    tied_direct = include_controls ? BlockB.run_arm(
        context.block_b_config, context.graph, input.llr, "qbar_tied__direct";
        frame=input.frame, stage=input.channel_label) : nothing
    native_bp = BlockB.native_decode(context.bp_modem, context.bp_code, input.llr)
    bp_gate = native_bp_endpoint_gate(
        context.graph, direct_runs.endpoint, native_bp)
    Bool(bp_gate["passed"]) || error("native exact-sum-product endpoint gate failed")

    native_rung = rung_from_scalar(
        "native_projected_gd", gd.result; backend="native_gd")
    shadow_rung_base = rung_from_scalar(
        "shadow_edge_state", gd.shadow_result; backend="shadow")
    shadow_rung = merge(shadow_rung_base, (;
        state_sha256=scientific_sha256(Dict(
            "native_scalar" => shadow_rung_base.state_sha256,
            "inactive_shadow" => shadow_gate["inactive_shadow_sha256"]))))
    rungs = Dict{String,Any}(
        native_rung.id => native_rung,
        shadow_rung.id => shadow_rung,
        "assigned_frozen_compound_box" => rung_from_block_a(
            "assigned_frozen_compound_box", a.results["compound__box"]),
        "assigned_frozen_product_box" => rung_from_block_a(
            "assigned_frozen_product_box", a.results["product_only__box"]),
        "assigned_frozen_product_unconstrained" => rung_from_block_a(
            "assigned_frozen_product_unconstrained",
            a.results["product_only__unconstrained"]),
        "edge_product_residual_gradient_tied" => rung_from_edge(
            "edge_product_residual_gradient_tied", product;
            backend="product_edge"),
        "exact_sp_residual_gradient_tied" => rung_from_edge(
            "exact_sp_residual_gradient_tied", tied_residual;
            backend="block_b"),
        "exact_sp_residual_gradient_full" => rung_from_edge(
            "exact_sp_residual_gradient_full", full_residual;
            backend="block_b"),
        "exact_sp_direct_full_fixed30" => rung_from_edge(
            "exact_sp_direct_full_fixed30", full_direct;
            backend="block_b"),
        "exact_sp_direct_full_stop30" => rung_from_stop30(direct_runs),
        "native_exact_sum_product" => rung_from_native_bp(native_bp),
    )
    controls = Dict{String,Any}()
    if include_controls
        controls["assigned_frozen_compound_unconstrained"] = rung_from_block_a(
            "assigned_frozen_compound_unconstrained",
            a.results["compound__unconstrained"])
        controls["exact_sp_direct_tied_fixed30"] = rung_from_edge(
            "exact_sp_direct_tied_fixed30", tied_direct; backend="block_b")
    end

    rung_identity_gate = runtime_rung_identity_gate(rungs)
    Bool(rung_identity_gate["passed"]) ||
        error("runtime rung identity/backend gate failed")

    iterations = NamedTuple[]
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "native_projected_gd", gd.result))
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "shadow_edge_state", gd.shadow_result))
    for (id, arm) in (("assigned_frozen_compound_box", "compound__box"),
                      ("assigned_frozen_product_box", "product_only__box"),
                      ("assigned_frozen_product_unconstrained",
                       "product_only__unconstrained"))
        append!(iterations, iteration_rows_for(
            input.frame, input.channel_label, id, a.results[arm]))
    end
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "edge_product_residual_gradient_tied", product))
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "exact_sp_residual_gradient_tied", tied_residual))
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "exact_sp_residual_gradient_full", full_residual))
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "exact_sp_direct_full_fixed30", full_direct))
    stop_update = min(30, direct_runs.endpoint.first_valid_update == 0 ? 30 :
        direct_runs.endpoint.first_valid_update)
    stop_trace = (iteration_rows=
        direct_runs.endpoint.iteration_rows[1:stop_update],)
    append!(iterations, iteration_rows_for(input.frame, input.channel_label,
        "exact_sp_direct_full_stop30", stop_trace))
    if include_controls
        append!(iterations, iteration_rows_for(input.frame, input.channel_label,
            "assigned_frozen_compound_unconstrained",
            a.results["compound__unconstrained"]))
        append!(iterations, iteration_rows_for(input.frame, input.channel_label,
            "exact_sp_direct_tied_fixed30", tied_direct))
    end
    (; rungs, controls, iterations, gd_gate=gd.gate, bp_gate, shadow_gate,
       rung_identity_gate)
end

# ---------------------------------------------------------------------------
# Scientific tables, attribution ledger, and job execution
# ---------------------------------------------------------------------------

function frame_row(input, rung)
    (; channel=input.channel_label, snr_db=input.snr_db, frame=input.frame,
       noise_seed=input.seed, llr_sha256=input.llr_sha256,
       received_sha256=input.received_sha256, rung_id=rung.id,
       backend=rung.backend, parity_valid=rung.parity_valid,
       transmitted_word_equal=rung.transmitted_word_equal,
       coded_bit_errors=rung.coded_bit_errors,
       syndrome_weight=rung.syndrome_weight,
       updates=rung.updates, status=rung.status,
       first_valid_update=rung.first_valid_update,
       first_exact_update=rung.first_exact_update,
       state_sha256=rung.state_sha256,
       hard_word_sha256=rung.hard_word_sha256)
end

function case_specs(config, job_id)
    frames = config["frames"]
    range(name) = Int(frames[name * "_first"]):Int(frames[name * "_last"])
    if job_id == "03_native_endpoint_and_rung_gate"
        return [("six_db", frame) for frame in range("endpoint_gate")]
    elseif job_id == "04_fresh_dual_snr_anchor"
        return vcat([("six_db", frame) for frame in range("anchor")],
                    [("second_snr", frame) for frame in range("anchor")])
    elseif job_id == "05_six_db_forward_transfer"
        return [("six_db", frame) for frame in range("six_db")]
    elseif job_id == "06_six_db_order_controls_and_attribution"
        return vcat([("six_db", frame) for frame in range("six_db")],
                    [("six_db", frame) for frame in range("locked")])
    elseif job_id == "07_second_snr_confirmation"
        return [("second_snr", frame) for frame in range("second_snr")]
    end
    Tuple{String,Int}[]
end

function transition_ledger(frame_rows)
    lookup = Dict((row.channel, row.frame, row.rung_id) => row for row in frame_rows)
    cases = sort!(unique((row.channel, row.frame) for row in frame_rows))
    records = Dict{String,Any}[]
    total_net = 0
    for index in 1:length(FORWARD_ORDER)-1
        from = FORWARD_ORDER[index]
        to = FORWARD_ORDER[index + 1]
        gained = 0
        lost = 0
        both_success = 0
        both_failure = 0
        for case in cases
            before = lookup[(case..., from)].transmitted_word_equal
            after = lookup[(case..., to)].transmitted_word_equal
            gained += !before && after
            lost += before && !after
            both_success += before && after
            both_failure += !before && !after
        end
        net = gained - lost
        total_net += net
        joint = from == JOINT_FROM && to == JOINT_TO
        push!(records, Dict(
            "from" => from, "to" => to,
            "newly_recovered" => gained, "previous_successes_lost" => lost,
            "net_recovery_change" => net,
            "both_success" => both_success,
            "to_only_success" => gained,
            "from_only_success" => lost,
            "both_failure" => both_failure,
            "pairs" => length(cases),
            "risk_difference_to_minus_from" => net / length(cases),
            "atomic" => !joint, "attributable" => !joint,
        ))
    end
    native_gd = count(case -> lookup[(case..., FORWARD_ORDER[1])].transmitted_word_equal,
                      cases)
    native_bp = count(case -> lookup[(case..., FORWARD_ORDER[end])].transmitted_word_equal,
                      cases)
    Dict(
        "case_count" => length(cases),
        "native_projected_gd_successes" => native_gd,
        "native_exact_sum_product_successes" => native_bp,
        "native_net_gap" => native_bp - native_gd,
        "transition_net_sum" => total_net,
        "native_gap_accounted" => total_net == native_bp - native_gd,
        "atomic_causal_decomposition_complete" => false,
        "non_atomic_transition" => JOINT_FROM * " -> " * JOINT_TO,
        "transitions" => records,
    )
end

function paired_transition_inference(ledger, config)
    inference = config["inference"]
    confidence = Float64(inference["simultaneous_interval_confidence_level"])
    records = Dict{String,Any}()
    pvalues = Dict{String,Float64}()
    for transition in ledger["transitions"]
        Bool(transition["attributable"]) || continue
        id = String(transition["from"]) * "__to__" * String(transition["to"])
        counts = Dict{String,Any}(
            "both_success" => Int(transition["both_success"]),
            "active_only_success" => Int(transition["to_only_success"]),
            "control_only_success" => Int(transition["from_only_success"]),
            "both_failure" => Int(transition["both_failure"]),
        )
        pvalue = BlockA.Legacy.mcnemar_exact_pvalue(counts)
        interval = BlockA.Legacy.newcombe_paired_interval(
            counts; confidence_level=confidence)
        pvalues[id] = pvalue
        records[id] = Dict(
            "from" => transition["from"],
            "to" => transition["to"],
            "paired_counts" => counts,
            "risk_difference_to_minus_from" =>
                Float64(transition["risk_difference_to_minus_from"]),
            "mcnemar_exact_two_sided_pvalue" => pvalue,
            "newcombe_interval" => interval,
        )
    end
    length(records) == Int(inference["atomic_transition_count"]) ||
        error("paired inference did not receive exactly the atomic transitions")
    adjusted = BlockA.Legacy.holm_adjust(pvalues)
    for (id, value) in adjusted
        records[id]["holm_adjusted_pvalue"] = value
    end
    non_atomic = only(filter(
        transition -> !Bool(transition["attributable"]),
        ledger["transitions"]))
    Dict(
        "applied" => true,
        "familywise_alpha" => Float64(inference["familywise_alpha"]),
        "family_size" => length(records),
        "holm_family" => String(inference["holm_family"]),
        "simultaneous_interval_confidence_level" => confidence,
        "non_atomic_handoff_included" => false,
        "records" => records,
        "non_atomic_handoff" => Dict(
            "from" => non_atomic["from"],
            "to" => non_atomic["to"],
            "descriptive_only" => true,
            "newly_recovered" => non_atomic["newly_recovered"],
            "previous_successes_lost" =>
                non_atomic["previous_successes_lost"],
            "risk_difference_to_minus_from" =>
                non_atomic["risk_difference_to_minus_from"],
        ),
    )
end

function factorial_controls(frame_rows)
    lookup = Dict((row.channel, row.frame, row.rung_id) => row for row in frame_rows)
    cases = sort!(unique((row.channel, row.frame) for row in frame_rows))
    success(case, rung) = lookup[(case..., rung)].transmitted_word_equal ? 1 : 0
    a_values = Int[]
    b_values = Int[]
    for case in cases
        # d - c - b + a for the retained Block A 2x2.
        push!(a_values,
            success(case, "assigned_frozen_product_unconstrained") -
            success(case, "assigned_frozen_compound_unconstrained") -
            success(case, "assigned_frozen_product_box") +
            success(case, "assigned_frozen_compound_box"))
        # full/direct - tied/direct - full/gradient + tied/gradient.
        push!(b_values,
            success(case, "exact_sp_direct_full_fixed30") -
            success(case, "exact_sp_direct_tied_fixed30") -
            success(case, "exact_sp_residual_gradient_full") +
            success(case, "exact_sp_residual_gradient_tied"))
    end
    Dict(
        "block_a_parity_by_projection_interaction_count" => sum(a_values),
        "block_a_nonzero_case_interactions" => count(!iszero, a_values),
        "block_b_state_by_operator_interaction_count" => sum(b_values),
        "block_b_nonzero_case_interactions" => count(!iszero, b_values),
        "interaction_detected" =>
            any(!iszero, a_values) || any(!iszero, b_values),
        "path_conditional_attribution_required" =>
            any(!iszero, a_values) || any(!iszero, b_values),
        "reverse_composition_across_joint_handoff_run" => false,
    )
end

function job6_evidence_groups(frame_rows, config)
    frames = config["frames"]
    fresh_range = Int(frames["six_db_first"]):Int(frames["six_db_last"])
    locked_range = Int(frames["locked_first"]):Int(frames["locked_last"])
    groups = Dict(
        "six_db_transfer" => [row for row in frame_rows
                              if row.frame in fresh_range],
        "locked_attribution" => [row for row in frame_rows
                                 if row.frame in locked_range],
    )
    expected = Dict("six_db_transfer" => length(fresh_range),
                    "locked_attribution" => length(locked_range))
    ledgers = Dict{String,Any}()
    controls = Dict{String,Any}()
    for name in ("six_db_transfer", "locked_attribution")
        rows = groups[name]
        cases = unique((row.channel, row.frame) for row in rows)
        length(cases) == expected[name] || error(
            "$name contains $(length(cases)) cases, expected $(expected[name])")
        forward = [row for row in rows if row.rung_id in FORWARD_ORDER]
        ledgers[name] = transition_ledger(forward)
        controls[name] = factorial_controls(rows)
    end
    (; ledgers, controls)
end

function locked_endpoint_reproduction_gate(ledgers, config)
    observed = ledgers["locked_attribution"]
    registered = config["job6"]["locked_expected"]
    checks = Dict(
        "case_count" => Int(observed["case_count"]) ==
            Int(registered["case_count"]),
        "native_projected_gd_successes" =>
            Int(observed["native_projected_gd_successes"]) ==
            Int(registered["native_projected_gd_successes"]),
        "native_exact_sum_product_successes" =>
            Int(observed["native_exact_sum_product_successes"]) ==
            Int(registered["native_exact_sum_product_successes"]),
        "native_net_gap" => Int(observed["native_net_gap"]) ==
            Int(registered["native_net_gap"]),
        "transition_ledger_telescopes" =>
            Bool(observed["native_gap_accounted"]),
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "registered" => Dict(key => Int(value)
                             for (key, value) in registered),
        "observed" => Dict(
            "case_count" => Int(observed["case_count"]),
            "native_projected_gd_successes" =>
                Int(observed["native_projected_gd_successes"]),
            "native_exact_sum_product_successes" =>
                Int(observed["native_exact_sum_product_successes"]),
            "native_net_gap" => Int(observed["native_net_gap"]),
        ),
    )
end

function calculate_cases(context, specs; include_controls::Bool=false,
                         confirmatory_inference::Bool=false,
                         progress_callback=(completed, total)->nothing)
    include_controls && confirmatory_inference && throw(ArgumentError(
        "confirmatory transition inference cannot pool Job 6 evidence sets"))
    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    gd_gates = Bool[]
    bp_gates = Bool[]
    shadow_gates = Bool[]
    rung_identity_gates = Bool[]
    for (position, (label, frame)) in enumerate(specs)
        input = generate_input(context, frame, label)
        calculated = compute_frame(context, input; include_controls)
        for id in FORWARD_ORDER
            push!(frame_rows, frame_row(input, calculated.rungs[id]))
        end
        if include_controls
            for id in ("assigned_frozen_compound_unconstrained",
                       "exact_sp_direct_tied_fixed30")
                push!(frame_rows, frame_row(input, calculated.controls[id]))
            end
        end
        append!(iteration_rows, calculated.iterations)
        push!(gd_gates, Bool(calculated.gd_gate["passed"]))
        push!(bp_gates, Bool(calculated.bp_gate["passed"]))
        push!(shadow_gates, Bool(calculated.shadow_gate["passed"]))
        push!(rung_identity_gates, Bool(calculated.rung_identity_gate["passed"]))
        progress_callback(position, length(specs))
    end
    ledger_rows = [row for row in frame_rows if row.rung_id in FORWARD_ORDER]
    if include_controls
        separated = job6_evidence_groups(frame_rows, context.composition_config)
        ledgers = separated.ledgers
        controls = separated.controls
        locked_endpoint_gate = locked_endpoint_reproduction_gate(
            ledgers, context.composition_config)
        gap_accounted = all(Bool(value["native_gap_accounted"])
                            for value in values(ledgers))
        # No success count or effect estimate is formed by pooling the fresh
        # transfer cases with the locked descriptive cases.
        ledger = Dict(
            "native_gap_accounted" => gap_accounted,
            "combined_counts_reported" => false,
            "named_ledgers" => ledgers,
        )
    else
        ledger = transition_ledger(ledger_rows)
        ledgers = Dict("registered_cases" => ledger)
        controls = Dict{String,Any}()
        locked_endpoint_gate = Dict(
            "passed" => true,
            "not_applicable" => true,
        )
        gap_accounted = Bool(ledger["native_gap_accounted"])
    end
    transition_inference = if confirmatory_inference
        paired_transition_inference(ledger, context.composition_config)
    else
        Dict(
            "applied" => false,
            "reason" => include_controls ?
                "Job 6 fresh and locked evidence remain separate and descriptive" :
                "confirmatory inference is registered only for Jobs 5 and 7",
        )
    end
    gates = Dict(
        "native_gd_endpoint_equal" => all(gd_gates),
        "native_bp_endpoint_equal" => all(bp_gates),
        "shadow_state_null" => all(shadow_gates),
        "runtime_rung_identity" => all(rung_identity_gates),
        "locked_endpoint_reproduction" =>
            Bool(locked_endpoint_gate["passed"]),
        "native_gap_accounted" => gap_accounted,
    )
    science = Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "case_count" => length(specs),
        "forward_rung_count" => length(FORWARD_ORDER),
        "execution_variant_count" => include_controls ? 13 : 11,
        "frame_rows" => frame_rows,
        "iteration_rows" => iteration_rows,
        "transition_ledgers" => ledgers,
        "paired_transition_inference" => transition_inference,
        "factorial_controls" => controls,
        "locked_endpoint_gate" => locked_endpoint_gate,
        "gates" => gates,
    )
    (; science, frame_rows, iteration_rows, gates, ledger, controls)
end

function validation_science(job_id, payload)
    Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => job_id,
        "validation_only" => true,
        "validation" => payload,
    )
end

function result_columns()
    (:channel, :snr_db, :frame, :noise_seed, :llr_sha256, :received_sha256,
     :rung_id, :backend, :parity_valid, :transmitted_word_equal,
     :coded_bit_errors, :syndrome_weight, :updates, :status,
     :first_valid_update, :first_exact_update, :state_sha256,
     :hard_word_sha256)
end

function iteration_columns()
    (:channel, :frame, :rung_id, :update, :accepted, :objective_before,
     :objective_after, :state_sha256, :hard_word_sha256, :syndrome_weight,
     :parity_valid, :transmitted_word_equal)
end

function write_toml(path, payload)
    open(path, "w") do io
        TOML.print(io, payload; sorted=true)
    end
end

function result_manifest(root)
    names = sort!(filter(name -> name != "MANIFEST.sha256", readdir(root)))
    join((file_sha256(joinpath(root, name)) * "  " * name for name in names), "\n") * "\n"
end

function write_atomic_result(output::AbstractString, job_id::String,
                             config_path::String, registry_path::String,
                             primary, replay, timing;
                             validation_only::Bool)
    write_started = time_ns()
    ispath(output) && throw(ArgumentError("refusing to overwrite $output"))
    parent = dirname(abspath(output))
    mkpath(parent)
    staging = mktempdir(parent; prefix="." * basename(output) * ".staging-")
    science_path = joinpath(staging, "science.json")
    science_text = canonical_json(primary.science) * "\n"
    replay_science_text = canonical_json(replay.science) * "\n"
    open(science_path, "w") do io
        write(io, science_text)
    end
    write_csv(joinpath(staging, "frames.csv"), primary.frame_rows, result_columns())
    write_csv(joinpath(staging, "iterations.csv"), primary.iteration_rows,
              iteration_columns())

    primary_hash = text_sha256(science_text)
    replay_hash = text_sha256(replay_science_text)
    deterministic = primary_hash == replay_hash
    correctness = Bool(primary.correctness_passed) &&
        Bool(replay.correctness_passed)
    registry_hash = scientific_sha256(load_registry(registry_path))
    gate = Dict(
        "schema_version" => JOB_GATE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => job_id,
        "job_kind" => validation_only ? "validation" : "science",
        "status" => correctness && deterministic ? "pass" : "fail",
        "validation_only" => validation_only,
        "correctness_passed" => correctness,
        "deterministic_replay_passed" => deterministic,
        "config_sha256" => file_sha256(config_path),
        "rungs_sha256" => file_sha256(registry_path),
        "registry_sha256" => registry_hash,
        "primary_science_sha256" => primary_hash,
        "replay_science_sha256" => replay_hash,
    )
    job_gate_path = joinpath(staging, "job_gate.toml")
    write_toml(job_gate_path, gate)

    endpoint_hash = ""
    if !validation_only
        endpoint = Dict{String,Any}(
            "schema_version" => ENDPOINT_GATE_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "job_id" => job_id,
            "status" => correctness ? "pass" : "fail",
            "native_gd_endpoint_equal" =>
                Bool(primary.gates["native_gd_endpoint_equal"]),
            "native_bp_endpoint_equal" =>
                Bool(primary.gates["native_bp_endpoint_equal"]),
            "native_gap_accounted" =>
                Bool(primary.gates["native_gap_accounted"]),
            "atomic_causal_decomposition_complete" => false,
            "joint_handoff_registered_non_atomic" => true,
            "joint_handoff_single_factor_claim_made" => false,
            "case_count" => Int(primary.science["case_count"]),
        )
        if job_id == JOB_IDS[6]
            endpoint["combined_counts_reported"] = false
            named = Dict{String,Any}()
            for name in ("six_db_transfer", "locked_attribution")
                ledger = primary.ledger["named_ledgers"][name]
                named[name] = Dict(
                    "case_count" => Int(ledger["case_count"]),
                    "native_projected_gd_successes" =>
                        Int(ledger["native_projected_gd_successes"]),
                    "native_exact_sum_product_successes" =>
                        Int(ledger["native_exact_sum_product_successes"]),
                    "native_net_gap" => Int(ledger["native_net_gap"]),
                    "transition_net_sum" => Int(ledger["transition_net_sum"]),
                    "native_gap_accounted" => Bool(ledger["native_gap_accounted"]),
                )
            end
            endpoint["named_ledgers"] = named
        else
            endpoint["combined_counts_reported"] = true
            endpoint["native_projected_gd_successes"] =
                Int(primary.ledger["native_projected_gd_successes"])
            endpoint["native_exact_sum_product_successes"] =
                Int(primary.ledger["native_exact_sum_product_successes"])
            endpoint["native_net_gap"] = Int(primary.ledger["native_net_gap"])
            endpoint["transition_net_sum"] = Int(primary.ledger["transition_net_sum"])
        end
        endpoint_path = joinpath(staging, "endpoint_gate.toml")
        write_toml(endpoint_path, endpoint)
        endpoint_hash = file_sha256(endpoint_path)
    end

    timing["write_seconds"] = (time_ns() - write_started) / 1.0e9
    timing["total_seconds"] = Float64(timing["primary_seconds"]) +
        Float64(timing["replay_seconds"]) + Float64(timing["write_seconds"])
    timing_path = joinpath(staging, "timing.toml")
    write_toml(timing_path, timing)
    completion = Dict(
        "schema_version" => COMPLETION_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => job_id,
        "status" => correctness && deterministic ? "complete_valid" : "invalid",
        "correctness_passed" => correctness,
        "deterministic_replay_passed" => deterministic,
        "science_sha256" => file_sha256(science_path),
        "job_gate_sha256" => file_sha256(job_gate_path),
        "endpoint_gate_sha256" => endpoint_hash,
    )
    write_toml(joinpath(staging, "COMPLETED.toml"), completion)
    open(joinpath(staging, "MANIFEST.sha256"), "w") do io
        write(io, result_manifest(staging))
    end
    Base.Filesystem.rename(staging, abspath(output))
    completion
end

function result_wrapper(science; frame_rows=NamedTuple[],
                        iteration_rows=NamedTuple[], gates=Dict{String,Bool}(),
                        ledger=Dict{String,Any}(), correctness_passed=true)
    (; science, frame_rows, iteration_rows, gates, ledger,
       correctness_passed=Bool(correctness_passed))
end

function progress_reporter(job_id, pass_name)
    (completed, total) -> begin
        println("progress job=$job_id pass=$pass_name cases=$completed/$total")
        flush(stdout)
    end
end

function run_validation_job(job_id, config, registry, config_path;
                            pass_name::String="primary")
    if job_id == JOB_IDS[1]
        payload = registry_gate(registry)
        science = validation_science(job_id, payload)
        return result_wrapper(science; correctness_passed=Bool(payload["passed"]))
    elseif job_id == JOB_IDS[2]
        payload = common_harness_gate(config)
        science = validation_science(job_id, payload)
        return result_wrapper(science; correctness_passed=Bool(payload["passed"]))
    elseif job_id == JOB_IDS[3]
        context = backend_context(config, config_path)
        calculated = calculate_cases(
            context, case_specs(config, job_id);
            progress_callback=progress_reporter(job_id, pass_name))
        payload = Dict(
            "validation_case_count" => length(case_specs(config, job_id)),
            "gates" => calculated.gates,
            "transition_ledger" => calculated.ledger,
            "frame_rows_sha256" => scientific_sha256(calculated.frame_rows),
            "iteration_rows_sha256" => scientific_sha256(calculated.iteration_rows),
            "frame_row_count" => length(calculated.frame_rows),
            "iteration_row_count" => length(calculated.iteration_rows),
        )
        science = validation_science(job_id, payload)
        passed = all(values(calculated.gates))
        return result_wrapper(science;
            frame_rows=calculated.frame_rows,
            iteration_rows=calculated.iteration_rows,
            gates=calculated.gates, ledger=calculated.ledger,
            correctness_passed=passed)
    end
    throw(ArgumentError("unknown validation job $job_id"))
end

function run_job(job_id::AbstractString; config_path::AbstractString,
                 registry_path::AbstractString, output::AbstractString)
    job_id in JOB_IDS || throw(ArgumentError("unknown job ID $job_id"))
    config = load_config(config_path)
    registry = load_registry(registry_path)
    registered = registry_gate(registry)
    Bool(registered["passed"]) || throw(ArgumentError("rung registry gate failed"))

    total_started = time_ns()
    primary_started = time_ns()
    if job_id in VALIDATION_JOBS
        primary = run_validation_job(
            job_id, config, registry, config_path; pass_name="primary")
    else
        context = backend_context(config, config_path)
        include_controls = job_id == JOB_IDS[6]
        confirmatory_inference = job_id in (JOB_IDS[5], JOB_IDS[7])
        calculated = calculate_cases(
            context, case_specs(config, job_id); include_controls,
            confirmatory_inference,
            progress_callback=progress_reporter(job_id, "primary"))
        calculated.science["job_id"] = String(job_id)
        calculated.science["validation_only"] = false
        primary = result_wrapper(calculated.science;
            frame_rows=calculated.frame_rows,
            iteration_rows=calculated.iteration_rows,
            gates=calculated.gates, ledger=calculated.ledger,
            correctness_passed=all(values(calculated.gates)))
    end
    primary_seconds = (time_ns() - primary_started) / 1.0e9

    replay_started = time_ns()
    if job_id in VALIDATION_JOBS
        replay = run_validation_job(
            job_id, config, registry, config_path; pass_name="replay")
    else
        context = backend_context(config, config_path)
        include_controls = job_id == JOB_IDS[6]
        confirmatory_inference = job_id in (JOB_IDS[5], JOB_IDS[7])
        calculated = calculate_cases(
            context, case_specs(config, job_id); include_controls,
            confirmatory_inference,
            progress_callback=progress_reporter(job_id, "replay"))
        calculated.science["job_id"] = String(job_id)
        calculated.science["validation_only"] = false
        replay = result_wrapper(calculated.science;
            frame_rows=calculated.frame_rows,
            iteration_rows=calculated.iteration_rows,
            gates=calculated.gates, ledger=calculated.ledger,
            correctness_passed=all(values(calculated.gates)))
    end
    primary_science_sha256 = scientific_sha256(primary.science)
    replay_science_sha256 = scientific_sha256(replay.science)
    primary_science_sha256 == replay_science_sha256 ||
        throw(ArgumentError("deterministic replay differs"))
    replay_seconds = (time_ns() - replay_started) / 1.0e9

    validation_only = job_id in VALIDATION_JOBS
    frame_count = validation_only ? 0 : length(case_specs(config, job_id))
    validation_case_count = job_id == JOB_IDS[3] ?
        length(case_specs(config, job_id)) : 0
    execution_variant_count = validation_only ? 0 :
        (job_id == JOB_IDS[6] ? 13 : 11)
    work = frame_count * execution_variant_count
    seconds_per_variant = work == 0 ? 0.0 :
        (primary_seconds + replay_seconds) / work
    timing = Dict(
        "schema_version" => TIMING_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => String(job_id),
        "frame_count" => frame_count,
        "rung_count" => validation_only ? 0 : length(FORWARD_ORDER),
        "execution_variant_count" => execution_variant_count,
        "pass_count" => validation_only ? 0 : 2,
        "primary_seconds" => primary_seconds,
        "replay_seconds" => replay_seconds,
        "write_seconds" => 0.0,
        "total_seconds" => (time_ns() - total_started) / 1.0e9,
        "seconds_per_frame_variant" => seconds_per_variant,
        "seconds_per_frame_rung" => seconds_per_variant,
    )
    validation_only && (timing["validation_case_count"] = validation_case_count)
    completion = write_atomic_result(
        output, String(job_id), abspath(config_path), abspath(registry_path),
        primary, replay, timing; validation_only)
    completion_status = completion["status"]
    completion_science_sha256 = completion["science_sha256"]
    println("$completion_status job=$job_id " *
            "science_sha256=$completion_science_sha256")
    (; completion, output=abspath(output))
end

function parse_options(arguments)
    options = Dict{String,String}()
    index = 1
    while index <= length(arguments)
        startswith(arguments[index], "--") ||
            throw(ArgumentError("expected option, got $(arguments[index])"))
        index < length(arguments) ||
            throw(ArgumentError("missing value for $(arguments[index])"))
        options[arguments[index][3:end]] = arguments[index + 1]
        index += 2
    end
    options
end

function main(arguments=ARGS)
    length(arguments) >= 2 || throw(ArgumentError(
        "usage: native_composition.jl job JOB_ID --config PATH --rungs PATH --output DIR"))
    arguments[1] == "job" || throw(ArgumentError("only the job command is supported"))
    job_id = arguments[2]
    options = parse_options(arguments[3:end])
    for required in ("config", "rungs", "output")
        haskey(options, required) || throw(ArgumentError("--$required is required"))
    end
    run_job(job_id; config_path=options["config"],
            registry_path=options["rungs"], output=options["output"])
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
