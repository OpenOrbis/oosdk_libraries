#!/bin/bash
FILES="mdct.c
smallft.c
block.c
envelope.c
window.c
lsp.c
lpc.c
analysis.c
synthesis.c
psy.c
info.c
floor1.c
floor0.c
res0.c
mapping0.c
registry.c
codebook.c
sharedbook.c
lookup.c
bitrate.c
vorbisfile.c
vorbisenc.c"
OBJS=""
rm *.o
for i in $FILES; do
    clang++ -cc1 -triple x86_64-pc-freebsd-elf -munwind-tables -I$OO_PS4_TOOLCHAIN/include -I. -fuse-init-array -debug-info-kind=limited -debugger-tuning=gdb -DGRAPHICS_USES_FONT -emit-obj $i -o "$(basename "$i" .c).o"
    OBJS="$OBJS $(basename "$i" .c).o"
done

llvm-ar rc libvorbis.a $OBJS
