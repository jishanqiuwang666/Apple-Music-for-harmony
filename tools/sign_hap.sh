#!/bin/zsh
#
# 手动给未签名 hap 打上调试签名。
#
# 什么时候需要它：本机「安全删除」网关按轮次限量删除文件，hvigor 的 SignHap
# 任务每次都要删一个临时 json（signConfigCheckJson.json），配额用光时会抛
#   Error Code: 00308018 Unknown Error
# 这时 PackageHap 其实已经成功（unsigned hap 在 outputs 里），只差签名这一脚。
# 这个脚本直接用 DevEco 自带的 hap-sign-tool.jar 补上。
#
# 签名材料读的是 build-profile.json5 里那份调试证书（~/.ohos/config）。
#
# 用法：tools/sign_hap.sh
#
set -u
cd "$(dirname "$0")/.." || exit 1

JAR="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
# macOS 的 /usr/bin/java 只是个 stub（没装 JDK 会提示去 java.com 下载），
# 用 DevEco 自带的 jbr。
JAVA="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java"
CFG="/Users/jishanqiuwang/.ohos/config/default_vibecodingforharmony_r2MA4x-TvxhMDapEL3LQAO9Fi7OGXbOTNABYzadaV0E="
OUT="products/default/build/default/outputs/default"

"$JAVA" -jar "$JAR" sign-app \
  -mode localSign \
  -keystoreFile "${CFG}.p12" \
  -keystorePwd "0000001B52919502B2EF81808F065F603795E5B5F787BDB968AC9619E6609C26C0869024FAB6349C40BDA6" \
  -keyAlias "debugKey" \
  -keyPwd "0000001BC8EA9D66468329B983704910A89F12C6C3A19C80B8917C8AE892BD3AFBA19157D5AE8F3F6512F3" \
  -appCertFile "${CFG}.cer" \
  -profileFile "${CFG}.p7b" \
  -profileSigned 1 \
  -signAlg "SHA256withECDSA" \
  -compatibleVersion 26 \
  -inFile "${OUT}/musichomesample-default-unsigned.hap" \
  -outFile "${OUT}/musichomesample-default-signed.hap" 2>&1 | tail -12

ls -lh "${OUT}/musichomesample-default-signed.hap" 2>/dev/null || echo "签名未产出，检查上面的报错"
