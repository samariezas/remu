OUTPUT_ARCH( "riscv" )
ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5); /* RX */
  data PT_LOAD FLAGS(6); /* RW */
}

SECTIONS
{
  /* code section */
  . = 0x80000000;
  .text.boot : { *(.text.boot) } :text
  .text : { *(.text) } :text
  .tohost (NOLOAD) : { *(.tohost) } :data

  . = ALIGN(0x1000);
  begin_signature = .;
  .data.signature : { *(.data.signature) } :data
  . = ALIGN(0x20);
  end_signature = .;

  . = ALIGN(0x1000);
  .data : { *(.data) } :data
  .bss (NOLOAD) : { *(.bss) } :data
    
  .stack (NOLOAD) :
  {
    . = ALIGN(0x1000);
    . = . + 0x4000;
    _stack_start = .;
  }
}
