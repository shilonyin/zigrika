@echo off
chcp 65001 >nul
title Fix Zigrika Login Server Address (One-Click)
echo ============================================================
echo   Fix Zigrika 登录服务器地址  (一键修复)
echo   目标: 让登录界面地址栏默认 = http://127.0.0.1:10001
echo ============================================================
echo.
echo  [1/3] 正在关闭游戏客户端 (Client-Win64-Shipping.exe)...
taskkill /IM Client-Win64-Shipping.exe /F >nul 2>&1
if errorlevel 1 (
    echo        游戏未在运行，直接继续。
) else (
    echo        游戏已关闭。
)
echo.
echo  [2/3] 等待数据库释放并写入地址...
python "%~dp0tmp_ls_fix.py"
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
    echo  [3/3] ===== 修改成功! =====
    echo        地址已设为 http://127.0.0.1:10001
    echo        现在可以重新打开游戏了。
    echo        登录界面地址栏应自动显示完整地址, 无需再手动填写。
) else (
    echo  [失败] 未修改成功 (错误码 %RC%)。
    echo        请确认:
    echo        - 本机装了 Python 且在 PATH 中
    echo        - 游戏确实已完全退出
)
echo.
pause
