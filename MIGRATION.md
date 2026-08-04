# Mirakurun から mirakc への移行

[pix-smb400-mirakurun](https://github.com/tsuyopon123/pix-smb400-mirakurun) で
既に動いている筐体を mirakc に切り替える手順。

新規に素の筐体から構築する場合は [README.md](./README.md) を見ること。

---

## 何が変わるか

| | Mirakurun 版 | mirakc 版 |
|---|---|---|
| 本体 | Node.js（Alpine ARM32 rootfs に chroot） | 単一の静的リンクバイナリ |
| 常駐メモリ | Node に `--max-old-space-size=256` を強いる程度には逼迫 | パイプライン全体で約 55MB |
| BS4K | TLV を JS でパース | dantto4k で MPEG-TS に remux |
| 起動 | init サービス `mirakurun_proxy` → `start_proxy.sh` | init サービス `mirakc` → `start_mirakc.sh` |
| chroot / bind mount / `/dev` ノード作成 | 必要 | **全部不要** |
| ポート | 40772 | 40772（同じ。クライアント側の設定変更は不要） |

**API は Mirakurun 互換**なので、EPGStation 等の設定は変えなくてよい。

消えるもの: `/data/local/tmp/mirakurun-root/`（Alpine rootfs、約 200MB）と
`/data/local/tmp/mirakurun/`（Mirakurun 本体）。**切り戻せるよう、移行手順では消さない。**

---

## 移行は 2 段階

| | やること | 再起動 | 元に戻るか |
|---|---|---|---|
| **A. 試用** | バイナリと設定を置いて手動で起動 | 不要 | **再起動すれば勝手に Mirakurun に戻る** |
| **B. 恒久化** | initramfs を焼き直してブート経路を差し替える | 要 | `use_mirakurun` 相当の切り戻しは無い（.bak を書き戻す） |

**まず A で動作確認してから B に進むこと。**

> ⚠️ `/data/local/tmp/` の `start_proxy.sh` / `crash_guard.sh` /
> `stop_android_tv.sh` / `smb400-tuner.sh` は
> **initramfs が毎ブート上書きする**（`init.pixboot.rc` の `on post-fs-data`）。
> A で `adb push` した内容は再起動で消える。これは安全側の性質でもある。

---

## A. 試用（再起動不要・自動で元に戻る）

### A-1. Mirakurun を止める

init サービスなので `stop` を使う。`pkill` だと init が復活させる。

```sh
ADB="adb -s <device-ip>:5555"
$ADB shell "stop mirakurun_proxy"
```

チューナーは 1 本しかないので、**これをやらないと mirakc がチューナーを掴めない。**

### A-2. 一式を置く

```sh
make push-all      # bin/ scripts/ config/ をまとめて転送
```

`config/config.yml` のチャンネル定義は関東（東京）向けの例なので、
Mirakurun 側の `channels.yml` を見ながら地域に合わせて直しておくこと。
Mirakurun は 1 サービス 1 エントリだが、mirakc は同じ物理チャンネルを
1 エントリにまとめて `services: [...]` で列挙する。

```yaml
# Mirakurun (channels.yml)          # mirakc (config.yml)
- name: NHK BS                      - name: NHK BS
  type: BS                            type: BS
  channel: BS15_0                     channel: BS15_0
  serviceId: 101                      services: [101, 102]
- name: NHK BS (102)
  type: BS
  channel: BS15_0
  serviceId: 102
```

ACAS キー（`/data/local/tmp/.acas_key`）は Mirakurun 版と共通なので、
既に入っていればそのまま使える。

### A-3. 起動して確認

```sh
make start
make status
make test-bs4k     # 先頭が 47 なら remux 成功
make services
```

### A-4. 戻したいとき

```sh
make stop
$ADB shell "start mirakurun_proxy"
```

**あるいは再起動するだけでよい**（ブート経路はまだ Mirakurun のままなので）。

---

## B. 恒久化（initramfs を焼き直す）

ブート時に mirakc が上がるようにする。ここまでやると Mirakurun は起動しなくなる。

### B-1. 現在動いている initramfs を材料にする

`kernel.img` も binwalk も要らない。**実機の USB メディアは ADB から見える。**

```sh
$ADB shell "ls -la /mnt/media_rw/sda1/"
$ADB pull /mnt/media_rw/sda1/initramfs_patched.uimg .
```

### B-2. オーバーレイを当て直す

```sh
bash boot/repack_initramfs.sh initramfs_patched.uimg boot/initramfs_new.uimg
```

`repack_initramfs.sh` がやること:

- `init.pixboot.rc` を差し替え（`mirakurun_proxy` → `mirakc` サービス、
  `on post-fs-data` のコピー一覧を mirakc 用に）
- `start_mirakc.sh` / `tuner_reaper.sh` / `crash_guard.sh` /
  `stop_android_tv.sh` / `smb400_tuner.sh` を焼き込み
- `start_proxy.sh` を削除
- **`default.prop` は元の .uimg のものを維持**（機種差があるため。→ [VARIANTS.md](./VARIANTS.md)）
- `init` バイナリは触らない（パッチ済みのものをそのまま引き継ぐ）
- 焼く前に健全性チェック（ADB 関連プロパティ、`copy` 行とファイルの対応、
  サービスが指すスクリプトの実在）

### B-3. 書き戻して再起動

```sh
# 必ずバックアップを取る（USB メディアは 3 ファイルとも退避しておく）
$ADB shell "cd /mnt/media_rw/sda1 && \
    cp initramfs_patched.uimg initramfs_patched.uimg.bak && \
    cp bootargs.bin bootargs.bin.bak && \
    cp root_rsa_pub_crc.bin root_rsa_pub_crc.bin.bak && sync"

$ADB push boot/initramfs_new.uimg /mnt/media_rw/sda1/initramfs_patched.uimg
$ADB shell sync

# 書けたバイト列が一致するか必ず確認する
$ADB pull /mnt/media_rw/sda1/initramfs_patched.uimg /tmp/readback.uimg
cmp boot/initramfs_new.uimg /tmp/readback.uimg && echo "readback OK"

$ADB reboot
```

> **リモートだけで作業しているなら、先にキルスイッチを置いてから再起動すること。**
> ブート時に mirakc を起動させず、素の状態で上がってくることを先に確認できる。
>
> ```sh
> $ADB shell "touch /data/local/tmp/mirakc.disabled"   # ← 再起動前に置く
> $ADB reboot
> # 起動を確認してから
> $ADB shell "rm -f /data/local/tmp/mirakc.disabled"
> $ADB shell "start mirakc"
> ```
>
> `/data/local/tmp/mirakc.disabled` があると `start_mirakc.sh` は
> **何もせずに終了する**（Android TV も止めないし、プロセスも殺さない）。
> `/data` にあるので再起動しても残る。
> これが無いと「ブート時に自動起動する設定」を止める手段が
> initramfs の焼き直ししか無くなり、失敗時に詰む。

### B-4. 確認

```sh
# 起動には 1〜2 分かかる
adb connect <device-ip>:5555
$ADB shell "getprop init.svc.mirakc"     # → running もしくは stopped(oneshot 完了)
make status
```

### ⚠️ 失敗したときの復旧には物理アクセスが要る

起動しなくなった場合、ADB でも直せない。以下のいずれかになる。

1. USB メディアを PC に挿し、`initramfs_patched.uimg.bak` を
   `initramfs_patched.uimg` に書き戻す
2. USB メディアを抜く（＝ USB ブートしなくなり、eMMC の素の Android TV に戻る）

**どちらも筐体に手が届く必要がある。**
リモートだけで作業している場合は B に進まないこと。

### B-5. Mirakurun に戻す

```sh
$ADB shell "cp /mnt/media_rw/sda1/initramfs_patched.uimg.bak \
                /mnt/media_rw/sda1/initramfs_patched.uimg"
$ADB shell sync
$ADB reboot
```

`/data/local/tmp/mirakurun/` と `mirakurun-root/` は消していないので、
これだけで元の Mirakurun 構成に戻る。

---

## 移行後の後片付け（任意）

動作が安定してから。**急がなくてよい。**

```sh
# Alpine rootfs（約 200MB）と Mirakurun 本体を消す
$ADB shell "rm -rf /data/local/tmp/mirakurun-root /data/local/tmp/mirakurun"
```

消すと B-5 の切り戻しができなくなるので、**USB メディアの `.bak` と合わせて
戻せなくなる点に注意**。ディスクに余裕があるなら残しておくのが安全。

---

## つまずきやすいところ

| 症状 | 原因 | 対処 |
|---|---|---|
| mirakc がチューナーを掴めない | Mirakurun が生きている | `stop mirakurun_proxy`。`pkill` では init が復活させる |
| BS4K で 1.3 秒後に Bus error | `/proc/cpu/alignment` が `4`（SIGBUS） | `start_mirakc.sh` が `2` に設定する。手動なら `echo 2 > /proc/cpu/alignment` |
| BS4K のストリームが `7f ff` で始まる | ACAS 未復号 | `/data/local/tmp/.acas_key` を確認 |
| BS4K が例外で止まる | `--frontend-descrambled` の付け忘れ | 同梱の dantto4k は ACAS 経路をスタブ化したビルド |
| 地上波が全滅 | `smb400-tuner.sh` の `portId` が `0x20` | 十進の `32` にする（このリポジトリでは修正済み） |
| `adb shell "... pkill -f xxx ..."` が無言で失敗 | adb shell 自身のコマンドラインがマッチして自殺（exit 137） | kill と後片付けを別の adb 呼び出しに分ける |
| 再起動したら設定が戻った | `/data/local/tmp/` のスクリプトは initramfs が上書きする | 恒久化するなら B を行う |
