#!/usr/bin/env julia

module RQ2CommonCoordinateRepro001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using TOML

const HERE = @__DIR__
const EXPERIMENT_ID = "RQ2-COMMON-COORDINATE-REPRO-001"
const CONFIG_SCHEMA = "rq2-common-coordinate-repro-001/config-v1"
const SCIENCE_SCHEMA = "rq2-common-coordinate-repro-001/science-v1"
const GATE_SCHEMA = "rq2-common-coordinate-repro-001/gate-v1"
const COMPLETION_SCHEMA = "rq2-common-coordinate-repro-001/completion-v1"
const PROGRESS_SCHEMA = "rq2-common-coordinate-repro-001/progress-v1"

const NATIVE_FREEZE = normpath(joinpath(
    HERE, "..", "rq2_native_composition_001", "freeze", "2026-11-01_v2"))
const COMPOSITION_RUNNER = joinpath(NATIVE_FREEZE, "source", "native_composition.jl")
const COMPOSITION_CONFIG = joinpath(NATIVE_FREEZE, "source", "config.toml")
const ORACLE_RESULT = normpath(joinpath(
    HERE, "..", "rq2_native_composition_001", "results", "2026-11-01_v2",
    "03_native_endpoint_and_rung_gate"))

include(COMPOSITION_RUNNER)
const Composition = RQ2NativeComposition001
const BlockA = Composition.BlockA
const BlockB = Composition.BlockB
const Legacy = BlockA.Legacy

export GateMismatch, load_config, source_gate, lift_gd, collapse_gd!,
       gd_scalar_evaluate!, gd_edge_evaluate!, gd_active_read_gate,
       bp_transform, bp_transform_reference,
       bp_initial_q, bp_check_from_z, bp_variable_from_u, bp_active_read_gate,
       thread_environment_gate, graph_identity_gate, input_identity_gate,
       run_gd_pair, run_bp_pair, run_gate, main

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
scientific_sha256(value) = Composition.scientific_sha256(value)
vector_sha256(value) = BlockB.vector_sha256(value)
edge_sha256(value) = Legacy.edge_sha256(value)
float_hex(value::Real) = @sprintf("0x%016x", reinterpret(UInt64, Float64(value)))

struct GateMismatch <: Exception
    frame::Int
    lane::String
    iteration::Int
    trial::Int
    field::String
    index::String
    reference::String
    reproduced::String
end

function Base.showerror(io::IO, error::GateMismatch)
    print(io, "trajectory mismatch at frame=$(error.frame) lane=$(error.lane) ",
          "iteration=$(error.iteration) trial=$(error.trial) ",
          "field=$(error.field) index=$(error.index): ",
          "reference=$(error.reference), reproduced=$(error.reproduced)")
end

float_bits_equal(left::Real, right::Real) =
    reinterpret(UInt64, Float64(left)) == reinterpret(UInt64, Float64(right))

function vector_bits_equal(left, right)
    length(left) == length(right) || return false
    reinterpret(UInt64, Float64.(left)) == reinterpret(UInt64, Float64.(right))
end

function edge_bits_equal(left, right)
    length(left) == length(right) || return false
    all(length(left[index]) == length(right[index]) &&
        reinterpret(UInt64, Float64.(left[index])) ==
        reinterpret(UInt64, Float64.(right[index]))
        for index in eachindex(left))
end

function mismatch(frame, lane, iteration, trial, field,
                  reference, reproduced; index="all")
    throw(GateMismatch(Int(frame), String(lane), Int(iteration), Int(trial),
        String(field), String(index), String(reference), String(reproduced)))
end

function require_float(frame, lane, iteration, trial, field, reference, reproduced)
    float_bits_equal(reference, reproduced) || mismatch(
        frame, lane, iteration, trial, field,
        float_hex(reference), float_hex(reproduced))
end

function require_vector(frame, lane, iteration, trial, field, reference, reproduced)
    if !vector_bits_equal(reference, reproduced)
        length(reference) == length(reproduced) || mismatch(
            frame, lane, iteration, trial, field,
            string(length(reference)), string(length(reproduced)); index="length")
        for index in eachindex(reference, reproduced)
            float_bits_equal(reference[index], reproduced[index]) && continue
            mismatch(frame, lane, iteration, trial, field,
                float_hex(reference[index]), float_hex(reproduced[index]);
                index=string(index))
        end
    end
    true
end

function require_bool_vector(frame, lane, iteration, trial, field,
                             reference, reproduced)
    left = Bool.(reference)
    right = Bool.(reproduced)
    length(left) == length(right) || mismatch(
        frame, lane, iteration, trial, field,
        string(length(left)), string(length(right)); index="length")
    for index in eachindex(left, right)
        left[index] == right[index] && continue
        mismatch(frame, lane, iteration, trial, field,
            string(left[index]), string(right[index]); index=string(index))
    end
    true
end

function require_complex_vector(frame, lane, iteration, trial, field,
                                reference, reproduced)
    length(reference) == length(reproduced) || mismatch(
        frame, lane, iteration, trial, field,
        string(length(reference)), string(length(reproduced)); index="length")
    for index in eachindex(reference, reproduced)
        left = ComplexF64(reference[index])
        right = ComplexF64(reproduced[index])
        if !float_bits_equal(real(left), real(right))
            mismatch(frame, lane, iteration, trial, field,
                float_hex(real(left)), float_hex(real(right));
                index="$(index)_real")
        end
        if !float_bits_equal(imag(left), imag(right))
            mismatch(frame, lane, iteration, trial, field,
                float_hex(imag(left)), float_hex(imag(right));
                index="$(index)_imag")
        end
    end
    true
end

function require_scalar_value(frame, lane, iteration, trial, field,
                              reference, reproduced)
    reference == reproduced || mismatch(
        frame, lane, iteration, trial, field,
        string(reference), string(reproduced))
    true
end

function require_edges(frame, lane, iteration, trial, field, reference, reproduced)
    if !edge_bits_equal(reference, reproduced)
        length(reference) == length(reproduced) || mismatch(
            frame, lane, iteration, trial, field,
            string(length(reference)), string(length(reproduced)); index="rows")
        for row in eachindex(reference, reproduced)
            length(reference[row]) == length(reproduced[row]) || mismatch(
                frame, lane, iteration, trial, field,
                string(length(reference[row])), string(length(reproduced[row]));
                index="row_$row")
            for slot in eachindex(reference[row], reproduced[row])
                float_bits_equal(reference[row][slot], reproduced[row][slot]) && continue
                mismatch(frame, lane, iteration, trial, field,
                    float_hex(reference[row][slot]), float_hex(reproduced[row][slot]);
                    index="row_$(row)_slot_$(slot)")
            end
        end
    end
    true
end

function load_config(path::AbstractString=joinpath(HERE, "config.toml"))
    config = TOML.parsefile(path)
    get(config, "schema_version", "") == CONFIG_SCHEMA ||
        throw(ArgumentError("unsupported configuration schema"))
    get(config, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("unexpected experiment identifier"))
    get(config, "research_question", "") == "RQ2 validation prerequisite" ||
        throw(ArgumentError("research-question classification changed"))
    Bool(config["performance_inference_allowed"]) == false ||
        throw(ArgumentError("performance inference is forbidden"))
    protocol = config["protocol"]
    Int(protocol["frame_first"]) == 20001 ||
        throw(ArgumentError("retained first frame changed"))
    Int(protocol["frame_last"]) == 20024 ||
        throw(ArgumentError("retained last frame changed"))
    Int(protocol["case_count"]) == 24 ||
        throw(ArgumentError("retained case count changed"))
    String(protocol["channel_label"]) == "six_db" ||
        throw(ArgumentError("retained channel changed"))
    Float64(protocol["snr_db"]) == 6.0 ||
        throw(ArgumentError("retained SNR changed"))
    Float64(protocol["noise_variance"]) == 0.251188643150958 ||
        throw(ArgumentError("registered noise variance changed"))
    Bool(protocol["fresh_performance_cases"]) == false ||
        throw(ArgumentError("fresh performance cases are forbidden"))
    String(protocol["transmitted_word"]) == "all_zero" ||
        throw(ArgumentError("transmitted word changed"))
    String(protocol["llr_sign"]) == "positive_favors_zero" ||
        throw(ArgumentError("LLR sign convention changed"))
    Float64(protocol["llr_clip"]) == 20.0 ||
        throw(ArgumentError("LLR clip changed"))
    gd = config["gd"]
    Int(gd["maximum_update_attempts"]) == 30 ||
        throw(ArgumentError("GD update budget changed"))
    Float64(gd["parity_weight"]) == 2.0 ||
        throw(ArgumentError("GD parity weight changed"))
    Float64(gd["binary_weight"]) == 0.2 ||
        throw(ArgumentError("GD binary weight changed"))
    Float64(gd["initial_step"]) == 0.2 ||
        throw(ArgumentError("GD initial step changed"))
    Int(gd["maximum_backtracks"]) == 16 ||
        throw(ArgumentError("GD backtrack budget changed"))
    Int(gd["edge_reads_per_objective_evaluation"]) == 61200 ||
        throw(ArgumentError("GD active-read count changed"))
    Bool(gd["copies_tied"]) && !Bool(gd["copies_independently_optimized"]) ||
        throw(ArgumentError("GD edge-copy contract changed"))
    Bool(gd["parity_reads_edge_values"]) ||
        throw(ArgumentError("GD active edge-value contract changed"))
    all(Bool(gd[field]) for field in (
        "native_objective_unchanged", "native_update_unchanged",
        "native_projection_unchanged", "native_stopping_unchanged")) ||
        throw(ArgumentError("GD native-operation contract changed"))
    bp = config["bp"]
    Int(bp["maximum_message_passing_iterations"]) == 80 ||
        throw(ArgumentError("BP iteration cap changed"))
    Float64(bp["damping"]) == 0.0 ||
        throw(ArgumentError("BP damping changed"))
    Int(bp["edge_reads_per_check_phase"]) == 153000 ||
        throw(ArgumentError("BP active-read count changed"))
    Bool(bp["recipient_specific"]) ||
        throw(ArgumentError("BP recipient-specific state changed"))
    Bool(bp["inverse_coordinate_reconstruction_forbidden"]) ||
        throw(ArgumentError("BP inverse reconstruction prohibition changed"))
    Bool(bp["check_reads_edge_values_with_q_unavailable"]) ||
        throw(ArgumentError("BP active edge-value contract changed"))
    execution = config["execution"]
    Int(execution["scientific_passes"]) == 2 ||
        throw(ArgumentError("primary and deterministic replay are required"))
    String.(execution["pass_names"]) == ["primary", "replay"] ||
        throw(ArgumentError("scientific pass names changed"))
    Bool(execution["automatic_downstream_launch_allowed"]) == false ||
        throw(ArgumentError("automatic downstream launch is forbidden"))
    config
end

function verify_manifest(root::AbstractString)
    manifest = joinpath(root, "MANIFEST.sha256")
    isfile(manifest) || return Dict("passed" => false,
        "reason" => "missing_manifest", "root" => abspath(root))
    failures = String[]
    entries = 0
    for line in eachline(manifest)
        isempty(line) && continue
        fields = split(line, "  "; limit=2)
        if length(fields) != 2
            push!(failures, "malformed:$line")
            continue
        end
        expected, relative = fields
        candidate = normpath(joinpath(root, relative))
        if !startswith(candidate, normpath(root) * Base.Filesystem.path_separator)
            push!(failures, "unsafe:$relative")
        elseif !isfile(candidate)
            push!(failures, "missing:$relative")
        elseif file_sha256(candidate) != expected
            push!(failures, "hash:$relative")
        end
        entries += 1
    end
    Dict("passed" => isempty(failures), "entries" => entries,
         "failures" => failures, "root" => abspath(root))
end

function source_gate(config; require_study_freeze::Bool=false)
    sources = config["sources"]
    paths = Dict(
        "native_freeze_manifest" => joinpath(NATIVE_FREEZE, "MANIFEST.sha256"),
        "native_freeze_metadata" => joinpath(NATIVE_FREEZE, "freeze_manifest.toml"),
        "native_composition_runner" => COMPOSITION_RUNNER,
        "native_composition_config" => COMPOSITION_CONFIG,
        "rung_registry" => joinpath(NATIVE_FREEZE, "source", "rung_registry.toml"),
        "block_a_runner" => joinpath(NATIVE_FREEZE,
            "rq2_gd_residual_projection_budget_001",
            "rq2_gd_residual_projection_budget_001.jl"),
        "block_a_config" => joinpath(NATIVE_FREEZE,
            "rq2_gd_residual_projection_budget_001", "config.toml"),
        "block_b_runner" => joinpath(NATIVE_FREEZE,
            "rq2_bp_target_state_update_001", "rq2_bp_target_state_update_001.jl"),
        "block_b_config" => joinpath(NATIVE_FREEZE,
            "rq2_bp_target_state_update_001", "config.toml"),
        "jade_project" => joinpath(NATIVE_FREEZE, "source", "jade_project", "Project.toml"),
        "jade_manifest" => joinpath(NATIVE_FREEZE, "source", "jade_project", "Manifest.toml"),
        "jade_common" => joinpath(NATIVE_FREEZE, "source", "jade_project", "src", "core", "common.jl"),
        "job03_manifest" => joinpath(ORACLE_RESULT, "MANIFEST.sha256"),
        "job03_completion" => joinpath(ORACLE_RESULT, "COMPLETED.toml"),
        "job03_job_gate" => joinpath(ORACLE_RESULT, "job_gate.toml"),
        "job03_science" => joinpath(ORACLE_RESULT, "science.json"),
        "job03_frames" => joinpath(ORACLE_RESULT, "frames.csv"),
        "job03_iterations" => joinpath(ORACLE_RESULT, "iterations.csv"),
    )
    checks = Dict{String,Bool}()
    for (name, path) in paths
        key = name * "_sha256"
        checks[name] = isfile(path) && haskey(sources, key) &&
            file_sha256(path) == String(sources[key])
    end
    freeze_manifest = verify_manifest(NATIVE_FREEZE)
    oracle_manifest = verify_manifest(ORACLE_RESULT)
    checks["native_freeze_tree"] = Bool(freeze_manifest["passed"])
    checks["job03_result_tree"] = Bool(oracle_manifest["passed"])
    completion = TOML.parsefile(joinpath(ORACLE_RESULT, "COMPLETED.toml"))
    gate = TOML.parsefile(joinpath(ORACLE_RESULT, "job_gate.toml"))
    checks["job03_complete_valid"] = get(completion, "status", "") == "complete_valid"
    checks["job03_correctness"] = Bool(get(completion, "correctness_passed", false))
    checks["job03_replay"] = Bool(get(completion, "deterministic_replay_passed", false))
    checks["job03_gate_pass"] = get(gate, "status", "") == "pass"
    contract = TOML.parsefile(joinpath(HERE, "reference_contract.toml"))
    checks["reference_contract_schema"] = get(contract, "schema_version", "") ==
        "rq2-common-coordinate-repro-001/reference-contract-v1"
    checks["reference_contract_experiment"] = get(contract, "experiment_id", "") ==
        EXPERIMENT_ID
    checks["reference_contract_frames"] =
        Int(get(contract, "frame_first", -1)) ==
            Int(config["protocol"]["frame_first"]) &&
        Int(get(contract, "frame_last", -1)) ==
            Int(config["protocol"]["frame_last"])
    checks["reference_contract_evidence_boundary"] =
        Bool(get(contract, "performance_inference_allowed", true)) == false
    contract_freeze = get(contract, "native_composition_freeze", Dict())
    contract_job = get(contract, "native_composition_job03", Dict())
    checks["reference_contract_freeze"] =
        get(contract_freeze, "manifest_sha256", "") ==
            sources["native_freeze_manifest_sha256"] &&
        get(contract_freeze, "freeze_manifest_sha256", "") ==
            sources["native_freeze_metadata_sha256"] &&
        get(contract_freeze, "composition_runner_sha256", "") ==
            sources["native_composition_runner_sha256"] &&
        get(contract_freeze, "composition_config_sha256", "") ==
            sources["native_composition_config_sha256"]
    checks["reference_contract_job03"] =
        get(contract_job, "manifest_sha256", "") ==
            sources["job03_manifest_sha256"] &&
        get(contract_job, "science_json_sha256", "") ==
            sources["job03_science_sha256"] &&
        get(contract_job, "frames_csv_sha256", "") ==
            sources["job03_frames_sha256"] &&
        get(contract_job, "iterations_csv_sha256", "") ==
            sources["job03_iterations_sha256"] &&
        get(contract_job, "completion_sha256", "") ==
            sources["job03_completion_sha256"] &&
        get(contract_job, "job_gate_sha256", "") ==
            sources["job03_job_gate_sha256"]
    contract_exact = get(contract, "exact_reproduction", Dict())
    checks["reference_contract_exact_reproduction"] =
        get(contract_exact, "gd_edge_value", "") == "z_c_i = x_i" &&
        get(contract_exact, "bp_edge_value", "") ==
            "z_i_to_c = tanh(clamp(Q_i_to_c,-20,20)/2)" &&
        get(contract_exact, "floating_point_equality", "") ==
            "exact_ieee754_bits" &&
        Int(get(contract_exact,
                "gd_edge_reads_per_objective_evaluation", -1)) == 61200 &&
        Int(get(contract_exact, "bp_edge_reads_per_check_phase", -1)) == 153000 &&
        Bool(get(contract_exact,
                 "inverse_bp_coordinate_reconstruction_allowed", true)) == false &&
        Bool(get(contract_exact,
                 "automatic_downstream_launch_allowed", true)) == false
    study_freeze = Dict{String,Any}(
        "required" => require_study_freeze,
        "passed" => !require_study_freeze)
    if require_study_freeze
        study_root = normpath(joinpath(HERE, "..", ".."))
        metadata_path = joinpath(study_root, "freeze_manifest.toml")
        isfile(metadata_path) || mismatch(
            0, "source", 0, 0, "study_freeze_metadata", "present", "missing")
        metadata = TOML.parsefile(metadata_path)
        get(metadata, "experiment_id", "") == EXPERIMENT_ID || mismatch(
            0, "source", 0, 0, "study_freeze_experiment",
            EXPERIMENT_ID, string(get(metadata, "experiment_id", "missing")))
        manifest_result = verify_manifest(study_root)
        Bool(manifest_result["passed"]) || mismatch(
            0, "source", 0, 0, "study_freeze_manifest", "true",
            scientific_sha256(manifest_result["failures"]))
        expected_here = normpath(joinpath(
            study_root, "source", basename(HERE)))
        realpath(expected_here) == realpath(HERE) || mismatch(
            0, "source", 0, 0, "study_source_location",
            expected_here, realpath(HERE))
        study_freeze = Dict(
            "required" => true,
            "passed" => true,
            "root" => abspath(study_root),
            "manifest_sha256" => file_sha256(joinpath(
                study_root, "MANIFEST.sha256")),
            "metadata_sha256" => file_sha256(metadata_path),
            "entries" => manifest_result["entries"],
        )
    end
    if !all(values(checks))
        failed = first(sort([name for (name, passed) in checks if !passed]))
        mismatch(0, "source", 0, 0, failed, "true", "false")
    end
    Dict("passed" => true, "checks" => checks,
         "freeze_manifest" => freeze_manifest,
         "oracle_manifest" => oracle_manifest,
         "paths" => Dict(key => abspath(value) for (key, value) in paths),
         "study_freeze" => study_freeze,
         "reference_contract_sha256" =>
             file_sha256(joinpath(HERE, "reference_contract.toml")))
end

function thread_environment_gate(config)
    execution = config["execution"]
    expected_julia = Int(execution["julia_threads"])
    expected_blas = Int(execution["blas_threads"])
    expected_omp = string(execution["omp_threads"])
    Threads.nthreads() == expected_julia || mismatch(
        0, "execution", 0, 0, "julia_threads",
        string(expected_julia), string(Threads.nthreads()))
    get(ENV, "OMP_NUM_THREADS", "") == expected_omp || mismatch(
        0, "execution", 0, 0, "omp_threads",
        expected_omp, get(ENV, "OMP_NUM_THREADS", "missing"))
    BLAS.set_num_threads(expected_blas)
    BLAS.get_num_threads() == expected_blas || mismatch(
        0, "execution", 0, 0, "blas_threads",
        string(expected_blas), string(BLAS.get_num_threads()))
    Dict("passed" => true,
         "julia_threads" => Threads.nthreads(),
         "blas_threads" => BLAS.get_num_threads(),
         "omp_threads" => parse(Int, expected_omp))
end

function graph_identity_gate(context, config)
    sources = config["sources"]
    expected_hash = String(sources["graph_sha256"])
    gd_checks = [Int.(check) for check in context.code.check_vars]
    bp_checks = [Int.(check) for check in context.bp_code.check_vars]
    graph_checks = context.graph.checks
    observed_gd_hash = BlockB.graph_sha256(gd_checks)
    observed_bp_hash = BlockB.graph_sha256(bp_checks)
    observed_view_hash = BlockB.graph_sha256(graph_checks)
    for (field, observed) in (
            ("gd_graph_sha256", observed_gd_hash),
            ("bp_graph_sha256", observed_bp_hash),
            ("graph_view_sha256", observed_view_hash))
        observed == expected_hash || mismatch(
            0, "graph", 0, 0, field, expected_hash, observed)
    end
    gd_checks == bp_checks || mismatch(
        0, "graph", 0, 0, "bp_adjacency_order",
        scientific_sha256(gd_checks), scientific_sha256(bp_checks))
    gd_checks == graph_checks || mismatch(
        0, "graph", 0, 0, "graph_view_adjacency_order",
        scientific_sha256(gd_checks), scientific_sha256(graph_checks))
    rebuilt = BlockB.GraphView(deepcopy(gd_checks), context.code.n)
    rebuilt.check_edges == context.graph.check_edges || mismatch(
        0, "graph", 0, 0, "check_edge_order",
        scientific_sha256(rebuilt.check_edges),
        scientific_sha256(context.graph.check_edges))
    rebuilt.variable_edges == context.graph.variable_edges || mismatch(
        0, "graph", 0, 0, "variable_edge_order",
        scientific_sha256(rebuilt.variable_edges),
        scientific_sha256(context.graph.variable_edges))
    rebuilt.edge_variable == context.graph.edge_variable || mismatch(
        0, "graph", 0, 0, "edge_variable_order",
        scientific_sha256(rebuilt.edge_variable),
        scientific_sha256(context.graph.edge_variable))

    expected_root = realpath(joinpath(NATIVE_FREEZE, "source", "jade_project"))
    loaded_root = realpath(dirname(dirname(pathof(JadeJcade))))
    loaded_root == expected_root || mismatch(
        0, "source", 0, 0, "loaded_jade_root", expected_root, loaded_root)
    registered_head = String(sources["jade_expected_git_head"])
    upstream_head = String(context.block_b_config["sources"][
        "jade_project_expected_head"])
    registered_head == upstream_head || mismatch(
        0, "source", 0, 0, "jade_provenance_head",
        registered_head, upstream_head)
    Dict("passed" => true,
         "graph_sha256" => expected_hash,
         "adjacency_sha256" => scientific_sha256(gd_checks),
         "loaded_jade_root" => loaded_root,
         "jade_provenance_head" => registered_head)
end

function input_identity_gate(context, config, frame::Int, input, legacy_input)
    protocol = config["protocol"]
    first_frame = Int(protocol["frame_first"])
    last_frame = Int(protocol["frame_last"])
    first_frame <= frame <= last_frame || mismatch(
        frame, "input", 0, 0, "retained_frame_range",
        "$(first_frame):$(last_frame)", string(frame))
    input.frame == frame || mismatch(
        frame, "input", 0, 0, "composition_frame", string(frame),
        string(input.frame))
    legacy_input.frame == frame || mismatch(
        frame, "input", 0, 0, "legacy_frame", string(frame),
        string(legacy_input.frame))
    String(input.channel_label) == String(protocol["channel_label"]) || mismatch(
        frame, "input", 0, 0, "channel_label",
        String(protocol["channel_label"]), String(input.channel_label))
    require_float(frame, "input", 0, 0, "snr_db",
                  Float64(protocol["snr_db"]), input.snr_db)
    variance = Float64(protocol["noise_variance"])
    require_float(frame, "input", 0, 0, "noise_variance",
                  variance, legacy_input.variance)
    require_float(frame, "input", 0, 0, "composition_noise_variance",
                  variance, input.variance)
    input.seed == legacy_input.noise_seed || mismatch(
        frame, "input", 0, 0, "noise_seed",
        string(legacy_input.noise_seed), string(input.seed))

    n = context.code.n
    expected_bits = falses(n)
    expected_symbols = Vector{ComplexF64}(undef, n ÷ 2)
    scale = inv(sqrt(2.0))
    @inbounds for symbol in eachindex(expected_symbols)
        expected_symbols[symbol] = complex(1.0, 1.0) * scale
    end
    rng = MersenneTwister(input.seed)
    expected_noise = complex.(randn(rng, length(expected_symbols)),
                              randn(rng, length(expected_symbols))) ./ sqrt(2.0)
    expected_received = expected_symbols .+ sqrt(variance) .* expected_noise
    expected_raw_llr = Vector{Float64}(undef, n)
    llr_scale = 2sqrt(2.0) / variance
    @inbounds for symbol in eachindex(expected_received)
        expected_raw_llr[2symbol - 1] = llr_scale * real(expected_received[symbol])
        expected_raw_llr[2symbol] = llr_scale * imag(expected_received[symbol])
    end
    clip = Float64(protocol["llr_clip"])
    expected_clipped_llr = clamp.(expected_raw_llr, -clip, clip)

    require_bool_vector(frame, "input", 0, 0, "transmitted_bits",
                        expected_bits, legacy_input.transmitted_bits)
    require_complex_vector(frame, "input", 0, 0, "transmitted_symbols",
                           expected_symbols, legacy_input.transmitted_symbols)
    require_complex_vector(frame, "input", 0, 0, "unit_noise",
                           expected_noise, legacy_input.unit_noise)
    require_complex_vector(frame, "input", 0, 0, "received_samples",
                           expected_received, legacy_input.received)
    require_vector(frame, "input", 0, 0, "raw_llr",
                   expected_raw_llr, legacy_input.raw_llr)
    require_vector(frame, "input", 0, 0, "clipped_llr",
                   expected_clipped_llr, legacy_input.clipped_llr)
    require_vector(frame, "input", 0, 0, "composition_clipped_llr",
                   expected_clipped_llr, input.llr)

    expected_hashes = Dict(
        "transmitted_word_sha256" => vector_sha256(expected_bits),
        "transmitted_symbols_sha256" => vector_sha256(expected_symbols),
        "unit_noise_sha256" => vector_sha256(expected_noise),
        "received_sha256" => vector_sha256(expected_received),
        "raw_llr_sha256" => vector_sha256(expected_raw_llr),
        "clipped_llr_sha256" => vector_sha256(expected_clipped_llr),
        "graph_sha256" => String(config["sources"]["graph_sha256"]),
    )
    for field in sort(collect(keys(expected_hashes)))
        observed = string(getproperty(legacy_input.identities, Symbol(field)))
        expected = expected_hashes[field]
        observed == expected || mismatch(
            frame, "input", 0, 0, field, expected, observed)
    end
    input.received_sha256 == expected_hashes["received_sha256"] || mismatch(
        frame, "input", 0, 0, "composition_received_sha256",
        expected_hashes["received_sha256"], input.received_sha256)
    input.unit_noise_sha256 == expected_hashes["unit_noise_sha256"] || mismatch(
        frame, "input", 0, 0, "composition_unit_noise_sha256",
        expected_hashes["unit_noise_sha256"], input.unit_noise_sha256)
    input.llr_sha256 == expected_hashes["clipped_llr_sha256"] || mismatch(
        frame, "input", 0, 0, "composition_clipped_llr_sha256",
        expected_hashes["clipped_llr_sha256"], input.llr_sha256)
    Dict("passed" => true, "identities" => expected_hashes,
         "noise_seed" => input.seed)
end

# ---------------------------------------------------------------------------
# Projected-GD edge-value reproduction
# ---------------------------------------------------------------------------

lift_gd(x, checks) = [[Float64(x[bit]) for bit in check] for check in checks]

function assert_gd_tied!(z, problem; frame=0, iteration=0, trial=0)
    length(z) == length(problem.check_vars) || mismatch(
        frame, "gd", iteration, trial, "edge_row_count",
        string(length(problem.check_vars)), string(length(z)))
    for bit in eachindex(problem.var_edges)
        incident = problem.var_edges[bit]
        isempty(incident) && mismatch(frame, "gd", iteration, trial,
            "isolated_bit", "incident edge", "none"; index=string(bit))
        first_check, first_slot = first(incident)
        canonical = z[first_check][first_slot]
        for (check, slot) in incident
            float_bits_equal(canonical, z[check][slot]) || mismatch(
                frame, "gd", iteration, trial, "tied_copy", float_hex(canonical),
                float_hex(z[check][slot]); index="bit_$(bit)_check_$(check)")
        end
    end
    true
end

function collapse_gd!(x, z, problem; frame=0, iteration=0, trial=0)
    length(x) == length(problem.var_edges) ||
        throw(DimensionMismatch("temporary scalar length changed"))
    assert_gd_tied!(z, problem; frame, iteration, trial)
    for bit in eachindex(problem.var_edges)
        check, slot = first(problem.var_edges[bit])
        x[bit] = z[check][slot]
    end
    x
end

function broadcast_gd!(z, x, problem)
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        length(z[check_index]) == length(check) ||
            throw(DimensionMismatch("edge slot count changed"))
        for (slot, bit) in enumerate(check)
            z[check_index][slot] = Float64(x[bit])
        end
    end
    z
end

"""Native compound objective whose parity calculation reads only edge values z."""
function gd_edge_evaluate!(workspace::Legacy.EvalWorkspace, problem, x, z;
                           enforce_tied::Bool=true,
                           frame::Int=0, iteration::Int=0, trial::Int=0)
    n = length(problem.llr)
    length(x) == n || throw(DimensionMismatch("temporary scalar length changed"))
    enforce_tied && assert_gd_tied!(z, problem; frame, iteration, trial)
    fill!(workspace.gradient, 0.0)
    fill!(workspace.h, 0.0)
    for row in workspace.g_rows
        fill!(row, 0.0)
    end

    check_count = length(problem.check_vars)
    scale = 1.0 / check_count
    parity_loss = 0.0
    edge_reads = 0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        product = 1.0
        for slot in eachindex(check)
            workspace.prefix[slot] = product
            product *= Float64(z[check_index][slot])
            edge_reads += 1
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
            suffix *= Float64(z[check_index][slot])
            edge_reads += 1
        end
    end
    factor = problem.parity_weight * check_count / n
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
       gradient=workspace.gradient, h=workspace.h,
       g_rows=workspace.g_rows, edge_reads)
end

"""Independent native-order decomposition whose parity calculation reads x."""
function gd_scalar_evaluate!(workspace::Legacy.EvalWorkspace, problem, x)
    n = length(problem.llr)
    length(x) == n || throw(DimensionMismatch("scalar state length changed"))
    fill!(workspace.gradient, 0.0)
    fill!(workspace.h, 0.0)
    for row in workspace.g_rows
        fill!(row, 0.0)
    end

    check_count = length(problem.check_vars)
    scale = 1.0 / check_count
    parity_loss = 0.0
    @inbounds for (check_index, check) in enumerate(problem.check_vars)
        product = 1.0
        for (slot, bit) in enumerate(check)
            workspace.prefix[slot] = product
            product *= Float64(x[bit])
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
            suffix *= Float64(x[bit])
        end
    end
    factor = problem.parity_weight * check_count / n
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
       gradient=workspace.gradient, h=workspace.h,
       g_rows=workspace.g_rows)
end

function compare_gd_evaluation!(reference_workspace, treatment_workspace,
                                problem, x_reference, x_treatment, z;
                                frame, iteration, trial, expected_reads,
                                native_module=nothing, native_problem=nothing)
    reference = gd_scalar_evaluate!(reference_workspace, problem, x_reference)
    treatment = gd_edge_evaluate!(
        treatment_workspace, problem, x_treatment, z;
        frame, iteration, trial)
    if native_module !== nothing
        native_problem === nothing && throw(ArgumentError(
            "native problem is required with the native module"))
        native = Legacy.native_call(
            native_module, :objective_gradient, native_problem, x_reference)
        for term in (:channel, :parity, :binary)
            require_float(frame, "gd", iteration, trial,
                "native_$(term)", getproperty(native.terms, term),
                getproperty(reference.terms, term))
        end
        require_float(frame, "gd", iteration, trial, "native_loss",
                      native.loss, reference.loss)
        require_vector(frame, "gd", iteration, trial, "native_gradient",
                       native.gradient, reference.gradient)
    end
    for term in (:channel, :parity, :binary)
        require_float(frame, "gd", iteration, trial, String(term),
            getproperty(reference.terms, term), getproperty(treatment.terms, term))
    end
    require_float(frame, "gd", iteration, trial, "loss",
                  reference.loss, treatment.loss)
    require_vector(frame, "gd", iteration, trial, "gradient",
                   reference.gradient, treatment.gradient)
    require_vector(frame, "gd", iteration, trial, "h",
                   reference.h, treatment.h)
    require_edges(frame, "gd", iteration, trial, "check_partials",
                  reference.g_rows, treatment.g_rows)
    treatment.edge_reads == expected_reads || mismatch(
        frame, "gd", iteration, trial, "active_edge_reads",
        string(expected_reads), string(treatment.edge_reads))
    reference, treatment
end

function gd_active_read_gate(problem, x; expected_reads::Int)
    z = lift_gd(x, problem.check_vars)
    baseline_workspace = Legacy.EvalWorkspace(problem)
    changed_workspace = Legacy.EvalWorkspace(problem)
    baseline = gd_edge_evaluate!(baseline_workspace, problem, x, z)
    poisoned = Legacy.copy_edge_rows(z)
    value = poisoned[1][1]
    poisoned[1][1] = clamp(value + (value <= 0.75 ? 0.125 : -0.125), -1.0, 1.0)
    changed = gd_edge_evaluate!(changed_workspace, problem, x, poisoned;
                                enforce_tied=false)
    other_checks_unchanged = all(
        edge_bits_equal([baseline.g_rows[index]], [changed.g_rows[index]])
        for index in 2:length(problem.check_vars))
    checks = Dict(
        "registered_read_count" => baseline.edge_reads == expected_reads,
        "parity_changed" => !float_bits_equal(
            baseline.terms.parity, changed.terms.parity),
        "poisoned_check_changed" => !edge_bits_equal(
            [baseline.g_rows[1]], [changed.g_rows[1]]),
        "other_checks_unchanged" => other_checks_unchanged,
        "tied_invariant_rejects_poison" => try
            assert_gd_tied!(poisoned, problem)
            false
        catch error
            error isa GateMismatch
        end,
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "edge_reads" => baseline.edge_reads)
end

function require_state_metrics(frame, lane, iteration, trial,
                               reference, reproduced)
    require_bool_vector(frame, lane, iteration, trial, "hard_decision",
                        reference.hard, reproduced.hard)
    require_bool_vector(frame, lane, iteration, trial, "syndrome",
                        reference.syndrome, reproduced.syndrome)
    for field in (:syndrome_weight, :parity_valid,
                  :transmitted_word_equal, :coded_bit_errors,
                  :hard_word_sha256)
        require_scalar_value(frame, lane, iteration, trial, String(field),
            getproperty(reference, field), getproperty(reproduced, field))
    end
    true
end

function run_gd_pair(context, llr, frame::Int, config; native=nothing)
    native === nothing && (native = Composition.native_gd_and_oracle(context, llr))
    Bool(native.gate["passed"]) || mismatch(
        frame, "gd", 0, 0, "native_oracle_gate", "true", "false")
    Bool(native.shadow_gate["passed"]) || mismatch(
        frame, "gd", 0, 0, "shadow_oracle_gate", "true", "false")

    gd = config["gd"]
    problem = BlockA.BridgeProblem(context.code, llr;
        parity_weight=Float64(gd["parity_weight"]),
        binary_weight=Float64(gd["binary_weight"]))
    native_problem = Legacy.native_call(
        context.native, :ScalarProblem, context.code, llr;
        parity_weight=Float64(gd["parity_weight"]),
        binary_weight=Float64(gd["binary_weight"]))
    require_vector(frame, "gd", 0, 0, "native_llr",
                   native_problem.llr, problem.llr)
    require_vector(frame, "gd", 0, 0, "native_curvature_bound",
                   native_problem.curvature_bound, problem.curvature_bound)
    initial = tanh.(llr ./ 2.0)
    require_vector(frame, "gd", 0, 0, "native_initial_state",
                   native.initial, initial)
    x_reference = clamp.(Float64.(initial), -1.0, 1.0)
    z = lift_gd(x_reference, problem.check_vars)
    z_trial = lift_gd(x_reference, problem.check_vars)
    x_treatment = similar(x_reference)
    collapse_gd!(x_treatment, z, problem; frame)
    require_vector(frame, "gd", 0, 0, "initial_state", x_reference, x_treatment)

    trial_reference = similar(x_reference)
    trial_treatment = similar(x_reference)
    projected_edge_scalar = similar(x_reference)
    raw_reference = similar(x_reference)
    raw_treatment = similar(x_reference)
    direction_reference = similar(x_reference)
    direction_treatment = similar(x_reference)
    reference_workspace = Legacy.EvalWorkspace(problem)
    treatment_workspace = Legacy.EvalWorkspace(problem)
    trial_reference_workspace = Legacy.EvalWorkspace(problem)
    trial_treatment_workspace = Legacy.EvalWorkspace(problem)
    history = Float64[]
    state_hashes = String[vector_sha256(x_reference)]
    iteration_rows = NamedTuple[]
    accepted_steps = 0
    status = "steps_completed"
    current_loss = NaN
    expected_reads = Int(gd["edge_reads_per_objective_evaluation"])

    initial_reference_metrics = BlockA.state_metrics(
        problem, context.code, x_reference)
    initial_treatment_metrics = BlockA.state_metrics(
        problem, context.code, x_treatment)
    require_state_metrics(frame, "gd", 0, 0,
                          initial_reference_metrics, initial_treatment_metrics)

    for iteration in 1:Int(gd["maximum_update_attempts"])
        collapse_gd!(x_treatment, z, problem; frame, iteration)
        require_vector(frame, "gd", iteration, 0, "state_boundary",
                       x_reference, x_treatment)
        reference, treatment = compare_gd_evaluation!(
            reference_workspace, treatment_workspace, problem,
            x_reference, x_treatment, z;
            frame, iteration, trial=0, expected_reads,
            native_module=context.native, native_problem)
        isempty(history) && push!(history, reference.loss)
        current_loss = reference.loss
        @inbounds for bit in eachindex(x_reference)
            direction_reference[bit] = -reference.gradient[bit] /
                problem.curvature_bound[bit]
            direction_treatment[bit] = -treatment.gradient[bit] /
                problem.curvature_bound[bit]
        end
        require_vector(frame, "gd", iteration, 0, "preconditioned_direction",
                       direction_reference, direction_treatment)

        accepted = false
        accepted_step = 0.0
        accepted_loss = reference.loss
        trial_count = 0
        for backtrack in 0:Int(gd["maximum_backtracks"])
            step = Float64(gd["initial_step"]) * 0.5^backtrack
            @inbounds for bit in eachindex(x_reference)
                raw_reference[bit] = x_reference[bit] + step * direction_reference[bit]
                raw_treatment[bit] = x_treatment[bit] + step * direction_treatment[bit]
                trial_reference[bit] = clamp(raw_reference[bit], -1.0, 1.0)
                trial_treatment[bit] = clamp(raw_treatment[bit], -1.0, 1.0)
            end
            trial_count += 1
            require_vector(frame, "gd", iteration, trial_count, "raw_trial",
                           raw_reference, raw_treatment)
            require_vector(frame, "gd", iteration, trial_count, "projected_trial",
                           trial_reference, trial_treatment)
            broadcast_gd!(z_trial, trial_treatment, problem)
            collapse_gd!(projected_edge_scalar, z_trial, problem;
                         frame, iteration, trial=trial_count)
            require_vector(frame, "gd", iteration, trial_count,
                           "projected_edge_copy", trial_treatment,
                           projected_edge_scalar)
            reference_trial, treatment_trial = compare_gd_evaluation!(
                trial_reference_workspace, trial_treatment_workspace, problem,
                trial_reference, trial_treatment, z_trial;
                frame, iteration, trial=trial_count, expected_reads,
                native_module=context.native, native_problem)
            reference_accept = isfinite(reference_trial.loss) &&
                reference_trial.loss < reference.loss
            treatment_accept = isfinite(treatment_trial.loss) &&
                treatment_trial.loss < treatment.loss
            reference_accept == treatment_accept || mismatch(
                frame, "gd", iteration, trial_count, "acceptance_decision",
                string(reference_accept), string(treatment_accept))
            if reference_accept
                accepted = true
                accepted_step = step
                accepted_loss = reference_trial.loss
                break
            end
        end

        if !accepted
            status = "line_search_stalled"
            push!(iteration_rows, (;
                frame, lane="gd", iteration, trial_count,
                accepted=false, state_sha256=vector_sha256(x_reference),
                auxiliary_sha256=edge_sha256(z), syndrome_weight=-1,
                status, active_reads=expected_reads * (1 + trial_count)))
            break
        end

        x_reference, trial_reference = trial_reference, x_reference
        z, z_trial = z_trial, z
        accepted_steps += 1
        current_loss = accepted_loss
        push!(history, accepted_loss)
        push!(state_hashes, vector_sha256(x_reference))
        collapse_gd!(x_treatment, z, problem; frame, iteration)
        require_vector(frame, "gd", iteration, 0, "accepted_state",
                       x_reference, x_treatment)
        reference_metrics = BlockA.state_metrics(
            problem, context.code, x_reference)
        treatment_metrics = BlockA.state_metrics(
            problem, context.code, x_treatment)
        require_state_metrics(frame, "gd", iteration, 0,
                              reference_metrics, treatment_metrics)
        push!(iteration_rows, (;
            frame, lane="gd", iteration, trial_count,
            accepted=true, state_sha256=vector_sha256(x_reference),
            auxiliary_sha256=edge_sha256(z),
            syndrome_weight=reference_metrics.syndrome_weight,
            status="accepted_step_" * @sprintf("%.17g", accepted_step),
            active_reads=expected_reads * (1 + trial_count)))
    end

    terminal = BlockA.state_metrics(problem, context.code, x_reference)
    require_vector(frame, "gd", accepted_steps, 0, "native_terminal_x",
                   native.oracle.x, x_reference)
    require_vector(frame, "gd", accepted_steps, 0, "controlled_terminal_x",
                   native.result.x, x_reference)
    require_vector(frame, "gd", accepted_steps, 0, "objective_history",
                   native.oracle.history, history)
    native.oracle.state_hashes == state_hashes || mismatch(
        frame, "gd", accepted_steps, 0, "state_hash_path",
        scientific_sha256(native.oracle.state_hashes), scientific_sha256(state_hashes))
    native.oracle.accepted_steps == accepted_steps || mismatch(
        frame, "gd", accepted_steps, 0, "accepted_steps",
        string(native.oracle.accepted_steps), string(accepted_steps))
    native.oracle.status == status || mismatch(
        frame, "gd", accepted_steps, 0, "stop_status",
        native.oracle.status, status)
    require_float(frame, "gd", accepted_steps, 0, "terminal_loss",
                  native.oracle.final_loss, current_loss)
    require_bool_vector(frame, "gd", accepted_steps, 0,
                        "native_hard_decision",
                        native.result.hard, terminal.hard)
    require_bool_vector(frame, "gd", accepted_steps, 0,
                        "native_syndrome",
                        native.result.syndrome, terminal.syndrome)

    (; native, problem, initial, initial_z=lift_gd(initial, problem.check_vars),
       x=copy(x_reference), z=Legacy.copy_edge_rows(z), terminal,
       history, state_hashes, accepted_steps, status, current_loss,
       iteration_rows)
end

# ---------------------------------------------------------------------------
# BP edge-value reproduction
# ---------------------------------------------------------------------------

bp_transform(q) = tanh.(0.5 .* clamp.(Float64.(q), -BlockB.LLR_CLIP, BlockB.LLR_CLIP))

function bp_transform_reference(q)
    transformed = Vector{Float64}(undef, length(q))
    @inbounds for index in eachindex(q)
        value = Float64(q[index])
        clipped = if value < -BlockB.LLR_CLIP
            -BlockB.LLR_CLIP
        elseif value > BlockB.LLR_CLIP
            BlockB.LLR_CLIP
        else
            value
        end
        transformed[index] = tanh(clipped / 2.0)
    end
    transformed
end

bp_initial_q(graph::BlockB.GraphView, llr) =
    [Float64(llr[graph.edge_variable[edge]])
     for edge in 1:BlockB.edge_count(graph)]

function bp_check_from_z(graph::BlockB.GraphView, z)
    length(z) == BlockB.edge_count(graph) ||
        throw(DimensionMismatch("BP edge-value length changed"))
    output = zeros(Float64, length(z))
    products = ones(Float64, length(z))
    edge_reads = 0
    limit = tanh(0.5 * BlockB.LLR_CLIP)
    for range in graph.check_edges
        if length(range) == 1
            output[first(range)] = BlockB.LLR_CLIP
            continue
        end
        @inbounds for target in range
            product = 1.0
            for source in range
                source == target && continue
                product *= Float64(z[source])
                edge_reads += 1
            end
            products[target] = product
            output[target] = clamp(
                2atanh(clamp(product, -limit, limit)),
                -BlockB.LLR_CLIP, BlockB.LLR_CLIP)
        end
    end
    (; output, products, edge_reads)
end

function bp_reference_products(graph::BlockB.GraphView, q)
    products = ones(Float64, BlockB.edge_count(graph))
    for range in graph.check_edges
        length(range) == 1 && continue
        @inbounds for target in range
            product = 1.0
            for source in range
                source == target && continue
                product *= tanh(0.5 * clamp(Float64(q[source]),
                    -BlockB.LLR_CLIP, BlockB.LLR_CLIP))
            end
            products[target] = product
        end
    end
    products
end

function bp_variable_from_u(graph::BlockB.GraphView, llr, u)
    length(llr) == graph.n || throw(DimensionMismatch("BP LLR length changed"))
    length(u) == BlockB.edge_count(graph) ||
        throw(DimensionMismatch("BP check-value length changed"))
    lpost = Float64.(llr)
    q = zeros(Float64, BlockB.edge_count(graph))
    for variable in 1:graph.n
        total = Float64(llr[variable])
        incident = graph.variable_edges[variable]
        @inbounds for edge in incident
            total += Float64(u[edge])
        end
        lpost[variable] = total
        @inbounds for edge in incident
            q[edge] = total - Float64(u[edge])
        end
    end
    (; lpost, q)
end

function bp_active_read_gate(graph; expected_reads::Int)
    edge_total = BlockB.edge_count(graph)
    z = [0.15 + 0.01 * mod(edge, 7) for edge in 1:edge_total]
    baseline = bp_check_from_z(graph, z)
    first_range = first(graph.check_edges)
    poisoned_edge = first(first_range)
    poisoned = copy(z)
    poisoned[poisoned_edge] += 0.125
    changed = bp_check_from_z(graph, poisoned)
    same_return_edge = float_bits_equal(
        baseline.output[poisoned_edge], changed.output[poisoned_edge])
    other_first_outputs_changed = all(
        !float_bits_equal(baseline.output[edge], changed.output[edge])
        for edge in first_range if edge != poisoned_edge)
    later_outputs_unchanged = all(
        float_bits_equal(baseline.output[edge], changed.output[edge])
        for edge in (last(first_range) + 1):edge_total)
    checks = Dict(
        "registered_read_count" => baseline.edge_reads == expected_reads,
        "return_edge_excludes_poison" => same_return_edge,
        "other_outputs_read_poison" => other_first_outputs_changed,
        "other_checks_unchanged" => later_outputs_unchanged,
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "edge_reads" => baseline.edge_reads)
end

function run_bp_pair(context, llr, frame::Int, config; native=nothing)
    graph = context.graph
    native === nothing &&
        (native = BlockB.native_decode(context.bp_modem, context.bp_code, llr))
    direct = Composition.run_exact_direct_endpoint_oracle(
        graph, llr; fixed_attempts=30,
        endpoint_attempts=Int(config["bp"]["maximum_message_passing_iterations"]),
        frame, stage="common_coordinate")
    endpoint_gate = Composition.native_bp_endpoint_gate(
        graph, direct.endpoint, native)
    Bool(endpoint_gate["passed"]) || mismatch(
        frame, "bp", 0, 0, "native_endpoint_gate", "true", "false")

    edge_total = BlockB.edge_count(graph)
    u_reference = zeros(Float64, edge_total)
    u_treatment = zeros(Float64, edge_total)
    q_reference = bp_initial_q(graph, llr)
    q_treatment = copy(q_reference)
    z = bp_transform(q_treatment)
    require_vector(frame, "bp", 0, 0, "initial_transformed_state",
                   bp_transform_reference(q_reference), z)
    iteration_rows = NamedTuple[]
    reference_first_valid = 0
    treatment_first_valid = 0
    expected_reads = Int(config["bp"]["edge_reads_per_check_phase"])
    terminal_lpost = Float64.(llr)
    terminal_hard = BitVector(terminal_lpost .< 0.0)
    terminal_syndrome = BlockB.syndrome_vector(graph, terminal_hard)

    for iteration in 1:Int(config["bp"]["maximum_message_passing_iterations"])
        require_vector(frame, "bp", iteration, 0, "current_q",
                       q_reference, q_treatment)
        expected_z = bp_transform_reference(q_reference)
        require_vector(frame, "bp", iteration, 0, "transformed_check_input",
                       expected_z, z)
        require_vector(frame, "bp", iteration, 0, "production_transform",
                       expected_z, bp_transform(q_treatment))

        reference_output = zeros(Float64, edge_total)
        for range in graph.check_edges
            BlockB.CORE._bp_check_sum_product!(
                view(reference_output, range), view(q_reference, range))
        end
        treatment = bp_check_from_z(graph, z)
        treatment.edge_reads == expected_reads || mismatch(
            frame, "bp", iteration, 0, "active_edge_reads",
            string(expected_reads), string(treatment.edge_reads))
        reference_products = bp_reference_products(graph, q_reference)
        require_vector(frame, "bp", iteration, 0, "temporary_products",
                       reference_products, treatment.products)
        require_vector(frame, "bp", iteration, 0, "check_to_variable",
                       reference_output, treatment.output)
        u_reference = copy(reference_output)
        u_treatment = copy(treatment.output)

        reference_values = BlockB.variable_values(
            graph, llr, u_reference, :full)
        treatment_values = bp_variable_from_u(graph, llr, u_treatment)
        require_vector(frame, "bp", iteration, 0, "posterior_llr",
                       reference_values.lpost, treatment_values.lpost)
        require_vector(frame, "bp", iteration, 0, "new_variable_to_check",
                       reference_values.q_used, treatment_values.q)
        q_reference = copy(reference_values.q_used)
        q_treatment = copy(treatment_values.q)
        z = bp_transform(q_treatment)
        require_vector(frame, "bp", iteration, 0, "next_transformed_state",
                       bp_transform_reference(q_reference), z)

        reference_hard = BitVector(reference_values.lpost .< 0.0)
        treatment_hard = BitVector(treatment_values.lpost .< 0.0)
        reference_syndrome = BlockB.syndrome_vector(graph, reference_hard)
        treatment_syndrome = BlockB.syndrome_vector(graph, treatment_hard)
        require_bool_vector(frame, "bp", iteration, 0, "hard_decision",
                            reference_hard, treatment_hard)
        require_bool_vector(frame, "bp", iteration, 0, "syndrome",
                            reference_syndrome, treatment_syndrome)
        reference_weight = count(reference_syndrome)
        treatment_weight = count(treatment_syndrome)
        require_scalar_value(frame, "bp", iteration, 0, "syndrome_weight",
                             reference_weight, treatment_weight)
        reference_valid = reference_weight == 0
        treatment_valid = treatment_weight == 0
        require_scalar_value(frame, "bp", iteration, 0, "stopping_decision",
                             reference_valid, treatment_valid)
        reference_first_valid == 0 && reference_valid &&
            (reference_first_valid = iteration)
        treatment_first_valid == 0 && treatment_valid &&
            (treatment_first_valid = iteration)
        require_scalar_value(frame, "bp", iteration, 0, "first_valid_iteration",
                             reference_first_valid, treatment_first_valid)

        direct_row = direct.endpoint.iteration_rows[iteration]
        require_scalar_value(frame, "bp", iteration, 0,
                             "direct_syndrome_weight",
                             direct_row.syndrome_weight, reference_weight)
        require_scalar_value(frame, "bp", iteration, 0,
                             "direct_parity_valid",
                             direct_row.parity_valid, reference_valid)
        require_scalar_value(frame, "bp", iteration, 0,
                             "direct_hard_word_sha256",
                             direct_row.hard_word_sha256,
                             vector_sha256(reference_hard))

        terminal_lpost = copy(treatment_values.lpost)
        terminal_hard = treatment_hard
        terminal_syndrome = treatment_syndrome
        syndrome_weight = treatment_weight
        push!(iteration_rows, (;
            frame, lane="bp", iteration, trial_count=1,
            accepted=true, state_sha256=vector_sha256(q_treatment),
            auxiliary_sha256=scientific_sha256(Dict(
                "u" => vector_sha256(u_treatment),
                "z" => vector_sha256(z),
                "posterior" => vector_sha256(terminal_lpost))),
            syndrome_weight,
            status=syndrome_weight == 0 ? "first_zero_syndrome" : "continue",
            active_reads=treatment.edge_reads))
        if reference_valid
            break
        end
    end

    require_scalar_value(frame, "bp", reference_first_valid, 0,
                         "terminal_first_valid_iteration",
                         reference_first_valid, treatment_first_valid)
    first_valid = reference_first_valid

    native_q = BlockB.flatten_rows(native.q)
    native_u = BlockB.flatten_rows(native.u)
    require_vector(frame, "bp", first_valid, 0, "native_terminal_q",
                   native_q, q_treatment)
    require_vector(frame, "bp", first_valid, 0, "native_terminal_u",
                   native_u, u_treatment)
    require_vector(frame, "bp", first_valid, 0, "native_posterior_metric",
                   native.lpost_metric, -terminal_lpost)
    require_bool_vector(frame, "bp", first_valid, 0,
                        "native_hard_decision", native.hard, terminal_hard)
    native_syndrome = BlockB.syndrome_vector(graph, native.hard)
    require_bool_vector(frame, "bp", first_valid, 0,
                        "native_syndrome", native_syndrome, terminal_syndrome)
    native.syndrome_weight == count(terminal_syndrome) || mismatch(
        frame, "bp", first_valid, 0, "syndrome_weight",
        string(native.syndrome_weight), string(count(terminal_syndrome)))
    native.iterations == length(iteration_rows) || mismatch(
        frame, "bp", first_valid, 0, "stop_iteration",
        string(native.iterations), string(length(iteration_rows)))

    (; native, direct, endpoint_gate,
       initial_q=bp_initial_q(graph, llr),
       initial_z=bp_transform_reference(bp_initial_q(graph, llr)),
       q=q_treatment, u=u_treatment, z,
       lpost=terminal_lpost, hard=terminal_hard,
       syndrome=terminal_syndrome, first_valid,
       iteration_rows)
end

# ---------------------------------------------------------------------------
# Retained oracle, passes, and durable output
# ---------------------------------------------------------------------------

parse_bool(value) = lowercase(String(value)) == "true"

function retained_oracle_rows()
    selected = Dict{Tuple{Int,String},Any}()
    for row in Legacy.parse_simple_csv(joinpath(ORACLE_RESULT, "frames.csv"))
        row.rung_id in ("native_projected_gd", "native_exact_sum_product") || continue
        selected[(parse(Int, row.frame), row.rung_id)] = row
    end
    expected = Set((frame, rung)
        for frame in 20001:20024
        for rung in ("native_projected_gd", "native_exact_sum_product"))
    observed = Set(keys(selected))
    observed == expected || mismatch(
        0, "retained", 0, 0, "endpoint_key_set",
        scientific_sha256(sort!(collect(expected))),
        scientific_sha256(sort!(collect(observed))))
    selected
end

function compare_retained_rung(frame, rung, row, input)
    comparisons = Dict(
        "llr_sha256" => (row.llr_sha256, input.llr_sha256),
        "received_sha256" => (row.received_sha256, input.received_sha256),
        "state_sha256" => (row.state_sha256, rung.state_sha256),
        "hard_word_sha256" => (row.hard_word_sha256, rung.hard_word_sha256),
        "updates" => (parse(Int, row.updates), rung.updates),
        "status" => (row.status, rung.status),
        "coded_bit_errors" =>
            (parse(Int, row.coded_bit_errors), rung.coded_bit_errors),
        "syndrome_weight" =>
            (parse(Int, row.syndrome_weight), rung.syndrome_weight),
        "parity_valid" => (parse_bool(row.parity_valid), rung.parity_valid),
        "transmitted_word_equal" => (parse_bool(row.transmitted_word_equal),
                                      rung.transmitted_word_equal),
    )
    checks = Dict{String,Bool}()
    for field in sort(collect(keys(comparisons)))
        expected, observed = comparisons[field]
        checks[field] = expected == observed
        checks[field] || mismatch(
            frame, "retained_$(rung.id)", 0, 0, field,
            string(expected), string(observed))
    end
    checks
end

function compare_frame(context, config, oracle_rows, frame::Int)
    input = Composition.generate_input(context, frame, "six_db")
    legacy_input = Legacy.generate_input(
        context.split, context.native, context.code, frame)
    input_gate = input_identity_gate(
        context, config, frame, input, legacy_input)

    # Follow the registered per-frame order: native GD then its coordinate
    # treatment, followed by native BP then its coordinate treatment.
    native_gd = Composition.native_gd_and_oracle(context, input.llr)
    Bool(native_gd.gate["passed"]) || mismatch(
        frame, "native_gd", 0, 0, "native_oracle_gate", "true", "false")
    Bool(native_gd.shadow_gate["passed"]) || mismatch(
        frame, "native_gd", 0, 0, "shadow_oracle_gate", "true", "false")
    gd_rung = Composition.rung_from_scalar(
        "native_projected_gd", native_gd.result; backend="native_gd")
    gd_retained = compare_retained_rung(
        frame, gd_rung, oracle_rows[(frame, "native_projected_gd")], input)
    gd = run_gd_pair(context, input.llr, frame, config; native=native_gd)

    native_bp = BlockB.native_decode(
        context.bp_modem, context.bp_code, input.llr)
    bp_rung = Composition.rung_from_native_bp(native_bp)
    bp_retained = compare_retained_rung(
        frame, bp_rung, oracle_rows[(frame, "native_exact_sum_product")], input)
    bp = run_bp_pair(context, input.llr, frame, config; native=native_bp)
    initial_gd_flat = Legacy.flatten_edge_rows(gd.initial_z)
    require_vector(frame, "interface", 0, 0, "initial_edge_values",
                   initial_gd_flat, bp.initial_z)

    identity_payload = Dict{String,Any}(
        String(key) => value
        for (key, value) in pairs(input_gate["identities"]))
    identity_payload["noise_seed"] = input_gate["noise_seed"]
    row = (;
        frame, channel="six_db", snr_db=input.snr_db, noise_seed=input.seed,
        input_identity_sha256=scientific_sha256(identity_payload),
        llr_sha256=input.llr_sha256,
        received_sha256=input.received_sha256,
        initial_edge_values_sha256=vector_sha256(bp.initial_z),
        gd_terminal_scalar_sha256=vector_sha256(gd.x),
        gd_terminal_edge_sha256=edge_sha256(gd.z),
        gd_trace_sha256=scientific_sha256(gd.iteration_rows),
        gd_accepted_steps=gd.accepted_steps,
        gd_status=gd.status,
        gd_syndrome_weight=gd.terminal.syndrome_weight,
        gd_transmitted_word_equal=gd.terminal.transmitted_word_equal,
        bp_terminal_q_sha256=vector_sha256(bp.q),
        bp_terminal_u_sha256=vector_sha256(bp.u),
        bp_terminal_z_sha256=vector_sha256(bp.z),
        bp_trace_sha256=scientific_sha256(bp.iteration_rows),
        bp_iterations=length(bp.iteration_rows),
        bp_syndrome_weight=count(bp.syndrome),
        bp_transmitted_word_equal=!any(bp.hard),
        retained_gd_oracle_passed=all(values(gd_retained)),
        retained_bp_oracle_passed=all(values(bp_retained)),
        input_identity_passed=Bool(input_gate["passed"]),
        exact_trajectory_passed=true)
    (; row, iterations=vcat(gd.iteration_rows, bp.iteration_rows),
       identity_payload)
end

function write_progress(path, pass_name, phase, completed, total;
                        previous_seconds=0.0, status="running")
    payload = Dict(
        "schema_version" => PROGRESS_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "status" => status,
        "pass" => pass_name,
        "phase" => phase,
        "completed_frames" => completed,
        "total_frames" => total,
        "previous_phase_seconds" => previous_seconds,
        "updated_utc" => string(now(UTC)),
    )
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, payload; sorted=true)
        write(io, '\n')
    end
    mv(temporary, path; force=true)
end

function log_phase(path, pass_name, phase, event, seconds)
    new_file = !isfile(path)
    open(path, "a") do io
        new_file && println(io, "utc\tpass\tphase\tevent\tseconds")
        println(io, string(now(UTC)), '\t', pass_name, '\t', phase, '\t',
                event, '\t', @sprintf("%.6f", seconds))
    end
end

function run_pass(config, oracle_rows, pass_name, progress_path, phase_log_path)
    frames = (Int(config["protocol"]["frame_first"]):
              Int(config["protocol"]["frame_last"]))
    total_started = time_ns()
    phase_started = time_ns()
    write_progress(progress_path, pass_name, "context", 0, length(frames))
    log_phase(phase_log_path, pass_name, "context", "start", 0.0)
    composition_config = Composition.load_config(COMPOSITION_CONFIG)
    context = Composition.backend_context(composition_config, COMPOSITION_CONFIG)
    graph_gate = graph_identity_gate(context, config)
    context_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "context", "end", context_seconds)

    synthetic_problem = BlockA.BridgeProblem(
        context.code, zeros(Float64, context.code.n);
        parity_weight=Float64(config["gd"]["parity_weight"]),
        binary_weight=Float64(config["gd"]["binary_weight"]))
    synthetic_x = [0.2sin(0.017bit) + 0.1cos(0.031bit)
                   for bit in 1:context.code.n]
    gd_active = gd_active_read_gate(
        synthetic_problem, synthetic_x;
        expected_reads=Int(config["gd"]["edge_reads_per_objective_evaluation"]))
    bp_active = bp_active_read_gate(
        context.graph;
        expected_reads=Int(config["bp"]["edge_reads_per_check_phase"]))
    Bool(gd_active["passed"]) || mismatch(
        0, "gd", 0, 0, "active_read_poison_gate", "true", "false")
    Bool(bp_active["passed"]) || mismatch(
        0, "bp", 0, 0, "active_read_poison_gate", "true", "false")

    phase_started = time_ns()
    write_progress(progress_path, pass_name, "frames", 0, length(frames);
                   previous_seconds=context_seconds)
    log_phase(phase_log_path, pass_name, "frames", "start", 0.0)
    rows = NamedTuple[]
    iterations = NamedTuple[]
    identities = Dict{String,Any}[]
    for (index, frame) in enumerate(frames)
        result = compare_frame(context, config, oracle_rows, frame)
        push!(rows, result.row)
        append!(iterations, result.iterations)
        push!(identities, Dict(
            "frame" => frame,
            "identities" => result.identity_payload,
        ))
        write_progress(progress_path, pass_name, "frames", index, length(frames))
    end
    frame_seconds = (time_ns() - phase_started) / 1.0e9
    log_phase(phase_log_path, pass_name, "frames", "end", frame_seconds)
    expected_frames = collect(frames)
    observed_frames = [row.frame for row in rows]
    observed_identity_frames = [Int(item["frame"]) for item in identities]
    observed_frames == expected_frames || mismatch(
        0, "evidence", 0, 0, "evaluated_frame_ids",
        scientific_sha256(expected_frames), scientific_sha256(observed_frames))
    observed_identity_frames == expected_frames || mismatch(
        0, "evidence", 0, 0, "identity_frame_ids",
        scientific_sha256(expected_frames),
        scientific_sha256(observed_identity_frames))
    length(rows) == Int(config["protocol"]["case_count"]) || mismatch(
        0, "evidence", 0, 0, "case_count",
        string(config["protocol"]["case_count"]), string(length(rows)))
    science = Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "classification" => config["classification"],
        "frame_first" => first(frames),
        "frame_last" => last(frames),
        "frame_count" => length(frames),
        "frames" => rows,
        "iterations" => iterations,
        "input_identities" => identities,
        "graph_identity_gate" => graph_gate,
        "gd_active_read_gate" => gd_active,
        "bp_active_read_gate" => bp_active,
        "all_exact_reproduction_gates_passed" => true,
        "no_frame_outside_retained_set_evaluated" =>
            observed_frames == expected_frames,
        "performance_inference_allowed" => false,
    )
    (; science, rows, iterations,
       seconds=(time_ns() - total_started) / 1.0e9)
end

function write_json(path, value)
    open(path, "w") do io
        write(io, Composition.canonical_json(value))
        write(io, '\n')
    end
end

function write_toml(path, value)
    open(path, "w") do io
        TOML.print(io, value; sorted=true)
        write(io, '\n')
    end
end

function write_csv(path, rows)
    if isempty(rows)
        open(path, "w") do _ end
    else
        Composition.write_csv(path, rows, collect(keys(first(rows))))
    end
end

function write_manifest(output)
    files = String[]
    for (root, _, names) in walkdir(output)
        for name in names
            path = joinpath(root, name)
            relative = relpath(path, output)
            relative == "MANIFEST.sha256" && continue
            push!(files, relative)
        end
    end
    sort!(files)
    open(joinpath(output, "MANIFEST.sha256"), "w") do io
        for relative in files
            println(io, file_sha256(joinpath(output, relative)), "  ", relative)
        end
    end
end

function failure_payload(error)
    payload = Dict{String,Any}(
        "schema_version" => "rq2-common-coordinate-repro-001/failure-v1",
        "experiment_id" => EXPERIMENT_ID,
        "status" => "complete_invalid",
        "error_type" => string(typeof(error)),
        "error" => sprint(showerror, error),
        "failed_utc" => string(now(UTC)),
    )
    if error isa GateMismatch
        payload["frame"] = error.frame
        payload["lane"] = error.lane
        payload["iteration"] = error.iteration
        payload["trial"] = error.trial
        payload["field"] = error.field
        payload["index"] = error.index
        payload["reference"] = error.reference
        payload["reproduced"] = error.reproduced
    end
    payload
end

function run_gate(; config_path::AbstractString=joinpath(HERE, "config.toml"),
                  output::AbstractString)
    ispath(output) && throw(ArgumentError("refusing to overwrite result $output"))
    mkpath(output)
    progress_path = joinpath(output, "progress.toml")
    phase_log_path = joinpath(output, "phase_log.tsv")
    total_started = time_ns()
    try
        config = load_config(config_path)
        threads = thread_environment_gate(config)
        sources = source_gate(config; require_study_freeze=true)
        oracle_rows = retained_oracle_rows()
        primary = run_pass(config, oracle_rows, "primary",
                           progress_path, phase_log_path)

        checkpoint = joinpath(output, "primary_checkpoint")
        mkpath(checkpoint)
        write_json(joinpath(checkpoint, "science.json"), primary.science)
        write_csv(joinpath(checkpoint, "frames.csv"), primary.rows)
        write_csv(joinpath(checkpoint, "iterations.csv"), primary.iterations)
        write_toml(joinpath(checkpoint, "checkpoint.toml"), Dict(
            "schema_version" =>
                "rq2-common-coordinate-repro-001/primary-checkpoint-v1",
            "experiment_id" => EXPERIMENT_ID,
            "status" => "primary_complete",
            "science_sha256" => scientific_sha256(primary.science),
            "frames_sha256" => scientific_sha256(primary.rows),
            "iterations_sha256" => scientific_sha256(primary.iterations),
            "frame_count" => length(primary.rows),
        ))
        write_manifest(checkpoint)
        write_progress(progress_path, "primary", "primary_checkpoint", 24, 24)

        replay = run_pass(config, oracle_rows, "replay",
                          progress_path, phase_log_path)
        primary_science_hash = scientific_sha256(primary.science)
        replay_science_hash = scientific_sha256(replay.science)
        primary_frames_hash = scientific_sha256(primary.rows)
        replay_frames_hash = scientific_sha256(replay.rows)
        primary_iterations_hash = scientific_sha256(primary.iterations)
        replay_iterations_hash = scientific_sha256(replay.iterations)
        primary_science_hash == replay_science_hash || mismatch(
            0, "replay", 0, 0, "science_sha256",
            primary_science_hash, replay_science_hash)
        primary_frames_hash == replay_frames_hash || mismatch(
            0, "replay", 0, 0, "frames_sha256",
            primary_frames_hash, replay_frames_hash)
        primary_iterations_hash == replay_iterations_hash || mismatch(
            0, "replay", 0, 0, "iterations_sha256",
            primary_iterations_hash, replay_iterations_hash)

        write_json(joinpath(output, "science.json"), primary.science)
        write_csv(joinpath(output, "frames.csv"), primary.rows)
        write_csv(joinpath(output, "iterations.csv"), primary.iterations)
        gate = Dict(
            "schema_version" => GATE_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "status" => "pass",
            "correctness_passed" => true,
            "deterministic_replay_passed" => true,
            "retained_oracle_passed" => true,
            "gd_active_edge_read_passed" => true,
            "bp_active_edge_read_passed" => true,
            "frame_count" => length(primary.rows),
            "primary_science_sha256" => primary_science_hash,
            "replay_science_sha256" => replay_science_hash,
            "primary_frames_sha256" => primary_frames_hash,
            "replay_frames_sha256" => replay_frames_hash,
            "primary_iterations_sha256" => primary_iterations_hash,
            "replay_iterations_sha256" => replay_iterations_hash,
            "source_gate_sha256" => scientific_sha256(sources),
            "thread_environment_sha256" => scientific_sha256(threads),
            "performance_inference_allowed" => false,
        )
        write_toml(joinpath(output, "job_gate.toml"), gate)
        completion = Dict(
            "schema_version" => COMPLETION_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "status" => "complete_valid",
            "science_sha256" => primary_science_hash,
            "config_sha256" => file_sha256(config_path),
            "primary_seconds" => primary.seconds,
            "replay_seconds" => replay.seconds,
            "total_seconds" => (time_ns() - total_started) / 1.0e9,
            "completed_utc" => string(now(UTC)),
            "performance_inference_allowed" => false,
        )
        write_toml(joinpath(output, "COMPLETED.toml"), completion)
        write_progress(progress_path, "replay", "write_result", 24, 24;
                       status="complete_valid")
        write_manifest(output)
        println("complete_valid science_sha256=$primary_science_hash")
        return (; completion, output=abspath(output))
    catch error
        failure = failure_payload(error)
        write_toml(joinpath(output, "FAILURE.toml"), failure)
        write_toml(joinpath(output, "COMPLETED.toml"), Dict(
            "schema_version" => COMPLETION_SCHEMA,
            "experiment_id" => EXPERIMENT_ID,
            "status" => "complete_invalid",
            "failure_sha256" => scientific_sha256(failure),
            "total_seconds" => (time_ns() - total_started) / 1.0e9,
            "completed_utc" => string(now(UTC)),
            "performance_inference_allowed" => false,
        ))
        write_progress(progress_path, "unknown", "failed", 0, 24;
                       status="complete_invalid")
        write_manifest(output)
        rethrow()
    end
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
    isempty(arguments) && throw(ArgumentError(
        "usage: rq2_common_coordinate_repro_001.jl run --config PATH --output DIR"))
    arguments[1] == "run" ||
        throw(ArgumentError("only the run command is supported"))
    options = parse_options(arguments[2:end])
    haskey(options, "config") || throw(ArgumentError("--config is required"))
    haskey(options, "output") || throw(ArgumentError("--output is required"))
    run_gate(config_path=options["config"], output=options["output"])
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
