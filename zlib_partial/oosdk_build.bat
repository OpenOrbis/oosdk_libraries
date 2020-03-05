SETLOCAL EnableDelayedExpansion

Rem Libraries to link in
set libraries=-lc -lkernel

Rem Read the script arguments into local vars
set intdir=%1
set targetname=%~2
set outputPath=%3

set outputLib=libzlib.a

Rem Compile object files for all the source files
for %%f in (source/*.c) do (
    clang -cc1 -triple x86_64-scei-ps4-elf -munwind-tables -I"%OO_PS4_TOOLCHAIN%\\include" -I"include/" -emit-obj -o source/%%~nf.o source/%%~nf.c
)

Rem Get a list of object files for linking
set obj_files=
for %%f in (source\*.o) do set obj_files=!obj_files! %%f

Rem the archiver to make the libzlib.a file
llvm-ar -rc libzlib.a %obj_files% 

Rem install the library
copy "%CD%\libzlib.a" "%OO_PS4_TOOLCHAIN%/lib/libzlib.a"
copy "%CD%\include\zconf.h" "%OO_PS4_TOOLCHAIN%/include/zconf.h"
copy "%CD%\include\zlib.h" "%OO_PS4_TOOLCHAIN%/include/zlib.h"
copy "%CD%\include\zutil.h" "%OO_PS4_TOOLCHAIN%/include/zutil.h"
