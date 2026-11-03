#!/usr/bin/env julia

using Test

include(joinpath(@__DIR__, "rq2_tied_scalar_edge_repro_001.jl"))
const Study = RQ2TiedScalarEdgeRepro001

@testset "configuration and source pins" begin
    config = Study.load_config(joinpath(@__DIR__, "config.toml"))
    @test config["experiment_id"] == "RQ2-TIED-SCALAR-EDGE-REPRO-001"
    gate = Study.source_gate(config)
    @test gate["passed"]
    @test all(values(gate["checks"]))
end

function toy_problem()
    code = (n=3, check_vars=[[1, 2], [2, 3]])
    problem = Study.BlockA.BridgeProblem(
        code, [-2.0, 0.5, 1.0]; parity_weight=2.0, binary_weight=0.2)
    x = [-0.0, 0.25, -0.5]
    delta = [[0.1, -0.2], [0.3, -0.4]]
    problem, x, delta
end

@testset "direct copy lift and collapse" begin
    problem, x, _ = toy_problem()
    z = Study.lift_scalar(x, problem.check_vars)
    reconstructed = fill(NaN, length(x))
    Study.collapse_tied!(reconstructed, z, problem)
    @test Study.vector_bits_equal(x, reconstructed)
    @test reinterpret(UInt64, reconstructed[1]) == reinterpret(UInt64, -0.0)
    @test length(z) == 2
    @test sum(length, z) == 4

    broken = Study.Legacy.copy_edge_rows(z)
    broken[2][1] = nextfloat(broken[2][1])
    @test_throws Study.GateMismatch Study.collapse_tied!(
        reconstructed, broken, problem)
end

@testset "active tied evaluator is bit-for-bit equal" begin
    problem, x, delta = toy_problem()
    z = Study.lift_scalar(x, problem.check_vars)
    reference_workspace = Study.Legacy.EvalWorkspace(problem)
    treatment_workspace = Study.Legacy.EvalWorkspace(problem)
    reference = Study.BlockA.product_only_evaluate!(
        reference_workspace, problem, x, delta)
    treatment = Study.tied_evaluate!(
        treatment_workspace, problem, x, z, delta)
    @test Study.float_bits_equal(reference.loss, treatment.loss)
    @test Study.float_bits_equal(reference.terms.channel,
                                 treatment.terms.channel)
    @test Study.float_bits_equal(reference.terms.parity,
                                 treatment.terms.parity)
    @test Study.float_bits_equal(reference.terms.binary,
                                 treatment.terms.binary)
    @test Study.vector_bits_equal(reference.gradient, treatment.gradient)
    @test Study.vector_bits_equal(reference.h, treatment.h)
    @test Study.edge_bits_equal(reference.g_rows, treatment.g_rows)

    active = Study.active_read_gate(problem, x, delta)
    @test active["passed"]
    @test active["checks"]["parity_reads_edge_state"]
    @test active["checks"]["perturbation_breaks_tied_invariant"]
end

@testset "tied finite differences retain the scalar derivative" begin
    problem, x, delta = toy_problem()
    z = Study.lift_scalar(x, problem.check_vars)
    workspace = Study.Legacy.EvalWorkspace(problem)
    evaluated = Study.tied_evaluate!(workspace, problem, x, z, delta)
    tied = Study.tied_finite_difference_maximum(
        problem, x, z, delta, evaluated.gradient; step=1.0e-6)
    scalar = Study.BlockA.finite_difference_maximum(
        problem, x, delta, evaluated.gradient, :product_only; step=1.0e-6)
    @test Study.float_bits_equal(tied.maximum_error, scalar.maximum_error)
    @test tied.maximum_bit == scalar.maximum_bit
    @test tied.maximum_error <= 3.0e-8
    @test tied.z_sha256_before == tied.z_sha256_after
    @test tied.delta_sha256_before == tied.delta_sha256_after
end

