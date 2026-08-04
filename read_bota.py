from __future__ import annotations

import argparse
import csv
import json
import signal
import sys
import time
from contextlib import ExitStack
from pathlib import Path
from typing import Any, TextIO


CSV_FIELDS = (
    "host_time_s",
    "sensor_timestamp_us",
    "fx_N",
    "fy_N",
    "fz_N",
    "tx_Nm",
    "ty_Nm",
    "tz_Nm",
    "ax_m_s2",
    "ay_m_s2",
    "az_m_s2",
    "wx_rad_s",
    "wy_rad_s",
    "wz_rad_s",
    "temperature_C",
    "throttled",
    "overrange",
    "invalid",
    "raw",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="读取 BOTA BFT-ROKS-ECAT-M8 六维力/力矩传感器。"
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(__file__).with_name("bota_config.json"),
        help="BOTA 驱动 JSON 配置文件。",
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=10.0,
        help="读取和显示频率（Hz，默认 10）。",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=0.0,
        help="运行秒数；0 表示持续运行，直到 Ctrl+C。",
    )
    tare_group = parser.add_mutually_exclusive_group()
    tare_group.add_argument(
        "--tare",
        dest="tare",
        action="store_true",
        help="连接后将当前六维力/力矩读数清零（默认启用）。",
    )
    tare_group.add_argument(
        "--no-tare",
        dest="tare",
        action="store_false",
        help="跳过连接后的自动清零。",
    )
    parser.set_defaults(tare=True)
    parser.add_argument(
        "--csv",
        type=Path,
        help="可选的 CSV 输出路径。",
    )
    args = parser.parse_args()

    if args.rate <= 0:
        parser.error("--rate 必须大于 0")
    if args.duration < 0:
        parser.error("--duration 不能小于 0")
    return args


def load_device_summary(config_path: Path) -> tuple[str, str, str]:
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))["driver_config"]
        return (
            str(config["product_name"]),
            str(config["serial_number"]),
            str(config["communication_interface_params"]["network_interface"]),
        )
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"无法读取配置文件 {config_path}: {exc}") from exc


def frame_to_row(frame: Any) -> dict[str, Any]:
    status = frame.status
    return dict(
        zip(
            CSV_FIELDS,
            (
                time.time(),
                frame.timestamp,
                *frame.force,
                *frame.torque,
                *frame.acceleration,
                *frame.angular_rate,
                frame.temperature,
                status.throttled,
                status.overrange,
                status.invalid,
                status.raw,
            ),
        )
    )


def print_row(row: dict[str, Any]) -> None:
    print(
        f"F[N] {row['fx_N']:+9.3f} {row['fy_N']:+9.3f} {row['fz_N']:+9.3f}  "
        f"T[Nm] {row['tx_Nm']:+8.4f} {row['ty_Nm']:+8.4f} {row['tz_Nm']:+8.4f}  "
        f"Temp {row['temperature_C']:6.2f} C  "
        f"Status(thr={int(row['throttled'])}, over={int(row['overrange'])}, "
        f"invalid={int(row['invalid'])}, raw={int(row['raw'])})"
    )


def open_csv(stack: ExitStack, path: Path | None) -> tuple[TextIO | None, Any | None]:
    if path is None:
        return None, None

    path.parent.mkdir(parents=True, exist_ok=True)
    file_handle = stack.enter_context(path.open("w", newline="", encoding="utf-8-sig"))
    writer = csv.DictWriter(file_handle, fieldnames=CSV_FIELDS)
    writer.writeheader()
    return file_handle, writer


def main() -> int:
    args = parse_args()

    try:
        import bota_driver
    except ImportError:
        print(
            "未安装 bota-driver。请先运行：python -m pip install bota-driver",
            file=sys.stderr,
        )
        return 2

    config_path = args.config.resolve()
    product_name, serial_number, network_interface = load_device_summary(config_path)

    print(f"设备: {product_name} / {serial_number}")
    print(f"网卡: {network_interface}")
    print("正在连接 EtherCAT 传感器...")

    driver = None
    configured = False
    activated = False
    stop_requested = False

    def request_stop(_signum: int, _frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGINT, request_stop)

    try:
        driver = bota_driver.BotaDriver(str(config_path))
        print(f"BOTA 驱动版本: {driver.get_driver_version_string()}")

        if not driver.configure():
            raise RuntimeError("驱动配置失败")
        configured = True

        if args.tare:
            print("正在自动清零，请保持传感器处于零点参考状态...")
            if not driver.tare():
                raise RuntimeError("传感器清零失败")
            print("清零完成。")

        if not driver.activate():
            raise RuntimeError("传感器进入 ACTIVE 状态失败")
        activated = True

        period = 1.0 / args.rate
        started_at = time.perf_counter()
        next_read_at = started_at
        print("连接成功，开始读取。按 Ctrl+C 停止。")

        with ExitStack() as stack:
            csv_file, csv_writer = open_csv(stack, args.csv)
            while not stop_requested:
                if args.duration and time.perf_counter() - started_at >= args.duration:
                    break

                row = frame_to_row(driver.read_frame())
                print_row(row)
                if csv_writer is not None:
                    csv_writer.writerow(row)
                    csv_file.flush()

                next_read_at += period
                time.sleep(max(0.0, next_read_at - time.perf_counter()))

        return 0
    except Exception as exc:
        print(f"读取失败: {exc}", file=sys.stderr)
        print(
            "请确认传感器和 EtherCAT 供电注入器已上电、网线链路灯亮，"
            "并关闭 TwinCAT/Wireshark 等可能占用该网卡的程序。",
            file=sys.stderr,
        )
        return 1
    finally:
        if driver is not None:
            if activated:
                try:
                    driver.deactivate()
                except Exception:
                    pass
            if configured:
                try:
                    driver.shutdown()
                except Exception:
                    pass
        print("已停止读取。")


if __name__ == "__main__":
    raise SystemExit(main())
