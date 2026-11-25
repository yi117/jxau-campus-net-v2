@echo off
setlocal
echo ��������ע����ǰ��У԰���Ự�����ػ������ܲ����Լ��ǻ�����
echo �м����� 5 �� 10 �룬ʧ�ܵĻ��������������֤ҳ�ֶ���¼��
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0guard.ps1" -SelfTest -Once
echo.
pause
