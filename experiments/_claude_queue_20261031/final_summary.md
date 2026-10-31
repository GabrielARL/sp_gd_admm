# Final summary 2026-10-31T09:19:30Z

## /home/gabiel/Documents/GitHub/sp_gd_admm-claude-controls-20261031/experiments/rq2_gd_offset_null_001/results/2026-10-31_anchor_v1
anchor_expansion_authorized = true
completed_utc = "2026-10-31T05:43:21.067"
correctness_passed = true
deterministic_replay_passed = true
experiment_id = "RQ2-GD-OFFSET-NULL-001"
schema_version = "rq2-gd-offset-null-001/completion-v1"
science_sha256 = "9941227d6ea64ada36918cbf8471a1a31c166a4df784a86e4c9b5127280abc61"
stage = "anchor"
status = "complete_valid"

endpoint,contrast,treatment,reference,pairs,both_success,treatment_only_success,reference_only_success,both_failure,treatment_successes,reference_successes,risk_difference,interval_lower,interval_upper,mcnemar_p,holm_p
transmitted_word_equal,reference_vs_control,reference,control,24,15,7,0,2,22,15,0.29166666666666669,NaN,NaN,NaN,NaN
transmitted_word_equal,permuted_vs_control,permuted,control,24,10,0,5,9,10,15,-0.20833333333333334,NaN,NaN,NaN,NaN
transmitted_word_equal,frozen_vs_control,frozen,control,24,15,7,0,2,22,15,0.29166666666666669,NaN,NaN,NaN,NaN
transmitted_word_equal,reference_vs_permuted,reference,permuted,24,10,12,0,2,22,10,0.5,NaN,NaN,NaN,NaN
transmitted_word_equal,reference_vs_frozen,reference,frozen,24,22,0,0,2,22,22,0,NaN,NaN,NaN,NaN
parity_valid,reference_vs_control,reference,control,24,15,7,0,2,22,15,0.29166666666666669,NaN,NaN,NaN,NaN
parity_valid,permuted_vs_control,permuted,control,24,10,0,5,9,10,15,-0.20833333333333334,NaN,NaN,NaN,NaN
parity_valid,frozen_vs_control,frozen,control,24,15,7,0,2,22,15,0.29166666666666669,NaN,NaN,NaN,NaN
parity_valid,reference_vs_permuted,reference,permuted,24,10,12,0,2,22,10,0.5,NaN,NaN,NaN,NaN
parity_valid,reference_vs_frozen,reference,frozen,24,22,0,0,2,22,22,0,NaN,NaN,NaN,NaN

## /home/gabiel/Documents/GitHub/sp_gd_admm-claude-controls-20261031/experiments/rq2_gd_offset_null_001/results/2026-10-31_heldout_v1
anchor_expansion_authorized = false
completed_utc = "2026-10-31T09:18:17.712"
correctness_passed = true
deterministic_replay_passed = true
experiment_id = "RQ2-GD-OFFSET-NULL-001"
schema_version = "rq2-gd-offset-null-001/completion-v1"
science_sha256 = "2c298d36f34fe03ba930e78bdd2e84ea16436899ba6de9764d8741e250c7266e"
stage = "heldout"
status = "complete_valid"

endpoint,contrast,treatment,reference,pairs,both_success,treatment_only_success,reference_only_success,both_failure,treatment_successes,reference_successes,risk_difference,interval_lower,interval_upper,mcnemar_p,holm_p
transmitted_word_equal,reference_vs_control,reference,control,200,107,56,0,37,163,107,0.28000000000000003,0.18748030241144506,0.36676479097700293,2.7755575615628914e-17,1.6653345369377348e-16
transmitted_word_equal,permuted_vs_control,permuted,control,200,73,0,34,93,73,107,-0.17000000000000001,-0.24218996688673144,-0.093078838422791313,1.1641532182693481e-10,4.6566128730773926e-10
transmitted_word_equal,frozen_vs_control,frozen,control,200,107,58,0,35,165,107,0.28999999999999998,0.19642594238027328,0.37766798085730641,6.9388939039072284e-18,5.5511151231257827e-17
transmitted_word_equal,reference_vs_permuted,reference,permuted,200,73,90,0,37,163,73,0.45000000000000001,0.34260687691784975,0.53978345812324924,1.6155871338926322e-27,1.6155871338926322e-26
transmitted_word_equal,reference_vs_frozen,reference,frozen,200,163,0,2,35,163,165,-0.01,-0.044970949740533131,0.022909590182547235,0.5,1
parity_valid,reference_vs_control,reference,control,200,107,56,0,37,163,107,0.28000000000000003,0.18748030241144506,0.36676479097700293,2.7755575615628914e-17,1.6653345369377348e-16
parity_valid,permuted_vs_control,permuted,control,200,73,0,34,93,73,107,-0.17000000000000001,-0.24218996688673144,-0.093078838422791313,1.1641532182693481e-10,4.6566128730773926e-10
parity_valid,frozen_vs_control,frozen,control,200,107,58,0,35,165,107,0.28999999999999998,0.19642594238027328,0.37766798085730641,6.9388939039072284e-18,5.5511151231257827e-17
parity_valid,reference_vs_permuted,reference,permuted,200,73,90,0,37,163,73,0.45000000000000001,0.34260687691784975,0.53978345812324924,1.6155871338926322e-27,1.6155871338926322e-26
parity_valid,reference_vs_frozen,reference,frozen,200,163,0,2,35,163,165,-0.01,-0.044970949740533131,0.022909590182547235,0.5,1

## /home/gabiel/Documents/GitHub/sp_gd_admm-claude-controls-20261031/experiments/rq2_native_gap_001/results/2026-10-31_six_v2
completed_utc = "2026-10-31T06:10:34.927"
correctness_passed = true
deterministic_replay_passed = true
experiment_id = "RQ2-NATIVE-GAP-001"
schema_version = "rq2-native-gap-001/completion-v1"
science_sha256 = "60815a04d607419c4f1f72807800fbb5613ca7ef75e9963dc713a83348ad1411"
stage = "six"
status = "complete_valid"

endpoint,pairs,both_success,bp_only_success,gd_only_success,both_failure,bp_successes,gd_successes,risk_difference_bp_minus_gd,interval_lower,interval_upper,mcnemar_p,holm_p
transmitted_word_equal,200,107,93,0,0,200,107,0.46500000000000002,0.38398184723786494,0.54393897211582043,2.0194839173657902e-28,4.0389678347315804e-28
parity_valid,200,107,93,0,0,200,107,0.46500000000000002,0.38398184723786494,0.54393897211582043,2.0194839173657902e-28,4.0389678347315804e-28

## /home/gabiel/Documents/GitHub/sp_gd_admm-claude-controls-20261031/experiments/rq2_native_gap_001/results/2026-10-31_profile_v2
completed_utc = "2026-10-31T06:26:18.669"
correctness_passed = true
deterministic_replay_passed = true
experiment_id = "RQ2-NATIVE-GAP-001"
schema_version = "rq2-native-gap-001/completion-v1"
science_sha256 = "892168599d206477bae9081abd499f873e063873ee232a1e28d013fa9848e9da"
stage = "profile"
status = "complete_valid"

bp_saturated_on_grid = true
selected_second_esn0_db = 1.5

[profile."1.5"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 0
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 0

[profile."2.0"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 0
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 0

[profile."2.5"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 0
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 0

[profile."3.0"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 0
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 0

[profile."3.5"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 0
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 0

[profile."4.0"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 0
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 0

[profile."5.0"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 1
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 1

[profile."6.0"]
bp_exact_sum_product = 24
frames = 24
gd_native_projected = 15
parity_valid_bp_exact_sum_product = 24
parity_valid_gd_native_projected = 15

## /home/gabiel/Documents/GitHub/sp_gd_admm-claude-controls-20261031/experiments/rq2_native_gap_001/results/2026-10-31_second_v2
completed_utc = "2026-10-31T06:44:57.947"
correctness_passed = true
deterministic_replay_passed = true
experiment_id = "RQ2-NATIVE-GAP-001"
schema_version = "rq2-native-gap-001/completion-v1"
science_sha256 = "28a262739fddbb5428c99631510670a6a36b7c49214f061753a8bdf69ae75739"
stage = "second"
status = "complete_valid"

endpoint,pairs,both_success,bp_only_success,gd_only_success,both_failure,bp_successes,gd_successes,risk_difference_bp_minus_gd,interval_lower,interval_upper,mcnemar_p,holm_p
transmitted_word_equal,200,0,200,0,0,200,0,1,0.96534624278665548,1,1.2446030555722283e-60,2.4892061111444567e-60
parity_valid,200,0,200,0,0,200,0,1,0.96534624278665548,1,1.2446030555722283e-60,2.4892061111444567e-60
