#!/usr/bin/env julia

using Test

include(joinpath(@__DIR__, "rq2_common_coordinate_repro_001.jl"))
const Study = RQ2CommonCoordinateRepro001

@testset "configuration and frozen source gates" begin
    config = Study.load_config(joinpath(@__DIR__, "config.toml"))
    @test config["experiment_id"] == "RQ2-COMMON-COORDINATE-REPRO-001"
    @test config["performance_inference_allowed"] == false
    gate = Study.source_gate(config)
    @test gate["passed"]
    @test all(values(gate["checks"]))
    @test Study.verify_manifest(Study.NATIVE_FREEZE *
                                Base.Filesystem.path_separator)["passed"]
    threads = Study.thread_environment_gate(config)
    @test threads["passed"]
    composition_config = Study.Composition.load_config(Study.COMPOSITION_CONFIG)
    context = Study.Composition.backend_context(
        composition_config, Study.COMPOSITION_CONFIG)
    graph = Study.graph_identity_gate(context, config)
    @test graph["passed"]
end

function toy_gd_problem()
    code = (n=3, check_vars=[[1, 2], [1, 3]])
    problem = Study.BlockA.BridgeProblem(
        code, [-2.0, 0.5, 1.0]; parity_weight=2.0, binary_weight=0.2)
    problem, [0.25, -0.4, 0.6]
end

@testset "GD direct-copy lift and signed-zero collapse" begin
    problem, _ = toy_gd_problem()
    x = [-0.0, 0.25, -0.5]
    z = Study.lift_gd(x, problem.check_vars)
    reconstructed = fill(NaN, length(x))
    Study.collapse_gd!(reconstructed, z, problem)
    @test Study.vector_bits_equal(x, reconstructed)
    @test reinterpret(UInt64, reconstructed[1]) == reinterpret(UInt64, -0.0)

    broken = Study.Legacy.copy_edge_rows(z)
    broken[2][1] = nextfloat(broken[2][1])
    @test_throws Study.GateMismatch Study.collapse_gd!(
        reconstructed, broken, problem)
end

@testset "GD parity calculation actively reads tied edge values" begin
    problem, x = toy_gd_problem()
    z = Study.lift_gd(x, problem.check_vars)
    reference_workspace = Study.Legacy.EvalWorkspace(problem)
    treatment_workspace = Study.Legacy.EvalWorkspace(problem)
    reference = Study.gd_scalar_evaluate!(reference_workspace, problem, x)
    treatment = Study.gd_edge_evaluate!(
        treatment_workspace, problem, x, z)
    @test Study.float_bits_equal(reference.loss, treatment.loss)
    @test Study.float_bits_equal(reference.terms.channel,
                                 treatment.terms.channel)
    @test Study.float_bits_equal(reference.terms.parity,
                                 treatment.terms.parity)
    @test Study.float_bits_equal(reference.terms.binary,
                                 treatment.terms.binary)
    @test Study.vector_bits_equal(reference.gradient, treatment.gradient)
    @test Study.edge_bits_equal(reference.g_rows, treatment.g_rows)
    @test treatment.edge_reads == 8

    active = Study.gd_active_read_gate(problem, x; expected_reads=8)
    @test active["passed"]
    @test all(values(active["checks"]))

    signed_x = [-0.0, 0.25, -0.5]
    signed_z = Study.lift_gd(signed_x, problem.check_vars)
    signed_reference = Study.gd_scalar_evaluate!(
        Study.Legacy.EvalWorkspace(problem), problem, signed_x)
    signed_treatment = Study.gd_edge_evaluate!(
        Study.Legacy.EvalWorkspace(problem), problem, signed_x, signed_z)
    @test Study.float_bits_equal(signed_reference.loss, signed_treatment.loss)
    @test Study.vector_bits_equal(
        signed_reference.gradient, signed_treatment.gradient)
    @test Study.edge_bits_equal(
        signed_reference.g_rows, signed_treatment.g_rows)
end

@testset "GD projection and strict-decrease primitives" begin
    current = [0.9, -0.9]
    direction = [2.0, -2.0]
    step = 0.2 * 0.5^3
    raw = current .+ step .* direction
    projected = clamp.(raw, -1.0, 1.0)
    @test raw == [0.9500000000000001, -0.9500000000000001]
    @test projected == raw
    @test !(1.0 < 1.0)
    @test 0.9999999999999999 < 1.0

    problem, _ = toy_gd_problem()
    trial = [1.0, -1.0, 0.125]
    z = Study.lift_gd(trial, problem.check_vars)
    collapsed = similar(trial)
    Study.collapse_gd!(collapsed, z, problem)
    @test Study.vector_bits_equal(trial, collapsed)
end

@testset "BP degree-six check calculation consumes z" begin
    graph = Study.BlockB.GraphView([collect(1:6)], 6)
    q = [0.31, -0.57, 0.83, -1.09, 1.37, -1.61]
    z = Study.bp_transform(q)
    @test Study.vector_bits_equal(z, Study.bp_transform_reference(q))
    treatment = Study.bp_check_from_z(graph, z)
    native_output = zeros(6)
    Study.BlockB.CORE._bp_check_sum_product!(native_output, q)
    @test Study.vector_bits_equal(native_output, treatment.output)
    @test treatment.edge_reads == 30
    @test all(isfinite, treatment.products)

    active = Study.bp_active_read_gate(graph; expected_reads=30)
    @test active["passed"]
    @test all(values(active["checks"]))

    permuted = Study.bp_check_from_z(graph, reverse(z))
    @test !Study.vector_bits_equal(treatment.output, permuted.output)
    @test Study.BlockB.graph_sha256([collect(1:6)]) !=
          Study.BlockB.graph_sha256([reverse(collect(1:6))])
end

@testset "BP degree-one branch and non-invertible transform" begin
    graph = Study.BlockB.GraphView([[1]], 1)
    result = Study.bp_check_from_z(graph, [0.25])
    @test result.output == [Study.BlockB.LLR_CLIP]
    @test result.edge_reads == 0

    transformed = Study.bp_transform([20.0, 21.0, -20.0, -21.0])
    @test Study.vector_bits_equal(
        transformed,
        Study.bp_transform_reference([20.0, 21.0, -20.0, -21.0]))
    @test Study.vector_bits_equal(transformed[1:1], transformed[2:2])
    @test Study.vector_bits_equal(transformed[3:3], transformed[4:4])

    signed_graph = Study.BlockB.GraphView([[1, 2]], 2)
    signed_q = Study.bp_initial_q(signed_graph, [-0.0, 0.0])
    @test reinterpret(UInt64, signed_q[1]) == reinterpret(UInt64, -0.0)
    @test reinterpret(UInt64, signed_q[2]) == reinterpret(UInt64, 0.0)

    saturated_q = [100.0, -100.0]
    saturated_z = Study.bp_transform(saturated_q)
    saturated = Study.bp_check_from_z(signed_graph, saturated_z)
    saturated_native = zeros(2)
    Study.BlockB.CORE._bp_check_sum_product!(saturated_native, saturated_q)
    @test Study.vector_bits_equal(saturated.output, saturated_native)
    @test all(abs.(saturated.output) .<= Study.BlockB.LLR_CLIP)
    product_clipped = Study.bp_check_from_z(signed_graph, [1.0, -1.0])
    clamp_limit = tanh(0.5 * Study.BlockB.LLR_CLIP)
    @test Study.vector_bits_equal(product_clipped.output,
        [2atanh(-clamp_limit), 2atanh(clamp_limit)])
end

@testset "BP variable order and two flooding iterations" begin
    graph = Study.BlockB.GraphView([[1, 2], [2, 3]], 3)
    @test graph.variable_edges[2] == [2, 3]
    llr = [-2.197225, 0.405465, 0.693147]
    u_reference = zeros(4)
    u_treatment = zeros(4)
    q = Study.BlockB.variable_values(graph, llr, u_reference, :full).q_used
    z = Study.bp_transform(q)
    for _ in 1:2
        reference = Study.BlockB.evaluate_map(graph, llr, u_reference, :full)
        treatment = Study.bp_check_from_z(graph, z)
        @test Study.vector_bits_equal(reference.output, treatment.output)
        u_reference = copy(reference.output)
        u_treatment = copy(treatment.output)
        reference_values = Study.BlockB.variable_values(
            graph, llr, u_reference, :full)
        treatment_values = Study.bp_variable_from_u(
            graph, llr, u_treatment)
        @test Study.vector_bits_equal(reference_values.lpost,
                                     treatment_values.lpost)
        @test Study.vector_bits_equal(reference_values.q_used,
                                     treatment_values.q)
        reference_hard = BitVector(reference_values.lpost .< 0.0)
        treatment_hard = BitVector(treatment_values.lpost .< 0.0)
        @test reference_hard == treatment_hard
        reference_syndrome = Study.BlockB.syndrome_vector(
            graph, reference_hard)
        treatment_syndrome = Study.BlockB.syndrome_vector(
            graph, treatment_hard)
        @test reference_syndrome == treatment_syndrome
        @test (count(reference_syndrome) == 0) ==
              (count(treatment_syndrome) == 0)
        z = Study.bp_transform(treatment_values.q)
    end
end

@testset "first mismatch and canonical replay hash" begin
    error = try
        Study.require_vector(9, "unit", 2, 3, "probe", [0.0], [-0.0])
        nothing
    catch caught
        caught
    end
    @test error isa Study.GateMismatch
    @test error.frame == 9
    @test error.lane == "unit"
    @test error.iteration == 2
    @test error.trial == 3
    @test error.field == "probe"
    @test error.index == "1"

    payload = Dict("b" => [1.0, -0.0], "a" => Dict("x" => true))
    @test Study.scientific_sha256(payload) == Study.scientific_sha256(deepcopy(payload))
end
