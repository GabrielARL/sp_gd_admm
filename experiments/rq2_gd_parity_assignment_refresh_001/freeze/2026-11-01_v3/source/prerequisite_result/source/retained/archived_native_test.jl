using Test

include(joinpath(@__DIR__, "run_three_receivers.jl"))
using .AWGNThreeReceivers

@testset "AWGN three-receiver mathematics" begin
    @testset "QPSK likelihood" begin
        x = [1.0, 1.0, -1.0, 1.0]
        symbols = qpsk_symbols(x)
        @test symbols == ComplexF64[(1 + im) / sqrt(2), (-1 + im) / sqrt(2)]
        llr = awgn_llrs(symbols, 0.5)
        @test llr ≈ [4.0, 4.0, -4.0, 4.0]
        @test jade_awgn_llrs(symbols, 0.5, zeros(4)) == llr
        @test jade_awgn_llrs(symbols, 0.5, ones(4)) == llr
    end

    @testset "exact analytical gradient" begin
        checks = [[1, 2, 3, 4], [2, 3, 5, 6]]
        problem = ScalarProblem(checks, 6,
            [0.7, -0.4, 1.1, -0.2, 0.6, 0.9];
            parity_weight=2.0, binary_weight=0.2)
        x = [-0.41, 0.32, 0.73, -0.58, 0.27, 0.66]
        evaluated = objective_gradient(problem, x)
        numerical = similar(x)
        h = 1.0e-6
        for bit in eachindex(x)
            plus, minus = copy(x), copy(x)
            plus[bit] += h
            minus[bit] -= h
            numerical[bit] =
                (objective(problem, plus) - objective(problem, minus)) / (2h)
        end
        @test maximum(abs, evaluated.gradient - numerical) < 2.0e-8
        @test evaluated.gradient_kind == :exact_analytic_product
    end

    @testset "projected descent" begin
        checks = [[1, 2, 3, 4], [2, 3, 5, 6]]
        problem = ScalarProblem(checks, 6,
            [0.7, -0.4, 1.1, -0.2, 0.6, 0.9];
            parity_weight=2.0, binary_weight=0.2)
        solved = solve_scalar(problem, tanh.(problem.llr ./ 2); steps=20)
        @test all(-1 .<= solved.x .<= 1)
        @test solved.accepted_steps > 0
        @test all(diff(solved.objective_history) .< 0)
        @test solved.final_objective < solved.initial_objective
        @test solved.pseudogradient_calls == 0
        @test solved.decoder_calls == 0
    end

    @testset "SNR convention" begin
        @test noise_variance_from_ebn0(0.0, 1 / 4) ≈ 2.0
        @test noise_variance_from_ebn0(3.010299956639812, 1 / 4) ≈ 1.0
        @test noise_variance_from_ebn0(0.0, 1 / 2) ≈ 1.0
        @test AWGNThreeReceivers._snr_grid(0, 0.5, 2) ==
            [0.0, 0.5, 1.0, 1.5, 2.0]
    end

    @testset "regular rate-one-half graph parameters" begin
        @test AWGNThreeReceivers._information_length(0.5, 10_200) == 5_100
        @test AWGNThreeReceivers._check_degree(10_200, 2_550, 3) == 4
        @test AWGNThreeReceivers._check_degree(10_200, 5_100, 3) == 6
        @test_throws ArgumentError AWGNThreeReceivers._check_degree(100, 37, 3)
    end
end

