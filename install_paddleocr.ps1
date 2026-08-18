# PaddleOCR installer for 64-bit Windows.
# Download this file first, then run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install_paddleocr.ps1
# Direct execution through irm | iex is intentionally rejected.

param(
    [Alias("h")]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$UvVersion = "0.11.19"
$UvInstallerSha256 = "46d8ffb1f8f71bd015020cfc79acd0e816ff9de6a45ee3495d3e7d3717c24fdd"
$PythonVersion = "3.11.15"
$PaddleVersion = "3.3.1"
$PaddleOcrVersion = "3.7.0"
$PaddleXVersion = "3.7.2"
$MinimumFreeBytes = 2GB

function Show-Help {
    Write-Host @"
用法: powershell -NoProfile -ExecutionPolicy Bypass -File .\install_paddleocr.ps1

安装到当前用户的 Windows 应用数据目录，不需要管理员权限：
  %LOCALAPPDATA%\oneKeyPaddle

离线安装模型时，必须同时设置 PADDLEOCR_DET_MODEL_DIR 和
PADDLEOCR_REC_MODEL_DIR。脚本仍需要本地 uv/Python/软件包缓存；模型本身
不会联网获取。
"@
}

if ($Help) {
    Show-Help
    exit 0
}

if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
    -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
    Write-Error "为避免执行未经检查的远程内容，请先下载脚本文件，再用 -File 执行。"
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "仅支持 64 位 Windows。"
}
if (-not $env:LOCALAPPDATA) {
    Write-Error "无法确定 LOCALAPPDATA，不能选择安全的用户级安装位置。"
}

$AppRoot = Join-Path $env:LOCALAPPDATA "oneKeyPaddle"
$VenvDir = Join-Path $AppRoot "venv"
$PythonDir = Join-Path $AppRoot "python"
$ToolsDir = Join-Path $AppRoot "tools"
$CacheDir = Join-Path $AppRoot "cache\uv"
$ModelCacheDir = Join-Path $AppRoot "models"
$OutputDir = Join-Path $AppRoot "output"
$LogDir = Join-Path $AppRoot "logs"
$LockPath = Join-Path $AppRoot ".install.lock"

@($AppRoot, $ToolsDir, $CacheDir, $ModelCacheDir, $OutputDir, $LogDir) |
    ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }

$LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$TranscriptStarted = $false
$LockStream = $null
$TempInstaller = $null

try {
    Start-Transcript -Path $LogFile -Append | Out-Null
    $TranscriptStarted = $true

    try {
        $LockStream = [IO.File]::Open(
            $LockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch {
        throw "另一个安装进程正在运行。锁文件: $LockPath"
    }

    Write-Host "=================================================="
    Write-Host " PaddleOCR 安装脚本 (Windows)"
    Write-Host "=================================================="
    Write-Host "安装根目录: $AppRoot"
    Write-Host "Python 环境: $VenvDir"
    Write-Host "模型缓存目录: $ModelCacheDir"
    Write-Host "测试输出目录: $OutputDir"
    Write-Host "安装日志: $LogFile"

    $Architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    if ($Architecture -notin @("AMD64", "ARM64")) {
        throw "不支持的处理器架构: ${Architecture}（仅支持 64 位 x86/ARM）。"
    }
    Write-Host "运行平台: Windows/${Architecture}；安装 CPU 版 PaddlePaddle"

    $DriveRoot = [IO.Path]::GetPathRoot($AppRoot)
    $DriveInfo = New-Object -TypeName IO.DriveInfo -ArgumentList $DriveRoot
    if ($DriveInfo.AvailableFreeSpace -lt $MinimumFreeBytes) {
        throw "安装目录所在磁盘至少需要 2 GiB 可用空间。"
    }

    function Invoke-Download {
        param(
            [Parameter(Mandatory = $true)][string]$Uri,
            [Parameter(Mandatory = $true)][string]$Destination
        )

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec 120
                return
            } catch {
                if ($Attempt -eq 3) { throw }
                Write-Host "下载失败，2 秒后重试（$Attempt/3）..."
                Start-Sleep -Seconds 2
            }
        }
    }

    $UvBin = $null
    $ExistingUv = Get-Command uv -ErrorAction SilentlyContinue
    $ExistingVenvUv = Join-Path $VenvDir "Scripts\uv.exe"
    if ($ExistingUv -and $ExistingUv.Source -ne $ExistingVenvUv) {
        $ExistingUvOutput = & $ExistingUv.Source --version 2>$null
        $ExistingUvExitCode = $LASTEXITCODE
        if ($ExistingUvExitCode -eq 0 -and $ExistingUvOutput -match '^uv\s+([^\s]+)') {
            $ExistingUvVersion = $Matches[1]
        } else {
            $ExistingUvVersion = $null
        }
        if ($ExistingUvVersion -eq $UvVersion) {
            $UvBin = $ExistingUv.Source
            Write-Host "[1/6] 使用已安装的 uv ${UvVersion}: $UvBin"
        }
    }

    $PrivateUv = Join-Path $ToolsDir "uv.exe"
    if (-not $UvBin -and (Test-Path -LiteralPath $PrivateUv -PathType Leaf)) {
        $PrivateUvOutput = & $PrivateUv --version 2>$null
        $PrivateUvExitCode = $LASTEXITCODE
        if ($PrivateUvExitCode -eq 0 -and $PrivateUvOutput -match '^uv\s+([^\s]+)') {
            $PrivateUvVersion = $Matches[1]
        } else {
            $PrivateUvVersion = $null
        }
        if ($PrivateUvVersion -eq $UvVersion) {
            $UvBin = $PrivateUv
            Write-Host "[1/6] 使用专用 uv ${UvVersion}: $UvBin"
        }
    }

    if (-not $UvBin) {
        Write-Host "[1/6] 下载并安装专用 uv $UvVersion ..."
        $TempInstaller = Join-Path $AppRoot ("uv-installer-{0}.ps1" -f [Guid]::NewGuid())
        Invoke-Download -Uri "https://astral.sh/uv/$UvVersion/install.ps1" -Destination $TempInstaller
        $ActualHash = (Get-FileHash -LiteralPath $TempInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualHash -ne $UvInstallerSha256) {
            throw "uv 安装器 SHA-256 校验失败，拒绝执行。"
        }

        $PreviousInstallDir = $env:UV_INSTALL_DIR
        $PreviousNoModifyPath = $env:UV_NO_MODIFY_PATH
        try {
            $env:UV_INSTALL_DIR = $ToolsDir
            $env:UV_NO_MODIFY_PATH = "1"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TempInstaller
            if ($LASTEXITCODE -ne 0) {
                throw "uv 安装器失败，退出码: $LASTEXITCODE"
            }
        } finally {
            $env:UV_INSTALL_DIR = $PreviousInstallDir
            $env:UV_NO_MODIFY_PATH = $PreviousNoModifyPath
        }

        $UvBin = $PrivateUv
        if (-not (Test-Path -LiteralPath $UvBin -PathType Leaf)) {
            throw "uv 安装后未出现在预期位置: $UvBin"
        }
        $InstalledUvOutput = & $UvBin --version
        $InstalledUvExitCode = $LASTEXITCODE
        if ($InstalledUvExitCode -ne 0 -or
            $InstalledUvOutput -notmatch '^uv\s+([^\s]+)' -or
            $Matches[1] -ne $UvVersion) {
            throw "uv 安装后版本不符合预期。"
        }
    }

    $env:UV_CACHE_DIR = $CacheDir
    $env:UV_PYTHON_INSTALL_DIR = $PythonDir
    $env:UV_HTTP_TIMEOUT = "120"
    $env:UV_HTTP_RETRIES = "5"
    $env:PADDLE_PDX_CACHE_HOME = $ModelCacheDir
    $env:ONEKEYPADDLE_OUTPUT_DIR = $OutputDir
    $env:ONEKEYPADDLE_EXPECTED_PADDLE = $PaddleVersion
    $env:ONEKEYPADDLE_EXPECTED_PADDLEOCR = $PaddleOcrVersion
    $env:ONEKEYPADDLE_EXPECTED_PADDLEX = $PaddleXVersion

    Write-Host "[2/6] 安装固定版本 Python $PythonVersion ..."
    & $UvBin --no-config python install $PythonVersion --install-dir $PythonDir --no-bin
    if ($LASTEXITCODE -ne 0) {
        throw "Python 安装失败，退出码: $LASTEXITCODE"
    }

    Write-Host "[3/6] 在固定位置重建虚拟环境 ..."
    if ($VenvDir -ne (Join-Path $AppRoot "venv") -or $AppRoot -eq $DriveRoot) {
        throw "虚拟环境路径安全检查失败: $VenvDir"
    }
    & $UvBin --no-config venv --clear --managed-python --python $PythonVersion $VenvDir
    if ($LASTEXITCODE -ne 0) {
        throw "虚拟环境创建失败，退出码: $LASTEXITCODE"
    }
    $VenvPython = Join-Path $VenvDir "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        throw "虚拟环境 Python 不存在: $VenvPython"
    }
    $VenvUv = Join-Path $VenvDir "Scripts\uv.exe"
    Copy-Item -LiteralPath $UvBin -Destination $VenvUv -Force
    $VenvUvOutput = & $VenvUv --version
    $VenvUvExitCode = $LASTEXITCODE
    if ($VenvUvExitCode -ne 0 -or
        $VenvUvOutput -notmatch '^uv\s+([^\s]+)' -or
        $Matches[1] -ne $UvVersion) {
        throw "无法在虚拟环境中提供固定版本 uv。"
    }

    if ($env:PADDLEOCR_INDEX_URL) {
        $IndexUri = $null
        if (-not [Uri]::TryCreate($env:PADDLEOCR_INDEX_URL, [UriKind]::Absolute, [ref]$IndexUri) -or
            $IndexUri.Scheme -ne "https") {
            throw "PADDLEOCR_INDEX_URL 必须是有效的 HTTPS 地址。"
        }
    }

    Write-Host "[4/6] 安装固定版本 PaddlePaddle、PaddleOCR 和 PaddleX ..."
    if ($env:PADDLEOCR_INDEX_URL) {
        Write-Host "使用用户指定的 HTTPS PaddlePaddle 软件源（地址不写入日志）。"
        & $UvBin --no-config pip install --python $VenvPython --index-strategy first-index `
            --index-url $env:PADDLEOCR_INDEX_URL --extra-index-url https://pypi.org/simple/ `
            "paddlepaddle==$PaddleVersion" "paddleocr==$PaddleOcrVersion" `
            "paddlex==$PaddleXVersion"
        if ($LASTEXITCODE -ne 0) {
            throw "从指定软件源安装失败，退出码: $LASTEXITCODE"
        }
    } else {
        & $UvBin --no-config pip install --python $VenvPython `
            "paddlepaddle==$PaddleVersion" "paddleocr==$PaddleOcrVersion" `
            "paddlex==$PaddleXVersion"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "PyPI 安装失败，使用 PaddlePaddle 官方 CPU 源重试。"
            & $UvBin --no-config pip install --python $VenvPython --index-strategy first-index `
                --index-url https://www.paddlepaddle.org.cn/packages/stable/cpu/ `
                --extra-index-url https://pypi.org/simple/ `
                "paddlepaddle==$PaddleVersion" "paddleocr==$PaddleOcrVersion" `
                "paddlex==$PaddleXVersion"
            if ($LASTEXITCODE -ne 0) {
                throw "PaddlePaddle 官方 CPU 源安装失败，退出码: $LASTEXITCODE"
            }
        }
    }

    Write-Host "[5/6] 校验安装版本和导入路径 ..."
    $VerifyCode = @'
from importlib.metadata import version
import os
import paddle
import paddleocr

expected_paddle = os.environ["ONEKEYPADDLE_EXPECTED_PADDLE"]
expected_ocr = os.environ["ONEKEYPADDLE_EXPECTED_PADDLEOCR"]
expected_paddlex = os.environ["ONEKEYPADDLE_EXPECTED_PADDLEX"]
actual_paddle = version("paddlepaddle")
actual_ocr = version("paddleocr")
actual_paddlex = version("paddlex")
assert actual_paddle == expected_paddle, (actual_paddle, expected_paddle)
assert actual_ocr == expected_ocr, (actual_ocr, expected_ocr)
assert actual_paddlex == expected_paddlex, (actual_paddlex, expected_paddlex)
print("  paddle     :", actual_paddle, paddle.__file__)
print("  paddleocr  :", actual_ocr, paddleocr.__file__)
print("  paddlex    :", actual_paddlex)
'@
    & $VenvPython -c $VerifyCode
    if ($LASTEXITCODE -ne 0) {
        throw "模块版本或导入路径校验失败，退出码: $LASTEXITCODE"
    }

    $DetectionModelDir = $env:PADDLEOCR_DET_MODEL_DIR
    $RecognitionModelDir = $env:PADDLEOCR_REC_MODEL_DIR
    if ($env:PADDLEOCR_MODEL_DIR) {
        if ($DetectionModelDir -or $RecognitionModelDir) {
            throw "PADDLEOCR_MODEL_DIR 不能与两个独立模型目录变量混用。"
        }
        $DetectionModelDir = Join-Path $env:PADDLEOCR_MODEL_DIR "PP-OCRv6_medium_det"
        $RecognitionModelDir = Join-Path $env:PADDLEOCR_MODEL_DIR "PP-OCRv6_medium_rec"
    }

    if ($DetectionModelDir -or $RecognitionModelDir) {
        if (-not $DetectionModelDir -or -not $RecognitionModelDir) {
            throw "离线模式必须同时指定检测和识别模型目录。"
        }
        foreach ($ModelDir in @($DetectionModelDir, $RecognitionModelDir)) {
            if (-not (Test-Path -LiteralPath (Join-Path $ModelDir "inference.yml") -PathType Leaf) -or
                -not (Test-Path -LiteralPath (Join-Path $ModelDir "inference.pdiparams") -PathType Leaf)) {
                throw "模型目录不完整: $ModelDir"
            }
        }
        $env:PADDLEOCR_DET_MODEL_DIR = $DetectionModelDir
        $env:PADDLEOCR_REC_MODEL_DIR = $RecognitionModelDir
        $env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK = "True"
        Write-Host "[6/6] 使用已校验的本地检测/识别模型运行离线测试 ..."
    } else {
        Remove-Item Env:PADDLEOCR_DET_MODEL_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:PADDLEOCR_REC_MODEL_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK -ErrorAction SilentlyContinue
        Write-Host "[6/6] 预下载默认 OCR 模型到固定缓存目录 ..."
    }

    $PrepareModelsCode = @'
import socket
import os
from paddleocr import PaddleOCR

socket.setdefaulttimeout(120)
print("  模型 1/2: PP-OCRv6_medium_det（文字检测）")
print("  模型 2/2: PP-OCRv6_medium_rec（文字识别）")
kwargs = {
    "use_doc_orientation_classify": False,
    "use_doc_unwarping": False,
    "use_textline_orientation": False,
}
det_dir = os.environ.get("PADDLEOCR_DET_MODEL_DIR")
rec_dir = os.environ.get("PADDLEOCR_REC_MODEL_DIR")
if det_dir and rec_dir:
    kwargs.update(
        text_detection_model_dir=det_dir,
        text_recognition_model_dir=rec_dir,
    )
PaddleOCR(
    **kwargs,
)
print("  默认 OCR 模型已准备完成。")
'@
    & $VenvPython -c $PrepareModelsCode
    if ($LASTEXITCODE -ne 0) {
        throw "默认 OCR 模型预下载失败，退出码: $LASTEXITCODE"
    }

    Write-Host "[6/6] 模型准备完成，开始运行 OCR 验证 ..."

    $SmokeTestCode = @'
import os
import socket
import tempfile
import uuid
from pathlib import Path

import cv2
import numpy as np
from paddleocr import PaddleOCR

socket.setdefaulttimeout(120)
output_dir = Path(os.environ["ONEKEYPADDLE_OUTPUT_DIR"])
output_dir.mkdir(parents=True, exist_ok=True)
kwargs = {
    "use_doc_orientation_classify": False,
    "use_doc_unwarping": False,
    "use_textline_orientation": False,
}
det_dir = os.environ.get("PADDLEOCR_DET_MODEL_DIR")
rec_dir = os.environ.get("PADDLEOCR_REC_MODEL_DIR")
if det_dir and rec_dir:
    kwargs.update(
        text_detection_model_dir=det_dir,
        text_recognition_model_dir=rec_dir,
    )

ocr = PaddleOCR(**kwargs)
image = 255 * np.ones((120, 560, 3), dtype=np.uint8)
cv2.putText(
    image,
    "PaddleOCR install OK 2026",
    (20, 75),
    cv2.FONT_HERSHEY_SIMPLEX,
    1.1,
    (0, 0, 0),
    3,
)

tmp_path = None
try:
    with tempfile.NamedTemporaryFile(
        dir=output_dir, prefix="ocr-input-", suffix=".png", delete=False
    ) as tmp:
        tmp_path = Path(tmp.name)
    if not cv2.imwrite(str(tmp_path), image):
        raise RuntimeError(f"无法写入测试图片: {tmp_path}")

    results = list(ocr.predict(str(tmp_path)))
    if not results:
        raise RuntimeError("OCR 未返回任何结果")
    recognized = " ".join(
        str(text) for result in results for text in result.get("rec_texts", [])
    )
    normalized = recognized.lower().replace(" ", "")
    if "paddleocr" not in normalized or "2026" not in normalized:
        raise RuntimeError(f"OCR 结果不符合预期: {recognized!r}")
    annotated = image.copy()
    polygons = [
        polygon
        for result in results
        for polygon in result.get("rec_polys", [])
    ]
    if not polygons:
        raise RuntimeError("OCR 返回了文本，但没有返回识别框")
    for polygon in polygons:
        points = np.asarray(polygon, dtype=np.int32).reshape((-1, 1, 2))
        cv2.polylines(annotated, [points], True, (0, 0, 255), 2)
    result_path = output_dir / f"ocr-result-{uuid.uuid4().hex}.png"
    if not cv2.imwrite(str(result_path), annotated):
        raise RuntimeError(f"无法写入 OCR 结果图片: {result_path}")
    print("  识别文本:", recognized)
    print("  结果图片:", result_path)
finally:
    if tmp_path is not None:
        tmp_path.unlink(missing_ok=True)
'@

    & $VenvPython -c $SmokeTestCode
    if ($LASTEXITCODE -ne 0) {
        Write-Host "OCR 测试首次失败，等待 2 秒后重试一次 ..."
        Start-Sleep -Seconds 2
        & $VenvPython -c $SmokeTestCode
        if ($LASTEXITCODE -ne 0) {
            throw "OCR 测试失败，退出码: $LASTEXITCODE"
        }
    }

    Write-Host "--------------------------------------------------"
    Write-Host "安装成功。"
    Write-Host "Paddle 安装位置: $VenvDir\Lib\site-packages\paddle"
    Write-Host "激活环境: & '$VenvDir\Scripts\Activate.ps1'"
    Write-Host "模型目录: $ModelCacheDir"
    Write-Host "测试输出: $OutputDir"
    Write-Host "安装日志: $LogFile"
    Write-Host "--------------------------------------------------"
} catch {
    Write-Host "错误: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "完整日志: $LogFile" -ForegroundColor Red
    exit 1
} finally {
    if ($LockStream) {
        $LockStream.Dispose()
    }
    if ($TempInstaller -and (Test-Path -LiteralPath $TempInstaller -PathType Leaf)) {
        Remove-Item -LiteralPath $TempInstaller -Force
    }
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}
