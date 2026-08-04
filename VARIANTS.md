# 機種差（PIX-SMB400 / TU-BUHD100）

Hi3798CV200 のこの基板は複数のブランドで売られていて、**ブート部分だけ機種差がある**。
チューナー制御・mirakc 層（`bin/` `scripts/` `config/` `src/`）は**共通**。

| | PIX-SMB400 系 | TU-BUHD100 |
|---|---|---|
| 製品名 | PIXELA PIX-SMB400 | Panasonic TU-BUHD100（PIXELA 製造の OEM） |
| Ethernet PHY (`phy_addr`) | `2,1` | **`2,3`** |
| `persist.sys.usb.config` | `adb`（→ 下記） | **`adb`** |
| kernel.img | 機種の公式ファームから抽出 | 機種の公式ファームから抽出 |
| `init` バイナリ | 共通（md5 `9ce50b95ce81a86f3bf8e4b42bbb9faa`） | **同じ** |

TU-BUHD100 のブート対応は
[SomeDena786/Uboot-TU-BUHD100](https://github.com/SomeDena786/Uboot-TU-BUHD100)
が調べたもの。ここでの扱いはその情報に基づく。

---

## 0. ⚠️ `getprop` では機種を判別できない

**TU-BUHD100 実機の `getprop` は `POE-SMB400-PS1` と答える。**
中身が PIXELA 製なので、firmware の型番文字列は retail の製品名と一致しない。

```
[ro.product.model]:  [POE-SMB400-PS1]          ← TU-BUHD100 でもこう出る
[pix.hw.boardname]:  [PIX-SMB400]              ← 基板名。これも同じ
[ro.product.brand]:  [Panasonic]
[ro.product.manufacturer]: [PIXELA CORPORATION]
[vendor.jp.pixela.product.destination]: [Panasonic]   ← Panasonic 向けである手がかり
[ro.build.product]:  [kadoma]
```

### 確実な判別方法: `bootargs.bin` の `phy_addr` を読む

既に USB ブートで動いている個体なら、これが決定的。

```sh
adb pull /mnt/media_rw/sda1/bootargs.bin .
python3 - bootargs.bin <<'PY'
import sys, struct, binascii
d = open(sys.argv[1], 'rb').read()
crc  = struct.unpack_from('<I', d, 0)[0]
calc = binascii.crc32(d[4:]) & 0xFFFFFFFF
print(f"CRC32 stored=0x{crc:08x} computed=0x{calc:08x} "
      f"{'OK' if crc == calc else 'MISMATCH'}")
for line in d[4:].split(b'\x00\x00')[0].decode('ascii', 'replace').split('\x00'):
    if line.startswith('phy_addr'):
        print(" ", line)
PY
```

```
phy_addr=2,1  → PIX-SMB400
phy_addr=2,3  → TU-BUHD100
```

実測（TU-BUHD100 実機）: `phy_addr=2,3` / CRC32 `0x5d86759b`。
この CRC は `make_usb_boot.py --variant TU-BUHD100` が生成する値と一致する。

---

## 1. `phy_addr` — 間違えるとネットワークが上がらない

`bootargs.bin` に入る u-boot 環境変数。**基板の Ethernet PHY の結線に合わせる**。
外すとリンクが上がらず、DHCP も ADB over TCP も来ない
（＝シリアルコンソールか物理アクセスなしでは何もできなくなる）。

```sh
# PIX-SMB400 系（既定）
python3 boot/make_usb_boot.py

# TU-BUHD100
python3 boot/make_usb_boot.py --variant TU-BUHD100
#   または VARIANT=TU-BUHD100 python3 boot/make_usb_boot.py
```

`make_usb_boot.py` が `phy_addr` を差し替えて CRC32 を計算し直す。
それ以外（RSA 鍵の扱い、`root_rsa_pub_crc.bin` の構造）は機種共通。

---

## 2. `default.prop` — ADB が生き残るかどうか

`boot/initramfs_overlay/default.prop` は **`persist.sys.usb.config=adb`** にしてある。

上流の pix-smb400-mirakurun は `none` だが、
[Uboot-TU-BUHD100](https://github.com/SomeDena786/Uboot-TU-BUHD100) が
「init が adbd を落としてしまうのを防ぐため `adb` にした」と報告している。
**実機（POE-SMB400-PS1）で動いている initramfs も `adb` だった**ので、
こちらを既定にした。

```
persist.sys.usb.config=adb
service.adb.tcp.port=5555
ro.adb.secure=0
ro.debuggable=1
```

> ⚠️ **`repack_initramfs.sh` は既定で `default.prop` を上書きしない。**
> 材料にした `.uimg` のものが「その個体で実際に ADB が上がっている設定」なので、
> それを維持するのが最も安全。上書きしたいときだけ `OVERWRITE_DEFAULT_PROP=1`。
>
> `build_initramfs.sh`（素の kernel.img から作る初回構築）はオーバーレイの
> `default.prop` を使う。こちらは既知の良品が無いため。

---

## 3. kernel.img — 機種ごとに用意する

`build_initramfs.sh` は「その機種の公式ファームウェアの kernel.img を
binwalk で展開した initramfs cpio」を材料にする。**機種を跨いで流用しない。**

```sh
binwalk -e kernel.img         # → _kernel.img.extracted/ の中の大きい cpio
bash boot/build_initramfs.sh /path/to/_kernel.img.extracted/988000
```

`init` バイナリ自体は両機種で同一なので、`patch_init.py` のオフセットは共通。
`patch_init.py` は書き換え前のバイトを検証してから書くので、
別バージョンの `init` に当たると `[!] unexpected byte` で止まる。

---

## どちらの手順を使うか

| 状況 | 使うもの |
|---|---|
| 素の筐体を初めて構築する | `build_initramfs.sh` ＋ `make_usb_boot.py --variant <機種>` |
| 既に USB ブートで動いている個体の中身だけ更新したい | **`repack_initramfs.sh`**（kernel.img 不要・機種差を自動で引き継ぐ） |
| Mirakurun 版から乗り換える | [MIGRATION.md](./MIGRATION.md) |

**`repack_initramfs.sh` が機種差に強い**のは、材料がその個体で現に動いている
`.uimg` だから。`default.prop` も `init` もそのまま引き継がれるので、
`phy_addr` や機種固有の調整を考えなくてよい
（`bootargs.bin` を作り直さない限り `phy_addr` は変わらない）。

---

## 新しい機種を足すとき

1. その個体で `getprop ro.product.model` と
   `getprop | grep -i phy` を確認する
2. `boot/make_usb_boot.py` の `PHY_ADDR_BY_VARIANT` に 1 行足す
3. この表に追記する

```python
PHY_ADDR_BY_VARIANT = {
    "SMB400":     "2,1",
    "TU-BUHD100": "2,3",
}
```
