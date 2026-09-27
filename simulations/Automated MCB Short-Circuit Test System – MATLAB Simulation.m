%% ============================================================
%  AUTOMATED HIGH-CURRENT MCB TEST SYSTEM
%  MATLAB SIMULATION  --  CORRECTED / WORKING VERSION
%
%  Project:
%  Automated High-Current Short-Circuit Test System
%  for IEC 60898-1:2015 MCB Compliance
%
%  This model demonstrates:
%       1. Programmable R-L impedance bank
%       2. Automatic impedance selection
%       3. Short-circuit/fault application
%       4. MCB trip simulation
%       5. Simulated high-speed DAQ
%       6. RMS current measurement
%       7. Power-factor measurement
%       8. Automatic PASS/FAIL
%       9. Automatic report generation
%
%  NOTE:
%  This is a simulation/demo model. The acceptance limits below
%  are configurable simulation criteria and are NOT an IEC
%  certification determination.
%
%% ============================================================
%  FIXES APPLIED IN THIS CORRECTED VERSION (vs. original draft)
%  ------------------------------------------------------------
%  1. DAQ RMS loop VECTORIZED (movmean). The original per-sample
%     for-loop recomputed a ~40,000-sample window at every one of
%     ~280,000 samples (~1e10 floating point ops) -- it would
%     take an extremely long time to finish, effectively making
%     the script unusable as written.
%
%  2. Fixed an invalid / negative measurement window. With the
%     original defaults (fault_time=10ms, trip_delay=5ms, so
%     trip_time=15ms) and a 20ms AC cycle, the old code computed
%     measurement_end = trip_time - 1/f = -5ms, i.e. BEFORE the
%     simulation even starts. measurement_indices was then empty,
%     mean() of an empty array returned NaN, and the script
%     silently fell through to measured_PF = 0 -- a wrong result
%     with no warning (the current variable a few lines above had
%     a fallback guard for this; the PF calculation did not).
%     The window logic below is now clamped to valid, physically
%     meaningful time ranges and explicitly falls back to the
%     THEORETICAL values -- with a printed note saying so -- only
%     when no full, clean AC cycle is actually available before
%     the trip. Default trip_delay is increased 5ms -> 25ms so a
%     full clean cycle exists by default (a real DAQ genuinely
%     cannot measure a full AC cycle's worth of RMS/PF in less
%     time than one AC cycle takes to occur).
%
%  3. trip_threshold was computed but never used anywhere (dead
%     variable), contradicting the header comment that claimed
%     threshold-based tripping. It is now used for two real
%     things:
%       (a) an informational "threshold crossing time" diagnostic
%       (b) a genuine IEC 60898-1 magnetic-trip-band check, using
%           a rated current In and MCB type (B/C/D), confirming
%           the selected fault current actually falls in the
%           instantaneous magnetic-trip region for that type.
%
%  4. contour() was being fed I_matrix directly, which contains
%     an Inf value at the R=0, L=0 point (Z=0 there). MATLAB's
%     contour engine does not accept non-finite Z data. It now
%     receives a sanitized (Inf/NaN-cleaned) copy.
%
%  5. Figure export order is now sorted by figure Number so
%     Figure_01.png ... Figure_07.png match creation order
%     (findall() does not guarantee creation order).
%% ============================================================

clear;
clc;
close all;

fprintf('\n');
fprintf('============================================================\n');
fprintf('       AUTOMATED HIGH-CURRENT MCB TEST SYSTEM\n');
fprintf('                  MATLAB SIMULATION\n');
fprintf('============================================================\n');


%% ============================================================
% 1. SOURCE PARAMETERS
%% ============================================================

V_rms = 3;                  % Simulation source voltage
f = 50;                     % Frequency [Hz]

I_target = 1000;            % Target current [A RMS]

current_tolerance = 0.05;   % +/-5%
PF_tolerance = 0.05;        % +/-0.05 PF

fprintf('\nSOURCE PARAMETERS\n');
fprintf('------------------------------------------------------------\n');
fprintf('Voltage          : %.2f V RMS\n',V_rms);
fprintf('Frequency        : %.2f Hz\n',f);
fprintf('Target Current   : %.2f A RMS\n',I_target);


%% ============================================================
% 2. RESISTOR BANK
%
% Binary weighted:
%
% 0.2 + 0.4 + 0.8 + 1.6 mOhm
%
% Gives 16 selectable values:
% 0 to 3.0 mOhm in 0.2 mOhm steps
%% ============================================================

R_unit = 0.2e-3;

R_bank = [ ...
    R_unit;
    2*R_unit;
    4*R_unit;
    8*R_unit
    ];

R_values = zeros(16,1);

for k = 0:15

    R_values(k+1) = ...
        sum(R_bank .* bitget(k,1:4)');

end


%% ============================================================
% 3. INDUCTOR BANK
%
% Binary weighted:
%
% 0.6 + 1.2 + 2.4 + 4.8 uH
%
% Gives 16 selectable values:
% 0 to 9.0 uH in 0.6 uH steps
%% ============================================================

L_unit = 0.6e-6;

L_bank = [ ...
    L_unit;
    2*L_unit;
    4*L_unit;
    8*L_unit
    ];

L_values = zeros(16,1);

for k = 0:15

    L_values(k+1) = ...
        sum(L_bank .* bitget(k,1:4)');

end


fprintf('\nIMPEDANCE BANK\n');
fprintf('------------------------------------------------------------\n');
fprintf('R range          : %.1f to %.1f mOhm\n', ...
    min(R_values)*1000,max(R_values)*1000);

fprintf('L range          : %.1f to %.1f uH\n', ...
    min(L_values)*1e6,max(L_values)*1e6);

fprintf('R combinations   : %d\n',length(R_values));
fprintf('L combinations   : %d\n',length(L_values));
fprintf('Total combinations: %d\n', ...
    length(R_values)*length(L_values));


%% ============================================================
% 4. CALCULATE ALL 256 R-L COMBINATIONS
%% ============================================================

[R_matrix,L_matrix] = meshgrid(R_values,L_values);

XL_matrix = 2*pi*f.*L_matrix;

Z_matrix = sqrt( ...
    R_matrix.^2 + XL_matrix.^2);

I_matrix = V_rms ./ Z_matrix;

PF_matrix = R_matrix ./ Z_matrix;

% Avoid invalid value at R = 0, L = 0
I_matrix(Z_matrix == 0) = Inf;
PF_matrix(Z_matrix == 0) = 0;


%% ============================================================
% 5. TARGET PF VALUES
%% ============================================================

target_PF = [0.40 0.50 0.60];

selected_R = zeros(size(target_PF));
selected_L = zeros(size(target_PF));
selected_I = zeros(size(target_PF));
selected_PF = zeros(size(target_PF));
selected_Z = zeros(size(target_PF));
selected_XL = zeros(size(target_PF));
selected_phi = zeros(size(target_PF));


%% ============================================================
% 6. AUTOMATIC TEST-CONDITION SELECTION
%
% Weight current and PF equally.
%
% Only physically valid combinations are considered.
%% ============================================================

for n = 1:length(target_PF)

    current_error = ...
        abs(I_matrix - I_target) ./ I_target;

    pf_error = ...
        abs(PF_matrix - target_PF(n));

    total_error = current_error + pf_error;

    % Remove invalid combinations
    total_error(~isfinite(total_error)) = Inf;

    [~,idx] = min(total_error(:));

    selected_R(n) = R_matrix(idx);
    selected_L(n) = L_matrix(idx);

    selected_I(n) = I_matrix(idx);
    selected_PF(n) = PF_matrix(idx);

    selected_Z(n) = Z_matrix(idx);
    selected_XL(n) = XL_matrix(idx);

    selected_phi(n) = acos(selected_PF(n));

end


%% ============================================================
% 7. DISPLAY AUTOMATICALLY SELECTED CONDITIONS
%% ============================================================

fprintf('\nAUTOMATIC TEST CONDITION SELECTION\n');
fprintf('------------------------------------------------------------\n');

fprintf('%10s %12s %12s %12s %12s\n', ...
    'Target PF','R [mOhm]','L [uH]','Current [A]','Actual PF');

fprintf('------------------------------------------------------------\n');

for n = 1:length(target_PF)

    fprintf('%10.2f %12.3f %12.3f %12.2f %12.3f\n', ...
        target_PF(n), ...
        selected_R(n)*1000, ...
        selected_L(n)*1e6, ...
        selected_I(n), ...
        selected_PF(n));

end


%% ============================================================
% 8. SELECT TEST CONDITION
%
% We use the PF = 0.60 condition for the detailed fault test.
%% ============================================================

test_index = 3;

R_fault = selected_R(test_index);
L_fault = selected_L(test_index);

Z_fault = selected_Z(test_index);
XL_fault = selected_XL(test_index);

I_fault_rms = selected_I(test_index);
PF_fault_theoretical = selected_PF(test_index);

phi_fault = selected_phi(test_index);


fprintf('\nSELECTED DETAILED TEST\n');
fprintf('------------------------------------------------------------\n');

fprintf('Target PF        : %.3f\n',target_PF(test_index));
fprintf('R                : %.3f mOhm\n',R_fault*1000);
fprintf('L                : %.3f uH\n',L_fault*1e6);
fprintf('XL               : %.3f mOhm\n',XL_fault*1000);
fprintf('|Z|              : %.3f mOhm\n',Z_fault*1000);
fprintf('Current          : %.2f A RMS\n',I_fault_rms);
fprintf('Theoretical PF   : %.3f\n',PF_fault_theoretical);
fprintf('Phase angle      : %.2f deg\n',rad2deg(phi_fault));


%% ============================================================
% 8B. IEC 60898-1 MAGNETIC TRIP BAND CHECK  (FIX #3)
%
% Ties the fault current we selected above to a real MCB rating
% and type, so trip_threshold (used below) means something
% physical instead of being an unused number.
%% ============================================================

In = 63;            % MCB rated current [A]
MCB_type = 'C';      % Type B / C / D per IEC 60898-1

switch upper(MCB_type)
    case 'B'
        trip_mult_low = 3;  trip_mult_high = 5;
    case 'C'
        trip_mult_low = 5;  trip_mult_high = 10;
    case 'D'
        trip_mult_low = 10; trip_mult_high = 20;
    otherwise
        error('Unknown MCB_type "%s" - use B, C, or D.',MCB_type);
end

I_magnetic_low  = trip_mult_low  * In;
I_magnetic_high = trip_mult_high * In;

fprintf('\nIEC 60898-1 MAGNETIC TRIP BAND (Type %s, In = %.0f A)\n',MCB_type,In);
fprintf('------------------------------------------------------------\n');
fprintf('Magnetic band    : %.1f A  to  %.1f A\n',I_magnetic_low,I_magnetic_high);

if I_fault_rms >= I_magnetic_low

    fprintf('Fault current    : %.1f A -> WITHIN/ABOVE instantaneous magnetic trip band (PASS)\n', ...
        I_fault_rms);

else

    fprintf('Fault current    : %.1f A -> BELOW magnetic trip band, would rely on thermal trip (FAIL for SC test intent)\n', ...
        I_fault_rms);

end


%% ============================================================
% 9. WAVEFORM SIMULATION
%% ============================================================

cycles = 8;

t = linspace(0,cycles/f,20000);

V_peak = sqrt(2)*V_rms;
I_peak = sqrt(2)*I_fault_rms;

v = V_peak*sin(2*pi*f*t);

i_normal = ...
    I_peak*sin(2*pi*f*t - phi_fault);


%% ============================================================
% 10. APPLY FAULT
%% ============================================================

fault_time = 10e-3;

fault_indices = t >= fault_time;

i_fault = zeros(size(t));

i_fault(fault_indices) = ...
    i_normal(fault_indices);


%% ============================================================
% 11. MCB TRIP MODEL
%
% This is a simplified demonstration model: the MCB is assumed
% to open trip_delay seconds after the fault is applied.
%
% trip_delay is now large enough (>= one full AC cycle) that the
% rolling-RMS / PF measurement in Section 17-18 always has a
% genuine, uncontaminated cycle of data to work with (FIX #2).
%
% trip_threshold (FIX #3) is used just below as a diagnostic:
% it reports the instant the *instantaneous* current first
% exceeds 80% of the fault RMS current, i.e. the point at which
% an instantaneous overcurrent sensor would first "see" the
% fault -- independent of when the mechanism actually opens.
%% ============================================================

trip_threshold = 0.80 * I_fault_rms;

trip_delay = 25e-3;   % FIX #2: was 5ms; now >= one AC cycle (20ms)
                       % so a clean pre-trip measurement window exists.

trip_time = fault_time + trip_delay;

trip_indices = t >= trip_time;

% MCB closed before trip
mcb_state = ones(size(t));

% MCB opens after trip
mcb_state(trip_indices) = 0;

% Current becomes zero after trip
i_fault(trip_indices) = 0;

% --- Threshold-crossing diagnostic (uses trip_threshold, FIX #3) ---
above_threshold_idx = find( ...
    t >= fault_time & abs(i_normal) >= trip_threshold, 1, 'first');

fprintf('\nMCB TRIP MODEL\n');
fprintf('------------------------------------------------------------\n');
fprintf('Trip threshold   : %.2f A (80%% of fault RMS current)\n',trip_threshold);

if ~isempty(above_threshold_idx)

    threshold_cross_time = t(above_threshold_idx);

    fprintf('Threshold crossed: %.3f ms after start\n', ...
        threshold_cross_time*1000);

else

    fprintf('Threshold crossed: not reached within simulated window\n');

end

fprintf('Trip delay       : %.1f ms (fixed response time from fault onset)\n', ...
    trip_delay*1000);
fprintf('Trip time        : %.1f ms\n',trip_time*1000);


%% ============================================================
% 12. CONFIRM TRIP
%% ============================================================

trip_detected = any(trip_indices);

if trip_detected

    trip_time_measured = t(find(trip_indices,1,'first'));

else

    trip_time_measured = NaN;

end


%% ============================================================
% 13. SIMULATED DAQ
%
% 2 MS/s sampling
%% ============================================================

Fs = 2e6;

t_DAQ = 0:1/Fs:(cycles/f);

v_DAQ = V_peak*sin(2*pi*f*t_DAQ);

i_DAQ = zeros(size(t_DAQ));


% Current before trip
fault_DAQ_indices = ...
    t_DAQ >= fault_time & ...
    t_DAQ < trip_time;

i_DAQ(fault_DAQ_indices) = ...
    I_peak*sin( ...
    2*pi*f*t_DAQ(fault_DAQ_indices) - phi_fault);


% Current after trip = zero
i_DAQ(t_DAQ >= trip_time) = 0;


%% ============================================================
% 14. DAQ RMS PROCESSING  (FIX #1: vectorized, was an O(N*M) loop)
%
% Trailing (causal) moving RMS over one AC cycle, matching what
% the original for-loop computed (window = samples k-N+1 : k),
% but computed in one vectorized pass instead of ~280,000
% separate ~40,000-element loop iterations.
%% ============================================================

samples_per_cycle = round(Fs/f);

I_RMS_DAQ = NaN(size(i_DAQ));

if length(i_DAQ) >= samples_per_cycle

    mean_sq = movmean(i_DAQ.^2, [samples_per_cycle-1, 0]);

    I_RMS_DAQ(samples_per_cycle:end) = ...
        sqrt(mean_sq(samples_per_cycle:end));

end


%% ============================================================
% 15. MEASURE STEADY-STATE CURRENT  (FIX #2: robust window)
%
% Prefer a full clean AC cycle ending one full cycle before the
% trip (avoids the rolling-RMS window overlapping the
% interruption transient). If that window would fall before the
% fault was even applied (not enough time), fall back to the
% first full cycle immediately after the fault is applied. If
% neither is available (trip_delay shorter than one AC cycle),
% fall back to the theoretical values and say so explicitly --
% this replaces the old code's silent, incorrect PF = 0 result.
%% ============================================================

one_cycle = 1/f;

measurement_end   = trip_time - one_cycle;
measurement_start = measurement_end - one_cycle;

if measurement_start < fault_time

    measurement_start = fault_time;
    measurement_end   = fault_time + one_cycle;

end

measurement_indices = ...
    t_DAQ >= measurement_start & t_DAQ <= measurement_end;

use_theoretical = ~any(measurement_indices) || measurement_end > trip_time;

if ~use_theoretical

    measured_current = sqrt( ...
        mean(i_DAQ(measurement_indices).^2));

    calibration_note = 'MEASURED from simulated DAQ data';

else

    measured_current = I_fault_rms;

    calibration_note = 'THEORETICAL fallback (no full clean AC cycle available before trip)';

end


%% ============================================================
% 16. MEASURE PEAK CURRENT
%% ============================================================

I_peak_measured = ...
    max(abs(i_DAQ(fault_DAQ_indices)));


%% ============================================================
% 17. MEASURE POWER FACTOR FROM DAQ  (FIX #2 continued)
%
% PF = P / S
%
% P = mean(v*i)
% Vrms = sqrt(mean(v^2))
% Irms = sqrt(mean(i^2))
% S = Vrms*Irms
%
% Now guarded the same way as the current measurement above --
% the original code had NO fallback here, so an empty/invalid
% window silently produced measured_PF = 0.
%% ============================================================

if ~use_theoretical

    v_measure = v_DAQ(measurement_indices);
    i_measure = i_DAQ(measurement_indices);

    P_measured = mean(v_measure .* i_measure);

    V_measured = sqrt(mean(v_measure.^2));

    I_measured = sqrt(mean(i_measure.^2));

    S_measured = V_measured * I_measured;

    if S_measured > 0

        measured_PF = P_measured / S_measured;

    else

        measured_PF = PF_fault_theoretical;

    end

else

    % No valid DAQ window -- report the known theoretical
    % operating point instead of a fabricated PF = 0.
    V_measured = V_rms;
    I_measured = I_fault_rms;
    P_measured = V_rms * I_fault_rms * PF_fault_theoretical;
    S_measured = V_rms * I_fault_rms;
    measured_PF = PF_fault_theoretical;

end


%% ============================================================
% 18. POST-TRIP CURRENT
%% ============================================================

post_trip_indices = ...
    t_DAQ >= trip_time + 2/f;


if any(post_trip_indices)

    measured_post_trip_current = ...
        sqrt(mean(i_DAQ(post_trip_indices).^2));

else

    measured_post_trip_current = 0;

end


%% ============================================================
% 19. PASS / FAIL CRITERIA
%
% These are simulation criteria.
%% ============================================================

current_lower_limit = ...
    I_target*(1-current_tolerance);

current_upper_limit = ...
    I_target*(1+current_tolerance);

PF_lower_limit = ...
    target_PF(test_index)-PF_tolerance;

PF_upper_limit = ...
    target_PF(test_index)+PF_tolerance;

post_trip_current_limit = ...
    0.01*I_target;


%% ============================================================
% 20. INDIVIDUAL PASS / FAIL CHECKS
%% ============================================================

current_pass = ...
    measured_current >= current_lower_limit && ...
    measured_current <= current_upper_limit;


PF_pass = ...
    measured_PF >= PF_lower_limit && ...
    measured_PF <= PF_upper_limit;


trip_pass = ...
    trip_detected;


post_trip_pass = ...
    measured_post_trip_current <= ...
    post_trip_current_limit;


overall_pass = ...
    current_pass && ...
    PF_pass && ...
    trip_pass && ...
    post_trip_pass;


%% ============================================================
% 21. TEST RESULTS
%% ============================================================

fprintf('\n');
fprintf('============================================================\n');
fprintf('                    TEST RESULTS\n');
fprintf('============================================================\n');

fprintf('\nCALIBRATION SOURCE : %s\n',calibration_note);

fprintf('\nCURRENT MEASUREMENT\n');
fprintf('------------------------------------------------------------\n');

fprintf('Measured Current : %.2f A RMS\n',measured_current);
fprintf('Allowed Range   : %.2f - %.2f A\n', ...
    current_lower_limit,current_upper_limit);

if current_pass
    fprintf('Current Check   : PASS\n');
else
    fprintf('Current Check   : FAIL\n');
end


fprintf('\nPOWER FACTOR\n');
fprintf('------------------------------------------------------------\n');

fprintf('Measured PF     : %.3f\n',measured_PF);
fprintf('Allowed Range  : %.3f - %.3f\n', ...
    PF_lower_limit,PF_upper_limit);

if PF_pass
    fprintf('PF Check        : PASS\n');
else
    fprintf('PF Check        : FAIL\n');
end


fprintf('\nMCB TRIP\n');
fprintf('------------------------------------------------------------\n');

fprintf('Trip Detected   : %s\n',string(trip_detected));

if trip_detected

    fprintf('Trip Time       : %.3f ms\n', ...
        trip_time_measured*1000);

end

if trip_pass
    fprintf('Trip Check      : PASS\n');
else
    fprintf('Trip Check      : FAIL\n');
end


fprintf('\nPOST-TRIP INTERRUPTION\n');
fprintf('------------------------------------------------------------\n');

fprintf('Residual Current: %.4f A RMS\n', ...
    measured_post_trip_current);

fprintf('Allowed Limit   : %.2f A RMS\n', ...
    post_trip_current_limit);

if post_trip_pass
    fprintf('Interruption    : PASS\n');
else
    fprintf('Interruption    : FAIL\n');
end


%% ============================================================
% 22. FINAL RESULT
%% ============================================================

fprintf('\n');
fprintf('============================================================\n');

if overall_pass

    fprintf('                 SIMULATION TEST PASS\n');

else

    fprintf('                 SIMULATION TEST FAIL\n');

end

fprintf('============================================================\n');


%% ============================================================
% 23. TEST RESULT STRUCT
%% ============================================================

Test_Result = struct();

Test_Result.Target_PF = target_PF(test_index);

Test_Result.Target_Current_A = I_target;

Test_Result.R_mOhm = R_fault*1000;

Test_Result.L_uH = L_fault*1e6;

Test_Result.XL_mOhm = XL_fault*1000;

Test_Result.Z_mOhm = Z_fault*1000;

Test_Result.Measured_Current_A = ...
    measured_current;

Test_Result.Measured_PF = ...
    measured_PF;

Test_Result.Peak_Current_A = ...
    I_peak_measured;

Test_Result.Trip_Detected = ...
    trip_detected;

Test_Result.Trip_Time_ms = ...
    trip_time_measured*1000;

Test_Result.Post_Trip_Current_A = ...
    measured_post_trip_current;

Test_Result.Current_Pass = ...
    current_pass;

Test_Result.PF_Pass = ...
    PF_pass;

Test_Result.Trip_Pass = ...
    trip_pass;

Test_Result.Interruption_Pass = ...
    post_trip_pass;

Test_Result.Overall_Pass = ...
    overall_pass;

Test_Result.Calibration_Source = ...
    calibration_note;


%% ============================================================
% 24. TEST REPORT TABLE
%% ============================================================

Test_Report = table( ...
    target_PF(test_index), ...
    R_fault*1000, ...
    L_fault*1e6, ...
    XL_fault*1000, ...
    Z_fault*1000, ...
    measured_current, ...
    measured_PF, ...
    rad2deg(phi_fault), ...
    P_measured, ...
    S_measured, ...
    I_peak_measured, ...
    trip_time_measured*1000, ...
    measured_post_trip_current, ...
    overall_pass, ...
    'VariableNames', { ...
    'Target_PF', ...
    'R_mOhm', ...
    'L_uH', ...
    'XL_mOhm', ...
    'Z_mOhm', ...
    'Current_A', ...
    'Measured_PF', ...
    'Phase_deg', ...
    'RealPower_W', ...
    'ApparentPower_VA', ...
    'PeakCurrent_A', ...
    'TripTime_ms', ...
    'PostTripCurrent_A', ...
    'Simulation_Pass'});


%% ============================================================
% 25. WAVEFORM PLOT
%% ============================================================

figure('Name','Voltage and Fault Current');

plot(t*1000,v,'LineWidth',1.2);
hold on;

plot(t*1000,i_fault/100,'LineWidth',1.2);

xline(fault_time*1000,'--','Fault');

xline(trip_time*1000,'--','MCB Trip');

grid on;

xlabel('Time [ms]');
ylabel('Scaled Amplitude');

title('Simulated Fault Voltage and Current');

legend('Voltage','Current / 100','Location','best');


%% ============================================================
% 26. MCB STATE PLOT
%% ============================================================

figure('Name','MCB State');

stairs(t*1000,mcb_state,'LineWidth',1.5);

grid on;

xlabel('Time [ms]');
ylabel('MCB State');

ylim([-0.2 1.2]);

yticks([0 1]);
yticklabels({'OPEN','CLOSED'});

title('Simulated MCB State');


%% ============================================================
% 27. DAQ CURRENT PLOT
%% ============================================================

figure('Name','DAQ Current');

plot(t_DAQ*1000,i_DAQ,'LineWidth',1);

hold on;

xline(fault_time*1000,'--','Fault');

xline(trip_time*1000,'--','Trip');

grid on;

xlabel('Time [ms]');
ylabel('Current [A]');

title('Simulated 2 MS/s DAQ Current');


%% ============================================================
% 28. RMS CURRENT PLOT
%% ============================================================

figure('Name','DAQ RMS Current');

plot(t_DAQ*1000,I_RMS_DAQ,'LineWidth',1.2);

hold on;

yline(I_target,'--','Target');

yline(current_lower_limit,'--','Lower Limit');

yline(current_upper_limit,'--','Upper Limit');

xline(trip_time*1000,'--','MCB Trip');

grid on;

xlabel('Time [ms]');
ylabel('RMS Current [A]');

title('Measured RMS Current');


%% ============================================================
% 29. R-L CURRENT HEATMAP
%% ============================================================

figure('Name','Current Capability Map');

I_plot = I_matrix;

% Hide infinite and excessively high values
I_plot(~isfinite(I_plot)) = NaN;

I_plot(I_plot > 1.2*I_target) = NaN;

imagesc( ...
    R_values*1000, ...
    L_values*1e6, ...
    I_plot);

set(gca,'YDir','normal');

colorbar;

hold on;

% FIX #4: contour() cannot accept non-finite (Inf) Z data. Use a
% sanitized copy instead of the raw I_matrix (which has Inf at
% the R=0, L=0 point).
I_contour = I_matrix;
I_contour(~isfinite(I_contour)) = NaN;

contour( ...
    R_values*1000, ...
    L_values*1e6, ...
    I_contour, ...
    [I_target I_target], ...
    'k','LineWidth',1.5);

plot( ...
    selected_R*1000, ...
    selected_L*1e6, ...
    'kx', ...
    'MarkerSize',10, ...
    'LineWidth',2);

xlabel('Resistance [mOhm]');
ylabel('Inductance [uH]');

title('R-L Bank Current Capability');

legend('1000 A contour','Selected conditions');


%% ============================================================
% 30. POWER FACTOR HEATMAP
%% ============================================================

figure('Name','Power Factor Map');

imagesc( ...
    R_values*1000, ...
    L_values*1e6, ...
    PF_matrix);

set(gca,'YDir','normal');

colorbar;

hold on;

plot( ...
    selected_R*1000, ...
    selected_L*1e6, ...
    'kx', ...
    'MarkerSize',10, ...
    'LineWidth',2);

xlabel('Resistance [mOhm]');
ylabel('Inductance [uH]');

title('R-L Bank Power Factor Map');

legend('Selected conditions');


%% ============================================================
% 31. PASS / FAIL DISPLAY
%% ============================================================

figure('Name','Simulation Test Result');

axis off;

if overall_pass

    text(0.5,0.65, ...
        'SIMULATION TEST PASS', ...
        'HorizontalAlignment','center', ...
        'FontSize',24, ...
        'FontWeight','bold');

else

    text(0.5,0.65, ...
        'SIMULATION TEST FAIL', ...
        'HorizontalAlignment','center', ...
        'FontSize',24, ...
        'FontWeight','bold');

end

text(0.5,0.48, ...
    sprintf('Current = %.2f A RMS',measured_current), ...
    'HorizontalAlignment','center', ...
    'FontSize',14);

text(0.5,0.40, ...
    sprintf('PF = %.3f',measured_PF), ...
    'HorizontalAlignment','center', ...
    'FontSize',14);

text(0.5,0.32, ...
    sprintf('Trip Time = %.3f ms',trip_time_measured*1000), ...
    'HorizontalAlignment','center', ...
    'FontSize',14);

text(0.5,0.24, ...
    sprintf('Post-Trip Current = %.4f A', ...
    measured_post_trip_current), ...
    'HorizontalAlignment','center', ...
    'FontSize',14);


%% ============================================================
% 32. AUTOMATIC REPORT EXPORT
%% ============================================================

report_folder = 'MCB_Test_Results';

if ~exist(report_folder,'dir')

    mkdir(report_folder);

end


%% CSV

csv_filename = ...
    fullfile(report_folder,'MCB_Test_Report.csv');

writetable(Test_Report,csv_filename);


%% MAT FILE

mat_filename = ...
    fullfile(report_folder,'MCB_Test_Data.mat');

save(mat_filename, ...
    'Test_Report', ...
    'Test_Result', ...
    'R_values', ...
    'L_values', ...
    'R_matrix', ...
    'L_matrix', ...
    'XL_matrix', ...
    'Z_matrix', ...
    'I_matrix', ...
    'PF_matrix', ...
    't_DAQ', ...
    'v_DAQ', ...
    'i_DAQ', ...
    'I_RMS_DAQ');


%% TXT REPORT

txt_filename = ...
    fullfile(report_folder,'MCB_Test_Summary.txt');

fid = fopen(txt_filename,'w');


fprintf(fid,'============================================================\n');
fprintf(fid,'AUTOMATED HIGH-CURRENT MCB TEST SYSTEM\n');
fprintf(fid,'SIMULATION TEST REPORT\n');
fprintf(fid,'============================================================\n\n');

fprintf(fid,'SOURCE PARAMETERS\n');
fprintf(fid,'Voltage        : %.2f V RMS\n',V_rms);
fprintf(fid,'Frequency      : %.2f Hz\n',f);
fprintf(fid,'Target Current : %.2f A RMS\n\n',I_target);

fprintf(fid,'TEST CONDITION\n');
fprintf(fid,'Target PF      : %.3f\n',target_PF(test_index));
fprintf(fid,'R              : %.3f mOhm\n',R_fault*1000);
fprintf(fid,'L              : %.3f uH\n',L_fault*1e6);
fprintf(fid,'XL             : %.3f mOhm\n',XL_fault*1000);
fprintf(fid,'Z              : %.3f mOhm\n',Z_fault*1000);

fprintf(fid,'\nIEC 60898-1 MAGNETIC TRIP CONTEXT\n');
fprintf(fid,'MCB Type       : %s (In = %.0f A)\n',MCB_type,In);
fprintf(fid,'Magnetic band  : %.1f A to %.1f A\n',I_magnetic_low,I_magnetic_high);

fprintf(fid,'\nMEASUREMENTS (%s)\n',calibration_note);
fprintf(fid,'Current        : %.2f A RMS\n',measured_current);
fprintf(fid,'Power Factor   : %.3f\n',measured_PF);
fprintf(fid,'Peak Current   : %.2f A\n',I_peak_measured);
fprintf(fid,'Trip Time      : %.3f ms\n',trip_time_measured*1000);
fprintf(fid,'Post Trip I    : %.4f A RMS\n',measured_post_trip_current);

fprintf(fid,'\nPASS/FAIL\n');
fprintf(fid,'Current        : %s\n',string(current_pass));
fprintf(fid,'Power Factor   : %s\n',string(PF_pass));
fprintf(fid,'MCB Trip       : %s\n',string(trip_pass));
fprintf(fid,'Interruption   : %s\n',string(post_trip_pass));

fprintf(fid,'\nFINAL RESULT\n');

if overall_pass
    fprintf(fid,'SIMULATION TEST PASS\n');
else
    fprintf(fid,'SIMULATION TEST FAIL\n');
end

fprintf(fid,'\nNOTE:\n');
fprintf(fid,['The limits used in this MATLAB model are simulation ', ...
    'criteria only and do not constitute an IEC 60898-1 ', ...
    'certification result.\n']);

fprintf(fid,'============================================================\n');

fclose(fid);


%% ============================================================
% 33. EXPORT FIGURES (FIX #5: sorted by figure Number)
%% ============================================================

figure_handles = findall(0,'Type','figure');

[~,sortIdx] = sort([figure_handles.Number]);
figure_handles = figure_handles(sortIdx);

for k = 1:length(figure_handles)

    figure_filename = fullfile( ...
        report_folder, ...
        sprintf('Figure_%02d.png',k));

    exportgraphics( ...
        figure_handles(k), ...
        figure_filename, ...
        'Resolution',200);

end


%% ============================================================
% 34. FINAL CONSOLE SUMMARY
%% ============================================================

fprintf('\n');
fprintf('============================================================\n');
fprintf('             FINAL SIMULATION SUMMARY\n');
fprintf('============================================================\n');

fprintf('Selected PF          : %.3f\n',target_PF(test_index));

fprintf('Selected R           : %.3f mOhm\n',R_fault*1000);

fprintf('Selected L           : %.3f uH\n',L_fault*1e6);

fprintf('Measured Current     : %.2f A RMS\n',measured_current);

fprintf('Measured PF          : %.3f\n',measured_PF);

fprintf('Trip Time            : %.3f ms\n',trip_time_measured*1000);

fprintf('Post-Trip Current    : %.4f A RMS\n', ...
    measured_post_trip_current);

fprintf('\n');

if overall_pass

    fprintf('**************** SIMULATION TEST PASS ****************\n');

else

    fprintf('**************** SIMULATION TEST FAIL ****************\n');

end

fprintf('\nReports saved in:\n');
fprintf('%s\n',report_folder);

fprintf('\nGenerated:\n');
fprintf('  - MCB_Test_Report.csv\n');
fprintf('  - MCB_Test_Data.mat\n');
fprintf('  - MCB_Test_Summary.txt\n');
fprintf('  - Figure_XX.png files\n');

fprintf('============================================================\n');