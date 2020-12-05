#!/bin/bash
FILES="bitwise.c
framing.c"
OBJS=""
rm *.o
for i in $FILES; do
    clang++ -cc1 -triple x86_64-pc-freebsd-elf -munwind-tables -I$OO_PS4_TOOLCHAIN/include -I. -fuse-init-array -debug-info-kind=limited -debugger-tuning=gdb -DGRAPHICS_USES_FONT -emit-obj $i -o "$(basename "$i" .c).o"
    OBJS="$OBJS $(basename "$i" .c).o"
done

llvm-ar rc libogg.a $OBJS
