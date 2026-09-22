# funcVer

This directory is reserved for `bc-eh` function verification.

The subdirectories map to the non-empty reset-handler combinations covered by
the `scsi_eh_check_point()` `if / else if` branches, plus the final
`Implement nothing` branch.

Naming rule:
- `01_device`
- `02_target`
- `03_bus`
- `04_host`
- `05_device_target`
- `06_device_bus`
- `07_device_host`
- `08_target_bus`
- `09_target_host`
- `10_bus_host`
- `11_device_target_bus`
- `12_device_target_host`
- `13_device_bus_host`
- `14_target_bus_host`
- `15_device_target_bus_host`
- `16_none`

Current minimal cases:
- `01_device`: `D1_device_terminal_success`
- `02_target`: `T1_target_terminal_success`
- `03_bus`: `B1_bus_terminal_success`
- `04_host`: `H1_host_terminal_success`
- `05_device_target`: `T1_target_terminal_success`
- `06_device_bus`: `B1_bus_fallback_after_device_fail`
- `07_device_host`: `H1_host_fallback_after_device_fail`
- `08_target_bus`: `B1_bus_terminal_success`
- `09_target_host`: `H1_host_fallback_after_target_fail`
- `10_bus_host`: `B1_bus_terminal_success`
- `11_device_target_bus`: `B1_bus_terminal_success`
- `12_device_target_host`: `H1_host_fallback_after_target_fail`
- `13_device_bus_host`: `H1_host_fallback_after_device_fail`
- `14_target_bus_host`: `H1_host_terminal_success`
- `15_device_target_bus_host`: keep `B1_bus_terminal_success`, `W1_checkpoint_wait_reenter`, `M1_multi_sequence_restart`, `S1_scope_matched_absorb_before_reset`, `P1_pending_fault_already_queued`, and `X1_cross_scope_no_absorb_restart`
- `16_none`: `N1_offline_without_reset_handler`
