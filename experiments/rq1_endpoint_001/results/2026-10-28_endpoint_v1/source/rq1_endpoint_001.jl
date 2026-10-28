#!/usr/bin/env julia

module RQ1Endpoint001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using SHA
using TOML

const CORE = JadeJcade.ReceiverCore
const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__

export load_config, load_oracles, calculate_science, execute, main,
       canonical_json, scientific_sha256, rung_fingerprints,
       endpoint_equivalence

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

"""Return a stable JSON representation used for scientific replay hashes."""
function canonical_json(value)
    if value === nothing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Integer
        return string(value)
    elseif value isa AbstractFloat
        isfinite(value) || throw(ArgumentError("canonical scientific JSON requires finite floats"))
        return repr(Float64(value))
    elseif value isa AbstractString
        return "\"" * json_escape(value) * "\""
    elseif value isa Symbol
        return canonical_json(String(value))
    elseif value isa NamedTuple
        return canonical_json(Dict(String(key) => getfield(value, key) for key in keys(value)))
    elseif value isa AbstractDict
        pairs_sorted = sort!(collect(value); by=pair -> String(first(pair)))
        return "{" * join((canonical_json(String(first(pair))) * ":" *
                            canonical_json(last(pair)) for pair in pairs_sorted), ",") * "}"
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

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq1-endpoint-001/v1" ||
        throw(ArgumentError("unsupported endpoint-bridge schema"))
    config["experiment_id"] == "RQ1-ENDPOINT-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    checks = config["graph"]["checks"]
    length(checks) == 2 && all(length(check) == 2 for check in checks) ||
        throw(ArgumentError("the locked bridge requires two degree-two checks"))
    values = Float64.(config["channel_evidence"]["values"])
    expected = [-log(9.0), log(3.0 / 2.0), log(2.0)]
    maximum(abs, values - expected) <= 1.0e-15 ||
        throw(ArgumentError("configured LLR decimals do not reproduce the symbolic values"))
    config
end

checks_from_config(config) = [Int.(check) for check in config["graph"]["checks"]]
llr_bit1_from_config(config) = Float64.(config["channel_evidence"]["values"])

function load_runner_module(path::AbstractString, label::Symbol)
    isfile(path) || throw(ArgumentError("native runner not found: $path"))
    container = Module(Symbol("RQ1EndpointContainer_", label))
    Base.include(container, path)
    isdefined(container, :AWGNThreeReceivers) ||
        throw(ArgumentError("runner did not define AWGNThreeReceivers: $path"))
    Base.invokelatest(() -> getfield(container, :AWGNThreeReceivers))
end

function load_oracles(config)
    sources = config["sources"]
    current = load_runner_module(String(sources["current_runner"]), :current)
    archived = load_runner_module(String(sources["archived_runner"]), :archived)
    (; current, archived)
end

named_terms(terms) = Dict(String(key) => Float64(getfield(terms, key)) for key in keys(terms))

function native_scalar_summary(oracle, checks, ell, initial, config)
    projected = config["projected_gradient"]
    problem = oracle.ScalarProblem(checks, length(ell), ell;
        parity_weight=Float64(projected["parity_weight"]),
        binary_weight=Float64(projected["binary_weight"]))
    evaluated = oracle.objective_gradient(problem, initial)
    solved = oracle.solve_scalar(problem, initial;
        steps=Int(projected["native_steps"]),
        initial_step=Float64(projected["native_initial_step"]))
    Dict(
        "initial_x" => Float64.(initial),
        "initial_objective" => Float64(solved.initial_objective),
        "initial_terms" => named_terms(solved.initial_terms),
        "initial_gradient" => Float64.(evaluated.gradient),
        "gradient_kind" => String(solved.gradient_kind),
        "x" => Float64.(solved.x),
        "final_objective" => Float64(solved.final_objective),
        "final_terms" => named_terms(solved.final_terms),
        "objective_history" => Float64.(solved.objective_history),
        "accepted_steps" => Int(solved.accepted_steps),
        "steps_requested" => Int(solved.steps_requested),
        "objective_evaluations" => Int(solved.objective_evaluations),
        "status" => String(solved.status),
        "pseudogradient_calls" => Int(solved.pseudogradient_calls),
        "decoder_calls" => Int(solved.decoder_calls),
    )
end

function compare_structures(left, right; atol::Float64=0.0)
    maximum_difference = Ref(0.0)
    first_mismatch = Ref{Union{Nothing,String}}(nothing)
    function visit(a, b, path)
        if a isa Number && !(a isa Bool) && b isa Number && !(b isa Bool)
            difference = abs(Float64(a) - Float64(b))
            maximum_difference[] = max(maximum_difference[], difference)
            if !(difference <= atol) && first_mismatch[] === nothing
                first_mismatch[] = "$path: $a != $b"
            end
        elseif a isa AbstractDict && b isa AbstractDict
            left_keys = sort!(String.(collect(keys(a))))
            right_keys = sort!(String.(collect(keys(b))))
            if left_keys != right_keys
                first_mismatch[] === nothing &&
                    (first_mismatch[] = "$path: keys $left_keys != $right_keys")
                return
            end
            for key in left_keys
                visit(a[key], b[key], "$path.$key")
            end
        elseif (a isa AbstractVector || a isa Tuple) &&
               (b isa AbstractVector || b isa Tuple)
            if length(a) != length(b)
                first_mismatch[] === nothing &&
                    (first_mismatch[] = "$path: lengths $(length(a)) != $(length(b))")
                return
            end
            for index in eachindex(a, b)
                visit(a[index], b[index], "$path[$index]")
            end
        elseif !isequal(a, b) && first_mismatch[] === nothing
            first_mismatch[] = "$path: $(repr(a)) != $(repr(b))"
        end
    end
    visit(left, right, "root")
    Dict(
        "passed" => first_mismatch[] === nothing,
        "maximum_absolute_difference" => maximum_difference[],
        "first_mismatch" => first_mismatch[],
    )
end

function endpoint_equivalence(current, archived)
    exact = canonical_json(current) == canonical_json(archived)
    comparison = compare_structures(current, archived; atol=0.0)
    merge(comparison, Dict(
        "passed" => exact && comparison["passed"],
        "canonical_sha256_current" => scientific_sha256(current),
        "canonical_sha256_archived" => scientific_sha256(archived),
        "bitwise_canonical_match" => exact,
    ))
end

function syndrome(checks, bits)
    [foldl(xor, (Bool(bits[bit]) for bit in check); init=false) ? 1 : 0
     for check in checks]
end

function variable_edges(checks, n)
    edges = [Tuple{Int,Int}[] for _ in 1:n]
    for (check_index, check) in enumerate(checks), (slot, bit) in enumerate(check)
        push!(edges[bit], (check_index, slot))
    end
    edges
end

function toy_code(checks, n)
    H = falses(length(checks), n)
    for (check_index, check) in enumerate(checks), bit in check
        H[check_index, bit] = true
    end
    edges = variable_edges(checks, n)
    CORE._Code(0, n, 1, "rq1-endpoint-001-toy", 0, true,
        collect(1:n), falses(n, 0), H, deepcopy(checks), edges, collect(1:n))
end

function check_message_bit1(incoming, target_slot)
    degree = length(incoming)
    product = 1.0
    for slot in eachindex(incoming)
        slot == target_slot && continue
        product *= tanh(0.5 * incoming[slot])
    end
    -2atanh((-1.0)^(degree - 1) * product)
end

function enumerated_check_message_bit1(incoming, target_slot)
    other_slots = [slot for slot in eachindex(incoming) if slot != target_slot]
    totals = zeros(Float64, 2)
    for mask in 0:(1 << length(other_slots)) - 1
        parity = false
        log_weight = 0.0
        for (position, slot) in enumerate(other_slots)
            bit = ((mask >> (position - 1)) & 1) == 1
            parity = xor(parity, bit)
            bit && (log_weight += incoming[slot])
        end
        target_bit = parity # even total parity requires target XOR others = 0
        totals[Int(target_bit) + 1] += exp(log_weight)
    end
    log(totals[2] / totals[1])
end

function flatten_rows(rows)
    Float64[value for row in rows for value in row]
end

function bp_control_trace(checks, L, sweeps)
    n = length(L)
    edges = variable_edges(checks, n)
    previous_u = [zeros(Float64, length(check)) for check in checks]
    iterations = Dict{String,Any}[]
    max_enumeration_error = 0.0
    max_native_check_error = 0.0
    max_abs_check_input = 0.0
    max_abs_check_output = 0.0
    for iteration in 1:sweeps
        q = [zeros(Float64, length(check)) for check in checks]
        for (check_index, check) in enumerate(checks), (slot, bit) in enumerate(check)
            q[check_index][slot] = L[bit] + sum(
                previous_u[other_check][other_slot]
                for (other_check, other_slot) in edges[bit]
                if other_check != check_index;
                init=0.0)
        end
        u = [zeros(Float64, length(check)) for check in checks]
        native_u = [zeros(Float64, length(check)) for check in checks]
        for check_index in eachindex(checks)
            incoming_bit0 = -q[check_index]
            outgoing_bit0 = similar(incoming_bit0)
            CORE._bp_check_sum_product!(outgoing_bit0, incoming_bit0)
            native_u[check_index] .= -outgoing_bit0
            for slot in eachindex(q[check_index])
                u[check_index][slot] = check_message_bit1(q[check_index], slot)
                enumerated = enumerated_check_message_bit1(q[check_index], slot)
                max_enumeration_error = max(max_enumeration_error,
                    abs(u[check_index][slot] - enumerated))
                max_native_check_error = max(max_native_check_error,
                    abs(u[check_index][slot] - native_u[check_index][slot]))
            end
            max_abs_check_input = max(max_abs_check_input, maximum(abs, q[check_index]))
            max_abs_check_output = max(max_abs_check_output, maximum(abs, u[check_index]))
        end
        posterior = copy(L)
        for bit in 1:n, (check_index, slot) in edges[bit]
            posterior[bit] += u[check_index][slot]
        end
        hard = [value >= 0.0 ? 1 : 0 for value in posterior]
        push!(iterations, Dict(
            "iteration" => iteration,
            "q_bit1" => flatten_rows(q),
            "u_bit1" => flatten_rows(u),
            "q_bit0" => -flatten_rows(q),
            "u_bit0" => -flatten_rows(u),
            "posterior_bit1" => posterior,
            "posterior_bit0" => -posterior,
            "hard_decision" => hard,
            "syndrome" => syndrome(checks, hard),
        ))
        previous_u = u
    end
    Dict(
        "iterations" => iterations,
        "max_local_enumeration_error" => max_enumeration_error,
        "max_native_check_error" => max_native_check_error,
        "max_abs_check_input" => max_abs_check_input,
        "max_abs_check_output" => max_abs_check_output,
    )
end

function native_bp_summary(checks, L, sweeps)
    n = length(L)
    ell = -L
    code = toy_code(checks, n)
    modem = JadeJcade.Jade.Modulation(
        pilot_ratio=0.0, inner_pilot_ratio=0.0, bp_iterations=sweeps)
    result = CORE._bp_decode_sum_product(modem, code, -ell)
    scratch = modem.bp_scratch
    hard = [value > 0.0 ? 1 : 0 for value in result.lpost_metric]
    Dict(
        "entrypoint" => "JadeJcade.ReceiverCore._bp_decode_sum_product",
        "check_function" => "JadeJcade.ReceiverCore._bp_check_sum_product!",
        "lpost_metric_bit1" => Float64.(result.lpost_metric),
        "hard_decision" => hard,
        "syndrome_recomputed" => syndrome(checks, hard),
        "syndrome_native" => Int(result.syndrome),
        "valid" => Bool(result.valid),
        "iterations" => Int(result.iterations),
        "terminal_q_bit0" => flatten_rows(scratch.q),
        "terminal_r_bit0" => flatten_rows(scratch.r),
    )
end

function bp_endpoint(checks, L, config)
    tolerance = Float64(config["validation"]["absolute_tolerance"])
    sweeps = Int(config["belief_propagation"]["fixed_sweeps"])
    llr_clip = Float64(config["belief_propagation"]["llr_clip"])
    control = bp_control_trace(checks, L, sweeps)
    native = native_bp_summary(checks, L, sweeps)
    terminal = control["iterations"][end]
    exact_posterior = fill(sum(L), length(L))
    posterior_error = maximum(abs,
        Float64.(terminal["posterior_bit1"]) - exact_posterior)
    native_posterior_error = maximum(abs,
        Float64.(native["lpost_metric_bit1"]) - Float64.(terminal["posterior_bit1"]))
    native_hard_equal = native["hard_decision"] == terminal["hard_decision"]
    native_syndrome_equal = native["syndrome_recomputed"] == terminal["syndrome"] &&
        native["syndrome_native"] == sum(terminal["syndrome"])
    clip_inactive = control["max_abs_check_input"] < llr_clip &&
        control["max_abs_check_output"] < llr_clip
    checks_gate = Dict(
        "local_enumeration" => control["max_local_enumeration_error"] <= tolerance,
        "native_check_function" => control["max_native_check_error"] <= tolerance,
        "exact_tree_posterior" => posterior_error <= tolerance,
        "native_terminal_posterior" => native_posterior_error <= tolerance,
        "native_hard_decision" => native_hard_equal,
        "native_syndrome" => native_syndrome_equal,
        "native_iteration_count" => native["iterations"] == sweeps,
        "native_valid" => native["valid"],
        "llr_clipping_inactive" => clip_inactive,
        "normalized_min_sum_not_called" => true,
    )
    Dict(
        "control" => control,
        "native" => native,
        "exact_tree_posterior_bit1" => exact_posterior,
        "posterior_error" => posterior_error,
        "native_posterior_error" => native_posterior_error,
        "checks" => checks_gate,
        "passed" => all(values(checks_gate)),
    )
end

function scalar_objective_gradient(x, ell, checks, fingerprint)
    n = length(x)
    parity_weight = Float64(fingerprint["parity_weight"])
    binary_weight = Float64(fingerprint["binary_weight"])
    channel_weight = Float64(fingerprint["channel_weight"])
    gradient = zeros(Float64, n)
    raw_parity = 0.0
    for check in checks
        product = prod(x[bit] for bit in check)
        residual = 1.0 - product
        raw_parity += residual^2
        coefficient = -2.0 * parity_weight * residual / n
        for (slot, bit) in enumerate(check)
            leave_one = 1.0
            for (other_slot, other_bit) in enumerate(check)
                slot == other_slot && continue
                leave_one *= x[other_bit]
            end
            gradient[bit] += coefficient * leave_one
        end
    end
    channel = -channel_weight * dot(ell, x) / (2n)
    gradient .-= channel_weight .* ell ./ (2n)
    binary_raw = 0.0
    for bit in eachindex(x)
        binary_raw += (1.0 - x[bit]^2)^2
        gradient[bit] += 4.0 * binary_weight * x[bit] * (x[bit]^2 - 1.0) / n
    end
    parity = parity_weight * raw_parity / n
    binary = binary_weight * binary_raw / n
    Dict(
        "loss" => channel + parity + binary,
        "gradient" => gradient,
        "terms" => Dict(
            "channel" => channel,
            "parity" => parity,
            "binary" => binary,
            "raw_parity" => raw_parity,
            "raw_binary" => binary_raw,
        ),
    )
end

function scalar_loss(x, ell, checks, fingerprint)
    scalar_objective_gradient(x, ell, checks, fingerprint)["loss"]
end

function independent_box_projection(raw, lower, upper)
    [value < lower ? lower : (value > upper ? upper : value) for value in raw]
end

function degrees(checks, n)
    result = zeros(Int, n)
    for check in checks, bit in check
        result[bit] += 1
    end
    result
end

function rung_fingerprints(config)
    projected = config["projected_gradient"]
    n = length(config["channel_evidence"]["values"])
    parity_weight = Float64(projected["parity_weight"])
    normalized_step = Float64(projected["teaching_step"]) * n / parity_weight
    constant = Dict{String,Any}(
        "state_representation" => "one_scalar_per_bit_bit0_positive",
        "parity_kernel" => "exact_product_residual",
        "parity_weight" => parity_weight,
        "binary_weight" => 0.0,
        "channel_weight" => 0.0,
        "step_size" => normalized_step,
        "preconditioner" => "identity",
        "line_search" => "none",
        "termination_policy" => "one_update",
        "projection" => "componentwise_box",
        "box_lower" => Float64(projected["box_lower"]),
        "box_upper" => Float64(projected["box_upper"]),
        "schedule" => "frozen_synchronous_full_gradient",
        "maximum_backtracks" => Int(projected["maximum_backtracks"]),
    )
    identifiers = [
        "RQ1-ENDPOINT-PG-BASE-001",
        "RQ1-BRIDGE-CHANNEL-001",
        "RQ1-BRIDGE-BINARY-001",
        "RQ1-BRIDGE-STEP-001",
        "RQ1-BRIDGE-PRECOND-001",
        "RQ1-BRIDGE-LINESEARCH-001",
        "RQ1-ENDPOINT-PG-001",
    ]
    fingerprints = Dict{String,Any}[]
    current = deepcopy(constant)
    push!(fingerprints, merge(Dict("card_id" => identifiers[1]), deepcopy(current)))
    current["channel_weight"] = 1.0
    push!(fingerprints, merge(Dict("card_id" => identifiers[2]), deepcopy(current)))
    current["binary_weight"] = Float64(projected["binary_weight"])
    push!(fingerprints, merge(Dict("card_id" => identifiers[3]), deepcopy(current)))
    current["step_size"] = Float64(projected["native_initial_step"])
    push!(fingerprints, merge(Dict("card_id" => identifiers[4]), deepcopy(current)))
    current["preconditioner"] = "native_curvature_bound"
    push!(fingerprints, merge(Dict("card_id" => identifiers[5]), deepcopy(current)))
    current["line_search"] = "native_strict_decrease"
    push!(fingerprints, merge(Dict("card_id" => identifiers[6]), deepcopy(current)))
    current["termination_policy"] = "native_30_or_stall"
    push!(fingerprints, merge(Dict("card_id" => identifiers[7]), deepcopy(current)))
    fingerprints
end

function fingerprint_payload(fingerprint)
    Dict(key => value for (key, value) in fingerprint if key != "card_id")
end

function adjacent_fingerprint_checks(fingerprints)
    expected = ["channel_weight", "binary_weight", "step_size", "preconditioner",
                "line_search", "termination_policy"]
    records = Dict{String,Any}[]
    all_passed = true
    for index in 1:length(fingerprints)-1
        left = fingerprint_payload(fingerprints[index])
        right = fingerprint_payload(fingerprints[index + 1])
        keys_union = sort!(collect(union(Set(keys(left)), Set(keys(right)))))
        differences = [key for key in keys_union if !isequal(left[key], right[key])]
        passed = differences == [expected[index]]
        all_passed &= passed
        push!(records, Dict(
            "from" => fingerprints[index]["card_id"],
            "to" => fingerprints[index + 1]["card_id"],
            "expected_changed_field" => expected[index],
            "observed_changed_fields" => differences,
            "from_sha256" => scientific_sha256(left),
            "to_sha256" => scientific_sha256(right),
            "passed" => passed,
        ))
    end
    Dict("passed" => all_passed, "adjacent_pairs" => records)
end

function solve_control(initial, ell, checks, fingerprint)
    lower = Float64(fingerprint["box_lower"])
    upper = Float64(fingerprint["box_upper"])
    x = independent_box_projection(Float64.(initial), lower, upper)
    current = scalar_objective_gradient(x, ell, checks, fingerprint)
    initial_record = deepcopy(current)
    history = Float64[current["loss"]]
    trace = Dict{String,Any}[]
    evaluations = 1
    accepted_steps = 0
    requested = fingerprint["termination_policy"] == "one_update" ? 1 : 30
    status = "steps_completed"
    bit_degrees = degrees(checks, length(x))
    n = length(x)
    for update in 1:requested
        before = copy(x)
        gradient = copy(current["gradient"])
        direction = if fingerprint["preconditioner"] == "identity"
            -gradient
        else
            curvature = [
                (2Float64(fingerprint["parity_weight"]) * bit_degrees[bit] +
                 8Float64(fingerprint["binary_weight"])) / n
                for bit in eachindex(x)
            ]
            -gradient ./ curvature
        end
        accepted = false
        accepted_evaluated = nothing
        accepted_raw = Float64[]
        accepted_projected = Float64[]
        accepted_step = 0.0
        accepted_backtrack = -1
        maximum_backtracks = fingerprint["line_search"] == "none" ? 0 :
            Int(fingerprint["maximum_backtracks"])
        for backtrack in 0:maximum_backtracks
            step = Float64(fingerprint["step_size"]) * 0.5^backtrack
            raw = before .+ step .* direction
            projected = independent_box_projection(raw, lower, upper)
            evaluated = scalar_objective_gradient(projected, ell, checks, fingerprint)
            evaluations += 1
            passes = fingerprint["line_search"] == "none" ||
                evaluated["loss"] < current["loss"]
            if passes
                accepted = true
                accepted_evaluated = evaluated
                accepted_raw = raw
                accepted_projected = projected
                accepted_step = step
                accepted_backtrack = backtrack
                break
            end
        end
        active = accepted ? [bit for bit in eachindex(accepted_raw)
                             if accepted_raw[bit] != accepted_projected[bit]] : Int[]
        push!(trace, Dict(
            "update" => update,
            "x_before" => before,
            "frozen_state_sha256" => scientific_sha256(before),
            "gradient" => gradient,
            "direction" => direction,
            "raw_proposal" => accepted_raw,
            "projected_proposal" => accepted_projected,
            "active_projection_coordinates" => active,
            "accepted" => accepted,
            "accepted_step" => accepted_step,
            "backtrack_index" => accepted_backtrack,
            "loss_before" => current["loss"],
            "loss_after" => accepted ? accepted_evaluated["loss"] : current["loss"],
        ))
        if !accepted
            status = "line_search_stalled"
            break
        end
        x = accepted_projected
        current = accepted_evaluated
        push!(history, current["loss"])
        accepted_steps += 1
    end
    Dict(
        "x" => x,
        "initial_objective" => initial_record["loss"],
        "initial_terms" => initial_record["terms"],
        "initial_gradient" => initial_record["gradient"],
        "final_objective" => current["loss"],
        "final_terms" => current["terms"],
        "objective_history" => history,
        "accepted_steps" => accepted_steps,
        "steps_requested" => requested,
        "objective_evaluations" => evaluations,
        "status" => status,
        "trace" => trace,
    )
end

function finite_difference_check(x, ell, checks, fingerprint, config)
    h = Float64(config["validation"]["finite_difference_step"])
    tolerance = Float64(config["validation"]["finite_difference_tolerance"])
    analytic = scalar_objective_gradient(x, ell, checks, fingerprint)["gradient"]
    numerical = similar(analytic)
    for bit in eachindex(x)
        plus, minus = copy(x), copy(x)
        plus[bit] += h
        minus[bit] -= h
        numerical[bit] = (scalar_loss(plus, ell, checks, fingerprint) -
                          scalar_loss(minus, ell, checks, fingerprint)) / (2h)
    end
    error = maximum(abs, analytic - numerical)
    Dict(
        "analytic" => analytic,
        "numerical" => numerical,
        "maximum_absolute_error" => error,
        "tolerance" => tolerance,
        "passed" => error <= tolerance,
    )
end

function teaching_parity_gradient(x, checks)
    gradient = zeros(Float64, length(x))
    loss = 0.0
    for check in checks
        target = (-1.0)^length(check)
        product = prod(x[bit] for bit in check)
        residual = 1.0 - target * product
        loss += residual^2
        for (slot, bit) in enumerate(check)
            leave_one = 1.0
            for (other_slot, other_bit) in enumerate(check)
                slot == other_slot && continue
                leave_one *= x[other_bit]
            end
            gradient[bit] += -2.0 * target * residual * leave_one
        end
    end
    Dict("loss" => loss, "gradient" => gradient)
end

function parity_base_equivalence(checks, L, ell, initial_bit0, fingerprint, config)
    tolerance = Float64(config["validation"]["absolute_tolerance"])
    projected = config["projected_gradient"]
    teaching_step = Float64(projected["teaching_step"])
    lower = Float64(projected["box_lower"])
    upper = Float64(projected["box_upper"])
    initial_bit1 = tanh.(L ./ 2)
    teaching = teaching_parity_gradient(initial_bit1, checks)
    teaching_raw = initial_bit1 .- teaching_step .* teaching["gradient"]
    teaching_projected = independent_box_projection(teaching_raw, lower, upper)
    base = solve_control(initial_bit0, ell, checks, fingerprint)
    base_step = base["trace"][1]
    raw_error = maximum(abs, Float64.(base_step["raw_proposal"]) + teaching_raw)
    projected_error = maximum(abs, Float64.(base_step["projected_proposal"]) +
        teaching_projected)
    canonical = scalar_objective_gradient(initial_bit0, ell, checks, fingerprint)
    scaling = Float64(fingerprint["parity_weight"]) / length(initial_bit0)
    loss_error = abs(canonical["loss"] - scaling * teaching["loss"])
    gradient_chain_error = maximum(abs,
        Float64.(canonical["gradient"]) + scaling .* Float64.(teaching["gradient"]))
    checks_gate = Dict(
        "initial_sign_transform" => initial_bit0 == -initial_bit1,
        "objective_scaling" => loss_error <= tolerance,
        "gradient_chain_rule" => gradient_chain_error <= tolerance,
        "raw_proposal_sign_transform" => raw_error <= tolerance,
        "projected_proposal_sign_transform" => projected_error <= tolerance,
    )
    Dict(
        "teaching_initial_bit1" => initial_bit1,
        "teaching_loss" => teaching["loss"],
        "teaching_gradient" => teaching["gradient"],
        "teaching_raw" => teaching_raw,
        "teaching_projected" => teaching_projected,
        "canonical_initial_bit0" => initial_bit0,
        "canonical_base" => base,
        "loss_error" => loss_error,
        "gradient_chain_error" => gradient_chain_error,
        "raw_error" => raw_error,
        "projected_error" => projected_error,
        "checks" => checks_gate,
        "passed" => all(values(checks_gate)),
    )
end

function projection_and_frozen_gates(rung_results, fingerprints, ell, checks, config)
    tolerance = Float64(config["validation"]["absolute_tolerance"])
    projection_passed = true
    frozen_passed = true
    records = Dict{String,Any}[]
    for (result, fingerprint) in zip(rung_results, fingerprints)
        for step in result["trace"]
            step["accepted"] || continue
            independent = independent_box_projection(step["raw_proposal"],
                Float64(fingerprint["box_lower"]), Float64(fingerprint["box_upper"]))
            projection_error = maximum(abs,
                Float64.(independent) - Float64.(step["projected_proposal"]))
            reevaluated = scalar_objective_gradient(
                step["x_before"], ell, checks, fingerprint)["gradient"]
            frozen_error = maximum(abs,
                Float64.(reevaluated) - Float64.(step["gradient"]))
            expected_raw = Float64.(step["x_before"]) .+
                Float64(step["accepted_step"]) .* Float64.(step["direction"])
            proposal_error = maximum(abs,
                expected_raw - Float64.(step["raw_proposal"]))
            projection_passed &= projection_error <= tolerance
            frozen_passed &= frozen_error <= tolerance && proposal_error <= tolerance
            push!(records, Dict(
                "card_id" => fingerprint["card_id"],
                "update" => step["update"],
                "projection_error" => projection_error,
                "frozen_gradient_error" => frozen_error,
                "proposal_error" => proposal_error,
            ))
        end
    end
    Dict(
        "projection_passed" => projection_passed,
        "frozen_state_passed" => frozen_passed,
        "records" => records,
        "passed" => projection_passed && frozen_passed,
    )
end

function scalar_composition_view(result)
    Dict(
        "x" => result["x"],
        "initial_objective" => result["initial_objective"],
        "initial_terms" => Dict(key => result["initial_terms"][key]
                                for key in ("channel", "parity", "binary")),
        "initial_gradient" => result["initial_gradient"],
        "final_objective" => result["final_objective"],
        "final_terms" => Dict(key => result["final_terms"][key]
                              for key in ("channel", "parity", "binary")),
        "objective_history" => result["objective_history"],
        "accepted_steps" => result["accepted_steps"],
        "steps_requested" => result["steps_requested"],
        "objective_evaluations" => result["objective_evaluations"],
        "status" => result["status"],
    )
end

function native_composition_view(result)
    Dict(
        "x" => result["x"],
        "initial_objective" => result["initial_objective"],
        "initial_terms" => result["initial_terms"],
        "initial_gradient" => result["initial_gradient"],
        "final_objective" => result["final_objective"],
        "final_terms" => result["final_terms"],
        "objective_history" => result["objective_history"],
        "accepted_steps" => result["accepted_steps"],
        "steps_requested" => result["steps_requested"],
        "objective_evaluations" => result["objective_evaluations"],
        "status" => result["status"],
    )
end

function source_gate(config)
    sources = config["sources"]
    archived_path = String(sources["archived_runner"])
    current_path = String(sources["current_runner"])
    archived_exists = isfile(archived_path)
    current_exists = isfile(current_path)
    observed = archived_exists ? file_sha256(archived_path) : "missing"
    expected = String(sources["archived_runner_sha256"])
    Dict(
        "archived_runner_exists" => archived_exists,
        "current_runner_exists" => current_exists,
        "archived_runner_sha256_expected" => expected,
        "archived_runner_sha256_observed" => observed,
        "passed" => archived_exists && current_exists && observed == expected,
    )
end

function invalid_science(reason, source_validation; endpoint=nothing)
    result = Dict{String,Any}(
        "schema_version" => "rq1-endpoint-001/science-v1",
        "experiment_id" => "RQ1-ENDPOINT-001",
        "status" => "invalid",
        "invalid_reason" => reason,
        "source_gate" => source_validation,
        "downstream_cards_executed" => false,
        "validation_passed" => false,
    )
    endpoint === nothing || (result["native_endpoint_equivalence"] = endpoint)
    result
end

function calculate_science(config, oracles; source_validation=source_gate(config))
    source_validation["passed"] ||
        return invalid_science("source_provenance_gate_failed", source_validation)
    checks = checks_from_config(config)
    L = llr_bit1_from_config(config)
    ell = -L
    initial_bit0 = tanh.(ell ./ 2)
    current_native = native_scalar_summary(
        oracles.current, checks, ell, initial_bit0, config)
    archived_native = native_scalar_summary(
        oracles.archived, checks, ell, initial_bit0, config)
    endpoint_gate = endpoint_equivalence(current_native, archived_native)
    endpoint_gate["passed"] || return invalid_science(
        "archived_current_native_endpoint_mismatch", source_validation;
        endpoint=Dict(
            "gate" => endpoint_gate,
            "current" => current_native,
            "archived" => archived_native,
        ))

    bp = bp_endpoint(checks, L, config)
    fingerprints = rung_fingerprints(config)
    adjacency = adjacent_fingerprint_checks(fingerprints)
    base = parity_base_equivalence(
        checks, L, ell, initial_bit0, fingerprints[1], config)
    rung_results = [solve_control(initial_bit0, ell, checks, fingerprint)
                    for fingerprint in fingerprints]
    finite_differences = [finite_difference_check(
        initial_bit0, ell, checks, fingerprint, config)
        for fingerprint in fingerprints]
    projection_frozen = projection_and_frozen_gates(
        rung_results, fingerprints, ell, checks, config)

    line_result = rung_results[end - 1]
    final_result = rung_results[end]
    prefix_left = isempty(line_result["trace"]) ? nothing : line_result["trace"][1]
    prefix_right = isempty(final_result["trace"]) ? nothing : final_result["trace"][1]
    prefix_comparison = compare_structures(prefix_left, prefix_right; atol=0.0)

    composition_tolerance = Float64(
        config["validation"]["native_composition_tolerance"])
    composed_view = scalar_composition_view(final_result)
    current_view = native_composition_view(current_native)
    archived_view = native_composition_view(archived_native)
    current_composition = compare_structures(
        composed_view, current_view; atol=composition_tolerance)
    archived_composition = compare_structures(
        composed_view, archived_view; atol=composition_tolerance)

    convention_checks = Dict(
        "ell_is_negative_L" => ell == -L,
        "initial_scalar_sign_transform" => initial_bit0 == -tanh.(L ./ 2),
        "hard_decision_invariance" =>
            [value < 0.0 ? 1 : 0 for value in ell] ==
            [value >= 0.0 ? 1 : 0 for value in L],
        "syndrome_invariance" => syndrome(checks,
            [value < 0.0 ? 1 : 0 for value in ell]) == syndrome(checks,
            [value >= 0.0 ? 1 : 0 for value in L]),
        "parity_gradient_chain_rule" => base["checks"]["gradient_chain_rule"],
    )
    all_finite_difference = all(check["passed"] for check in finite_differences)
    all_checks = Dict(
        "coordinate_convention" => all(values(convention_checks)),
        "native_endpoint_equivalence" => endpoint_gate["passed"],
        "exact_sum_product_endpoint" => bp["passed"],
        "parity_base_equivalence" => base["passed"],
        "adjacent_field_hashes" => adjacency["passed"],
        "finite_differences" => all_finite_difference,
        "projection_and_frozen_state" => projection_frozen["passed"],
        "line_search_prefix" => prefix_comparison["passed"],
        "current_native_composition" => current_composition["passed"],
        "archived_native_composition" => archived_composition["passed"],
        "zero_decoder_calls_in_coral" => current_native["decoder_calls"] == 0 &&
            archived_native["decoder_calls"] == 0,
        "zero_pseudogradient_calls_in_coral" =>
            current_native["pseudogradient_calls"] == 0 &&
            archived_native["pseudogradient_calls"] == 0,
    )
    passed = all(values(all_checks))
    Dict(
        "schema_version" => "rq1-endpoint-001/science-v1",
        "experiment_id" => "RQ1-ENDPOINT-001",
        "status" => passed ? "valid" : "invalid",
        "validation_passed" => passed,
        "downstream_cards_executed" => true,
        "graph" => Dict("checks" => checks,
                         "edge_order" => config["graph"]["edge_order"]),
        "channel_evidence" => Dict(
            "convention" => config["channel_evidence"]["convention"],
            "L_bit1_positive" => L,
            "ell_bit0_positive" => ell,
        ),
        "source_gate" => source_validation,
        "coordinate_card" => Dict(
            "card_id" => "RQ1-CONVENTION-001",
            "checks" => convention_checks,
            "passed" => all(values(convention_checks)),
        ),
        "bp_card" => merge(Dict("card_id" => "RQ1-ENDPOINT-BP-001"), bp),
        "native_endpoint_equivalence" => Dict(
            "gate" => endpoint_gate,
            "current" => current_native,
            "archived" => archived_native,
        ),
        "parity_base_card" => base,
        "fingerprints" => [Dict(
            "card_id" => fingerprint["card_id"],
            "payload" => fingerprint_payload(fingerprint),
            "payload_sha256" => scientific_sha256(fingerprint_payload(fingerprint)),
        ) for fingerprint in fingerprints],
        "adjacent_field_hashes" => adjacency,
        "rung_results" => [Dict(
            "card_id" => fingerprint["card_id"],
            "result" => result,
            "finite_difference" => finite_difference,
        ) for (fingerprint, result, finite_difference) in
            zip(fingerprints, rung_results, finite_differences)],
        "projection_and_frozen_state" => projection_frozen,
        "line_search_prefix" => prefix_comparison,
        "current_native_composition" => current_composition,
        "archived_native_composition" => archived_composition,
        "validation_checks" => all_checks,
    )
end

function git_output(repo, arguments...)
    try
        readchomp(Cmd(vcat(["git", "-C", repo], String.(arguments))))
    catch error
        "ERROR: " * sprint(showerror, error)
    end
end

function provenance(config, config_path, source_validation)
    sources = config["sources"]
    jade_repo = String(sources["jade_repo"])
    sp_repo = normpath(joinpath(HERE, "..", ".."))
    current_runner = String(sources["current_runner"])
    archived_runner = String(sources["archived_runner"])
    status_sp = git_output(sp_repo, "status", "--porcelain=v1", "--untracked-files=all")
    status_jade = git_output(jade_repo, "status", "--porcelain=v1", "--untracked-files=all")
    Dict(
        "julia_version" => string(VERSION),
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "config_path" => abspath(config_path),
        "config_sha256" => file_sha256(config_path),
        "runner_path" => abspath(RUNNER_PATH),
        "runner_sha256" => file_sha256(RUNNER_PATH),
        "experiment_card_sha256" => file_sha256(joinpath(HERE, "experiment_card.md")),
        "current_runner_path" => current_runner,
        "current_runner_sha256" => isfile(current_runner) ? file_sha256(current_runner) : "missing",
        "archived_runner_path" => archived_runner,
        "archived_runner_sha256" => isfile(archived_runner) ? file_sha256(archived_runner) : "missing",
        "source_gate" => source_validation,
        "sp_repo" => sp_repo,
        "sp_git_head" => git_output(sp_repo, "rev-parse", "HEAD"),
        "sp_git_status_porcelain_v1" => status_sp,
        "sp_git_status_sha256" => bytes2hex(sha256(codeunits(status_sp))),
        "jade_repo" => jade_repo,
        "jade_git_head" => git_output(jade_repo, "rev-parse", "HEAD"),
        "jade_git_status_porcelain_v1" => status_jade,
        "jade_git_status_sha256" => bytes2hex(sha256(codeunits(status_jade))),
        "archived_commit_resolved" => git_output(
            jade_repo, "rev-parse", String(sources["archived_commit"]) * "^{commit}"),
        "core_common_sha256" => file_sha256(joinpath(jade_repo, "src", "core", "common.jl")),
        "core_projected_gradient_sha256" => file_sha256(joinpath(
            jade_repo, "src", "core", "joint_cz_projected_gradient.jl")),
    )
end

function write_new_file(path, content)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    open(path, "w") do io
        write(io, content)
    end
end

function write_result_directory(output, science, replay_hash, replay_passed,
                                provenance_record, config_path, command)
    ispath(output) && throw(ArgumentError("output directory already exists: $output"))
    output_parent = dirname(output)
    ispath(output_parent) && !isdir(output_parent) &&
        throw(ArgumentError("output parent is not a directory: $output_parent"))
    isdir(output_parent) || mkpath(output_parent)
    mkdir(output)
    trace_text = canonical_json(science) * "\n"
    trace_path = joinpath(output, "trace.json")
    write_new_file(trace_path, trace_text)
    trace_hash = file_sha256(trace_path)
    manifest = Dict(
        "schema_version" => "rq1-endpoint-001/manifest-v1",
        "experiment_id" => "RQ1-ENDPOINT-001",
        "created_utc" => string(now(UTC)),
        "status" => science["status"],
        "validation_passed" => science["validation_passed"],
        "non_overwrite_gate" => true,
        "scientific_trace_sha256" => trace_hash,
        "independent_replay_sha256" => replay_hash,
        "deterministic_replay_passed" => replay_passed,
        "scientific_hash_scope" => "canonical trace JSON; runtime and provenance excluded",
        "config_path" => abspath(config_path),
        "exact_command" => command,
        "provenance" => provenance_record,
    )
    manifest_path = joinpath(output, "manifest.json")
    write_new_file(manifest_path, canonical_json(manifest) * "\n")
    source_directory = joinpath(output, "source")
    mkdir(source_directory)
    retained_sources = Dict(
        "config.toml" => abspath(config_path),
        "experiment_card.md" => joinpath(HERE, "experiment_card.md"),
        "rq1_endpoint_001.jl" => RUNNER_PATH,
        "current_run_three_receivers.jl" => String(provenance_record["current_runner_path"]),
        "archived_r050_run_three_receivers.jl" => String(provenance_record["archived_runner_path"]),
    )
    for (name, source) in retained_sources
        write_new_file(joinpath(source_directory, name), read(source, String))
    end
    checksum_entries = Dict(
        "trace.json" => file_sha256(trace_path),
        "manifest.json" => file_sha256(manifest_path),
    )
    for name in keys(retained_sources)
        relative = "source/$name"
        checksum_entries[relative] = file_sha256(joinpath(output, relative))
    end
    checksum_text = join(("$(checksum_entries[name])  $name"
                          for name in sort!(collect(keys(checksum_entries)))), "\n") * "\n"
    write_new_file(joinpath(output, "MANIFEST.sha256"), checksum_text)
    (; trace_hash, manifest, checksum_entries)
end

function execute(; config_path::AbstractString=DEFAULT_CONFIG,
                   output::AbstractString,
                   command::AbstractString="julia rq1_endpoint_001.jl")
    ispath(output) && throw(ArgumentError("output directory already exists: $output"))
    config = load_config(config_path)
    source_validation = source_gate(config)
    provenance_record = provenance(config, config_path, source_validation)
    science = if source_validation["passed"]
        try
            oracles = load_oracles(config)
            Base.invokelatest(calculate_science, config, oracles;
                source_validation=source_validation)
        catch error
            invalid_science("native_endpoint_load_or_execution_error: " *
                            sprint(showerror, error), source_validation)
        end
    else
        invalid_science("source_provenance_gate_failed", source_validation)
    end
    replay = if science["status"] == "invalid" &&
                !get(science, "downstream_cards_executed", false)
        deepcopy(science)
    else
        oracles = load_oracles(config)
        Base.invokelatest(calculate_science, config, oracles;
            source_validation=source_validation)
    end
    first_hash = scientific_sha256(science)
    replay_hash = scientific_sha256(replay)
    replay_passed = first_hash == replay_hash
    science["deterministic_replay"] = Dict(
        "first_sha256" => first_hash,
        "second_sha256" => replay_hash,
        "passed" => replay_passed,
    )
    science["validation_passed"] &= replay_passed
    replay_passed || (science["status"] = "invalid")
    written = write_result_directory(output, science, replay_hash, replay_passed,
        provenance_record, config_path, command)
    (; science, written)
end

function parse_cli(arguments)
    config_path = DEFAULT_CONFIG
    output = nothing
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        if argument == "--config"
            index += 1
            index <= length(arguments) || throw(ArgumentError("--config requires a path"))
            config_path = arguments[index]
        elseif argument == "--output"
            index += 1
            index <= length(arguments) || throw(ArgumentError("--output requires a path"))
            output = arguments[index]
        elseif argument in ("-h", "--help")
            return (; help=true, config_path, output)
        else
            throw(ArgumentError("unknown argument: $argument"))
        end
        index += 1
    end
    (; help=false, config_path, output)
end

function main(arguments=ARGS)
    parsed = parse_cli(arguments)
    if parsed.help
        println("usage: julia --project=/path/to/JadeJcade rq1_endpoint_001.jl --output DIR [--config FILE]")
        return 0
    end
    parsed.output === nothing && throw(ArgumentError("--output is required"))
    command = join(["julia", "--project=/home/gabiel/Documents/GitHub/JadeJcade",
                    abspath(RUNNER_PATH), arguments...], " ")
    result = execute(; config_path=parsed.config_path, output=parsed.output, command)
    println("RQ1-ENDPOINT-001 status: ", result.science["status"])
    println("trace SHA-256: ", result.written.trace_hash)
    result.science["validation_passed"] ? 0 : 2
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(main())
end

end # module
