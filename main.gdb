target extended-remote localhost:1234
set logging file debug.log
set logging enabled

define px
python
args = gdb.string_to_argv(gdb.current_command_args())
addr1 = int(args[1], 0)
addr2 = int(args[2], 0)
data = gdb.inferiors()[0].read_memory(addr1, addr2-addr1)
print(''.join(f'{b:02x}' for b in data))
end
end

while 1
    x/i $pc
    stepi
    info registers
    (px &begin_address &end_address)
end
