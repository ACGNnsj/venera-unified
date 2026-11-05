@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >NUL
cd /d D:\venera\unified\native\inpaint
cargo build --release
