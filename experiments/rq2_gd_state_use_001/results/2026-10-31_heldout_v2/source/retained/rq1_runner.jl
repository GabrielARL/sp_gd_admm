#!/usr/bin/env julia

module RQ1GDStateUse001

using Dates
using LinearAlgebra
using Printf
using SHA
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__
const TEST_PATH = joinpath(HERE, "test_rq1_gd_state_use_001.jl")

export load_config, source_gate, endpoint_lock_gate, load_dependencies,
       objective_decomposition, finite_difference_check, calculate_case,
       calculate_science, canonical_json, scientific_sha256, execute, main

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

"""Return stable JSON for scientific replay hashes."""
function canonical_json(value)
    if value === nothing
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

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq1-gd-state-use-001/v1" ||
        throw(ArgumentError("unsupported check-specific-state ablation study schema"))
    config["experiment_id"] == "RQ1-GD-STATE-USE-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["cases"]["tree"]["checks"] == [[1, 2], [2, 3]] ||
        throw(ArgumentError("tree anchor graph changed"))
    config["cases"]["cycle"]["checks"] == [[1, 2], [2, 3], [1, 3]] ||
        throw(ArgumentError("cycle confirmation graph changed"))
    values = Float64.(config["channel_evidence"]["values_bit1_positive"])
    expected = [-log(9.0), log(3.0 / 2.0), log(2.0)]
    maximum(abs, values - expected) <= 1.0e-15 ||
        throw(ArgumentError("configured LLR decimals do not reproduce symbolic values"))
    config["intervention"]["cell_order"] == [
        "collapsed__ignored", "retained__ignored",
        "collapsed__consumed", "retained__consumed",
    ] || throw(ArgumentError("registered cell order changed"))
    config
end

checks_for(config, case_name::AbstractString) =
    [Int.(check) for check in config["cases"][case_name]["checks"]]

function zero_edge_rows(checks)
    [zeros(Float64, length(check)) for check in checks]
end

copy_edge_rows(rows) = [Float64.(row) for row in rows]
flatten_edge_rows(rows) = Float64[value for row in rows for value in row]

function variable_edges(checks, n)
    edges = [Tuple{Int,Int}[] for _ in 1:n]
    for (check_index, check) in enumerate(checks), (slot, bit) in enumerate(check)
        1 <= bit <= n || throw(ArgumentError("bit index outside 1:$n"))
        push!(edges[bit], (check_index, slot))
    end
    edges
end

function syndrome(checks, bits)
    [foldl(xor, (Bool(bits[bit]) for bit in check); init=false) ? 1 : 0
     for check in checks]
end

function syndrome_integer_mod2(checks, bits)
    [mod(sum(Int(bits[bit]) for bit in check; init=0), 2) for check in checks]
end

function source_gate(config)
    sources = config["sources"]
    specifications = [
        ("endpoint_config", "endpoint_config_sha256"),
        ("endpoint_card", "endpoint_card_sha256"),
        ("endpoint_runner", "endpoint_runner_sha256"),
        ("endpoint_test", "endpoint_test_sha256"),
        ("current_native_runner", "current_native_runner_sha256"),
        ("archived_native_runner", "archived_native_runner_sha256"),
    ]
    records = Dict{String,Any}()
    passed = true
    for (path_key, hash_key) in specifications
        path = String(sources[path_key])
        expected = String(sources[hash_key])
        exists = isfile(path)
        observed = exists ? file_sha256(path) : "missing"
        valid = exists && observed == expected
        records[path_key] = Dict(
            "path" => path,
            "exists" => exists,
            "expected_sha256" => expected,
            "observed_sha256" => observed,
            "passed" => valid,
        )
        passed &= valid
    end
    Dict("passed" => passed, "records" => records)
end

function load_endpoint_module(path::AbstractString)
    isfile(path) || throw(ArgumentError("endpoint module not found: $path"))
    container = Module(gensym(:RQ1GDStateUseEndpointContainer))
    Base.include(container, path)
    isdefined(container, :RQ1Endpoint001) ||
        throw(ArgumentError("endpoint source did not define RQ1Endpoint001"))
    Base.invokelatest(getfield, container, :RQ1Endpoint001)
end

function load_dependencies(config)
    sources = config["sources"]
    endpoint = load_endpoint_module(String(sources["endpoint_runner"]))
    load_config = Base.invokelatest(getfield, endpoint, :load_config)
    load_oracles = Base.invokelatest(getfield, endpoint, :load_oracles)
    endpoint_config = Base.invokelatest(
        load_config, String(sources["endpoint_config"]))
    oracles = Base.invokelatest(load_oracles, endpoint_config)
    (; endpoint, endpoint_config, oracles)
end

function endpoint_lock_gate(config, endpoint_config)
    projected = config["projected_gradient"]
    endpoint_projected = endpoint_config["projected_gradient"]
    L = Float64.(config["channel_evidence"]["values_bit1_positive"])
    endpoint_L = Float64.(endpoint_config["channel_evidence"]["values"])
    checks = checks_for(config, "tree")
    cycle = checks_for(config, "cycle")
    gates = Dict(
        "tree_graph" => checks == [Int.(row) for row in endpoint_config["graph"]["checks"]],
        "tree_edge_order" => config["cases"]["tree"]["edge_order"] ==
            endpoint_config["graph"]["edge_order"],
        "cycle_graph" => cycle == [[1, 2], [2, 3], [1, 3]],
        "cycle_edge_order" => config["cases"]["cycle"]["edge_order"] ==
            ["b0-c0", "b1-c0", "b1-c1", "b2-c1", "b0-c2", "b2-c2"],
        "channel_values" => L == endpoint_L,
        "channel_convention" => config["channel_evidence"]["convention"] ==
            endpoint_config["channel_evidence"]["convention"],
        "parity_weight" => Float64(projected["parity_weight"]) ==
            Float64(endpoint_projected["parity_weight"]),
        "binary_weight" => Float64(projected["binary_weight"]) ==
            Float64(endpoint_projected["binary_weight"]),
        "initial_step" => Float64(projected["initial_step"]) ==
            Float64(endpoint_projected["native_initial_step"]),
        "maximum_backtracks" => Int(projected["maximum_backtracks"]) ==
            Int(endpoint_projected["maximum_backtracks"]),
        "box_lower" => Float64(projected["box_lower"]) ==
            Float64(endpoint_projected["box_lower"]),
        "box_upper" => Float64(projected["box_upper"]) ==
            Float64(endpoint_projected["box_upper"]),
        "native_preconditioner" => projected["preconditioner"] ==
            "native_curvature_bound",
        "strict_decrease" => projected["line_search"] ==
            "first_strict_decrease",
        "two_updates" => Int(config["scope"]["updates_per_case"]) == 2,
    )
    Dict("checks" => gates, "passed" => all(values(gates)))
end

function product_except(values, omitted)
    result = 1.0
    for index in eachindex(values)
        index == omitted && continue
        result *= values[index]
    end
    result
end

"""Evaluate F_delta and the corresponding partial derivatives of the objective function with delta held fixed."""
function objective_decomposition(x, ell, checks, projected;
                                 delta_rows=zero_edge_rows(checks))
    n = length(x)
    length(ell) == n || throw(DimensionMismatch("LLR and scalar lengths differ"))
    length(delta_rows) == length(checks) ||
        throw(DimensionMismatch("delta and check-row counts differ"))
    parity_weight = Float64(projected["parity_weight"])
    binary_weight = Float64(projected["binary_weight"])

    channel = -dot(ell, x) / (2n)
    h = zeros(Float64, n)
    raw_binary = 0.0
    for bit in eachindex(x)
        raw_binary += (1.0 - x[bit]^2)^2
    end

    raw_parity = 0.0
    check_products = Float64[]
    check_residuals = Float64[]
    check_readings = Vector{Vector{Float64}}()
    g_rows = [zeros(Float64, length(check)) for check in checks]
    # Preserve the native endpoint's accumulation order exactly: parity first,
    # then channel evidence, then the binary contribution.  `h` is calculated
    # separately for constructing the check-indexed values and does not change that order.
    gradient = zeros(Float64, n)
    for (check_index, check) in enumerate(checks)
        length(delta_rows[check_index]) == length(check) ||
            throw(DimensionMismatch("delta row $check_index has the wrong length"))
        readings = [Float64(x[bit]) + Float64(delta_rows[check_index][slot])
                    for (slot, bit) in enumerate(check)]
        product = prod(readings)
        residual = 1.0 - product
        push!(check_readings, readings)
        push!(check_products, product)
        push!(check_residuals, residual)
        raw_parity += residual^2
        coefficient = -2.0 * parity_weight * residual / n
        for (slot, bit) in enumerate(check)
            contribution = coefficient * product_except(readings, slot)
            g_rows[check_index][slot] = contribution
            gradient[bit] += contribution
        end
    end

    gradient .-= ell ./ (2n)
    for bit in eachindex(x)
        binary_contribution =
            4.0 * binary_weight * x[bit] * (x[bit]^2 - 1.0) / n
        gradient[bit] += binary_contribution
        h[bit] = -ell[bit] / (2n) + binary_contribution
    end

    parity = parity_weight * raw_parity / n
    binary = binary_weight * raw_binary / n
    Dict(
        "loss" => channel + parity + binary,
        "gradient" => gradient,
        "h" => h,
        "g_rows" => g_rows,
        "check_readings" => check_readings,
        "check_products" => check_products,
        "check_residuals" => check_residuals,
        "terms" => Dict(
            "channel" => channel,
            "parity" => parity,
            "binary" => binary,
            "raw_parity" => raw_parity,
            "raw_binary" => raw_binary,
        ),
    )
end

function objective_loss(x, ell, checks, projected, delta_rows)
    objective_decomposition(x, ell, checks, projected;
                            delta_rows=delta_rows)["loss"]
end

function independent_box_projection(raw, lower, upper)
    [value < lower ? lower : (value > upper ? upper : value) for value in raw]
end

function bit_degrees(checks, n)
    edges = variable_edges(checks, n)
    [length(edge_list) for edge_list in edges]
end

function curvature_bound(checks, n, projected)
    parity_weight = Float64(projected["parity_weight"])
    binary_weight = Float64(projected["binary_weight"])
    [(2.0 * parity_weight * degree + 8.0 * binary_weight) / n
     for degree in bit_degrees(checks, n)]
end

function readings_in_box(evaluation, lower, upper; strict::Bool=false,
                         margin::Float64=0.0)
    values = flatten_edge_rows(evaluation["check_readings"])
    if strict
        return all(value -> lower + margin < value < upper - margin, values)
    end
    all(value -> lower <= value <= upper, values)
end

function finite_difference_check(x, ell, checks, projected, delta_rows, config)
    h = Float64(config["validation"]["finite_difference_step"])
    tolerance = Float64(config["validation"]["finite_difference_tolerance"])
    lower = Float64(projected["box_lower"])
    upper = Float64(projected["box_upper"])
    analytic = objective_decomposition(
        x, ell, checks, projected; delta_rows=delta_rows)["gradient"]
    numerical = similar(analytic)
    all_points_in_domain = true
    point_records = Dict{String,Any}[]
    for bit in eachindex(x)
        plus, minus = copy(x), copy(x)
        plus[bit] += h
        minus[bit] -= h
        plus_evaluation = objective_decomposition(
            plus, ell, checks, projected; delta_rows=delta_rows)
        minus_evaluation = objective_decomposition(
            minus, ell, checks, projected; delta_rows=delta_rows)
        plus_in_domain = all(lower .<= plus .<= upper) &&
            readings_in_box(plus_evaluation, lower, upper)
        minus_in_domain = all(lower .<= minus .<= upper) &&
            readings_in_box(minus_evaluation, lower, upper)
        all_points_in_domain &= plus_in_domain && minus_in_domain
        numerical[bit] = (plus_evaluation["loss"] - minus_evaluation["loss"]) / (2h)
        push!(point_records, Dict(
            "bit" => bit,
            "plus_in_domain" => plus_in_domain,
            "minus_in_domain" => minus_in_domain,
        ))
    end
    error = maximum(abs, analytic - numerical)
    Dict(
        "analytic" => analytic,
        "numerical" => numerical,
        "maximum_absolute_error" => error,
        "tolerance" => tolerance,
        "delta_sha256_before" => scientific_sha256(delta_rows),
        "delta_sha256_after" => scientific_sha256(delta_rows),
        "delta_held_fixed" => true,
        "points" => point_records,
        "all_points_in_domain" => all_points_in_domain,
        "passed" => error <= tolerance && all_points_in_domain,
    )
end

function single_update(x, ell, checks, projected, delta_rows)
    lower = Float64(projected["box_lower"])
    upper = Float64(projected["box_upper"])
    initial_step = Float64(projected["initial_step"])
    maximum_backtracks = Int(projected["maximum_backtracks"])
    before = objective_decomposition(
        x, ell, checks, projected; delta_rows=delta_rows)
    kappa = curvature_bound(checks, length(x), projected)
    direction = -Float64.(before["gradient"]) ./ kappa
    frozen_x_hash = scientific_sha256(x)
    fixed_delta_hash = scientific_sha256(delta_rows)
    trials = Dict{String,Any}[]
    accepted_index = nothing
    accepted_evaluation = nothing
    accepted_raw = Float64[]
    accepted_projected = Float64[]
    for backtrack in 0:maximum_backtracks
        step = initial_step * 0.5^backtrack
        raw = Float64.(x) .+ step .* direction
        projected_x = independent_box_projection(raw, lower, upper)
        evaluated = objective_decomposition(
            projected_x, ell, checks, projected; delta_rows=delta_rows)
        independent = clamp.(Float64.(raw), lower, upper)
        projection_error = maximum(abs, independent - projected_x)
        in_domain = all(lower .<= projected_x .<= upper) &&
            readings_in_box(evaluated, lower, upper)
        strict_decrease = isfinite(evaluated["loss"]) &&
            evaluated["loss"] < before["loss"]
        push!(trials, Dict(
            "backtrack_index" => backtrack,
            "step" => step,
            "raw_proposal" => raw,
            "projected_proposal" => projected_x,
            "active_projection_coordinates" => [
                bit for bit in eachindex(raw) if raw[bit] != projected_x[bit]
            ],
            "projection_error" => projection_error,
            "check_readings_in_box" => in_domain,
            "objective" => evaluated["loss"],
            "terms" => evaluated["terms"],
            "evaluation" => evaluated,
            "strict_decrease" => strict_decrease,
            "fixed_delta_sha256" => scientific_sha256(delta_rows),
        ))
        if strict_decrease
            accepted_index = length(trials)
            accepted_evaluation = evaluated
            accepted_raw = raw
            accepted_projected = projected_x
            break
        end
    end
    accepted = accepted_index !== nothing
    after_x = accepted ? accepted_projected : Float64.(x)
    after = accepted ? accepted_evaluation : before
    recomputed = objective_decomposition(
        x, ell, checks, projected; delta_rows=delta_rows)
    frozen_gradient_error = maximum(abs,
        Float64.(recomputed["gradient"]) - Float64.(before["gradient"]))
    proposal_error = accepted ? maximum(abs,
        Float64.(x) .+ Float64(trials[accepted_index]["step"]) .* direction -
        accepted_raw) : 0.0
    all_trial_readings_in_box = all(trial["check_readings_in_box"] for trial in trials)
    all_projection_checks = all(trial["projection_error"] == 0.0 for trial in trials)
    Dict(
        "x_before" => Float64.(x),
        "frozen_x_sha256" => frozen_x_hash,
        "fixed_delta" => copy_edge_rows(delta_rows),
        "fixed_delta_sha256_before" => fixed_delta_hash,
        "fixed_delta_sha256_after" => scientific_sha256(delta_rows),
        "delta_held_fixed" => fixed_delta_hash == scientific_sha256(delta_rows),
        "evaluation_before" => before,
        "kappa" => kappa,
        "direction" => direction,
        "trials" => trials,
        "accepted" => accepted,
        "accepted_trial_index" => accepted_index,
        "accepted_step" => accepted ? Float64(trials[accepted_index]["step"]) : 0.0,
        "accepted_raw_proposal" => accepted_raw,
        "accepted_projected_proposal" => accepted_projected,
        "x_after" => after_x,
        "evaluation_after" => after,
        "status" => accepted ? "steps_completed" : "line_search_stalled",
        "frozen_gradient_error" => frozen_gradient_error,
        "proposal_error" => proposal_error,
        "all_trial_readings_in_box" => all_trial_readings_in_box,
        "all_projection_checks" => all_projection_checks,
    )
end

named_terms(terms) = Dict(String(key) => Float64(getfield(terms, key))
                          for key in keys(terms))

function native_summary(oracle, checks, ell, initial, projected, steps)
    problem = Base.invokelatest(
        oracle.ScalarProblem, checks, length(ell), ell;
        parity_weight=Float64(projected["parity_weight"]),
        binary_weight=Float64(projected["binary_weight"]))
    evaluated = Base.invokelatest(oracle.objective_gradient, problem, initial)
    solved = Base.invokelatest(
        oracle.solve_scalar, problem, initial;
        steps=Int(steps), initial_step=Float64(projected["initial_step"]))
    Dict(
        "x" => Float64.(solved.x),
        "initial_objective" => Float64(solved.initial_objective),
        "initial_terms" => named_terms(solved.initial_terms),
        "initial_gradient" => Float64.(evaluated.gradient),
        "final_objective" => Float64(solved.final_objective),
        "final_terms" => named_terms(solved.final_terms),
        "objective_history" => Float64.(solved.objective_history),
        "accepted_steps" => Int(solved.accepted_steps),
        "steps_requested" => Int(solved.steps_requested),
        "objective_evaluations" => Int(solved.objective_evaluations),
        "status" => String(solved.status),
        "gradient_kind" => String(solved.gradient_kind),
        "pseudogradient_calls" => Int(solved.pseudogradient_calls),
        "decoder_calls" => Int(solved.decoder_calls),
        "curvature_bound" => Float64.(problem.curvature_bound),
    )
end

function update1_native_view(update)
    before = update["evaluation_before"]
    after = update["evaluation_after"]
    history = Float64[before["loss"]]
    update["accepted"] && push!(history, after["loss"])
    Dict(
        "x" => update["x_after"],
        "initial_objective" => before["loss"],
        "initial_terms" => Dict(key => before["terms"][key]
                                for key in ("channel", "parity", "binary")),
        "initial_gradient" => before["gradient"],
        "final_objective" => after["loss"],
        "final_terms" => Dict(key => after["terms"][key]
                              for key in ("channel", "parity", "binary")),
        "objective_history" => history,
        "accepted_steps" => update["accepted"] ? 1 : 0,
        "steps_requested" => 1,
        "objective_evaluations" => 1 + length(update["trials"]),
        "status" => update["status"],
        "gradient_kind" => "exact_analytic_product",
        "pseudogradient_calls" => 0,
        "decoder_calls" => 0,
        "curvature_bound" => update["kappa"],
    )
end

function composed_two_update_view(update1, update2)
    initial = update1["evaluation_before"]
    final = update2["evaluation_after"]
    history = Float64[initial["loss"]]
    update1["accepted"] && push!(history, update1["evaluation_after"]["loss"])
    update2["accepted"] && push!(history, final["loss"])
    accepted_steps = (update1["accepted"] ? 1 : 0) +
        (update2["accepted"] ? 1 : 0)
    Dict(
        "x" => update2["x_after"],
        "initial_objective" => initial["loss"],
        "initial_terms" => Dict(key => initial["terms"][key]
                                for key in ("channel", "parity", "binary")),
        "initial_gradient" => initial["gradient"],
        "final_objective" => final["loss"],
        "final_terms" => Dict(key => final["terms"][key]
                              for key in ("channel", "parity", "binary")),
        "objective_history" => history,
        "accepted_steps" => accepted_steps,
        "steps_requested" => 2,
        "objective_evaluations" => 1 + length(update1["trials"]) +
            length(update2["trials"]),
        "status" => update1["accepted"] ? update2["status"] : update1["status"],
        "gradient_kind" => "exact_analytic_product",
        "pseudogradient_calls" => 0,
        "decoder_calls" => 0,
        "curvature_bound" => update1["kappa"],
    )
end

function construct_check_indexed_values(x0, ell, checks, projected, update1, config)
    n = length(x0)
    edges = variable_edges(checks, n)
    evaluation = update1["evaluation_before"]
    native_gradient = Float64.(evaluation["gradient"])
    h = Float64.(evaluation["h"])
    g_rows = evaluation["g_rows"]
    local_values = zero_edge_rows(checks)
    decomposition_error = zeros(Float64, n)
    mean_error = zeros(Float64, n)
    degree_one_rule_error = zeros(Float64, n)
    for bit in 1:n
        incident = edges[bit]
        reconstructed = h[bit] + sum(
            Float64(g_rows[check_index][slot])
            for (check_index, slot) in incident; init=0.0)
        decomposition_error[bit] = abs(reconstructed - native_gradient[bit])
        degree = length(incident)
        degree > 0 || throw(ArgumentError(
            "isolated bits are outside this check-specific-state intervention"))
        for (indexed_check, indexed_slot) in incident
            value = if degree == 1
                native_gradient[bit]
            else
                other_sum = sum(
                    Float64(g_rows[check_index][slot])
                    for (check_index, slot) in incident
                    if check_index != indexed_check; init=0.0)
                h[bit] + degree / (degree - 1) * other_sum
            end
            local_values[indexed_check][indexed_slot] = value
            if degree == 1
                degree_one_rule_error[bit] = max(
                    degree_one_rule_error[bit], abs(value - native_gradient[bit]))
            end
        end
        mean_value = sum(
            local_values[check_index][slot]
            for (check_index, slot) in incident; init=0.0) / degree
        mean_error[bit] = abs(mean_value - native_gradient[bit])
    end

    update1["accepted"] || return Dict(
        "passed" => false,
        "invalid_reason" => "native_update_1_stalled",
    )
    alpha = Float64(update1["accepted_step"])
    kappa = Float64.(update1["kappa"])
    native_raw = Float64.(update1["accepted_raw_proposal"])
    local_raw = zero_edge_rows(checks)
    delta = zero_edge_rows(checks)
    for (check_index, check) in enumerate(checks), (slot, bit) in enumerate(check)
        local_raw[check_index][slot] =
            Float64(x0[bit]) - alpha * local_values[check_index][slot] / kappa[bit]
        delta[check_index][slot] = local_raw[check_index][slot] - native_raw[bit]
    end

    lower = Float64(projected["box_lower"])
    upper = Float64(projected["box_upper"])
    margin = Float64(config["validation"]["strict_interior_margin"])
    native_projection_inactive = all(bit ->
        lower + margin < native_raw[bit] < upper - margin &&
        native_raw[bit] == update1["accepted_projected_proposal"][bit],
        eachindex(native_raw))
    local_projection_inactive = all(value ->
        lower + margin < value < upper - margin, flatten_edge_rows(local_raw))

    x1 = Float64.(update1["x_after"])
    reconstruction_error = 0.0
    for (check_index, check) in enumerate(checks), (slot, bit) in enumerate(check)
        reconstructed = x1[bit] + delta[check_index][slot]
        reconstruction_error = max(reconstruction_error,
            abs(reconstructed - local_raw[check_index][slot]))
    end
    active_initial_evaluation = objective_decomposition(
        x1, ell, checks, projected; delta_rows=delta)
    initial_readings_error = maximum(abs,
        flatten_edge_rows(active_initial_evaluation["check_readings"]) -
        flatten_edge_rows(local_raw))
    zero_sum = zeros(Float64, n)
    degree_one_delta = zeros(Float64, n)
    for bit in 1:n
        incident = edges[bit]
        zero_sum[bit] = sum(delta[check_index][slot]
                            for (check_index, slot) in incident; init=0.0)
        if length(incident) == 1
            check_index, slot = only(incident)
            degree_one_delta[bit] = delta[check_index][slot]
        end
    end
    tolerance = Float64(config["validation"]["absolute_tolerance"])
    zero_tolerance = Float64(config["validation"]["zero_sum_tolerance"])
    delta_maximum = maximum(abs, flatten_edge_rows(delta))
    delta_hash_distinct = scientific_sha256(delta) !=
        scientific_sha256(zero_edge_rows(checks))
    checks_gate = Dict(
        "gradient_decomposition" => maximum(decomposition_error) <= tolerance,
        "constructed_value_mean" => maximum(mean_error) <= tolerance,
        "degree_one_rule" => maximum(degree_one_rule_error) <= tolerance,
        "native_first_projection_inactive" => native_projection_inactive,
        "local_first_projection_inactive" => local_projection_inactive,
        "delta_zero_sum" => maximum(abs, zero_sum) <= zero_tolerance,
        "degree_one_delta_zero" => maximum(abs, degree_one_delta) <= zero_tolerance,
        "local_raw_reconstruction" => reconstruction_error <= tolerance,
        "initial_check_readings_reconstruction" => initial_readings_error <= tolerance,
        "registered_delta_nonzero" => delta_maximum > tolerance && delta_hash_distinct,
    )
    Dict(
        "native_gradient" => native_gradient,
        "h" => h,
        "g_rows" => g_rows,
        "constructed_values_leaving_out_indexed_check" => local_values,
        "accepted_step" => alpha,
        "kappa" => kappa,
        "native_raw" => native_raw,
        "local_raw" => local_raw,
        "delta" => delta,
        "delta_maximum_absolute" => delta_maximum,
        "active_initial_evaluation" => active_initial_evaluation,
        "decomposition_error_by_bit" => decomposition_error,
        "constructed_value_mean_error_by_bit" => mean_error,
        "degree_one_rule_error_by_bit" => degree_one_rule_error,
        "delta_sum_by_bit" => zero_sum,
        "degree_one_delta_by_bit" => degree_one_delta,
        "reconstruction_error" => reconstruction_error,
        "checks" => checks_gate,
        "passed" => all(values(checks_gate)),
    )
end

function operation_counts(checks, n, update)
    edge_count = sum(length, checks)
    evaluations = 1 + length(update["trials"])
    Dict(
        "objective_evaluations" => evaluations,
        "check_products" => evaluations * length(checks),
        "leave_one_products" => evaluations * edge_count,
        "channel_contributions" => evaluations * n,
        "binary_contributions" => evaluations * n,
        "parity_contributions" => evaluations * edge_count,
        "preconditioner_divisions" => n,
        "projection_comparisons" => 2 * n * length(update["trials"]),
    )
end

function cell_path_view(cell)
    Dict(
        "effective_delta" => cell["effective_delta"],
        "update2" => cell["update2"],
        "hard_decision" => cell["hard_decision"],
        "syndrome" => cell["syndrome"],
        "finite_difference" => cell["finite_difference"],
        "operation_counts" => cell["operation_counts"],
    )
end

function run_cell(cell_id, x1, ell, checks, projected,
                  check_indexed_values, update1_hash, config)
    retained = startswith(cell_id, "retained__")
    used_in_update2 = endswith(cell_id, "__consumed")
    zeros_rows = zero_edge_rows(checks)
    state = retained ? copy_edge_rows(check_indexed_values["delta"]) :
        copy_edge_rows(zeros_rows)
    effective = used_in_update2 ? copy_edge_rows(state) : copy_edge_rows(zeros_rows)
    state_hash_before = scientific_sha256(state)
    effective_hash_before = scientific_sha256(effective)
    update2 = single_update(x1, ell, checks, projected, effective)
    finite_difference = finite_difference_check(
        x1, ell, checks, projected, effective, config)
    hard = [value < 0.0 ? 1 : 0 for value in update2["x_after"]]
    parity = syndrome(checks, hard)
    edge_count = sum(length, checks)
    Dict(
        "cell_id" => cell_id,
        "retention" => retained ? "retained" : "collapsed",
        "use_in_update2" => used_in_update2 ? "used" : "ignored",
        "entry_update1_sha256" => update1_hash,
        "x_entry" => Float64.(x1),
        "retained_state" => state,
        "retained_state_sha256_before" => state_hash_before,
        "retained_state_sha256_after" => scientific_sha256(state),
        "effective_delta" => effective,
        "effective_delta_sha256_before" => effective_hash_before,
        "effective_delta_sha256_after" => scientific_sha256(effective),
        "update2" => update2,
        "finite_difference" => finite_difference,
        "hard_decision" => hard,
        "syndrome" => parity,
        "syndrome_recomputed" => syndrome_integer_mod2(checks, hard),
        "operation_counts" => operation_counts(checks, length(x1), update2),
        "stored_state_counts" => Dict(
            "physical_scalar_slots_allocated" => length(x1),
            "physical_check_specific_slots_allocated" => edge_count,
            "logical_scalar_values_retained" => length(x1),
            "logical_check_specific_values_retained" => retained ? edge_count : 0,
        ),
    )
end

function native_initial_view(summary)
    Dict(
        "loss" => summary["initial_objective"],
        "gradient" => summary["initial_gradient"],
        "terms" => summary["initial_terms"],
    )
end

function independent_initial_view(evaluation)
    Dict(
        "loss" => evaluation["loss"],
        "gradient" => evaluation["gradient"],
        "terms" => Dict(key => evaluation["terms"][key]
                        for key in ("channel", "parity", "binary")),
    )
end

function update_validity(cell, projected, config)
    update = cell["update2"]
    tolerance = Float64(config["validation"]["absolute_tolerance"])
    lower = Float64(projected["box_lower"])
    upper = Float64(projected["box_upper"])
    current_in_domain = all(lower .<= update["x_before"] .<= upper) &&
        readings_in_box(update["evaluation_before"], lower, upper)
    accepted_rule = if update["accepted"]
        update["evaluation_after"]["loss"] < update["evaluation_before"]["loss"]
    else
        update["x_after"] == update["x_before"] &&
            all(!trial["strict_decrease"] for trial in update["trials"])
    end
    gates = Dict(
        "retained_state_unchanged" =>
            cell["retained_state_sha256_before"] == cell["retained_state_sha256_after"],
        "effective_state_unchanged" =>
            cell["effective_delta_sha256_before"] == cell["effective_delta_sha256_after"],
        "delta_fixed_in_update" => update["delta_held_fixed"],
        "delta_fixed_in_finite_difference" =>
            cell["finite_difference"]["delta_held_fixed"],
        "finite_difference" => cell["finite_difference"]["passed"],
        "current_check_readings_in_box" => current_in_domain,
        "evaluated_trial_check_readings_in_box" =>
            update["all_trial_readings_in_box"],
        "independent_projection" => update["all_projection_checks"],
        "frozen_input_state" => update["frozen_gradient_error"] <= tolerance,
        "proposal_from_frozen_direction" => update["proposal_error"] <= tolerance,
        "strict_decrease_or_stall" => accepted_rule,
        "syndrome_recomputed" => cell["syndrome"] == cell["syndrome_recomputed"],
    )
    Dict("checks" => gates, "passed" => all(values(gates)))
end

function contrast_vector(left, right, key_path)
    left_value = left
    right_value = right
    for key in key_path
        left_value = left_value[key]
        right_value = right_value[key]
    end
    Float64.(left_value) - Float64.(right_value)
end

function cell_measurements(cell)
    update = cell["update2"]
    Dict(
        "gradient" => Float64.(update["evaluation_before"]["gradient"]),
        "direction" => Float64.(update["direction"]),
        "x_after" => Float64.(update["x_after"]),
        "objective_before" => Float64(update["evaluation_before"]["loss"]),
        "objective_after" => Float64(update["evaluation_after"]["loss"]),
    )
end

function measurement_difference(left, right)
    Dict(
        "gradient" => Float64.(left["gradient"]) - Float64.(right["gradient"]),
        "direction" => Float64.(left["direction"]) - Float64.(right["direction"]),
        "x_after" => Float64.(left["x_after"]) - Float64.(right["x_after"]),
        "objective_before" => Float64(left["objective_before"]) -
            Float64(right["objective_before"]),
        "objective_after" => Float64(left["objective_after"]) -
            Float64(right["objective_after"]),
    )
end

function difference_of_differences(left_difference, right_difference)
    Dict(
        "gradient" => Float64.(left_difference["gradient"]) -
            Float64.(right_difference["gradient"]),
        "direction" => Float64.(left_difference["direction"]) -
            Float64.(right_difference["direction"]),
        "x_after" => Float64.(left_difference["x_after"]) -
            Float64.(right_difference["x_after"]),
        "objective_before" => Float64(left_difference["objective_before"]) -
            Float64(right_difference["objective_before"]),
        "objective_after" => Float64(left_difference["objective_after"]) -
            Float64(right_difference["objective_after"]),
    )
end

function measurement_difference_is_zero(difference; atol::Float64=0.0)
    maximum(abs, difference["gradient"]) <= atol &&
    maximum(abs, difference["direction"]) <= atol &&
    maximum(abs, difference["x_after"]) <= atol &&
    abs(difference["objective_before"]) <= atol &&
    abs(difference["objective_after"]) <= atol
end

function calculate_case_core(config, dependencies, case_name::AbstractString, checks)
    projected = config["projected_gradient"]
    tolerance = Float64(config["validation"]["native_composition_tolerance"])
    L = Float64.(config["channel_evidence"]["values_bit1_positive"])
    ell = -L
    x0 = tanh.(ell ./ 2)
    current_one = native_summary(
        dependencies.oracles.current, checks, ell, x0, projected, 1)
    archived_one = native_summary(
        dependencies.oracles.archived, checks, ell, x0, projected, 1)
    current_two = native_summary(
        dependencies.oracles.current, checks, ell, x0, projected, 2)
    archived_two = native_summary(
        dependencies.oracles.archived, checks, ell, x0, projected, 2)
    native_one_equivalence = compare_structures(current_one, archived_one; atol=0.0)
    native_two_equivalence = compare_structures(current_two, archived_two; atol=0.0)

    zero_delta = zero_edge_rows(checks)
    initial_evaluation = objective_decomposition(
        x0, ell, checks, projected; delta_rows=zero_delta)
    current_initial = compare_structures(
        independent_initial_view(initial_evaluation),
        native_initial_view(current_one); atol=tolerance)
    archived_initial = compare_structures(
        independent_initial_view(initial_evaluation),
        native_initial_view(archived_one); atol=tolerance)
    initial_finite_difference = finite_difference_check(
        x0, ell, checks, projected, zero_delta, config)

    update1 = single_update(x0, ell, checks, projected, zero_delta)
    update1_view = update1_native_view(update1)
    current_update1 = compare_structures(update1_view, current_one; atol=tolerance)
    archived_update1 = compare_structures(update1_view, archived_one; atol=tolerance)
    check_indexed_values = construct_check_indexed_values(
        x0, ell, checks, projected, update1, config)

    prechecks = Dict(
        "current_archived_native_one_update" => native_one_equivalence["passed"],
        "current_archived_native_two_updates" => native_two_equivalence["passed"],
        "independent_initial_current" => current_initial["passed"],
        "independent_initial_archived" => archived_initial["passed"],
        "native_initial_finite_difference" => initial_finite_difference["passed"],
        "native_update1_accepted" => update1["accepted"],
        "independent_update1_current" => current_update1["passed"],
        "independent_update1_archived" => archived_update1["passed"],
        "check_indexed_value_construction" =>
            get(check_indexed_values, "passed", false),
    )
    preflight_passed = all(values(prechecks))
    common = Dict{String,Any}(
        "case_name" => case_name,
        "checks" => checks,
        "channel_evidence" => Dict(
            "L_bit1_positive" => L,
            "ell_bit0_positive" => ell,
        ),
        "x0" => x0,
        "native" => Dict(
            "current_one_update" => current_one,
            "archived_one_update" => archived_one,
            "one_update_equivalence" => native_one_equivalence,
            "current_two_updates" => current_two,
            "archived_two_updates" => archived_two,
            "two_update_equivalence" => native_two_equivalence,
        ),
        "initial_evaluation" => initial_evaluation,
        "initial_finite_difference" => initial_finite_difference,
        "initial_current_comparison" => current_initial,
        "initial_archived_comparison" => archived_initial,
        "update1" => update1,
        "update1_current_comparison" => current_update1,
        "update1_archived_comparison" => archived_update1,
        "check_indexed_values" => check_indexed_values,
        "preflight_checks" => prechecks,
        "cells_executed" => false,
    )
    if !preflight_passed
        common["status"] = "invalid"
        common["invalid_reason"] = "case_preflight_failed"
        common["validation_checks"] = prechecks
        common["validation_passed"] = false
        return common
    end

    x1 = Float64.(update1["x_after"])
    update1_hash = scientific_sha256(Dict(
        "x0" => x0,
        "update1" => update1,
        "constructed_values_generated" => check_indexed_values,
    ))
    cells = Dict{String,Any}()
    for cell_id in config["intervention"]["cell_order"]
        cells[cell_id] = run_cell(
            cell_id, x1, ell, checks, projected,
            check_indexed_values, update1_hash, config)
    end
    cell_validations = Dict(
        cell_id => update_validity(cells[cell_id], projected, config)
        for cell_id in config["intervention"]["cell_order"]
    )

    controls = String.(config["intervention"]["controls"])
    baseline_view = cell_path_view(cells[controls[1]])
    control_comparisons = Dict{String,Any}()
    for cell_id in controls[2:end]
        control_comparisons[cell_id] = compare_structures(
            baseline_view, cell_path_view(cells[cell_id]); atol=0.0)
    end
    controls_exact = all(comparison["passed"]
                         for comparison in values(control_comparisons))

    two_update_comparisons = Dict{String,Any}()
    for cell_id in controls
        composed = composed_two_update_view(update1, cells[cell_id]["update2"])
        two_update_comparisons[cell_id] = Dict(
            "composed" => composed,
            "current" => compare_structures(composed, current_two; atol=tolerance),
            "archived" => compare_structures(composed, archived_two; atol=tolerance),
        )
    end
    controls_match_two_native = all(
        record["current"]["passed"] && record["archived"]["passed"]
        for record in values(two_update_comparisons))

    zero_hash = scientific_sha256(zero_delta)
    state_rules = Dict{String,Bool}()
    for cell_id in config["intervention"]["cell_order"]
        cell = cells[cell_id]
        retained = cell["retention"] == "retained"
        used_in_update2 = cell["use_in_update2"] == "used"
        expected_state = retained ?
            scientific_sha256(check_indexed_values["delta"]) : zero_hash
        expected_effective = used_in_update2 ? expected_state : zero_hash
        state_rules[cell_id] =
            cell["retained_state_sha256_before"] == expected_state &&
            cell["effective_delta_sha256_before"] == expected_effective
    end
    retained_hash_distinct =
        cells["retained__ignored"]["retained_state_sha256_before"] !=
        cells["collapsed__ignored"]["retained_state_sha256_before"]
    entry_hashes = unique(cells[cell_id]["entry_update1_sha256"]
                          for cell_id in config["intervention"]["cell_order"])
    entry_states = unique(scientific_sha256(cells[cell_id]["x_entry"])
                          for cell_id in config["intervention"]["cell_order"])
    no_early_divergence = length(entry_hashes) == 1 && length(entry_states) == 1

    active = cells[String(config["intervention"]["active_cell"])]
    baseline = cells[controls[1]]
    measurements = Dict(
        cell_id => cell_measurements(cells[cell_id])
        for cell_id in config["intervention"]["cell_order"]
    )
    storage_only = measurement_difference(
        measurements["retained__ignored"],
        measurements["collapsed__ignored"])
    use_switch = measurement_difference(
        measurements["collapsed__consumed"],
        measurements["collapsed__ignored"])
    active_vs_control = measurement_difference(
        measurements["retained__consumed"],
        measurements["collapsed__ignored"])
    active_minus_storage = measurement_difference(
        measurements["retained__consumed"],
        measurements["retained__ignored"])
    interaction = difference_of_differences(
        active_minus_storage, use_switch)
    factorial_contrasts = Dict(
        "storage_only_RI_minus_CI" => storage_only,
        "use_switch_CC_minus_CI" => use_switch,
        "active_RC_minus_CI" => active_vs_control,
        "interaction_RC_minus_RI_minus_CC_plus_CI" => interaction,
    )
    factorial_nulls_exact = measurement_difference_is_zero(storage_only) &&
        measurement_difference_is_zero(use_switch)
    active_effect = Dict(
        "gradient_difference" => contrast_vector(
            active, baseline, ["update2", "evaluation_before", "gradient"]),
        "direction_difference" => contrast_vector(
            active, baseline, ["update2", "direction"]),
        "state_difference" => contrast_vector(
            active, baseline, ["update2", "x_after"]),
        "objective_before_difference" =>
            active["update2"]["evaluation_before"]["loss"] -
            baseline["update2"]["evaluation_before"]["loss"],
        "objective_after_difference" =>
            active["update2"]["evaluation_after"]["loss"] -
            baseline["update2"]["evaluation_after"]["loss"],
        "accepted_step_difference" =>
            active["update2"]["accepted_step"] - baseline["update2"]["accepted_step"],
        "hard_decision_changed" =>
            active["hard_decision"] != baseline["hard_decision"],
        "syndrome_changed" => active["syndrome"] != baseline["syndrome"],
    )
    active_effect["maximum_gradient_difference"] =
        maximum(abs, active_effect["gradient_difference"])
    active_effect["maximum_state_difference"] =
        maximum(abs, active_effect["state_difference"])
    effect_tolerance = Float64(config["validation"]["absolute_tolerance"])
    active_effect["maximum_direction_difference"] =
        maximum(abs, active_effect["direction_difference"])
    active_effect["partial_derivative_changed"] =
        active_effect["maximum_gradient_difference"] > effect_tolerance
    active_effect["direction_changed"] =
        active_effect["maximum_direction_difference"] > effect_tolerance
    active_effect["scalar_state_changed"] =
        active_effect["maximum_state_difference"] > effect_tolerance
    active_effect["line_search_changed"] =
        active["update2"]["status"] != baseline["update2"]["status"] ||
        abs(active_effect["accepted_step_difference"]) > effect_tolerance ||
        length(active["update2"]["trials"]) != length(baseline["update2"]["trials"])
    aligned_trial_count = min(length(active["update2"]["trials"]),
                              length(baseline["update2"]["trials"]))
    maximum_trial_proposal_difference = 0.0
    trial_acceptance_flags_changed = false
    for trial_index in 1:aligned_trial_count
        active_trial = active["update2"]["trials"][trial_index]
        baseline_trial = baseline["update2"]["trials"][trial_index]
        maximum_trial_proposal_difference = max(
            maximum_trial_proposal_difference,
            maximum(abs, Float64.(active_trial["raw_proposal"]) -
                         Float64.(baseline_trial["raw_proposal"])),
            maximum(abs, Float64.(active_trial["projected_proposal"]) -
                         Float64.(baseline_trial["projected_proposal"])),
        )
        trial_acceptance_flags_changed |=
            active_trial["strict_decrease"] != baseline_trial["strict_decrease"]
    end
    active_effect["maximum_trial_proposal_difference"] =
        maximum_trial_proposal_difference
    active_effect["trial_path_changed"] =
        length(active["update2"]["trials"]) != length(baseline["update2"]["trials"]) ||
        maximum_trial_proposal_difference > effect_tolerance ||
        trial_acceptance_flags_changed
    active_effect["parity_calculation_changed"] =
        compare_structures(
            active["update2"]["evaluation_before"]["check_products"],
            baseline["update2"]["evaluation_before"]["check_products"];
            atol=effect_tolerance)["passed"] == false
    active_effect["trajectory_effect_detected"] =
        active_effect["parity_calculation_changed"] ||
        active_effect["partial_derivative_changed"] ||
        active_effect["direction_changed"] ||
        active_effect["trial_path_changed"] ||
        active_effect["line_search_changed"] ||
        active_effect["scalar_state_changed"]
    active_effect["nonzero_diagnostic_change"] =
        active_effect["trajectory_effect_detected"]

    if case_name == "tree"
        edges = variable_edges(checks, length(x0))
        delta_max_by_bit = [maximum(abs,
            [check_indexed_values["delta"][check_index][slot]
             for (check_index, slot) in edges[bit]]) for bit in eachindex(edges)]
        active_effect["delta_maximum_absolute_by_bit"] = delta_max_by_bit
        active_effect["only_bit2_is_intervention_site"] =
            delta_max_by_bit[1] == 0.0 && delta_max_by_bit[3] == 0.0
    end

    independent_hard = Dict(
        cell_id => [value < 0.0 ? 1 : 0
                    for value in cells[cell_id]["update2"]["x_after"]]
        for cell_id in config["intervention"]["cell_order"]
    )
    independent_syndrome = Dict(
        cell_id => syndrome_integer_mod2(checks, independent_hard[cell_id])
        for cell_id in config["intervention"]["cell_order"]
    )
    hard_and_syndrome = all(
        independent_hard[cell_id] == cells[cell_id]["hard_decision"] &&
        independent_syndrome[cell_id] == cells[cell_id]["syndrome"]
        for cell_id in config["intervention"]["cell_order"])

    validation_checks = merge(copy(prechecks), Dict(
        "all_cell_validations" => all(record["passed"]
                                      for record in values(cell_validations)),
        "three_control_paths_exact" => controls_exact,
        "three_controls_match_native_two_updates" => controls_match_two_native,
        "retention_and_use_state_rules" => all(values(state_rules)),
        "retained_state_hash_distinct_from_collapsed" => retained_hash_distinct,
        "factorial_storage_and_switch_nulls_exact" => factorial_nulls_exact,
        "no_divergence_before_update2" => no_early_divergence,
        "hard_decisions_and_syndromes_recomputed" => hard_and_syndrome,
    ))
    passed = all(values(validation_checks))
    merge(common, Dict(
        "status" => passed ? "valid" : "invalid",
        "cells_executed" => true,
        "x1" => x1,
        "update1_shared_sha256" => update1_hash,
        "cells" => cells,
        "cell_validations" => cell_validations,
        "control_comparisons" => control_comparisons,
        "two_update_native_comparisons" => two_update_comparisons,
        "state_rule_checks" => state_rules,
        "factorial_contrasts" => factorial_contrasts,
        "active_effect" => active_effect,
        "validation_checks" => validation_checks,
        "validation_passed" => passed,
    ))
end

function unpermute_rows(rows, permutation)
    length(rows) == length(permutation) ||
        throw(DimensionMismatch("row permutation has the wrong length"))
    restored = Vector{Vector{Float64}}(undef, length(rows))
    for new_index in eachindex(permutation)
        old_index = permutation[new_index]
        restored[old_index] = Float64.(rows[new_index])
    end
    restored
end

function unpermute_vector(values, permutation)
    length(values) == length(permutation) ||
        throw(DimensionMismatch("vector permutation has the wrong length"))
    restored = Vector{Float64}(undef, length(values))
    for new_index in eachindex(permutation)
        restored[permutation[new_index]] = Float64(values[new_index])
    end
    restored
end

function row_evaluation_comparison(base, relabeled, permutation, tolerance)
    fields = Dict(
        "check_readings" => compare_structures(
            base["check_readings"],
            unpermute_rows(relabeled["check_readings"], permutation);
            atol=tolerance),
        "g_rows" => compare_structures(
            base["g_rows"],
            unpermute_rows(relabeled["g_rows"], permutation);
            atol=tolerance),
        "check_products" => compare_structures(
            base["check_products"],
            unpermute_vector(relabeled["check_products"], permutation);
            atol=tolerance),
        "check_residuals" => compare_structures(
            base["check_residuals"],
            unpermute_vector(relabeled["check_residuals"], permutation);
            atol=tolerance),
    )
    Dict("fields" => fields,
         "passed" => all(comparison["passed"] for comparison in values(fields)))
end

function scalar_outcome_view(case_result, cell_id)
    cell = case_result["cells"][cell_id]
    update = cell["update2"]
    Dict(
        "objective_before" => update["evaluation_before"]["loss"],
        "terms_before" => update["evaluation_before"]["terms"],
        "gradient" => update["evaluation_before"]["gradient"],
        "direction" => update["direction"],
        "trial_scalars" => [Dict(
            "backtrack_index" => trial["backtrack_index"],
            "step" => trial["step"],
            "raw_proposal" => trial["raw_proposal"],
            "projected_proposal" => trial["projected_proposal"],
            "objective" => trial["objective"],
            "terms" => trial["terms"],
            "strict_decrease" => trial["strict_decrease"],
        ) for trial in update["trials"]],
        "accepted" => update["accepted"],
        "accepted_step" => update["accepted_step"],
        "x_after" => update["x_after"],
        "objective_after" => update["evaluation_after"]["loss"],
        "terms_after" => update["evaluation_after"]["terms"],
        "hard_decision" => cell["hard_decision"],
    )
end

function check_row_relabeling_gate(base, relabeled, permutation, config)
    tolerance = Float64(config["validation"]["absolute_tolerance"])
    comparisons = Dict{String,Any}()
    comparisons["current_native_one_update"] = compare_structures(
        base["native"]["current_one_update"],
        relabeled["native"]["current_one_update"]; atol=tolerance)
    comparisons["archived_native_one_update"] = compare_structures(
        base["native"]["archived_one_update"],
        relabeled["native"]["archived_one_update"]; atol=tolerance)
    comparisons["current_native_two_updates"] = compare_structures(
        base["native"]["current_two_updates"],
        relabeled["native"]["current_two_updates"]; atol=tolerance)
    comparisons["archived_native_two_updates"] = compare_structures(
        base["native"]["archived_two_updates"],
        relabeled["native"]["archived_two_updates"]; atol=tolerance)
    comparisons["update1_scalar_state"] = compare_structures(
        base["update1"]["x_after"], relabeled["update1"]["x_after"];
        atol=tolerance)

    for field in ("g_rows", "constructed_values_leaving_out_indexed_check",
                  "local_raw", "delta")
        comparisons["check_indexed_values_$field"] = compare_structures(
            base["check_indexed_values"][field],
            unpermute_rows(relabeled["check_indexed_values"][field], permutation);
            atol=tolerance)
    end

    cell_records = Dict{String,Any}()
    all_cells = true
    for cell_id in config["intervention"]["cell_order"]
        base_cell = base["cells"][cell_id]
        relabeled_cell = relabeled["cells"][cell_id]
        retained_state = compare_structures(
            base_cell["retained_state"],
            unpermute_rows(relabeled_cell["retained_state"], permutation);
            atol=tolerance)
        effective_state = compare_structures(
            base_cell["effective_delta"],
            unpermute_rows(relabeled_cell["effective_delta"], permutation);
            atol=tolerance)
        scalar_outcome = compare_structures(
            scalar_outcome_view(base, cell_id),
            scalar_outcome_view(relabeled, cell_id); atol=tolerance)
        base_update = base_cell["update2"]
        relabeled_update = relabeled_cell["update2"]
        row_before = row_evaluation_comparison(
            base_update["evaluation_before"],
            relabeled_update["evaluation_before"], permutation, tolerance)
        row_after = row_evaluation_comparison(
            base_update["evaluation_after"],
            relabeled_update["evaluation_after"], permutation, tolerance)
        trial_rows = Dict{String,Any}[]
        trial_rows_passed = length(base_update["trials"]) ==
            length(relabeled_update["trials"])
        if trial_rows_passed
            for trial_index in eachindex(base_update["trials"])
                comparison = row_evaluation_comparison(
                    base_update["trials"][trial_index]["evaluation"],
                    relabeled_update["trials"][trial_index]["evaluation"],
                    permutation, tolerance)
                trial_rows_passed &= comparison["passed"]
                push!(trial_rows, merge(
                    Dict("trial_index" => trial_index), comparison))
            end
        end
        hard_equal = base_cell["hard_decision"] == relabeled_cell["hard_decision"]
        syndrome_permuted = relabeled_cell["syndrome"] ==
            base_cell["syndrome"][permutation]
        passed = retained_state["passed"] && effective_state["passed"] &&
            scalar_outcome["passed"] && row_before["passed"] &&
            row_after["passed"] && trial_rows_passed && hard_equal &&
            syndrome_permuted
        all_cells &= passed
        cell_records[cell_id] = Dict(
            "retained_edge_state" => retained_state,
            "effective_edge_state" => effective_state,
            "scalar_outcome" => scalar_outcome,
            "row_indexed_evaluation_before" => row_before,
            "row_indexed_evaluation_after" => row_after,
            "row_indexed_trial_evaluations" => trial_rows,
            "row_indexed_trials_passed" => trial_rows_passed,
            "hard_decision_equal" => hard_equal,
            "syndrome_row_permutation" => syndrome_permuted,
            "passed" => passed,
        )
    end
    all_comparisons = all(comparison["passed"] for comparison in values(comparisons))
    passed = base["validation_passed"] && relabeled["validation_passed"] &&
        all_comparisons && all_cells
    Dict(
        "permutation_new_row_to_original_row" => permutation,
        "relabeled_checks" => relabeled["checks"],
        "base_validation_passed" => base["validation_passed"],
        "relabeled_validation_passed" => relabeled["validation_passed"],
        "scalar_and_check_indexed_value_comparisons" => comparisons,
        "cell_comparisons" => cell_records,
        "relabeled_science_sha256" => scientific_sha256(relabeled),
        "passed" => passed,
    )
end

function calculate_case(config, dependencies, case_name::AbstractString)
    checks = checks_for(config, case_name)
    base = calculate_case_core(config, dependencies, case_name, checks)
    if !base["validation_passed"]
        base["check_row_relabeling"] = Dict(
            "executed" => false,
            "reason" => "base_case_invalid",
            "passed" => false,
        )
        base["validation_checks"]["check_row_relabeling"] = false
        base["validation_passed"] = false
        base["status"] = "invalid"
        return base
    end
    permutation = reverse(collect(eachindex(checks)))
    relabeled_checks = [copy(checks[index]) for index in permutation]
    relabeled = calculate_case_core(
        config, dependencies, case_name * "_row_relabel_control", relabeled_checks)
    if !relabeled["validation_passed"]
        base["check_row_relabeling"] = Dict(
            "executed" => true,
            "permutation_new_row_to_original_row" => permutation,
            "relabeled_checks" => relabeled_checks,
            "relabeled_validation_passed" => false,
            "relabeled_status" => relabeled["status"],
            "relabeled_science_sha256" => scientific_sha256(relabeled),
            "passed" => false,
        )
        base["validation_checks"]["check_row_relabeling"] = false
        base["validation_passed"] = false
        base["status"] = "invalid"
        return base
    end
    relabeling = check_row_relabeling_gate(base, relabeled, permutation, config)
    relabeling["executed"] = true
    base["check_row_relabeling"] = relabeling
    base["validation_checks"]["check_row_relabeling"] = relabeling["passed"]
    base["validation_passed"] &= relabeling["passed"]
    base["status"] = base["validation_passed"] ? "valid" : "invalid"
    base
end

function invalid_science(reason, source_validation; endpoint_lock=nothing)
    result = Dict{String,Any}(
        "schema_version" => "rq1-gd-state-use-001/science-v1",
        "experiment_id" => "RQ1-GD-STATE-USE-001",
        "status" => "invalid",
        "invalid_reason" => reason,
        "source_gate" => source_validation,
        "tree_executed" => false,
        "cycle_executed" => false,
        "validation_passed" => false,
    )
    endpoint_lock === nothing || (result["endpoint_lock_gate"] = endpoint_lock)
    result
end

function effect_summary(case_result, tolerance)
    effect = case_result["active_effect"]
    flags = Dict(
        "parity_calculation_changed" => Bool(effect["parity_calculation_changed"]),
        "partial_derivative_changed" => Bool(effect["partial_derivative_changed"]),
        "direction_changed" => Bool(effect["direction_changed"]),
        "trial_path_changed" => Bool(effect["trial_path_changed"]),
        "line_search_changed" => Bool(effect["line_search_changed"]),
        "scalar_state_changed" => Bool(effect["scalar_state_changed"]),
        "hard_decision_changed" => Bool(effect["hard_decision_changed"]),
        "syndrome_changed" => Bool(effect["syndrome_changed"]),
    )
    trajectory_changed = any(flags[key] for key in (
        "parity_calculation_changed", "partial_derivative_changed",
        "direction_changed", "trial_path_changed", "line_search_changed",
        "scalar_state_changed"))
    claim = if flags["scalar_state_changed"]
        "Retaining check-specific values and using them in update 2 causally changed the update-2 calculation and accepted scalar state on this locked case."
    elseif trajectory_changed
        "Retaining check-specific values and using them in update 2 causally changed an update-2 calculation but did not change the accepted scalar state beyond tolerance on this locked case."
    else
        "Retaining check-specific values and using them in update 2 produced no detected update-2 trajectory change beyond tolerance on this locked case."
    end
    Dict(
        "tolerance" => tolerance,
        "flags" => flags,
        "trajectory_effect_detected" => trajectory_changed,
        "claim" => claim,
    )
end

function calculate_science(config, dependencies;
                           source_validation=source_gate(config))
    source_validation["passed"] ||
        return invalid_science("source_provenance_gate_failed", source_validation)
    lock = endpoint_lock_gate(config, dependencies.endpoint_config)
    lock["passed"] || return invalid_science(
        "endpoint_lock_gate_failed", source_validation; endpoint_lock=lock)

    tree = calculate_case(config, dependencies, "tree")
    if !tree["validation_passed"]
        return Dict(
            "schema_version" => "rq1-gd-state-use-001/science-v1",
            "experiment_id" => "RQ1-GD-STATE-USE-001",
            "status" => "invalid",
            "invalid_reason" => "tree_anchor_validation_failed",
            "source_gate" => source_validation,
            "endpoint_lock_gate" => lock,
            "tree_executed" => true,
            "tree" => tree,
            "cycle_executed" => false,
            "cycle" => Dict(
                "status" => "skipped",
                "reason" => "tree_anchor_validation_failed",
            ),
            "validation_passed" => false,
        )
    end

    cycle = calculate_case(config, dependencies, "cycle")
    checks = Dict(
        "source_gate" => source_validation["passed"],
        "endpoint_lock_gate" => lock["passed"],
        "tree_anchor" => tree["validation_passed"],
        "cycle_executed_after_tree" => true,
        "cycle_confirmation" => cycle["validation_passed"],
        "no_retuning_between_cases" => true,
    )
    if !cycle["validation_passed"]
        return Dict(
            "schema_version" => "rq1-gd-state-use-001/science-v1",
            "experiment_id" => "RQ1-GD-STATE-USE-001",
            "status" => "invalid",
            "invalid_reason" => "cycle_confirmation_validation_failed",
            "source_gate" => source_validation,
            "endpoint_lock_gate" => lock,
            "tree_executed" => true,
            "tree" => tree,
            "cycle_executed" => true,
            "cycle" => cycle,
            "validation_checks" => checks,
            "validation_passed" => false,
            "claim_boundary" => Dict(
                "status" => "not_evaluated",
                "reason" => "cycle_confirmation_validation_failed",
                "not_established" => [
                    "BP equivalence",
                    "BER or FER effect",
                    "transmitted-word recovery effect",
                    "unique explanation of the native BP-versus-GD gap",
                ],
            ),
        )
    end
    passed = all(values(checks))
    effect_tolerance = Float64(config["validation"]["absolute_tolerance"])
    tree_effect = effect_summary(tree, effect_tolerance)
    cycle_effect = effect_summary(cycle, effect_tolerance)
    affected_cases = String[]
    tree_effect["flags"]["scalar_state_changed"] && push!(affected_cases, "tree")
    cycle_effect["flags"]["scalar_state_changed"] && push!(affected_cases, "cycle")
    calculation_only_cases = String[]
    for (name, summary) in (("tree", tree_effect), ("cycle", cycle_effect))
        summary["trajectory_effect_detected"] &&
            !summary["flags"]["scalar_state_changed"] &&
            push!(calculation_only_cases, name)
    end
    scoped_claim = if !isempty(affected_cases)
        "Retaining check-specific values and using them in update 2 causally changed the accepted scalar state on the locked " *
        join(affected_cases, " and ") * " case" *
        (length(affected_cases) == 1 ? "." : "s.")
    elseif !isempty(calculation_only_cases)
        "Retaining check-specific values and using them in update 2 changed an update-2 calculation but not the accepted scalar state beyond tolerance on the locked " *
        join(calculation_only_cases, " and ") * " case" *
        (length(calculation_only_cases) == 1 ? "." : "s.")
    else
        "The registered intervention produced no detected update-2 trajectory effect beyond tolerance on either locked case."
    end
    Dict(
        "schema_version" => "rq1-gd-state-use-001/science-v1",
        "experiment_id" => "RQ1-GD-STATE-USE-001",
        "status" => passed ? "valid" : "invalid",
        "source_gate" => source_validation,
        "endpoint_lock_gate" => lock,
        "tree_executed" => true,
        "tree" => tree,
        "cycle_executed" => true,
        "cycle" => cycle,
        "validation_checks" => checks,
        "validation_passed" => passed,
        "claim_boundary" => Dict(
            "effect_tolerance" => effect_tolerance,
            "tree" => tree_effect,
            "cycle" => cycle_effect,
            "scoped_mechanism_claim" => scoped_claim,
            "not_established" => [
                "BP equivalence",
                "BER or FER effect",
                "transmitted-word recovery effect",
                "unique explanation of the native BP-versus-GD gap",
            ],
        ),
    )
end

function git_output(repo, arguments...)
    try
        command = Cmd(String["git", "-C", String(repo), String.(arguments)...])
        readchomp(command)
    catch error
        "ERROR: " * sprint(showerror, error)
    end
end

git_capture_succeeded(value::AbstractString) = !startswith(value, "ERROR: ")

function provenance(config, config_path, source_validation)
    sources = config["sources"]
    sp_repo = String(sources["sp_repo"])
    jade_repo = String(sources["jade_repo"])
    status_sp = git_output(sp_repo, "status", "--porcelain=v1", "--untracked-files=all")
    status_jade = git_output(jade_repo, "status", "--porcelain=v1", "--untracked-files=all")
    sp_head = git_output(sp_repo, "rev-parse", "HEAD")
    jade_head = git_output(jade_repo, "rev-parse", "HEAD")
    archived_commit_resolved = git_output(
        jade_repo, "rev-parse", String(sources["archived_commit"]) * "^{commit}")
    git_captures = Dict(
        "sp_git_head" => sp_head,
        "sp_git_status_porcelain_v1" => status_sp,
        "jade_git_head" => jade_head,
        "jade_git_status_porcelain_v1" => status_jade,
        "archived_commit_resolved" => archived_commit_resolved,
    )
    failed_git_captures = sort!([name for (name, value) in git_captures
                                 if !git_capture_succeeded(value)])
    Dict(
        "julia_version" => string(VERSION),
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
        "config_path" => abspath(config_path),
        "config_sha256" => file_sha256(config_path),
        "runner_path" => abspath(RUNNER_PATH),
        "runner_sha256" => file_sha256(RUNNER_PATH),
        "test_path" => abspath(TEST_PATH),
        "test_sha256" => isfile(TEST_PATH) ? file_sha256(TEST_PATH) : "missing",
        "experiment_card_path" => joinpath(HERE, "experiment_card.md"),
        "experiment_card_sha256" => file_sha256(joinpath(HERE, "experiment_card.md")),
        "source_gate" => source_validation,
        "capture_gate" => Dict(
            "checked_fields" => sort!(collect(keys(git_captures))),
            "failed_fields" => failed_git_captures,
            "passed" => isempty(failed_git_captures),
        ),
        "sp_repo" => sp_repo,
        "sp_git_head" => sp_head,
        "sp_git_status_porcelain_v1" => status_sp,
        "sp_git_status_sha256" => bytes2hex(sha256(codeunits(status_sp))),
        "jade_repo" => jade_repo,
        "jade_git_head" => jade_head,
        "jade_git_status_porcelain_v1" => status_jade,
        "jade_git_status_sha256" => bytes2hex(sha256(codeunits(status_jade))),
        "archived_commit_resolved" => archived_commit_resolved,
        "endpoint_sources" => source_validation["records"],
    )
end

function write_new_file(path, content)
    ispath(path) && throw(ArgumentError("refusing to overwrite existing file: $path"))
    open(path, "w") do io
        write(io, content)
    end
end

function retained_sources(config, config_path)
    sources = config["sources"]
    Dict(
        "config.toml" => abspath(config_path),
        "experiment_card.md" => joinpath(HERE, "experiment_card.md"),
        "rq1_gd_state_use_001.jl" => RUNNER_PATH,
        "test_rq1_gd_state_use_001.jl" => TEST_PATH,
        "endpoint_config.toml" => String(sources["endpoint_config"]),
        "endpoint_experiment_card.md" => String(sources["endpoint_card"]),
        "endpoint_rq1_endpoint_001.jl" => String(sources["endpoint_runner"]),
        "endpoint_test_rq1_endpoint_001.jl" => String(sources["endpoint_test"]),
        "current_run_three_receivers.jl" => String(sources["current_native_runner"]),
        "archived_r050_run_three_receivers.jl" => String(sources["archived_native_runner"]),
    )
end

function write_result_directory(output, science, replay_hash, replay_passed,
                                provenance_record, config, config_path, command)
    ispath(output) && throw(ArgumentError("output directory already exists: $output"))
    output_parent = dirname(output)
    ispath(output_parent) && !isdir(output_parent) &&
        throw(ArgumentError("output parent is not a directory: $output_parent"))
    isdir(output_parent) || mkpath(output_parent)
    mkdir(output)

    trace_path = joinpath(output, "trace.json")
    write_new_file(trace_path, canonical_json(science) * "\n")
    trace_hash = file_sha256(trace_path)
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "created_utc" => string(now(UTC)),
        "status" => science["status"],
        "validation_passed" => science["validation_passed"],
        "non_overwrite_gate" => true,
        "scientific_trace_sha256" => trace_hash,
        "independent_replay_sha256" => replay_hash,
        "deterministic_replay_passed" => replay_passed,
        "scientific_hash_scope" => String(
            config["provenance"]["scientific_hash_scope"]),
        "config_path" => abspath(config_path),
        "exact_command" => command,
        "provenance" => provenance_record,
    )
    manifest_path = joinpath(output, "manifest.json")
    write_new_file(manifest_path, canonical_json(manifest) * "\n")

    source_directory = joinpath(output, "source")
    mkdir(source_directory)
    sources = retained_sources(config, config_path)
    for (name, source) in sources
        isfile(source) || throw(ArgumentError("retained source is missing: $source"))
        write_new_file(joinpath(source_directory, name), read(source, String))
    end
    checksum_entries = Dict(
        "trace.json" => file_sha256(trace_path),
        "manifest.json" => file_sha256(manifest_path),
    )
    for name in keys(sources)
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
                   command::AbstractString="julia rq1_gd_state_use_001.jl")
    ispath(output) && throw(ArgumentError("output directory already exists: $output"))
    config = load_config(config_path)
    source_validation = source_gate(config)
    provenance_record = provenance(config, config_path, source_validation)
    science = if !source_validation["passed"]
        invalid_science("source_provenance_gate_failed", source_validation)
    elseif !provenance_record["capture_gate"]["passed"]
        invalid_science("provenance_capture_gate_failed", source_validation)
    else
        try
            dependencies = load_dependencies(config)
            Base.invokelatest(calculate_science, config, dependencies;
                              source_validation=source_validation)
        catch error
            invalid_science("dependency_load_or_execution_error: " *
                            sprint(showerror, error), source_validation)
        end
    end

    replay = if science["status"] == "invalid" &&
                !get(science, "tree_executed", false)
        deepcopy(science)
    else
        dependencies = load_dependencies(config)
        Base.invokelatest(calculate_science, config, dependencies;
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
        provenance_record, config, config_path, command)
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
            index <= length(arguments) ||
                throw(ArgumentError("--config requires a path"))
            config_path = arguments[index]
        elseif argument == "--output"
            index += 1
            index <= length(arguments) ||
                throw(ArgumentError("--output requires a path"))
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
        println("usage: julia --project=/path/to/JadeJcade rq1_gd_state_use_001.jl --output DIR [--config FILE]")
        return 0
    end
    parsed.output === nothing && throw(ArgumentError("--output is required"))
    command = join([
        "julia", "--project=/home/gabiel/Documents/GitHub/JadeJcade",
        abspath(RUNNER_PATH), arguments...,
    ], " ")
    result = execute(;
        config_path=parsed.config_path, output=parsed.output, command=command)
    println("RQ1-GD-STATE-USE-001 status: ", result.science["status"])
    println("trace SHA-256: ", result.written.trace_hash)
    result.science["validation_passed"] ? 0 : 2
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(main())
end

end # module
