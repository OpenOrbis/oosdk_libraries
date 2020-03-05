SETLOCAL EnableDelayedExpansion

Rem Libraries to link in
set libraries=-lc -lkernel

Rem Read the script arguments into local vars
set intdir=%1
set targetname=%~2
set outputPath=%3

set outputLib=libpng.a

Rem Compile object files for all the source files
for %%f in (source/*.c) do (
    clang -cc1 -triple x86_64-scei-ps4-elf -munwind-tables -I"%OO_PS4_TOOLCHAIN%\\include" -I"include/" -emit-obj -o source/%%~nf.o source/%%~nf.c
)

Rem Get a list of object files for linking
set obj_files=
for %%f in (source\*.o) do set obj_files=!obj_files! %%f

Rem the archiver to make the libzlib.a file
llvm-ar -rc %outputLib% %obj_files% 

Rem install the library
copy "%CD%\%outputLib%" "%OO_PS4_TOOLCHAIN%/lib/%outputLib%"
copy "%CD%\include\png.h" "%OO_PS4_TOOLCHAIN%/include/png.h"
copy "%CD%\include\pngconf.h" "%OO_PS4_TOOLCHAIN%/include/pngconf.h"
copy "%CD%\include\pnglibconf.h" "%OO_PS4_TOOLCHAIN%/include/pnglibconf.h"
copy "%CD%\include\pngstruct.h" "%OO_PS4_TOOLCHAIN%/include/pngstruct.h"
copy "%CD%\include\pnginfo.h" "%OO_PS4_TOOLCHAIN%/include/pnginfo.h"