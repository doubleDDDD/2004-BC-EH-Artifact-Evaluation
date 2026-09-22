# funcVer

This directory is reserved for `bc-eh` function verification.

Each subdirectory name encodes which SCSI reset handlers are available in the
`scsi_debug` test driver for that functional-verification group. The four
handler names mean:

- `device`: device reset handler is available
- `target`: target reset handler is available
- `bus`: bus reset handler is available
- `host`: host reset handler is available

For example, `06_device_bus` means that the group enables the device-reset and
bus-reset handlers, but does not provide target-reset or host-reset handlers.
`15_device_target_bus_host` means all four reset handlers are available.
`16_none` means no reset handler is available, so BC-EH should converge to the
offline path.

These groups are not paper P1-P9 cases. They are functional-validation groups
used to exercise the BC-EH branch logic for different LLDD reset-handler
capabilities.

Functional Case Coverage:
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
