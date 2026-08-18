#!/usr/bin/env bash
#
# PaddleOCR installer for macOS and Linux.
# Run this downloaded file with: bash install_paddleocr.sh
# Direct execution from a network pipe is intentionally rejected.
#
# Optional environment variables:
#   PADDLEOCR_INDEX_URL          HTTPS package index for paddlepaddle
#   PADDLEOCR_DET_MODEL_DIR      Existing detection model directory
#   PADDLEOCR_REC_MODEL_DIR      Existing recognition model directory
#   PADDLEOCR_MODEL_DIR          Parent of PP-OCRv6_medium_det/ and
#                               PP-OCRv6_medium_rec/ (legacy shorthand)

set -Eeuo pipefail

readonly UV_VERSION="0.11.19"
readonly UV_INSTALLER_SHA256="ef8cf0575d37cf3c72e05f153dd72a845a87a7bb9be86184d5fe931b8c426250"
readonly PYTHON_VERSION="3.11.15"
readonly PADDLE_VERSION="3.3.1"
readonly PADDLEOCR_VERSION="3.7.0"
readonly PADDLEX_VERSION="3.7.2"
readonly MIN_FREE_KIB=$((2 * 1024 * 1024))

show_help() {
  cat <<'EOF'
用法: bash install_paddleocr.sh

安装到当前用户的系统应用数据目录，不需要管理员权限：
  macOS: ~/Library/Application Support/oneKeyPaddle
  Linux: ${XDG_DATA_HOME:-~/.local/share}/onekeypaddle

离线安装模型时，必须同时设置 PADDLEOCR_DET_MODEL_DIR 和
PADDLEOCR_REC_MODEL_DIR。脚本仍需要本地 uv/Python/软件包缓存；模型本身
不会联网获取。
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  show_help
  exit 0
elif (( $# > 0 )); then
  printf '错误: 未知参数: %s\n' "$1" >&2
  show_help >&2
  exit 2
fi

script_source="${BASH_SOURCE[0]:-}"
if [[ -z "$script_source" || ! -f "$script_source" || "$script_source" == /dev/* ]]; then
  echo "错误: 为避免执行未经检查的远程内容，请先下载脚本文件，再用 bash 执行。" >&2
  exit 2
fi

if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
  echo "错误: HOME 必须是有效的绝对路径。" >&2
  exit 1
fi
if [[ -n "${XDG_DATA_HOME:-}" && "$XDG_DATA_HOME" != /* ]]; then
  echo "错误: XDG_DATA_HOME 必须是绝对路径。" >&2
  exit 1
fi

case "$(uname -s 2>/dev/null || true)" in
  Darwin)
    readonly APP_ROOT="$HOME/Library/Application Support/oneKeyPaddle"
    ;;
  Linux)
    readonly APP_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/onekeypaddle"
    ;;
  *)
    echo "错误: 仅支持 macOS 和 Linux。Windows 请运行 install_paddleocr.ps1。" >&2
    exit 1
    ;;
esac

readonly VENV_DIR="$APP_ROOT/venv"
readonly PYTHON_DIR="$APP_ROOT/python"
readonly TOOLS_DIR="$APP_ROOT/tools"
readonly CACHE_DIR="$APP_ROOT/cache/uv"
readonly MODEL_CACHE_DIR="$APP_ROOT/models"
readonly OUTPUT_DIR="$APP_ROOT/output"
readonly LOG_DIR="$APP_ROOT/logs"
readonly LOCK_DIR="$APP_ROOT/.install.lock"

mkdir -p "$APP_ROOT" "$TOOLS_DIR" "$CACHE_DIR" "$MODEL_CACHE_DIR" \
  "$OUTPUT_DIR" "$LOG_DIR"

readonly LOG_FILE="$LOG_DIR/install-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

lock_acquired=0
temp_installer=""
error_reported=0

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$temp_installer" && -f "$temp_installer" ]]; then
    rm -f -- "$temp_installer"
  fi
  if (( lock_acquired )); then
    rm -f -- "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if (( status != 0 && ! error_reported )); then
    echo "错误: 安装意外终止（退出码 ${status}）。完整日志: $LOG_FILE" >&2
  fi
  exit "$status"
}

on_error() {
  local status=$?
  local line=${BASH_LINENO[0]:-unknown}
  error_reported=1
  echo "错误: 安装在第 ${line} 行失败（退出码 ${status}）。完整日志: $LOG_FILE" >&2
  exit "$status"
}

trap cleanup EXIT
trap on_error ERR

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lock_pid=""
  if [[ -f "$LOCK_DIR/pid" ]]; then
    read -r lock_pid < "$LOCK_DIR/pid" || true
  fi
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "错误: 另一个安装进程正在运行（PID ${lock_pid}）。" >&2
    exit 1
  fi
  echo "检测到失效的安装锁，正在恢复。"
  rm -f -- "$LOCK_DIR/pid"
  if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "错误: 无法恢复安装锁: $LOCK_DIR" >&2
    exit 1
  fi
fi
lock_acquired=1
printf '%s\n' "$$" > "$LOCK_DIR/pid"

echo "=================================================="
echo " PaddleOCR 安装脚本 (macOS / Linux)"
echo "=================================================="
echo "安装根目录: $APP_ROOT"
echo "Python 环境: $VENV_DIR"
echo "模型缓存目录: $MODEL_CACHE_DIR"
echo "测试输出目录: $OUTPUT_DIR"
echo "安装日志: $LOG_FILE"

for command_name in cp curl df mktemp uname; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "错误: 缺少必需命令: $command_name" >&2
    exit 1
  fi
done

os_name=$(uname -s)
arch_name=$(uname -m)
case "$arch_name" in
  x86_64|amd64|arm64|aarch64) ;;
  *)
    echo "错误: 不支持的处理器架构: ${arch_name}（仅支持 64 位 x86/ARM）。" >&2
    exit 1
    ;;
esac
echo "运行平台: ${os_name}/${arch_name}；安装 CPU 版 PaddlePaddle"

free_kib=$(df -Pk "$APP_ROOT" | awk 'NR == 2 { print $4 }')
if [[ ! "$free_kib" =~ ^[0-9]+$ ]]; then
  echo "错误: 无法读取安装磁盘的剩余空间。" >&2
  exit 1
fi
if (( free_kib < MIN_FREE_KIB )); then
  echo "错误: 安装目录所在磁盘至少需要 2 GiB 可用空间。" >&2
  exit 1
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "错误: 缺少 sha256sum 或 shasum，无法验证下载内容。" >&2
    return 1
  fi
}

uv_bin=""
uv_candidate=$(command -v uv 2>/dev/null || true)
if [[ -n "$uv_candidate" && "$uv_candidate" != "$VENV_DIR/bin/uv" ]] \
  && [[ "$("$uv_candidate" --version | awk '{print $2}')" == "$UV_VERSION" ]]; then
  uv_bin="$uv_candidate"
  echo "[1/6] 使用已安装的 uv $UV_VERSION: $uv_bin"
elif [[ -x "$TOOLS_DIR/uv" && "$("$TOOLS_DIR/uv" --version | awk '{print $2}')" == "$UV_VERSION" ]]; then
  uv_bin="$TOOLS_DIR/uv"
  echo "[1/6] 使用专用 uv $UV_VERSION: $uv_bin"
else
  echo "[1/6] 下载并安装专用 uv $UV_VERSION ..."
  temp_installer=$(mktemp "$APP_ROOT/uv-installer.XXXXXX")
  curl --proto '=https' --tlsv1.2 -fLsS \
    --connect-timeout 15 --max-time 120 --retry 3 \
    "https://astral.sh/uv/$UV_VERSION/install.sh" -o "$temp_installer"
  actual_hash=$(sha256_file "$temp_installer")
  if [[ "$actual_hash" != "$UV_INSTALLER_SHA256" ]]; then
    echo "错误: uv 安装器 SHA-256 校验失败，拒绝执行。" >&2
    exit 1
  fi
  UV_INSTALL_DIR="$TOOLS_DIR" UV_NO_MODIFY_PATH=1 sh "$temp_installer"
  uv_bin="$TOOLS_DIR/uv"
  if [[ ! -x "$uv_bin" || "$("$uv_bin" --version | awk '{print $2}')" != "$UV_VERSION" ]]; then
    echo "错误: uv 安装后版本或路径不符合预期。" >&2
    exit 1
  fi
fi
readonly UV_BIN="$uv_bin"

export UV_CACHE_DIR="$CACHE_DIR"
export UV_PYTHON_INSTALL_DIR="$PYTHON_DIR"
export UV_HTTP_TIMEOUT=120
export UV_HTTP_RETRIES=5
export PADDLE_PDX_CACHE_HOME="$MODEL_CACHE_DIR"
export ONEKEYPADDLE_OUTPUT_DIR="$OUTPUT_DIR"
export ONEKEYPADDLE_EXPECTED_PADDLE="$PADDLE_VERSION"
export ONEKEYPADDLE_EXPECTED_PADDLEOCR="$PADDLEOCR_VERSION"
export ONEKEYPADDLE_EXPECTED_PADDLEX="$PADDLEX_VERSION"

echo "[2/6] 安装固定版本 Python $PYTHON_VERSION ..."
"$UV_BIN" --no-config python install "$PYTHON_VERSION" --install-dir "$PYTHON_DIR" --no-bin

echo "[3/6] 在固定位置重建虚拟环境 ..."
if [[ "$VENV_DIR" != "$APP_ROOT/venv" || "$APP_ROOT" == "/" ]]; then
  echo "错误: 虚拟环境路径安全检查失败: $VENV_DIR" >&2
  exit 1
fi
"$UV_BIN" --no-config venv --clear --managed-python --python "$PYTHON_VERSION" "$VENV_DIR"
readonly VENV_PYTHON="$VENV_DIR/bin/python"
if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "错误: 虚拟环境 Python 不存在: $VENV_PYTHON" >&2
  exit 1
fi
cp -f -- "$UV_BIN" "$VENV_DIR/bin/uv"
if [[ "$("$VENV_DIR/bin/uv" --version | awk '{print $2}')" != "$UV_VERSION" ]]; then
  echo "错误: 无法在虚拟环境中提供固定版本 uv。" >&2
  exit 1
fi

if [[ -n "${PADDLEOCR_INDEX_URL:-}" && "$PADDLEOCR_INDEX_URL" != https://* ]]; then
  echo "错误: PADDLEOCR_INDEX_URL 必须使用 HTTPS。" >&2
  exit 1
fi

echo "[4/6] 安装固定版本 PaddlePaddle、PaddleOCR 和 PaddleX ..."
if [[ -n "${PADDLEOCR_INDEX_URL:-}" ]]; then
  echo "使用用户指定的 HTTPS PaddlePaddle 软件源（地址不写入日志）。"
  "$UV_BIN" --no-config pip install --python "$VENV_PYTHON" --index-strategy first-index \
    --index-url "$PADDLEOCR_INDEX_URL" --extra-index-url https://pypi.org/simple/ \
    "paddlepaddle==$PADDLE_VERSION" "paddleocr==$PADDLEOCR_VERSION" \
    "paddlex==$PADDLEX_VERSION"
elif ! "$UV_BIN" --no-config pip install --python "$VENV_PYTHON" \
  "paddlepaddle==$PADDLE_VERSION" "paddleocr==$PADDLEOCR_VERSION" \
  "paddlex==$PADDLEX_VERSION"; then
  echo "PyPI 安装失败，使用 PaddlePaddle 官方 CPU 源重试。"
  "$UV_BIN" --no-config pip install --python "$VENV_PYTHON" --index-strategy first-index \
    --index-url https://www.paddlepaddle.org.cn/packages/stable/cpu/ \
    --extra-index-url https://pypi.org/simple/ \
    "paddlepaddle==$PADDLE_VERSION" "paddleocr==$PADDLEOCR_VERSION" \
    "paddlex==$PADDLEX_VERSION"
fi

echo "[5/6] 校验安装版本和导入路径 ..."
"$VENV_PYTHON" - <<'PY'
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
PY

det_model_dir="${PADDLEOCR_DET_MODEL_DIR:-}"
rec_model_dir="${PADDLEOCR_REC_MODEL_DIR:-}"
if [[ -n "${PADDLEOCR_MODEL_DIR:-}" ]]; then
  if [[ -n "$det_model_dir" || -n "$rec_model_dir" ]]; then
    echo "错误: PADDLEOCR_MODEL_DIR 不能与两个独立模型目录变量混用。" >&2
    exit 1
  fi
  det_model_dir="$PADDLEOCR_MODEL_DIR/PP-OCRv6_medium_det"
  rec_model_dir="$PADDLEOCR_MODEL_DIR/PP-OCRv6_medium_rec"
fi
if [[ -n "$det_model_dir" || -n "$rec_model_dir" ]]; then
  if [[ -z "$det_model_dir" || -z "$rec_model_dir" ]]; then
    echo "错误: 离线模式必须同时指定检测和识别模型目录。" >&2
    exit 1
  fi
  for model_dir in "$det_model_dir" "$rec_model_dir"; do
    if [[ ! -f "$model_dir/inference.yml" || ! -f "$model_dir/inference.pdiparams" ]]; then
      echo "错误: 模型目录不完整: $model_dir" >&2
      exit 1
    fi
  done
  export PADDLEOCR_DET_MODEL_DIR="$det_model_dir"
  export PADDLEOCR_REC_MODEL_DIR="$rec_model_dir"
  export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
  echo "[6/6] 使用已校验的本地检测/识别模型运行离线测试 ..."
else
  unset PADDLEOCR_DET_MODEL_DIR PADDLEOCR_REC_MODEL_DIR
  unset PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK
  echo "[6/6] 预下载默认 OCR 模型到固定缓存目录 ..."
fi

prepare_models() {
  "$VENV_PYTHON" - <<'PY'
import os
import socket
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
PY
}

prepare_models

echo "[6/6] 模型准备完成，开始运行 OCR 验证 ..."

run_smoke_test() {
  "$VENV_PYTHON" - <<'PY'
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
PY
}

if ! run_smoke_test; then
  echo "OCR 测试首次失败，等待 2 秒后重试一次 ..."
  sleep 2
  run_smoke_test
fi

echo "--------------------------------------------------"
echo "安装成功。"
echo "Paddle 安装位置: $VENV_DIR/lib/python3.11/site-packages/paddle"
echo "激活环境: source '$VENV_DIR/bin/activate'"
echo "模型目录: $MODEL_CACHE_DIR"
echo "测试输出: $OUTPUT_DIR"
echo "安装日志: $LOG_FILE"
echo "--------------------------------------------------"
