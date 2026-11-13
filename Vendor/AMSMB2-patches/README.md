# AMSMB2 本地 patch

`Vendor/setup.sh` 会 clone AMSMB2 的 `4.0.3`（`1726aaa`），然后按顺序应用这里的 patch：

1. `0001-expose-smb2client.patch`
   - 把 `SMB2Manager.client` 从 `fileprivate` 放宽到 `internal`，供同模块的 `SMBSession` 复用底层句柄做随机读。
2. `0002-force-smb-dialect.patch`
   - 支持通过 `SMB2_FORCE_VERSION` 环境变量强制 SMB 方言，默认行为不变。

不要直接修改 `Vendor/AMSMB2` 里的源码；需要调整时改 patch 或新增 patch，再运行：

```bash
./Vendor/setup.sh
```

升级 AMSMB2 时：

1. 更新 `Vendor/setup.sh` 里的 `AMSMB2_REF` / `AMSMB2_COMMIT`；
2. 重新生成 patch 并确认 `git apply --check` 能通过；
3. 编译通过后提交 patch 与脚本。
