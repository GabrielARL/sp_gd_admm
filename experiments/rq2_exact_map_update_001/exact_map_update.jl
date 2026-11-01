#!/usr/bin/env julia

module RQ2ExactMapUpdate001

using Dates
using JadeJcade
using LinearAlgebra
using Printf
using Random
using SHA
using TOML

const HERE = @__DIR__
const DEFAULT_CONFIG = joinpath(HERE, "config.toml")
const BLOCK_B_PATH = normpath(joinpath(
    HERE, "..", "rq2_bp_target_state_update_001",
    "rq2_bp_target_state_update_001.jl"))

isfile(BLOCK_B_PATH) || throw(ArgumentError(
    "retained Block-B runner is missing at $BLOCK_B_PATH"))
Base.include(@__MODULE__, BLOCK_B_PATH)
const BlockB = RQ2BPTargetStateUpdate001

const EXPERIMENT_ID = "RQ2-EXACT-MAP-UPDATE-001"
const CONFIG_SCHEMA = "rq2-exact-map-update-001/config-v1"
const SCIENCE_SCHEMA = "rq2-exact-map-update-001/science-v1"
const JOB_GATE_SCHEMA = "rq2-exact-map-update-001/job-gate-v1"
const ENDPOINT_GATE_SCHEMA = "rq2-exact-map-update-001/endpoint-gate-v1"
const COMPLETION_SCHEMA = "rq2-exact-map-update-001/job-completion-v1"
const TIMING_SCHEMA = "rq2-exact-map-update-001/timing-v1"

const JOB_ORDER = (
    "01_validation_reproduction_gate",
    "02_fresh_dual_snr_anchor",
    "03_six_db_transfer",
    "04_second_snr_confirmation",
)
const ARMS = (
    "true_gradient__armijo",
    "map_minus_state__armijo",
    "true_gradient__unit",
    "map_minus_state__unit",
)

export EXPERIMENT_ID, JOB_ORDER, ARMS, load_config, job_case_specs,
       arm_spec, run_arm, trajectory_reproduction_gate,
       calculate_job, run_job, main, scientific_sha256

# ---------------------------------------------------------------------------
# Configuration and stable serialization
# ---------------------------------------------------------------------------

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))
text_sha256(value::AbstractString) =
    bytes2hex(sha256(Vector{UInt8}(codeunits(value))))
scientific_sha256(value) = text_sha256(BlockB.canonical_json(value))

resolve_from(base::AbstractString, path::AbstractString) =
    isabspath(path) ? normpath(path) : normpath(joinpath(base, path))

function load_config(path::AbstractString=DEFAULT_CONFIG)
    config = TOML.parsefile(path)
    get(config, "schema_version", "") == CONFIG_SCHEMA ||
        throw(ArgumentError("unsupported exact-map-update configuration schema"))
    get(config, "experiment_id", "") == EXPERIMENT_ID ||
        throw(ArgumentError("unexpected experiment identifier"))
    get(config, "research_question", "") == "RQ2" ||
        throw(ArgumentError("this experiment must remain registered to RQ2"))
    String.(config["factorial"]["arm_order"]) == collect(ARMS) ||
        throw(ArgumentError("registered arm order changed"))
    Int(config["budget"]["update_attempts_per_arm"]) == 30 ||
        throw(ArgumentError("every arm requires exactly 30 attempted updates"))
    Int(config["budget"]["scientific_passes"]) == 2 ||
        throw(ArgumentError("primary and replay passes are required"))
    Bool(config["budget"]["outcome_altering_early_stop"]) == false ||
        throw(ArgumentError("outcome-altering early stopping is forbidden"))

    jobs = config["jobs"]
    expected = Dict(
        JOB_ORDER[1] => (20001, 20024, 24, ["six_db"], true),
        JOB_ORDER[2] => (60425, 60448, 48, ["six_db", "second_snr"], false),
        JOB_ORDER[3] => (60449, 60648, 200, ["six_db"], false),
        JOB_ORDER[4] => (60649, 60848, 200, ["second_snr"], false),
    )
    for job_id in JOB_ORDER
        haskey(jobs, job_id) || throw(ArgumentError("missing job $job_id"))
        first_expected, last_expected, count_expected, channels_expected,
            validation_expected = expected[job_id]
        job = jobs[job_id]
        Int(job["frame_first"]) == first_expected ||
            throw(ArgumentError("$job_id first frame changed"))
        Int(job["frame_last"]) == last_expected ||
            throw(ArgumentError("$job_id last frame changed"))
        Int(job["expected_case_count"]) == count_expected ||
            throw(ArgumentError("$job_id expected case count changed"))
        String.(job["channels"]) == channels_expected ||
            throw(ArgumentError("$job_id channel order changed"))
        Bool(job["validation_only"]) == validation_expected ||
            throw(ArgumentError("$job_id validation role changed"))
    end

    provenance = config["provenance"]
    expected_schemas = Dict(
        "science_schema" => SCIENCE_SCHEMA,
        "job_gate_schema" => JOB_GATE_SCHEMA,
        "endpoint_gate_schema" => ENDPOINT_GATE_SCHEMA,
        "completion_schema" => COMPLETION_SCHEMA,
        "timing_schema" => TIMING_SCHEMA,
    )
    all(String(provenance[key]) == value for (key, value) in expected_schemas) ||
        throw(ArgumentError("registered artifact schemas changed"))
    inference = config["inference"]
    alpha = Float64(inference["familywise_alpha"])
    contrast_count = Int(inference["atomic_contrast_count"])
    alpha == 0.05 || throw(ArgumentError("familywise alpha changed"))
    contrast_count == 4 || throw(ArgumentError("four atomic contrasts required"))
    Float64(inference["simultaneous_interval_confidence_level"]) ==
        1.0 - alpha / contrast_count ||
        throw(ArgumentError("simultaneous interval confidence changed"))
    Bool(inference["pool_across_snr"]) == false ||
        throw(ArgumentError("SNR pooling is forbidden"))
    Bool(inference["pool_across_jobs"]) == false ||
        throw(ArgumentError("job pooling is forbidden"))
    config
end

function job_case_specs(config, job_id::AbstractString)
    job_id in JOB_ORDER || throw(ArgumentError("unknown job ID $job_id"))
    job = config["jobs"][String(job_id)]
    specs = [(String(channel), frame)
             for channel in String.(job["channels"])
             for frame in Int(job["frame_first"]):Int(job["frame_last"])]
    length(specs) == Int(job["expected_case_count"]) ||
        throw(ArgumentError("$job_id case count differs from registration"))
    specs
end

function enforce_thread_environment(config)
    validation = config["validation"]
    Threads.nthreads() == Int(validation["julia_threads"]) ||
        throw(ArgumentError("registered Julia thread count required"))
    get(ENV, "OMP_NUM_THREADS", "") == string(validation["omp_threads"]) ||
        throw(ArgumentError("OMP_NUM_THREADS must equal the registered value"))
    BLAS.set_num_threads(Int(validation["blas_threads"]))
    BLAS.get_num_threads() == Int(validation["blas_threads"]) ||
        throw(ArgumentError("registered BLAS thread count did not take effect"))
    true
end

function source_paths(config, config_path::AbstractString)
    base = dirname(abspath(config_path))
    sources = config["sources"]
    Dict(
        "block_b_runner" => resolve_from(base, String(sources["block_b_runner"])),
        "block_b_config" => resolve_from(base, String(sources["block_b_config"])),
        "jade_project" => resolve_from(base, String(sources["jade_project_repo"])),
        "native_runner" => resolve_from(base, String(sources["archived_native_runner"])),
    )
end

function source_gate(config, config_path::AbstractString)
    paths = source_paths(config, config_path)
    sources = config["sources"]
    jade = paths["jade_project"]
    loaded_root = realpath(dirname(dirname(pathof(JadeJcade))))
    checks = Dict{String,Bool}(
        "block_b_relative_identity" => realpath(paths["block_b_runner"]) ==
            realpath(BLOCK_B_PATH),
        "block_b_runner_hash" => file_sha256(paths["block_b_runner"]) ==
            String(sources["block_b_runner_sha256"]),
        "block_b_config_hash" => file_sha256(paths["block_b_config"]) ==
            String(sources["block_b_config_sha256"]),
        "loaded_jade_root" => loaded_root == realpath(jade),
        "jade_project_hash" => file_sha256(joinpath(jade, "Project.toml")) ==
            String(sources["jade_project_toml_sha256"]),
        "jade_manifest_hash" => file_sha256(joinpath(jade, "Manifest.toml")) ==
            String(sources["jade_manifest_toml_sha256"]),
        "jade_module_hash" => file_sha256(joinpath(jade, "src", "JadeJcade.jl")) ==
            String(sources["jade_module_sha256"]),
        "jade_ldpc_hash" => file_sha256(joinpath(jade, "src", "LDPC.jl")) ==
            String(sources["jade_ldpc_sha256"]),
        "jade_receiver_core_hash" =>
            file_sha256(joinpath(jade, "src", "ReceiverCore.jl")) ==
            String(sources["jade_receiver_core_sha256"]),
        "native_runner_hash" => file_sha256(paths["native_runner"]) ==
            String(sources["archived_native_runner_sha256"]),
    )
    Dict("passed" => all(values(checks)), "checks" => checks,
         "block_b_runner_sha256" => file_sha256(paths["block_b_runner"]))
end

function load_native(config, config_path::AbstractString)
    path = source_paths(config, config_path)["native_runner"]
    if !isdefined(@__MODULE__, :AWGNThreeReceivers)
        Base.include(@__MODULE__, path)
    end
    Base.invokelatest(() -> getfield(@__MODULE__, :AWGNThreeReceivers))
end

function make_code(config, native)
    modem, code = BlockB.native_call(native, :_modem_and_code;
        k=Int(config["code"]["k"]), n=Int(config["code"]["n"]),
        variable_degree=Int(config["code"]["variable_degree"]))
    BlockB.graph_sha256(code.check_vars) == String(config["code"]["graph_sha256"]) ||
        throw(ArgumentError("LDPC graph hash changed"))
    all(length(check) == Int(config["code"]["check_degree"])
        for check in code.check_vars) ||
        throw(ArgumentError("LDPC check degree changed"))
    (; modem, code, graph=BlockB.graph_view(code))
end

function channel_section(config, label::AbstractString)
    channels = config["channels"]
    haskey(channels, label) || throw(ArgumentError("unknown channel $label"))
    channels[label]
end

function generate_input(config, native, code, channel::AbstractString,
                        frame::Integer)
    section = channel_section(config, channel)
    variance = Float64(section["noise_variance"])
    seed = Int(section["noise_seed_base"]) + Int(frame)
    n = Int(config["code"]["n"])
    symbols = BlockB.native_call(native, :qpsk_symbols, ones(Float64, n))
    rng = MersenneTwister(seed)
    unit_noise = complex.(randn(rng, length(symbols)),
                          randn(rng, length(symbols))) ./ sqrt(2.0)
    received = symbols .+ sqrt(variance) .* unit_noise
    raw_llr = BlockB.native_call(native, :awgn_llrs, received, variance)
    clip = Float64(section["llr_clip"])
    llr = clamp.(Float64.(raw_llr), -clip, clip)
    (; channel=String(channel), snr_db=Float64(section["snr_db"]),
       frame=Int(frame), noise_seed=seed, llr,
       llr_sha256=BlockB.vector_sha256(llr),
       received_sha256=BlockB.vector_sha256(received),
       unit_noise_sha256=BlockB.vector_sha256(unit_noise))
end

# ---------------------------------------------------------------------------
# Four-cell direction-by-step execution
# ---------------------------------------------------------------------------

function arm_spec(arm::AbstractString)
    arm in ARMS || throw(ArgumentError("unknown arm $arm"))
    direction = startswith(arm, "true_gradient__") ? :true_gradient :
        :map_minus_state
    step_rule = endswith(arm, "__armijo") ? :armijo : :unit
    (; arm=String(arm), direction, step_rule)
end

float_bits_equal(left::AbstractVector{Float64}, right::AbstractVector{Float64}) =
    length(left) == length(right) &&
    reinterpret(UInt64, left) == reinterpret(UInt64, right)

function float_bits_equal(left::Float64, right::Float64)
    reinterpret(UInt64, [left]) == reinterpret(UInt64, [right])
end

function independent_decision_gate(graph, llr, u, state, code=nothing)
    lpost = Float64.(llr)
    for variable in 1:graph.n
        @inbounds for edge in graph.variable_edges[variable]
            lpost[variable] += Float64(u[edge])
        end
    end
    hard = BitVector(lpost .< 0.0)
    syndrome = falses(length(graph.checks))
    for (check_index, members) in enumerate(graph.checks)
        parity = false
        @inbounds for variable in members
            parity = xor(parity, hard[variable])
        end
        syndrome[check_index] = parity
    end
    checks = Dict(
        "hard_decision" => hard == state.hard,
        "coded_bit_errors" => count(hard) == state.coded_bit_errors,
        "syndrome_weight" => count(syndrome) == state.syndrome_weight,
        "parity_valid" => (!any(syndrome)) == state.parity_valid,
    )
    if code !== nothing
        checks["jade_syndrome_weight"] =
            BlockB.CORE._syndrome_weight(code, hard) == state.syndrome_weight
    end
    Dict("passed" => all(values(checks)), "checks" => checks)
end

function finite_vector(values)
    all(isfinite, values)
end

function run_arm(config, graph, llr, arm::AbstractString;
                 job_id::AbstractString="unit", channel::AbstractString="unit",
                 frame::Integer=0, code=nothing)
    spec = arm_spec(arm)
    attempts = Int(config["budget"]["update_attempts_per_arm"])
    gradient_config = config["gradient"]
    u = zeros(Float64, BlockB.edge_count(graph))
    iteration_rows = NamedTuple[]
    accepted_updates = 0
    stalls = 0
    non_descent_stalls = 0
    objective_evaluations = 0
    objective_increase_count = 0
    directional_derivative_nonnegative_count = 0
    first_valid_update = 0
    first_exact_update = 0
    first_valid_snapshot = nothing
    first_valid_hard_sha256 = "none"
    first_exact_hard_sha256 = "none"
    absorbing_failure = false
    failure_update = 0
    failure_reason = "none"
    last_finite_objective = BlockB.residual_objective(graph, llr, u, :full)
    unit_identity_exact_all = true
    unit_identity_max_abs_error = 0.0
    unit_assignment_exact_all = true
    unit_assignment_max_abs_error = 0.0
    decision_consistent_all = true

    for update in 1:attempts
        if absorbing_failure
            state = BlockB.decision_state(graph, llr, u, :full)
            decision_gate = independent_decision_gate(graph, llr, u, state, code)
            decision_consistent_all &= Bool(decision_gate["passed"])
            hard_hash = BlockB.vector_sha256(state.hard)
            push!(iteration_rows, (;
                job_id=String(job_id), channel=String(channel), frame=Int(frame),
                arm_id=spec.arm, direction_rule=String(spec.direction),
                step_rule=String(spec.step_rule), update,
                objective_before=last_finite_objective,
                objective_after=last_finite_objective,
                residual_norm_before=sqrt(2last_finite_objective),
                residual_norm_after=sqrt(2last_finite_objective),
                gradient_norm=0.0, direction_norm=0.0,
                directional_derivative=0.0, gradient_evaluated=false,
                step_size=0.0, backtracks=0,
                accepted=false, non_descent=false, absorbing_failure=true,
                finite_trial=false, objective_increased=false,
                unit_identity_exact=true, unit_identity_max_abs_error=0.0,
                unit_assignment_exact=true,
                unit_assignment_max_abs_error=0.0,
                parity_valid=state.parity_valid, exact_word=state.exact_word,
                coded_bit_errors=state.coded_bit_errors,
                syndrome_weight=state.syndrome_weight,
                state_sha256=BlockB.vector_sha256(u),
                hard_word_sha256=hard_hash,
            ))
            continue
        end

        gradient_evaluated = !(spec.direction === :map_minus_state &&
                               spec.step_rule === :unit)
        current = if gradient_evaluated
            BlockB.residual_objective_gradient(graph, llr, u, :full)
        else
            evaluation = BlockB.evaluate_map(graph, llr, u, :full)
            residual = u .- evaluation.output
            (objective=0.5 * BlockB.row_dot(residual, residual),
             gradient=Float64[], residual, evaluation)
        end
        objective_evaluations += 1
        current_finite = isfinite(current.objective) &&
            (!gradient_evaluated || finite_vector(current.gradient)) &&
            finite_vector(current.residual) &&
            finite_vector(current.evaluation.output)
        if !current_finite
            absorbing_failure = true
            failure_update = update
            failure_reason = "nonfinite_current_gradient_or_map"
            state = BlockB.decision_state(graph, llr, u, :full)
            decision_gate = independent_decision_gate(graph, llr, u, state, code)
            decision_consistent_all &= Bool(decision_gate["passed"])
            push!(iteration_rows, (;
                job_id=String(job_id), channel=String(channel), frame=Int(frame),
                arm_id=spec.arm, direction_rule=String(spec.direction),
                step_rule=String(spec.step_rule), update,
                objective_before=last_finite_objective,
                objective_after=last_finite_objective,
                residual_norm_before=sqrt(2last_finite_objective),
                residual_norm_after=sqrt(2last_finite_objective),
                gradient_norm=0.0, direction_norm=0.0,
                directional_derivative=0.0,
                gradient_evaluated=gradient_evaluated,
                step_size=0.0, backtracks=0,
                accepted=false, non_descent=false, absorbing_failure=true,
                finite_trial=false, objective_increased=false,
                unit_identity_exact=true, unit_identity_max_abs_error=0.0,
                unit_assignment_exact=true,
                unit_assignment_max_abs_error=0.0,
                parity_valid=state.parity_valid, exact_word=state.exact_word,
                coded_bit_errors=state.coded_bit_errors,
                syndrome_weight=state.syndrome_weight,
                state_sha256=BlockB.vector_sha256(u),
                hard_word_sha256=BlockB.vector_sha256(state.hard),
            ))
            continue
        end

        objective_before = current.objective
        last_finite_objective = objective_before
        residual_norm_before = norm(current.residual)
        gradient_norm = gradient_evaluated ? norm(current.gradient) : 0.0
        direction = spec.direction === :true_gradient ?
            -current.gradient : current.evaluation.output .- u
        direction_norm = norm(direction)
        directional_derivative = gradient_evaluated ?
            BlockB.row_dot(current.gradient, direction) : 0.0
        gradient_evaluated && directional_derivative >= 0.0 &&
            (directional_derivative_nonnegative_count += 1)
        accepted = false
        non_descent = false
        finite_trial = true
        step_size = 0.0
        backtracks = 0
        objective_after = objective_before
        identity_exact = true
        identity_error = 0.0
        assignment_exact = true
        assignment_error = 0.0

        if spec.step_rule === :armijo
            if spec.direction === :map_minus_state &&
               !(isfinite(directional_derivative) && directional_derivative < 0.0)
                non_descent = true
                stalls += 1
                non_descent_stalls += 1
            else
                alpha = Float64(gradient_config["initial_step"])
                factor = Float64(gradient_config["backtrack_factor"])
                armijo_c = Float64(gradient_config["armijo_c"])
                maximum_backtracks = Int(gradient_config["maximum_backtracks"])
                for backtrack in 0:maximum_backtracks
                    trial = if spec.direction === :true_gradient
                        u .- alpha .* current.gradient
                    elseif backtrack == 0 && alpha == 1.0
                        algebraic_candidate = u .+ direction
                        identity_exact = float_bits_equal(
                            algebraic_candidate, current.evaluation.output)
                        identity_error = maximum(
                            abs, algebraic_candidate - current.evaluation.output;
                            init=0.0)
                        unit_identity_exact_all &= identity_exact
                        unit_identity_max_abs_error = max(
                            unit_identity_max_abs_error, identity_error)
                        candidate = copy(current.evaluation.output)
                        assignment_exact = float_bits_equal(
                            candidate, current.evaluation.output)
                        assignment_error = maximum(
                            abs, candidate - current.evaluation.output; init=0.0)
                        unit_assignment_exact_all &= assignment_exact
                        unit_assignment_max_abs_error = max(
                            unit_assignment_max_abs_error, assignment_error)
                        candidate
                    else
                        u .+ alpha .* direction
                    end
                    trial_finite = finite_vector(trial)
                    trial_objective = trial_finite ?
                        BlockB.residual_objective(graph, llr, trial, :full) : Inf
                    objective_evaluations += trial_finite
                    rhs = objective_before +
                        armijo_c * alpha * directional_derivative
                    if trial_finite && isfinite(trial_objective) &&
                       trial_objective < objective_before &&
                       trial_objective <= rhs
                        u = trial
                        objective_after = trial_objective
                        accepted = true
                        accepted_updates += 1
                        step_size = alpha
                        backtracks = backtrack
                        break
                    end
                    alpha *= factor
                    backtracks = backtrack + 1
                end
                if !accepted
                    stalls += 1
                    objective_after = objective_before
                end
            end
        elseif spec.direction === :map_minus_state
            algebraic_candidate = u .+ direction
            identity_exact = float_bits_equal(
                algebraic_candidate, current.evaluation.output)
            identity_error = maximum(
                abs, algebraic_candidate - current.evaluation.output; init=0.0)
            unit_identity_exact_all &= identity_exact
            unit_identity_max_abs_error = max(
                unit_identity_max_abs_error, identity_error)
            trial = copy(current.evaluation.output)
            assignment_exact = float_bits_equal(trial, current.evaluation.output)
            assignment_error = maximum(
                abs, trial - current.evaluation.output; init=0.0)
            unit_assignment_exact_all &= assignment_exact
            unit_assignment_max_abs_error = max(
                unit_assignment_max_abs_error, assignment_error)
            trial_objective = BlockB.residual_objective(graph, llr, trial, :full)
            objective_evaluations += 1
            if finite_vector(trial) && isfinite(trial_objective)
                u = trial
                objective_after = trial_objective
                last_finite_objective = trial_objective
                accepted = true
                accepted_updates += 1
                step_size = 1.0
            else
                absorbing_failure = true
                failure_update = update
                failure_reason = "nonfinite_map_unit_trial"
                finite_trial = false
            end
        else
            trial = u .- current.gradient
            trial_finite = finite_vector(trial)
            trial_objective = trial_finite ?
                BlockB.residual_objective(graph, llr, trial, :full) : Inf
            objective_evaluations += trial_finite
            if trial_finite && isfinite(trial_objective)
                u = trial
                objective_after = trial_objective
                last_finite_objective = trial_objective
                accepted = true
                accepted_updates += 1
                step_size = 1.0
            else
                absorbing_failure = true
                failure_update = update
                failure_reason = "nonfinite_true_gradient_unit_trial"
                finite_trial = false
            end
        end

        objective_increased = accepted && objective_after > objective_before
        objective_increased && (objective_increase_count += 1)
        accepted && (last_finite_objective = objective_after)
        residual_norm_after = sqrt(max(0.0, 2last_finite_objective))
        state = BlockB.decision_state(graph, llr, u, :full)
        decision_gate = independent_decision_gate(graph, llr, u, state, code)
        decision_consistent_all &= Bool(decision_gate["passed"])
        hard_hash = BlockB.vector_sha256(state.hard)
        if !absorbing_failure && state.parity_valid && first_valid_update == 0
            first_valid_update = update
            first_valid_hard_sha256 = hard_hash
            first_valid_snapshot = (;
                update, hard=copy(state.hard),
                lpost_metric=copy(state.lpost_metric), q=copy(state.q),
                u=copy(u), syndrome_weight=state.syndrome_weight,
            )
        end
        if !absorbing_failure && state.exact_word && first_exact_update == 0
            first_exact_update = update
            first_exact_hard_sha256 = hard_hash
        end
        push!(iteration_rows, (;
            job_id=String(job_id), channel=String(channel), frame=Int(frame),
            arm_id=spec.arm, direction_rule=String(spec.direction),
            step_rule=String(spec.step_rule), update,
            objective_before, objective_after=last_finite_objective,
            residual_norm_before, residual_norm_after, gradient_norm,
            direction_norm, directional_derivative, gradient_evaluated,
            step_size, backtracks,
            accepted, non_descent, absorbing_failure, finite_trial,
            objective_increased, unit_identity_exact=identity_exact,
            unit_identity_max_abs_error=identity_error,
            unit_assignment_exact=assignment_exact,
            unit_assignment_max_abs_error=assignment_error,
            parity_valid=state.parity_valid, exact_word=state.exact_word,
            coded_bit_errors=state.coded_bit_errors,
            syndrome_weight=state.syndrome_weight,
            state_sha256=BlockB.vector_sha256(u), hard_word_sha256=hard_hash,
        ))
    end

    terminal = BlockB.decision_state(graph, llr, u, :full)
    terminal_objective = BlockB.residual_objective(graph, llr, u, :full)
    objective_evaluations += 1
    isfinite(terminal_objective) || (terminal_objective = last_finite_objective)
    terminal_gate = independent_decision_gate(graph, llr, u, terminal, code)
    decision_consistent_all &= Bool(terminal_gate["passed"])
    (; spec, u, terminal, terminal_objective, iteration_rows,
       updates_attempted=attempts, accepted_updates, stalls,
       non_descent_stalls, objective_evaluations, objective_increase_count,
       directional_derivative_nonnegative_count, first_valid_update,
       first_exact_update, first_valid_snapshot, first_valid_hard_sha256,
       first_exact_hard_sha256, absorbing_failure, failure_update,
       failure_reason, unit_identity_exact_all, unit_identity_max_abs_error,
       unit_assignment_exact_all, unit_assignment_max_abs_error,
       decision_consistent_all)
end

function scalar_fields_equal(ours, retained, fields)
    checks = Dict{String,Bool}()
    for field in fields
        left = getproperty(ours, field)
        right = getproperty(retained, field)
        checks[String(field)] = if left isa Float64 && right isa Float64
            float_bits_equal(left, right)
        else
            left == right
        end
    end
    checks
end

function trajectory_reproduction_gate(ours, retained; operator::Symbol)
    checks = Dict{String,Bool}(
        "row_count" => length(ours.iteration_rows) == length(retained.iteration_rows),
        "terminal_state_float_bits" => float_bits_equal(ours.u, retained.u),
        "terminal_objective_float_bits" =>
            float_bits_equal(ours.terminal_objective, retained.terminal_objective),
        "terminal_hard_word" => ours.terminal.hard == retained.terminal.hard,
        "first_valid_update" => ours.first_valid_update == retained.first_valid_update,
        "first_exact_update" => ours.first_exact_update == retained.first_exact_update,
        "accepted_updates" => ours.accepted_updates == retained.accepted_updates,
        "stalls" => ours.stalls == retained.stalls,
        "objective_evaluations" =>
            ours.objective_evaluations == retained.objective_evaluations,
    )
    fields = if operator === :residual_gradient
        (:update, :objective_before, :objective_after, :gradient_norm,
         :step_size, :backtracks, :accepted, :parity_valid, :exact_word,
         :coded_bit_errors, :syndrome_weight, :hard_word_sha256)
    elseif operator === :direct
        (:update, :objective_before, :objective_after, :step_size, :backtracks,
         :accepted, :parity_valid, :exact_word, :coded_bit_errors,
         :syndrome_weight, :hard_word_sha256)
    else
        throw(ArgumentError("unknown retained operator $operator"))
    end
    if checks["row_count"]
        row_checks = [all(values(scalar_fields_equal(ours_row, retained_row, fields)))
                      for (ours_row, retained_row) in
                          zip(ours.iteration_rows, retained.iteration_rows)]
        checks["all_iteration_fields"] = all(row_checks)
    else
        checks["all_iteration_fields"] = false
    end
    Dict("passed" => all(values(checks)), "checks" => checks,
         "operator" => String(operator))
end

# ---------------------------------------------------------------------------
# Case calculation, diagnostics, and causal contrasts
# ---------------------------------------------------------------------------

function arm_frame_row(job_id, input, result, native, native_gate)
    terminal = result.terminal
    (;
        job_id=String(job_id), channel=input.channel, snr_db=input.snr_db,
        frame=input.frame, noise_seed=input.noise_seed,
        llr_sha256=input.llr_sha256, arm_id=result.spec.arm,
        direction_rule=String(result.spec.direction),
        step_rule=String(result.spec.step_rule),
        gradient_evaluated=!(result.spec.direction === :map_minus_state &&
                             result.spec.step_rule === :unit),
        updates_attempted=result.updates_attempted,
        accepted_updates=result.accepted_updates,
        line_search_stalls=result.stalls,
        non_descent_stalls=result.non_descent_stalls,
        absorbing_failure=result.absorbing_failure,
        failure_update=result.failure_update,
        objective_evaluations=result.objective_evaluations,
        first_valid_update=result.first_valid_update,
        first_exact_word_update=result.first_exact_update,
        terminal_outcome_eligible=!result.absorbing_failure,
        terminal_parity_valid=terminal.parity_valid,
        terminal_exact_word=terminal.exact_word,
        terminal_coded_bit_errors=terminal.coded_bit_errors,
        terminal_syndrome_weight=terminal.syndrome_weight,
        terminal_hard_word_sha256=BlockB.vector_sha256(terminal.hard),
        terminal_objective=result.terminal_objective,
        objective_increase_count=result.objective_increase_count,
        directional_derivative_nonnegative_count=
            result.directional_derivative_nonnegative_count,
        unit_identity_exact_all=result.unit_identity_exact_all,
        unit_identity_max_abs_error=result.unit_identity_max_abs_error,
        unit_assignment_exact_all=result.unit_assignment_exact_all,
        unit_assignment_max_abs_error=result.unit_assignment_max_abs_error,
        native_valid=native.valid, native_exact_word=native.exact_word,
        native_iterations=native.iterations,
        native_coded_bit_errors=native.coded_bit_errors,
        native_hard_word_sha256=BlockB.vector_sha256(native.hard),
        native_endpoint_gate_passed=Bool(native_gate["passed"]),
    )
end

function arm_science(row, result)
    Dict(
        "arm_id" => row.arm_id,
        "gradient_evaluated" => row.gradient_evaluated,
        "accepted_updates" => row.accepted_updates,
        "line_search_stalls" => row.line_search_stalls,
        "non_descent_stalls" => row.non_descent_stalls,
        "absorbing_failure" => row.absorbing_failure,
        "failure_update" => row.failure_update,
        "failure_reason" => result.failure_reason,
        "objective_evaluations" => row.objective_evaluations,
        "first_valid_update" => row.first_valid_update,
        "first_exact_word_update" => row.first_exact_word_update,
        "first_valid_hard_word_sha256" => result.first_valid_hard_sha256,
        "first_exact_hard_word_sha256" => result.first_exact_hard_sha256,
        "terminal_outcome_eligible" => row.terminal_outcome_eligible,
        "terminal_parity_valid" => row.terminal_parity_valid,
        "terminal_exact_word" => row.terminal_exact_word,
        "terminal_coded_bit_errors" => row.terminal_coded_bit_errors,
        "terminal_syndrome_weight" => row.terminal_syndrome_weight,
        "terminal_hard_word_sha256" => row.terminal_hard_word_sha256,
        "terminal_objective" => row.terminal_objective,
        "objective_increase_count" => row.objective_increase_count,
        "directional_derivative_nonnegative_count" =>
            row.directional_derivative_nonnegative_count,
        "unit_identity_exact_all" => row.unit_identity_exact_all,
        "unit_identity_max_abs_error" => row.unit_identity_max_abs_error,
        "unit_assignment_exact_all" => row.unit_assignment_exact_all,
        "unit_assignment_max_abs_error" =>
            row.unit_assignment_max_abs_error,
        "decision_and_syndrome_consistent" => result.decision_consistent_all,
    )
end

arm_terminal_success(row) = row.terminal_outcome_eligible &&
    row.terminal_exact_word
arm_ever_success(row) = row.terminal_outcome_eligible &&
    row.first_exact_word_update > 0

function paired_change(rows, from_arm::AbstractString, to_arm::AbstractString)
    grouped = Dict{Tuple{String,Int},Dict{String,Bool}}()
    for row in rows
        key = (row.channel, row.frame)
        get!(grouped, key, Dict{String,Bool}())[row.arm_id] =
            arm_terminal_success(row)
    end
    gained = 0
    lost = 0
    unchanged_success = 0
    unchanged_failure = 0
    for outcomes in values(grouped)
        from = outcomes[from_arm]
        to = outcomes[to_arm]
        if !from && to
            gained += 1
        elseif from && !to
            lost += 1
        elseif from
            unchanged_success += 1
        else
            unchanged_failure += 1
        end
    end
    Dict(
        "from_arm" => String(from_arm), "to_arm" => String(to_arm),
        "case_count" => length(grouped), "gained" => gained, "lost" => lost,
        "net" => gained - lost, "unchanged_success" => unchanged_success,
        "unchanged_failure" => unchanged_failure,
    )
end

function paired_contrasts(rows)
    direction_armijo = paired_change(
        rows, "true_gradient__armijo", "map_minus_state__armijo")
    direction_unit = paired_change(
        rows, "true_gradient__unit", "map_minus_state__unit")
    step_gradient = paired_change(
        rows, "true_gradient__armijo", "true_gradient__unit")
    step_map = paired_change(
        rows, "map_minus_state__armijo", "map_minus_state__unit")
    interaction_direction = Int(direction_unit["net"]) -
        Int(direction_armijo["net"])
    interaction_step = Int(step_map["net"]) - Int(step_gradient["net"])
    Dict(
        "direction_effect_under_armijo" => direction_armijo,
        "direction_effect_under_unit" => direction_unit,
        "step_effect_under_true_gradient" => step_gradient,
        "step_effect_under_map_minus_state" => step_map,
        "interaction_net" => interaction_direction,
        "interaction_parameterizations_equal" =>
            interaction_direction == interaction_step,
    )
end

function exact_two_sided_mcnemar(gained::Integer, lost::Integer)
    gained >= 0 && lost >= 0 || throw(ArgumentError("discordant counts must be nonnegative"))
    discordant = Int(gained + lost)
    discordant == 0 && return 1.0
    lower = min(Int(gained), Int(lost))
    numerator = sum(binomial(BigInt(discordant), k) for k in 0:lower)
    probability = BigFloat(numerator) / BigFloat(big(2)^discordant)
    min(1.0, Float64(2probability))
end

function wilson_interval(successes::Integer, total::Integer, z::Real)
    0 <= successes <= total || throw(ArgumentError("invalid Wilson count"))
    total > 0 || throw(ArgumentError("Wilson interval requires observations"))
    p = Float64(successes) / total
    z2 = Float64(z)^2
    denominator = 1.0 + z2 / total
    center = (p + z2 / (2total)) / denominator
    half = Float64(z) * sqrt(p * (1.0 - p) / total +
                             z2 / (4total^2)) / denominator
    (max(0.0, center - half), min(1.0, center + half))
end

function paired_newcombe_interval(contrast, z::Real)
    n = Int(contrast["case_count"])
    gained = Int(contrast["gained"])
    lost = Int(contrast["lost"])
    both_success = Int(contrast["unchanged_success"])
    both_failure = Int(contrast["unchanged_failure"])
    gained + lost + both_success + both_failure == n ||
        throw(ArgumentError("paired table does not sum to case count"))
    from_success = lost + both_success
    to_success = gained + both_success
    p_from = from_success / n
    p_to = to_success / n
    from_lower, from_upper = wilson_interval(from_success, n, z)
    to_lower, to_upper = wilson_interval(to_success, n, z)
    denominator = sqrt(max(0.0,
        p_from * (1.0 - p_from) * p_to * (1.0 - p_to)))
    correlation = if denominator == 0.0
        0.0
    else
        p11 = both_success / n
        p00 = both_failure / n
        p10 = lost / n
        p01 = gained / n
        clamp((p11 * p00 - p10 * p01) / denominator, -1.0, 1.0)
    end
    difference = p_to - p_from
    lower_radius = sqrt(max(0.0,
        (p_to - to_lower)^2 + (from_upper - p_from)^2 -
        2correlation * (p_to - to_lower) * (from_upper - p_from)))
    upper_radius = sqrt(max(0.0,
        (to_upper - p_to)^2 + (p_from - from_lower)^2 -
        2correlation * (to_upper - p_to) * (p_from - from_lower)))
    Dict(
        "estimate" => difference,
        "lower" => max(-1.0, difference - lower_radius),
        "upper" => min(1.0, difference + upper_radius),
        "correlation" => correlation,
        "method" => "Newcombe paired score interval",
    )
end

function holm_adjust(raw_pvalues::Dict{String,Float64}, alpha::Real)
    ordered = sort!(collect(raw_pvalues); by=pair -> (last(pair), first(pair)))
    adjusted = Dict{String,Float64}()
    ranks = Dict{String,Int}()
    running = 0.0
    family_size = length(ordered)
    for (rank, pair) in enumerate(ordered)
        name, pvalue = pair
        running = max(running, min(1.0, (family_size - rank + 1) * pvalue))
        adjusted[name] = running
        ranks[name] = rank
    end
    Dict(name => Dict(
        "raw_p_value" => raw_pvalues[name],
        "holm_adjusted_p_value" => adjusted[name],
        "holm_rank" => ranks[name],
        "reject_familywise_null" => adjusted[name] <= Float64(alpha),
    ) for name in keys(raw_pvalues))
end

function interaction_diagnostics(rows)
    grouped = Dict{Tuple{String,Int},Dict{String,Int}}()
    for row in rows
        key = (row.channel, row.frame)
        get!(grouped, key, Dict{String,Int}())[row.arm_id] =
            Int(arm_terminal_success(row))
    end
    values_by_case = Dict{String,Int}()
    counts = Dict(string(value) => 0 for value in -2:2)
    for (key, outcomes) in sort!(collect(grouped); by=first)
        interaction =
            (outcomes["map_minus_state__unit"] -
             outcomes["true_gradient__unit"]) -
            (outcomes["map_minus_state__armijo"] -
             outcomes["true_gradient__armijo"])
        case_id = first(key) * ":" * string(last(key))
        values_by_case[case_id] = interaction
        counts[string(interaction)] += 1
    end
    nonzero = count(!=(0), values(values_by_case))
    net = sum(values(values_by_case))
    Dict(
        "case_count" => length(grouped),
        "per_case" => values_by_case,
        "value_counts" => counts,
        "nonzero_case_count" => nonzero,
        "net" => net,
        "mean" => isempty(grouped) ? 0.0 : net / length(grouped),
        "material_under_registered_rule" => nonzero > 0,
        "additive_attribution_allowed" => nonzero == 0,
    )
end

function inference_by_channel(rows, config, job_id::AbstractString)
    validation_only = Bool(config["jobs"][String(job_id)]["validation_only"])
    validation_only && return Dict(
        "applied" => false,
        "reason" => "validation-only retained cases do not enter inference",
    )
    inference = config["inference"]
    alpha = Float64(inference["familywise_alpha"])
    confidence = Float64(inference["simultaneous_interval_confidence_level"])
    z = Float64(inference["simultaneous_interval_z"])
    families = Dict{String,Any}()
    for channel in sort!(unique(row.channel for row in rows))
        selected = [row for row in rows if row.channel == channel]
        contrasts = paired_contrasts(selected)
        contrast_names = (
            "direction_effect_under_armijo",
            "direction_effect_under_unit",
            "step_effect_under_true_gradient",
            "step_effect_under_map_minus_state",
        )
        raw = Dict(name => exact_two_sided_mcnemar(
            Int(contrasts[name]["gained"]), Int(contrasts[name]["lost"]))
            for name in contrast_names)
        holm = holm_adjust(raw, alpha)
        records = Dict{String,Any}()
        for name in contrast_names
            record = deepcopy(contrasts[name])
            merge!(record, holm[name])
            record["paired_risk_difference_interval"] =
                paired_newcombe_interval(record, z)
            records[name] = record
        end
        interaction = interaction_diagnostics(selected)
        families[channel] = Dict(
            "case_count" => length(selected) ÷ length(ARMS),
            "familywise_alpha" => alpha,
            "contrast_count" => length(contrast_names),
            "simultaneous_interval_confidence_level" => confidence,
            "confirmatory" => job_id in (JOB_ORDER[3], JOB_ORDER[4]),
            "contrasts" => records,
            "interaction" => interaction,
            "additive_attribution_allowed" =>
                Bool(interaction["additive_attribution_allowed"]),
        )
    end
    Dict(
        "applied" => true,
        "pooled_across_snr" => false,
        "pooled_across_jobs" => false,
        "families" => families,
    )
end

function aggregate_rows(rows)
    aggregates = Dict{String,Any}()
    for arm in ARMS
        selected = [row for row in rows if row.arm_id == arm]
        aggregates[arm] = Dict(
            "cases" => length(selected),
            "ever_exact_word_count" => count(arm_ever_success, selected),
            "ever_parity_valid_count" => count(
                row -> row.terminal_outcome_eligible && row.first_valid_update > 0,
                selected),
            "terminal_exact_word_count" => count(
                arm_terminal_success, selected),
            "terminal_parity_valid_count" => count(
                row -> row.terminal_outcome_eligible && row.terminal_parity_valid,
                selected),
            "absorbing_failure_count" => count(row -> row.absorbing_failure, selected),
            "accepted_updates_total" => sum(row.accepted_updates for row in selected),
            "line_search_stalls_total" =>
                sum(row.line_search_stalls for row in selected),
            "non_descent_stalls_total" =>
                sum(row.non_descent_stalls for row in selected),
            "objective_increase_total" =>
                sum(row.objective_increase_count for row in selected),
        )
    end
    aggregates
end

function baseline_gates(config, config_path, native, built)
    source = source_gate(config, config_path)
    validation_input = generate_input(config, native, built.code, "six_db", 20001)
    toy = BlockB.toy_derivative_gate(config)
    long = BlockB.long_directional_gate(config, built.graph, validation_input.llr)
    graph = BlockB.graph_sha256(built.code.check_vars) ==
        String(config["code"]["graph_sha256"])
    Dict(
        "passed" => Bool(source["passed"]) && graph && Bool(toy["passed"]) &&
            Bool(long["passed"]),
        "source" => source,
        "graph_hash" => graph,
        "toy_finite_difference_and_vjp" => toy,
        "long_finite_difference_and_vjp" => long,
    )
end

function calculate_job(config, config_path::AbstractString, job_id::AbstractString;
                       pass_name::AbstractString="primary",
                       progress_callback=(completed, total)->nothing)
    native = load_native(config, config_path)
    built = make_code(config, native)
    baseline = baseline_gates(config, config_path, native, built)
    Bool(baseline["passed"]) ||
        throw(ArgumentError("source, graph, derivative, or VJP gate failed"))
    validation_only = Bool(config["jobs"][String(job_id)]["validation_only"])
    specs = job_case_specs(config, job_id)
    frame_rows = NamedTuple[]
    iteration_rows = NamedTuple[]
    case_science = Dict{String,Any}[]
    endpoint_gates_passed = true
    unit_identity_passed = true
    decision_gates_passed = true
    gradient_reproduction_passed = true
    direct_reproduction_passed = true
    oracle_prefix_passed = true

    for (position, (channel, frame)) in enumerate(specs)
        input = generate_input(config, native, built.code, channel, frame)
        native_result = BlockB.native_decode(built.modem, built.code, input.llr)
        results = Dict{String,Any}()
        for arm in ARMS
            results[arm] = run_arm(
                config, built.graph, input.llr, arm;
                job_id, channel, frame, code=built.code)
            append!(iteration_rows, results[arm].iteration_rows)
        end
        retained_direct_30 = BlockB.run_arm(
            config, built.graph, input.llr, "full__direct";
            frame, stage=String(job_id))
        prefix_gate = trajectory_reproduction_gate(
            results["map_minus_state__unit"], retained_direct_30;
            operator=:direct)
        oracle_prefix_passed &= Bool(prefix_gate["passed"])
        oracle_config = deepcopy(config)
        oracle_config["budget"]["update_attempts_per_arm"] = Int(
            config["native_endpoint_gate"]["maximum_message_passing_iterations"])
        direct_oracle_80 = BlockB.run_arm(
            oracle_config, built.graph, input.llr, "full__direct";
            frame, stage=String(job_id) * "__native_oracle")
        endpoint = BlockB.endpoint_gate(
            built.graph, direct_oracle_80, native_result)
        endpoint_gates_passed &= Bool(endpoint["passed"])
        unit_identity_passed &=
            results["map_minus_state__unit"].unit_assignment_exact_all &&
            results["map_minus_state__unit"].unit_assignment_max_abs_error == 0.0
        decision_gates_passed &= all(
            result.decision_consistent_all for result in values(results))

        reproduction = Dict{String,Any}()
        if validation_only
            retained_gradient = BlockB.run_arm(
                config, built.graph, input.llr, "full__residual_gradient";
                frame, stage=String(job_id))
            gradient_gate = trajectory_reproduction_gate(
                results["true_gradient__armijo"], retained_gradient;
                operator=:residual_gradient)
            direct_gate = prefix_gate
            gradient_reproduction_passed &= Bool(gradient_gate["passed"])
            direct_reproduction_passed &= Bool(direct_gate["passed"])
            reproduction["true_gradient_armijo_equals_retained"] = gradient_gate
            reproduction["map_unit_equals_retained_direct"] = direct_gate
        end

        rows = NamedTuple[]
        for arm in ARMS
            row = arm_frame_row(job_id, input, results[arm], native_result, endpoint)
            push!(rows, row)
            push!(frame_rows, row)
        end
        case_record = Dict{String,Any}(
            "channel" => channel, "snr_db" => input.snr_db,
            "frame" => frame, "noise_seed" => input.noise_seed,
            "llr_sha256" => input.llr_sha256,
            "received_sha256" => input.received_sha256,
            "unit_noise_sha256" => input.unit_noise_sha256,
            "native" => Dict(
                "valid" => native_result.valid,
                "exact_word" => native_result.exact_word,
                "iterations" => native_result.iterations,
                "coded_bit_errors" => native_result.coded_bit_errors,
                "hard_word_sha256" => BlockB.vector_sha256(native_result.hard),
            ),
            "native_endpoint_gate" => endpoint,
            "direct_oracle_80" => Dict(
                "first_valid_update" => direct_oracle_80.first_valid_update,
                "first_exact_word_update" => direct_oracle_80.first_exact_update,
                "first_valid_exact_word" =>
                    direct_oracle_80.first_valid_snapshot !== nothing &&
                    !any(direct_oracle_80.first_valid_snapshot.hard),
                "first_valid_hard_word_sha256" =>
                    direct_oracle_80.first_valid_hard_sha256,
                "terminal_hard_word_sha256" =>
                    BlockB.vector_sha256(direct_oracle_80.terminal.hard),
            ),
            "map_unit_first30_oracle_gate" => prefix_gate,
            "arms" => Dict(row.arm_id => arm_science(row, results[row.arm_id])
                           for row in rows),
        )
        validation_only && (case_record["retained_reproduction"] = reproduction)
        push!(case_science, case_record)
        progress_callback(position, length(specs))
    end

    frames_hash = scientific_sha256(frame_rows)
    iterations_hash = scientific_sha256(iteration_rows)
    channels = sort!(unique(row.channel for row in frame_rows))
    aggregates_by_channel = Dict(
        channel => aggregate_rows([row for row in frame_rows if row.channel == channel])
        for channel in channels)
    contrasts_by_channel = Dict(
        channel => paired_contrasts(
            [row for row in frame_rows if row.channel == channel])
        for channel in channels)
    paired_inference = inference_by_channel(frame_rows, config, job_id)
    gates = Dict(
        "baseline_source_graph_derivatives" => Bool(baseline["passed"]),
        "native_exact_sum_product_oracle_endpoint_equal" =>
            endpoint_gates_passed,
        "map_unit_first30_oracle_equal" => oracle_prefix_passed,
        "map_unit_assignment_exact" => unit_identity_passed,
        "hard_decision_and_syndrome_consistent" => decision_gates_passed,
        "true_gradient_armijo_retained_reproduction" =>
            validation_only ? gradient_reproduction_passed : true,
        "map_unit_retained_direct_reproduction" =>
            validation_only ? direct_reproduction_passed : true,
        "absorbing_failure_protocol_applied" => true,
    )
    correctness_passed = all(values(gates))
    science = Dict(
        "schema_version" => SCIENCE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => String(job_id),
        "validation_only" => validation_only,
        "case_count" => length(specs),
        "arm_order" => collect(ARMS),
        "update_attempts_per_arm" =>
            Int(config["budget"]["update_attempts_per_arm"]),
        "frames_sha256" => frames_hash,
        "iterations_sha256" => iterations_hash,
        "gates" => gates,
        "baseline_validation" => baseline,
        "cases" => case_science,
        "aggregates" => aggregates_by_channel,
        "paired_contrasts" => contrasts_by_channel,
        "paired_inference" => paired_inference,
        "complete_valid" => correctness_passed,
    )
    (; science, frame_rows, iteration_rows, gates, correctness_passed)
end

# ---------------------------------------------------------------------------
# Artifact contract and command line
# ---------------------------------------------------------------------------

function frame_columns()
    (
        :job_id, :channel, :snr_db, :frame, :noise_seed, :llr_sha256,
        :arm_id, :direction_rule, :step_rule, :gradient_evaluated,
        :updates_attempted,
        :accepted_updates, :line_search_stalls, :non_descent_stalls,
        :absorbing_failure, :failure_update, :objective_evaluations,
        :first_valid_update, :first_exact_word_update,
        :terminal_outcome_eligible, :terminal_parity_valid,
        :terminal_exact_word, :terminal_coded_bit_errors,
        :terminal_syndrome_weight, :terminal_hard_word_sha256,
        :terminal_objective, :objective_increase_count,
        :directional_derivative_nonnegative_count,
        :unit_identity_exact_all, :unit_identity_max_abs_error,
        :unit_assignment_exact_all, :unit_assignment_max_abs_error,
        :native_valid, :native_exact_word, :native_iterations,
        :native_coded_bit_errors, :native_hard_word_sha256,
        :native_endpoint_gate_passed,
    )
end

function iteration_columns()
    (
        :job_id, :channel, :frame, :arm_id, :direction_rule, :step_rule,
        :update, :objective_before, :objective_after, :residual_norm_before,
        :residual_norm_after, :gradient_norm, :direction_norm,
        :directional_derivative, :gradient_evaluated, :step_size,
        :backtracks, :accepted,
        :non_descent, :absorbing_failure, :finite_trial,
        :objective_increased, :unit_identity_exact,
        :unit_identity_max_abs_error, :unit_assignment_exact,
        :unit_assignment_max_abs_error, :parity_valid, :exact_word,
        :coded_bit_errors, :syndrome_weight, :state_sha256,
        :hard_word_sha256,
    )
end

function csv_value(value)
    value isa Bool && return lowercase(string(value))
    value isa AbstractFloat && return @sprintf("%.17g", value)
    text = string(value)
    occursin(r"[,\"\n\r]", text) || return text
    "\"" * replace(text, "\"" => "\"\"") * "\""
end

function write_csv(path::AbstractString, rows, columns)
    open(path, "w") do io
        println(io, join(String.(columns), ","))
        for row in rows
            println(io, join((csv_value(getproperty(row, column))
                              for column in columns), ","))
        end
    end
end

function write_toml(path::AbstractString, payload)
    open(path, "w") do io
        TOML.print(io, payload; sorted=true)
    end
end

function endpoint_payload(result, job_id::AbstractString)
    science = result.science
    cases = science["cases"]
    case_ids = [(String(case["channel"]), Int(case["frame"])) for case in cases]
    llr_ids = [(String(case["channel"]), Int(case["frame"]),
                String(case["llr_sha256"])) for case in cases]
    native_pairs = [(String(case["channel"]), Int(case["frame"]),
                     String(case["native"]["hard_word_sha256"]))
                    for case in cases]
    oracle_pairs = Tuple{String,Int,String}[]
    for case in cases
        oracle = case["direct_oracle_80"]
        digest = Int(oracle["first_valid_update"]) > 0 ?
            String(oracle["first_valid_hard_word_sha256"]) :
            String(oracle["terminal_hard_word_sha256"])
        push!(oracle_pairs,
              (String(case["channel"]), Int(case["frame"]), digest))
    end
    aggregates_by_channel = science["aggregates"]
    arm_success_counts = Dict(
        arm => sum(Int(aggregates[arm]["terminal_exact_word_count"])
                   for aggregates in values(aggregates_by_channel)) for arm in ARMS)
    failure_counts = Dict(
        arm => sum(Int(aggregates[arm]["absorbing_failure_count"])
                   for aggregates in values(aggregates_by_channel)) for arm in ARMS)
    native_successes = count(case -> Bool(case["native"]["exact_word"]), cases)
    oracle_successes = count(
        case -> Bool(case["direct_oracle_80"]["first_valid_exact_word"]), cases)
    map_fixed30_successes = arm_success_counts["map_minus_state__unit"]
    native_equal = Bool(
        result.gates["native_exact_sum_product_oracle_endpoint_equal"]) &&
        native_successes == oracle_successes &&
        scientific_sha256(native_pairs) == scientific_sha256(oracle_pairs)
    prefix_equal = Bool(result.gates["map_unit_first30_oracle_equal"])
    assignment_exact = Bool(result.gates["map_unit_assignment_exact"])
    Dict(
        "schema_version" => ENDPOINT_GATE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => String(job_id),
        "status" => native_equal && prefix_equal && assignment_exact ? "pass" : "fail",
        "case_count" => length(cases),
        "case_ids_sha256" => scientific_sha256(case_ids),
        "channel_llrs_sha256" => scientific_sha256(llr_ids),
        "native_bp_successes" => native_successes,
        "direct_oracle_80_successes" => oracle_successes,
        "native_bp_direct_oracle_equal" => native_equal,
        "map_unit_fixed30_successes" => map_fixed30_successes,
        "map_unit_first30_oracle_equal" => prefix_equal,
        "unit_assignment_exact" => assignment_exact,
        "native_hard_words_sha256" => scientific_sha256(native_pairs),
        "direct_oracle_80_hard_words_sha256" =>
            scientific_sha256(oracle_pairs),
        "arm_success_counts" => arm_success_counts,
        "absorbing_failure_counts" => failure_counts,
    )
end

function result_manifest(root::AbstractString)
    names = sort!(filter(name -> name != "MANIFEST.sha256", readdir(root)))
    join((file_sha256(joinpath(root, name)) * "  " * name for name in names),
         "\n") * "\n"
end

function write_atomic_result(output::AbstractString, config_path::AbstractString,
                             job_id::AbstractString, primary, replay, timing)
    ispath(output) && throw(ArgumentError("refusing to overwrite $output"))
    write_started = time_ns()
    parent = dirname(abspath(output))
    mkpath(parent)
    staging = mktempdir(parent; prefix="." * basename(output) * ".staging-")

    science_path = joinpath(staging, "science.json")
    science_text = BlockB.canonical_json(primary.science) * "\n"
    replay_science_text = BlockB.canonical_json(replay.science) * "\n"
    open(science_path, "w") do io
        write(io, science_text)
    end
    frames_path = joinpath(staging, "frames.csv")
    iterations_path = joinpath(staging, "iterations.csv")
    write_csv(frames_path, primary.frame_rows, frame_columns())
    write_csv(iterations_path, primary.iteration_rows, iteration_columns())

    primary_science_hash = text_sha256(science_text)
    replay_science_hash = text_sha256(replay_science_text)
    primary_frames_hash = scientific_sha256(primary.frame_rows)
    replay_frames_hash = scientific_sha256(replay.frame_rows)
    primary_iterations_hash = scientific_sha256(primary.iteration_rows)
    replay_iterations_hash = scientific_sha256(replay.iteration_rows)
    deterministic = primary_science_hash == replay_science_hash &&
        primary_frames_hash == replay_frames_hash &&
        primary_iterations_hash == replay_iterations_hash
    correctness = Bool(primary.correctness_passed) &&
        Bool(replay.correctness_passed)
    paths = source_paths(load_config(config_path), config_path)
    validation_only = Bool(primary.science["validation_only"])
    gate = Dict(
        "schema_version" => JOB_GATE_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => String(job_id),
        "job_kind" => validation_only ? "validation" : "science",
        "status" => correctness && deterministic ? "pass" : "fail",
        "validation_only" => validation_only,
        "correctness_passed" => correctness,
        "deterministic_replay_passed" => deterministic,
        "config_sha256" => file_sha256(config_path),
        "block_b_runner_sha256" => file_sha256(paths["block_b_runner"]),
        "primary_science_sha256" => primary_science_hash,
        "replay_science_sha256" => replay_science_hash,
        "primary_frames_sha256" => primary_frames_hash,
        "replay_frames_sha256" => replay_frames_hash,
        "primary_iterations_sha256" => primary_iterations_hash,
        "replay_iterations_sha256" => replay_iterations_hash,
    )
    job_gate_path = joinpath(staging, "job_gate.toml")
    write_toml(job_gate_path, gate)

    endpoint_hash = ""
    if !validation_only
        primary_endpoint = endpoint_payload(primary, job_id)
        replay_endpoint = endpoint_payload(replay, job_id)
        primary_endpoint == replay_endpoint ||
            throw(ArgumentError("endpoint replay differs"))
        endpoint_path = joinpath(staging, "endpoint_gate.toml")
        write_toml(endpoint_path, primary_endpoint)
        endpoint_hash = file_sha256(endpoint_path)
    end

    timing["write_seconds"] = (time_ns() - write_started) / 1.0e9
    timing["total_seconds"] = Float64(timing["primary_seconds"]) +
        Float64(timing["replay_seconds"]) + Float64(timing["write_seconds"])
    timing_path = joinpath(staging, "timing.toml")
    write_toml(timing_path, timing)
    completion = Dict(
        "schema_version" => COMPLETION_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => String(job_id),
        "status" => correctness && deterministic ? "complete_valid" : "invalid",
        "correctness_passed" => correctness,
        "deterministic_replay_passed" => deterministic,
        "science_sha256" => file_sha256(science_path),
        "frames_sha256" => file_sha256(frames_path),
        "iterations_sha256" => file_sha256(iterations_path),
        "job_gate_sha256" => file_sha256(job_gate_path),
        "endpoint_gate_sha256" => endpoint_hash,
    )
    write_toml(joinpath(staging, "COMPLETED.toml"), completion)
    open(joinpath(staging, "MANIFEST.sha256"), "w") do io
        write(io, result_manifest(staging))
    end
    Base.Filesystem.rename(staging, abspath(output))
    completion
end

function progress_reporter(job_id, pass_name)
    (completed, total) -> begin
        println("progress job=$job_id pass=$pass_name cases=$completed/$total")
        flush(stdout)
    end
end

function run_job(job_id::AbstractString; config_path::AbstractString=DEFAULT_CONFIG,
                 output::AbstractString)
    job_id in JOB_ORDER || throw(ArgumentError("unknown job ID $job_id"))
    config = load_config(config_path)
    enforce_thread_environment(config)
    total_started = time_ns()
    primary_started = time_ns()
    primary = calculate_job(
        config, config_path, job_id; pass_name="primary",
        progress_callback=progress_reporter(job_id, "primary"))
    primary_seconds = (time_ns() - primary_started) / 1.0e9
    replay_started = time_ns()
    replay = calculate_job(
        config, config_path, job_id; pass_name="replay",
        progress_callback=progress_reporter(job_id, "replay"))
    replay_seconds = (time_ns() - replay_started) / 1.0e9

    scientific_sha256(primary.science) == scientific_sha256(replay.science) ||
        throw(ArgumentError("primary and replay science differ"))
    scientific_sha256(primary.frame_rows) == scientific_sha256(replay.frame_rows) ||
        throw(ArgumentError("primary and replay frame tables differ"))
    scientific_sha256(primary.iteration_rows) ==
        scientific_sha256(replay.iteration_rows) ||
        throw(ArgumentError("primary and replay iteration tables differ"))

    frame_count = length(job_case_specs(config, job_id))
    arm_count = length(ARMS)
    timing = Dict(
        "schema_version" => TIMING_SCHEMA,
        "experiment_id" => EXPERIMENT_ID,
        "job_id" => String(job_id),
        "frame_count" => frame_count,
        "arm_count" => arm_count,
        "update_attempts_per_arm" =>
            Int(config["budget"]["update_attempts_per_arm"]),
        "pass_count" => Int(config["budget"]["scientific_passes"]),
        "primary_seconds" => primary_seconds,
        "replay_seconds" => replay_seconds,
        "write_seconds" => 0.0,
        "total_seconds" => (time_ns() - total_started) / 1.0e9,
        "seconds_per_case_arm" =>
            (primary_seconds + replay_seconds) / (2frame_count * arm_count),
    )
    completion = write_atomic_result(
        output, abspath(config_path), String(job_id), primary, replay, timing)
    completion_status = completion["status"]
    completion_science_sha256 = completion["science_sha256"]
    println("$completion_status job=$job_id " *
            "science_sha256=$completion_science_sha256")
    (; completion, output=abspath(output))
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
    length(arguments) >= 2 || throw(ArgumentError(
        "usage: exact_map_update.jl job JOB_ID --config PATH --output DIR"))
    arguments[1] == "job" ||
        throw(ArgumentError("only the job command is supported"))
    job_id = arguments[2]
    options = parse_options(arguments[3:end])
    for required in ("config", "output")
        haskey(options, required) ||
            throw(ArgumentError("--$required is required"))
    end
    run_job(job_id; config_path=options["config"], output=options["output"])
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

end # module
