# ColorOS Fastboot Fix

本项目包含两个脚本。`extract_ota.py` 在电脑上从 OTA 全量包提取 `abl.img` 和 `engineering_cdt.img`。`restore_fastboot.sh` 在已 Root 的 A/B 分区手机上备份并替换当前运行槽位对侧的这两个分区。

> **安装 OTA 后先停在系统升级的待重启状态。完成 Magisk 安装和脚本写入校验后，回到系统升级页面点「重启」。整个升级流程只在这一步重启手机。**

## 适用条件

- 手机已 Root，使用 A/B 槽位，两个槽位都有 `abl` 和 `engineering_cdt` 分区。
- 一加 13（`PJZ110`）的来源镜像按 ColorOS `16.0.10.501` 校验。目标参考版本是 ColorOS `17.0.1.202`。
- 其他机型的菜单只提供从当前运行槽位提取镜像的选项。当前版本与目标版本的引导分区仍需兼容。

## 在电脑上提取镜像

电脑需要 Python 3。下载对应机型和旧版系统的 OTA 全量 ZIP，保留原始压缩包。运行以下命令，再输入 ZIP 的绝对路径。

```powershell
python .\extract_ota.py
```

也可以直接传入路径。路径含空格时请保留引号。

```powershell
python .\extract_ota.py "D:\OTA\PJZ110_16.0.10.501.zip"
```

脚本核对 OTA 清单中的分区 SHA-256 后，在 ZIP 同目录创建 `<包名>_images`，并输出两个镜像的路径、大小和 SHA-256。输出目录必须尚不存在。使用 `--output` 可指定新目录，其父目录必须已存在。

```powershell
python .\extract_ota.py "D:\OTA\PJZ110_16.0.10.501.zip" --output "D:\OTA\FixFastbootImages"
python .\extract_ota.py "D:\OTA\PJZ110_16.0.10.501.zip" --list
python .\extract_ota.py --help
```

`--list` 只检查 OTA 清单中是否存在这两个分区。使用手机当前系统作为镜像来源时，可以跳过电脑提取。

## 在手机上升级

1. 在手机内部存储建立 `FixFastboot` 文件夹，将 `restore_fastboot.sh` 放进去。使用一加 13 的本地镜像选项时，将 `abl.img` 和 `engineering_cdt.img` 放在脚本同一目录。
2. 在系统升级页面安装新系统，等到页面出现「重启」按钮，保持待重启状态。
3. 打开 Magisk，选择「安装到未使用的槽位（OTA 后）」。等安装完成后退出 Magisk，把重启留到第 7 步。
4. 打开 MT 管理器终端，执行下面的命令。`id -u` 输出 `0` 后即可运行脚本。

   ```sh
   su
   id -u
   sh /sdcard/FixFastboot/restore_fastboot.sh
   ```

5. 选择镜像来源。脚本从当前运行槽位推算目标槽位，当前为 `_a` 则目标为 `_b`，反之亦然。

   | 机型 | `1` | `2` | `0` |
   | --- | --- | --- | --- |
   | 一加 13（`PJZ110`） | 使用同目录的两个镜像 | 从当前运行槽位提取 | 退出 |
   | 其他机型 | 从当前运行槽位提取 | 不适用 | 退出 |

6. 脚本备份目标分区后会显示写入确认。输入 `1` 继续，输入 `0` 取消。一加 13 的目标版本哈希不符时会显示警告，仍可输入 `1` 确认。来源镜像校验失败会停止写入。
7. 看到「两个目标镜像已写入并通过回读校验」，并确认日志中的退出码为 `0` 后，**回到系统升级页面点「重启」**。脚本按当前运行槽位确定写入目标，下次启动槽位由系统升级流程管理。

## 预检、导出和日志

在 Root 终端运行下列命令。

| 参数 | 用途 |
| --- | --- |
| `--check` | 只读预检。一加 13 使用同目录镜像，其他机型使用当前槽位镜像。 |
| `--check-current` | 只读预检，以当前运行槽位的镜像为来源。 |
| `--from-current` | 跳过来源菜单，直接使用当前运行槽位镜像，写入前仍需确认。 |
| `--dump-current [新目录绝对路径]` | 只导出当前运行槽位的两个完整镜像。省略目录时在 `/data/local/tmp/` 下创建导出目录。 |

```sh
sh /sdcard/FixFastboot/restore_fastboot.sh --check
sh /sdcard/FixFastboot/restore_fastboot.sh --dump-current /sdcard/FixFastboot/current-backup
```

一加 13 使用本地镜像时，如果脚本同目录的两个镜像都不存在，脚本会查找同级的 `PJZ110_16.0.10.501_images` 子目录。

日志保存在脚本同目录的 `restore_fastboot.log.*`。写入流程的原始分区备份在 `/data/local/tmp/restore_fastboot.*`，以实际日志打印的路径为准。写入或回读报错时，先保留日志和备份，暂缓重启。新版系统能否搭配旧版引导镜像启动取决于固件兼容性。

[GitHub 源码](https://github.com/xanthichi/coloros-fastboot-fix) · [夸克网盘](https://pan.quark.cn/s/1cc3228c49d6)
