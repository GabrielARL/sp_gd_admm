#!/usr/bin/env julia

module RQ2NativeGap001

# RQ2-NATIVE-GAP-001: native exact sum-product BP and native projected GD on
# the same frozen cases.  Three stages:
#
#   six      frames 30001:30200 at 6 dB (the split experiment's held-out cases)
#   profile  frames 20001:20024 at a registered Es/N0 grid, descriptive only;
#            it selects the second confirmatory Es/N0 by a registered rule
#   second   frames 30001:30200 at the selected Es/N0
#
# The unit-noise realization of a frame is seeded by its frame index, so a
# frame keeps the same noise draw at every Es/N0; only the scale changes.

using Dates
using JadeJcade
using LinearAlgebra
using SHA
using Statistics
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const RUNNER_PATH = @__FILE__
const TEST_PATH = joinpath(HERE, "test_rq2_native_gap_001.jl")
const CARD_PATH = joinpath(HERE, "experiment_card.md")
const SPLIT_RUNNER_PATH = joinpath(dirname(HERE), "rq2_gd_offset_split_001",
                                   "rq2_gd_offset_split_001.jl")

include(SPLIT_RUNNER_PATH)
const Split = RQ2GDOffsetSplit001
const Legacy = Split.Legacy
const CORE = JadeJcade.ReceiverCore

const vector_sha256 = Legacy.vector_sha256
const file_sha256 = Legacy.file_sha256
const scientific_sha256 = Legacy.scientific_sha256
const canonical_json = Legacy.canonical_json
const write_new_file = Legacy.write_new_file
const write_csv = Legacy.write_csv
const parse_simple_csv = Legacy.parse_simple_csv
const git_output = Legacy.git_output

const METHODS = ("bp_exact_sum_product", "gd_native_projected")
const ENDPOINTS = ("transmitted_word_equal", "parity_valid")

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    config["schema_version"] == "rq2-native-gap-001/v1" ||
        throw(ArgumentError("unsupported schema"))
    config["experiment_id"] == "RQ2-NATIVE-GAP-001" ||
        throw(ArgumentError("unexpected experiment identifier"))
    config["stages"]["six"]["frame_first"] == 30001 &&
        config["stages"]["six"]["frame_last"] == 30200 ||
        throw(ArgumentError("six-dB frame set changed"))
    config["stages"]["profile"]["frame_first"] == 20001 &&
        config["stages"]["profile"]["frame_last"] == 20024 ||
        throw(ArgumentError("profile frame set changed"))
    config
end

split_config_path() = joinpath(dirname(HERE), "rq2_gd_offset_split_001", "config.toml")

function load_split_config(config)
    path = split_config_path()
    file_sha256(path) == String(config["protocol"]["split_config_sha256"]) ||
        throw(ArgumentError("retained split configuration changed"))
    TOML.parsefile(path)
end

function source_gate(config)
    protocol = config["protocol"]
    checks = Dict{String,Bool}(
        "split_config" => file_sha256(split_config_path()) ==
            String(protocol["split_config_sha256"]),
        "split_runner" => file_sha256(SPLIT_RUNNER_PATH) ==
            String(protocol["split_runner_sha256"]),
        "legacy_runner" => file_sha256(Split.LEGACY_RUNNER_PATH) ==
            String(protocol["legacy_runner_sha256"]),
        "codex_freeze_table" => file_sha256(String(
            protocol["split_freeze_input_table"])) ==
            String(protocol["split_freeze_input_table_sha256"]),
        "codex_anchor_frames" => file_sha256(String(
            protocol["split_anchor_frames"])) ==
            String(protocol["split_anchor_frames_sha256"]))
    split = load_split_config(config)
    legacy_gate = Legacy.source_gate(split)
    checks["retained_static_sources"] = Bool(legacy_gate["passed"])
    Dict("passed" => all(values(checks)), "checks" => checks)
end

stage_frames(config, stage::Symbol) =
    Int(config["stages"][String(stage)]["frame_first"]):Int(
        config["stages"][String(stage)]["frame_last"])

noise_variance(esn0_db::Real) = 10.0^(-Float64(esn0_db) / 10.0)

function channel_config(split, esn0_db::Float64)
    config = deepcopy(split)
    variance = noise_variance(esn0_db)
    if esn0_db == Float64(split["channel"]["physical_esn0_db"])
        variance = Float64(split["channel"]["noise_variance"])
        abs(variance - noise_variance(esn0_db)) <= 1.0e-15 ||
            throw(ArgumentError("6 dB variance disagrees with the retained value"))
    end
    config["channel"]["noise_variance"] = variance
    config["channel"]["physical_esn0_db"] = esn0_db
    config
end

"""Build the modem and code with the BP iteration cap registered for this
experiment, and check the graph hash against the retained protocol."""
function make_bp_code(config, split)
    bp = config["bp"]
    modem = JadeJcade.Jade.Modulation(
        ldpc_k=Int(split["code"]["k"]), ldpc_n=Int(split["code"]["n"]),
        ldpc_npc=Int(split["code"]["variable_degree"]), ldpc_method=:evenboth,
        ldpc_seed=Int(split["code"]["graph_seed"]), ldpc_no4cycle=false,
        inner_pilot_ratio=0.0, pilot_ratio=0.0,
        bp_iterations=Int(bp["maximum_message_passing_iterations"]))
    code = CORE._code(modem)
    Legacy.graph_sha256(code.check_vars) == String(split["code"]["graph_sha256"]) ||
        throw(ArgumentError("graph hash differs from the retained protocol"))
    (; modem, code)
end

function decode_bp(modem, code, llr::AbstractVector{Float64})
    # JadeJcade's kernel negates its metric argument internally, so the
    # registered LLR convention (positive favors coded bit zero) enters as -llr.
    value = CORE._bp_decode_sum_product(modem, code, -llr)
    scratch = CORE._bp_scratch(modem, code)
    hard = BitVector(copy(scratch.bits))
    syndrome = Legacy.syndrome_vector([Int.(c) for c in code.check_vars], hard)
    weight = sum(syndrome)
    weight == CORE._syndrome_weight(code, hard) || error("independent syndrome disagrees")
    (; hard, parity_valid=weight == 0, syndrome_weight=weight,
       kernel_valid=Bool(value.valid), kernel_syndrome=Int(value.syndrome),
       iterations=Int(value.iterations),
       transmitted_word_equal=count(hard) == 0, coded_bit_errors=count(hard))
end

function decode_gd(split, code, llr::AbstractVector{Float64}; collect_diagnostics=true)
    problem = Legacy.BridgeProblem(code, llr;
        parity_weight=Float64(split["projected_gradient"]["parity_weight"]),
        binary_weight=Float64(split["projected_gradient"]["binary_weight"]))
    pg = split["projected_gradient"]; validation = split["validation"]
    result = Split.solve_variant(problem, code, tanh.(llr ./ 2), Split.REQUIRED_ARMS[1];
        maximum_updates=Int(pg["maximum_update_attempts"]),
        initial_step=Float64(pg["initial_step"]),
        maximum_backtracks=Int(pg["maximum_backtracks"]),
        collect_trace=false, collect_diagnostics, validate_derivatives=false,
        mean_tolerance=Float64(validation["mean_offset_tolerance"]),
        box_tolerance=Float64(validation["box_tolerance"]))
    (; result.hard, result.parity_valid, result.syndrome_weight,
       iterations=result.accepted_steps, status=result.status,
       result.transmitted_word_equal, result.coded_bit_errors)
end

function frame_row(frame, esn0, method, input, decoded, information_positions)
    information_errors = count(@view decoded.hard[information_positions])
    (; frame, physical_esn0_db=esn0, method, noise_seed=input.noise_seed,
       coded_bit_errors=decoded.coded_bit_errors,
       information_bit_errors=information_errors,
       transmitted_word_equal=decoded.transmitted_word_equal,
       information_word_equal=information_errors == 0,
       parity_valid=decoded.parity_valid,
       wrong_valid_word=decoded.parity_valid && !decoded.transmitted_word_equal,
       syndrome_weight=decoded.syndrome_weight,
       iterations=decoded.iterations,
       hard_word_sha256=vector_sha256(decoded.hard),
       received_sha256=input.identities.received_sha256,
       clipped_llr_sha256=input.identities.clipped_llr_sha256)
end

# ---------------------------------------------------------------------------
# Freeze
# ---------------------------------------------------------------------------

function authored_source_paths(config_path)
    Dict("config.toml" => abspath(config_path), "experiment_card.md" => CARD_PATH,
         "rq2_native_gap_001.jl" => RUNNER_PATH,
         "test_rq2_native_gap_001.jl" => TEST_PATH)
end

function freeze_source_paths(config, config_path)
    paths = authored_source_paths(config_path)
    paths["retained/rq2_gd_offset_split_001.jl"] = SPLIT_RUNNER_PATH
    paths["retained/rq2_gd_state_use_001.jl"] = Split.LEGACY_RUNNER_PATH
    paths["retained/split_config.toml"] = split_config_path()
    paths["retained/split_input_freeze.csv"] =
        String(config["protocol"]["split_freeze_input_table"])
    paths["retained/split_anchor_frames.csv"] =
        String(config["protocol"]["split_anchor_frames"])
    paths
end

function stage_points(config)
    grid = Float64.(config["stages"]["profile"]["esn0_grid_db"])
    points = Tuple{String,Int,Float64}[]
    for frame in stage_frames(config, :profile), esn0 in grid
        push!(points, ("profile", frame, esn0))
    end
    for esn0 in grid, frame in stage_frames(config, :six)
        push!(points, (esn0 == 6.0 ? "six" : "second_candidate", frame, esn0))
    end
    points
end

function input_rows(config, split, native, code)
    rows = NamedTuple[]
    cache = Dict{Float64,Any}()
    for (set_name, frame, esn0) in stage_points(config)
        channel = get!(cache, esn0) do; channel_config(split, esn0); end
        input = Legacy.generate_input(channel, native, code, frame)
        push!(rows, (; set=set_name, frame, physical_esn0_db=esn0,
            noise_seed=input.noise_seed, noise_variance=input.variance,
            noise_variance_float64_hex=Legacy.float64_hex(input.variance),
            graph_sha256=input.identities.graph_sha256,
            unit_noise_sha256=input.identities.unit_noise_sha256,
            received_sha256=input.identities.received_sha256,
            clipped_llr_sha256=input.identities.clipped_llr_sha256))
    end
    rows
end

function environment_record(split)
    Dict("julia_version" => string(VERSION), "julia_threads" => Threads.nthreads(),
         "blas_threads" => BLAS.get_num_threads(), "cpu" => Sys.CPU_NAME,
         "sp_head" => git_output(HERE, "rev-parse", "HEAD"),
         "sp_branch" => git_output(HERE, "branch", "--show-current"),
         "jade_root" => String(split["sources"]["jade_project_repo"]),
         "jade_head" => git_output(String(split["sources"]["jade_project_repo"]),
                                   "rev-parse", "HEAD"))
end

function freeze_inputs(output; config_path=DEFAULT_CONFIG, command="freeze")
    output = abspath(output)
    ispath(output) && throw(ArgumentError("freeze output already exists: $output"))
    config = load_config(config_path)
    gate = source_gate(config)
    gate["passed"] || throw(ArgumentError("source gate failed: $(gate["checks"])"))
    split = load_split_config(config)
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = make_bp_code(config, split)
    rows = input_rows(config, split, native, generated.code)
    # The six-dB identities must equal the retained split freeze row for row.
    codex = Dict(parse(Int, r.frame) => r for r in parse_simple_csv(
        String(config["protocol"]["split_freeze_input_table"])))
    for row in rows
        row.physical_esn0_db == 6.0 || continue
        haskey(codex, row.frame) || continue
        codex[row.frame].clipped_llr_sha256 == row.clipped_llr_sha256 ||
            throw(ArgumentError("frame $(row.frame) differs from the split freeze"))
    end
    mkpath(dirname(output)); mkdir(output)
    input_path = joinpath(output, "input_freeze.csv")
    write_csv(input_path, rows, propertynames(first(rows)))
    source_directory = joinpath(output, "source"); mkdir(source_directory)
    records = Legacy.archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["freeze_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "created_utc" => string(now(UTC)), "command" => String(command),
        "configuration_sha256" => file_sha256(config_path),
        "input_freeze_sha256" => file_sha256(input_path),
        "input_row_count" => length(rows),
        "six_db_identities_equal_split_freeze" => true,
        "graph_sha256" => Legacy.graph_sha256(generated.code.check_vars),
        "environment" => environment_record(split),
        "source_gate" => gate, "sources" => records)
    open(joinpath(output, "freeze_manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    written = Legacy.write_checksum_manifest(output)
    Dict("output" => output, "input_rows" => length(rows),
         "input_freeze_sha256" => file_sha256(input_path),
         "checksum_entries" => length(written.entries))
end

function validate_freeze(config, freeze; config_path=DEFAULT_CONFIG)
    freeze = abspath(freeze)
    checksum = Legacy.verify_checksum_manifest(freeze)
    manifest = TOML.parsefile(joinpath(freeze, "freeze_manifest.toml"))
    table_path = joinpath(freeze, "input_freeze.csv")
    frozen = Dict(String(r["label"]) => r for r in manifest["sources"])
    authored_ok = all(haskey(frozen, label) && isfile(path) &&
                      file_sha256(path) == String(frozen[label]["sha256"])
                      for (label, path) in authored_source_paths(config_path))
    checks = Dict{String,Bool}(
        "checksum_manifest" => Bool(checksum["passed"]),
        "experiment" => manifest["experiment_id"] == config["experiment_id"],
        "configuration" => manifest["configuration_sha256"] == file_sha256(config_path),
        "input_table_hash" => manifest["input_freeze_sha256"] == file_sha256(table_path),
        "input_row_count" => length(parse_simple_csv(table_path)) ==
            length(stage_points(config)),
        "current_source_gate" => Bool(source_gate(config)["passed"]),
        "authored_sources_equal_freeze" => authored_ok)
    Dict("passed" => all(values(checks)), "checks" => checks, "manifest" => manifest)
end

# ---------------------------------------------------------------------------
# Scientific execution
# ---------------------------------------------------------------------------

function write_progress(path, payload)
    path === nothing && return
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, payload; sorted=true)
    end
    mv(temporary, path; force=true)
end

"""Registered selection of the second Es/N0: the highest grid value below 6 dB
at which BP recovers at most `bp_maximum_recoveries` of the profile frames; if
BP exceeds that at every grid value, the lowest grid value is used and the
saturation flag is set."""
function select_second_esn0(config, profile_counts)
    grid = sort(Float64.(config["stages"]["profile"]["esn0_grid_db"]))
    limit = Int(config["stages"]["second"]["bp_maximum_recoveries_for_selection"])
    candidates = [esn0 for esn0 in grid
                  if esn0 < 6.0 && profile_counts[esn0]["bp_exact_sum_product"] <= limit]
    if isempty(candidates)
        return (; esn0=first(grid), bp_saturated_on_grid=true)
    end
    (; esn0=maximum(candidates), bp_saturated_on_grid=false)
end

function paired_table(rows)
    table = Dict{String,Any}()
    for endpoint in ENDPOINTS
        counts = Split.paired_endpoint_counts(rows, Symbol(endpoint),
            "bp_exact_sum_product", "gd_native_projected")
        table[endpoint] = counts
    end
    table
end

function add_inference!(table, confidence_level)
    pvalues = Dict{String,Float64}()
    for endpoint in ENDPOINTS
        legacy = Split.legacy_count_keys(table[endpoint])
        pvalue = Legacy.mcnemar_exact_pvalue(legacy)
        table[endpoint]["mcnemar_exact_two_sided_pvalue"] = pvalue
        table[endpoint]["newcombe_interval"] =
            Legacy.newcombe_paired_interval(legacy; confidence_level)
        pvalues[endpoint] = pvalue
    end
    for (endpoint, value) in Legacy.holm_adjust(pvalues)
        table[endpoint]["holm_adjusted_pvalue"] = value
    end
    table
end

function calculate_science(config, freeze, stage::Symbol; collect_runtime::Bool,
                           config_path=DEFAULT_CONFIG, progress_path=nothing,
                           pass_name="primary", started_utc="",
                           second_esn0::Union{Nothing,Float64}=nothing)
    validation = validate_freeze(config, freeze; config_path)
    validation["passed"] || throw(ArgumentError(
        "frozen input gate failed: $(validation["checks"])"))
    split = load_split_config(config)
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = make_bp_code(config, split)
    modem, code = generated.modem, generated.code
    information_positions = Legacy.native_call(native, :_message_positions, code)
    frozen = Dict((parse(Int, r.frame), parse(Float64, r.physical_esn0_db)) => r
                  for r in parse_simple_csv(joinpath(freeze, "input_freeze.csv")))
    codex_anchor = Dict(parse(Int, r.frame) => r for r in parse_simple_csv(
        String(config["protocol"]["split_anchor_frames"]))
        if r.arm == "objective0__bounds0")
    points = if stage === :profile
        [(frame, esn0) for frame in stage_frames(config, :profile)
         for esn0 in Float64.(config["stages"]["profile"]["esn0_grid_db"])]
    elseif stage === :six
        [(frame, 6.0) for frame in stage_frames(config, :six)]
    elseif stage === :second
        second_esn0 === nothing && throw(ArgumentError("second stage needs its Es/N0"))
        [(frame, second_esn0) for frame in stage_frames(config, :six)]
    else
        throw(ArgumentError("unknown stage $stage"))
    end
    started = isempty(started_utc) ? string(now(UTC)) : String(started_utc)
    progress = (completed, frame, esn0) -> write_progress(progress_path, Dict(
        "experiment_id" => String(config["experiment_id"]), "stage" => String(stage),
        "pass" => String(pass_name), "status" => "running",
        "frames_completed" => completed, "frames_total" => length(points),
        "current_frame" => frame, "current_esn0_db" => esn0,
        "started_utc" => started, "updated_utc" => string(now(UTC)),
        "process_id" => getpid()))
    channels = Dict{Float64,Any}()
    if collect_runtime
        warm_llr = [2sin(0.013bit) + 0.4cos(0.031bit) for bit in 1:code.n]
        decode_bp(modem, code, warm_llr)
        decode_gd(split, code, warm_llr; collect_diagnostics=false)
    end
    rows = NamedTuple[]
    runtime_rows = NamedTuple[]
    frozen_ok = true
    bp_kernel_agrees = true
    codex_control_checked = 0
    codex_control_equal = true
    for (position, (frame, esn0)) in enumerate(points)
        progress(position - 1, frame, esn0)
        channel = get!(channels, esn0) do; channel_config(split, esn0); end
        input = Legacy.generate_input(channel, native, code, frame)
        row = frozen[(frame, esn0)]
        frozen_ok &= row.clipped_llr_sha256 == input.identities.clipped_llr_sha256
        llr = Float64.(input.clipped_llr)
        if collect_runtime
            order = isodd(position) ? (:bp, :gd) : (:gd, :bp)
            for (order_position, method) in enumerate(order)
                timed = method === :bp ? (@timed decode_bp(modem, code, llr)) :
                    (@timed decode_gd(split, code, llr; collect_diagnostics=false))
                push!(runtime_rows, (; frame, physical_esn0_db=esn0,
                    method=method === :bp ? METHODS[1] : METHODS[2],
                    order_position, seconds=Float64(timed.time),
                    allocated_bytes=Int(timed.bytes)))
            end
        end
        bp = decode_bp(modem, code, llr)
        gd = decode_gd(split, code, llr)
        bp_kernel_agrees &= bp.kernel_valid == bp.parity_valid
        if esn0 == 6.0 && haskey(codex_anchor, frame)
            codex_control_checked += 1
            codex_control_equal &= codex_anchor[frame].hard_word_sha256 ==
                vector_sha256(gd.hard)
        end
        push!(rows, frame_row(frame, esn0, METHODS[1], input, bp, information_positions))
        push!(rows, frame_row(frame, esn0, METHODS[2], input, gd, information_positions))
        progress(position, frame, esn0)
    end
    gates = Dict{String,Bool}(
        "frozen_inputs_regenerated_identically" => frozen_ok,
        "bp_kernel_validity_equals_independent_syndrome" => bp_kernel_agrees,
        "gd_control_equals_split_anchor_control" =>
            codex_control_checked == 0 || codex_control_equal,
        "every_point_has_both_methods" => length(rows) == 2length(points))
    science = Dict{String,Any}(
        "schema_version" => String(config["provenance"]["science_schema"]),
        "experiment_id" => String(config["experiment_id"]),
        "stage" => String(stage), "points" => length(points),
        "methods" => collect(METHODS),
        "correctness_gates" => gates, "correctness_passed" => all(values(gates)),
        "hard_words" => Dict(method => [r.hard_word_sha256 for r in rows
                                        if r.method == method] for method in METHODS))
    if stage === :profile
        grid = Float64.(config["stages"]["profile"]["esn0_grid_db"])
        per_snr = Dict{Float64,Any}()
        for esn0 in grid
            subset = [r for r in rows if r.physical_esn0_db == esn0]
            per_snr[esn0] = Dict(method => count(r -> r.transmitted_word_equal,
                [r for r in subset if r.method == method]) for method in METHODS)
            per_snr[esn0]["parity_valid_" * METHODS[1]] = count(
                r -> r.parity_valid, [r for r in subset if r.method == METHODS[1]])
            per_snr[esn0]["parity_valid_" * METHODS[2]] = count(
                r -> r.parity_valid, [r for r in subset if r.method == METHODS[2]])
            per_snr[esn0]["frames"] = length(stage_frames(config, :profile))
        end
        selection = select_second_esn0(config, per_snr)
        science["profile"] = Dict(string(k) => v for (k, v) in per_snr)
        science["selected_second_esn0_db"] = selection.esn0
        science["bp_saturated_on_grid"] = selection.bp_saturated_on_grid
        science["six_db_control_frames_checked"] = codex_control_checked
    else
        science["physical_esn0_db"] = stage === :six ? 6.0 : second_esn0
        science["method_outcomes"] = Dict(method => Dict(
            "transmitted_word_equal" => count(r -> r.transmitted_word_equal && r.method == method, rows),
            "parity_valid" => count(r -> r.parity_valid && r.method == method, rows),
            "information_word_equal" => count(r -> r.information_word_equal && r.method == method, rows),
            "wrong_valid_word" => count(r -> r.wrong_valid_word && r.method == method, rows),
            "mean_coded_bit_errors" => mean(r.coded_bit_errors for r in rows if r.method == method),
            "mean_iterations" => mean(r.iterations for r in rows if r.method == method))
            for method in METHODS)
        table = paired_table(rows)
        add_inference!(table, Float64(config["inference"]["interval_confidence_level"]))
        science["bp_minus_gd"] = table
    end
    (; science, rows, runtime_rows)
end

function write_result(output, config, config_path, freeze, stage, calculated,
                      replay_hash, replay_passed, command)
    science = calculated.science
    base_hash = scientific_sha256(science)
    science["deterministic_replay"] = Dict("first_sha256" => base_hash,
        "second_sha256" => replay_hash, "passed" => replay_passed)
    science["correctness_gates"]["deterministic_replay"] = replay_passed
    science["correctness_passed"] &= replay_passed
    science_path = joinpath(output, "science.json")
    write_new_file(science_path, canonical_json(science) * "\n")
    write_csv(joinpath(output, "frames.csv"), calculated.rows,
              propertynames(first(calculated.rows)))
    isempty(calculated.runtime_rows) || write_csv(joinpath(output, "runtime.csv"),
        calculated.runtime_rows, propertynames(first(calculated.runtime_rows)))
    if stage === :profile
        open(joinpath(output, "selection.toml"), "w") do io
            TOML.print(io, Dict("selected_second_esn0_db" => science["selected_second_esn0_db"],
                "bp_saturated_on_grid" => science["bp_saturated_on_grid"],
                "profile" => science["profile"]); sorted=true)
        end
    else
        aggregates = NamedTuple[]
        for endpoint in ENDPOINTS
            c = science["bp_minus_gd"][endpoint]
            push!(aggregates, (; endpoint, pairs=c["pairs"],
                both_success=c["both_success"], bp_only_success=c["treatment_only_success"],
                gd_only_success=c["reference_only_success"], both_failure=c["both_failure"],
                bp_successes=c["treatment_successes"], gd_successes=c["reference_successes"],
                risk_difference_bp_minus_gd=c["risk_difference_treatment_minus_reference"],
                interval_lower=c["newcombe_interval"]["lower"],
                interval_upper=c["newcombe_interval"]["upper"],
                mcnemar_p=c["mcnemar_exact_two_sided_pvalue"],
                holm_p=c["holm_adjusted_pvalue"]))
        end
        write_csv(joinpath(output, "aggregate.csv"), aggregates,
                  propertynames(first(aggregates)))
    end
    split = load_split_config(config)
    source_directory = joinpath(output, "source"); mkdir(source_directory)
    records = Legacy.archive_sources(source_directory,
        freeze_source_paths(config, config_path))
    manifest = Dict(
        "schema_version" => String(config["provenance"]["manifest_schema"]),
        "experiment_id" => String(config["experiment_id"]), "stage" => String(stage),
        "created_utc" => string(now(UTC)), "command" => String(command),
        "freeze" => abspath(freeze),
        "freeze_manifest_sha256" => file_sha256(joinpath(freeze, "freeze_manifest.toml")),
        "base_scientific_sha256" => base_hash,
        "stored_scientific_sha256" => scientific_sha256(science),
        "environment" => environment_record(split), "sources" => records)
    open(joinpath(output, "manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    status = science["correctness_passed"] ? "complete_valid" : "complete_invalid"
    completion = Dict(
        "schema_version" => String(config["provenance"]["completion_schema"]),
        "experiment_id" => String(config["experiment_id"]), "stage" => String(stage),
        "completed_utc" => string(now(UTC)), "status" => status,
        "correctness_passed" => Bool(science["correctness_passed"]),
        "deterministic_replay_passed" => replay_passed,
        "science_sha256" => file_sha256(science_path))
    open(joinpath(output, "COMPLETED.toml"), "w") do io
        TOML.print(io, completion; sorted=true)
    end
    write_progress(joinpath(output, "progress.toml"), Dict(
        "experiment_id" => String(config["experiment_id"]), "stage" => String(stage),
        "pass" => "artifact_write", "status" => status,
        "frames_completed" => Int(science["points"]),
        "frames_total" => Int(science["points"]), "updated_utc" => string(now(UTC))))
    Legacy.write_checksum_manifest(output)
    (; output, science, completion)
end

function run_stage(stage::Symbol, output, freeze; config_path=DEFAULT_CONFIG,
                   profile_result=nothing, command=String(stage))
    config = load_config(config_path)
    output = abspath(output)
    ispath(output) && throw(ArgumentError("result output already exists: $output"))
    second_esn0 = nothing
    if stage === :second
        profile_result === nothing && throw(ArgumentError(
            "second stage requires --profile-result"))
        checksum = Legacy.verify_checksum_manifest(profile_result)
        Bool(checksum["passed"]) || throw(ArgumentError("profile result checksum failed"))
        completion = TOML.parsefile(joinpath(profile_result, "COMPLETED.toml"))
        completion["status"] == "complete_valid" || throw(ArgumentError(
            "profile result is not complete_valid"))
        selection = TOML.parsefile(joinpath(profile_result, "selection.toml"))
        second_esn0 = Float64(selection["selected_second_esn0_db"])
    end
    mkpath(dirname(output)); mkdir(output)
    progress_path = joinpath(output, "progress.toml")
    started = string(now(UTC))
    try
        calculated = calculate_science(config, freeze, stage; collect_runtime=true,
            config_path, progress_path, pass_name="primary", started_utc=started,
            second_esn0)
        replay = calculate_science(config, freeze, stage; collect_runtime=false,
            config_path, progress_path, pass_name="replay", started_utc=started,
            second_esn0)
        first_hash = scientific_sha256(calculated.science)
        replay_hash = scientific_sha256(replay.science)
        write_result(output, config, config_path, freeze, stage, calculated,
            replay_hash, first_hash == replay_hash, String(command))
    catch exception
        write_progress(progress_path, Dict("stage" => String(stage), "status" => "failed",
            "error" => sprint(showerror, exception), "updated_utc" => string(now(UTC))))
        rethrow()
    end
end

function verify_result(result; config_path=DEFAULT_CONFIG)
    config = load_config(config_path)
    checksum = Legacy.verify_checksum_manifest(result)
    completion = TOML.parsefile(joinpath(result, "COMPLETED.toml"))
    passed = Bool(checksum["passed"]) && completion["status"] == "complete_valid" &&
        completion["experiment_id"] == config["experiment_id"] &&
        completion["science_sha256"] == file_sha256(joinpath(result, "science.json"))
    Dict("passed" => passed, "checksum" => checksum, "completion" => completion)
end

function usage()
    "usage:\n" *
    "  rq2_native_gap_001.jl preflight-probe\n" *
    "  rq2_native_gap_001.jl freeze --output DIR\n" *
    "  rq2_native_gap_001.jl six|profile --freeze DIR --output DIR\n" *
    "  rq2_native_gap_001.jl second --freeze DIR --profile-result DIR --output DIR\n" *
    "  rq2_native_gap_001.jl verify --result DIR"
end

function main(arguments=ARGS)
    parsed = Legacy.parse_cli(arguments)
    parsed.help && (println(usage()); return 0)
    config_path = get(parsed.options, "config", DEFAULT_CONFIG)
    command = join(vcat(["julia", "--project=" * something(Base.active_project(), ""),
                         RUNNER_PATH], String.(arguments)), " ")
    if parsed.mode === Symbol("preflight-probe")
        config = load_config(config_path)
        gate = source_gate(config)
        gate["passed"] || throw(ArgumentError("source gate failed: $(gate["checks"])"))
        split = load_split_config(config)
        Legacy.enforce_thread_environment(split)
        generated = make_bp_code(config, split)
        println("experiment: ", config["experiment_id"])
        println("graph SHA-256: ", Legacy.graph_sha256(generated.code.check_vars))
        println("bp iterations: ", generated.modem.bp_iterations)
        return 0
    elseif parsed.mode === :freeze
        output = get(parsed.options, "output", nothing)
        output === nothing && throw(ArgumentError("freeze requires --output"))
        frozen = freeze_inputs(output; config_path, command)
        println("frozen input rows: ", frozen["input_rows"])
        return 0
    elseif parsed.mode in (:six, :profile, :second)
        freeze = get(parsed.options, "freeze", nothing)
        output = get(parsed.options, "output", nothing)
        (freeze === nothing || output === nothing) &&
            throw(ArgumentError("$(parsed.mode) requires --freeze and --output"))
        written = run_stage(parsed.mode, output, freeze; config_path,
            profile_result=get(parsed.options, "profile-result", nothing), command)
        println("$(parsed.mode) status: ", written.completion["status"])
        if parsed.mode === :profile
            println("selected second Es/N0: ", written.science["selected_second_esn0_db"],
                    " dB (bp saturated on grid: ",
                    written.science["bp_saturated_on_grid"], ")")
            for (esn0, counts) in sort(collect(written.science["profile"]);
                                       by=p -> parse(Float64, p[1]))
                println("  ", esn0, " dB: bp ", counts[METHODS[1]], "  gd ",
                        counts[METHODS[2]], "  of ", counts["frames"])
            end
        else
            for method in METHODS
                o = written.science["method_outcomes"][method]
                println("  ", method, ": transmitted-word ", o["transmitted_word_equal"],
                        "  parity-valid ", o["parity_valid"], "  of ",
                        written.science["points"])
            end
        end
        return written.completion["correctness_passed"] ? 0 : 2
    elseif parsed.mode === :verify
        result = get(parsed.options, "result", nothing)
        result === nothing && throw(ArgumentError("verify requires --result"))
        verified = verify_result(result; config_path)
        println("verify passed: ", verified["passed"])
        return verified["passed"] ? 0 : 2
    end
    throw(ArgumentError("unsupported mode $(parsed.mode)\n$(usage())"))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    exit(Base.invokelatest(main))
end

end # module
