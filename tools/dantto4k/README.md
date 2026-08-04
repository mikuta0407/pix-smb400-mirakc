# dantto4k armv7 ビルド再現手順

**qemu 上の armv7 Alpine コンテナでネイティブビルド**する。クロスコンパイルではない。
TSDuck 込みで **約 4 時間**かかる（エミュレーションのオーバーヘッドで、実機性能とは無関係）。

成果物は `bin/dantto4k` として同梱済みなので、通常この手順は不要。

## 0. 準備

```sh
# qemu の binfmt ハンドラを登録（一度だけ）
docker run --privileged --rm tonistiigi/binfmt --install arm

KIT=$(pwd)     # このリポジトリのルート
WORK=/tmp/dantto4k-build && mkdir -p "$WORK" && cd "$WORK"
git clone https://github.com/nekohkr/dantto4k.git
cd dantto4k
git submodule update --init --recursive --depth 1

# x86 依存を外すパッチ
git apply "$KIT"/tools/dantto4k/01-armv7-portability.patch
```

## ⚠️ `--hostname` を必ず固定すること

TSDuck は出力先を `bin/release-<arch>-<hostname>/` にする
（`scripts/make-config.sh` の `hpart="-$HOSTNAME"`）。

**Docker はコンテナごとにホスト名をランダム生成する**ため、指定しないと
ビルドしたコンテナと install するコンテナで別ディレクトリを見に行き、

```
install: cannot stat '.../bin/release-arm-<別のhash>/tsduck.tables.model.xml': No such file or directory
```

で失敗する。以下の全コマンドで `--hostname 40e90cf6db80` を揃えること
（値自体は何でもよいが、全ステージで同一にする）。

## 1. TSDuck のビルド（約 4 時間 / 4 コア）

```sh
cd "$WORK"/dantto4k
docker run --rm --name tsduck-armv7 --platform linux/arm/v7 \
  --hostname 40e90cf6db80 \
  -v "$PWD":/work -w /work/thirdparty/tsduck \
  -v "$KIT/tools/dantto4k/build-tsduck-armv7.sh":/build.sh:ro \
  alpine:3.21 sh /build.sh
```

`libtscore` と `libtsduck` だけを作る。`tsplugins` / `tstools` は
dantto4k がリンクしないので省略（エミュレーション下ではリンクが重い）。

## 2. dantto4k 本体のビルド

TSDuck の install 先はコンテナの `/usr` で永続しないので、
**install と dantto4k のビルドは同一コンテナで**行う。

```sh
docker run --rm --name dantto4k-armv7 --platform linux/arm/v7 \
  --hostname 40e90cf6db80 \
  -v "$PWD":/work \
  -v "$KIT/tools/dantto4k/build-dantto4k-armv7.sh":/build.sh:ro \
  alpine:3.21 sh /build.sh
```

## 3. 検証（実行確認 + 静的リンク）

TSDuck の install 先はコンテナの `/usr` で永続しないので、
install・実行確認・静的リンクは 1 コンテナの中でまとめてやる。

BS4K の実データが無いので、合成した TLV ヌルパケット列を流し、
統計値でデマルチプレクサが実際にストリームを消費したことを確認する。

```sh
M="$KIT"/tools/dantto4k
docker run --rm --platform linux/arm/v7 --hostname 40e90cf6db80 \
  -v "$WORK/dantto4k":/work \
  -v $M/03-verify-armv7.sh:/verify.sh:ro \
  -v $M/02-gen-tlv.py:/gen-tlv.py:ro \
  -v $M/04-pcsc-stub.c:/pcsc-stub.c:ro \
  alpine:3.21 sh /verify.sh
```

成果物は `build/dantto4k-static`（strip 後 8.5MB、完全に静的）。

> **注意**: dantto4k は入力か出力が `-` のとき進捗も統計も自動で無効化する
> （`dantto4k.cpp:118-121`）。統計を見たい確認はファイル入出力で行う必要がある。

## ファイル

| ファイル | 内容 |
|---|---|
| `01-armv7-portability.patch` | dantto4k の x86 依存を外すパッチ（`-maes -msse4.1` と AES-NI） |
| `02-gen-tlv.py` | 合成 TLV ヌルパケット生成 |
| `03-verify-armv7.sh` | qemu 上での実行確認と静的リンク |
| `04-pcsc-stub.c` | 静的リンク用の PCSC スタブ（remux 専用ビルドでのみ使うこと） |
| `build-tsduck-armv7.sh` | ステージ 1（コンテナ内で実行される） |
| `build-dantto4k-armv7.sh` | ステージ 2（コンテナ内で実行される） |
