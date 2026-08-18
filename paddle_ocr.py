#!/usr/bin/env python3
"""Recognize one image or every supported image in a directory."""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


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


@dataclass(frozen=True)
class OCRLine:
    index: int
    text: str
    score: float | None
    box: tuple[float, float, float, float] | None


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


def normalize_box(value: object) -> tuple[float, float, float, float] | None:
    try:
        coordinates = list(value)  # type: ignore[arg-type]
        if len(coordinates) != 4:
            return None
        x0, y0, x1, y1 = (float(coordinate) for coordinate in coordinates)
    except (TypeError, ValueError):
        return None
    return min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)


def extract_lines(result: object, start_index: int) -> list[OCRLine]:
    texts = list(result.get("rec_texts", []))  # type: ignore[attr-defined]
    scores = list(result.get("rec_scores", []))  # type: ignore[attr-defined]
    boxes = list(result.get("rec_boxes", []))  # type: ignore[attr-defined]
    lines = []
    for offset, text in enumerate(texts):
        try:
            score = float(scores[offset])
        except (IndexError, TypeError, ValueError):
            score = None
        box = normalize_box(boxes[offset]) if offset < len(boxes) else None
        lines.append(OCRLine(start_index + offset, str(text), score, box))
    return lines


def geometric_key(line: OCRLine) -> tuple[float, float, int]:
    if line.box is None:
        return float("inf"), float("inf"), line.index
    return line.box[1], line.box[0], line.index


def find_column_split(lines: Sequence[OCRLine]) -> float | None:
    boxes = [line.box for line in lines if line.box is not None]
    if len(boxes) < 8:
        return None

    page_left = min(box[0] for box in boxes)
    page_right = max(box[2] for box in boxes)
    page_width = page_right - page_left
    if page_width <= 0:
        return None

    search_left = page_left + page_width * 0.2
    search_right = page_right - page_width * 0.2
    boundaries = sorted(
        {coordinate for box in boxes for coordinate in (box[0], box[2])}
    )
    candidates = [
        (left + right) / 2
        for left, right in zip(boundaries, boundaries[1:])
        if search_left <= (left + right) / 2 <= search_right
    ]

    minimum_side = max(3, len(boxes) // 6)
    maximum_spanning = max(2, len(boxes) // 10)
    best: tuple[int, int, int, float] | None = None
    for split in candidates:
        left_count = sum(box[2] <= split for box in boxes)
        right_count = sum(box[0] >= split for box in boxes)
        spanning_count = len(boxes) - left_count - right_count
        if (
            left_count < minimum_side
            or right_count < minimum_side
            or spanning_count > maximum_spanning
        ):
            continue
        rank = (
            spanning_count,
            abs(left_count - right_count),
            -min(left_count, right_count),
            split,
        )
        if best is None or rank < best:
            best = rank
    return None if best is None else best[3]


def line_center_y(line: OCRLine) -> float:
    assert line.box is not None
    return (line.box[1] + line.box[3]) / 2


def order_boxed_lines(lines: Sequence[OCRLine], depth: int = 0) -> list[OCRLine]:
    if depth >= 4:
        return sorted(lines, key=geometric_key)

    split = find_column_split(lines)
    if split is None:
        return sorted(lines, key=geometric_key)

    left = [line for line in lines if line.box is not None and line.box[2] <= split]
    right = [line for line in lines if line.box is not None and line.box[0] >= split]
    spanning = [
        line
        for line in lines
        if line.box is not None and line.box[0] < split < line.box[2]
    ]
    if not left or not right:
        return sorted(lines, key=geometric_key)

    ordered = []
    remaining_left = left
    remaining_right = right
    for full_width_line in sorted(spanning, key=geometric_key):
        separator_y = line_center_y(full_width_line)
        upper_left = [
            line for line in remaining_left if line_center_y(line) < separator_y
        ]
        upper_right = [
            line for line in remaining_right if line_center_y(line) < separator_y
        ]
        remaining_left = [line for line in remaining_left if line not in upper_left]
        remaining_right = [line for line in remaining_right if line not in upper_right]
        ordered.extend(order_boxed_lines(upper_left, depth + 1))
        ordered.extend(order_boxed_lines(upper_right, depth + 1))
        ordered.append(full_width_line)

    ordered.extend(order_boxed_lines(remaining_left, depth + 1))
    ordered.extend(order_boxed_lines(remaining_right, depth + 1))
    return ordered


def reading_order(lines: Sequence[OCRLine]) -> list[OCRLine]:
    boxed = [line for line in lines if line.box is not None]
    unboxed = [line for line in lines if line.box is None]
    return order_boxed_lines(boxed) + sorted(unboxed, key=lambda line: line.index)


def print_lines(lines: Iterable[OCRLine]) -> None:
    for line in lines:
        score = f"{line.score:.4f}" if line.score is not None else "   n/a"
        print(f"  {score}\t{line.text}")


def save_markdown(texts: Iterable[str], path: Path) -> None:
    content = "\n".join(texts)
    path.write_text(f"{content}\n" if content else "", encoding="utf-8")


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
        markdown_path = destination / image.with_suffix(".md").name
        try:
            image_lines = []
            for result in ocr.predict(str(image)):
                image_lines.extend(extract_lines(result, len(image_lines)))
                result.save_to_img(str(destination))
            image_lines = reading_order(image_lines)
            image_texts = [line.text for line in image_lines]
            print_lines(image_lines)
            recognized += len(image_texts)
            save_markdown(image_texts, markdown_path)
            if not image_texts:
                print("  没有识别到文字")
            print(f"  Markdown: {markdown_path}")
        except Exception as exc:
            failed += 1
            print(f"  失败: {exc}", file=sys.stderr)

    succeeded = len(images) - failed
    print("\n处理完成")
    print(f"成功图片: {succeeded}/{len(images)}")
    print(f"识别文本: {recognized} 条")
    print(f"带框结果: {output_dir}")
    print(f"Markdown结果: {output_dir}")
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
