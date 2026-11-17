# pix-smb400-mirakc

PIX-SMB400 / Panasonic TU-BUHD100（HiSilicon Hi3798CV200 / Android TV /
root 化済み）を **mirakc** のチューナーサーバーにする一式。
地上波・BS(2K)・**BS4K** に対応する。

> 動作確認は **TU-BUHD100 実機**で行った。両機種の差はブート部分だけで、
> チューナー制御と mirakc 層は共通。→ [VARIANTS.md](./VARIANTS.md)

[pix-smb400-mirakurun](https://github.com/tsuyopon123/pix-smb400-mirakurun) の派生。
root 化・チューナー制御はそのまま使い、**Mirakurun（Alpine chroot + Node.js）を
mirakc に置き換えて**ある。→ [NOTICE](./NOTICE)

**Mirakurun は使わない。** Alpine rootfs も Node.js も不要。

---

## なにが動くのか

| | 状態 |
|---|---|
| GR（地上波 / ISDB-T） | 動く |
| BS（2K / ISDB-S） | 動く |
| **BS4K（ISDB-S3）** | **動く。** MMT/TLV を dantto4k で MPEG-TS に remux |
| BS8K（`45280`、左旋） | **未確認。** 衛星ロックしない（受信設備側の問題と思われる） |
| EPG / サービススキャン | 動く。BS4K も remux 済み TS から取れる |
| EPGStation 等 | mirakc は Mirakurun 互換 API を出すのでそのまま繋がる想定 |
| 長期稼働 | **長期間動かしているとハングすることがあるかも。**原因は未特定（→ [運用上の注意](#運用上の注意)） |

実測（TU-BUHD100 実機、BS4K 33Mbps 受信中）:

| プロセス | CPU（1 コア比） | RSS |
|---|---|---|
| `dantto4k` | 32.9% | 18.5 MB |
| `mirakc` | 13.7% | 9.4 MB |
| `b61dec` | 5.8% | 23.4 MB |
| **合計** | **約 54%（4 コアなので SoC の約 13.5%）** | **約 55 MB** |

チャンネル切り替えから最初の TS パケットまで約 4 秒。

---

## ドキュメント

| | |
|---|---|
| [BOOT.md](./BOOT.md) | USB ブート・root 化・initramfs のビルド |
| [VARIANTS.md](./VARIANTS.md) | **機種差（PIX-SMB400 / TU-BUHD100）。**`phy_addr` と `default.prop` |
| [MIGRATION.md](./MIGRATION.md) | **Mirakurun 版からの移行**と切り戻し |
| [tools/dantto4k/README.md](./tools/dantto4k/README.md) | dantto4k の armv7 ビルド再現 |

## 構成

```
bin/          armv7 ビルド済みバイナリ（そのまま push できる）。SHA256SUMS 付き
config/       mirakc の設定（config.yml / strings.yml）
scripts/      デバイス上で動くシェルスクリプト
src/          チューナー／デスクランブラの C ソース
include/      b61dec のビルドに要る OpenSSL ヘッダ
boot/         USB ブート・root 化・initramfs 一式（→ BOOT.md）
  build_initramfs.sh   kernel.img から初回構築する
  repack_initramfs.sh  既に動いている .uimg にオーバーレイを当て直す
  make_usb_boot.py     bootargs.bin / root_rsa_pub_crc.bin（機種差あり）
tools/dantto4k/  dantto4k を armv7 でビルドし直すための手順とパッチ
Makefile      デプロイと運用
LICENSES/     bin/ に同梱したサードパーティのライセンス全文
kit/          配布用キット（USB に入れてインストーラを叩くだけの zip）を作るスクリプト
```

### データの流れ

```
GR   : smb400-tuner.sh → tuner-stream-ng  → b21dec ...... MPEG-TS ─┐
BS   : smb400-tuner.sh → tuner-stream-bs  → b21dec ...... MPEG-TS ─┼→ mirakc
BS4K : smb400-tuner.sh → tuner-stream-bs-ng → b61dec ... MMT/TLV ─→ dantto4k ─┘
                                                          （復号済み）  （remux）
```

`b21dec` / `b61dec` が復号を済ませるので、mirakc 側は `tuners[].decoded: true`
にして `decode-filter` を止めてある。
BS4K だけ `filters.for-channel-types.BS4K.tuner-filter` に dantto4k を挟む。
`tuner-filter` はチューナー起動時に適用されるので、**視聴もバックグラウンド
ジョブ（EPG・サービススキャン）も remux 済みの TS を見る。**

---

## セットアップ

> **既に Mirakurun 版で動いている筐体を切り替える場合は
> [MIGRATION.md](./MIGRATION.md) を見ること。**以下は素の筐体からの構築。

### かんたん構築（キット）

公式ファームウェアの `boot.img`（= `kernel.img`）を用意すれば、
USB ブート用ファイルの作成からインストーラまでを 1 つの zip にまとめられる。
以下の 1〜5 を手作業でやるのと同じ結果になる。

```sh
bash kit/build_kit.sh --tu-buhd100 /path/to/boot.img    # PIX-SMB400 なら --pix-smb400
# → dist/pix-smb400-mirakc-kit-<日付>-<commit>.zip
```

zip を展開して `README.txt` のとおりに進める。

1. `USB/<機種>/` の 3 ファイルを USB メモリにコピーし、USB ブートで起動する
2. `install.bat`（Windows）または `install.sh`（Linux）を実行して、IP アドレスを入れる

インストーラは root・機種・initramfs を確認してからファイルを送り、mirakc を起動して
API が応答するまで待つ。adb が無ければ Google の公式配布を取ってくる。
ACAS キーは実行時に入力する（キットには入らない）。

`--tu-buhd100` / `--pix-smb400` には `boot.img` のほか、復号済みのアップデート zip、
取り出し済みの initramfs cpio、USB ブートで動いている `initramfs_patched.uimg` も渡せる。
必要なもの: Docker, Python 3, cpio, gzip, zip

以下は手作業で構築する場合の手順。

### 1. root 化と USB ブート

[BOOT.md](./BOOT.md) の手順で USB ブートイメージを作り、デバイスを起動する。
ここは元リポジトリとほぼ同じ。

```sh
bash boot/build_initramfs.sh <firmware_cpio>
python3 boot/make_usb_boot.py                        # PIX-SMB400 系
python3 boot/make_usb_boot.py --variant TU-BUHD100   # TU-BUHD100
```

**`--variant` を間違えると Ethernet PHY のアドレスが合わずネットワークが
上がらない**（＝ ADB も来ない）。→ [VARIANTS.md](./VARIANTS.md)

`boot/initramfs_overlay/` の中身が initramfs に焼き込まれ、
**毎ブート `/data/local/tmp/` にコピーされる**（`init.pixboot.rc` の
`on post-fs-data`）。`sys.boot_completed` で init サービス `mirakc` が起動する。

> ⚠️ **`scripts/` の中身を ADB で直接書き換えても再起動で消える。**
> 恒久化するには `boot/initramfs_overlay/` を直して initramfs を作り直すこと。
> `make push-scripts` は再起動までの一時適用。

### 2. ACAS キー（BS4K に必須）

デバイス固有。**リポジトリには絶対に入れないこと**（`.gitignore` 済み）。

```sh
adb shell "echo '<64桁のhex>' > /data/local/tmp/.acas_key"
adb shell "chmod 600 /data/local/tmp/.acas_key"
```

### 3. チャンネル設定

`config/config.yml` は**関東（東京）向けの例**。地域に合わせて書き換える。
BS4K の `channel` は TLV ストリーム ID で、`smb400-tuner.sh` が IF 周波数に対応づける。

### 4. デプロイ

```sh
adb connect <device-ip>:5555
make push-all
make start
make status
```

### 5. 確認

```sh
make test-bs4k      # 先頭が 47 なら remux 成功
make test-gr
make services
make programs
```

`make test-bs4k` の先頭バイトの読み方:

| 先頭 | 意味 |
|---|---|
| `47 ...` | **remux 成功（MPEG-TS）。**以後 188 バイトごとに `47` |
| `7f 02` / `7f 03` | 生 TLV（復号は成功しているが remux されていない） |
| `7f ff` | Null TLV = **復号できていない。**ACAS キーを疑う |
| 何も出ない | チューナーがロックしていない |

---

## 設定（config.yml）を変える

本体の設定は `/data/local/tmp/mirakc/config.yml`。**initramfs には入っていない**ので、
`adb push` するだけで再起動後も残る（スクリプト類とは違う）。
mirakc は設定を自動で読み直さないので、**送ったら再起動する。**

```sh
# config/config.yml を編集してから
make push-config
make restart
```

本体のものを直接直すなら `adb pull` → 編集 → `adb push` → `make restart`。
その場合はリポジトリの `config/config.yml` にも反映しておくこと
（次の `make push-config` で巻き戻さないように）。

- 再起動の瞬間、視聴・録画中のストリームは切れる
- チャンネルを変えたら、番組表がそろうまでしばらくかかる

---

## ⚠️ `/proc/cpu/alignment` は必ず `2` にする

このカーネルは非アラインメモリアクセスに **SIGBUS を送る**設定（`4`）で出荷される。
dantto4k は MMT のパース中に非アラインな 64bit ロードを行うため、
**実データを流すと約 1.3 秒で Bus error で落ちる。**

```sh
echo 2 > /proc/cpu/alignment   # 2 = カーネルがソフトウェアで肩代わり（fixup）
```

`scripts/start_mirakc.sh` が起動のたびに設定するので、通常は意識しなくてよい。
コストは無視できる（33Mbps の 20 秒分で fixup 3275 回）。

> qemu ユーザーモードエミュレーションは非アラインアクセスを通してしまうため、
> **エミュレータ上のテストではこの問題は再現しない。**

---

## 運用上の注意

- **チューナーは 1 本しかない。** 視聴リクエスト（priority 0）は
  バックグラウンドジョブ（priority -1）を preempt する。
  preempt されたジョブは残りのチャンネルすべてが `Tuner unavailable` で失敗するので、
  `config.yml` の `jobs.*.schedule` は視聴しない時間帯に寄せること
- **自動再起動はしない。** init サービスは `oneshot`、`start_mirakc.sh` にも
  再起動ループは無い。このデバイスはクラッシュループで文鎮化した実績があるため
- **キルスイッチ。** ブート時の自動起動を止めたいときは
  `/data/local/tmp/mirakc.disabled` を置く。`start_mirakc.sh` は
  他に何もせず終了する（Android TV も止めない）。`/data` にあるので再起動しても残り、
  **initramfs を焼き直さずに autostart を無効化できる唯一の手段**

  ```sh
  adb shell "touch /data/local/tmp/mirakc.disabled"   # 無効化
  adb shell "rm -f /data/local/tmp/mirakc.disabled"   # 再有効化
  ```
- **`crash_guard.sh` は mirakc を kill しない**（メモリ下限ブランチは
  Node.js 向けのまま）。ブリック防止の本体である crash_dump32 フォークボム検知は
  プロセス非依存なので効く
- **`tuner_reaper.sh`** が孤児化した `tuner-stream-*` / `tunertest` を回収する
  （判定は `PPID == 1`）。preempt のたびに残骸が出るため
- **長期間動かしているとハングすることがあるかも。**連続稼働中に、
  ping も ADB も応答しなくなったことがある。原因は未特定。
  ネットワークからの死活監視（ICMP と mirakc の `40772/tcp`）を入れておくと気づきやすい。
  復旧後は `/data/local/tmp/mirakc.log`・`/sys/fs/pstore`・`/proc/last_kmsg` を見ると
  手がかりが残っているかもしれない

---

## バイナリを作り直す

`bin/` には armv7 ビルド済みのものが入っているので通常は不要。

### チューナー系（`tuner-stream-*`, `b21dec`, `b61dec`）

```sh
sudo apt install gcc-arm-linux-gnueabi libssl-dev
make build-bins      # 実機から bionic の .so を pull してリンクする
```

### mirakc

`filters.for-channel-types` / `jobs.for-channel-types`（チャンネル種別ごとに
コマンドを差し替える機能）を入れた fork が必要。
同梱の `bin/mirakc` は
[mikuta0407/mirakc の `feat/for-channel-types`](https://github.com/mikuta0407/mirakc/tree/feat/for-channel-types)
（`6d1f578a`）からビルドしたもの。

```sh
git clone -b feat/for-channel-types https://github.com/mikuta0407/mirakc.git
cd mirakc
rustup target add armv7-unknown-linux-musleabihf
CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=rust-lld \
RUSTFLAGS="-C target-feature=+crt-static" \
  cargo build --release -p mirakc --target armv7-unknown-linux-musleabihf
```

`resources/strings.yml` も一緒に配置すること（`config/strings.yml`）。

### mirakc-arib

公式の armv7 イメージから抜くのが早い。

```sh
docker pull --platform linux/arm/v7 mirakc/tools:alpine
docker create --platform linux/arm/v7 --name x mirakc/tools:alpine
docker cp x:/usr/local/bin/mirakc-arib ./bin/mirakc-arib
docker rm x
```

### dantto4k

qemu 上の armv7 Alpine でネイティブビルドする。**TSDuck 込みで約 4 時間。**
手順とパッチ: [tools/dantto4k/README.md](./tools/dantto4k/README.md)

`--frontend-descrambled` 前提のビルド（ACAS / AES-NI はスタブ）なので、
**このオプションを必ず付けること。**付け忘れると例外で止まる。

---

## ライセンス

このリポジトリのスクリプト・ソースは Apache License 2.0（[LICENSE](./LICENSE)）。
派生元の帰属は [NOTICE](./NOTICE) を参照。

`bin/` の同梱バイナリはそれぞれの上流のライセンスに従う。
ビルド元のバージョン・コミットとライセンスの対応は [NOTICE](./NOTICE)、全文は [LICENSES/](./LICENSES/)。
特に **`mirakc-arib` は GPL-2.0-or-later**（公式イメージから無改変で取り出したもの。
ソースは上流の tag `0.24.20`）。
