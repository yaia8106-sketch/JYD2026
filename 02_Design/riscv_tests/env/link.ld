/* Custom linker script for RV32I CPU
 * IROM: 0x80000000 (instruction ROM, read-only)
 * DRAM: 0x80100000 - 0x80140000 (256KB, read-write)
 */

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  /* Code in IROM */
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text : { *(.text) }

  /* Data in DRAM */
  . = 0x80100000;
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
