// NSCSCC/chiplab source manifest. LoongArch is the processor's sole ISA.
-F cpu.f
../core/cpu_top.sv
../memory/dcache_read_result_select.sv
../memory/dcache_data_format.sv
../memory/dcache.sv
../memory/icache_refill_ctrl.sv
../memory/icache.sv
../bus/axi/memory_backend_arbiter.sv
../bus/axi/axi_master_adapter.sv
../memory/dcache_data_ram.sv
../bus/axi/nscscc_axi_bridge.sv
../top/mycpu_top.v
