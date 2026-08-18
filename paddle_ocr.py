#!/usr/bin/env python3
"""Recognize one image or every supported image in a directory."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Iterable


SUPPORTED_EXTENSIONS = {
    ".bmp",
    ".jpeg",
    ".jpg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
}
DEFAULT_INPUT_DIR = Path("input")


def installed_app_root() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "oneKeyPaddle"
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if not local_app_data:
            raise RuntimeError("LOCALAPPDATA is not set")
        return Path(local_app_data) / "oneKeyPaddle"
    data_home = os.environ.get("XDG_DATA_HOME")
    return (
        Path(data_home).expanduser()
        if data_home
        else Path.home() / ".local" / "share"
    ) / "onekeypaddle"


def configure_model_cache() -> Path:
    model_dir = installed_app_root() / "models"
    os.environ.setdefault("PADDLE_PDX_CACHE_HOME", str(model_dir))
    return Path(os.environ["PADDLE_PDX_CACHE_HOME"])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="使用 PaddleOCR 识别一张图片或递归识别文件夹中的图片。"
    )
    parser.add_argument(
        "input",
        type=Path,
        nargs="?",
        default=DEFAULT_INPUT_DIR,
        help="图片文件或图片文件夹，默认递归扫描 ./input",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("ocr_output"),
        help="带框结果图目录，默认: ./ocr_output",
    )
    return parser.parse_args()


def is_supported_image(path: Path) -> bool:
    return path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def collect_images(input_path: Path, output_dir: Path) -> list[Path]:
    if input_path.is_file():
        if not is_supported_image(input_path):
            extensions = ", ".join(sorted(SUPPORTED_EXTENSIONS))
            raise ValueError(f"不支持的图片格式: {input_path.suffix}；支持: {extensions}")
        return [input_path]

    if not input_path.is_dir():
        raise FileNotFoundError(f"输入路径不存在: {input_path}")

    images = [
        path
        for path in input_path.rglob("*")
        if is_supported_image(path.resolve())
        and not is_relative_to(path.resolve(), output_dir)
    ]
    return sorted(images, key=lambda path: str(path).casefold())


def result_directory(image: Path, input_path: Path, output_dir: Path) -> Path:
    if input_path.is_file():
        return output_dir
    return output_dir / image.relative_to(input_path).parent


def print_texts(texts: Iterable[object], scores: Iterable[object]) -> int:
    count = 0
    for text, score in zip(texts, scores):
        print(f"  {float(score):.4f}\t{text}")
        count += 1
    return count


def main() -> int:
    args = parse_args()
    input_path = args.input.expanduser().resolve()
    output_dir = args.output.expanduser().resolve()
    model_dir = configure_model_cache()

    try:
        images = collect_images(input_path, output_dir)
    except (FileNotFoundError, ValueError) as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 2

    if not images:
        print(f"错误: 文件夹中没有支持的图片: {input_path}", file=sys.stderr)
        return 2

    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"输入: {input_path}")
    print(f"图片数量: {len(images)}")
    print(f"模型目录: {model_dir}")
    print(f"输出目录: {output_dir}")

    from paddleocr import PaddleOCR

    ocr = PaddleOCR(
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
    )

    failed = 0
    recognized = 0
    for index, image in enumerate(images, start=1):
        print(f"\n[{index}/{len(images)}] {image}")
        destination = result_directory(image, input_path, output_dir)
        destination.mkdir(parents=True, exist_ok=True)
        try:
            image_has_text = False
            for result in ocr.predict(str(image)):
                count = print_texts(
                    result.get("rec_texts", []), result.get("rec_scores", [])
                )
                recognized += count
                image_has_text = image_has_text or count > 0
                result.save_to_img(str(destination))
            if not image_has_text:
                print("  没有识别到文字")
        except Exception as exc:
            failed += 1
            print(f"  失败: {exc}", file=sys.stderr)

    succeeded = len(images) - failed
    print("\n处理完成")
    print(f"成功图片: {succeeded}/{len(images)}")
    print(f"识别文本: {recognized} 条")
    print(f"带框结果: {output_dir}")
    if failed:
        print(f"失败图片: {failed}，请查看上方错误信息", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已取消", file=sys.stderr)
        raise SystemExit(130)
