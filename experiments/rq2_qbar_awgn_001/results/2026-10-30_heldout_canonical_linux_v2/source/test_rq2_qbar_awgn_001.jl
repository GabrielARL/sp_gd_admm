using Test
using LinearAlgebra

include(joinpath(@__DIR__, "rq2_qbar_awgn_001.jl"))
using .RQ2QbarAWGN001

const RQ2 = RQ2QbarAWGN001

@testset "BPGD-RQ2-QBAR-AWGN-001 registered design" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = load_config(config_path)
    BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))

    @test config["experiment_id"] == "BPGD-RQ2-QBAR-AWGN-001"
    @test !config["scope"]["native_bp_vs_projected_gd_attribution"]
    @test !config["scope"]["admm_included"]
    @test config["decoder"]["tie_start"] ==
        "first post-check variable update; consumed by check iteration 2"
    @test RQ2.require_registered_config(config_path)
    alternative = tempname()
    RQ2.write_new_file(alternative, read(config_path, String))
    @test_throws ArgumentError RQ2.require_registered_config(alternative)
    rm(alternative)
end

@testset "canonical integer-key snapshot serialization" begin
    @test canonical_json(Dict(2 => "two", 1 => "one", 10 => "ten")) ==
        "{\"1\":\"one\",\"10\":\"ten\",\"2\":\"two\"}"
    snapshot = Dict(
        "full" => Dict(
            1 => Dict("q" => [[1.0, -2.0]], "syndrome" => 3),
            2 => Dict("q" => [[0.5, -1.0]], "syndrome" => 1),
        ),
    )
    reordered = Dict(
        "full" => Dict(
            2 => Dict("syndrome" => 1, "q" => [[0.5, -1.0]]),
            1 => Dict("syndrome" => 3, "q" => [[1.0, -2.0]]),
        ),
    )
    @test canonical_json(snapshot) == canonical_json(reordered)
    @test scientific_sha256(snapshot) == scientific_sha256(reordered)
    tampered = deepcopy(snapshot)
    tampered["full"][2]["q"][1][1] = nextfloat(0.5)
    @test scientific_sha256(snapshot) != scientific_sha256(tampered)
    @test_throws ArgumentError canonical_json(Dict{Any,Any}(1 => "integer", "1" => "string"))
    @test_throws ArgumentError canonical_json(Dict(1.5 => "unsupported"))
end

@testset "exact check kernel and categorical operations" begin
    config = load_config(joinpath(@__DIR__, "config.toml"))
    enumeration = RQ2.check_enumeration_gate(config)
    @test enumeration["passed"]
    @test length(enumeration["records"]) == 20
    @test enumeration["degree_one_output"] == [20.0]

    degree_one_graph = GraphView([[1]], 1)
    degree_one_result = instrumented_decode(degree_one_graph, [-31.0];
        mode=:full, maximum_iterations=1, stop_on_valid=false)
    @test degree_one_result.u == [[20.0]]
    @test degree_one_result.operation_counts["tanh_evaluations"] == 0
    @test degree_one_result.operation_counts["atanh_evaluations"] == 0
    @test degree_one_result.operation_counts["check_product_clamps"] == 0

    graph = GraphView([[1, 2, 3]], 3)
    counted = instrumented_decode(graph, [-10.0, -10.0, -10.0];
        mode=:full, maximum_iterations=1, stop_on_valid=false)
    operations = counted.operation_counts
    @test operations["check_limit_tanh_evaluations"] == 1
    @test operations["check_limit_half_scale_multiplications"] == 1
    @test operations["check_half_input_scale_multiplications"] == 6
    @test operations["check_input_clamps"] == 6
    @test operations["tanh_evaluations"] == 6
    @test operations["check_product_multiplications"] == 6
    @test operations["check_product_clamps"] == 3
    @test operations["atanh_evaluations"] == 3
    @test operations["check_output_scale_multiplications"] == 3
    @test operations["check_output_clamps"] == 3
    @test operations["initial_syndrome_xors"] == 3
    @test operations["incremental_syndrome_parity_toggles"] == 0
    @test operations["independent_syndrome_xors"] == 3
end

@testset "causal ordering, controls, stopping, and syndrome" begin
    config = load_config(joinpath(@__DIR__, "config.toml"))
    graph = GraphView([[1, 2, 3], [1, 3, 4], [1, 2, 4]], 4)
    llr = [-1.7, 0.2, 1.1, -0.4]
    full = instrumented_decode(graph, llr; mode=:full,
        maximum_iterations=5, stop_on_valid=false)
    tied = instrumented_decode(graph, llr; mode=:tied,
        maximum_iterations=5, stop_on_valid=false)
    shadow = instrumented_decode(graph, llr; mode=:shadow,
        maximum_iterations=5, stop_on_valid=false)
    reconstructed = instrumented_decode(graph, llr; mode=:reconstruct,
        maximum_iterations=5, stop_on_valid=false)

    @test RQ2.first_iteration_gate(full, tied)["passed"]
    @test RQ2.compare_decodes(full, shadow; tolerance=0.0)["passed"]
    @test RQ2.canonical_json(full.trace) == RQ2.canonical_json(shadow.trace)
    @test RQ2.compare_decodes(full, reconstructed;
        tolerance=Float64(config["validation"]["reconstruction_tolerance"]))["passed"]
    @test all(row["syndrome_consistent"] for row in full.trace)
    @test all(row["syndrome_consistent"] for row in tied.trace)
    @test full.physical_state_bytes == tied.physical_state_bytes
    @test !full.intervention_activated
    @test tied.intervention_activated
    @test RQ2.degree_one_gate(config)["passed"]
    @test RQ2.relabel_gate(config)["passed"]

    clean = instrumented_decode(GraphView([[1, 2]], 2), [10.0, 10.0];
        mode=:full, maximum_iterations=80, stop_on_valid=true)
    @test clean.valid
    @test clean.iterations == 1
    @test clean.hard == falses(2)

    capped = instrumented_decode(GraphView([[1, 2, 3]], 3),
        [-10.0, -10.0, -10.0]; mode=:full,
        maximum_iterations=80, stop_on_valid=true)
    @test !capped.valid
    @test capped.iterations == 80
    @test all(row["syndrome_consistent"] for row in capped.trace)

    wrong_valid = instrumented_decode(GraphView([[1, 2]], 2), [-10.0, -10.0];
        mode=:full, maximum_iterations=80, stop_on_valid=true)
    @test wrong_valid.valid
    @test wrong_valid.hard == trues(2)
    @test wrong_valid.hard != falses(2)
end

@testset "paired statistical fixtures" begin
    counts = Dict(
        "n11_both_success" => 20,
        "n10_full_only_success" => 12,
        "n01_tied_only_success" => 2,
        "n00_both_failure" => 16,
    )
    interval = newcombe_paired_interval(counts; confidence_level=0.95)
    @test isapprox(interval["lower"], 0.0562; atol=5e-5)
    @test isapprox(interval["upper"], 0.3292; atol=5e-5)
    @test occursin("continuity-corrected", interval["method"])
    @test isapprox(mcnemar_exact_pvalue(counts), 212 / 16384; atol=1e-15)
    adjusted = RQ2.holm_adjust(Dict("a" => 0.01, "b" => 0.01, "c" => 0.04))
    @test adjusted["a"] == 0.03
    @test adjusted["b"] == 0.03
    @test adjusted["c"] == 0.04
end

@testset "Jade graph, native state, freeze, and tamper gates" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = load_config(config_path)
    BLAS.set_num_threads(Int(config["validation"]["blas_threads"]))
    sources = source_gate(config)
    @test sources["passed"]

    modem, code = RQ2.AWGN.code_and_graph()
    graph_gate = RQ2.graph_invariant_gate(config, modem, code)
    @test graph_gate["passed"]
    input = RQ2.AWGN.paired_frame(code, 1;
        esn0_db=Float64(config["channel"]["physical_esn0_db"]))
    full = instrumented_decode(RQ2.graph_view(code), input.llr; mode=:full,
        maximum_iterations=Int(config["decoder"]["maximum_message_passing_iterations"]),
        stop_on_valid=true)
    native_result = native_decode(modem, code, input.llr)
    equivalence = RQ2.endpoint_equivalence(full, native_result)
    @test equivalence["passed"]
    @test all(values(equivalence["checks"]))
    native_preflight = RQ2.native_phase_preflight(config, modem, code, :anchor)
    @test native_preflight["passed"]
    @test native_preflight["frame_count"] == 24
    @test all(frame_gate["passed"] for frame_gate in
              values(native_preflight["frames"]))

    temporary = mktempdir()
    frozen = joinpath(temporary, "freeze")
    freeze_inputs(; config_path, output=frozen,
                  exact_command="test input freeze")
    verified = verify_freeze(config, frozen)
    @test verified["passed"]
    freeze_manifest = RQ2.TOML.parsefile(joinpath(frozen, "freeze_manifest.toml"))
    @test freeze_manifest["anchor_count"] == 24
    @test freeze_manifest["heldout_count"] == 200
    @test !freeze_manifest["heldout_decoders_executed"]
    @test freeze_manifest["anchor_reference_gate"]["passed"]

    extra = joinpath(frozen, "unexpected.txt")
    RQ2.write_new_file(extra, "tamper\n")
    @test !RQ2.verify_checksum_manifest(frozen)["passed"]
    rm(extra)
    @test RQ2.verify_checksum_manifest(frozen)["passed"]

    unsafe_link = joinpath(frozen, "unsafe_link")
    symlink("/etc/hosts", unsafe_link)
    @test !RQ2.verify_checksum_manifest(frozen)["passed"]
    rm(unsafe_link)
    @test RQ2.verify_checksum_manifest(frozen)["passed"]

    snapshot_graph = GraphView([[1, 2, 3]], 3)
    snapshot_decode = instrumented_decode(snapshot_graph,
        [-10.0, -10.0, -10.0]; mode=:full, maximum_iterations=2,
        stop_on_valid=false, capture_snapshots=true)
    snapshot_science = Dict("full" => snapshot_decode.snapshots)
    snapshot_hash = scientific_sha256(snapshot_science)
    @test length(snapshot_hash) == 64
    snapshot_tamper = deepcopy(snapshot_science)
    snapshot_tamper["full"][1].q[1][1] = nextfloat(
        snapshot_tamper["full"][1].q[1][1])
    @test scientific_sha256(snapshot_tamper) != snapshot_hash
    snapshot_path = joinpath(temporary, "snapshot.csv.gz")
    RQ2.write_snapshot_archive(snapshot_path,
        Dict("full" => snapshot_decode.snapshots), snapshot_graph)
    @test isfile(snapshot_path)
    @test startswith(read(pipeline(`gzip -cd $snapshot_path`), String),
                     "arm,iteration,check,slot,variable")

    retained = joinpath(temporary, "synthetic_result")
    mkdir(retained)
    science = Dict(
        "phase" => "anchor",
        "status" => "invalid",
        "validation_passed" => false,
        "anchor_expansion_gate" => Dict("passed" => false),
    )
    bundle = (;
        science,
        frame_rows=NamedTuple[],
        iteration_rows=NamedTuple[],
        runtime_rows=NamedTuple[],
        aggregate_rows=NamedTuple[],
        snapshots=Dict{String,Any}(),
    )
    replay = Dict{String,Any}(
        "first_sha256" => scientific_sha256(science),
        "second_sha256" => "not_run",
        "passed" => false,
        "scope" => "synthetic writer test",
    )
    written = RQ2.write_phase_result(retained, bundle, config, frozen,
                                     "synthetic writer test", replay)
    @test RQ2.verify_checksum_manifest(retained)["passed"]
    @test isfile(joinpath(retained, "COMPLETED.toml"))
    @test length(written.completion_sha256) == 64
    @test !RQ2.validate_anchor_handoff(retained, frozen)["passed"]

    open(joinpath(retained, "science.json"), "a") do io
        write(io, "tamper\n")
    end
    @test !RQ2.verify_checksum_manifest(retained)["passed"]

    @test_throws ArgumentError freeze_inputs(; config_path, output=frozen,
        exact_command="must refuse overwrite")
end
