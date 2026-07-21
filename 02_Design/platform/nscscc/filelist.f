// NSCSCC/chiplab source manifest.  This platform deliberately selects only
// the LoongArch ISA boundary; the JYD manifest separately selects RISC-V.
-F ../../rtl/filelists/loongarch_cpu.f
../../rtl/core/cpu_top.sv
../../rtl/memory/dcache_store_buffer.sv
../../rtl/memory/dcache.sv
../../rtl/memory/backends/irom_backend_adapter.sv
../../rtl/bus/axi/memory_backend_arbiter.sv
../../rtl/bus/axi/axi_master_adapter.sv
rtl/dcache_data_ram.sv
rtl/nscscc_axi_bridge.sv
rtl/mycpu_top.v
