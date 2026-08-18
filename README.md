# oneKeyPaddle

用一条终端命令安装固定版本的 CPU 版 PaddlePaddle、PaddleOCR 和 PaddleX，并运行一次 OCR 验证。

脚本支持 64 位 macOS、Linux 和 Windows。安装不需要管理员权限，所有文件都放在当前用户的应用数据目录中。

## 一行安装

### macOS / Linux

在 Bash 或 Zsh 中粘贴执行：

```bash
( tmp="$(mktemp)" && curl --proto '=https' --tlsv1.2 -fLsS --connect-timeout 15 --max-time 120 --retry 3 -o "$tmp" https://raw.githubusercontent.com/cardioio/oneKeyPaddle/main/install_paddleocr.sh && bash "$tmp"; status=$?; rm -f -- "$tmp"; exit "$status" )
```

### Windows PowerShell

在 PowerShell 中粘贴执行：

```powershell
& { $tmp = Join-Path $env:TEMP ("onekeypaddle-install-{0}.ps1" -f [guid]::NewGuid()); try { Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/cardioio/oneKeyPaddle/main/install_paddleocr.ps1 -OutFile $tmp -TimeoutSec 120; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
```

这两条命令都会先把脚本保存到临时文件，再执行本地文件。脚本本身会拒绝 `curl ... | bash` 和 `irm ... | iex`，避免未经检查的远程内容直接进入解释器。

如果需要审计版本，建议把 URL 中的 `main` 替换为一个已确认的 Git commit 或 release tag。

## 安装位置

| 系统 | 安装根目录 | Paddle 包位置 |
| --- | --- | --- |
| macOS | `~/Library/Application Support/oneKeyPaddle` | `.../venv/lib/python3.11/site-packages/paddle` |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/onekeypaddle` | `.../venv/lib/python3.11/site-packages/paddle` |
| Windows | `%LOCALAPPDATA%\oneKeyPaddle` | `...\venv\Lib\site-packages\paddle` |

目录内还包括：

- `venv/`：固定 Python 3.11.15 的虚拟环境
- `models/`：PaddleX 模型缓存
- `output/`：安装测试生成的 OCR 结果图
- `logs/`：安装和失败诊断日志
- `cache/uv/`：uv 下载缓存

安装成功时脚本会打印实际的 Paddle 包路径、激活命令、模型目录、输出目录和日志路径。

## 安装后使用

macOS / Linux：

```bash
source "$HOME/Library/Application Support/oneKeyPaddle/venv/bin/activate"  # macOS
source "${XDG_DATA_HOME:-$HOME/.local/share}/onekeypaddle/venv/bin/activate" # Linux
```

Windows PowerShell：

```powershell
& "$env:LOCALAPPDATA\oneKeyPaddle\venv\Scripts\Activate.ps1"
```

然后可以在已激活的环境中使用：

```bash
python -c "from paddleocr import PaddleOCR; print('PaddleOCR ready')"
```

当前固定版本为：`uv 0.11.19`、`Python 3.11.15`、`paddlepaddle 3.3.1`、`paddleocr 3.7.0`、`paddlex 3.7.2`。

## 镜像和离线模型

指定 PaddlePaddle 软件源时必须使用 HTTPS：

```bash
PADDLEOCR_INDEX_URL=https://your-mirror.example/simple bash install_paddleocr.sh
```

使用本地模型时，必须同时提供检测模型和识别模型目录：

```bash
PADDLEOCR_DET_MODEL_DIR=/path/to/det \
PADDLEOCR_REC_MODEL_DIR=/path/to/rec \
bash install_paddleocr.sh
```

两个目录都必须包含 `inference.yml` 和 `inference.pdiparams`。也可以设置旧版兼容变量 `PADDLEOCR_MODEL_DIR`，其下应存在 `PP-OCRv6_medium_det/` 和 `PP-OCRv6_medium_rec/` 两个子目录。

离线模型只表示模型文件不联网获取；如果 Python、uv 或依赖包不在本地缓存中，安装阶段仍需要网络。首次在线安装会将模型放入固定的 `models/official_models/` 目录。

## 注意事项

- 脚本安装的是 CPU 版，不包含 CUDA/GPU 配置。
- 至少预留 2 GiB 磁盘空间；完整安装还会产生 uv 缓存和模型缓存。
- 首次运行可能下载 Python、Python 包和 OCR 模型，耗时取决于网络。
- 不要在多个终端同时运行安装脚本；脚本会使用安装锁保护固定目录。
- 安装目录是固定的，脚本会重建其中的 `venv/`，不要把个人文件放进该目录。
- `PADDLEOCR_INDEX_URL` 只接受 HTTPS；不要把带密码的 URL 放进公共命令历史或日志。
- `PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK` 仅由脚本在本地模型目录校验成功后设置。
- `No ccache found` 是 Paddle 的性能警告，不代表安装失败。
- 发生错误时先查看安装输出末尾给出的 `logs/` 日志路径。

## 卸载

确认不再需要环境后，可以删除对应的整个安装根目录。下面的命令只针对脚本使用的固定目录，请先确认路径：

macOS：

```bash
rm -rf "$HOME/Library/Application Support/oneKeyPaddle"
```

Linux：

```bash
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/onekeypaddle"
```

Windows PowerShell：

```powershell
Remove-Item -LiteralPath "$env:LOCALAPPDATA\oneKeyPaddle" -Recurse -Force
```
