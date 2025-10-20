OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.boot : { *(.text.boot) }
  . = ALIGN(0x4000);
  _stack_start = .;
  . = . + 0x1000;
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  begin_signature = .;
  .data.signature : { *(.data.signature) }
  . = ALIGN(0x20);
  end_signature = .;
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
