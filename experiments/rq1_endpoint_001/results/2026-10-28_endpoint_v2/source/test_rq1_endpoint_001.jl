using Test

include(joinpath(@__DIR__, "rq1_endpoint_001.jl"))
using .RQ1Endpoint001

@testset "RQ1-ENDPOINT-001 deterministic bridge" begin
    config_path = joinpath(@__DIR__, "config.toml")
    config = load_config(config_path)

    @test config["channel_evidence"]["convention"] ==
        "L_i = log(P(bit_i=1|y_i)/P(bit_i=0|y_i)); positive favors bit 1"
    @test !config["scope"]["admm_included"]
    @test !config["scope"]["broad_awgn_run"]
    @test !config["scope"]["performance_claim"]

    fingerprints = rung_fingerprints(config)
    @test length(fingerprints) == 7
    @test [fingerprint["card_id"] for fingerprint in fingerprints] == [
        "RQ1-ENDPOINT-PG-BASE-001",
        "RQ1-BRIDGE-CHANNEL-001",
        "RQ1-BRIDGE-BINARY-001",
        "RQ1-BRIDGE-STEP-001",
        "RQ1-BRIDGE-PRECOND-001",
        "RQ1-BRIDGE-LINESEARCH-001",
        "RQ1-ENDPOINT-PG-001",
    ]

    temporary_parent = mktempdir()
    output = joinpath(temporary_parent, "retained")
    executed = execute(; config_path, output,
        command="test_rq1_endpoint_001.jl deterministic execution")
    science = executed.science

    @test science["status"] == "valid"
    @test science["validation_passed"]
    @test science["downstream_cards_executed"]
    @test all(values(science["validation_checks"]))
    @test science["native_endpoint_equivalence"]["gate"]["bitwise_canonical_match"]
    @test science["native_endpoint_equivalence"]["gate"]["passed"]
    @test science["bp_card"]["native"]["entrypoint"] ==
        "JadeJcade.ReceiverCore._bp_decode_sum_product"
    @test science["bp_card"]["checks"]["normalized_min_sum_not_called"]
    @test science["bp_card"]["checks"]["llr_clipping_inactive"]
    @test science["parity_base_card"]["passed"]
    @test science["adjacent_field_hashes"]["passed"]
    @test science["projection_and_frozen_state"]["passed"]
    @test science["line_search_prefix"]["passed"]
    @test science["current_native_composition"]["passed"]
    @test science["archived_native_composition"]["passed"]
    @test science["deterministic_replay"]["passed"]

    @test isfile(joinpath(output, "trace.json"))
    @test isfile(joinpath(output, "manifest.json"))
    @test isfile(joinpath(output, "MANIFEST.sha256"))
    @test isfile(joinpath(output, "source", "config.toml"))
    @test isfile(joinpath(output, "source", "experiment_card.md"))
    @test isfile(joinpath(output, "source", "rq1_endpoint_001.jl"))
    @test isfile(joinpath(output, "source", "test_rq1_endpoint_001.jl"))
    @test isfile(joinpath(output, "source", "current_run_three_receivers.jl"))
    @test isfile(joinpath(output, "source", "archived_r050_run_three_receivers.jl"))

    current = science["native_endpoint_equivalence"]["current"]
    altered = deepcopy(science["native_endpoint_equivalence"]["archived"])
    altered["x"][1] = nextfloat(altered["x"][1])
    @test !endpoint_equivalence(current, altered)["passed"]

    @test_throws ArgumentError execute(; config_path, output,
        command="must refuse overwrite")
end
