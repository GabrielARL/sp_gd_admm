#!/usr/bin/env julia

using Dates
using LinearAlgebra
using Printf
using SHA
using TOML

const SCRIPT_PATH = abspath(@__FILE__)

function parse_args(args)
    values = Dict{String,String}()
    index = 1
    while index <= length(args)
        startswith(args[index], "--") || error("unexpected argument: $(args[index])")
        index == length(args) && error("$(args[index]) requires a value")
        values[args[index]] = args[index + 1]
        index += 2
    end
    values
end

function required(values, name)
    haskey(values, name) || error("$name is required")
    values[name]
end

function parse_frames(specification::AbstractString)
    fields = split(specification, ':')
    length(fields) == 2 || error("frame range must be FIRST:LAST")
    first_frame, last_frame = parse.(Int, fields)
    first_frame <= last_frame || error("frame range is reversed")
    collect(first_frame:last_frame)
end

const OPTIONS = parse_args(ARGS)
const REPO = abspath(required(OPTIONS, "--repo"))
const PHASE = Symbol(get(OPTIONS, "--phase", "heldout"))
const FRAME_SPEC = required(OPTIONS, "--frames")
const FRAMES = parse_frames(FRAME_SPEC)
const PASSES = parse(Int, get(OPTIONS, "--passes", "2"))
const OUTPUT = abspath(required(OPTIONS, "--output"))
const FREEZE = abspath(get(OPTIONS, "--freeze",
    joinpath(REPO, "experiments", "rq2_qbar_awgn_001", "freeze", "2026-10-28_v2")))
const ANCHOR = abspath(get(OPTIONS, "--anchor",
    joinpath(REPO, "experiments", "rq2_qbar_awgn_001", "results", "2026-10-28_anchor_v2")))
const ORIGINAL_RUNNER = joinpath(REPO, "experiments", "rq2_qbar_awgn_001",
                                 "rq2_qbar_awgn_001.jl")
const GZIP_EXE = get(OPTIONS, "--gzip", raw"C:\Program Files\Git\usr\bin\gzip.exe")

PHASE in (:anchor, :heldout) || error("phase must be anchor or heldout")
PASSES in (1, 2) || error("passes must be 1 or 2")
isfile(ORIGINAL_RUNNER) || error("original runner not found: $ORIGINAL_RUNNER")

include(ORIGINAL_RUNNER)
const R = RQ2QbarAWGN001
const AWGN = R.AWGN

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
text_sha256(value::AbstractString) = bytes2hex(sha256(codeunits(value)))

function normalized_source_hashes(config)
    observed = R.source_hashes(config)
    Dict(replace(String(name), '\\' => "__") => String(value)
         for (name, value) in observed)
end

function actual_files(root)
    result = Set{String}()
    for (directory, _, files) in walkdir(root), file in files
        relative = relpath(joinpath(directory, file), root)
        normalized = replace(relative, '\\' => '/')
        normalized == "MANIFEST.sha256" && continue
        push!(result, normalized)
    end
    result
end

function portable_checksum_gate(root)
    manifest_path = joinpath(root, "MANIFEST.sha256")
    isfile(manifest_path) || return Dict("passed" => false,
        "reason" => "missing MANIFEST.sha256")
    checks = Dict{String,Bool}()
    listed = Set{String}()
    for line in readlines(manifest_path)
        isempty(strip(line)) && continue
        fields = split(line; limit=2)
        length(fields) == 2 || return Dict("passed" => false,
            "reason" => "malformed checksum line")
        expected = String(fields[1])
        relative = replace(strip(String(fields[2])), '\\' => '/')
        safe = !isempty(relative) && !startswith(relative, "/") &&
               !occursin(r"(^|/)\.\.(/|$)", relative) &&
               !(relative in listed)
        safe || return Dict("passed" => false,
            "reason" => "unsafe or duplicate checksum path: $relative")
        target = joinpath(root, split(relative, '/')...)
        push!(listed, relative)
        checks[relative] = isfile(target) && !islink(target) &&
                           file_sha256(target) == expected
    end
    actual = actual_files(root)
    symlink_free = all(!islink(joinpath(directory, name))
        for (directory, subdirectories, files) in walkdir(root)
        for name in vcat(subdirectories, files))
    Dict(
        "passed" => !isempty(checks) && all(values(checks)) &&
                    listed == actual && symlink_free,
        "checks" => checks,
        "exact_file_set" => listed == actual,
        "symlink_free" => symlink_free,
        "listed_count" => length(listed),
        "actual_count" => length(actual),
    )
end

function portable_freeze_gate(config, code)
    checksum = portable_checksum_gate(FREEZE)
    manifest_path = joinpath(FREEZE, "freeze_manifest.toml")
    input_path = joinpath(FREEZE, "input_freeze.csv")
    manifest = TOML.parsefile(manifest_path)
    current = normalized_source_hashes(config)
    frozen = Dict(String(key) => String(value)
                  for (key, value) in manifest["source_hashes"])
    source_checks = Dict(name => get(current, name, "missing") == hash
                         for (name, hash) in frozen)
    archived = Dict(String(key) => String(value)
                    for (key, value) in manifest["archived_source_hashes"])
    archived_checks = Dict(name => begin
        path = joinpath(FREEZE, "source", name)
        isfile(path) && file_sha256(path) == hash
    end for (name, hash) in archived)
    regenerated = R.generate_input_records(config, code)
    temporary, io = mktemp()
    close(io)
    rm(temporary)
    R.write_csv(temporary, regenerated)
    regenerated_hash = file_sha256(temporary)
    rm(temporary)
    checks = Dict(
        "portable_checksum_manifest" => Bool(checksum["passed"]),
        "source_hashes" => all(values(source_checks)),
        "source_key_set" => Set(keys(current)) == Set(keys(frozen)),
        "archived_source_hashes" => all(values(archived_checks)),
        "archive_key_set" => Set(keys(archived)) == Set(keys(frozen)),
        "input_table_hash" => file_sha256(input_path) ==
                              String(manifest["input_table_sha256"]),
        "input_regeneration" => regenerated_hash ==
                                String(manifest["input_table_sha256"]),
        "graph_hash" => AWGN.graph_sha256(code) == String(manifest["graph_sha256"]),
        "heldout_not_executed_at_freeze" => manifest["heldout_decoders_executed"] == false,
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "portable_checksum_gate" => checksum,
        "source_checks" => source_checks,
        "archived_source_checks" => archived_checks,
        "input_table_sha256" => file_sha256(input_path),
        "regenerated_table_sha256" => regenerated_hash,
        "freeze_manifest_sha256" => file_sha256(manifest_path),
    )
end

function source_gate_parallel(config, freeze_gate)
    jade = config["jade"]
    checks = Dict(
        "frozen_source_hashes" => Bool(freeze_gate["checks"]["source_hashes"]),
        "jade_head" => R.git_output(String(jade["repo"]), "rev-parse", "HEAD") ==
                       String(jade["expected_head"]),
        "active_project" => realpath(Base.active_project()) ==
                            realpath(String(jade["project_toml"])),
        "julia_version" => string(VERSION) == String(config["validation"]["expected_julia_version"]),
        "blas_threads" => BLAS.get_num_threads() == 1,
        "parallel_worker_threads" => Threads.nthreads() >= 2,
    )
    Dict(
        "passed" => all(values(checks)),
        "checks" => checks,
        "julia_threads" => Threads.nthreads(),
        "original_registered_julia_threads" => Int(config["validation"]["julia_threads"]),
        "execution_deviation" =>
            "independent frames execute concurrently; each frame retains the original decoder calculation and one BLAS thread",
    )
end

function anchor_static_gate()
    checksum = portable_checksum_gate(ANCHOR)
    manifest = TOML.parsefile(joinpath(ANCHOR, "manifest.toml"))
    completion = TOML.parsefile(joinpath(ANCHOR, "COMPLETED.toml"))
    checks = Dict(
        "checksum" => Bool(checksum["passed"]),
        "phase" => manifest["phase"] == "anchor" && completion["phase"] == "anchor",
        "status" => manifest["status"] == "valid" && completion["status"] == "valid",
        "validation" => manifest["validation_passed"] && completion["validation_passed"],
        "expansion" => manifest["anchor_expansion_passed"] &&
                       completion["anchor_expansion_passed"],
        "deterministic_replay" => manifest["deterministic_replay_passed"],
        "freeze_binding" => manifest["freeze_manifest_sha256"] ==
                            file_sha256(joinpath(FREEZE, "freeze_manifest.toml")),
        "input_binding" => manifest["input_freeze_sha256"] ==
                           file_sha256(joinpath(FREEZE, "input_freeze.csv")),
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "checksum_gate" => checksum,
         "completion_sha256" => file_sha256(joinpath(ANCHOR, "COMPLETED.toml")))
end

function progress_printer(label, total)
    completed = Threads.Atomic{Int}(0)
    lock = ReentrantLock()
    function mark(frame)
        count = Threads.atomic_add!(completed, 1) + 1
        if count == total || count == 1 || count % max(1, min(10, total)) == 0
            Base.lock(lock) do
                println(stderr, Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"),
                    " ", label, " ", count, "/", total, " frame=", frame)
                flush(stderr)
            end
        end
    end
    mark
end

function make_contexts()
    # Julia 1.12 may reserve thread 1 for the interactive pool, so worker
    # thread IDs can extend through maxthreadid() even when nthreads() reports
    # only the default-pool size.
    contexts = Vector{Any}(undef, Threads.maxthreadid())
    for index in eachindex(contexts)
        modem, code = AWGN.code_and_graph()
        contexts[index] = (; modem, code, graph=R.graph_view(code))
    end
    contexts
end

function parallel_preflight(config, contexts, frames; label)
    maximum_iterations = Int(config["decoder"]["maximum_message_passing_iterations"])
    results = Vector{Any}(undef, length(frames))
    mark = progress_printer(label, length(frames))
    Threads.@threads :static for index in eachindex(frames)
        frame = frames[index]
        context = contexts[Threads.threadid()]
        input = AWGN.paired_frame(context.code, frame;
            esn0_db=Float64(config["channel"]["physical_esn0_db"]))
        full = R.instrumented_decode(context.graph, input.llr; mode=:full,
            maximum_iterations, stop_on_valid=true,
            capture_snapshots=false, record_trace=false)
        native = R.native_decode(context.modem, context.code, input.llr)
        results[index] = R.endpoint_equivalence(full, native)
        mark(frame)
    end
    checks = Dict(@sprintf("frame_%05d", frames[index]) => results[index]
                  for index in eachindex(frames))
    Dict(
        "passed" => all(Bool(result["passed"]) for result in results),
        "phase" => String(PHASE),
        "frame_count" => length(frames),
        "bitwise_required" => true,
        "frames" => checks,
    )
end

function compute_one_frame(config, context, frozen, frame, capture)
    maximum_iterations = Int(config["decoder"]["maximum_message_passing_iterations"])
    split_name = String(PHASE)
    input = AWGN.paired_frame(context.code, frame;
        esn0_db=Float64(config["channel"]["physical_esn0_db"]))
    record = R.input_record(config, context.code, frame, split_name)
    frozen_key = (split_name, frame)
    input_gate = haskey(frozen, frozen_key) ?
        R.frozen_input_gate(record, frozen[frozen_key]) :
        Dict("passed" => false, "reason" => "frozen input key missing")

    full = R.instrumented_decode(context.graph, input.llr; mode=:full,
        maximum_iterations, stop_on_valid=true,
        capture_snapshots=capture, record_trace=true)
    tied = R.instrumented_decode(context.graph, input.llr; mode=:tied,
        maximum_iterations, stop_on_valid=true,
        capture_snapshots=capture, record_trace=true)
    native = R.native_decode(context.modem, context.code, input.llr)
    native_gate = R.endpoint_equivalence(full, native)
    iteration_one = R.first_iteration_gate(full, tied)
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
        timed[mode] = R.timed_kernel(context.graph, input.llr, mode, maximum_iterations)
    end
    timing_gate = Dict(
        "passed" => R.timed_matches_trace(timed[:full].result, full) &&
                    R.timed_matches_trace(timed[:tied].result, tied),
        "full_matches_trace" => R.timed_matches_trace(timed[:full].result, full),
        "tied_matches_trace" => R.timed_matches_trace(timed[:tied].result, tied),
    )

    frame_rows = [
        R.arm_summary(frame, "full", full, input.word,
                      findfirst(==(:full), order), record),
        R.arm_summary(frame, "tied", tied, input.word,
                      findfirst(==(:tied), order), record),
    ]
    iteration_rows = vcat(
        R.iteration_rows(frame, "full", full.trace),
        R.iteration_rows(frame, "tied", tied.trace),
    )
    runtime_rows = NamedTuple[]
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
            native_validation_seconds=mode === :full ? native.seconds : 0.0,
            native_validation_allocated_bytes=
                mode === :full ? native.allocated_bytes : 0,
        ))
    end
    gates = Dict(
        "input_freeze" => input_gate,
        "native_full_state_equivalence" => native_gate,
        "iteration_one" => iteration_one,
        "independent_syndrome" => syndrome_gate,
        "physical_state_storage" => physical_gate,
        "diagnostic_invariants" => diagnostic_gate,
        "timed_kernel_matches_trace" => timing_gate,
    )
    snapshots = capture ? Dict("full" => full.snapshots, "tied" => tied.snapshots) :
                          Dict{String,Any}()
    (; frame_rows, iteration_rows, runtime_rows, gates, snapshots)
end

function snapshot_fingerprint(snapshots)
    fingerprint = Dict{String,Any}()
    for arm in sort!(collect(keys(snapshots)))
        arm_rows = Dict{String,Any}()
        for iteration in sort!(collect(keys(snapshots[arm])))
            snapshot = snapshots[arm][iteration]
            arm_rows[string(iteration)] = Dict(
                "q" => R.rows_sha256(snapshot.q),
                "u" => R.rows_sha256(snapshot.u),
                "qstar" => R.rows_sha256(snapshot.qstar),
                "qbar" => R.vector_sha256(snapshot.qbar),
                "delta" => R.rows_sha256(snapshot.delta),
                "lpost" => R.vector_sha256(snapshot.lpost),
                "hard" => AWGN.sha256_values(snapshot.bits),
                "syndrome_weight" => Int(snapshot.syndrome),
            )
        end
        fingerprint[arm] = arm_rows
    end
    R.scientific_sha256(fingerprint)
end

function calculate_parallel(config, contexts, source_gate, freeze_gate, anchor_gate;
                            pass_number)
    for context in contexts, mode in (:full, :tied)
        input = AWGN.paired_frame(context.code, Int(config["timing"]["warmup_frame"]);
            esn0_db=Float64(config["channel"]["physical_esn0_db"]))
        R.instrumented_decode(context.graph, input.llr; mode,
            maximum_iterations=Int(config["decoder"]["maximum_message_passing_iterations"]),
            stop_on_valid=true, capture_snapshots=false, record_trace=false)
    end

    preflight = parallel_preflight(config, contexts, FRAMES;
        label="pass$(pass_number)-native-preflight")
    preflight["passed"] || error("native/full preflight failed")

    frozen = R.input_freeze_map(FREEZE)
    results = Vector{Any}(undef, length(FRAMES))
    mark = progress_printer("pass$(pass_number)-paired", length(FRAMES))
    Threads.@threads :static for index in eachindex(FRAMES)
        frame = FRAMES[index]
        context = contexts[Threads.threadid()]
        results[index] = compute_one_frame(config, context, frozen, frame,
                                           frame == first(FRAMES))
        mark(frame)
    end

    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    runtime_rows = NamedTuple[]
    snapshots = Dict{String,Any}()
    per_frame = Dict{String,Any}()
    for index in eachindex(FRAMES)
        frame = FRAMES[index]
        result = results[index]
        append!(frame_rows, result.frame_rows)
        append!(iteration_rows, result.iteration_rows)
        append!(runtime_rows, result.runtime_rows)
        frame == first(FRAMES) && merge!(snapshots, result.snapshots)
        per_frame[@sprintf("frame_%05d", frame)] = result.gates
    end

    confidence = Float64(config["heldout"]["newcombe_confidence_level"])
    endpoints = Dict(
        "parity_valid" => R.endpoint_statistics(frame_rows, :parity_valid, confidence),
        "transmitted_equal" => R.endpoint_statistics(frame_rows, :transmitted_equal, confidence),
    )
    adjusted = R.holm_adjust(Dict(name => Float64(result["mcnemar_exact_two_sided_pvalue"])
                                  for (name, result) in endpoints))
    for (name, value) in adjusted
        endpoints[name]["holm_adjusted_pvalue"] = value
        interval = endpoints[name]["newcombe_interval"]
        endpoints[name]["directional_claim_passed"] =
            PHASE === :heldout && interval["estimate"] > 0.0 &&
            interval["lower"] > 0.0 &&
            value < Float64(config["heldout"]["familywise_alpha"])
    end
    aggregate_rows = NamedTuple[]
    for endpoint in ("parity_valid", "transmitted_equal")
        result = endpoints[endpoint]
        counts = result["counts"]
        interval = result["newcombe_interval"]
        push!(aggregate_rows, (;
            split=String(PHASE), endpoint,
            pairs=Int(counts["pairs"]),
            both_success=Int(counts["n11_both_success"]),
            full_only_success=Int(counts["n10_full_only_success"]),
            tied_only_success=Int(counts["n01_tied_only_success"]),
            both_failure=Int(counts["n00_both_failure"]),
            risk_difference_full_minus_tied=Float64(counts["risk_difference_full_minus_tied"]),
            interval_confidence_level=Float64(interval["confidence_level"]),
            interval_lower=Float64(interval["lower"]),
            interval_upper=Float64(interval["upper"]),
            mcnemar_exact_two_sided_pvalue=Float64(result["mcnemar_exact_two_sided_pvalue"]),
            holm_adjusted_pvalue=Float64(result["holm_adjusted_pvalue"]),
        ))
    end

    all_frame_gates = all(Bool(gate["passed"])
        for result in results for gate in values(result.gates))
    correctness = Dict(
        "source" => Bool(source_gate["passed"]),
        "freeze" => Bool(freeze_gate["passed"]),
        "anchor_handoff_static" => PHASE === :anchor || Bool(anchor_gate["passed"]),
        "native_preflight" => Bool(preflight["passed"]),
        "all_frame_gates" => all_frame_gates,
    )
    science = Dict(
        "schema_version" => "bpgd-rq2-qbar-awgn-001/parallel-transfer-v1",
        "experiment_id" => String(config["experiment_id"]),
        "phase" => String(PHASE),
        "status" => all(values(correctness)) ? "valid_parallel_transfer" : "invalid",
        "validation_passed" => all(values(correctness)),
        "claim_boundary" =>
            "Parallel Windows transfer of the locked exact-SP state ablation; not the original preregistered single-thread execution record.",
        "execution_schedule" => Dict(
            "frame_parallelism" => Threads.nthreads(),
            "blas_threads_per_process" => BLAS.get_num_threads(),
            "frame_order_in_output" => "ascending",
            "arm_order_within_timed_frame" =>
                "full first on odd frame indices; tied first on even frame indices",
        ),
        "frame_count" => length(FRAMES),
        "frame_first" => first(FRAMES),
        "frame_last" => last(FRAMES),
        "correctness_checks" => correctness,
        "gates" => Dict(
            "source" => source_gate,
            "freeze" => freeze_gate,
            "anchor_handoff_static" => anchor_gate,
            "native_full_state_preflight" => preflight,
            "per_frame" => per_frame,
        ),
        "endpoints" => endpoints,
        "categorical_work" => Dict(
            "full" => R.categorical_work_totals(frame_rows, "full"),
            "tied" => R.categorical_work_totals(frame_rows, "tied"),
            "rule" => "categories are not collapsed into one scalar",
        ),
        "frame_table_sha256" => text_sha256(R.csv_text(frame_rows)),
        "iteration_table_sha256" => text_sha256(R.csv_text(iteration_rows)),
        "aggregate_table_sha256" => text_sha256(R.csv_text(aggregate_rows)),
        "snapshot_scientific_sha256" => snapshot_fingerprint(snapshots),
        "runtime_scope" => "excluded from scientific replay",
        "inference_status" =>
            "parallel transfer result; eligible for engineering confirmation, not a substitute for the frozen single-thread record",
    )
    (; science, frame_rows, iteration_rows, runtime_rows, aggregate_rows, snapshots)
end

function write_snapshot_portable(path, snapshots, graph)
    raw = endswith(path, ".gz") ? path[1:end-3] : error("snapshot path must end in .gz")
    columns = (
        "arm", "iteration", "check", "slot", "variable",
        "q", "q_hex", "u", "u_hex", "qstar", "qstar_hex",
        "qbar", "qbar_hex", "delta", "delta_hex", "lpost",
        "lpost_hex", "hard_bit", "syndrome_weight",
    )
    open(raw, "w") do io
        println(io, join(columns, ','))
        for arm in sort!(collect(keys(snapshots)))
            for iteration in sort!(collect(keys(snapshots[arm])))
                snapshot = snapshots[arm][iteration]
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
                            R.csv_value(q), R.float_hex(q),
                            R.csv_value(u), R.float_hex(u),
                            R.csv_value(qstar), R.float_hex(qstar),
                            R.csv_value(qbar), R.float_hex(qbar),
                            R.csv_value(delta), R.float_hex(delta),
                            R.csv_value(lpost), R.float_hex(lpost),
                            R.csv_value(snapshot.bits[variable]), snapshot.syndrome,
                        )
                        println(io, join(values, ','))
                    end
                end
            end
        end
    end
    run(Cmd([GZIP_EXE, "-n", raw]))
    isfile(path) || error("gzip failed to create $path")
end

function write_checksums(root)
    entries = Dict{String,String}()
    for relative in actual_files(root)
        entries[relative] = file_sha256(joinpath(root, split(relative, '/')...))
    end
    text = join(("$(entries[name])  $name" for name in sort!(collect(keys(entries)))), "\n") * "\n"
    open(joinpath(root, "MANIFEST.sha256"), "w") do io
        write(io, text)
    end
end

function write_output(bundle, replay, config, source_gate, freeze_gate, anchor_gate)
    ispath(OUTPUT) && error("refusing to overwrite output: $OUTPUT")
    mkpath(dirname(OUTPUT))
    mkdir(OUTPUT)
    open(joinpath(OUTPUT, "science.json"), "w") do io
        write(io, R.canonical_json(bundle.science), "\n")
    end
    R.write_csv(joinpath(OUTPUT, "frames.csv"), bundle.frame_rows)
    R.write_csv(joinpath(OUTPUT, "iterations.csv"), bundle.iteration_rows)
    R.write_csv(joinpath(OUTPUT, "aggregate.csv"), bundle.aggregate_rows)
    R.write_csv(joinpath(OUTPUT, "runtime.csv"), bundle.runtime_rows)
    _, code = AWGN.code_and_graph()
    write_snapshot_portable(joinpath(OUTPUT, "frame_first_state_snapshots.csv.gz"),
                            bundle.snapshots, R.graph_view(code))
    source_dir = joinpath(OUTPUT, "source")
    mkdir(source_dir)
    cp(SCRIPT_PATH, joinpath(source_dir, basename(SCRIPT_PATH)))
    cp(ORIGINAL_RUNNER, joinpath(source_dir, basename(ORIGINAL_RUNNER)))
    cp(R.DEFAULT_CONFIG, joinpath(source_dir, "config.toml"))

    manifest = Dict(
        "schema_version" => "bpgd-rq2-qbar-awgn-001/parallel-transfer-manifest-v1",
        "experiment_id" => String(config["experiment_id"]),
        "phase" => String(PHASE),
        "status" => String(bundle.science["status"]),
        "validation_passed" => Bool(bundle.science["validation_passed"]),
        "deterministic_replay" => replay,
        "science_file_sha256" => file_sha256(joinpath(OUTPUT, "science.json")),
        "input_freeze_sha256" => freeze_gate["input_table_sha256"],
        "freeze_manifest_sha256" => freeze_gate["freeze_manifest_sha256"],
        "anchor_completion_sha256" => anchor_gate["completion_sha256"],
        "parallel_wrapper_sha256" => file_sha256(SCRIPT_PATH),
        "original_runner_sha256" => file_sha256(ORIGINAL_RUNNER),
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => BLAS.get_num_threads(),
        "gzip" => readchomp(Cmd([GZIP_EXE, "--version"])),
        "created_utc" => string(now(UTC)),
        "exact_command" => join(vcat(["julia"], ARGS), " "),
        "source_gate" => source_gate,
    )
    open(joinpath(OUTPUT, "manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    completion = Dict(
        "status" => String(bundle.science["status"]),
        "validation_passed" => Bool(bundle.science["validation_passed"]),
        "replay_passed" => Bool(replay["passed"]),
        "science_file_sha256" => manifest["science_file_sha256"],
        "manifest_sha256" => file_sha256(joinpath(OUTPUT, "manifest.toml")),
    )
    open(joinpath(OUTPUT, "COMPLETED.toml"), "w") do io
        TOML.print(io, completion; sorted=true)
    end
    write_checksums(OUTPUT)
end

function retained_anchor_comparison(bundle)
    PHASE === :anchor || return Dict("applicable" => false)
    expected = Dict(
        "frames.csv" => file_sha256(joinpath(ANCHOR, "frames.csv")),
        "iterations.csv" => file_sha256(joinpath(ANCHOR, "iterations.csv")),
        "aggregate.csv" => file_sha256(joinpath(ANCHOR, "aggregate.csv")),
    )
    observed = Dict(
        "frames.csv" => text_sha256(R.csv_text(bundle.frame_rows)),
        "iterations.csv" => text_sha256(R.csv_text(bundle.iteration_rows)),
        "aggregate.csv" => text_sha256(R.csv_text(bundle.aggregate_rows)),
    )
    Dict("applicable" => true, "passed" => expected == observed,
         "expected" => expected, "observed" => observed)
end

function main()
    BLAS.set_num_threads(1)
    config = R.load_config()
    contexts = make_contexts()
    graph_gate = R.graph_invariant_gate(config, contexts[1].modem, contexts[1].code)
    graph_gate["passed"] || error("graph gate failed")
    freeze_gate = portable_freeze_gate(config, contexts[1].code)
    freeze_gate["passed"] || error("portable freeze gate failed")
    source_gate = source_gate_parallel(config, freeze_gate)
    source_gate["passed"] || error("parallel source gate failed")
    anchor_gate = anchor_static_gate()
    (PHASE === :anchor || anchor_gate["passed"]) ||
        error("anchor handoff gate failed: $(anchor_gate)")
    println(stderr, "parallel transfer start: phase=", PHASE,
            " frames=", first(FRAMES), ":", last(FRAMES),
            " threads=", Threads.nthreads(), " passes=", PASSES)
    flush(stderr)

    first_bundle = calculate_parallel(config, contexts, source_gate, freeze_gate,
                                      anchor_gate; pass_number=1)
    first_comparison = retained_anchor_comparison(first_bundle)
    if PHASE === :anchor && get(first_comparison, "passed", false) != true
        error("parallel anchor tables differ from the retained anchor")
    end
    first_bundle.science["retained_anchor_comparison"] = first_comparison
    first_hash = R.scientific_sha256(first_bundle.science)
    second_hash = "not_run"
    replay_passed = PASSES == 1
    if PASSES == 2
        second_bundle = calculate_parallel(config, contexts, source_gate, freeze_gate,
                                           anchor_gate; pass_number=2)
        second_bundle.science["retained_anchor_comparison"] =
            retained_anchor_comparison(second_bundle)
        second_hash = R.scientific_sha256(second_bundle.science)
        replay_passed = first_hash == second_hash
    end
    replay = Dict(
        "passes" => PASSES,
        "first_sha256" => first_hash,
        "second_sha256" => second_hash,
        "passed" => replay_passed,
        "scope" => "scientific states, categorical work, hashes, and gates; excludes runtime",
    )
    first_bundle.science["deterministic_replay"] = replay
    replay_passed || begin
        first_bundle.science["status"] = "invalid"
        first_bundle.science["validation_passed"] = false
    end
    write_output(first_bundle, replay, config, source_gate, freeze_gate, anchor_gate)
    println(stderr, "parallel transfer complete: status=",
            first_bundle.science["status"], " replay=", replay_passed,
            " output=", OUTPUT)
    flush(stderr)
end

main()
