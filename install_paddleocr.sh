#!/usr/bin/env bash
#
# PaddleOCR 一键安装脚本（macOS / Linux）
# 干什么：装 uv -> 装 Python 3.11 -> 建虚拟环境 -> 装 paddleocr -> 跑通推理 -> 生成示例图
# 用法：
#   本地：   bash install_paddleocr.sh
#   托管后： curl -fsSL <你的脚本URL> | bash
#
# 可选环境变量（都不填也能用）：
#   PADDLEOCR_INDEX_URL  指定 paddlepaddle 的 pip 镜像源（如百度源，解决 PyPI 慢/失败）
#   PADDLEOCR_MODEL_DIR  指定本地已下载好的模型目录（离线场景，可选）
#
set -euo pipefail

echo "=================================================="
echo " PaddleOCR 一键安装脚本 (macOS / Linux)"
echo "=================================================="

# ---------- 1. 安装 uv（若未装） ----------
if ! command -v uv >/dev/null 2>&1; then
  echo "[1/6] 未检测到 uv，正在安装 uv ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  if [ -f "$HOME/.local/bin/env" ]; then
    source "$HOME/.local/bin/env"
  fi
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
else
  echo "[1/6] 已检测到 uv: $(uv --version)"
fi

# ---------- 2. 安装 Python 3.11（若未装） ----------
echo "[2/6] 确保 Python 3.11 可用 ..."
uv python install 3.11 2>&1 | tail -n 2 || true

# ---------- 3. 创建虚拟环境 ----------
echo "[3/6] 创建虚拟环境 .venv ..."
uv venv --python 3.11 .venv
source .venv/bin/activate
echo "      已激活虚拟环境: $(which python)"

# ---------- 4. 安装 paddlepaddle(CPU) + paddleocr ----------
echo "[4/6] 安装 paddlepaddle + paddleocr（会下载一些包，请稍候）..."
if [ -n "${PADDLEOCR_INDEX_URL:-}" ]; then
  echo "      使用指定镜像源: $PADDLEOCR_INDEX_URL"
  uv pip install "paddlepaddle" --index-url "$PADDLEOCR_INDEX_URL" \
                  "paddleocr" --extra-index-url https://pypi.org/simple/
elif ! uv pip install paddlepaddle paddleocr 2>/dev/null; then
  echo "      PyPI 安装失败，尝试百度镜像源 ..."
  uv pip install "paddlepaddle" \
    --index-url https://www.paddlepaddle.org.cn/packages/stable/cpu/ \
    "paddleocr" --extra-index-url https://pypi.org/simple/
fi

# ---------- 5. 验证导入 ----------
echo "[5/6] 验证模块导入 ..."
python - <<'PY'
import paddle, paddleocr
print("  paddle      :", paddle.__version__)
print("  paddleocr   :", paddleocr.__version__)
PY

# ---------- 6. 成功测试：真实跑一次 OCR 并生成示例图 ----------
echo "[6/6] 运行 OCR 成功测试，并生成示例图（首次会联网下载模型）..."
python - <<'PY'
import cv2, numpy as np, os, tempfile
from paddleocr import PaddleOCR

os.makedirs("output", exist_ok=True)

kwargs = dict(
    use_doc_orientation_classify=False,
    use_doc_unwarping=False,
    use_textline_orientation=False,
)
model_dir = os.environ.get("PADDLEOCR_MODEL_DIR")
if model_dir:
    print("      使用离线模型目录:", model_dir)
    kwargs.update(
        text_detection_model_dir=model_dir,
        text_recognition_model_dir=model_dir,
    )

ocr = PaddleOCR(**kwargs)

# 生成一张带文字的测试图（英文+数字，避免中文字体依赖）
img = 255 * np.ones((120, 560, 3), dtype=np.uint8)
cv2.putText(img, "PaddleOCR install OK 2026", (20, 75),
            cv2.FONT_HERSHEY_SIMPLEX, 1.1, (0, 0, 0), 3)

tmp = tempfile.mktemp(suffix=".png")
cv2.imwrite(tmp, img)
try:
    result = ocr.predict(tmp)
    for res in result:
        res.save_to_img("output")   # 生成带识别框+文字的示例图
        res.print()
finally:
    os.remove(tmp)

print("  已生成示例图，保存在 output/ 目录")
print("✅ 一键安装与测试全部成功！")
PY

echo "--------------------------------------------------"
echo " 以后想重新进入这个环境，只需在终端执行："
echo "   source .venv/bin/activate"
echo " 退出环境： deactivate"
echo " 示例图在： output/  （用看图工具打开即可看到识别结果）"
echo "--------------------------------------------------"
