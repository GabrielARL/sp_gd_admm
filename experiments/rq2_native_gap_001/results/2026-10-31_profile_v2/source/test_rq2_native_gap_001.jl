#!/usr/bin/env julia
# Focused tests for RQ2-NATIVE-GAP-001.
# OMP_NUM_THREADS=1 julia --project=<jade worktree> this_file.jl

using Test
include(joinpath(@__DIR__, "rq2_native_gap_001.jl"))
const G = RQ2NativeGap001
const Legacy = G.Legacy

ENV["OMP_NUM_THREADS"] = "1"

@testset "RQ2-NATIVE-GAP-001" begin
    config = G.load_config()
    split = G.load_split_config(config)
    @test G.source_gate(config)["passed"]
    Legacy.enforce_thread_environment(split)
    native = Legacy.load_native(split)
    generated = G.make_bp_code(config, split)
    modem, code = generated.modem, generated.code
    @test modem.bp_iterations == 80

    @testset "channel variance" begin
        six = G.channel_config(split, 6.0)
        @test six["channel"]["noise_variance"] == split["channel"]["noise_variance"]
        low = G.channel_config(split, 1.5)
        @test low["channel"]["noise_variance"] ≈ 10.0^(-0.15)
        @test low["channel"]["physical_esn0_db"] == 1.5
    end

    frame = 20001
    codex_freeze = Dict(parse(Int, r.frame) => r for r in Legacy.parse_simple_csv(
        String(config["protocol"]["split_freeze_input_table"])))
    codex_anchor = Dict(parse(Int, r.frame) => r for r in Legacy.parse_simple_csv(
        String(config["protocol"]["split_anchor_frames"])) if r.arm == "objective0__bounds0")
    input = Legacy.generate_input(G.channel_config(split, 6.0), native, code, frame)
    llr = Float64.(input.clipped_llr)

    @testset "same frozen case as the split experiment" begin
        @test codex_freeze[frame].clipped_llr_sha256 == input.identities.clipped_llr_sha256
        @test codex_freeze[frame].received_sha256 == input.identities.received_sha256
    end

    @testset "BP kernel" begin
        bp = G.decode_bp(modem, code, llr)
        @test bp.kernel_valid == bp.parity_valid
        @test bp.syndrome_weight == bp.kernel_syndrome || !bp.kernel_valid
        @test 1 <= bp.iterations <= 80
        # Same frame at 1.5 dB uses the same unit noise.
        low = Legacy.generate_input(G.channel_config(split, 1.5), native, code, frame)
        @test low.identities.unit_noise_sha256 == input.identities.unit_noise_sha256
        @test low.identities.clipped_llr_sha256 != input.identities.clipped_llr_sha256
    end

    @testset "GD control equals the split anchor control" begin
        gd = G.decode_gd(split, code, llr)
        @test G.vector_sha256(gd.hard) == codex_anchor[frame].hard_word_sha256
    end

    @testset "paired table and inference" begin
        rows = [(; frame=1, method="bp_exact_sum_product", transmitted_word_equal=true, parity_valid=true),
                (; frame=1, method="gd_native_projected", transmitted_word_equal=false, parity_valid=false),
                (; frame=2, method="bp_exact_sum_product", transmitted_word_equal=true, parity_valid=true),
                (; frame=2, method="gd_native_projected", transmitted_word_equal=true, parity_valid=true)]
        table = G.paired_table(rows)
        @test table["transmitted_word_equal"]["treatment_only_success"] == 1
        @test table["parity_valid"]["both_success"] == 1
        G.add_inference!(table, 0.975)
        @test haskey(table["parity_valid"], "holm_adjusted_pvalue")
        @test haskey(table["transmitted_word_equal"]["newcombe_interval"], "lower")
    end

    @testset "second Es/N0 selection rule" begin
        grid = Float64.(config["stages"]["profile"]["esn0_grid_db"])
        counts = Dict(e => Dict("bp_exact_sum_product" => 24, "gd_native_projected" => 0)
                      for e in grid)
        sat = G.select_second_esn0(config, counts)
        @test sat.bp_saturated_on_grid && sat.esn0 == 1.5
        counts[2.0]["bp_exact_sum_product"] = 12
        counts[1.5]["bp_exact_sum_product"] = 3
        pick = G.select_second_esn0(config, counts)
        @test !pick.bp_saturated_on_grid && pick.esn0 == 2.0
        counts[6.0]["bp_exact_sum_product"] = 0
        @test G.select_second_esn0(config, counts).esn0 == 2.0
    end
end
