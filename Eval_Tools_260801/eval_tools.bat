@echo off

set "PYTHON_EXE=C:\ProgramData\miniconda3\envs\visionAI\python.exe" 

set "PY_FILE=%~dp0GUI.py"

"%PYTHON_EXE%" "%PY_FILE%"

exit
