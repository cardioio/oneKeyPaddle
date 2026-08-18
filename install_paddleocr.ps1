# PaddleOCR 一键安装脚本（Windows）
# 干什么：装 uv -> 装 Python 3.11 -> 建虚拟环境 -> 装 paddleocr -> 跑通推理 -> 生成示例图
# 用法（在 PowerShell 里执行，不要用 cmd 直接跑）：
#   本地：   powershell -ExecutionPolicy Bypass -File .\install_paddleocr.ps1
#   从 cmd： powershell -ExecutionPolicy Bypass -Command "& { .\install_paddleocr.ps1 }"
#   托管后： irm <你的脚本URL> | iex
#
# 可选环境变量（都不填也能用）：
#   $env:PADDLEOCR_INDEX_URL  指定 paddlepaddle 的 pip 镜像源（如百度源）
#   $env:PADDLEOCR_MODEL_DIR  指定本地已下载好的模型目录（离线场景，可选）

$ErrorActionPreference = "Stop"

Write-Host "=================================================="
Write-Host " PaddleOCR 一键安装脚本 (Windows)"
Write-Host "=================================================="

# ---------- 1. 安装 uv（若未装） ----------
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "[1/6] 未检测到 uv，正在安装 uv ..."
    powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "User") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "Machine")
} else {
    Write-Host "[1/6] 已检测到 uv: $(uv --version)"
}

# ---------- 2. 安装 Python 3.11（若未装） ----------
Write-Host "[2/6] 确保 Python 3.11 可用 ..."
uv python install 3.11 2>&1 | Select-Object -Last 2

# ---------- 3. 创建虚拟环境 ----------
Write-Host "[3/6] 创建虚拟环境 .venv ..."
uv venv --python 3.11 .venv
. .\.venv\Scripts\Activate.ps1
Write-Host "      已激活虚拟环境: $((Get-Command python).Source)"

# ---------- 4. 安装 paddlepaddle(CPU) + paddleocr ----------
Write-Host "[4/6] 安装 paddlepaddle + paddleocr（会下载一些包，请稍候）..."
if ($env:PADDLEOCR_INDEX_URL) {
    Write-Host "      使用指定镜像源: $env:PADDLEOCR_INDEX_URL"
    uv pip install "paddlepaddle" --index-url $env:PADDLEOCR_INDEX_URL `
        "paddleocr" --extra-index-url https://pypi.org/simple/
} else {
    try {
        uv pip install paddlepaddle paddleocr
    } catch {
        Write-Host "      PyPI 安装失败，尝试百度镜像源 ..."
        uv pip install "paddlepaddle" `
            --index-url https://www.paddlepaddle.org.cn/packages/stable/cpu/ `
            "paddleocr" --extra-index-url https://pypi.org/simple/
    }
}

# ---------- 5. 验证导入 ----------
Write-Host "[5/6] 验证模块导入 ..."
python -c "import paddle, paddleocr; print('  paddle    :', paddle.__version__); print('  paddleocr :', paddleocr.__version__)"

# ---------- 6. 成功测试：真实跑一次 OCR 并生成示例图 ----------
Write-Host "[6/6] 运行 OCR 成功测试，并生成示例图（首次会联网下载模型）..."
python -c @"
import cv2, numpy as np, os, tempfile
from paddleocr import PaddleOCR
os.makedirs('output', exist_ok=True)
kwargs = dict(use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False)
model_dir = os.environ.get('PADDLEOCR_MODEL_DIR')
if model_dir:
    print('      使用离线模型目录:', model_dir)
    kwargs.update(text_detection_model_dir=model_dir, text_recognition_model_dir=model_dir)
ocr = PaddleOCR(**kwargs)
img = 255 * np.ones((120, 560, 3), dtype=np.uint8)
cv2.putText(img, 'PaddleOCR install OK 2026', (20, 75), cv2.FONT_HERSHEY_SIMPLEX, 1.1, (0,0,0), 3)
tmp = tempfile.mktemp(suffix='.png')
cv2.imwrite(tmp, img)
try:
    result = ocr.predict(tmp)
    for res in result:
        res.save_to_img('output')
        res.print()
finally:
    os.remove(tmp)
print('  已生成示例图，保存在 output/ 目录')
print('✅ 一键安装与测试全部成功！')
"@

Write-Host "--------------------------------------------------"
Write-Host " 以后想重新进入这个环境，只需在 PowerShell 执行："
Write-Host "   .\.venv\Scripts\Activate.ps1"
Write-Host " 退出环境： deactivate"
Write-Host " 示例图在： output\  （双击即可看到识别结果）"
Write-Host "--------------------------------------------------"
