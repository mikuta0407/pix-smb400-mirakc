#!/bin/sh
# ビルド済みの armv7 dantto4k を検証する。
#
# TSDuck の install 先はコンテナの /usr で永続しないので、
# install・実行確認・静的リンクは全部この 1 コンテナの中でやる必要がある。
#
# 実機も BS4K の実データも無いので、確認できるのは「動くか」まで。
# 合成した TLV ヌルパケット列を流し、デマルチプレクサが実際にストリームを
# 消費したことを統計値（stderr）で確認する。
#
# 注意: dantto4k は入力か出力が '-' のとき進捗も統計も自動で無効化する
#       （dantto4k.cpp:118-121）。統計を見たい確認はファイル入出力で行う。
set -e

apk add --no-cache bash coreutils make g++ gcc zlib-dev zlib-static \
    pcsc-lite-dev python3 file >/dev/null 2>&1

export NODEKTEC=1 NODTAPI=1 NOHIDES=1 NOVATEK=1 \
       NOCURL=1 NOSRT=1 NORIST=1 NOPCSC=1 NOOPENSSL=1 \
       NOJAVA=1 NOPYTHON=1 NOEDITLINE=1 \
       NODOC=1 NODOXYGEN=1 NOTEST=1 NOGITHUB=1

echo "### 0. TSDuck を install ###"
make -C /work/thirdparty/tsduck/src/libtscore install-tools install-devel >/dev/null
make -C /work/thirdparty/tsduck/src/libtsduck install-tools install-devel >/dev/null
echo "installed: $(pkg-config --modversion tsduck)"
echo

BIN=/work/build/dantto4k
python3 /gen-tlv.py 1000 /tmp/small.tlv >/dev/null

echo "### 1. バイナリの素性と実行時依存 ###"
file $BIN
ldd $BIN || true
echo

echo "### 2. --help ###"
$BIN --help 2>&1 | head -4 || true
echo

echo "### 3. デマルチプレクサが実際に TLV を消費するか（ファイル入出力・統計あり） ###"
set +e
$BIN /tmp/small.tlv /tmp/out-file.ts --frontend-descrambled --no-progress >/dev/null 2>/tmp/e-file.txt
echo "exit=$?"
set -e
grep -A6 "^TLV:" /tmp/e-file.txt || cat /tmp/e-file.txt
echo

echo "### 4. '- -' を位置引数として解釈し、パイプ入力でも同じ結果になるか ###"
# mirakc はシェルを経由せず直接 exec する。また seek 不可な入力で動く必要がある。
# リダイレクトではなくパイプにするのが要点。
cat /tmp/small.tlv | $BIN - - --frontend-descrambled >/tmp/out-pipe.ts 2>/dev/null || true
echo "file 経由: $(wc -c </tmp/out-file.ts) bytes / pipe 経由: $(wc -c </tmp/out-pipe.ts) bytes"
cmp /tmp/out-file.ts /tmp/out-pipe.ts && echo "一致" || echo "不一致"
echo

echo "### 5. 壊れた入力でクラッシュしないか ###"
set +e
head -c 200000 /dev/urandom | $BIN - - --frontend-descrambled >/dev/null 2>/dev/null
echo "exit=$? (0 なら異常入力でも落ちない)"
set -e
echo

echo "### 6. musl 静的リンク ###"
# mirakc は静的 musl にして STB の Alpine chroot を捨てる方針なので dantto4k も静的にしたい。
# Alpine の pcsc-lite-dev には libpcsclite.a が無いため、--frontend-descrambled では
# 呼ばれない PCSC シンボルをスタブで埋める（→ 04-pcsc-stub.c）。
gcc -c /pcsc-stub.c -o /tmp/pcsc-stub.o
set +e
g++ /work/build/*.o /tmp/pcsc-stub.o -static -o /work/build/dantto4k-static \
    $(pkg-config --libs --static tsduck) -lz -latomic -pthread 2>/tmp/link-err.txt
rc=$?
set -e
if [ $rc -ne 0 ]; then
    echo "静的リンク失敗 (rc=$rc):"
    grep -oE "undefined reference to \`[^']*'" /tmp/link-err.txt | sort -u | head -20
    exit 1
fi
echo "静的リンク成功"
file /work/build/dantto4k-static
ldd /work/build/dantto4k-static 2>&1 || true
echo
echo "-- 静的バイナリでも同じ統計が出るか --"
/work/build/dantto4k-static /tmp/small.tlv /tmp/out-static.ts --frontend-descrambled --no-progress \
    >/dev/null 2>/tmp/e-static.txt || true
grep -A6 "^TLV:" /tmp/e-static.txt || cat /tmp/e-static.txt
