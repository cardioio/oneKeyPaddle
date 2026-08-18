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

安装脚本已经自动下载默认的文字检测模型和文字识别模型，不需要再手动下载或配置模型。

### 1. 激活环境

macOS / Linux：

```bash
# macOS
source "$HOME/Library/Application Support/oneKeyPaddle/venv/bin/activate"

# Linux
source "${XDG_DATA_HOME:-$HOME/.local/share}/onekeypaddle/venv/bin/activate"
```

Windows PowerShell：

```powershell
& "$env:LOCALAPPDATA\oneKeyPaddle\venv\Scripts\Activate.ps1"
```

### 2. 识别图片或文件夹

仓库中的 `paddle_ocr.py` 是独立的识别脚本，它会自动使用安装脚本已经下载好的模型。激活环境后，安装器提供的固定版本 uv 也会自动进入 `PATH`。如果使用上面的一行命令完成安装，本地还没有仓库文件，可以先下载这个脚本。

macOS / Linux：

```bash
curl --proto '=https' --tlsv1.2 -fLsS -o paddle_ocr.py https://raw.githubusercontent.com/cardioio/oneKeyPaddle/main/paddle_ocr.py
```

Windows PowerShell：

```powershell
Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/cardioio/oneKeyPaddle/main/paddle_ocr.py -OutFile paddle_ocr.py
```

激活环境后，在 `paddle_ocr.py` 所在目录执行。仓库已经提供默认的 `input/` 文件夹，把图片放进去后可以直接运行：

```bash
cp /xxxx/xxx/xxx.jpg input/
uv run paddle_ocr.py
```

脚本会递归扫描 `./input/`，并把带框图片输出到 `./ocr_output/`。Windows PowerShell：

```powershell
Copy-Item "C:\xxxx\xxx\xxx.jpg" .\input\
uv run .\paddle_ocr.py
```

`uv run paddle_ocr.py` 会使用已经激活的固定 Paddle 环境。`uv python xxx.py` 不是 uv 的运行命令；如果当前目录存在其他 uv 项目配置，也可以使用更严格的写法 `uv run --active --no-project python paddle_ocr.py`。

也可以直接传入一张图片或其他文件夹，覆盖默认的 `input/`：

```bash
uv run paddle_ocr.py /xxxx/xxx/xxx.jpg
uv run paddle_ocr.py /xxxx/整个图片文件夹
```

文件夹会递归处理其中的 JPG、JPEG、PNG、BMP、TIF、TIFF 和 WebP 图片，并且只加载一次模型。

默认在当前目录的 `ocr_output/` 中生成带框结果图。处理文件夹时会保留原来的子目录结构，避免同名图片互相覆盖。可以用 `-o` 指定输出目录：

```bash
uv run paddle_ocr.py /xxxx/图片文件夹 -o /xxxx/识别结果
```

终端会逐张打印图片路径、识别文字和置信度，最后打印成功数量、文本数量及带框结果目录。路径中有空格时，请用引号包住路径。第一次生成带文字的结果图时，PaddleX 可能额外下载一次绘图字体，这不是重新下载 OCR 模型。

当前固定版本为：`uv 0.11.19`、`Python 3.11.15`、`paddlepaddle 3.3.1`、`paddleocr 3.7.0`、`paddlex 3.7.2`。

## 注意事项

- 脚本安装的是 CPU 版，不包含 CUDA/GPU 配置。
- 至少预留 2 GiB 磁盘空间；完整安装还会产生 uv 缓存和模型缓存。
- 安装阶段会先预下载两个必要模型，并显示 PaddleX 的下载进度：`PP-OCRv6_medium_det`（文字检测）和 `PP-OCRv6_medium_rec`（文字识别）。
- 安装测试完成后，默认检测模型和识别模型已经保存在固定的 `models/official_models/` 目录；正常使用 `paddle_ocr.py` 时不会再次下载模型。
- 如果预下载阶段失败，安装会直接失败并给出日志路径，不会留下一个看似成功但缺少模型的环境。


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
